---
title: feed-sync — 核可元件鏡像進 Azure Artifacts curated feed
type: howto
created: 2026-06-09
updated: 2026-06-09
tags: [supply-chain, azure-artifacts, feed-sync, curated-feed, quarantine, maven, l1-source-enforcement]
sources:
  - dep-policy/scripts/feed-sync-maven.sh
  - dep-policy/feed-sync.yml（pipeline id 3）
  - feed：approved-deps（project-scoped, upstream OFF, id 850fdf29...）
---

# feed-sync — 核可元件 → curated feed

> **目標**：dep-policy 審核過的 coord → 推進 Azure Artifacts **curated feed**（upstream OFF），
> build 只從 feed 拉 = 真正的 **default-deny quarantine**（沒核可的根本不在 feed）。
> 對照 [[dep-policy-gate-concepts]]（白名單）、[[azure-devops-port]]（無 Nexus 的取代）。

---

## 0. 結論

兩半：**(1) feed-sync**（核可 coord + transitive → 鏡像進 feed，本篇）+ **(2) L1 來源強制**（build 只從 feed 拉，§7 待做）。
feed 設 **upstream OFF（curated-only）**：feed 內**只有你明確推進去的**，才是 default-deny；upstream ON 會 proxy 公開源、擋不住沒核可的。

---

## 1. 為什麼 upstream OFF

| | upstream OFF（curated，採用）| upstream ON（proxy）|
|---|---|---|
| feed 內容 | 只有明確推入的核可清單 | 任何公開源有的拉過就快取 |
| 治理 | **default-deny** ✅ | default-allow |
| 代價 | feed-sync 要推核可 coord + 全 transitive | 輕，但非真 quarantine |

> 新建 feed 預設無 upstream sources = 自動 curated。

---

## 2. 建 feed（curated）

```bash
echo '{"name":"approved-deps","description":"核可第三方元件庫(curated, 無 upstream)"}' > feed.json
az devops invoke --area packaging --resource feeds --route-parameters project=<PROJ> \
  --http-method POST --in-file feed.json --api-version 7.1 \
  --query "{id:id,name:name,upstreamEnabled:upstreamEnabled}" -o json
# upstreamEnabled:null = 無 upstream = curated ✓
```

各生態系連線 URL（feed-sync 推 + L1 拉都用）：
```
Maven:  https://pkgs.dev.azure.com/<ORG>/<PROJ>/_packaging/approved-deps/maven/v1
npm:    https://pkgs.dev.azure.com/<ORG>/<PROJ>/_packaging/approved-deps/npm/registry/
NuGet:  https://pkgs.dev.azure.com/<ORG>/<PROJ>/_packaging/approved-deps/nuget/v3/index.json
```

---

## 3. 認證：用 FEED_PAT（不是 System.AccessToken）

**踩雷①**：原想用 pipeline 的 `System.AccessToken`（無 PAT），但 build service token 身分
（GUID `735fd06d…`）**即使在 feed UI 授了 Feed Publisher (Contributor) 仍 403** "need Reader"——
feed UI 顯示的 identity id 跟 token 實際 id 對不上（ADO 身分解析眉角），且 feedpermissions API
只有 preview 版本、被 az CLI 的版本 barrier 擋住（見踩雷②），無法用 CLI 授對。

**解法**：改用 **FEED_PAT**——一個 **Packaging (Read & write)** scope 的 PAT，加成 pipeline 的
**secret 變數**（同 Mend 認證模式，私鑰不經第三方）。腳本優先用 `FEED_PAT`、退回 `SYSTEM_ACCESSTOKEN`。

> 真公司環境若 build service 身分能授對，仍可用 System.AccessToken；demo 因身分對不上改 PAT。

---

## 4. 踩雷總表（4 個真 bug）

| # | 症狀 | 根因 | 解法 |
|---|---|---|---|
| ① | feed push 一直 403 "need Reader" | build service token 身分跟 feed 授權對不上 | 改 **FEED_PAT** secret（§3）|
| ② | `az devops invoke … --api-version 7.1-preview.1` 報 `could not convert '7.1.1'` | az CLI 對 `-preview.N` 有 float parse bug | 用 **`7.1-preview`（無 .N 後綴）** 繞過（pool 授權、查 feed 套件都靠這個）|
| ③ | deploy 秒失敗 `Cannot deploy artifact from the local repository` | maven-deploy-plugin **3.x 拒絕部署 ~/.m2 內的檔** | **複製出 .m2** 到暫存再 deploy |
| ④ | BOM(pom-only) 失敗 `artifact information is incomplete` | pom-only 沒帶座標 | 顯式 `-DgroupId -DartifactId -Dversion -Dpackaging=pom` |

---

## 5. feed-sync 腳本（`scripts/feed-sync-maven.sh`，全文）

```bash
#!/usr/bin/env bash
# 把核可 Maven coord 鏡像進 Azure Artifacts feed(curated, upstream OFF)。
# 認證：優先 FEED_PAT(Packaging read&write secret)，否則退回 System.AccessToken。
set -uo pipefail
APPROVED="${1:?需 maven-approved.yaml 路徑}"
FEED_URL="${FEED_MAVEN_URL:?需 FEED_MAVEN_URL}"
PAT="${FEED_PAT:-}"; case "$PAT" in '$(FEED_PAT)'|'') PAT="";; esac
TOKEN="${PAT:-${SYSTEM_ACCESSTOKEN:-}}"
[ -n "$TOKEN" ] || { echo "✗ 無認證：設 FEED_PAT(secret) 或 SYSTEM_ACCESSTOKEN"; exit 1; }

SETTINGS=$(mktemp); STAGE=$(mktemp -d)
cat > "$SETTINGS" <<EOF
<settings><servers><server>
<id>approved-deps</id><username>azdo</username><password>${TOKEN}</password>
</server></servers></settings>
EOF
GET='org.apache.maven.plugins:maven-dependency-plugin:3.6.1:get'

coords=$(grep -oE 'coord:[[:space:]]*[A-Za-z0-9._:-]+' "$APPROVED" | sed -E 's/coord:[[:space:]]*//')
pushed=0; skipped=0; failed=0
for c in $coords; do
  g="${c%%:*}"; r="${c#*:}"; a="${r%%:*}"; v="${r##*:}"
  [ "$g" = "$c" ] && continue
  P="$HOME/.m2/repository/${g//.//}/$a/$v"
  mvn -q "$GET" -Dartifact="$g:$a:$v" >/dev/null 2>&1 || true
  [ -f "$P/$a-$v.pom" ] || mvn -q "$GET" -Dartifact="$g:$a:$v:pom" >/dev/null 2>&1 || true
  # deploy-plugin 3.x 拒部署 local repo 內的檔 → 複製出 .m2（踩雷③）
  sjar="$STAGE/$a-$v.jar"; spom="$STAGE/$a-$v.pom"
  [ -f "$P/$a-$v.jar" ] && cp -f "$P/$a-$v.jar" "$sjar"
  [ -f "$P/$a-$v.pom" ] && cp -f "$P/$a-$v.pom" "$spom"
  args=(-DrepositoryId=approved-deps -Durl="$FEED_URL" --settings "$SETTINGS")
  if [ -f "$sjar" ]; then args+=(-Dfile="$sjar"); [ -f "$spom" ] && args+=(-DpomFile="$spom")
  elif [ -f "$spom" ]; then args+=(-Dfile="$spom" -DgroupId="$g" -DartifactId="$a" -Dversion="$v" -Dpackaging=pom)  # BOM（踩雷④）
  else echo "✗ 下載不到 $c"; failed=$((failed+1)); continue; fi
  out=$(mvn -q deploy:deploy-file "${args[@]}" 2>&1); rc=$?
  rm -f "$sjar" "$spom"
  if [ $rc -eq 0 ]; then echo "✓ pushed $c"; pushed=$((pushed+1))
  elif echo "$out" | grep -qiE "409|conflict|already exist"; then echo "= 已在 feed $c"; skipped=$((skipped+1))
  else echo "✗ 部署失敗 $c"; echo "$out" | grep -iE "status code|Unauthorized|Forbidden|Cannot deploy|Could not transfer|Failed to" | head -2; failed=$((failed+1)); fi
done
rm -rf "$SETTINGS" "$STAGE"
echo "feed-sync(maven): 推 $pushed、已在 $skipped、失敗 $failed"
[ "$failed" -eq 0 ]
```

> **idempotent**：已在 feed 的版本 deploy 會 409 → 視為 `= 已在 feed` 跳過。重跑只推新的。

---

## 6. pipeline（`feed-sync.yml`，獨立 pipeline）

```yaml
trigger:
  branches: { include: [main] }
  paths: { include: [ maven-approved.yaml, npm-approved.yaml, nuget-approved.yaml ] }
pr: none
pool: { name: Default }
steps:
  - checkout: self
  - bash: |
      set -e
      chmod +x scripts/feed-sync-maven.sh
      ./scripts/feed-sync-maven.sh maven-approved.yaml
    displayName: 'feed-sync: Maven 核可 → approved-deps feed'
    env:
      SYSTEM_ACCESSTOKEN: $(System.AccessToken)
      FEED_PAT: $(FEED_PAT)   # Packaging read&write PAT(secret)
      FEED_MAVEN_URL: 'https://pkgs.dev.azure.com/<ORG>/<PROJ>/_packaging/approved-deps/maven/v1'
```

> 新 pipeline 第一次用 Default pool 會卡 Checkpoint → CLI 授權：
> `az devops invoke --area pipelinePermissions --resource pipelinePermissions --route-parameters project=<PROJ> resourceType=queue resourceId=1 --http-method PATCH --in-file '{"pipelines":[{"id":<pid>,"authorized":true}]}' --api-version 7.1-preview`（注意 `7.1-preview` 無 .N，踩雷②）

### 驗證
```bash
az devops invoke --area packaging --resource packages --route-parameters project=<PROJ> \
  feedId=<FEED_ID> --api-version 7.1-preview --query "length(value)" -o tsv
# 實跑結果：feed 有全 32 個核可 Maven 元件（jakarta.* + microprofile BOM + commons-lang3）
```

---

## 7. L1 來源強制（待做）

讓 build **只從 feed 拉**（核可外的根本拿不到）——這才閉環。各生態系：
- **Maven**：`settings.xml` 加 `<mirror><mirrorOf>*</mirrorOf><url>feed/maven/v1</url></mirror>` + server 認證
- **npm**：`.npmrc` `registry=feed/npm/registry/` + auth token
- **NuGet**：`NuGet.config` `<packageSources>` 只留 feed

驗證：build 一個依賴**沒**在 feed 的版本 → 應失敗（證明擋住未核可來源）。

---

## See Also
- [[dep-policy-gate-concepts]] — 白名單 gate（feed-sync 的上游清單來源）
- [[azure-devops-port]] — 無 Nexus → Azure Artifacts 的取代脈絡
- [[file-artifact-delivery]] — 產物簽章/部署（feed 也放可部署產物）
- [[ado-self-hosted-agent]] — agent 需 mvn（feed-sync 解析/部署用）
