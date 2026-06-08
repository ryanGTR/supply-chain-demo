---
title: Azure DevOps 落地 — 治理閘門 MVP（自架 agent）
type: howto + reference
created: 2026-06-08
updated: 2026-06-08
tags: [supply-chain, azure-devops, azure-pipelines, self-hosted-agent, dep-policy, mend, portability]
sources:
  - azure-pipelines.yml（在 ADO repo ryan101chen/supply-chain-demo）
  - scripts/dep-policy-check.sh / scripts/mend-style-scan.sh
---

# Azure DevOps 落地 — 治理閘門 MVP（自架 agent）

> 把同一套供應鏈依賴治理（白名單 + 模擬 Mend）落地到 **Azure DevOps**，對齊公司的
> ADO + Mend 環境。治理骨架綁開放標準，換的只是平台膠水（GitHub Actions → Azure Pipelines）。
> 概念見 [[dep-policy-gate-concepts]]、[[mend-style-vs-allowlist]]；GitHub 版見 [[github-port-guide]]。

座標：org `ryan101chen` / project `supply-chain-demo`（CLI：`az devops`，PAT 認證）。

---

## 0. 成果

| 項目 | 狀態 |
|---|---|
| repos | `supply-chain-demo`(app) + `dep-policy`，由 GitHub `az repos import` 匯入 |
| pipeline | `azure-pipelines.yml`：SAST · Secret · dep-policy-gate · mend-style-gate · build(不 push) |
| run | 全綠（7 jobs：4 gate + 3 build）|
| branch policy | build validation（blocking）on main → PR 必過才能 merge |
| agent | 自架 `arch-azp`（Default pool）|

範圍是**治理閘門 MVP**：不含 image push（ADO 無原生 registry）。

---

## 1. 為什麼要自架 agent

新 ADO org **預設無免費 Microsoft-hosted 平行度**（`resourceusage` 查到 `resourceLimit: null`），
hosted-agent 的 job 會永遠卡 `notStarted`。要嘛填表申請（aka.ms/azpipelines-parallelism-request，
約 1~3 工作天），要嘛**自架 agent**（立即可跑）。本 demo 走自架。

設定（在自己機器，PAT 不經過第三方）：
```bash
# 1) 開 PAT：Agent Pools (Read & manage)
# 2) 下載官方 agent → 解壓 ~/azp-agent
# 3) 設定（互動或 --unattended）
~/azp-agent/config.sh --unattended --url https://dev.azure.com/ryan101chen \
  --auth pat --token <PAT> --pool Default --agent arch-azp --acceptTeeEula --replace
# 4) 跑（背景 / 或裝 systemd 服務）
nohup ~/azp-agent/run.sh &          # 臨時
# sudo ./svc.sh install $USER && sudo ./svc.sh start   # 常駐
```
pipeline 的 `pool` 設 `name: Default`。**單 agent = job 序列跑**（免費 1 並行槽），慢但會完成。

---

## 2. pipeline 結構（`azure-pipelines.yml`）

```
trigger/pr: [main]
resources.repositories: deppolicy (同專案 dep-policy repo)
pool: { name: Default }     # 自架
jobs:
  sast            Semgrep（拉 image 重試 → 掃 → SARIF error-level gate）
  secrets         Gitleaks（命中即 fail）
  dep_policy_gate checkout self + deppolicy → dep-policy-check.sh backend/frontend/nuget
  mend_style_gate Trivy + mend_policy_eval.py（backend+frontend+dotnet）
  build           dependsOn 上面四個；matrix backend/frontend/dotnet，docker build（不 push）
```
`scripts/*` 三生態系腳本與 GitHub 版**完全共用**，只是被不同 CI 呼叫。

---

## 3. 踩雷對照（實戰記錄）

| 症狀 | 原因 | 解法 |
|---|---|---|
| 匯入後 repo 少檔/看似舊 | `az repos import` 把 **default branch 設成某 dependabot 分支** | `az repos update --default-branch main` |
| job 永遠 `notStarted` | 新 org 無 hosted 平行度 | 自架 agent（§1）|
| run 卡 `Checkpoint inProgress` | 首次用受保護資源（agent pool / repo）需授權 | 到 **run 頁面按 Permit**（一次性；之後記住）|
| dep-policy 用 `git clone`+System.AccessToken → `TF401019` | build 身分對「別的 repo」無權 | 改 **原生 `resources.repositories` + `checkout`**（授權機制正確）|
| `az devops invoke` 授權 API 報 `could not convert string to float` | az 對 `X.Y-preview.N` api-version 解析 bug | pipelinePermissions 類授權**改走 UI**（Permit）|

---

## 4. GitHub ↔ Azure DevOps 對照

| GitHub（現有）| Azure DevOps（這裡）|
|---|---|
| GitHub Actions / `.github/workflows/*` | Azure Pipelines / `azure-pipelines.yml` |
| job `needs:` | job `dependsOn:` |
| `actions/checkout` repository | `resources.repositories` + `checkout:` |
| required status check（ruleset）| **Branch policy → Build validation** |
| CODEOWNERS 強制核可 | Branch policy → **Automatically included reviewers**（依路徑）|
| GHCR 推 image + cosign keyless | **無原生 registry** → 需 ACR + `az login`（本 MVP 不 push）|
| `dependency-review`（原生）| **GHAzDO Dependency scanning**（付費）或靠 mend-style 的 Trivy |
| GitHub-hosted runner（免費並行）| 新 org 需申請並行度，或**自架 agent** |

---

## 5. 已知限制

- **build 不 push**：ADO 無原生 container registry；完整 build→簽章需接 **ACR** + Azure 訂閱（`az login`）。
- **單 agent 序列跑**：要並行加 agent 或申請 hosted 平行度。
- **無原生 dependency-review**：對等是 GHAzDO（付費）；本 demo 由 mend-style-gate（Trivy）覆蓋漏洞掃描。
- 自架 agent 用 `nohup` 跑的話**重開機會停**；要常駐裝 systemd 服務。

## See Also
- [[dep-policy-gate-concepts]] · [[mend-style-vs-allowlist]] · [[ecosystem-cases]] · [[github-port-guide]]
