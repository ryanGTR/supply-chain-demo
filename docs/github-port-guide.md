---
title: GitHub 版供應鏈安全 — 設定與介紹指南
type: runbook
created: 2026-06-02
updated: 2026-06-02
status: v1.0
note: |
  把 GitLab 版 supply-chain-demo 移植到 GitHub 的成果說明 + 從零重建步驟 + demo 導覽 +
  排錯。核心是開放標準（Syft/Trivy/Semgrep/Gitleaks/cosign/OSV、NIST SSDF/SLSA/CycloneDX/
  Sigstore）；GitHub 換的是平台膠水，並用 GitHub 原生功能把稽核做得更嚴。
---

# GitHub 版供應鏈安全 — 設定與介紹指南

## 0. 一句話

任何 commit / 依賴 / image，從原始碼到發布，全程被掃描、簽章、附來源證明、過政策門檻，
而且**每一步的證據與審核紀錄都留在 GitHub 原生功能裡**（Actions / Security / Packages /
PR / Pages）。

## 1. 線上位置

| 物件 | 連結 |
|---|---|
| App repo | https://github.com/ryanGTR/supply-chain-demo |
| dep-policy repo（套件白名單 + 審核）| https://github.com/ryanGTR/dep-policy |
| 稽核證據索引（Pages）| https://ryangtr.github.io/supply-chain-demo/ |
| 依賴治理儀表板（Pages）| https://ryangtr.github.io/dep-policy/ |
| worked 審核 PR | https://github.com/ryanGTR/dep-policy/pull/1 |

工作目錄：`~/Documents/supply-chain/github/{app,dep-policy}`。
認證：git 走 **SSH**、API 用 **`gh`**。（早期版本曾用 `.secrets/github-pat.env` 內嵌 PAT，**已淘汰**——PAT 易外洩。）

## 2. 管線（`app/.github/workflows/supply-chain.yml`）

`SAST(Semgrep) → Secret(Gitleaks) → Build→GHCR → SBOM(Syft/CycloneDX) → Scan(Trivy) →
cosign keyless 簽章 + SBOM attestation → SLSA Build L3 provenance`
+ PR 時 `dependency-review`（擋新引入的漏洞/壞 license 依賴）
+ SAST/secret/scan 的 SARIF 上 **code scanning**（Security tab）。

`app/.github/workflows/pages.yml` → 稽核證據索引頁。`app/.github/dependabot.yml` → maven/npm/
github-actions/docker 自動更新。

## 3. 套件審核（`dep-policy` repo）

要加套件 = 開 PR 改 `{maven,npm}-approved.yaml`：
1. `review.yml`：lint → OSV CVE 查（貼回 PR）→ cooldown(≥30 天，未過則擋)
2. **CODEOWNERS 強制核可**（ruleset：require code-owner review、禁 bypass）
3. merge → App build 重跑放行
4. `pages.yml` → 治理儀表板（白名單健康度 + 核可後才爆的 CVE）

## 4. GitLab → GitHub 對應

| GitLab 版 | GitHub 版 |
|---|---|
| `.gitlab-ci.yml` / GitLab Runner（rootless podman 一堆雷）| `.github/workflows/*` / GitHub hosted runner |
| image 推 Nexus docker-hosted | 推 **GHCR**（ghcr.io/ryangtr/…）|
| cosign 帶 key 簽 + 最小 SLSA v0.2 | **cosign keyless（OIDC+Rekor）+ SLSA Build L3** |
| DTrack policy gate | Trivy + **Dependabot** + code scanning（原生）|
| MR + protected branch + 權限硬湊核可 | PR + **CODEOWNERS 強制核可（免費）** + ruleset |
| 自建稽核儀表板（DTrack 餵）| app 稽核做成輕量索引頁（原生 Security tab 涵蓋大半）+ dep-policy 治理儀表板 |
| 白名單 monorepo→獨立 GitLab 專案 | 獨立 GitHub repo `dep-policy` |

## 5. 從零重建（已有 GitHub 帳號 + 兩個空 repo）

```bash
# 0) 認證：gh 登入（git 走 SSH；下面 curl API 用 gh 的 token，不落地 PAT）
#    ⚠️ 別再把 PAT 內嵌進 remote URL（會在 git config 明文外洩）。
gh auth login                                    # 選 SSH protocol；或 gh auth status 確認
GITHUB_OWNER=ryanGTR
GITHUB_REPO=supply-chain-demo
A="Authorization: Bearer $(gh auth token)"       # 給下面 curl 用，token 不落地

# 1) App repo：推 app/（含 workflows + dependabot.yml）
cd app && git init -b main && git add -A && git commit -m init
git remote add origin "git@github.com:${GITHUB_OWNER}/${GITHUB_REPO}.git"
git push -u origin main

# 2) 開安全功能（secret scanning push protection + Dependabot 警報/自動修補）
curl -sX PATCH -H "$A" "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO" \
  -d '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'
curl -sX PUT -H "$A" "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/vulnerability-alerts"
curl -sX PUT -H "$A" "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/automated-security-fixes"

# 3) 啟用 Pages（source = Actions）→ 兩個 repo 都做
curl -sX POST -H "$A" "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/pages" -d '{"build_type":"workflow"}'

# 4) dep-policy repo：推 dep-policy/（allow-list + review.yml + pages.yml + CODEOWNERS）
#    同樣開 Pages

# 5) Rulesets（最後做，否則擋直推）：兩 repo 都設
#    PR + require code-owner review + required status checks(sast/secrets) + 禁 bypass/force-push/刪除
#    （POST /repos/.../rulesets，見下方踩雷）
```

> Pages 部署：workflow 用 `actions/upload-pages-artifact` + `actions/deploy-pages`，需要
> `pages: write` + `id-token: write` + `github-pages` environment。

## 6. 怎麼 demo（GitHub-native）

1. **Actions** 頁 → 指 supply-chain run：每步綠（SAST/secret/build/SBOM/scan/sign/SLSA）。
2. **Security tab** → code scanning（SARIF）+ Dependabot 警報 → 「掃描證據是原生的」。
3. **dep-policy PR #1** → CI 自動貼 OSV/cooldown 報告 + PR 卡在 code-owner review →「強制核可」。
4. **Packages（GHCR）** → image 有 cosign 簽章 + SBOM/SLSA attestation（`gh attestation verify oci://…`）。
5. **兩個 Pages 儀表板** → 稽核員入口 + 依賴治理（核可後才爆 CVE）。
6. 想演「防線發動」：開 PR 加一個有 CVE 的套件到 dep-policy → review CI 把 CVE 貼出來。

## 7. 對應 GitHub Well-Architected「managing dependency threats」6 層

| 層 | 我們的落地 |
|---|---|
| 1 關閉 lifecycle scripts | （可補 .npmrc ignore-scripts）|
| 2 隔離環境 | hosted runner（短命、隔離）|
| 3 簽 commit | ruleset 可加 require signed commits |
| 4 Rulesets（PR/status checks/禁 bypass）| ✅ 兩 repo 都設 |
| 5 Trusted publishing / attestation / SLSA L3 | ✅ GHCR + cosign keyless + attest-build-provenance |
| 6 持續監控 | ✅ Dependabot + dependency-review + code scanning + secret push protection |

## 8. 排錯（這次踩過的）

| 症狀 | 解法 |
|---|---|
| `Unable to resolve action trivy-action@0.28.0` | 版本不存在 → `@master`（或查實際 tag）|
| container job 跑不了 `upload-sarif`（node action）| 該 job 改 `runs-on: ubuntu-latest` + `docker run` 跑工具 |
| trivy/syft 拉 GHCR image 認證 | 先 `docker/login-action`，工具用 runner 的 docker config |
| `npm ci` 連 nexus.localhost | package-lock 的 resolved URL 改回 `registry.npmjs.org` |
| pages workflow 沒觸發 | 確認 workflow 在「預設分支」上（別推錯分支）|
| ruleset 擋自己直推 | 設定階段先 `enforcement: disabled`，內容推完再 active |
| 單帳號 PR 無法自批 | 正常；團隊裡換另一個 code-owner 批（demo 展示 blocked 即可）|

## 9. v1 範圍與後續

- v1 = 純 GitHub 原生：不接本機 Nexus/DTrack（image 推 GHCR、SCA 用 OSV/Dependabot）。
- 要接本機 Nexus/DTrack → 架 **self-hosted runner**（連得到本機服務），build 改走 Nexus proxy。
- 後續可加：require signed commits、.npmrc ignore-scripts、KEV/EPSS 風險導向 gate、
  把文件以 PR 方式併進 repo（demonstrate 受治理的變更）。

## See Also

- GitLab 版來源：`~/Documents/supply-chain/gitlab/docs/`（setup-guide / tech-stack / approval-flow-* / compliance-mapping）
- GitHub Well-Architected：managing dependency threats（本指南 §7 對照）
