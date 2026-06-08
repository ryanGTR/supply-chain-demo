---
title: Azure DevOps 自架 Agent — 安裝 / 啟動 / 常駐 runbook
type: runbook
created: 2026-06-09
updated: 2026-06-09
tags: [azure-devops, self-hosted-agent, runbook, ops]
sources:
  - 本機 agent：~/azp-agent（pool=Default, name=arch-azp, org=dev.azure.com/ryan101chen）
---

# Azure DevOps 自架 Agent — runbook

> **為何自架**：新 ADO org 預設無免費 Microsoft-hosted 平行度（`resourceLimit:null`），hosted-agent
> 的 job 會永遠卡 `notStarted`。自架 agent 可立即跑。見 [[azure-devops-port]]。
> 單一 agent = job 序列跑（免費 1 並行槽），慢但會完成。

---

## 0. 前置：agent 主機要裝的工具

pipeline 在 agent 上實際執行，所以**解析/掃描用的工具要裝在 agent 主機**（不是只在 image 裡）。
本機（Arch）已裝：
```bash
sudo pacman -S --noconfirm maven jdk21-openjdk nodejs npm dotnet-sdk
# maven+jdk → Mend/dep-policy 解析 Maven；node/npm → npm；dotnet → NuGet
```
另外 **Mend CLI 已快取**避免每次下載逾時：
```bash
mkdir -p ~/.mendcli
curl -fsSL https://downloads.mend.io/cli/linux_amd64/mend -o ~/.mendcli/mend && chmod +x ~/.mendcli/mend
```

---

## 1. 安裝 agent

```bash
mkdir -p ~/azp-agent && cd ~/azp-agent
# 下載連結可由 API 取最新；本次用 4.273.0 linux-x64
curl -sL https://download.agent.dev.azure.com/agent/4.273.0/vsts-agent-linux-x64-4.273.0.tar.gz -o agent.tar.gz
tar xzf agent.tar.gz && rm agent.tar.gz   # 解出 config.sh / run.sh / svc.sh
```

## 2. 設定（需 PAT，私鑰不經第三方）

PAT scope = **Agent Pools (Read & manage)**（建在 dev.azure.com/<org>/_usersSettings/tokens）。
```bash
cd ~/azp-agent
./config.sh --unattended \
  --url https://dev.azure.com/ryan101chen \
  --auth pat --token <PAT> \
  --pool Default --agent arch-azp --acceptTeeEula --replace
# 成功會看到 Settings Saved.（憑證存進 .agent/.credentials，之後 run 不需再給 PAT）
```
> ⚠️ PAT 會留 shell 歷史，跑完 `history -d` 清或設短到期。

## 3. 啟動

**臨時（前景 / 背景）**——重開機會停：
```bash
./run.sh                      # 前景
nohup ./run.sh > ~/azp-agent/agent.log 2>&1 &   # 背景（本次用這個）
```

**常駐（systemd 服務，推薦正式用）**——開機自動跑：
```bash
sudo ./svc.sh install $USER   # 裝成 systemd unit（寫 /etc，需密碼）
sudo ./svc.sh start
sudo ./svc.sh status          # 看狀態
# 停 / 移除：sudo ./svc.sh stop ; sudo ./svc.sh uninstall
```

## 4. 驗證上線

```bash
# agent log 出現 "Listening for Jobs" 即 online
tail -f ~/azp-agent/agent.log
# 或從 ADO 端查：
az pipelines agent list --pool-id 1 --query "[].{name:name,status:status}" -o table
```

## 5. 首次用 pool 的授權（一次性）

每條 pipeline **第一次用 Default pool** 會卡 `Checkpoint`（受保護資源授權）。到該 run 頁面
按 **View → Permit** 授權一次即可（之後同 pipeline 不用再點）。

## 6. 起停 / 常見問題

| 狀況 | 處理 |
|---|---|
| 停掉背景 agent | `pkill -f 'azp-agent/.*run.sh'` 或關該 process |
| 重開機後沒了 | 用 §3 的 systemd 服務常駐 |
| Mend/maven 解析失敗 | agent 主機缺工具 → §0 裝齊（PATH 要含）|
| job 一直 notStarted 且非 checkpoint | 無 agent online 或無並行槽 |

## See Also
- [[azure-devops-port]] — ADO 落地（平行度/registry 限制）
- [[mend-real-integration]] — Mend（需 agent 上 mvn/node/dotnet）
