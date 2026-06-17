#!/usr/bin/env python3
"""emit_manifest — 由 CI 在 sign 之後產出 ReleaseManifest(交接契約)。

把「已簽 artifact + 證據」打包成一份 ReleaseManifest YAML(見 release-contract.md),
交給 verify_release.py / cmdb_register.py 消費。digest 直接由 artifact 檔算(不信任外部輸入)。
testReport 由 surefire 報告目錄算雜湊(沒有報告 → 留空,讓 L4 fail-closed 擋下)。環境無關。

用法:
  emit_manifest.py --app supply-chain-backend --component backend --ecosystem java \
    --artifact backend/target/liberty-backend.war --signature <...>.sig --mode key-pair \
    --sbom sbom-backend.json --scan-verdict scan-verdict-backend.json \
    --surefire-dir backend/target/surefire-reports --out release-backend.yaml
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("✗ 需要 PyYAML")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()


def surefire_fingerprint(dirpath: Path) -> tuple[str, int]:
    """把 surefire 報告(TEST-*.xml)內容串接後雜湊,並數測試數。沒有 → ('', 0)。"""
    if not dirpath.is_dir():
        return "", 0
    xmls = sorted(dirpath.glob("TEST-*.xml"))
    if not xmls:
        return "", 0
    h = hashlib.sha256()
    tests = 0
    for x in xmls:
        data = x.read_bytes()
        h.update(data)
        # 粗略數 <testcase 數量(避免引 XML 解析相依)
        tests += data.count(b"<testcase")
    return "sha256:" + h.hexdigest(), tests


def main() -> int:
    ap = argparse.ArgumentParser(description="產出 ReleaseManifest")
    ap.add_argument("--app", required=True)
    ap.add_argument("--component", required=True)
    ap.add_argument("--ecosystem", required=True)
    ap.add_argument("--artifact", required=True, help="artifact 檔(算 digest)")
    ap.add_argument("--type", default="", help="artifact 型態;留空則由副檔名推斷")
    ap.add_argument("--coordinates", default="", help="座標(GAV / package 名);留空則用檔名")
    ap.add_argument("--signature", required=True)
    ap.add_argument("--mode", default="key-pair")
    ap.add_argument("--certificate", default="")
    ap.add_argument("--sbom", required=True)
    ap.add_argument("--scan-verdict", required=True)
    ap.add_argument("--surefire-dir", default="", help="surefire 報告目錄(算 testReport / testCount)")
    ap.add_argument("--requested-by", default="ci")
    ap.add_argument("--environment", default="")
    ap.add_argument("--data-classification", default="internal")
    # 變更治理(T2.4):可選;有就寫進 metadata.change,交給 validate_change_class.py fail-closed 驗。
    ap.add_argument("--change-type", default="", help="standard|normal|emergency|retroactive(留空=不寫 change 區塊)")
    ap.add_argument("--priority", default="", help="P1..P4")
    ap.add_argument("--justification", default="", help="emergency/retroactive 必填")
    ap.add_argument("--pir-owner", default="")
    ap.add_argument("--pir-due", default="", help="YYYY-MM-DD")
    ap.add_argument("--nonconformity", default="", help="retroactive 必填(補單≠漂白)")
    ap.add_argument("--expedite-by", default="")
    ap.add_argument("--expedite-reason", default="")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    art = Path(args.artifact)
    if not art.is_file():
        sys.exit(f"✗ 找不到 artifact:{art}")
    digest = sha256_file(art)
    art_type = args.type or art.suffix.lstrip(".") or "bin"
    coords = args.coordinates or art.name
    test_fp, test_count = surefire_fingerprint(Path(args.surefire_dir)) if args.surefire_dir else ("", 0)

    manifest = {
        "apiVersion": "supplychain/v1",
        "kind": "ReleaseManifest",
        "metadata": {
            "app": args.app, "component": args.component, "ecosystem": args.ecosystem,
            "requestedBy": args.requested_by, "environment": args.environment,
        },
        "spec": {
            "artifact": {
                "coordinates": coords, "type": art_type,
                "path": args.artifact, "digest": digest, "feed": "",
            },
            "signature": {"path": args.signature, "mode": args.mode, "certificate": args.certificate},
            "evidence": {
                "sbom": args.sbom, "scanVerdict": args.scan_verdict,
                "testReport": test_fp, "testCount": test_count, "provenance": "",
            },
            "dataClassification": args.data_classification,
        },
    }

    # 變更治理區塊(可選):任一 change 欄位有給才寫(缺則 = standard,零摩擦)。
    change: dict = {}
    if args.change_type:
        change["type"] = args.change_type
    if args.priority:
        change["priority"] = args.priority
    if args.justification:
        change["justification"] = args.justification
    if args.pir_owner or args.pir_due:
        change["pir"] = {"owner": args.pir_owner, "dueBy": args.pir_due}
    if args.nonconformity:
        change["nonconformity"] = args.nonconformity
    if args.expedite_by or args.expedite_reason:
        change["expedite"] = {"by": args.expedite_by, "reason": args.expedite_reason}
    if change:
        manifest["metadata"]["change"] = change

    Path(args.out).write_text(
        yaml.safe_dump(manifest, allow_unicode=True, sort_keys=False), encoding="utf-8")
    print(f"✅ 已產出 ReleaseManifest:{args.out}（digest={digest}, testCount={test_count}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
