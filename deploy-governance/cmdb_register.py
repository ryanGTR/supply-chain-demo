#!/usr/bin/env python3
"""CMDB 登錄器(L4)— 把一個「通過驗章、已發佈的 artifact」登錄為組態項目(CI)。

L4 的後半:verify_release.py 放行後,把「這次發佈」寫成一筆 CMDB-as-code CI,
帶**端到端證據鏈**(build → scan → sign → verify)。版控史 = 組態基線與發佈史。
環境無關、檔案型:輸入是 ReleaseManifest(見 release-contract.md),非容器。

冪等:同一 (app/component[/environment]) 重跑覆寫同一 CI(版控 diff 即發佈史)。

對應治理控制項:ISO 20000 組態管理;ISO 27001 A.8.9 組態管理、A.8.28 供應鏈完整性。

用法:
  cmdb_register.py --manifest <release-manifest.yaml> [--cmdb-dir cmdb] [--verified-at <iso8601>]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("✗ 需要 PyYAML(pip install pyyaml)")


def main() -> int:
    ap = argparse.ArgumentParser(description="CMDB 登錄器(L4,檔案型已發佈 artifact)")
    ap.add_argument("--manifest", required=True, help="ReleaseManifest YAML")
    ap.add_argument("--cmdb-dir", default="cmdb", help="CMDB 根目錄(預設 cmdb)")
    ap.add_argument("--verified-at", default="", help="驗章通過時間(ISO8601;留空則不填,由 CI 帶入)")
    args = ap.parse_args()

    man_path = Path(args.manifest)
    if not man_path.is_file():
        sys.exit(f"✗ 找不到 ReleaseManifest:{man_path}")
    man = yaml.safe_load(man_path.read_text(encoding="utf-8")) or {}
    meta = man.get("metadata", {}) or {}
    spec = man.get("spec", {}) or {}
    art = spec.get("artifact", {}) or {}
    sig = spec.get("signature", {}) or {}
    ev = spec.get("evidence", {}) or {}

    app = meta.get("app")
    component = meta.get("component")
    if not app or not component:
        sys.exit("✗ ReleaseManifest 缺 metadata.app / metadata.component")
    env = meta.get("environment") or ""

    ci_id = f"ci-{app}-{component}" + (f"-{env}" if env else "")
    ci = {
        "apiVersion": "cmdb/v1",
        "kind": "ReleasedArtifact",
        "metadata": {
            "ciId": ci_id, "app": app, "component": component,
            "ecosystem": meta.get("ecosystem"), "environment": env,
        },
        "spec": {
            "artifact": {
                "coordinates": art.get("coordinates"), "type": art.get("type"),
                "digest": art.get("digest"), "feed": art.get("feed", ""),
            },
            # 端到端證據鏈:每一段都指向版控內的物證,可被 cmdb_validate fail-closed 驗存在。
            "evidenceChain": {
                "build": {"provenance": ev.get("provenance", "")},
                "scan": {"sbom": ev.get("sbom"), "scanVerdict": ev.get("scanVerdict")},
                "test": {"testReport": ev.get("testReport"), "testCount": ev.get("testCount", 0)},
                "sign": {"signature": sig.get("path"), "mode": sig.get("mode", "key-pair")},
                "verify": {"gate": "passed", "verifiedAt": args.verified_at},
            },
            "provenance": {
                "requestedBy": meta.get("requestedBy", ""),
                "serviceRequest": meta.get("serviceRequest", ""),
                "releaseManifest": str(man_path),
            },
            "dataClassification": spec.get("dataClassification", ""),
            "relationships": [
                {"type": "released-from", "target": str(man_path)},
                {"type": "signed-by", "target": "trust/cosign.pub"},
            ],
        },
    }

    out_dir = Path(args.cmdb_dir) / (env or "released")
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{app}-{component}.yaml"
    header = (
        "# CMDB Configuration Item(CI)— 由 deploy-governance/cmdb_register.py 於驗章通過後產出。\n"
        "# 一筆 = 一個已發佈、已驗章的檔案型 artifact(含 build→scan→sign→verify 證據鏈)。\n"
        "# 版控史即組態基線與發佈史。對應:ISO 20000 組態管理 / ISO 27001 A.8.9 / A.8.28。請勿手改。\n"
    )
    out.write_text(header + yaml.safe_dump(ci, allow_unicode=True, sort_keys=False), encoding="utf-8")
    print(f"✅ 已登錄 CI:{out}  ({ci_id}, {art.get('digest')})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
