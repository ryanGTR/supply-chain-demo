#!/usr/bin/env python3
"""CMDB 驗證器(L4)— fail-closed 驗證已登錄的 ReleasedArtifact CI 結構與物證。

驗每一筆 cmdb/**/*.yaml 的 ReleasedArtifact CI:
  1. 結構欄位齊全(ciId / app / component / artifact.digest)。
  2. digest 為有效 sha256。
  3. 證據鏈物證存在:SBOM 檔、掃描判定檔、簽章檔(對 --root 解析)。
  4. testCount >= 1(空套件不算證據)。
任一不過 → exit 1(fail-closed):CMDB 不可有「指向不存在物證」的假紀錄。

對應治理控制項:ISO 20000 組態管理;ISO 27001 A.8.9 / A.8.28。

用法:  cmdb_validate.py [--cmdb-dir cmdb] [--root .]
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

DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")


def main() -> int:
    ap = argparse.ArgumentParser(description="CMDB 驗證器(L4,fail-closed)")
    ap.add_argument("--cmdb-dir", default="cmdb", help="CMDB 根目錄(預設 cmdb)")
    ap.add_argument("--root", default=".", help="物證檔的根目錄(預設當前目錄)")
    args = ap.parse_args()

    cmdb_dir = Path(args.cmdb_dir)
    root = Path(args.root)
    if not cmdb_dir.is_dir():
        sys.exit(f"✗ 找不到 CMDB 目錄:{cmdb_dir}")

    cis = [p for p in sorted(cmdb_dir.rglob("*.yaml"))]
    if not cis:
        sys.exit(f"✗ {cmdb_dir} 沒有任何 CI")

    errors: list[str] = []
    n = 0
    for path in cis:
        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        if doc.get("kind") != "ReleasedArtifact":
            continue
        n += 1
        meta = doc.get("metadata", {}) or {}
        spec = doc.get("spec", {}) or {}
        art = spec.get("artifact", {}) or {}
        chain = spec.get("evidenceChain", {}) or {}
        tag = meta.get("ciId") or path.name

        for field, val in (("ciId", meta.get("ciId")), ("app", meta.get("app")),
                           ("component", meta.get("component")), ("artifact.digest", art.get("digest"))):
            if not val:
                errors.append(f"[{tag}] 缺必要欄位:{field}")

        digest = str(art.get("digest", "") or "")
        if digest and not DIGEST_RE.match(digest):
            errors.append(f"[{tag}] artifact.digest 非有效 sha256:{digest!r}")

        scan = chain.get("scan", {}) or {}
        sign = chain.get("sign", {}) or {}
        test = chain.get("test", {}) or {}
        for label, rel in (("SBOM", scan.get("sbom")), ("掃描判定", scan.get("scanVerdict")),
                           ("簽章", sign.get("signature"))):
            if not rel:
                errors.append(f"[{tag}] 證據鏈缺 {label} 參照")
            elif not (root / rel).is_file():
                errors.append(f"[{tag}] {label} 物證不存在:{rel}")

        try:
            tc = int(test.get("testCount", 0))
        except (TypeError, ValueError):
            tc = 0
        if tc < 1:
            errors.append(f"[{tag}] testCount < 1(空套件不構成證據)")

    print(f"🔍 CMDB 驗證:共 {n} 筆 ReleasedArtifact CI")
    if errors:
        for e in errors:
            print(f"  ❌ {e}")
        print(f"✗ CMDB 驗證失敗(fail-closed):{len(errors)} 個問題。")
        return 1
    print("✅ CMDB 驗證通過:所有 CI 結構完整、證據鏈物證存在、digest 有效。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
