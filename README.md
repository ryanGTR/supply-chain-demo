# supply-chain-demo（GitHub 版）

軟體供應鏈安全黃金管線 — GitHub Actions 版，移植自 GitLab 版。
Java 21 / Open Liberty 後端 + Vue 3 前端，套上一條「安全預設」的 CI/CD。

## 管線（`.github/workflows/supply-chain.yml`）

| 階段 | 工具 | 做什麼 |
|---|---|---|
| SAST | Semgrep | 原始碼靜態分析，ERROR → fail |
| Secret scan | Gitleaks | 掃密鑰外洩 |
| Build | Docker → GHCR | 建 image 推 GitHub Container Registry |
| SBOM | Syft（CycloneDX） | 產軟體物料清單 |
| Scan | Trivy | image CVE 掃描 |
| 簽章 + 來源證明 | cosign（keyless / OIDC） | 簽 image + 綁 SBOM attestation |

> 規劃中：SLSA L3 provenance（slsa-github-generator）、SARIF 上 code scanning、
> 依賴白名單審核（獨立 repo [`dep-policy`](https://github.com/ryanGTR/dep-policy)）、
> 稽核 / 治理儀表板（GitHub Pages）。

開放標準件（Syft/Trivy/Semgrep/Gitleaks/cosign/OSV、NIST SSDF/SLSA/CycloneDX/Sigstore），
平台無關；本 repo 是 GitHub-native 落地版。

## 文件

- [docs/github-port-guide.md](docs/github-port-guide.md) — 設定/介紹/demo/排錯完整指南
