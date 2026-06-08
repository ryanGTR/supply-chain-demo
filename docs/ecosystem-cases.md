---
title: 多生態系案例 — Maven / npm / NuGet 過同兩條 gate
type: howto + reference
created: 2026-06-08
updated: 2026-06-08
tags: [supply-chain, maven, npm, nuget, dotnet, dep-policy, mend, multi-ecosystem]
sources:
  - backend/pom.xml
  - frontend/package-lock.json
  - dotnet/packages.lock.json
  - scripts/dep-policy-check.sh
  - scripts/mend-style-scan.sh
  - dep-policy repo：maven-approved.yaml / npm-approved.yaml / nuget-approved.yaml
---

# 多生態系案例 — Maven / npm / NuGet 過同兩條 gate

> demo 三個元件涵蓋三個生態系，全部過**同兩條依賴 gate**：
> `dep-policy-gate`（default-deny 白名單）與 `mend-style-gate`（default-allow 政策掃描，模擬 Mend）。
> 治理骨架不綁語言——換的只是「怎麼解析依賴」。概念見 [[dep-policy-gate-concepts]]、[[mend-style-vs-allowlist]]。

---

## 0. 三生態系一覽

| 元件 | 生態系 | 依賴來源（lockfile）| 白名單檔 | 乾淨基準（元件數）|
|---|---|---|---|---|
| `backend/` | Maven (Java) | `pom.xml` → `mvn dependency:list` | `maven-approved.yaml` | 31 |
| `frontend/` | npm (Vue) | `package-lock.json` | `npm-approved.yaml` | 126 |
| `dotnet/` | NuGet (.NET 8) | `packages.lock.json` | `nuget-approved.yaml` | 1（Newtonsoft.Json）|

兩條 gate 怎麼各自取依賴座標（`scripts/dep-policy-check.sh`）：

| 生態系 | dep-policy 取座標 | mend-style 掃描 |
|---|---|---|
| Maven | `mvn dependency:list` → `g:a:v` | Trivy fs（pom.xml）|
| npm | `package-lock.json` 的 `node_modules/*` → `name@ver` | Trivy fs（package-lock）|
| NuGet | `packages.lock.json` 的 `.dependencies[tfm][name].resolved` → `name@ver` | Trivy fs（packages.lock）|

> mend-style 的評估器（`mend_policy_eval.py`）對三者**完全共用**——它只吃 Trivy JSON，與語言無關。

---

## 1. Maven（backend）

**FAIL 示範**：pom 加未核可且有 Log4Shell 的 `log4j-core:2.14.1`：
```
dep-policy-gate : 未核可 2 筆（含 transitive log4j-api）→ FAIL
mend-style-gate : CVE-2021-44228/45046 (CRITICAL) + 45105 (HIGH) → FAIL
```
> 只加 1 顆卻抓到 2 顆 = transitive `log4j-api` 一起被解析。

## 2. npm（frontend）

**FAIL 示範**：加未核可且有漏洞的 `lodash@4.17.11`：
```
dep-policy-gate : 127 vs 126 → lodash@4.17.11 未核可 → FAIL
mend-style-gate : CVE-2019-10744 (CRITICAL) + 2020-8203/2021-23337/… (HIGH) → FAIL
```

## 3. NuGet（dotnet）

最小 .NET 8 minimal API（`/api/products`、`/health`），外部依賴 `Newtonsoft.Json`。
`packages.lock.json` 由 `dotnet restore`（`RestorePackagesWithLockFile`）產生，給 gate 比對/掃描。

**FAIL 示範**：把 `Newtonsoft.Json` 降到有漏洞的 `12.0.3`：
```
dep-policy-gate : 12.0.3 不在 nuget-approved.yaml → FAIL
mend-style-gate : CVE-2024-21907 (HIGH) → FAIL
```

---

## 4. 怎麼跑

```bash
cd app
# dep-policy（default-deny 白名單）
POLICY_DIR=../dep-policy ./scripts/dep-policy-check.sh backend   # 或 frontend / nuget
# mend-style（default-allow 政策掃描）
./scripts/mend-style-scan.sh all                                 # backend+frontend+dotnet
```

**CI**（`.github/workflows/supply-chain.yml`）：
- `dep-policy-gate`：三步（backend / frontend / dotnet）
- `mend-style-gate`：`mend-style-scan.sh all`（含 dotnet）
- `build-scan-sign` matrix：`[backend, frontend, dotnet]`，三者皆 build→SBOM→scan→簽章
- 四個 required check（sast / secrets / dep-policy-gate / mend-style-gate）對所有 PR 鎖 merge

---

## 5. 新增 NuGet 套件的流程（同 Maven/npm）

1. `dotnet/SupplyChainDemo.csproj` 加 `<PackageReference>` → `dotnet restore` 重產 `packages.lock.json`
2. 本機 `./scripts/dep-policy-check.sh nuget` → 不在白名單會 FAIL 並列出 coord
3. 開 PR 到 dep-policy repo 把 coord 加進 `nuget-approved.yaml` → review.yml 跑 OSV+cooldown → @security-team 核可
4. 回 app 重跑 → PASS

---

## See Also
- [[dep-policy-gate-concepts]] — 白名單 gate 原理/盲點/落地、defense in depth
- [[mend-style-vs-allowlist]] — 兩種治理哲學對照、Mend 模擬細節
- [[github-port-guide]] — GitLab → GitHub 移植
