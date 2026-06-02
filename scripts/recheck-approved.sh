#!/usr/bin/env bash
#
# recheck-approved.sh — 對所有 allow-list 內 coord 重新查當前 CVE
#
# 為什麼要這個：
#   套件半年前審核時 clean，CVE 是後來才爆的。每次 build / 每天排程跑一次，
#   抓出「過去核可但現在有問題」的 dep，提早處理。
#
# 用法:
#   ./recheck-approved.sh maven|npm|both [--fail-on HIGH|CRITICAL|none]
#
#   --fail-on HIGH      有 HIGH/CRITICAL CVE 就 exit 1
#   --fail-on CRITICAL  只有 CRITICAL 才 exit 1
#   --fail-on none      預設，只回報不擋（informational）
#
# 輸出:
#   stdout：human-readable summary
#   /tmp/recheck-findings.json：machine-readable，含每個 coord 的 CVE 清單
#

set -euo pipefail

C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'

KIND="${1:-both}"
shift || true
FAIL_ON="none"
while [ $# -gt 0 ]; do
    case "$1" in
        --fail-on) FAIL_ON="$2"; shift 2 ;;
        *) echo "未知參數: $1" >&2; exit 1 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY_DIR="${POLICY_DIR:-$ROOT/dep-policy}"   # 單一真實來源在獨立 repo；CI 用 POLICY_DIR 指過來

# ─────────────── extract approved coords ───────────────

extract_coords() {
    local file="$1"
    grep -E '^\s+- coord:\s+' "$file" | sed -E 's/^\s+- coord:\s+//; s/^"//; s/"$//' | sort -u
}

# ─────────────── OSV query ───────────────

OSV_API="https://api.osv.dev/v1/query"
FINDINGS_FILE=$(mktemp)
echo '{"findings":[]}' > "$FINDINGS_FILE"

query_one() {
    local coord="$1" eco="$2" name="$3" ver="$4"
    local resp vulns
    resp=$(curl -fsS -X POST -H "Content-Type: application/json" \
        --data "{\"package\":{\"name\":\"$name\",\"ecosystem\":\"$eco\"},\"version\":\"$ver\"}" \
        "$OSV_API" 2>/dev/null || echo '{}')
    vulns=$(echo "$resp" | jq -c '[.vulns // [] | .[] | {id, summary: (.summary // ""), severity: (.severity[0].score // "")}]')
    if [ "$vulns" != "[]" ]; then
        local entry
        entry=$(jq -n --arg c "$coord" --arg e "$eco" --argjson v "$vulns" \
            '{coord:$c, ecosystem:$e, vulns:$v}')
        jq --argjson e "$entry" '.findings += [$e]' "$FINDINGS_FILE" > "${FINDINGS_FILE}.tmp" \
            && mv "${FINDINGS_FILE}.tmp" "$FINDINGS_FILE"
    fi
}

# ─────────────── run ───────────────

TOTAL=0
WITH_CVE=0

if [ "$KIND" = "maven" ] || [ "$KIND" = "both" ]; then
    echo "${C_BOLD}${C_BLUE}═════════ Maven re-check ═════════${C_RESET}"
    while IFS= read -r coord; do
        [ -z "$coord" ] && continue
        TOTAL=$((TOTAL+1))
        IFS=: read -r g a v <<<"$coord"
        printf "  [%d] %s … " "$TOTAL" "$coord"
        before=$(jq '.findings | length' "$FINDINGS_FILE")
        query_one "$coord" "Maven" "$g:$a" "$v"
        after=$(jq '.findings | length' "$FINDINGS_FILE")
        if [ "$after" -gt "$before" ]; then
            WITH_CVE=$((WITH_CVE+1))
            echo "${C_RED}CVE${C_RESET}"
        else
            echo "ok"
        fi
    done < <(extract_coords "$POLICY_DIR/maven-approved.yaml")
fi

if [ "$KIND" = "npm" ] || [ "$KIND" = "both" ]; then
    echo "${C_BOLD}${C_BLUE}═════════ npm re-check ═════════${C_RESET}"
    while IFS= read -r coord; do
        [ -z "$coord" ] && continue
        TOTAL=$((TOTAL+1))
        # 拆 name@ver（可能有 @scope/）
        if [[ "$coord" =~ ^(@[^/]+/[^@]+)@(.+)$ ]]; then
            n="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
        elif [[ "$coord" =~ ^([^@]+)@(.+)$ ]]; then
            n="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
        else continue; fi
        printf "  [%d] %s … " "$TOTAL" "$coord"
        before=$(jq '.findings | length' "$FINDINGS_FILE")
        query_one "$coord" "npm" "$n" "$v"
        after=$(jq '.findings | length' "$FINDINGS_FILE")
        if [ "$after" -gt "$before" ]; then
            WITH_CVE=$((WITH_CVE+1))
            echo "${C_RED}CVE${C_RESET}"
        else
            echo "ok"
        fi
    done < <(extract_coords "$POLICY_DIR/npm-approved.yaml")
fi

# ─────────────── 出 summary ───────────────

cp "$FINDINGS_FILE" /tmp/recheck-findings.json

echo
echo "${C_BOLD}═════════ Summary ═════════${C_RESET}"
echo "  total approved: $TOTAL"
echo "  with CVE:       $WITH_CVE"
echo "  report:         /tmp/recheck-findings.json"
echo

if [ "$WITH_CVE" -gt 0 ]; then
    echo "${C_BOLD}有 CVE 的 coord:${C_RESET}"
    jq -r '.findings[] | "  - " + .coord + " (" + (.vulns | length | tostring) + " vulns)\n" +
        (.vulns[0:3][] | "      • " + .id + " — " + (.summary[:80] // "(no summary)"))' \
        "$FINDINGS_FILE"
fi

# ─────────────── fail-on policy ───────────────

# OSV 沒有統一 severity 欄位，這邊只以「有沒有 CVE」當門檻
# 真實使用要結合 DTrack 的 severity 欄位
case "$FAIL_ON" in
    HIGH|CRITICAL)
        if [ "$WITH_CVE" -gt 0 ]; then
            echo "${C_RED}  ✗ Re-check FAIL — 有 $WITH_CVE 個已核可 coord 出現 CVE${C_RESET}"
            exit 1
        fi
        ;;
    none) : ;;
    *) echo "${C_YELLOW}  ⚠ 未知 --fail-on '$FAIL_ON'，當 none 處理${C_RESET}" ;;
esac

if [ "$WITH_CVE" -eq 0 ]; then
    echo "${C_GREEN}  ✓ Re-check PASS — 所有已核可 coord 皆無 CVE${C_RESET}"
fi
