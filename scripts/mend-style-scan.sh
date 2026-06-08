#!/usr/bin/env bash
#
# mend-style-scan.sh — 用開源工具模擬 Mend 的依賴治理流程（非真接 Mend SaaS）
#
# 流程仿 Mend：
#   1. discovery：Trivy 從 manifest 解析全部元件（含 transitive）
#   2. scan：漏洞(vuln) + 授權(license)
#   3. evaluate：套 mend-sim/mend-policy.yaml（default-allow，命中 reject 政策才擋）
#   4. report：產 Mend 風格 inventory；有 reject 違規 → exit 1
#
# 用法:
#   ./mend-style-scan.sh                 # backend + frontend
#   ./mend-style-scan.sh backend
#   ./mend-style-scan.sh frontend
#
# 環境變數:
#   USE_HOST_TRIVY=1   不走 docker，用 host 的 trivy
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="${POLICY:-$ROOT/mend-sim/mend-policy.yaml}"
TRIVY_IMAGE="aquasec/trivy:0.71.0"
OUT="${OUT:-/tmp/mend-sim}"
mkdir -p "$OUT"

case "${1:-all}" in
    backend)  COMPONENTS=(backend) ;;
    frontend) COMPONENTS=(frontend) ;;
    all)      COMPONENTS=(backend frontend) ;;
    *) echo "用法: $0 [backend|frontend|all]" >&2; exit 1 ;;
esac

[ -f "$POLICY" ] || { echo "找不到 policy: $POLICY" >&2; exit 1; }

run_trivy() {  # $1=target dir  $2=out json
    if [ "${USE_HOST_TRIVY:-0}" = "1" ]; then
        trivy fs "$1" --scanners vuln,license --list-all-pkgs \
            --format json --quiet --output "$2"
    else
        docker run --rm -v "$1":/work -v "$OUT":/out "$TRIVY_IMAGE" \
            fs /work --scanners vuln,license --list-all-pkgs \
            --format json --quiet --output "/out/$(basename "$2")"
    fi
}

PAIRS=()
for c in "${COMPONENTS[@]}"; do
    echo ">> Trivy 掃描 $c（vuln + license，含 transitive）…"
    run_trivy "$ROOT/$c" "$OUT/trivy-$c.json"
    PAIRS+=("$c=$OUT/trivy-$c.json")
done

echo ">> 套用 Mend-style 政策評估…"
python3 "$ROOT/scripts/mend_policy_eval.py" \
    --policy "$POLICY" \
    --report "$OUT/mend-inventory.md" \
    "${PAIRS[@]}"
