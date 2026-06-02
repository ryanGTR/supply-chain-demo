#!/usr/bin/env bash
#
# audit-report.sh — 把每次發布的供應鏈證據彙整成單一自帶樣式的靜態 HTML + JSON
#                    （稽核員可直接點開的「稽核證據包」，roadmap §1.3）
#
# 彙整來源：
#   SBOM（Syft/CycloneDX）、SAST（Semgrep）、密鑰掃描（Gitleaks）、
#   CVE + policy gate（Dependency-Track API）、簽章/來源證明（cosign，狀態）
#
# 設計原則：這支腳本是「彙整報告」不是「gate」——任一證據缺漏（檔案不在、DTrack
# 連不上）都優雅降級成 N/A，**絕不** exit 1 把稽核流程弄掛（gate 是 dtrack-gate.sh 的事）。
#
# 用法:
#   ./scripts/audit-report.sh                      # 預設 --out audit --format html,json
#   ./scripts/audit-report.sh --out /tmp/audit
#   ./scripts/audit-report.sh --format json
#   ./scripts/audit-report.sh --verify-signatures  # 若 image + COSIGN_PUB 在，跑 cosign verify
#
# GitLab Pages 在本環境不可行（rootless podman + Traefik，見 ADR-0010），
# 故產出為自包含單檔，當 CI artifact 發布。
#

set -euo pipefail

# ─────────────────────────── 顏色 + helpers ───────────────────────────

C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
step()  { echo; echo "${C_BOLD}${C_BLUE}═════════ $1 ═════════${C_RESET}"; }
ok()    { echo "${C_GREEN}  ✓ $1${C_RESET}"; }
warn()  { echo "${C_YELLOW}  ⚠ $1${C_RESET}"; }
fail()  { echo "${C_RED}  ✗ $1${C_RESET}"; exit 1; }
info()  { echo "    $1"; }

# ─────────────────────────── 路徑 + .env ───────────────────────────

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/platform/.env"
# .env 是 local source；CI 透過 CI variables 注入時 .env 可不存在。
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

# ─────────────────────────── 參數 ───────────────────────────

OUT_DIR="$ROOT/audit"
FORMATS="html,json"
VERIFY_SIGS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --out)               OUT_DIR="$2"; shift 2 ;;
        --format)            FORMATS="$2"; shift 2 ;;
        --verify-signatures) VERIFY_SIGS=1; shift ;;
        -h|--help)           grep '^#' "$0" | head -20 | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                   fail "未知參數: $1（試試 --help）" ;;
    esac
done

mkdir -p "$OUT_DIR"
DTRACK_URL="${DTRACK_URL:-http://dtrack.localhost:8080}"

# ─────────────────────────── 小工具 ───────────────────────────

# 把計數 / 狀態映射成圖示。問題型控制（SAST/secret/CVE/violation）：0 → ✓、>0 → ✗、N/A → ⚠。
status_icon() {
    case "$1" in
        0)                 echo "✓" ;;
        N/A|na|"not run")  echo "⚠" ;;
        verified)          echo "✓" ;;
        *)                 echo "✗" ;;
    esac
}
# 存在型控制（SBOM）：有東西 → ✓、N/A → ⚠。
inv_icon() {
    case "$1" in
        N/A|na|"not run"|0|"") echo "⚠" ;;
        *)                     echo "✓" ;;
    esac
}
html_escape() { printf '%s' "${1:-}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# ─────────────────────────── 收集：release metadata ───────────────────────────

collect_release() {
    GIT_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo N/A)"
    GIT_DESC="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo N/A)"
    REL_REF="${CI_COMMIT_REF_NAME:-$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo N/A)}"
    REL_PIPE="${CI_PIPELINE_ID:-local}"
    REL_PROJ="${CI_PROJECT_URL:-N/A}"
    REL_WHEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    info "ref=$REL_REF commit=${GIT_SHA:0:12} pipeline=$REL_PIPE"
}

# ─────────────────────────── 收集：SBOM ───────────────────────────

# CI 寫到 repo root（sbom-<n>.json），local 在 sboms/。兩處都找。
sbom_path() {
    local n="$1" p
    for p in "$ROOT/sbom-$n.json" "$ROOT/sboms/sbom-$n.json" "$ROOT/sboms/$n.cdx.json"; do
        [ -f "$p" ] && { echo "$p"; return; }
    done
    echo ""
}
collect_sbom() {  # $1 = backend|frontend
    local n="$1" f cnt
    f="$(sbom_path "$n")"
    if [ -n "$f" ]; then
        cnt="$(jq '.components | length' "$f" 2>/dev/null || echo N/A)"
        printf -v "SBOM_${n}_N"   '%s' "$cnt"
        printf -v "SBOM_${n}_SRC" '%s' "${f#$ROOT/}"
    else
        printf -v "SBOM_${n}_N"   '%s' "N/A"
        printf -v "SBOM_${n}_SRC" '%s' "not run"
    fi
}

# ─────────────────────────── 收集：SAST（semgrep.json）───────────────────────────

collect_sast() {
    local f="$ROOT/semgrep.json"
    if [ -f "$f" ]; then
        SAST_ERR=$(jq  '[.results[]?|select(.extra.severity=="ERROR")]|length'   "$f" 2>/dev/null || echo N/A)
        SAST_WARN=$(jq '[.results[]?|select(.extra.severity=="WARNING")]|length' "$f" 2>/dev/null || echo N/A)
        SAST_INFO=$(jq '[.results[]?|select(.extra.severity=="INFO")]|length'    "$f" 2>/dev/null || echo N/A)
        SAST_SRC="semgrep.json"
    else
        SAST_ERR=N/A; SAST_WARN=N/A; SAST_INFO=N/A; SAST_SRC="not run"
    fi
}

# ─────────────────────────── 收集：密鑰掃描（gl-secrets.sarif）───────────────────────────

collect_secrets() {
    local f="$ROOT/gl-secrets.sarif"
    if [ -f "$f" ]; then
        SECRETS_N=$(jq '[.runs[]?.results[]?]|length' "$f" 2>/dev/null || echo N/A)
        SECRETS_SRC="gl-secrets.sarif"
    else
        SECRETS_N=N/A; SECRETS_SRC="not run"
    fi
}

# ─────────────────────────── 收集：CVE + policy gate（DTrack API）───────────────────────────

# 抓一個 DTrack endpoint。把 body 與 HTTP code 一起拿（-w 把 code 接在最後一行）。
# 只有 HTTP 200 + 非空 body 才算成功；其餘（000=連不上、401=沒權限、404=查無專案、5xx）
# 一律失敗並回傳該 code。**不可**把失敗吞成 "[]"，否則稽核報告會把「連不上 / 沒權限」
# 誤報成「掃過、0 個 CVE ✓」，那是危險的假陰性。
# 注意：直接在 collect_dtrack 內聯呼叫，不用 $(helper) 包——command substitution 會開
# 子 shell，子 shell 設的 HTTP code 變數母 shell 拿不到。
dtrack_fetch() {  # $1 = api path ; 設 DT_BODY / DT_CODE（caller 的同層變數）
    local raw
    raw="$(curl -sS -H "X-Api-Key: $DTRACK_API_KEY" -w $'\n%{http_code}' "$DTRACK_URL$1" 2>/dev/null)" || true
    DT_CODE="${raw##*$'\n'}"
    DT_BODY="${raw%$'\n'*}"
    [ "$DT_CODE" = "200" ] && [ -n "$DT_BODY" ]
}
collect_dtrack() {  # $1 = backend|frontend  $2 = project uuid
    local key="$1" uuid="$2" find viol DT_BODY DT_CODE
    if [ -z "$uuid" ] || [ -z "${DTRACK_API_KEY:-}" ]; then
        warn "DTrack: $key 缺 UUID 或 API key → CVE/policy 標 N/A"
        return
    fi
    dtrack_fetch "/api/v1/finding/project/$uuid" || {
        warn "DTrack: $key findings 取不到（HTTP ${DT_CODE:-?}；000=連不上 401=沒權限 404=查無專案）→ CVE 標 N/A"; return; }
    find="$DT_BODY"
    dtrack_fetch "/api/v1/violation/project/$uuid" || {
        warn "DTrack: $key violations 取不到（HTTP ${DT_CODE:-?}）→ policy 標 N/A"; return; }
    viol="$DT_BODY"
    printf -v "CVE_${key}_CRIT" '%s' "$(echo "$find" | jq '[.[]|select(.vulnerability.severity=="CRITICAL")]|length' 2>/dev/null || echo N/A)"
    printf -v "CVE_${key}_HIGH" '%s' "$(echo "$find" | jq '[.[]|select(.vulnerability.severity=="HIGH")]|length'     2>/dev/null || echo N/A)"
    printf -v "CVE_${key}_MED"  '%s' "$(echo "$find" | jq '[.[]|select(.vulnerability.severity=="MEDIUM")]|length'   2>/dev/null || echo N/A)"
    printf -v "CVE_${key}_LOW"  '%s' "$(echo "$find" | jq '[.[]|select(.vulnerability.severity=="LOW")]|length'      2>/dev/null || echo N/A)"
    printf -v "VIOL_${key}_FAIL" '%s' "$(echo "$viol" | jq '[.[]|select(.policyCondition.policy.violationState=="FAIL")]|length' 2>/dev/null || echo N/A)"
    printf -v "VIOL_${key}_WARN" '%s' "$(echo "$viol" | jq '[.[]|select(.policyCondition.policy.violationState=="WARN")]|length' 2>/dev/null || echo N/A)"
}

# ─────────────────────────── 收集：簽章 / 來源證明 ───────────────────────────

collect_signatures() {
    # 預設誠實狀態：簽章與 attestation 在 manual publish stage 才產生。
    SIG_STATE="pending — 於 manual publish stage 產生"
    if [ "$VERIFY_SIGS" = "1" ] && command -v cosign >/dev/null 2>&1 \
        && [ -n "${COSIGN_PUB:-}" ] && [ -n "${IMAGE_BACKEND:-}" ]; then
        if cosign verify --key "$COSIGN_PUB" "$IMAGE_BACKEND:${TAG:-latest}" >/dev/null 2>&1; then
            SIG_STATE="verified（cosign verify 通過）"
        else
            SIG_STATE="尚未簽章 / 驗證失敗"
        fi
    fi
}

# ─────────────────────────── 組 evidence inventory 列 ───────────────────────────

ROWS=""
add_row() {  # $1=控制 $2=icon $3=明細 $4=來源
    local cls
    case "$2" in ✓) cls=ok ;; ⚠) cls=warn ;; *) cls=bad ;; esac
    ROWS+="<tr><td>$(html_escape "$1")</td><td class=\"$cls\">$2</td><td>$(html_escape "$3")</td><td><code>$(html_escape "$4")</code></td></tr>"$'\n'
}

build_rows() {
    add_row "Semgrep SAST"          "$(status_icon "${SAST_ERR}")"          "ERROR=${SAST_ERR} WARNING=${SAST_WARN} INFO=${SAST_INFO}" "${SAST_SRC}"
    add_row "Gitleaks 密鑰掃描"      "$(status_icon "${SECRETS_N}")"         "命中 ${SECRETS_N}"                                        "${SECRETS_SRC}"
    add_row "Syft SBOM (backend)"   "$(inv_icon "${SBOM_backend_N:-N/A}")"  "${SBOM_backend_N:-N/A} components"                        "${SBOM_backend_SRC:-not run}"
    add_row "Syft SBOM (frontend)"  "$(inv_icon "${SBOM_frontend_N:-N/A}")" "${SBOM_frontend_N:-N/A} components"                       "${SBOM_frontend_SRC:-not run}"
    add_row "DTrack CVE (backend)"  "$(status_icon "$(cve_block backend)")" "CRIT=${CVE_backend_CRIT:-N/A} HIGH=${CVE_backend_HIGH:-N/A} MED=${CVE_backend_MED:-N/A} LOW=${CVE_backend_LOW:-N/A}"  "DTrack API"
    add_row "DTrack CVE (frontend)" "$(status_icon "$(cve_block frontend)")" "CRIT=${CVE_frontend_CRIT:-N/A} HIGH=${CVE_frontend_HIGH:-N/A} MED=${CVE_frontend_MED:-N/A} LOW=${CVE_frontend_LOW:-N/A}" "DTrack API"
    add_row "Policy gate (backend)" "$(status_icon "${VIOL_backend_FAIL:-N/A}")"  "FAIL=${VIOL_backend_FAIL:-N/A} WARN=${VIOL_backend_WARN:-N/A}"   "dtrack-gate.sh"
    add_row "Policy gate (frontend)" "$(status_icon "${VIOL_frontend_FAIL:-N/A}")" "FAIL=${VIOL_frontend_FAIL:-N/A} WARN=${VIOL_frontend_WARN:-N/A}" "dtrack-gate.sh"
    add_row "cosign 簽章 + attestation" "⚠" "${SIG_STATE}" "publish stage"
}

# CRIT+HIGH 任一 >0 視為問題（給 status_icon）；N/A → na。
cve_block() {
    local key="$1" c h
    c="$(eval echo "\${CVE_${key}_CRIT:-N/A}")"
    h="$(eval echo "\${CVE_${key}_HIGH:-N/A}")"
    if [ "$c" = "N/A" ] && [ "$h" = "N/A" ]; then echo "na"; return; fi
    if [ "${c:-0}" != "0" ] || [ "${h:-0}" != "0" ]; then echo "1"; else echo "0"; fi
}

# ─────────────────────────── 產出：HTML ───────────────────────────

write_html() {
    local ref desc sha proj
    ref="$(html_escape "$REL_REF")"; desc="$(html_escape "$GIT_DESC")"
    sha="$(html_escape "$GIT_SHA")"; proj="$(html_escape "$REL_PROJ")"
    cat > "$OUT_DIR/index.html" <<HTML
<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>稽核證據包 — ${ref} @ ${desc}</title>
<style>
  :root{--ok:#1a7f37;--warn:#9a6700;--bad:#cf222e;--bg:#fff;--ink:#1f2328;--line:#d0d7de}
  *{box-sizing:border-box}
  body{font:14px/1.55 -apple-system,Segoe UI,Roboto,"Noto Sans CJK TC","PingFang TC",sans-serif;color:var(--ink);margin:0;background:#f6f8fa}
  .wrap{max-width:980px;margin:0 auto;padding:28px 24px}
  h1{font-size:21px;margin:0 0 4px}
  .sub{color:#57606a;margin:0 0 20px}
  h2{font-size:15px;border-bottom:2px solid var(--line);padding-bottom:5px;margin:30px 0 12px}
  table{border-collapse:collapse;width:100%;background:var(--bg)}
  th,td{border:1px solid var(--line);padding:7px 10px;text-align:left;vertical-align:top}
  th{background:#f6f8fa;font-weight:600}
  code{background:#eff1f3;padding:1px 5px;border-radius:4px;font-size:12px}
  .meta td:first-child{width:170px;color:#57606a}
  .ok{color:var(--ok);font-weight:700;text-align:center}
  .warn{color:var(--warn);font-weight:700;text-align:center}
  .bad{color:var(--bad);font-weight:700;text-align:center}
  footer{color:#57606a;margin-top:34px;font-size:12px;border-top:1px solid var(--line);padding-top:12px}
</style></head><body><div class="wrap">
<h1>供應鏈稽核證據包</h1>
<p class="sub">每次發布自動產生 · SBOM + 來源證明 + 掃描結果 + 政策門檻 · 稽核/法遵可直接查閱</p>

<table class="meta">
 <tr><td>Release ref</td><td><code>${ref}</code></td></tr>
 <tr><td>Commit</td><td><code>${sha}</code> （${desc}）</td></tr>
 <tr><td>Pipeline</td><td>${REL_PIPE}</td></tr>
 <tr><td>Project</td><td>${proj}</td></tr>
 <tr><td>Generated (UTC)</td><td>${REL_WHEN}</td></tr>
</table>

<h2>證據盤點（Evidence Inventory）</h2>
<table><thead><tr><th>控制 Control</th><th style="width:56px">狀態</th><th>明細 / 數量</th><th style="width:140px">來源</th></tr></thead>
<tbody>
${ROWS}</tbody></table>

<h2>CVE 嚴重度彙整（Dependency-Track）</h2>
<table><thead><tr><th>專案</th><th>CRITICAL</th><th>HIGH</th><th>MEDIUM</th><th>LOW</th></tr></thead><tbody>
 <tr><td>liberty-backend</td><td>${CVE_backend_CRIT:-N/A}</td><td>${CVE_backend_HIGH:-N/A}</td><td>${CVE_backend_MED:-N/A}</td><td>${CVE_backend_LOW:-N/A}</td></tr>
 <tr><td>vue-frontend</td><td>${CVE_frontend_CRIT:-N/A}</td><td>${CVE_frontend_HIGH:-N/A}</td><td>${CVE_frontend_MED:-N/A}</td><td>${CVE_frontend_LOW:-N/A}</td></tr>
</tbody></table>

<h2>政策門檻判定（Policy Gate）</h2>
<p>backend：FAIL=${VIOL_backend_FAIL:-N/A} WARN=${VIOL_backend_WARN:-N/A} ·
   frontend：FAIL=${VIOL_frontend_FAIL:-N/A} WARN=${VIOL_frontend_WARN:-N/A}</p>

<h2>簽章 / 來源證明（Signatures &amp; Attestation）</h2>
<p>狀態：<strong>${SIG_STATE}</strong><br>
cosign sign（image 簽章）+ cosign attest（CycloneDX SBOM + 最小 SLSA provenance）於 manual <code>publish</code> stage 產生。</p>

<h2>安全控制 → NIST SSDF 對照（摘要）</h2>
<table><thead><tr><th>控制</th><th>NIST SSDF 實踐</th></tr></thead><tbody>
 <tr><td>依賴 allow-list / 二進位禁入</td><td>PW.4, PO.3</td></tr>
 <tr><td>Semgrep SAST</td><td>PW.7, PW.8</td></tr>
 <tr><td>Gitleaks 密鑰掃描</td><td>PW.5, PO.5</td></tr>
 <tr><td>Syft SBOM</td><td>PS.3</td></tr>
 <tr><td>Trivy + DTrack policy gate</td><td>RV.1, RV.3</td></tr>
 <tr><td>cosign sign + attest</td><td>PS.2, PS.3</td></tr>
</tbody></table>
<p>完整對照（每項實踐 ID 與監管主題）見 <code>docs/compliance-mapping.md</code>。</p>

<footer>Generated by <code>scripts/audit-report.sh</code> · ${REL_WHEN} · 自帶樣式單檔，無外部資產 · GitLab Pages 不可行見 ADR-0010</footer>
</div></body></html>
HTML
}

# ─────────────────────────── 產出：JSON ───────────────────────────

write_json() {
    jq -n \
        --arg ref "$REL_REF" --arg sha "$GIT_SHA" --arg desc "$GIT_DESC" \
        --arg pipe "$REL_PIPE" --arg proj "$REL_PROJ" --arg when "$REL_WHEN" \
        --arg sast_err "${SAST_ERR:-N/A}" --arg sast_warn "${SAST_WARN:-N/A}" \
        --arg secrets "${SECRETS_N:-N/A}" \
        --arg sbom_b "${SBOM_backend_N:-N/A}" --arg sbom_f "${SBOM_frontend_N:-N/A}" \
        --arg cve_b_crit "${CVE_backend_CRIT:-N/A}" --arg cve_b_high "${CVE_backend_HIGH:-N/A}" \
        --arg cve_f_crit "${CVE_frontend_CRIT:-N/A}" --arg cve_f_high "${CVE_frontend_HIGH:-N/A}" \
        --arg viol_b "${VIOL_backend_FAIL:-N/A}" --arg viol_f "${VIOL_frontend_FAIL:-N/A}" \
        --arg sig "$SIG_STATE" \
        '{
          release: {ref:$ref, commit:$sha, describe:$desc, pipeline:$pipe, project:$proj, generated:$when},
          controls: {
            sast:    {error:$sast_err, warning:$sast_warn},
            secrets: {hits:$secrets},
            sbom:    {backend:$sbom_b, frontend:$sbom_f},
            cve:     {backend:{critical:$cve_b_crit, high:$cve_b_high}, frontend:{critical:$cve_f_crit, high:$cve_f_high}},
            policy_gate: {backend_fail:$viol_b, frontend_fail:$viol_f},
            signatures:  $sig
          }
        }' > "$OUT_DIR/audit.json"
}

# ─────────────────────────── main ───────────────────────────

step "1/4  Release metadata";  collect_release
step "2/4  原始碼層證據（SAST + 密鑰）"; collect_sast; collect_secrets
step "3/4  SBOM + DTrack（CVE + policy）"
collect_sbom backend; collect_sbom frontend
collect_dtrack backend  "${DTRACK_PROJECT_BACKEND:-}"
collect_dtrack frontend "${DTRACK_PROJECT_FRONTEND:-}"
step "4/4  簽章狀態 + 產出"; collect_signatures
build_rows

case "$FORMATS" in *html*) write_html; ok "HTML → ${OUT_DIR#$ROOT/}/index.html" ;; esac
case "$FORMATS" in *json*) write_json; ok "JSON → ${OUT_DIR#$ROOT/}/audit.json" ;; esac

echo
ok "稽核證據包完成 → $OUT_DIR"
info "用瀏覽器開 index.html；CI 會把整個 audit/ 當 artifact 發布（留 365 天）。"
