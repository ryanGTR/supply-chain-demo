#!/usr/bin/env bash
# selftest.sh — deploy-governance 工具組的自我測試(fail-closed 驗證)。
#
# 在隔離的暫存工作區:產 cosign key-pair、簽一個假 artifact、組出 ReleaseManifest + 證據,
# 然後跑 1 個正向 + 6 個負向案例。每個案例斷言 verify_release.py 的 exit code 符合預期。
# 移植自 itops verify_deploy_gate 的負向案例,改成檔案型(artifact 內容雜湊 + verify-blob)。
#
# 需求:cosign、python3 + PyYAML。  用法:bash deploy-governance/tests/selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DG="$(cd "$HERE/.." && pwd)"
VERIFY="python3 $DG/verify_release.py"
VALIDATE="python3 $DG/cmdb_validate.py"
REGISTER="python3 $DG/cmdb_register.py"

command -v cosign >/dev/null || { echo "✗ 需要 cosign"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "✗ 需要 PyYAML"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
export COSIGN_PASSWORD=""

PASS=0; FAIL=0
# assert <expected-exit> <desc> -- <cmd...>
assert() {
  local want="$1" desc="$2"; shift 3
  "$@" >/tmp/dg-selftest.out 2>&1; local got=$?
  if [ "$got" = "$want" ]; then
    echo "  ✅ $desc(exit $got)"; PASS=$((PASS+1))
  else
    echo "  ❌ $desc(want exit $want, got $got)"; sed 's/^/       /' /tmp/dg-selftest.out; FAIL=$((FAIL+1))
  fi
}

# ── 共用：產信任根 + artifact + 證據 ──
cosign generate-key-pair >/dev/null 2>&1   # → cosign.key / cosign.pub
mkdir -p trust target cmdb
cp cosign.pub trust/cosign.pub
printf 'FAKE-WAR-CONTENT-%s' "$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')" > target/product.war
DIGEST="sha256:$(sha256sum target/product.war | cut -d' ' -f1)"
cosign sign-blob --key cosign.key --yes --output-signature target/product.war.sig target/product.war >/dev/null 2>&1
# 假 SBOM / 掃描判定(pass)/ 測試指紋
echo '{"bomFormat":"CycloneDX"}' > sbom-backend.json
echo '{"verdict":"pass","tool":"trivy","high":0,"critical":0}' > scan-verdict-backend.json
TESTFP="sha256:$(printf 'surefire-report' | sha256sum | cut -d' ' -f1)"

# manifest 產生器：write_manifest <out> <digest> <sigpath> <sbom> <verdict> <testfp> <testcount>
write_manifest() {
  cat > "$1" <<YAML
apiVersion: supplychain/v1
kind: ReleaseManifest
metadata: {app: supply-chain-backend, component: backend, ecosystem: java, requestedBy: selftest}
spec:
  artifact: {coordinates: com.example:product:1.0.0, type: war, path: target/product.war, digest: "$2"}
  signature: {path: "$3", mode: key-pair}
  evidence:
    sbom: "$4"
    scanVerdict: "$5"
    testReport: "$6"
    testCount: $7
  dataClassification: internal
YAML
}

echo "▶ deploy-governance self-test(在 $WORK)"

# 1) 正向：全部齊全 → 放行
write_manifest m-ok.yaml "$DIGEST" target/product.war.sig sbom-backend.json scan-verdict-backend.json "$TESTFP" 3
assert 0 "正向:完整 manifest 放行" -- $VERIFY --manifest m-ok.yaml --pubkey trust/cosign.pub --root .

# 2) 負向：未簽(指向不存在的簽章)
write_manifest m-unsigned.yaml "$DIGEST" target/missing.sig sbom-backend.json scan-verdict-backend.json "$TESTFP" 3
assert 1 "負向:未簽章被擋" -- $VERIFY --manifest m-unsigned.yaml --pubkey trust/cosign.pub --root .

# 3) 負向：artifact 被竄改(簽章後改內容 → hash 不符 / 驗章失敗)
cp target/product.war target/product.war.bak
printf 'TAMPERED' >> target/product.war
write_manifest m-tamper.yaml "$DIGEST" target/product.war.sig sbom-backend.json scan-verdict-backend.json "$TESTFP" 3
assert 1 "負向:artifact 被竄改被擋" -- $VERIFY --manifest m-tamper.yaml --pubkey trust/cosign.pub --root .
mv target/product.war.bak target/product.war   # 還原

# 4) 負向：缺 SBOM 物證
write_manifest m-nosbom.yaml "$DIGEST" target/product.war.sig sbom-missing.json scan-verdict-backend.json "$TESTFP" 3
assert 1 "負向:缺 SBOM 物證被擋" -- $VERIFY --manifest m-nosbom.yaml --pubkey trust/cosign.pub --root .

# 5) 負向：掃描判定非 pass
echo '{"verdict":"fail","high":2}' > scan-verdict-fail.json
write_manifest m-scanfail.yaml "$DIGEST" target/product.war.sig sbom-backend.json scan-verdict-fail.json "$TESTFP" 3
assert 1 "負向:掃描判定 fail 被擋" -- $VERIFY --manifest m-scanfail.yaml --pubkey trust/cosign.pub --root .

# 6) 負向：空測試套件(testCount=0)
write_manifest m-notest.yaml "$DIGEST" target/product.war.sig sbom-backend.json scan-verdict-backend.json "$TESTFP" 0
assert 1 "負向:空測試套件被擋" -- $VERIFY --manifest m-notest.yaml --pubkey trust/cosign.pub --root .

# 7) 負向：無效 digest
write_manifest m-baddigest.yaml "sha256:dead" target/product.war.sig sbom-backend.json scan-verdict-backend.json "$TESTFP" 3
assert 1 "負向:無效 digest 被擋" -- $VERIFY --manifest m-baddigest.yaml --pubkey trust/cosign.pub --root .

# ── CMDB:登錄(正向 manifest)→ 驗證通過;再驗缺物證 fail-closed ──
echo "▶ CMDB 登錄 + 驗證"
assert 0 "CMDB 登錄(正向)" -- $REGISTER --manifest m-ok.yaml --cmdb-dir cmdb --verified-at 2026-06-16T00:00:00Z
assert 0 "CMDB 驗證(物證齊全)" -- $VALIDATE --cmdb-dir cmdb --root .
# 把 SBOM 物證移走 → 驗證應 fail-closed
mv sbom-backend.json sbom-backend.json.hidden
assert 1 "CMDB 驗證(物證缺失被擋)" -- $VALIDATE --cmdb-dir cmdb --root .
mv sbom-backend.json.hidden sbom-backend.json

echo
echo "self-test 結果:PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "✅ 全部符合預期(L4 發佈閘門 fail-closed 有效)"; exit 0; } \
                  || { echo "✗ 有案例不符預期"; exit 1; }
