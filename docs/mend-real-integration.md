---
title: 真 Mend 整合（Azure DevOps）— 設定、踩雷、inventory、staleness 發現
type: howto + reference
created: 2026-06-08
updated: 2026-06-08
tags: [supply-chain, mend, sca, azure-devops, inventory, library-staleness, waiver]
sources:
  - azure-pipelines.yml（ADO ryan101chen/supply-chain-demo）— job mend_real_gate
---

# 真 Mend 整合（Azure DevOps）

> 公司用 Mend。Mend SaaS（`saas.whitesourcesoftware.com`）能從外部連到後，把 ADO pipeline
> 從「開源模擬」升級成**接真 Mend**（`mend-real-gate`），與 `mend-style-gate`（模擬）並存對照。
> 概念對照見 [[mend-style-vs-allowlist]]；ADO 落地見 [[azure-devops-port]]。

---

## 1. 怎麼接的

ADO pipeline 新增 `mend-real-gate` job：
```
裝 Mend CLI(26.5) → mend dep --fail-policy 掃 backend/frontend/dotnet → 上傳 SaaS → 套 org policy
```
- 認證走 pipeline **secret 變數**：`MEND_URL` / `MEND_EMAIL` / `MEND_USER_KEY`（後者 secret）。由 Ryan 自己
  `az pipelines variable create` 設，不經過第三方。
- `MEND_URL = https://saas.whitesourcesoftware.com`（Mend 經典 SaaS US 區）。
- 初次接入設 `continueOnError: true`（advisory，先不擋 PR）；清乾淨後再轉 blocking。

## 2. 踩雷：Mend 的 Maven resolver 需要 host `mvn`

backend 首掃失敗：`failed to detect global Maven and/or wrapper`——Mend 的 Maven 解析會在 agent 上跑
`mvn --version`，但自架 agent（Arch）原本沒裝 Maven（一路用 docker）。
**解法**：agent 機器 `pacman -S maven jdk21-openjdk`（常駐）→ backend 解析成功、0 漏洞 0 違規。
> npm（package-lock）、NuGet（packages.lock.json）Mend 直接讀 lockfile，不需額外工具。

## 3. Mend = 依賴清單（inventory of record），且 pipeline 已自動維護

- `mend dep` 每次跑 = **把專案依賴樹上傳 Mend SaaS**，那邊長期保存 = inventory。
- ADO pipeline `trigger: main` → 每次 push/merge 到 main 自動跑 → main 的 inventory 自動更新。
- ⭐ **Mend SaaS 會 server 端持續重評**已上傳的 inventory（新 CVE / policy 變更自動回頭標）——
  **不需排程重跑 pipeline** 來保持漏洞新鮮度；pipeline 只要在「依賴變動時」重新上傳。
- **待優化**：目前 `mend dep` 未給專案命名，三元件 inventory 可能混亂。應加
  `--scope "supply-chain-demo//<backend|frontend|dotnet>"` 讓 Mend console 一個 product 下三個 project，
  清單才 organized、歷史可追。建議：main 掃描=always 上傳(inventory of record)，PR 掃描=`--fail-policy`(gate)。

## 4. 發現：staleness 違規「可修 vs 不可修」

frontend 首掃 **12 筆 Library Staleness** 違規（0 漏洞）。處理後 **12 → 1**：

| 類型 | 例子 | 處理 |
|---|---|---|
| **可修**（自己引入）| `axios` 整棵子樹（form-data/asynckit/es-* 等 11 筆）| App.vue 只用一個 GET → 改原生 `fetch`、移除 axios，子樹消失 |
| **不可修**（框架自帶）| `estree-walker-2.0.2`（`vue→compiler-sfc→compiler-core` 釘死）| 程式動不了 → **開 Mend waiver** 或等 vue 升 |

**教訓**：staleness 一部分用「更新/移除」解，一部分本質要「waiver」——這是真實治理常態，不是 bug。
要 `mend-real-gate` 全綠，最後那顆 `estree-walker` 需在 Mend console 開 waiver（security team 動作）。

## 5. 去重結論（真 Mend 進來後）

- `mend-real-gate`（真 Mend）= 主力政策引擎（CVE/license/staleness + inventory），公司標準。
- `dep-policy-gate`（白名單，default-deny）= 互補的「准入身份」模型，**不**需要也加 Mend。
- `dep-policy` 審核（OSV+cooldown）= 白名單准入的輕量單座標把關，**保留**；**不**加 Mend（Mend 掃專案不掃單座標）。
- app 層 **OSV 不需要**（Mend 自有 DB 涵蓋 CVE）；dep-policy 審核層 **OSV 保留**（免費、單座標 CVE 訊號）。
- `mend-style-gate`（Trivy 模擬）真 Mend 進來後覆蓋上**變冗餘**，只剩教學/對照價值。

## 6. 未決項（open）

- [ ] **PR #4（移除 axios→fetch）** 開在 ADO，未 land；是真實好改動（清 11 筆違規），待決定是否併入（且是否同步回 GitHub SoT）。
- [ ] `mend-real-gate` 升級：加 `--scope` 專案命名 + main(inventory)/PR(`--fail-policy`) 分流。
- [ ] `estree-walker` 在 Mend 開 waiver → 才能讓 frontend 全綠 → 之後可把 mend-real-gate 轉 blocking。
- [ ] 真 Mend 是否也接到 **GitHub** 版（目前只在 ADO）。

## See Also
- [[mend-style-vs-allowlist]] · [[azure-devops-port]] · [[ecosystem-cases]] · [[dep-policy-gate-concepts]]
