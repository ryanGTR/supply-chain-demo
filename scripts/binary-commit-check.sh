#!/usr/bin/env bash
#
# binary-commit-check.sh — 偵測 git 提交內是否有禁止的二進位檔
#
# 規則：禁止任何「執行檔 / 套件壓縮包 / 編譯產物 / 預編譯 binary」進入 repo。
# 這類檔案應該由 build pipeline 產出、由 artifact registry（Nexus）發行，
# 不應該躺在源碼裡 — 否則 SBOM 抓不到、CVE 掃不到、簽章也對不上。
#
# 用法:
#   ./binary-commit-check.sh                # 檢查 staged files（給 pre-commit hook 用）
#   ./binary-commit-check.sh --commit <SHA> # 檢查單一 commit 引入的檔案
#   ./binary-commit-check.sh --range <A>..<B>   # 檢查一段 range（給 CI / pre-receive）
#
# 偵測策略：
#   1. 副檔名黑名單（快速）
#   2. magic byte 偵測（防 dev 改副檔名繞過）
#   3. > 1 MB 警告（可疑大檔）
#
# Exit code:
#   0 通過
#   1 有禁止檔
#

set -euo pipefail

C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YELLOW=$'\033[0;33m'; C_RESET=$'\033[0m'
ok()   { echo "${C_GREEN}  ✓ $1${C_RESET}"; }
warn() { echo "${C_YELLOW}  ⚠ $1${C_RESET}"; }
fail() { echo "${C_RED}  ✗ $1${C_RESET}"; }

# ─────────────── 黑名單 ───────────────

# 副檔名（小寫比對）
BANNED_EXTS=(
    # JVM 產物
    jar war ear class
    # Windows 執行檔
    exe dll msi
    # Linux 執行檔 / shared lib
    so a o ko
    # macOS 執行檔
    dylib dmg
    # Mobile
    apk aab ipa
    # Python compiled
    pyc pyo whl egg
    # Node / packager 產物
    tgz
    # Archive
    zip tar gz bz2 xz 7z rar
    # OS image / installer
    deb rpm iso img bin
    # ML / 大型 binary
    pkl pt onnx safetensors h5
)

# magic-byte signature → 描述
declare -A MAGIC_BYTES=(
    ["\x4d\x5a"]="DOS/Windows PE executable (.exe/.dll)"
    ["\x7f\x45\x4c\x46"]="ELF executable / shared library"
    ["\xfe\xed\xfa\xce"]="Mach-O 32-bit (macOS binary)"
    ["\xfe\xed\xfa\xcf"]="Mach-O 64-bit (macOS binary)"
    ["\xca\xfe\xba\xbe"]="Java class file or Mach-O universal binary"
    ["\x50\x4b\x03\x04"]="ZIP / JAR / WAR / DOCX archive"
    ["\x1f\x8b\x08"]="gzip archive (.gz/.tgz)"
    ["\x42\x5a\x68"]="bzip2 archive"
    ["\xfd\x37\x7a\x58\x5a"]="XZ archive"
    ["ustar"]="POSIX tar archive"
)

MAX_SIZE_MB=1

# ─────────────── 取得要檢查的檔案列表 ───────────────

MODE="staged"
COMMIT=""
RANGE=""
for arg in "$@"; do
    case "$arg" in
        --commit) MODE="commit"; shift; COMMIT="$1" ;;
        --range)  MODE="range";  shift; RANGE="$1" ;;
    esac
done

case "$MODE" in
    staged)  FILES=$(git diff --cached --name-only --diff-filter=AM) ;;
    commit)  FILES=$(git show --pretty="" --name-only "$COMMIT") ;;
    range)   FILES=$(git diff --name-only --diff-filter=AM "$RANGE") ;;
esac

[ -z "$FILES" ] && { ok "沒有 staged / 新增的檔案要檢查"; exit 0; }

# ─────────────── 檢查 ───────────────

BAD_COUNT=0

while IFS= read -r f; do
    [ -z "$f" ] || [ ! -f "$f" ] && continue

    # 1. 副檔名
    ext="${f##*.}"
    ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    for banned in "${BANNED_EXTS[@]}"; do
        if [ "$ext_lower" = "$banned" ]; then
            fail "$f"
            echo "      reason: 副檔名 .$ext_lower 在黑名單"
            BAD_COUNT=$((BAD_COUNT+1))
            continue 2
        fi
    done

    # 2. magic byte（讀前 16 bytes，比對所有 signature）
    head_bytes=$(head -c 16 "$f" 2>/dev/null | od -An -vtx1 | tr -d ' \n' | head -c 32 || echo "")
    for sig_pattern in "${!MAGIC_BYTES[@]}"; do
        # 把 \x.. pattern 轉為純 hex 比對
        hex_pattern=$(printf "$sig_pattern" | od -An -vtx1 | tr -d ' \n')
        if [ -n "$hex_pattern" ] && [[ "$head_bytes" == "$hex_pattern"* ]]; then
            fail "$f"
            echo "      reason: magic bytes 對應 ${MAGIC_BYTES[$sig_pattern]}"
            BAD_COUNT=$((BAD_COUNT+1))
            continue 2
        fi
    done

    # 3. tar magic 在 offset 257
    if [ "$(dd if="$f" bs=1 count=5 skip=257 2>/dev/null)" = "ustar" ]; then
        fail "$f"
        echo "      reason: tar archive (ustar at offset 257)"
        BAD_COUNT=$((BAD_COUNT+1))
        continue
    fi

    # 4. 大檔警告（不擋）
    size_bytes=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [ "$size_bytes" -gt $((MAX_SIZE_MB * 1024 * 1024)) ]; then
        size_mb=$((size_bytes / 1024 / 1024))
        warn "$f (${size_mb} MB) — 大檔，請確認不是 binary"
    fi
done <<<"$FILES"

# ─────────────── 結果 ───────────────

echo
if [ "$BAD_COUNT" -eq 0 ]; then
    ok "binary-commit-check PASS — 沒有被禁止的二進位檔"
    exit 0
else
    fail "binary-commit-check FAIL — 找到 $BAD_COUNT 個禁止的檔案"
    echo
    echo "  ${C_YELLOW}為什麼擋？${C_RESET}"
    echo "    1. 二進位無法 diff、SBOM 抓不到、CVE 掃不到"
    echo "    2. 應該由 CI build 出，存 Nexus / artifact registry"
    echo "    3. 防止偷渡 malicious binary 進 repo"
    echo
    echo "  ${C_YELLOW}怎麼做：${C_RESET}"
    echo "    - 把這些檔加到 .gitignore"
    echo "    - 已 commit 的用 git filter-repo / BFG 移除歷史"
    echo "    - 真的非要 commit？走 LFS + 經過 security exception 流程"
    exit 1
fi
