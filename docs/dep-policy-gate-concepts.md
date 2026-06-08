---
title: 依賴白名單 gate — 原理、盲點與落地
type: concept + howto
created: 2026-06-08
updated: 2026-06-08
tags: [supply-chain, policy-as-code, dep-policy, github-actions, defense-in-depth, nexus]
sources:
  - scripts/dep-policy-check.sh
  - scripts/binary-commit-check.sh
  - .github/workflows/supply-chain.yml
  - dep-policy repo (ryanGTR/dep-policy)：maven-approved.yaml / npm-approved.yaml / .github/workflows/review.yml
---

# 依賴白名單 gate — 原理、盲點與落地

> 本篇整理 2026-06-08 的一串討論：`maven-approved.yaml` 到底怎麼被用、它和 Nexus 的關係、
> 哪些手法繞得過、以及我們怎麼把這條 gate 從「只能本機跑」落地成「main 上不可繞的 CI 守門」。

---

## 0. 一句話總結

白名單（`dep-policy/{maven,npm}-approved.yaml`）是 **policy as code**：一份被程式讀進去做
pass/fail 決策的資料檔。它**只認依賴的「身份（座標）」、不管來源、不驗內容**，所以它本身擋不了
所有東西——必須是「**讀它的閘門 + 讓閘門不可繞的 branch protection**」在 enforce，且要靠
**多層防線（defense in depth）**互補盲點。

> **Java 類比**：`approved.yaml` 就像 `checkstyle.xml` 或 `maven-enforcer` 的
> `<bannedDependencies>` 規則檔。規則檔本身只是檔案，是「build 時跑它的 plugin + CI 強制」
> 讓它有效。沒人跑它，它就只是一份文件。

---

## 1. 三個檔案的關係（方向別搞反）

| 檔案 | 位置 | 角色 | Java 心智模型 |
|---|---|---|---|
| `pom.xml` / `package.json` | `app/backend` `app/frontend` | **你宣告**要用哪些套件 | 你寫的 `import` + build 設定 |
| `maven-approved.yaml` / `npm-approved.yaml` | `dep-policy/` | security team **核可**哪些可用 | 公司的「允許 import 清單」 |
| `dep-policy-check.sh` | `app/scripts/` | build 前比對：宣告依賴 ⊆ 白名單？不在就擋 | checkstyle/enforcer gate |

**關鍵**：白名單是 pom 的**產物**（由 `dep-policy` 的 seed 腳本從現有 pom 種子產生），不是來源。
不是「從白名單產生 pom」，是反過來。

---

## 2. 白名單到底「被怎麼用」？（不是只有審核紀錄）

它**同時是兩種角色**：

### 2a. 執行用（enforcement）— 會擋 build
`scripts/dep-policy-check.sh` 的核心邏輯：

```bash
# 1) 從 yaml 抽核可清單              （scripts/dep-policy-check.sh:54）
grep '- coord:' maven-approved.yaml | sed ... | sort -u > approved.txt
# 2) 抽 pom 解析後的實際依賴(含 transitive)（:74-77, npm 版 :83-86）
mvn -B dependency:list | awk -F: '{print $1":"$2":"$4}' | sort -u > actual.txt
# 3) 集合相減：實際有、白名單沒有的    （:98）
UNAPPROVED=$(comm -23 actual.txt approved.txt)
# 4) 有未核可 → 擋                    （:100-104 PASS / :118 exit 1）
[ -z "$UNAPPROVED" ] && exit 0 || exit 1
```
這支腳本被接進 CI（見 §5），`exit 1` 會讓 pipeline job 失敗。

### 2b. 治理「改清單本身」— dep-policy repo 的 `review.yml`
想加一筆 coord = 開 PR 改 yaml → CI 自動跑 **OSV CVE 查 + cooldown 30 天 gate** →
**CODEOWNERS 強制 @security-team 核可**才能 merge。改清單本身也被閘門管著。

### 2c. 紀錄/報告用（record）
每筆有 `approved_at` / `approved_by`，加上 git 歷史 + PR + CODEOWNERS 軌跡 = 誰在何時核可了什麼；
`recheck-approved.sh`（重掃已核可 coord 找新爆 CVE）、`governance-dashboard.py`（治理儀表板）讀它。

---

## 3. 它「只認身份」——盲點與互補控制

`dep-policy-check.sh` 是 **source-blind**：不管 jar 從 Central / Nexus / 本機 `~/.m2` / 手動丟，
只比對座標 `groupId:artifactId:version`。

| 它**檢查**的 | 它**不檢查**的 |
|---|---|
| 用了哪些套件（身份/座標）✅ | jar 從哪個 repo 下載 ❌ |
| 含 transitive 都比對 ✅ | jar 的位元組內容/雜湊 ❌ |
| 該座標有沒被核可 ✅ | 有沒被竄改、簽章真不真 ❌ |

→ **同一座標、jar 被掉包成惡意版**，這條 gate 仍 PASS（它只認名字）。

> **Java 類比**：像 checkstyle 檢查你 `import` 了哪些「類別名」在不在允許清單，
> 但它不驗那個 class 的 bytecode 是不是正版。

### 「自帶 jar」會不會被擋？取決於怎麼帶

| 帶法 | 白名單 gate | 互補控制 | 結果 |
|---|---|---|---|
| commit jar 進 repo（最常見）| 看不到（沒宣告）❌ | `binary-commit-check.sh` 擋 ✅ | **FAIL** |
| 改副檔名 `foo.jpg` 偷渡 jar | 看不到 ❌ | binary-check 用 **magic byte**（`PK..`/`CAFEBABE`）抓 ✅ | **FAIL** |
| `<systemPath>` 指本機 jar（有座標）| 看得到、不在清單 ✅ | — | **FAIL** |
| 裝進 `~/.m2`、座標不在白名單 | 擋 ✅ | — | **FAIL** |
| 座標在白名單、bytes 被掉包 | PASS ❌ | 需 checksum / 簽章 | ⚠️ 漏 |
| fat/shaded jar 內嵌別的 lib | 只看最外層宣告 ❌ | **SBOM(Syft) 掃成品實際內容** 可抓 ✅ | 多半擋到 |
| vendoring：複製 library 原始碼 `.java` | 沒 jar 沒座標 ❌ | SAST + code review + SBOM 部分抓 | ⚠️ 最難擋 |

`binary-commit-check.sh` 的偵測策略：副檔名黑名單（`scripts/binary-commit-check.sh:34-55`）
+ magic-byte（`:58-69`，防改副檔名繞過）+ 大檔警告。

> **一句話**：白名單管「你**說**你用了什麼」，SBOM 掃成品管「你**實際**裝了什麼」，
> binary-check 管「你有沒有偷塞二進位」——三個角度才補得齊。

---

## 4. 防線分層（defense in depth）

| 層 | 在哪擋 | 機制 | 本 demo |
|---|---|---|---|
| L1 開發機 `settings.xml` → 指向 Nexus | 源頭 | Maven mirror | ❌ |
| **L2 Nexus proxy + Firewall** | 抓取下載當下 | Sonatype Nexus Firewall / IQ Server（**獨立 policy 引擎**）/ content selector | ❌（只在 docs 提）|
| **L3 CI gate — 身份** | build/CI | `dep-policy-gate`：`dep-policy-check.sh` vs 白名單（**default-deny** 身份核可）| ✅ |
| **L3 CI gate — 漏洞/授權** | build/CI | `mend-style-gate`：Trivy 掃描 + `mend-policy.yaml`（**default-allow**，模擬 Mend；見 [[mend-style-vs-allowlist]]）| ✅ |
| L4 部署 / admission | 上線前 | cosign verify 簽章 + SLSA provenance | ❌（backlog T1）|

> L3 現有**兩條互補 gate**：身份層（沒核可就擋）+ 漏洞/授權層（有 CVE/壞 license 就擋）。
> 同一顆 log4j：`dep-policy-gate` 因「沒被核可」擋、`mend-style-gate` 因「有 CVE」擋。兩者皆為 main 的 required check。

**白名單 ≠ 交給 Nexus 下載**：Nexus 不讀這份 yaml（它不吃這格式）。要兩邊同一份政策，得把
allow-list **翻譯**成 Nexus 的 IQ policy / content selector——同一規則、兩個引擎各自實作。
這 demo 目前只做了 **L3**。

---

## 5. 落地：把 L3 gate 接進 GitHub pipeline（2026-06-08）

### 改了什麼
- 新增 job `dep-policy-gate`（`.github/workflows/supply-chain.yml`）：
  - checkout `ryanGTR/dep-policy`（public，免 token）到 `.dep-policy`
  - `setup-java` Java 21（runner 預裝 mvn）
  - backend：`USE_HOST_TOOLS=1 POLICY_DIR=.dep-policy ./scripts/dep-policy-check.sh backend`
  - frontend：`./scripts/dep-policy-check.sh frontend`
- `build-scan-sign` 改 `needs: [sast, secrets, dep-policy-gate]` → 未核可依賴連 build/簽章/發佈都擋。

### GitHub Actions 怎麼判讀（你來自 GitLab）

| GitLab | GitHub Actions |
|---|---|
| Pipelines 頁 | repo → **Actions** 分頁 |
| 一條 pipeline | 一個 **workflow run** |
| stage | 無顯式 stage，用 job `needs:` 串相依 |
| job script 失敗 | **step** exit ≠ 0 → job 紅 |
| MR 的 pipeline 狀態 | **PR 底部 Checks** |
| 紅燈擋 merge | **required status checks + branch protection/ruleset** |

SARIF（Semgrep / Gitleaks / Trivy）出現在 **Security 分頁 → Code scanning**，不在 run log。

### 設為不可繞
main 的 ruleset `protect-main`(id 17157658) required status checks =
**`sast` + `secrets` + `dep-policy-gate`**。job 存在 ≠ 擋得住 merge，要設成 required 才會鎖 Merge 鈕。

---

## 6. 現場驗證（live demo 結果）

**PASS（原狀）**：backend 31/31、frontend 126/126 → `exit 0`、Gate PASS。

**FAIL（在 PR 上故意加 `log4j-core:2.14.1`）**：
```
actual: 33 coords        ← 只加 1 顆，卻多 2 顆
approved: 31 coords
未核可的 coords（2）
  - org.apache.logging.log4j:log4j-api:2.14.1   ← transitive 也被抓
  - org.apache.logging.log4j:log4j-core:2.14.1
✗ Gate FAIL — 2 個 coord 不在 allow-list
```
PR 上呈現：`dep-policy-gate` ✗、`build-scan-sign` **SKIPPED**（needs 沒過不跑）、
`mergeStateStatus = BLOCKED`（Merge 鈕鎖死）。

**兩條 check 各因不同理由變紅**（印證 §3 / §4 的「兩個引擎」）：
- `dep-policy-gate` 紅 = log4j **沒被核可**（身份層 / 白名單）
- `dependency-review` 紅 = log4j 2.14.1 **有已知高風險 CVE**（漏洞層 / GitHub 漏洞庫）

---

## 7. Merge 與 governance 取捨

PR #18（接 gate）被 ruleset 擋（需 1 個有寫入權核可，連 `--admin` 都不能繞，因為原本無 bypass actor）
——**這正是治理 PoC 該有的樣子**：規則對 owner 也一視同仁。

決議：**永久加 `RepositoryRole#5`(Repository Admin) 為 bypass actor** → owner 可單人 admin-merge。
- 取捨：方便（單人 repo 不用湊第二人）；代價是 **review 這層對 owner 失效**。
- **required checks 仍對所有人有效，沒被削弱。**
- 日後若有協作者要恢復「連 owner 都被 review」：把 bypass_actors 清空即可。

---

## See Also
- [[github-port-guide]] — GitLab → GitHub 移植步驟與排錯
- [[assessment]]（supply-chain-demo/docs）— 品質與制度成熟度評估；最大缺口 T1 部署驗證(L4) + 制度層
- [[backlog-phased-todo]]（supply-chain-demo/docs）— T1 部署驗證 / T5 KEV·EPSS 風險分級 等觸發式待辦
- [[third-party-supply-chain]]（supply-chain-demo/docs）— 第三方審核與整合（當前焦點）
