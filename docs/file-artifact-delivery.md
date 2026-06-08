---
title: 非容器・檔案型 artifact 交付路線（jar/war/.NET/npm → Azure Artifacts）
type: concept + howto
created: 2026-06-08
updated: 2026-06-08
tags: [supply-chain, azure-artifacts, non-container, cosign, sign-blob, deploy-verification, jar, war, dotnet, npm]
sources:
  - 公司實況：Java 收 jar/war、.NET Core 同樣檔案型、無 image、無前後端分離
---

# 非容器・檔案型 artifact 交付路線

> **公司實況**：交付物是**檔案型 artifact**（Java 的 jar/war、.NET Core 的發佈輸出），
> 部署到 Liberty/JBoss/IIS，**沒有容器 image**。所以 demo 原本的「容器 image 中心」
> （Docker/GHCR/簽 image）**不代表真實部署模型**——本篇是貼合實況的非容器路線。
> 對照容器版見 [[azure-devops-port]]；整體成熟度見 [[maturity-assessment]]。

---

## 0. 一句話

沒有 image → 不用 ACR。registry = **Azure Artifacts** 的三種 feed；簽章改 **cosign sign-blob**
（簽檔案，不是簽 image）；部署前 **cosign verify-blob** 擋未簽/未核可上線。

> **關鍵概念**：**Universal Packages** = Azure Artifacts 用來放「不是天然套件的可部署產物」
> （任意檔案/zip）。.NET 發佈輸出、Node app bundle 都靠它。

---

## 1. 逐生態系：產物 → 放哪 → 怎麼推

| 生態系 | 產物 | Azure Artifacts feed | 發佈指令 |
|---|---|---|---|
| **Java** | `jar` / `war` | **Maven feed** | `mvn deploy`（war 也是 Maven artifact）|
| **.NET（可部署 app）** | `dotnet publish` 輸出 → zip | **Universal Packages** | `az artifacts universal publish` |
| .NET（library）| `nupkg` | NuGet feed | `dotnet nuget push` |
| **npm**（前端打包進 war/jar）| 無獨立 artifact | —（隨 war 一起）| 靜態檔進 jar/war；npm 依賴政策仍由 Mend+白名單管 |
| npm（獨立 Node app）| `dist` → zip | Universal Packages | `az artifacts universal publish` |
| npm（library）| `tgz` | npm feed | `npm publish` |

> 自己發佈的 feed 要與「第三方快取 feed」**分開**（internal-published vs third-party-cache）。

---

## 2. 共通三步（不分生態系）

1. **SBOM + 漏洞**：`syft <jar|publish-dir|tgz>` 產 CycloneDX SBOM；`trivy fs` 掃漏洞。
   （Syft/Trivy 都能掃檔案/資料夾/壓縮檔，不限 image。）
2. **簽章**：`cosign sign-blob <artifact>` → 產**分離式簽章**（`.sig`，+ 可選 cert/Rekor）。
   與 image 簽法不同，但 keyless/OIDC 一樣適用。
3. **附帶**：簽章 + SBOM + provenance 跟著 artifact 存（feed metadata 或併存檔）。

---

## 3. 節點 8：部署驗證（對檔案型最關鍵）

部署自動化（Ansible / Octopus / 腳本）在把 `jar/war/zip` 丟到 **Liberty/JBoss/IIS 之前**：
```
cosign verify-blob --signature <artifact>.sig [--certificate ...] <artifact>
# 通過才部署；同時可核對 SBOM/provenance
```
未過不准上線 = **非容器版的「擋得住」**。這就是 backlog T1「部署驗證閉環(非容器版)」。

---

## 4. 對 demo 的影響（待辦 B）

目前 demo 是容器 image 中心，與公司實況不符。**B：把 demo 改成檔案型路線**：
- backend(Java)：`mvn package` → 簽 `war` → 推 Maven feed（不 build image）
- dotnet：`dotnet publish` → zip → 簽 → Universal Packages
- frontend(npm)：靜態檔（若併入 war）或 dist zip → Universal Packages
- 三者：Syft SBOM + cosign sign-blob；部署步驟 `verify-blob`
> 排入 todo，待 Azure Artifacts feed 建好 + 決定各產物型態後實作。

---

## 5. 放進閉環的位置

| 閉環節點 | 檔案型做法 |
|---|---|
| 6 SBOM/簽章 | Syft + `cosign sign-blob`（blob 模式）|
| 7 發佈 registry | **Azure Artifacts**（Maven / Universal / NuGet / npm），非 ACR |
| 8 部署驗證 | 部署前 `cosign verify-blob` 擋未簽/未核可 |

---

## See Also
- [[maturity-assessment]] — 整體成熟度（節點 7/8 缺口）
- [[azure-devops-port]] — ADO 落地（容器版對照）
- [[mend-real-integration]] — Mend 政策/inventory
- [[dep-policy-gate-concepts]] — 白名單 / defense in depth
