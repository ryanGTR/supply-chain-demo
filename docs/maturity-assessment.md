---
title: 軟體供應鏈機制成熟度評估（2026-06 現況）
type: assessment
created: 2026-06-08
updated: 2026-06-08
tags: [supply-chain, maturity, assessment, mend, azure-devops, governance]
note: |
  涵蓋 GitHub + Azure DevOps 兩平台、真 Mend 整合、Azure Artifacts 規劃後的整體成熟度。
  不美化。刻度：L0無 / L1臨時 / L2有規劃 / L3已定義可示範 / L4已強制涵蓋 / L5持續優化。
  取代 supply-chain-demo(GitLab 版) 的舊 assessment.md（那份是早期 demo 階段）。
---

# 軟體供應鏈機制成熟度評估（2026-06 現況）

## 0. 結論

- **機制層**：成熟度不錯——接近 **L3（已定義+可示範）**，build/簽章那段達 **L4**。
- **端到端閉環 + 制度層**：還沒到位，整體約 **L2–3**。
- **最大價值**：已從「純 demo」落到「真實公司 stack」——Azure DevOps + 真 Mend(org=Bank of Taiwan)
  + Azure Artifacts(規劃) + Azure Boards(可見性)。比純展示前進一大步。
- **一句話**：能做、可演、且開始貼合真實環境；但「**核可 → 入庫 → 部署驗證**」這條鏈還有缺口，
  且尚未「成為制度」（無 mandate / 負責人 / 真實系統涵蓋）。

---

## 1. 逐環成熟度

| 環節 | 等級 | 說明 |
|---|---|---|
| Build / 簽章 / SLSA（SAST·Secret·SBOM·Scan·cosign·provenance）| **L4 機制** | 兩平台綠；GitHub 達 SLSA Build L3、keyless+Rekor |
| 依賴身份白名單（`dep-policy-gate`）| **L3–4** | 已 required、跨三生態系(Maven/npm/NuGet)、跨兩平台 |
| 依賴政策/漏洞（**真 Mend**）| 機制 **L3** / 強制 **L2** | 接通公司引擎，但目前 advisory 不擋、只在 ADO、waiver 待處理 |
| 入庫審核（加白名單）| **L3** | GitHub 完整(OSV+cooldown+CODEOWNERS)；ADO 正改用 Mend 判(進行中) |
| **元件庫 / quarantine**（Azure Artifacts feed + feed-sync）| **L1** ⚠️ | 只有設計、還沒建 ← **最大缺口（閉環沒接）** |
| **部署 / runtime 驗證**（擋未簽/未核可上線）| **L0–1** ⚠️ | 沒做（原 backlog T1）|
| 可見性 / 報告（Boards / Mend / SBOM 分發）| **L2** | Mend 有但 seat 不夠；Boards/feed 可見都還在設計 |
| SBOM | **L3** | Syft 產 + cosign attest(GitHub)、Mend inventory；全員可見分發未接 |

---

## 2. 制度層（治理體系）

**約 L1–2**，與早期評估一樣，是最大空洞：
- 無成文「全行安全交付標準」+ 管理層 mandate
- 無 RACI / 指派到真人團隊
- 例外/waiver 流程未成文（Mend 有 waiver 機制，但無「誰批/時限/台帳」）
- **覆蓋率仍是 demo repo（非真實系統）= L0–1** ← 制度最大空洞

> 但：已使用真實平台(ADO)、真實政策引擎(Mend)、真實 org(Bank of Taiwan)、並開始處理真實組織
> 約束（Mend seat 不足 → 用 Boards 補可見性；無 Nexus → 用 Artifacts）——grounding 比純 demo 強很多。

---

## 3. 最能推進成熟度的下一步（高槓桿）

1. **接 feed-sync（核可 → Azure Artifacts）** → 閉環從「審核」延到「入庫」，是 L2→L3 的關鍵一環。
   見 [[mend-real-integration]] 與待辦。
2. **Mend 轉 blocking + 接到全平台 + 處理 waiver**（estree-walker）→ 政策從 advisory 變強制（L2→L4）。
3. **部署驗證（L4）**：上線前驗 cosign 簽章 + provenance → 補「擋得住」那一段。
4. **制度骨架**：政策一頁 + 指派負責人(RACI) + 例外流程 + **挑一個真實系統正式納管**（覆蓋率 0→1）。

---

## 4. 真實環境對齊（這次的進展）

| 面向 | 早期 demo | 現況 |
|---|---|---|
| CI 平台 | GitLab/GitHub 示範 | + **Azure DevOps**（公司平台，自架 agent）|
| 政策引擎 | 模擬(Trivy)/白名單 | + **真 Mend**（公司引擎，org=Bank of Taiwan）|
| 元件庫 | Nexus(文件提及) | **Azure Artifacts**（公司實況，無 Nexus）|
| 風險可見性 | 儀表板/Pages | + **Azure Boards**（補 Mend seat 不足）|

---

## See Also
- [[dep-policy-gate-concepts]] — 白名單 gate 原理 / defense in depth
- [[mend-style-vs-allowlist]] — 兩種治理哲學
- [[mend-real-integration]] — 真 Mend on ADO（inventory / staleness / 待辦）
- [[azure-devops-port]] — ADO 落地
- [[ecosystem-cases]] — Maven/npm/NuGet
- supply-chain-demo(GitLab)/docs/assessment.md — 早期評估（歷史）
