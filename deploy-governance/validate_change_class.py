#!/usr/bin/env python3
"""變更分類驗證器(L4,檔案型)— fail-closed。

把 itops 右側的「部署側變更治理」(Phase E:變更分類 / 急件+PIR / 補單≠漂白)
移植成**環境無關、檔案型**的閘門,對 ReleaseManifest(見 release-contract.md)的
`metadata.change` 區塊執行強制檢查。例外路徑(急件/插單/補單)是供應鏈右側的現實校正層:
真實世界會有「先上線後補審」,但**鬆綁的只能是人工審核的時點/對象/順序,絕不是技術閘門**
(簽章/掃描/驗章對所有 changeType 一律強制,見規則 5)。

驗證規則(全部 fail-closed):
  1. change.type 必須是 standard|normal|emergency|retroactive(缺 = standard)。
  2. change.priority 若有,必須是 P1..P4。
  3. emergency / retroactive ⇒ 必附 justification(非空)——例外要有理由。
  3b. emergency / retroactive ⇒ 必附 pir{owner, dueBy}——先做後審/事後補不可賴帳。
  3c. retroactive(補單)⇒ 必附 nonconformity(關聯的不符合事項/漂移單)——補單≠漂白。
  4. expedite(插單)若有,必須同時有 by 與 reason(誰批 + 為何加急,SoD + 留痕)。
  5. ★ 安全閘門不可因 changeType 關閉:manifest 內不得出現任何「繞過旗標」
     (skipVerify / bypassGate / disableScan…)——本層核心鐵則,急件也不例外。

對應治理控制項:
  ISO 27001 A.8.32 變更管理(分類);A.8.28 完整性(閘門不鬆綁);
  A.5.3 職責分離(插單需授權);A.5.36 合規審查(PIR / 補單矯正)。

用法:
  validate_change_class.py [--path release-store]      # 掃目錄下所有 ReleaseManifest
  validate_change_class.py --manifest <release.yaml>   # 或驗單一份
Exit code:0 全通過;1 任一不合規(fail-closed)。
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("✗ 需要 PyYAML(pip install pyyaml)")

CHANGE_TYPES = {"standard", "normal", "emergency", "retroactive"}
NEEDS_JUSTIFICATION = {"emergency", "retroactive"}
NEEDS_PIR = {"emergency", "retroactive"}   # 急件先做後審、補單事後補,都要承諾 PIR
NEEDS_NONCONFORMITY = {"retroactive"}      # 補單必須綁「不符合事項」(補單≠漂白)
PRIORITY_RE = re.compile(r"^P[1-4]$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

# 「繞過旗標」偵測:key 名同時帶「關閉意圖」+「安全閘門對象」即視為試圖鬆綁護欄。
BYPASS_INTENT = r"(skip|bypass|disable|ignore|no|force)"
GATE_TARGET = r"(gate|verif|sign|signature|scan|sca|check|policy|attest)"
BYPASS_RE = re.compile(BYPASS_INTENT + r"[_-]?" + GATE_TARGET, re.IGNORECASE)


def walk_keys(node, prefix=""):
    """遞迴收集所有 key 的點分路徑(供繞過旗標掃描)。"""
    if isinstance(node, dict):
        for k, v in node.items():
            path = f"{prefix}.{k}" if prefix else str(k)
            yield path
            yield from walk_keys(v, path)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk_keys(v, f"{prefix}[{i}]")


def collect_manifests(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    if path.is_dir():
        return sorted(p for p in path.rglob("*.yaml") if "/sig/" not in p.as_posix())
    return []


def validate_one(f: Path, req: dict, err) -> None:
    meta = req.get("metadata", {}) or {}
    # change 區塊可缺(= standard,零摩擦);有才逐項驗。
    change = meta.get("change", {}) or {}

    # 1. type(缺 = standard)
    change_type = change.get("type", "standard")
    if change_type not in CHANGE_TYPES:
        err(f, "ISO 27001 A.8.32",
            f"change.type={change_type!r} 非法(應為 {sorted(CHANGE_TYPES)})")
        change_type = "standard"  # 後續以保守值續驗,避免雪崩

    # 2. priority
    priority = change.get("priority")
    if priority is not None and not PRIORITY_RE.match(str(priority)):
        err(f, "ISO 20000 變更管理", f"change.priority={priority!r} 非法(應為 P1..P4)")

    # 3. emergency / retroactive ⇒ justification
    if change_type in NEEDS_JUSTIFICATION:
        if not str(change.get("justification", "") or "").strip():
            err(f, "ISO 27001 A.8.32",
                f"change.type={change_type} 必須附 justification(例外要有理由)")

    # 3b. emergency / retroactive ⇒ pir{owner, dueBy}
    if change_type in NEEDS_PIR:
        pir = change.get("pir")
        if not isinstance(pir, dict):
            err(f, "ISO 27001 A.8.32 / A.5.36",
                f"{change_type} 必須附 pir{{owner, dueBy}}(承諾事後回顧的負責人與到期日)")
        else:
            if not str(pir.get("owner", "") or "").strip():
                err(f, "ISO 27001 A.5.36", f"{change_type} 的 pir 缺 owner(PIR 負責人)")
            due = str(pir.get("dueBy", "") or "")
            if not DATE_RE.match(due):
                err(f, "ISO 27001 A.5.36",
                    f"{change_type} 的 pir.dueBy 須為 YYYY-MM-DD(目前:{due!r})")

    # 3c. retroactive(補單)⇒ nonconformity(補單≠漂白)
    if change_type in NEEDS_NONCONFORMITY:
        if not str(change.get("nonconformity", "") or "").strip():
            err(f, "ISO 27001 A.5.36 / 矯正措施",
                "retroactive(補單)必須綁 nonconformity(關聯的不符合事項/漂移單)"
                "——補單≠漂白,要連回根因。")

    # 4. expedite(插單)需 by + reason
    expedite = change.get("expedite")
    if expedite is not None:
        if not isinstance(expedite, dict) or not str(expedite.get("by", "") or "").strip() \
                or not str(expedite.get("reason", "") or "").strip():
            err(f, "ISO 27001 A.5.3",
                "expedite(插單)必須同時有 by 與 reason(誰批 + 為何加急)")

    # 5. ★ 繞過旗標守衛:任一 changeType 都不可關閉安全閘門
    for key_path in walk_keys(req):
        leaf = key_path.split(".")[-1]
        if BYPASS_RE.search(leaf):
            err(f, "ISO 27001 A.8.28 完整性",
                f"偵測到繞過旗標 {key_path!r}——簽章/掃描/驗章不可因 changeType 關閉。")


def main() -> int:
    ap = argparse.ArgumentParser(description="變更分類驗證器(L4,檔案型,fail-closed)")
    ap.add_argument("--path", default="release-store",
                    help="掃描根目錄(找所有 ReleaseManifest);預設 release-store")
    ap.add_argument("--manifest", default="", help="只驗單一 ReleaseManifest 檔(覆寫 --path)")
    args = ap.parse_args()

    target = Path(args.manifest) if args.manifest else Path(args.path)
    if not target.exists():
        print(f"✗ 找不到掃描目標:{target}")
        return 1

    errors: list[str] = []

    def err(f: Path, control: str, msg: str) -> None:
        errors.append(f"  ❌ {f} [{control}]:{msg}")

    checked = 0
    for f in collect_manifests(target):
        try:
            req = yaml.safe_load(f.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError as exc:
            err(f, "結構", f"YAML 解析失敗:{exc}")
            continue
        if req.get("kind") != "ReleaseManifest":
            continue  # 只驗 ReleaseManifest
        checked += 1
        validate_one(f, req, err)

    print(f"🔍 變更分類驗證:共 {checked} 個 ReleaseManifest")
    if errors:
        print("\n".join(errors))
        print(f"\n✗ 變更分類驗證失敗:{len(errors)} 項不合規(fail-closed)")
        return 1
    print("✅ 變更分類驗證通過:分類合法、例外附理由與 PIR、補單綁不符合事項、插單留痕、無繞過旗標。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
