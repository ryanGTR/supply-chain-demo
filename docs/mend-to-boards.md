---
title: Mend findings → Azure Boards（給無 Mend seat 者的元件風險可見性）
type: howto
created: 2026-06-09
updated: 2026-06-09
tags: [supply-chain, mend, azure-boards, azure-devops, visibility, sca]
sources:
  - app/scripts/mend-to-boards.sh（ADO app repo）
  - app/azure-pipelines.yml mend-real-gate job
---

# Mend findings → Azure Boards

> **問題**：公司 Mend 後台登入帳號（seat）不夠多人用，但很多人需要知道「哪些第三方元件有問題」。
> **解法**：CI 把 Mend 的 findings 自動開成 **Azure Boards Issue**（大家都有 Boards）。
> Mend 整合見 [[mend-real-integration]]；整體閉環見 [[maturity-assessment]]。

---

## 0. 結論

`mend-real-gate` 在 **main run** 解析 `mend dep` 輸出 → 把**漏洞（High/Critical）+ policy 違規**開成 Azure Boards **Issue**（tag `mend-sca` 去重、severity→Priority），並**自動關閉不再出現的 Issue**（讓 Boards 反映現況）。沒有 Mend seat 的人在 Boards 就能看到元件風險。

---

## 1. 資料流

```
mend dep --update（main） ──stdout──▶ /tmp/mend-<comp>.out
        │                                    │
        │（漏洞表 + policy 違規表）           ▼
        │                          scripts/mend-to-boards.sh
        │                          解析 → 去重 → az boards work-item create
        ▼                                    │
  Mend 平台(inventory)                  Azure Boards Issue（tag: mend-sca）
```

逐元件（backend/frontend/dotnet）各存一個輸出檔再解析，避免跨元件混淆。

---

## 2. 關鍵設計決策

| 決策 | 為何 |
|---|---|
| **findings 來源 = 解析 mend stdout** | `mend-sca-report.json` 只有 stats、無 per-finding；此 CLI(26.5) 也無 `mend sbom`。findings 只在 stdout 的文字表格 |
| **只在 main/manual 開票**（PR 不開）| PR 是過程、會有 branch 噪音；main = inventory of record |
| **work item 用 Issue** | 此 ADO project 是 **Basic** process（無 Bug，只有 Issue/Task/Epic）|
| **去重 = tag `mend-sca` + `key:<lib@ver\|issue>`** | 重跑不重複開；WIQL 撈既有 key 比對 |
| **自動關閉**（idempotent）| 本元件既有 open Issue 中 key 不在本次掃描的 → 設 `Done`；讓 Boards 反映現況，不只增不減 |
| **掃描失敗護欄** | 只有 mend 確實完成掃描（有 `Detected`/`No Policy` 標記）才執行關閉，避免掃描失敗誤關全部 |
| **severity → Priority** | CRITICAL=1 / HIGH=2 / MEDIUM=3 |
| **continueOnError（advisory）** | Boards 開票失敗不擋 build |

解析兩張表：
- **漏洞表** `| SEV | lib.ext | CVE | fix |` → 取 HIGH/CRITICAL
- **policy 違規表** `| lib.ext | policy-type | policy-name |` → 排除依賴樹的 `|--` 行

---

## 3. 踩過的雷（重要）

| 雷 | 症狀 | 修法 |
|---|---|---|
| **az 認證** | `az boards` 在我互動 shell 能開票，pipeline 非互動 task 卻建 0 | az devops PAT 存**系統 keyring**，agent task 無解鎖的 keyring session → 改用 `AZURE_DEVOPS_EXT_PAT=$(System.AccessToken)` + `--organization`（build token，不靠 keyring）|
| **NuGet 版本解析** | `newtonsoft.json.13@0.3`（切錯）| NuGet 是 `name.ver.nupkg`（點分），改「首個 `.數字` 換 `@`」→ `newtonsoft.json@13.0.3` |
| **去重 key 含空格** | `policy:Library Staleness` 被空格分隔切爛、去重失效 | 改**換行分隔**、保留 key 內部空格 |
| **az 子命令參數不一致** | `az boards work-item update`/`show` 報 `unrecognized arguments: --project` | update/show **不吃 `--project`**（只 create/query 吃）→ 關閉時只傳 `--organization` |
| **吞錯** | 失敗看不到原因 | 拿掉 `2>/dev/null`，開票失敗印出 az 錯誤 |

> 教訓：自架 agent 上「我互動能跑」≠「pipeline task 能跑」——**互動 session 的 keyring/登入態，非互動 task 拿不到**。ADO 內要用 `System.AccessToken`。

---

## 4. 實跑結果（2026-06-09）

| 元件 | findings | Issue 數 |
|---|---|---|
| backend | commons-lang3 乾淨（最新版）| 0 |
| frontend | 12 個 Library Staleness（axios 子樹）| 12 |
| dotnet | Newtonsoft.Json 13.0.3 staleness | 1 |

共 **13 張 Issue**（人工驗證）。

---

## 5. 可選後續

- ~~自動關閉~~ ✅ **已實作**（§2）：finding 消失 → 自動設 `Done`，含掃描失敗護欄。
- **服務帳號權限**：靠 build service（System.AccessToken）的 work-item write/update；真實環境用專用服務帳號時要確認該權限。
- **重開**：finding 消失被關成 `Done` 後若再出現，去重查詢以 `[State] <> 'Done'` 過濾 → 會開**新** Issue（而非復活舊的）。

---

## 6. 在公司重現（step-by-step）

### 6.1 前置確認
1. **Boards process 類型** → 決定 work item type：
   ```bash
   az devops invoke --area wit --resource workitemtypes \
     --route-parameters project=<PROJECT> --api-version 7.1 \
     --query "value[].name" -o tsv
   ```
   有 `Bug` 用 Bug；只有 `Issue`（Basic process）就用 Issue（改腳本 `--type`）。
2. **build service 要能寫 work item**：用 `System.AccessToken` 認證，需 **Project Build Service** 有
   work-item write（多數預設有）。若公司開了「Limit job authorization scope」或自訂權限擋住，
   到 *Project Settings → Permissions → Project Build Service* 給 *Edit work items in this node*。
3. **agent 主機**已裝 `mvn/node/dotnet` + Mend CLI（見 [[ado-self-hosted-agent]]）。

### 6.2 腳本 `scripts/mend-to-boards.sh`（全文）
```bash
#!/usr/bin/env bash
# mend-to-boards.sh <component> <mend-output-file>
# 解析 mend dep 輸出 → 把 policy 違規 + High/Critical 漏洞開成 Azure Boards Issue（去重）。
set -uo pipefail
COMP="${1:?用法: mend-to-boards.sh <component> <mend-output>}"
OUT="${2:?需 mend 輸出檔}"
PROJECT="${BOARDS_PROJECT:-supply-chain-demo}"
TAG="mend-sca"
ORG="${SYSTEM_COLLECTIONURI:-https://dev.azure.com/<ORG>/}"; ORG="${ORG%/}"
AZ_ARGS=(--organization "$ORG" --project "$PROJECT")  # create/query 用
AZ_ORG=(--organization "$ORG")                        # update/show 不吃 --project
CLOSED_STATE="${BOARDS_CLOSED_STATE:-Done}"           # Basic process 完成態(Agile 用 Closed)

parse_lib() {   # lib 檔名 → name@version
  local f="$1"
  case "$f" in
    *.nupkg) echo "${f%.nupkg}" | sed -E 's/\.([0-9])/@\1/' ;;          # nuget: name.ver.nupkg
    *)       echo "$f" | sed -E 's/\.(jar|tgz|war|aar|zip)$//' | sed -E 's/^(.+)-([0-9][A-Za-z0-9.+_-]*)$/\1@\2/' ;;
  esac
}
sev_prio() { case "$1" in CRITICAL) echo 1;; HIGH) echo 2;; MEDIUM) echo 3;; *) echo 4;; esac; }

if [ "${MOCK:-0}" = "1" ]; then EXISTING=""; else
  EXISTING=$(az boards query "${AZ_ARGS[@]}" --wiql \
    "SELECT [System.Id],[System.Tags] FROM workitems WHERE [System.Tags] CONTAINS '$TAG' AND [System.State] <> '$CLOSED_STATE'" \
    --query "[].fields.\"System.Tags\"" -o tsv 2>/dev/null | tr ';' '\n' | grep -oE 'key:[^;]+' | sed -E 's/^key: *//; s/ +$//')
fi
SEEN=$(mktemp); printf '%s\n' "$EXISTING" > "$SEEN"
FOUND=$(mktemp)    # 本次掃描現況的 key(不論新舊)；給自動關閉比對
created=0; skipped=0

emit() {  # key  title  sev
  local key="$1" title="$2" sev="$3"
  echo "$key" >> "$FOUND"
  grep -qxF "$key" "$SEEN" && { skipped=$((skipped+1)); return; }
  echo "$key" >> "$SEEN"
  if [ "${MOCK:-0}" = "1" ]; then echo "  + [$sev] $title"; created=$((created+1)); return; fi
  if az boards work-item create "${AZ_ARGS[@]}" --type "Issue" --title "$title" \
       --fields "System.Tags=$TAG; key:$key; comp:$COMP" "Microsoft.VSTS.Common.Priority=$(sev_prio "$sev")" \
       -o none 2> /tmp/.boarderr; then created=$((created+1));
  else echo "  ✗ 開票失敗: $title"; sed 's/^/      /' /tmp/.boarderr | head -3; fi
}

# 1. 漏洞表：| SEV | lib.ext | CVE | fix |（取 HIGH/CRITICAL）
while IFS='|' read -r _ sev lib cve _; do
  sev=$(echo "$sev"|tr -d ' '); libf=$(echo "$lib"|tr -d ' '); cve=$(echo "$cve"|tr -d ' ')
  case "$libf" in *.jar|*.tgz|*.nupkg|*.war) ;; *) continue;; esac
  [ -n "$cve" ] || continue
  lv=$(parse_lib "$libf"); emit "${lv}|${cve}" "[supply-chain/$COMP] ${lv} — ${cve} (${sev})" "$sev"
done < <(grep -E '^\| *(HIGH|CRITICAL) +\|' "$OUT" 2>/dev/null)

# 2. policy 違規表：| lib.ext | policy-type | policy-name |（排除依賴樹 |-- 行）
while IFS='|' read -r _ lib ptype pname _; do
  libf=$(echo "$lib"|tr -d ' ')
  case "$libf" in *.jar|*.tgz|*.nupkg|*.war) ;; *) continue;; esac
  case "$libf" in *--*) continue;; esac
  ptype=$(echo "$ptype"|sed 's/^ *//; s/ *$//'); [ -z "$ptype" ] && continue
  lv=$(parse_lib "$libf"); emit "${lv}|policy:${ptype}" "[supply-chain/$COMP] ${lv} — policy: ${ptype}" "HIGH"
done < <(awk '/Detected .* Policy violations/{f=1} /^[A-Za-z].* = /{f=0} f' "$OUT" 2>/dev/null | grep -E '^\| ' | grep -ivE 'LIBRARY *\| *POLICY')

# 3. 自動關閉：本元件既有 open Issue 中 key 不在本次掃描的 → 設 Done（含掃描失敗護欄）
closed=0
if [ "${MOCK:-0}" != "1" ] && grep -qE "Detected .* (vulnerabilities|Policy violations)|No Policy violations" "$OUT"; then
  while IFS=$'\t' read -r id tags; do
    [ -z "$id" ] && continue
    key=$(echo "$tags" | tr ';' '\n' | grep -oE 'key:[^;]+' | sed -E 's/^key: *//; s/ +$//')
    grep -qxF "$key" "$FOUND" && continue                 # 仍在現況 → 不關
    az boards work-item update "${AZ_ORG[@]}" --id "$id" --state "$CLOSED_STATE" \
      --discussion "mend-sca: 此 finding 不再出現於最新掃描，自動關閉。" -o none 2>/dev/null \
      && { echo "  ✓ 關閉(finding 消失): $key"; closed=$((closed+1)); }
  done < <(az boards query "${AZ_ARGS[@]}" --wiql \
      "SELECT [System.Id],[System.Tags] FROM workitems WHERE [System.Tags] CONTAINS '$TAG' AND [System.Tags] CONTAINS 'comp:$COMP' AND [System.State] <> '$CLOSED_STATE'" \
      --query "[].{id:fields.\"System.Id\",tags:fields.\"System.Tags\"}" -o json 2>/dev/null \
    | jq -r '.[]? | "\(.id)\t\(.tags)"')
fi

rm -f "$SEEN" "$FOUND"; echo "[$COMP] Boards: 建立 $created、跳過 $skipped、關閉 $closed"
```
> 把 `<ORG>` 換成公司 org（pipeline 內會被 `SYSTEM_COLLECTIONURI` 覆蓋，本機測才用 fallback）。
> 本機測解析：`MOCK=1 ./scripts/mend-to-boards.sh frontend mend-output.txt`（只印不開票）。

### 6.3 pipeline 接法（`mend-real-gate` 迴圈內）
```yaml
      - bash: |
          # ...（前略：mend CLI 準備、MODE 判斷）
          for d in backend frontend dotnet; do
            SCOPE="$PRODUCT//<project>/$d"
            if [ "$d" = "dotnet" ]; then ( cd "$d" && dotnet restore ) || true; fi
            ( cd "$d" && "$MEND" dep $MODE --scope "$SCOPE" ) > "/tmp/mend-$d.out" 2>&1 || rc=1
            cat "/tmp/mend-$d.out"
            if [ "$BUILD_REASON" != "PullRequest" ]; then        # 只 main/manual 開票
              chmod +x scripts/mend-to-boards.sh
              ./scripts/mend-to-boards.sh "$d" "/tmp/mend-$d.out" || echo "⚠ Boards 開票失敗"
            fi
          done
        env:
          MEND_URL: $(MEND_URL)
          MEND_EMAIL: $(MEND_EMAIL)
          MEND_USER_KEY: $(MEND_USER_KEY)
          AZURE_DEVOPS_EXT_PAT: $(System.AccessToken)   # ★ az boards 認證關鍵（不靠 keyring）
```

### 6.4 驗證
```bash
az boards query --project <PROJECT> \
  --wiql "SELECT [System.Id],[System.Title] FROM workitems WHERE [System.Tags] CONTAINS 'mend-sca'" \
  --query "length(@)"
```

---

## See Also
- [[mend-real-integration]] — Mend CLI SCA 整合（findings 的來源）
- [[maturity-assessment]] — 整體閉環（Boards = 可見性層）
- [[ado-self-hosted-agent]] — 自架 agent（keyring/互動態的踩雷脈絡）
