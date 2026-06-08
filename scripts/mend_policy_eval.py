#!/usr/bin/env python3
"""
mend_policy_eval.py — 用 Mend 的判定哲學評估 Trivy 掃描結果。

仿 Mend：default-allow（元件預設可用）+ policy → 命中 reject 政策才擋。
對比 dep-policy 的 default-deny 顯式白名單。

用法:
    mend_policy_eval.py --policy mend-sim/mend-policy.yaml \
        backend=trivy-backend.json frontend=trivy-frontend.json

讀 policy（security 漏洞門檻 / license 禁用清單 / age）套到 Trivy JSON：
  - 印出 Mend 風格 inventory（discovery 出的全部元件 + 漏洞/授權摘要）
  - 列出違規（reject / warn）
  - 有 reject 違規 → exit 1（= build fail）；否則 exit 0
"""
import argparse
import json
import sys

try:
    import yaml
except ImportError:
    sys.exit("需要 PyYAML：pip install pyyaml（CI runner 已預裝）")

SEV_RANK = {"UNKNOWN": 0, "LOW": 1, "MEDIUM": 2, "HIGH": 3, "CRITICAL": 4}
C = {"red": "\033[0;31m", "grn": "\033[0;32m", "ylw": "\033[0;33m",
     "blu": "\033[0;34m", "bold": "\033[1m", "rst": "\033[0m"}


def load_policy(path):
    with open(path) as f:
        doc = yaml.safe_load(f)
    pol = {"min_severity": "CRITICAL", "banned_licenses": set(),
           "age_action": "warn", "fail_on": ["reject"]}
    for p in doc.get("policies", []):
        if p["type"] == "security":
            pol["min_severity"] = p.get("min_severity", "CRITICAL")
            pol["security_action"] = p.get("action", "reject")
        elif p["type"] == "license":
            pol["banned_licenses"] = {x.lower() for x in p.get("banned", [])}
            pol["license_action"] = p.get("action", "reject")
        elif p["type"] == "age":
            pol["age_action"] = p.get("action", "warn")
    pol["fail_on"] = doc.get("settings", {}).get("fail_on", ["reject"])
    return pol


def iter_results(trivy):
    for r in trivy.get("Results") or []:
        yield r


def evaluate(component, trivy, pol):
    """回傳 (inventory_count, vuln_rows, violations)"""
    components = set()
    vuln_rows = []          # (pkg, ver, vulnID, severity)
    violations = []         # (action, kind, detail)
    min_rank = SEV_RANK.get(pol["min_severity"], 4)

    for r in iter_results(trivy):
        for pkg in r.get("Packages") or []:
            name = pkg.get("Name")
            if name:
                components.add(f"{name}@{pkg.get('Version', '?')}")
        for v in r.get("Vulnerabilities") or []:
            sev = (v.get("Severity") or "UNKNOWN").upper()
            vuln_rows.append((v.get("PkgName"), v.get("InstalledVersion"),
                              v.get("VulnerabilityID"), sev))
            if SEV_RANK.get(sev, 0) >= min_rank:
                violations.append((
                    pol.get("security_action", "reject"), "security",
                    f"{v.get('PkgName')}@{v.get('InstalledVersion')} "
                    f"{v.get('VulnerabilityID')} ({sev})"))
        for lic in r.get("Licenses") or []:
            name = (lic.get("Name") or "").lower()
            if name in pol["banned_licenses"]:
                violations.append((
                    pol.get("license_action", "reject"), "license",
                    f"{lic.get('PkgName')} → {lic.get('Name')}"))

    return len(components), vuln_rows, violations


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--policy", required=True)
    ap.add_argument("pairs", nargs="+", help="component=trivy.json")
    ap.add_argument("--report", help="把 inventory markdown 也寫到此檔")
    args = ap.parse_args()

    pol = load_policy(args.policy)
    md = ["# Mend-style 依賴治理報告（policy-based / default-allow）", ""]
    md.append(f"政策：min_severity=`{pol['min_severity']}`，"
              f"banned_licenses={sorted(pol['banned_licenses']) or '—'}，"
              f"fail_on={pol['fail_on']}")
    md.append("")

    total_comp = 0
    all_reject = []
    all_warn = []
    sev_tally = {}

    for pair in args.pairs:
        comp, path = pair.split("=", 1)
        with open(path) as f:
            trivy = json.load(f)
        n, vrows, viol = evaluate(comp, trivy, pol)
        total_comp += n
        for _, _, _, sev in vrows:
            sev_tally[sev] = sev_tally.get(sev, 0) + 1

        print(f"\n{C['bold']}{C['blu']}═════ {comp} ═════{C['rst']}")
        print(f"    discovery：{n} 個元件（含 transitive）")
        print(f"    漏洞：{len(vrows)} 筆")
        rj = [v for v in viol if v[0] in pol["fail_on"]]
        wn = [v for v in viol if v[0] not in pol["fail_on"]]
        all_reject += [(comp,) + v for v in rj]
        all_warn += [(comp,) + v for v in wn]
        if rj:
            print(f"  {C['red']}REJECT 違規（{len(rj)}）{C['rst']}")
            for _, kind, detail in rj:
                print(f"    ✗ [{kind}] {detail}")
        else:
            print(f"  {C['grn']}  ✓ 無 reject 違規{C['rst']}")

        md += [f"## {comp}", "",
               f"- discovery：**{n}** 個元件（含 transitive）",
               f"- 漏洞：**{len(vrows)}** 筆",
               f"- REJECT 違規：**{len(rj)}**", ""]
        if rj:
            md += ["| kind | detail |", "|---|---|"]
            md += [f"| {k} | {d} |" for _, k, d in rj]
            md.append("")

    print(f"\n{C['bold']}═════ 總結 ═════{C['rst']}")
    print(f"    元件總數：{total_comp}")
    print(f"    漏洞分佈：{sev_tally or '無'}")
    if all_warn:
        print(f"  {C['ylw']}WARN（{len(all_warn)}，不擋）{C['rst']}")
        for comp, _, kind, detail in all_warn:
            print(f"    ⚠ {comp} [{kind}] {detail}")

    md += ["## 總結", "",
           f"- 元件總數：**{total_comp}**",
           f"- 漏洞分佈：`{sev_tally or '無'}`",
           f"- REJECT 違規：**{len(all_reject)}**", ""]
    if args.report:
        with open(args.report, "w") as f:
            f.write("\n".join(md) + "\n")

    if all_reject:
        print(f"\n{C['red']}{C['bold']}  ✗ Mend-style gate FAIL — "
              f"{len(all_reject)} 筆 reject 違規{C['rst']}")
        sys.exit(1)
    print(f"\n{C['grn']}{C['bold']}  ✓ Mend-style gate PASS — "
          f"default-allow，無 reject 違規{C['rst']}")


if __name__ == "__main__":
    main()
