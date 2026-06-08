---
title: 兩種依賴治理 — 顯式白名單 vs Mend-style 政策掃描
type: concept + howto
created: 2026-06-08
updated: 2026-06-08
tags: [supply-chain, mend, sca, policy-as-code, dep-policy, defense-in-depth]
sources:
  - scripts/dep-policy-check.sh
  - scripts/mend-style-scan.sh
  - scripts/mend_policy_eval.py
  - mend-sim/mend-policy.yaml
  - .github/workflows/supply-chain.yml
---

# 兩種依賴治理 — 顯式白名單 vs Mend-style 政策掃描

> demo 並存兩條依賴 gate，刻意對照兩種**相反的治理哲學**。第二條（Mend-style）是用開源
> 工具**模擬** Mend 的行為，貼合「公司實際用 Mend」的環境，**非真接 Mend SaaS**。
> 概念基礎見 [[dep-policy-gate-concepts]]。

---

## 0. 一句話

| | `dep-policy-gate` | `mend-style-gate`（模擬 Mend）|
|---|---|---|
| 哲學 | **default-deny**：沒列就擋 | **default-allow**：掃到違規才擋 |
| 判官 | 你手刻的 `approved.yaml` | 漏洞 DB + `mend-policy.yaml` 政策 |
| 閉包 | 你預先列（含 transitive）| 工具 discovery 自動解析 |
| 擋什麼 | 不在白名單的「身份」 | 命中 policy 的「漏洞 / 授權」 |
| 維護成本 | 高（逐筆、逐版）| 低（規則一次寫） |

兩者**互補、可疊用**：白名單給「確定性」，政策掃描給「可規模化」。

---

## 1. Mend-style gate 怎麼運作（模擬）

流程仿 Mend 的 SCA 管線（`scripts/mend-style-scan.sh`）：

```
1. discovery  Trivy 從 manifest 解析全部元件（含 transitive）
2. scan       漏洞(vuln) + 授權(license)
3. evaluate   套 mend-sim/mend-policy.yaml（default-allow，命中 reject 政策才擋）
              → scripts/mend_policy_eval.py
4. report     產 Mend 風格 inventory；有 reject 違規 → exit 1
```

政策檔 `mend-sim/mend-policy.yaml`（org policy 的縮影）目前三條：
- **security**：`min_severity: HIGH` → reject（≈ Mend security policy / CVSS·KEV）
- **license**：GPL/AGPL/LGPL-3.0 禁用 → reject（≈ Mend license policy）
- **age**：`min_age_days: 30` → warn（≈ Mend Renovate merge-confidence；sim 不強制）

---

## 2. 這個模擬 ↔ 真實 Mend 對照

| 真實 Mend | 本 sim 用什麼 | 落差/誠實標注 |
|---|---|---|
| 依賴 discovery（多語言、全 transitive）| Trivy `fs --list-all-pkgs` | **Maven 無 lockfile** → manifest 層 transitive 較淺；frontend 有 `package-lock` 故完整。真 Mend 用 Unified Agent 實跑 `mvn` 解析 |
| 漏洞 DB + policy | Trivy vuln + `mend-policy.yaml` | Trivy 用 NVD/廠商源；非 Mend 自有 DB |
| license policy | Trivy license + 禁用清單 | OK |
| reachability / effective-usage（降噪）| **未實作** | 真 Mend 會判「程式是否真的呼叫到漏洞」 |
| merge-confidence / 自動升版 | age policy（僅 warn）| 無離線發佈日期；對應 dep-policy 的 cooldown |
| Supply Chain Defender（擋惡意套件）| 未實作 | malware/typosquat 屬另一塊 |
| SaaS console / 跨專案 inventory | 一份 yaml + markdown 報告 | 真 Mend 是 SaaS 集中管控 |

> 重點：**模擬的是「形狀與判定邏輯」，不是 Mend 的 DB 與 reachability**。要真 Mend
> 就接 `mend` CLI + `MEND_API_KEY`（見當初討論的「真接」選項）。

---

## 3. 現場驗證（live demo）

**PASS（現狀）**：backend 0 漏洞、frontend 51 元件 0 漏洞 → `exit 0`、gate PASS。

**FAIL（暫時加 `log4j-core:2.14.1`）**：Trivy 解析出 log4j-core + transitive `log4j-api`，
命中 security policy：
```
discovery：3 個元件（含 transitive）
漏洞：7 筆（CRITICAL 2 / HIGH 1 / MEDIUM 4）
REJECT 違規（3）
  ✗ [security] log4j-core@2.14.1 CVE-2021-44228 (CRITICAL)
  ✗ [security] log4j-core@2.14.1 CVE-2021-45046 (CRITICAL)
  ✗ [security] log4j-core@2.14.1 CVE-2021-45105 (HIGH)
✗ Mend-style gate FAIL — 3 筆 reject 違規
```
→ 對比同一顆 log4j：`dep-policy-gate` 因「**沒被核可**」擋；`mend-style-gate` 因「**有 CVE**」擋。
**兩種哲學、同一顆套件、各自擋下**——這就是並存對照的價值。

---

## 4. 怎麼跑

**本機**：
```bash
cd app
./scripts/mend-style-scan.sh all        # 需 docker(trivy) + python3+pyyaml
# 報告：/tmp/mend-sim/mend-inventory.md
```

**CI**：`.github/workflows/supply-chain.yml` 的 `mend-style-gate` job；
`build-scan-sign` 已 `needs` 它（與 `dep-policy-gate` 並列，任一擋都不 build）。
若要它也鎖 merge，把 `mend-style-gate` 加進 ruleset 的 required status checks（同 dep-policy-gate 做法）。

---

## See Also
- [[dep-policy-gate-concepts]] — 白名單 gate 原理/盲點/落地（L3）、defense in depth L1~L4
- [[github-port-guide]] — GitLab → GitHub 移植
- `mend-sim/mend-policy.yaml` — 政策定義
