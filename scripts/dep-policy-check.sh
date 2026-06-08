#!/usr/bin/env bash
#
# dep-policy-check.sh — 比對專案依賴 vs dep-policy/{maven,npm}-approved.yaml
#
# 用法:
#   ./dep-policy-check.sh backend [<dir>]    # 預設 dir = ./backend
#   ./dep-policy-check.sh frontend [<dir>]   # 預設 dir = ./frontend
#
# 若有 dep 不在 allow-list → exit 1 + 列出未核可的 coords
#
# 環境變數:
#   USE_HOST_TOOLS=1   不走 docker，直接用 host 的 mvn / jq
#

set -euo pipefail

C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
step()  { echo; echo "${C_BOLD}${C_BLUE}═════════ $1 ═════════${C_RESET}"; }
ok()    { echo "${C_GREEN}  ✓ $1${C_RESET}"; }
warn()  { echo "${C_YELLOW}  ⚠ $1${C_RESET}"; }
gate_fail() { echo "${C_RED}  ✗ $1${C_RESET}"; exit 1; }
info()  { echo "    $1"; }

KIND="${1:-}"
TARGET_DIR="${2:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# allow-list 的單一真實來源是獨立專案 security-team/dep-policy。CI 會把它抓到某處再用
# POLICY_DIR 指過來；本機未設時 fallback 到 repo 內副本（若還在）。
POLICY_DIR="${POLICY_DIR:-$ROOT/dep-policy}"

case "$KIND" in
    backend)
        TARGET_DIR="${TARGET_DIR:-$ROOT/backend}"
        POLICY_FILE="$POLICY_DIR/maven-approved.yaml"
        ;;
    frontend)
        TARGET_DIR="${TARGET_DIR:-$ROOT/frontend}"
        POLICY_FILE="$POLICY_DIR/npm-approved.yaml"
        ;;
    nuget)
        TARGET_DIR="${TARGET_DIR:-$ROOT/dotnet}"
        POLICY_FILE="$POLICY_DIR/nuget-approved.yaml"
        ;;
    *)
        echo "用法: $0 backend|frontend|nuget [<dir>]" >&2
        exit 1
        ;;
esac

[ -f "$POLICY_FILE" ] || gate_fail "找不到 policy: $POLICY_FILE（先跑 ./platform/seed-dep-policy.sh）"
[ -d "$TARGET_DIR" ] || gate_fail "找不到 target dir: $TARGET_DIR"

# ─────────────── 抽 approved coords ───────────────
# YAML 結構固定，grep+sed 比拉 python 進來輕。
APPROVED_FILE=$(mktemp)
grep -E '^\s+- coord:\s+' "$POLICY_FILE" | sed -E 's/^\s+- coord:\s+//; s/^"//; s/"$//' | sort -u > "$APPROVED_FILE"
APPROVED_COUNT=$(wc -l < "$APPROVED_FILE")

# ─────────────── 抽 actual coords ───────────────

ACTUAL_FILE=$(mktemp)

case "$KIND" in
    backend)
        step "1/2  抽 backend Maven dependency 清單"
        if [ "${USE_HOST_TOOLS:-0}" = "1" ]; then
            ( cd "$TARGET_DIR" && mvn -B dependency:list 2>&1 ) > /tmp/dep-policy-mvn.log
        else
            info "用 docker maven image 抽（避免 host 沒裝 mvn）…"
            docker run --rm --network host \
                -v "$TARGET_DIR":/work -w /work \
                maven:3.9-eclipse-temurin-21 \
                mvn -B dependency:list > /tmp/dep-policy-mvn.log 2>&1
        fi
        # 抓格式 [INFO]    groupId:artifactId:type:version:scope -- ...
        grep -E '^\[INFO\]\s+[a-z0-9.-]+:[a-z0-9.-]+:[a-z]+:[^:]+:' /tmp/dep-policy-mvn.log \
            | sed -E 's/^\[INFO\]\s+//' \
            | awk -F: '{print $1 ":" $2 ":" $4}' \
            | sort -u > "$ACTUAL_FILE"
        ;;
    frontend)
        step "1/2  抽 frontend npm dependency 清單"
        LOCK="$TARGET_DIR/package-lock.json"
        [ -f "$LOCK" ] || gate_fail "找不到 $LOCK（要 npm install --package-lock-only）"
        jq -r '.packages | to_entries[]
            | select(.key | startswith("node_modules/"))
            | (.key | sub("^node_modules/"; "")) + "@" + .value.version' "$LOCK" \
            | sort -u > "$ACTUAL_FILE"
        ;;
    nuget)
        step "1/2  抽 .NET NuGet dependency 清單"
        LOCK="$TARGET_DIR/packages.lock.json"
        [ -f "$LOCK" ] || gate_fail "找不到 $LOCK（要 dotnet restore --use-lock-file）"
        # packages.lock.json：.dependencies[<tfm>][<name>].resolved；含 Direct + Transitive
        jq -r '.dependencies | to_entries[] | .value | to_entries[]
            | select(.value.resolved != null)
            | "\(.key)@\(.value.resolved)"' "$LOCK" \
            | sort -u > "$ACTUAL_FILE"
        ;;
esac

ACTUAL_COUNT=$(wc -l < "$ACTUAL_FILE")
info "actual: $ACTUAL_COUNT coords"
info "approved: $APPROVED_COUNT coords"

# ─────────────── 比對 ───────────────

step "2/2  比對"

UNAPPROVED=$(comm -23 "$ACTUAL_FILE" "$APPROVED_FILE")

if [ -z "$UNAPPROVED" ]; then
    ok "Gate PASS — 所有 $ACTUAL_COUNT 個 coords 都在 allow-list"
    rm -f "$APPROVED_FILE" "$ACTUAL_FILE"
    exit 0
fi

UNAPPROVED_COUNT=$(echo "$UNAPPROVED" | wc -l)
echo
echo "  ${C_RED}未核可的 coords（$UNAPPROVED_COUNT）${C_RESET}"
echo "$UNAPPROVED" | sed 's/^/    - /'
echo
info "申請流程："
info "  1. 開 MR 到 dep-policy repo 把上述 coord 加到 $(basename "$POLICY_FILE")"
info "  2. MR 上 CI 自動跑 Trivy CVE 掃描 + license check"
info "  3. @security-team approve → merge"
info "  4. 這個 build 重跑 → PASS"
echo
rm -f "$APPROVED_FILE" "$ACTUAL_FILE"
gate_fail "Gate FAIL — $UNAPPROVED_COUNT 個 coord 不在 allow-list"
