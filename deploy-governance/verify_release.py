#!/usr/bin/env python3
"""L4 發佈前驗章閘門(verify-before-release)— fail-closed。

供應鏈左側(build/scan/sign)簽完 artifact 後,本閘門在「發佈到 feed / 部署上線之前」
對一份 ReleaseManifest(見 release-contract.md)執行強制檢查;**任一不過即拒絕(exit 1)**。
這是「未驗章 / 未通過的 artifact 根本發佈不出去」的最後一道閘門——itops 右側治理的核心,
移植成**環境無關、檔案型(jar/war/zip)** 的工具,github / ADO pipeline 共用同一套。

檢查(全部 fail-closed):
  1. 必要 metadata 齊全(app / component / ecosystem)。
  2. 測試證據:evidence.testReport 為有效 sha256、testCount >= 1
     (「promote what passed test」的根據;空套件 = 綠燈空殼,拒絕)。
  3. digest 有效:artifact.digest 為 sha256:<64 hex>(否則=未經建置)。
  4. artifact 完整性:檔案存在,且實際 sha256 == 宣告 digest(防交接後被掉包)。
  5. 簽章有效:cosign verify-blob 對 artifact 檔驗分離式簽章;信任根依 signature.mode:
       key-pair / hashivault → --key <pubkey>(--insecure-ignore-tlog,離線自足)
       keyless               → --certificate + --certificate-identity(*)
  6. 證據物證存在:SBOM 檔存在;掃描判定檔存在且 verdict == pass。

(*) keyless 的 identity 比對需 --certificate-identity / --certificate-oidc-issuer;
    Tier 1 PoC 用 key-pair,keyless 參數預留給 github demo 既有路線。

對應治理控制項:
  ISO 27001 A.8.28 供應鏈完整性 / A.8.29 開發中測試 / A.8.32 變更管理。

用法:
  verify_release.py --manifest <release-manifest.yaml> \
      [--pubkey trust/cosign.pub] [--root <artifact 根目錄>] [--cosign cosign]

Exit code: 0 通過放行;1 任一失敗,拒絕發佈(fail-closed)。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("✗ 需要 PyYAML(pip install pyyaml)", file=sys.stderr)
    sys.exit(1)

DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
REQUIRED_META = ["app", "component", "ecosystem"]


def reject(control: str, msg: str) -> None:
    print(f"❌ 發佈被拒(fail-closed)[{control}]:{msg}")
    sys.exit(1)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser(description="L4 發佈前驗章閘門(檔案型,fail-closed)")
    ap.add_argument("--manifest", required=True, help="ReleaseManifest YAML")
    ap.add_argument("--pubkey", default="trust/cosign.pub", help="信任根公鑰(key-pair/hashivault 模式)")
    ap.add_argument("--root", default=".", help="artifact / 簽章 / 證據檔的根目錄(預設當前目錄)")
    ap.add_argument("--cosign", default="cosign", help="cosign 執行檔")
    args = ap.parse_args()

    root = Path(args.root)
    man_path = Path(args.manifest)
    if not man_path.is_file():
        reject("輸入", f"找不到 ReleaseManifest:{man_path}")
    man = yaml.safe_load(man_path.read_text(encoding="utf-8")) or {}
    if man.get("kind") != "ReleaseManifest":
        reject("輸入", f"不是 ReleaseManifest(kind={man.get('kind')!r})")
    meta = man.get("metadata", {}) or {}
    spec = man.get("spec", {}) or {}
    art = spec.get("artifact", {}) or {}
    sig = spec.get("signature", {}) or {}
    ev = spec.get("evidence", {}) or {}

    # --- 1. 必要 metadata ---
    missing = [k for k in REQUIRED_META if not meta.get(k)]
    if missing:
        reject("ISO 20000 組態管理", f"ReleaseManifest 缺必要欄位:{', '.join(missing)}")

    # --- 2. 測試證據(便宜,先做)---
    test_report = str(ev.get("testReport", "") or "")
    if not DIGEST_RE.match(test_report):
        reject("ISO 27001 A.8.29 開發中測試",
               f"缺有效測試證據指紋(evidence.testReport={test_report!r})——需為 sha256:<64 hex>。"
               "無測試證據 → 「promote what passed test」前提不成立,不可發佈。")
    try:
        test_count = int(ev.get("testCount", 0))
    except (TypeError, ValueError):
        test_count = 0
    if test_count < 1:
        reject("ISO 27001 A.8.29 開發中測試",
               f"測試套件為空(evidence.testCount={ev.get('testCount')!r})——"
               "空套件不構成證據(防『綠燈空殼』),不可發佈。")

    # --- 3. digest 有效 ---
    digest = str(art.get("digest", "") or "")
    if not DIGEST_RE.match(digest):
        reject("ISO 27001 A.8.28 完整性",
               f"artifact.digest 不是有效 sha256(目前:{digest!r})——尚未經建置/簽章,不可發佈。")

    # --- 4. artifact 完整性:檔案存在且 hash 一致 ---
    art_path_rel = art.get("path")
    if not art_path_rel:
        reject("輸入", "缺 spec.artifact.path")
    art_path = root / art_path_rel
    if not art_path.is_file():
        reject("ISO 27001 A.8.28 完整性", f"找不到 artifact 檔:{art_path}")
    actual = sha256_file(art_path)
    if actual != digest:
        reject("ISO 27001 A.8.28 完整性",
               f"artifact 內容與宣告 digest 不符(交接後被掉包?)\n"
               f"      宣告:{digest}\n      實際:{actual}")

    # --- 5. 簽章驗證(對 artifact 檔)---
    sig_rel = sig.get("path")
    if not sig_rel:
        reject("ISO 27001 A.8.28 完整性", "缺 spec.signature.path——未簽章的 artifact 不可發佈。")
    sig_path = root / sig_rel
    if not sig_path.is_file():
        reject("ISO 27001 A.8.28 完整性", f"找不到簽章檔:{sig_path}")
    mode = str(sig.get("mode", "key-pair") or "key-pair")

    cmd = [args.cosign, "verify-blob", "--signature", str(sig_path)]
    if mode in ("key-pair", "hashivault"):
        if not Path(args.pubkey).is_file():
            reject("信任根", f"找不到信任根公鑰:{args.pubkey}")
        # key-pair 不用 Rekor 透明日誌(keyless 才用)→ 離線自足,符合銀行氣隙情境。
        cmd += ["--key", args.pubkey, "--insecure-ignore-tlog=true"]
    elif mode == "keyless":
        cert = sig.get("certificate")
        if not cert or not (root / cert).is_file():
            reject("ISO 27001 A.8.28 完整性", "keyless 模式需 signature.certificate(簽章憑證)且檔案存在。")
        cmd += ["--certificate", str(root / cert)]
        # identity 比對欄位(若 manifest 提供)
        if sig.get("certificateIdentity"):
            cmd += ["--certificate-identity", sig["certificateIdentity"]]
        if sig.get("certificateOidcIssuer"):
            cmd += ["--certificate-oidc-issuer", sig["certificateOidcIssuer"]]
    else:
        reject("簽章後端", f"不支援的 signature.mode:{mode!r}(key-pair/keyless/hashivault/pkcs11)")
    cmd.append(str(art_path))

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError:
        reject("工具", f"找不到 cosign 執行檔:{args.cosign}")
    if proc.returncode != 0:
        reject("ISO 27001 A.8.28 完整性",
               "cosign 驗章失敗——簽章無效或非本平台信任根所簽。\n"
               f"      cosign: {proc.stderr.strip() or proc.stdout.strip()}")

    # --- 6. 證據物證存在 ---
    sbom_rel = ev.get("sbom")
    if not sbom_rel or not (root / sbom_rel).is_file():
        reject("ISO 27001 A.8.28 供應鏈", f"缺 SBOM 物證(evidence.sbom={sbom_rel!r})。")
    verdict_rel = ev.get("scanVerdict")
    if not verdict_rel or not (root / verdict_rel).is_file():
        reject("ISO 27001 A.8.28 供應鏈", f"缺掃描判定物證(evidence.scanVerdict={verdict_rel!r})。")
    try:
        verdict = json.loads((root / verdict_rel).read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        reject("ISO 27001 A.8.28 供應鏈", f"掃描判定檔無法解析:{exc}")
    if str(verdict.get("verdict", "")).lower() != "pass":
        reject("ISO 27001 A.8.28 供應鏈",
               f"掃描判定非 pass(verdict={verdict.get('verdict')!r})——有未處理風險,不可發佈。")

    print(f"✅ 驗章通過,放行發佈:{meta['app']}/{meta['component']} ({digest})")
    print(f"   通過:metadata 齊全 + 測試證據({test_count} 筆)+ digest 有效 + artifact 完整性"
          f" + 簽章有效(mode={mode})+ SBOM/掃描判定(pass)物證齊全。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
