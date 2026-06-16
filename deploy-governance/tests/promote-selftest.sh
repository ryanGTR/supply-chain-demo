#!/usr/bin/env bash
# promote-selftest.sh — build-once promote 的自我測試(fail-closed)。
# 在暫存發佈庫驗:逐區晉級放行、禁跳關、正式區需核可、來源被竄改擋、build-once。
# 需求:cosign、python3 + PyYAML。  用法:bash deploy-governance/tests/promote-selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DG="$(cd "$HERE/.." && pwd)"
PROMOTE="python3 $DG/promote.py"

command -v cosign >/dev/null || { echo "✗ 需要 cosign"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "✗ 需要 PyYAML"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$WORK"; export COSIGN_PASSWORD=""
PASS=0; FAIL=0
assert() { local want="$1" desc="$2"; shift 3
  "$@" >/tmp/promote-st.out 2>&1; local got=$?
  if [ "$got" = "$want" ]; then echo "  ✅ $desc(exit $got)"; PASS=$((PASS+1))
  else echo "  ❌ $desc(want $want got $got)"; sed 's/^/       /' /tmp/promote-st.out; FAIL=$((FAIL+1)); fi
}

# ── 準備:簽一個 artifact,建來源區 test 的發佈格 ──
cosign generate-key-pair >/dev/null 2>&1
APP=demo-app; COMP=backend; NAME="$APP-$COMP"
mkdir -p trust "release-store/test/$NAME"
cp cosign.pub trust/cosign.pub
cd "release-store/test/$NAME"
printf 'WAR-CONTENT-%s' "$(head -c 32 /dev/urandom | od -An -tx1|tr -d ' \n')" > app.war
DIGEST="sha256:$(sha256sum app.war|cut -d' ' -f1)"
cosign sign-blob --key "$WORK/cosign.key" --yes --tlog-upload=false --output-signature app.war.sig app.war >/dev/null 2>&1
echo '{"bomFormat":"CycloneDX"}' > sbom.json
echo '{"verdict":"pass"}' > scan-verdict.json
TESTFP="sha256:$(printf t|sha256sum|cut -d' ' -f1)"
cat > release.yaml <<YAML
apiVersion: supplychain/v1
kind: ReleaseManifest
metadata: {app: $APP, component: $COMP, ecosystem: java, environment: test}
spec:
  artifact: {coordinates: com.example:app:1, type: war, path: app.war, digest: "$DIGEST"}
  signature: {path: app.war.sig, mode: key-pair}
  evidence: {sbom: sbom.json, scanVerdict: scan-verdict.json, testReport: "$TESTFP", testCount: 2}
  dataClassification: internal
YAML
cd "$WORK"
PUB="$WORK/trust/cosign.pub"

echo "▶ promote self-test(在 $WORK)"

# 1) 正向:test → uat 放行
assert 0 "正向:test → uat 逐區晉級" -- $PROMOTE --app $APP --component $COMP --from test --to uat \
  --store release-store --order test,uat,prod --pubkey "$PUB"

# 2) 負向:禁跳關 test → prod
assert 1 "負向:禁跳關 test → prod 被擋" -- $PROMOTE --app $APP --component $COMP --from test --to prod \
  --store release-store --order test,uat,prod --pubkey "$PUB"

# 3) 負向:晉級正式區 prod 但無 CAB 核可(uat 已存在,from uat)
assert 1 "負向:prod 無 CAB 核可被擋" -- $PROMOTE --app $APP --component $COMP --from uat --to prod \
  --store release-store --order test,uat,prod --pubkey "$PUB"

# 4) 正向:uat → prod 帶 --approved-by
assert 0 "正向:uat → prod(CAB 核可)" -- $PROMOTE --app $APP --component $COMP --from uat --to prod \
  --store release-store --order test,uat,prod --pubkey "$PUB" --approved-by alice

# 5) 負向:來源區 artifact 被竄改 → 晉級時重新驗章擋
#    新起一個 sandbox→test 場景:把 test 的 artifact 改掉(簽章對不上)
printf 'TAMPER' >> "release-store/test/$NAME/app.war"
assert 1 "負向:來源被竄改 → 晉級重驗被擋" -- $PROMOTE --app $APP --component $COMP --from test --to uat \
  --store release-store --order test,uat,prod --pubkey "$PUB"

# 6) 負向:來源區不存在(uat2 無發佈)→ 禁跳關/無上游
assert 1 "負向:來源區無發佈被擋" -- $PROMOTE --app nope --component backend --from test --to uat \
  --store release-store --order test,uat,prod --pubkey "$PUB"

echo
echo "promote self-test 結果:PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "✅ 全部符合預期(build-once promote fail-closed 有效)"; exit 0; } \
                  || { echo "✗ 有案例不符預期"; exit 1; }
