---
title: provided-scope 依賴治理 與 runtime 平台治理軌
type: concept
created: 2026-06-09
updated: 2026-06-09
tags: [supply-chain, provided-scope, maven, runtime-platform, liberty, jboss, iis, dotnet-runtime, governance, mend]
---

# provided-scope 依賴治理 與 runtime 平台治理軌

> 起因：demo 的 backend 依賴全是 `provided` scope，Mend 後台沒有元件——因為 SCA 預設排除 provided。
> 本篇講 provided 該怎麼治理（不是靠 app SCA），以及它揭露的「runtime 平台治理軌」缺口。
> 整體閉環見 [[maturity-assessment]]；Mend 整合見 [[mend-real-integration]]。

---

## 0. 結論

`provided` 依賴的風險**不靠 app 的 SCA 管**，而是靠 **(1) 劃清責任邊界 + (2) 獨立的 runtime 平台治理軌**。
真正會跑的漏洞碼在 **app server 的實作**裡（Liberty/JBoss/IIS/.NET runtime），不在你出貨的 artifact。

---

## 1. provided 是什麼、為何 Mend 排除

| | |
|---|---|
| 定義 | 編譯/測試需要、但**執行期由容器/runtime 提供**，**不打包進 jar/war** |
| 例 | Jakarta EE / Servlet / MicroProfile API；你 compile 對著 API，runtime 由 Liberty 給實作 |
| 為何 SCA 排除 | SCA 掃「你出貨的 artifact 裡有什麼」——provided 不在裡面 |

> Mend / Unified Agent 預設忽略 `provided`（與 `test`）scope。

---

## 2. 關鍵洞見：風險沒消失，是「責任轉移」

provided 的漏洞風險不會不見——**真正會跑的那段碼在 app server 的實作裡**，責任從「你的 build」轉移到「平台 / 中介軟體 owner」。

> 例：`jakarta.servlet-api` 你 compile 對著它，runtime 跑的是 **Liberty 的 servlet 實作**。若有 CVE，是 **Liberty 該修**、不是你的 war 該換版本。
> 推論：**你 compile 的 API 版本 ≠ runtime 跑的實作版本**——所以拿 provided 的 API jar 去掃 CVE，得到的是「規格版的洞」，不是「跑的實作的洞」，可行動性低。

---

## 3. 怎麼管理（三件）

### 3a. 劃清責任邊界（最重要）
| 誰 | 管什麼 |
|---|---|
| **App 團隊** | 出貨的依賴（compile/runtime scope，打包進 war 的）→ app 的 Mend SCA 管 |
| **平台 / 中介軟體團隊** | provided 的實作（Liberty/JBoss/IIS/.NET runtime 版本）→ 透過 app server 修補 |

### 3b. Mend 裡 provided 怎麼設
- **排除（預設，建議）**：app inventory = 「你出貨的」，乾淨、可行動。
- **納入**：只在想要「provided API 已知 CVE 的可見性」時；但因 API≠impl 版本，偏噪音、可行動性低。

### 3c. 另立「runtime 平台治理軌」（真正涵蓋 provided 的地方）
把 **Liberty / JBoss / IIS / .NET runtime** 的版本當成**供應鏈元件**自己治理：
- **盤點**：每台/每環境跑的 app server + 版本（這是一份「平台 inventory」，獨立於 app 依賴 inventory）
- **掃描**：app server 版本對應的已知 CVE（廠商公告 / Mend container/host scan / OS 套件掃描）
- **修補節奏**：跟 OS patch 一樣的 cadence；高風險（如 Log4Shell 影響 Liberty 內建）要能快速答「哪些環境中」
- **責任**：平台/中介軟體團隊 owns（對應 3a 的責任邊界）

---

## 4. 對 demo / 真實 app 的結論

- backend 全 `provided` 是「薄 demo」的產物。**真實 Java app 大部分是 shipped 依賴**（JSON/log/http client…），provided 只是少數 API。
- 所以真實 Mend inventory **以 shipped 依賴為主**。demo 要有 Java inventory，正解是**加真實 compile-scope 依賴**（讓它像真 app）——provided 那幾顆 API 保持 Mend 排除、改走平台治理軌。

---

## See Also
- [[mend-real-integration]] — Mend 整合（provided 被排除的現象）
- [[maturity-assessment]] — 整體成熟度（平台修補=未涵蓋的軌）
- [[file-artifact-delivery]] — 部署到 Liberty/JBoss/IIS（平台是部署目標）
