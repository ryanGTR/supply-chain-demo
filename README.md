# supply-chain-demo

軟體供應鏈安全治理 demo。從一條「安全預設」CI/CD 出發，演進成**雙平台**實作：

- **GitHub 版**（本 repo / GitHub Actions）— 教學/可攜版，用**開源工具模擬** Mend。
- **Azure DevOps 版**（公司落地）— 接**真 Mend**、Azure Boards、Azure Artifacts curated feed，文件化於 `docs/`。

三個元件、三個生態系：

| 元件 | 生態系 | 說明 |
|---|---|---|
| `backend/` | Maven (Java 21 / Open Liberty) | REST `/api/products` |
| `frontend/` | npm (Vue 3 + Vite) | SPA，反向代理 `/api` |
| `dotnet/` | NuGet (.NET 8 minimal API) | REST `/api/products`、`/health` |

開放標準件（Syft/Trivy/Semgrep/Gitleaks/cosign/OSV · NIST SSDF/SLSA/CycloneDX/Sigstore）。

---

## GitHub 管線（`.github/workflows/supply-chain.yml`）

PR / push 觸發：

| Job | 工具 | 做什麼 | required? |
|---|---|---|---|
| `sast` | Semgrep | 原始碼靜態分析，ERROR → fail（SARIF 上 code scanning）| ✅ |
| `secrets` | Gitleaks | 掃密鑰外洩 | ✅ |
| `dependency-review` | GitHub 原生 | PR 擋新引入的漏洞/壞 license 依賴（Maven/npm/NuGet）| |
| `dep-policy-gate` | `dep-policy-check.sh` | **依賴白名單**：宣告依賴 ⊆ [`dep-policy`](https://github.com/ryanGTR/dep-policy)（**default-deny**）| ✅ |
| `mend-style-gate` | Trivy + `mend-sim/` | **模擬 Mend**：掃描 + policy（**default-allow**）| ✅ |
| `build-scan-sign` | Docker→GHCR · Syft · Trivy · cosign | build→SBOM(CycloneDX)→Trivy(SARIF)→cosign keyless 簽章+attestation→SLSA provenance | |

`main` 受 ruleset 保護：4 個 required check 任一紅就鎖 merge；PR 需 1 核可 + CODEOWNERS。

### 兩種依賴治理並存（核心教學點）

| | `dep-policy-gate` | `mend-style-gate` |
|---|---|---|
| 哲學 | default-deny 顯式白名單 | default-allow 政策掃描（模擬 Mend）|
| 判官 | 手刻 `approved.yaml` | 漏洞 DB + `mend-sim/mend-policy.yaml` |
| 同一顆 log4j 為何擋 | 沒被核可 | 有 CVE |

---

## Azure DevOps 落地版（公司真實實作）

公司用 ADO + 真 Mend、無 Nexus（改 Azure Artifacts）、Mend seat 有限（用 Boards）。差異與實作：

| 環節 | GitHub 版 | ADO 落地版 |
|---|---|---|
| 依賴政策判官 | mend-style-gate（模擬）| **真 Mend SCA**（公司 policy）→ [mend-real-integration](docs/mend-real-integration.md) |
| 風險可見性 | — | **Mend findings → Azure Boards Issue**（無 seat 者也看得到）→ [mend-to-boards](docs/mend-to-boards.md) |
| 元件來源治理 | — | **Azure Artifacts curated feed（upstream OFF）+ feed-sync + L1 來源強制** → [feed-sync](docs/feed-sync.md) |
| dep-policy 審核 | OSV | **改用真 Mend 判**（與 app gate 一致）|
| 跑 CI | hosted | **自架 agent**（新 org 無免費平行度）→ [ado-self-hosted-agent](docs/ado-self-hosted-agent.md) |
| 產物 | container image | **檔案型 jar/war/.NET zip**（公司無 image）→ [file-artifact-delivery](docs/file-artifact-delivery.md) |

**治理閉環現況**：審核(Mend) → inventory(Mend 三生態) → 可見性(Boards 開/關) → 核可 → feed-sync(入庫) → L1(只從 feed 拉、擋未核可)。成熟度與缺口見 [maturity-assessment](docs/maturity-assessment.md)。

---

## 文件（`docs/`）

**概念/原理**
- [dep-policy-gate-concepts.md](docs/dep-policy-gate-concepts.md) — 白名單 gate 原理/盲點、defense in depth（L1~L4）
- [mend-style-vs-allowlist.md](docs/mend-style-vs-allowlist.md) — 兩種治理哲學對照、Mend 模擬細節
- [ecosystem-cases.md](docs/ecosystem-cases.md) — Maven/npm/NuGet 過兩條 gate 的 worked example
- [provided-scope-platform-governance.md](docs/provided-scope-platform-governance.md) — provided scope 治理 + runtime 平台治理軌

**GitHub 落地**
- [github-port-guide.md](docs/github-port-guide.md) — 設定/介紹/demo/排錯

**Azure DevOps 落地（公司真實版）**
- [azure-devops-port.md](docs/azure-devops-port.md) — ADO 移植（平行度/registry 限制、無 Nexus）
- [ado-self-hosted-agent.md](docs/ado-self-hosted-agent.md) — 自架 agent 安裝/啟動 runbook
- [mend-real-integration.md](docs/mend-real-integration.md) — 真 Mend CLI SCA 整合
- [mend-to-boards.md](docs/mend-to-boards.md) — Mend findings → Azure Boards（可重現 + 自動關閉）
- [feed-sync.md](docs/feed-sync.md) — curated feed + feed-sync + L1 來源強制（9 踩雷可重現）
- [file-artifact-delivery.md](docs/file-artifact-delivery.md) — 檔案型產物簽章/部署驗證

**評估**
- [maturity-assessment.md](docs/maturity-assessment.md) — 機制成熟度、閉環缺口盤點

---

## 本機跑兩條 gate

```bash
# default-deny 白名單（需 dep-policy repo 在 ../dep-policy）
POLICY_DIR=../dep-policy ./scripts/dep-policy-check.sh backend   # 或 frontend / nuget

# default-allow 政策掃描（需 docker[trivy] + python3+pyyaml）
./scripts/mend-style-scan.sh all                                 # backend+frontend+dotnet
```

> ADO 落地版的腳本（真 Mend gate、feed-sync、Boards、L1 驗證）在 Azure DevOps 的同名 repo，
> 各篇 docs 附**可重現 runbook**（含全文腳本 + 踩雷表），可在公司真 ADO 重建。
