# supply-chain-demo（GitHub 版）

軟體供應鏈安全黃金管線 — GitHub Actions 版，移植自 GitLab 版。
三個元件、三個生態系，套上一條「安全預設」的 CI/CD：

| 元件 | 生態系 | 說明 |
|---|---|---|
| `backend/` | Maven (Java 21 / Open Liberty) | REST `/api/products` |
| `frontend/` | npm (Vue 3 + Vite) | SPA，反向代理 `/api` |
| `dotnet/` | NuGet (.NET 8 minimal API) | REST `/api/products`、`/health` |

開放標準件（Syft/Trivy/Semgrep/Gitleaks/cosign/OSV、NIST SSDF/SLSA/CycloneDX/Sigstore），
平台無關；本 repo 是 GitHub-native 落地版。

## 管線（`.github/workflows/supply-chain.yml`）

PR / push 觸發，jobs：

| Job | 工具 | 做什麼 | required? |
|---|---|---|---|
| `sast` | Semgrep | 原始碼靜態分析，ERROR → fail（SARIF 上 code scanning）| ✅ |
| `secrets` | Gitleaks | 掃密鑰外洩 | ✅ |
| `dependency-review` | GitHub 原生 | PR 擋新引入的漏洞/壞 license 依賴（含 Maven/npm/NuGet），會在 PR 留摘要 | |
| `dep-policy-gate` | `dep-policy-check.sh` | **依賴白名單**：宣告依賴 ⊆ [`dep-policy`](https://github.com/ryanGTR/dep-policy)（**default-deny**）| ✅ |
| `mend-style-gate` | Trivy + `mend-sim/` | **模擬 Mend**：掃描 + policy（**default-allow**，命中 reject 才擋）| ✅ |
| `build-scan-sign` | Docker→GHCR · Syft · Trivy · cosign | 三元件各自 build→SBOM(CycloneDX)→Trivy 掃描(SARIF)→cosign keyless 簽章+attestation→SLSA build provenance | |

`main` 受 ruleset 保護：四個 required check（`sast`/`secrets`/`dep-policy-gate`/`mend-style-gate`）
任一紅就鎖 merge；PR 需 1 核可 + CODEOWNERS。

## 兩種依賴治理並存（核心教學點）

| | `dep-policy-gate` | `mend-style-gate` |
|---|---|---|
| 哲學 | default-deny 顯式白名單 | default-allow 政策掃描（模擬 Mend）|
| 判官 | 手刻 `approved.yaml` | 漏洞 DB + `mend-sim/mend-policy.yaml` |
| 同一顆 log4j 為何擋 | 沒被核可 | 有 CVE |

## 文件

- [docs/dep-policy-gate-concepts.md](docs/dep-policy-gate-concepts.md) — 白名單 gate 原理/盲點/落地、defense in depth（L1~L4）
- [docs/mend-style-vs-allowlist.md](docs/mend-style-vs-allowlist.md) — 兩種治理哲學對照、Mend 模擬細節
- [docs/ecosystem-cases.md](docs/ecosystem-cases.md) — Maven/npm/NuGet 過同兩條 gate 的 worked example
- [docs/github-port-guide.md](docs/github-port-guide.md) — 設定/介紹/demo/排錯指南

## 本機跑兩條 gate

```bash
# default-deny 白名單（需 dep-policy repo 在 ../dep-policy）
POLICY_DIR=../dep-policy ./scripts/dep-policy-check.sh backend   # 或 frontend / nuget

# default-allow 政策掃描（需 docker[trivy] + python3+pyyaml）
./scripts/mend-style-scan.sh all                                 # backend+frontend+dotnet
```
