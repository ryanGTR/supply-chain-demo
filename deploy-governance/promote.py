#!/usr/bin/env python3
"""build-once promote(檔案型,L4)— 同一 artifact 逐區晉級,每區重新驗章。

「build once, promote the same artifact」:一個簽過、驗過的 artifact,從 test → uat → prod
**不重建、不重簽**,只把同一份(相同 digest + 相同簽章)搬進下一區的發佈庫(feed),
並在每一區**重新跑 L4 驗章閘門**(verify_release)。移植自 itops promote/validate_promote,
改成 feed/store 模型(對齊 supply-chain 的 Azure Artifacts feed,而非 git-PR-diff)。

發佈庫(store)佈局(每個 env 一格,模擬 test-feed / uat-feed / prod-feed):
  <store>/<env>/<app>-<component>/
      release.yaml        ReleaseManifest(metadata.environment=<env>)
      <artifact>          原樣搬移(同 digest,build once)
      <artifact>.sig      原樣搬移(同簽章)
      <evidence...>       sbom / scan-verdict

三道守衛(任一不過即拒,fail-closed):
  1. 順序 / 禁跳關:to_env 必須是 order 中 from_env 的**下一格**。
  2. build-once 血統:來源區的 release 必須先自身通過 L4 驗章(要 promote 的東西本身合規);
     搬進目標區時 digest / 簽章原樣不變(本工具不會重建或重簽)。
  3. 重新驗章:目標區用「搬過去的同一份」重跑 verify_release——簽章/完整性/證據全部重驗。
  4. 正式區(prod 或 order 最後一格)需 --approved-by(CAB 核可),否則擋。

對應治理控制項:ISO 27001 A.8.28 完整性(只搬已驗章產物)、A.8.32 變更管理(順序/禁跳關);
ISO 20000 發布與部署管理(每區重驗 + 正式區核可)。

用法:
  promote.py --app supply-chain-backend --component backend \
    --from test --to uat --store release-store --order test,uat,prod \
    --pubkey trust/cosign.pub [--approved-by alice]   # 晉級到正式區才需要
Exit:0 放行;1 任一守衛不過(fail-closed);2 輸入錯誤。
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("✗ 需要 PyYAML(pip install pyyaml)")

HERE = Path(__file__).resolve().parent


def reject(control: str, msg: str) -> int:
    print(f"❌ 過版被拒(fail-closed)[{control}]:{msg}")
    return 1


def run_verify(manifest: Path, root: Path, pubkey: str) -> tuple[int, str]:
    p = subprocess.run(
        [sys.executable, str(HERE / "verify_release.py"),
         "--manifest", str(manifest), "--root", str(root), "--pubkey", pubkey],
        capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


def main() -> int:
    ap = argparse.ArgumentParser(description="build-once promote(檔案型,fail-closed)")
    ap.add_argument("--app", required=True)
    ap.add_argument("--component", required=True)
    ap.add_argument("--from", dest="from_env", required=True)
    ap.add_argument("--to", dest="to_env", required=True)
    ap.add_argument("--store", default="release-store", help="發佈庫根目錄(模擬 feed)")
    ap.add_argument("--order", default="test,uat,prod", help="晉級順序(逗號分隔)")
    ap.add_argument("--pubkey", default="trust/cosign.pub")
    ap.add_argument("--approved-by", default="", help="正式區晉級的 CAB 核可人")
    ap.add_argument("--cmdb-dir", default="cmdb")
    args = ap.parse_args()

    order = [e.strip() for e in args.order.split(",") if e.strip()]
    name = f"{args.app}-{args.component}"
    store = Path(args.store)

    # --- 守衛 1:順序 / 禁跳關 ---
    if args.from_env not in order or args.to_env not in order:
        return reject("ISO 27001 A.8.32 變更管理",
                      f"環境不在晉級順序 {order} 內(from={args.from_env}, to={args.to_env})。")
    if order.index(args.to_env) != order.index(args.from_env) + 1:
        return reject("ISO 27001 A.8.32 變更管理",
                      f"禁跳關:{args.to_env} 不是 {args.from_env} 的下一格(順序 {order})。"
                      "只能逐區晉級。")

    from_dir = store / args.from_env / name
    from_manifest = from_dir / "release.yaml"
    if not from_manifest.is_file():
        return reject("ISO 27001 A.8.32 變更管理",
                      f"來源區 {args.from_env} 沒有已發佈的 {name}({from_manifest} 不存在)——"
                      "禁跳關,只能 promote 上一區真的發佈過的東西。")

    # --- 守衛 2:來源區自身先通過 L4 驗章(要 promote 的東西本身必須合規)---
    rc, detail = run_verify(from_manifest, from_dir, args.pubkey)
    if rc != 0:
        return reject("ISO 27001 A.8.28 完整性",
                      f"來源區 {args.from_env} 的 {name} 自身 L4 驗章不通過,不可晉級。\n      {detail}")
    src = yaml.safe_load(from_manifest.read_text(encoding="utf-8"))
    from_digest = (((src.get("spec") or {}).get("artifact") or {}).get("digest"))

    # --- 守衛 4:正式區需 CAB 核可 ---
    is_prod = args.to_env == order[-1]
    if is_prod and not args.approved_by:
        return reject("ISO 20000 發布管理",
                      f"晉級到正式區 {args.to_env} 需 CAB 核可(--approved-by);未核可,擋。")

    # --- build-once 搬移:把來源區「同一份」原樣複製到目標區(不重建/不重簽)---
    to_dir = store / args.to_env / name
    to_dir.mkdir(parents=True, exist_ok=True)
    for f in from_dir.iterdir():
        if f.name == "release.yaml":
            continue
        shutil.copy2(f, to_dir / f.name)   # artifact / sig / sbom / scan-verdict 原樣
    # 目標 manifest = 來源 manifest 改 environment(digest/簽章/證據路徑不變 = build once)
    dst = yaml.safe_load(from_manifest.read_text(encoding="utf-8"))
    dst.setdefault("metadata", {})["environment"] = args.to_env
    ((dst.get("spec") or {}).get("artifact") or {})["feed"] = f"{args.to_env}-feed"
    if args.approved_by:
        dst["metadata"]["approvedBy"] = args.approved_by
    (to_dir / "release.yaml").write_text(
        yaml.safe_dump(dst, allow_unicode=True, sort_keys=False), encoding="utf-8")

    # --- 守衛 3:目標區重新驗章(同一份,build once)---
    rc, detail = run_verify(to_dir / "release.yaml", to_dir, args.pubkey)
    if rc != 0:
        return reject("ISO 27001 A.8.28 完整性 / ISO 20000 發布驗證",
                      f"目標區 {args.to_env} 重新驗章未通過(搬移後物證/簽章異常)。\n      {detail}")
    to_digest = (((dst.get("spec") or {}).get("artifact") or {}).get("digest"))
    if to_digest != from_digest:
        return reject("ISO 27001 A.8.28 完整性",
                      "build-once 違規:目標區 digest 與來源區不同(疑似重建/換 artifact)。")

    # --- 登錄目標區 CMDB(同 digest,新環境)---
    subprocess.run(
        [sys.executable, str(HERE / "cmdb_register.py"),
         "--manifest", str(to_dir / "release.yaml"), "--cmdb-dir", args.cmdb_dir],
        check=False, capture_output=True)

    approval = f"(CAB 核可:{args.approved_by})" if args.approved_by else ""
    print(f"✅ 過版放行:{name}  {args.from_env} → {args.to_env}  {approval}")
    print(f"   build once:同一 digest {from_digest} 原樣搬移 + 目標區重新驗章通過。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
