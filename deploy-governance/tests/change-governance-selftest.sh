#!/usr/bin/env bash
# change-governance-selftest.sh — T2.4 變更治理工具組自我測試(fail-closed)。
#
# 兩支工具:
#   validate_change_class.py  變更分類閘門(急件/插單/補單 規則 + 繞過旗標守衛)
#   reconcile_release.py       發佈漂移對帳(CMDB 期望 vs 發佈庫實際)
# 在隔離暫存區用「手寫 manifest / CMDB CI / 發佈庫」跑正向 + 負向案例,斷言 exit code。
#
# 需求:python3 + PyYAML。  用法:bash deploy-governance/tests/change-governance-selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DG="$(cd "$HERE/.." && pwd)"
CC="python3 $DG/validate_change_class.py"
RC="python3 $DG/reconcile_release.py"

python3 -c 'import yaml' 2>/dev/null || { echo "✗ 需要 PyYAML"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

PASS=0; FAIL=0
assert() {  # assert <expected-exit> <desc> -- <cmd...>
  local want="$1" desc="$2"; shift 3
  "$@" >/tmp/cg-selftest.out 2>&1; local got=$?
  if [ "$got" = "$want" ]; then
    echo "  ✅ $desc(exit $got)"; PASS=$((PASS+1))
  else
    echo "  ❌ $desc(want $want, got $got)"; sed 's/^/       /' /tmp/cg-selftest.out; FAIL=$((FAIL+1))
  fi
}

# 寫一份最小 ReleaseManifest,change 區塊由 $2(YAML 片段,可空)注入。
write_manifest() {  # write_manifest <out> <change-yaml-block>
  { cat <<YAML
apiVersion: supplychain/v1
kind: ReleaseManifest
metadata:
  app: supply-chain-backend
  component: backend
  ecosystem: java
YAML
    if [ -n "${2:-}" ]; then printf '%s\n' "$2"; fi
    cat <<YAML
spec:
  artifact: {coordinates: com.example:product:1.0.0, type: war, path: target/product.war, digest: "sha256:$(printf 0 | head -c1; head -c63 </dev/zero | tr '\0' 0)"}
  signature: {path: target/product.war.sig, mode: key-pair}
  evidence: {sbom: sbom.json, scanVerdict: verdict.json, testReport: "sha256:$(printf x | sha256sum | cut -d' ' -f1)", testCount: 3}
  dataClassification: internal
YAML
  } > "$1"
}

echo "▶ 變更分類閘門 self-test(在 $WORK)"

# 1) 正向:無 change 區塊(= standard)→ 放行
write_manifest m1.yaml ""
assert 0 "正向:缺 change 視為 standard 放行" -- $CC --manifest m1.yaml

# 2) 正向:emergency 附齊 justification + pir
write_manifest m2.yaml "  change:
    type: emergency
    priority: P1
    justification: \"P1 production incident hotfix\"
    pir: {owner: alice, dueBy: 2026-07-01}"
assert 0 "正向:emergency 附 justification+pir 放行" -- $CC --manifest m2.yaml

# 3) 負向:emergency 缺 justification
write_manifest m3.yaml "  change:
    type: emergency
    pir: {owner: alice, dueBy: 2026-07-01}"
assert 1 "負向:emergency 缺 justification 被擋" -- $CC --manifest m3.yaml

# 4) 負向:emergency 缺 pir
write_manifest m4.yaml "  change:
    type: emergency
    justification: \"hotfix\""
assert 1 "負向:emergency 缺 pir 被擋" -- $CC --manifest m4.yaml

# 5) 負向:pir.dueBy 格式錯
write_manifest m5.yaml "  change:
    type: emergency
    justification: \"hotfix\"
    pir: {owner: alice, dueBy: 2026/07/01}"
assert 1 "負向:pir.dueBy 非 YYYY-MM-DD 被擋" -- $CC --manifest m5.yaml

# 6) 負向:retroactive 缺 nonconformity(補單≠漂白)
write_manifest m6.yaml "  change:
    type: retroactive
    justification: \"emergency 已上線,補單\"
    pir: {owner: alice, dueBy: 2026-07-01}"
assert 1 "負向:retroactive 缺 nonconformity 被擋(補單≠漂白)" -- $CC --manifest m6.yaml

# 7) 正向:retroactive 綁 nonconformity
write_manifest m7.yaml "  change:
    type: retroactive
    justification: \"emergency 已上線,補單\"
    nonconformity: \"DRIFT#42\"
    pir: {owner: alice, dueBy: 2026-07-01}"
assert 0 "正向:retroactive 綁 nonconformity 放行" -- $CC --manifest m7.yaml

# 8) 負向:非法 type
write_manifest m8.yaml "  change: {type: yolo}"
assert 1 "負向:非法 change.type 被擋" -- $CC --manifest m8.yaml

# 9) 負向:expedite 缺 reason
write_manifest m9.yaml "  change:
    type: normal
    expedite: {by: bob}"
assert 1 "負向:expedite 缺 reason 被擋" -- $CC --manifest m9.yaml

# 10) ★ 負向:繞過旗標(skipVerify)— 急件也不可關閘門
write_manifest m10.yaml "  change:
    type: emergency
    justification: \"hotfix\"
    pir: {owner: alice, dueBy: 2026-07-01}
    skipVerify: true"
assert 1 "負向:繞過旗標 skipVerify 被擋(★鐵則)" -- $CC --manifest m10.yaml

echo "▶ 發佈漂移對帳 self-test"
# 佈置:CMDB 期望 test 區 digest=AAAA;發佈庫 test 區實際擺 BBBB → 漂移
DA="sha256:$(printf a | sha256sum | cut -d' ' -f1)"
DB="sha256:$(printf b | sha256sum | cut -d' ' -f1)"
mkdir -p cmdb/test release-store/test/supply-chain-backend-backend
cat > cmdb/test/supply-chain-backend-backend.yaml <<YAML
apiVersion: cmdb/v1
kind: ReleasedArtifact
metadata: {ciId: ci-supply-chain-backend-backend-test, app: supply-chain-backend, component: backend, environment: test}
spec: {artifact: {digest: "$DA"}}
YAML
mkstore() {  # mkstore <digest>
  cat > release-store/test/supply-chain-backend-backend/release.yaml <<YAML
apiVersion: supplychain/v1
kind: ReleaseManifest
metadata: {app: supply-chain-backend, component: backend, ecosystem: java, environment: test}
spec: {artifact: {coordinates: x, type: war, path: product.war, digest: "$1"}}
YAML
}

# 11) 正向:CMDB 與發佈庫一致(都 AAAA)
mkstore "$DA"
assert 0 "正向:CMDB 與發佈庫 digest 一致 → 無漂移" -- $RC --cmdb-dir cmdb --store release-store --order test

# 12) 負向:發佈庫擺 BBBB ≠ CMDB AAAA → 漂移
mkstore "$DB"
assert 1 "負向:digest 不一致 → 偵測漂移(fail-closed)" -- $RC --cmdb-dir cmdb --store release-store --order test

# 13) 負向:CMDB 有登錄但發佈庫沒有 → 漂移
rm -rf release-store/test/supply-chain-backend-backend
assert 1 "負向:CMDB 登錄但發佈庫缺 → 偵測漂移" -- $RC --cmdb-dir cmdb --store release-store --order test

echo
echo "self-test 結果:PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "✅ 全部符合預期(變更治理 fail-closed 有效)"; exit 0; } \
                  || { echo "✗ 有案例不符預期"; exit 1; }
