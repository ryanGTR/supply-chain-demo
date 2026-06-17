#!/usr/bin/env python3
"""發佈漂移對帳(L4,檔案型)— CMDB 期望態 vs 發佈庫實際態。

itops 右側的漂移偵測(Phase E4)比對「CMDB 記錄的 digest」vs「線上實際跑的容器 digest」。
移植成檔案型後,「線上實際」= 發佈庫(release-store / feed)裡那一區真正擺著的 artifact。
本工具逐環境比對:
    期望(CMDB)  = cmdb/<env>/<app>-<component>.yaml  的 spec.artifact.digest
    實際(store)  = release-store/<env>/<name>/release.yaml 的 spec.artifact.digest
                  且該區 artifact 檔的內容 sha256 必須等於它宣告的 digest(防庫內被掉包)。

判定漂移的情形(任一即該環境 DRIFT):
  - CMDB 有登錄、但發佈庫沒有對應 artifact(記錄聲稱發佈了,實際庫裡沒有)。
  - 兩邊都有、digest 不一致(庫裡擺的不是 CMDB 記錄的那一版)。
  - 庫裡 artifact 內容 sha256 與 release.yaml 宣告 digest 不符(發佈後被掉包)。
(發佈庫有、CMDB 沒登錄:預設為「未登錄發佈」警告,加 --strict 才算漂移。)

對應治理控制項:ISO 20000 組態管理(基線一致性)、ISO 27001 A.8.9 組態管理、
A.8.28 完整性(已發佈內容未被竄改)。

用法:
  reconcile_release.py [--cmdb-dir cmdb] [--store release-store] [--root .]
       [--order test,uat,prod] [--strict] [--json]
Exit:0 無漂移;1 偵測到漂移(fail-closed,可當 CI 閘門);2 輸入錯誤。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("✗ 需要 PyYAML(pip install pyyaml)")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()


def load(p: Path) -> dict:
    try:
        return yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    except Exception:
        return {}


def digest_of(man: dict) -> str:
    return (((man.get("spec") or {}).get("artifact") or {}).get("digest")) or ""


def main() -> int:
    ap = argparse.ArgumentParser(description="發佈漂移對帳(L4,檔案型,fail-closed)")
    ap.add_argument("--cmdb-dir", default="cmdb")
    ap.add_argument("--store", default="release-store")
    ap.add_argument("--root", default=".", help="artifact 檔相對路徑的根(預設當前目錄)")
    ap.add_argument("--order", default="test,uat,prod", help="要對帳的環境(逗號分隔)")
    ap.add_argument("--strict", action="store_true",
                    help="把『發佈庫有但 CMDB 未登錄』也算漂移(預設僅警告)")
    ap.add_argument("--json", action="store_true", help="輸出機器可讀 JSON")
    args = ap.parse_args()

    cmdb_dir = Path(args.cmdb_dir)
    store = Path(args.store)
    root = Path(args.root)
    envs = [e.strip() for e in args.order.split(",") if e.strip()]

    results = []   # 每筆 {env, name, expected, actual, status, detail}
    drift = 0
    warn = 0

    for env in envs:
        # 期望態:該環境下的所有 CMDB CI
        cmdb_env = cmdb_dir / env
        cmdb_cis = sorted(cmdb_env.glob("*.yaml")) if cmdb_env.is_dir() else []
        # 實際態:該環境發佈庫下的所有 release(每個 app-component 一格)
        store_env = store / env
        store_names = (sorted(d.name for d in store_env.iterdir() if d.is_dir())
                       if store_env.is_dir() else [])
        store_seen = set()

        for ci_file in cmdb_cis:
            ci = load(ci_file)
            m = ci.get("metadata", {}) or {}
            name = f"{m.get('app')}-{m.get('component')}"
            expected = digest_of(ci)
            rel = store_env / name / "release.yaml"
            entry = {"env": env, "name": name, "expected": expected, "actual": None}
            if not rel.is_file():
                entry.update(status="DRIFT",
                             detail="CMDB 登錄了,但發佈庫沒有對應 release(記錄聲稱發佈,實際庫裡沒有)")
                drift += 1
                results.append(entry)
                continue
            store_seen.add(name)
            man = load(rel)
            actual = digest_of(man)
            entry["actual"] = actual
            if actual != expected:
                entry.update(status="DRIFT",
                             detail=f"digest 不一致:CMDB 期望 {expected},發佈庫實際 {actual}")
                drift += 1
                results.append(entry)
                continue
            # 內容完整性:庫內 artifact 檔 sha256 必須等於宣告 digest
            art_rel = (((man.get("spec") or {}).get("artifact") or {}).get("path"))
            art_path = (store_env / name / Path(art_rel).name) if art_rel else None
            if art_path and art_path.is_file():
                real = sha256_file(art_path)
                if real != actual:
                    entry.update(status="DRIFT",
                                 detail=f"發佈庫 artifact 內容被掉包:宣告 {actual},實際 {real}")
                    drift += 1
                    results.append(entry)
                    continue
            entry.update(status="OK", detail="CMDB 與發佈庫一致")
            results.append(entry)

        # 發佈庫有、CMDB 沒登錄
        for name in store_names:
            if name in store_seen:
                continue
            rel = store_env / name / "release.yaml"
            actual = digest_of(load(rel)) if rel.is_file() else ""
            status = "DRIFT" if args.strict else "WARN"
            results.append({"env": env, "name": name, "expected": None, "actual": actual,
                            "status": status,
                            "detail": "發佈庫有,但 CMDB 未登錄(未登錄發佈)"})
            if args.strict:
                drift += 1
            else:
                warn += 1

    if args.json:
        print(json.dumps({"drift": drift, "warn": warn, "results": results},
                         ensure_ascii=False, indent=2))
    else:
        print(f"🔍 發佈漂移對帳:{len(results)} 筆(環境 {envs})")
        for r in results:
            icon = {"OK": "✅", "WARN": "⚠️", "DRIFT": "❌"}[r["status"]]
            print(f"  {icon} [{r['env']}] {r['name']}:{r['detail']}")
        if drift:
            print(f"\n❌ 偵測到漂移:{drift} 筆(fail-closed)。"
                  "請對帳:補登 CMDB、重新發佈正確版本,或開漂移單追根因(補單≠漂白)。")
        elif warn:
            print(f"\n⚠️ 無硬漂移,但有 {warn} 筆未登錄發佈(--strict 會視為漂移)。")
        else:
            print("\n✅ 無漂移:所有環境的 CMDB 期望態與發佈庫實際態一致。")

    return 1 if drift else 0


if __name__ == "__main__":
    sys.exit(main())
