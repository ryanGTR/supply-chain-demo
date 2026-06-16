#!/usr/bin/env python3
"""scan_verdict — 把 Trivy 掃描結果濃縮成一個「判定」物證(scan-verdict.json)。

L4 驗章(verify_release.py)要的是「掃描判定 = pass」這個物證,而非原始 SARIF。
本工具讀 Trivy JSON(`trivy fs --format json`)或 SARIF,數 HIGH/CRITICAL 漏洞,
產出 {verdict, counts, tool}。預設 HIGH/CRITICAL > 0 即 verdict=fail。環境無關,github/ADO 共用。

用法:
  scan_verdict.py --in trivy.json --out scan-verdict.json [--fail-on HIGH,CRITICAL]
Exit: 0 一律(本工具只「產判定」,不當閘門;閘門在 verify_release.py 讀 verdict)。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def count_trivy_json(doc: dict, sev_set: set[str]) -> tuple[int, dict]:
    counts: dict[str, int] = {}
    for res in doc.get("Results", []) or []:
        for v in res.get("Vulnerabilities", []) or []:
            sev = str(v.get("Severity", "")).upper()
            counts[sev] = counts.get(sev, 0) + 1
    blocking = sum(counts.get(s, 0) for s in sev_set)
    return blocking, counts


def count_sarif(doc: dict, sev_set: set[str]) -> tuple[int, dict]:
    # SARIF 後備:用 result.level 粗略對應(error≈HIGH/CRITICAL)
    counts: dict[str, int] = {}
    for run in doc.get("runs", []) or []:
        for r in run.get("results", []) or []:
            lvl = str(r.get("level", "warning")).upper()
            counts[lvl] = counts.get(lvl, 0) + 1
    blocking = counts.get("ERROR", 0)
    return blocking, counts


def main() -> int:
    ap = argparse.ArgumentParser(description="Trivy 掃描結果 → scan-verdict.json")
    ap.add_argument("--in", dest="inp", required=True, help="Trivy JSON 或 SARIF")
    ap.add_argument("--out", required=True, help="輸出 scan-verdict.json")
    ap.add_argument("--fail-on", default="HIGH,CRITICAL", help="哪些嚴重度算 blocking(逗號分隔)")
    ap.add_argument("--tool", default="trivy", help="掃描工具名(記進判定)")
    args = ap.parse_args()

    p = Path(args.inp)
    if not p.is_file():
        # 沒有掃描結果 = 沒有證據 → 保守判 fail(fail-closed 的精神)
        verdict = {"verdict": "fail", "reason": f"找不到掃描結果:{args.inp}", "tool": args.tool}
        Path(args.out).write_text(json.dumps(verdict, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"⚠ 找不到掃描結果 {args.inp} → verdict=fail（保守）")
        return 0

    doc = json.loads(p.read_text(encoding="utf-8"))
    sev_set = {s.strip().upper() for s in args.fail_on.split(",") if s.strip()}
    if "Results" in doc:
        blocking, counts = count_trivy_json(doc, sev_set)
    elif "runs" in doc:
        blocking, counts = count_sarif(doc, sev_set)
    else:
        blocking, counts = 0, {}

    verdict = {
        "verdict": "pass" if blocking == 0 else "fail",
        "tool": args.tool,
        "failOn": sorted(sev_set),
        "blocking": blocking,
        "counts": counts,
    }
    Path(args.out).write_text(json.dumps(verdict, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"掃描判定:{verdict['verdict']}(blocking={blocking}, counts={counts}) → {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
