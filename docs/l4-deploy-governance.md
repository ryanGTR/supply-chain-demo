---
title: L4 部署治理 — 發佈前驗章閘門（檔案型,fail-closed）
type: concept + howto
created: 2026-06-16
updated: 2026-06-16
tags: [supply-chain, l4, deploy-verification, cosign, verify-blob, cmdb, fail-closed, itops]
sources:
  - itops_and_caas 右側部署治理(verify_deploy_gate / cmdb)
  - docs/file-artifact-delivery.md（檔案型交付模型）
  - ../itops-l4-integration-plan.md（整合計畫）
---

# L4 部署治理 — 發佈前驗章閘門

> **補上閉環最後一段**:supply-chain 左側(SAST/secret/dep-policy/SCA/sign)做得很滿,
> 但「**核可 → 入庫 → 部署驗證**」這條右側鏈一直是缺口(maturity-assessment 的
> 「部署/runtime 驗證」原本 L0–1)。本篇的 `deploy-governance/` 工具組把
> `itops_and_caas` 的右側治理**畢業**進來,補上 **L4「擋得住」** 那一段。

## 0. 一句話

已簽章 artifact 在「發佈進 feed / 部署上線」**之前**,要過一道 **fail-closed 驗章閘門**:
驗簽章、驗 artifact 沒被掉包、驗測試/掃描證據齊全——任一不過就發佈不出去。
通過的才登錄 CMDB(帶 build→scan→sign→verify 證據鏈)。

## 1. 為什麼是「右側」而非重做左側

itops 早期感覺白費,因為它在重做(且較弱)supply-chain 已做好的 build/sign → 冗餘 → 不被用。
**正解是單向交接**:左側只產「已簽 artifact + 證據」,右側只「驗證 + 放行 + 記錄」,靠
`ReleaseManifest`(交接契約,見 `deploy-governance/release-contract.md`)串接,兩側不互相重做。

```
SOURCE → BUILD → SCAN → SIGN          ← supply-chain 既有(左側,強)
        ──── 交接:ReleaseManifest(已簽 artifact + SBOM/掃描判定/測試證據/digest)────▶
〔 VERIFY-BEFORE-RELEASE（L4 驗章閘門,fail-closed）→ CMDB 證據鏈 〕  ← 本篇(右側)
```

## 2. 閘門檢查（`verify_release.py`,全 fail-closed）

| # | 檢查 | 擋掉什麼 | 控制項 |
|---|------|---------|--------|
| 1 | metadata 齊全(app/component/ecosystem) | 來路不明的發佈 | ISO 20000 組態 |
| 2 | 測試證據:`testReport` 為 sha256 + `testCount≥1` | 綠燈空殼(跳過/刪光測試假裝過) | A.8.29 |
| 3 | `digest` 為有效 sha256 | 未經建置/簽章的東西 | A.8.28 |
| 4 | **artifact 完整性**:檔案實際 sha256 == 宣告 digest | 交接後被掉包的 artifact | A.8.28 |
| 5 | `cosign verify-blob` 對 artifact 檔驗分離式簽章 | 未簽 / 非信任根所簽 / 竄改 | A.8.28 |
| 6 | SBOM 物證存在 + 掃描判定 `verdict==pass` | 缺證據 / 帶未處理風險 | A.8.28 |

任一不過 → `exit 1` → CI `release-backend` job 紅 → **發佈不出去**。

## 3. 為什麼是「檔案型」(jar/war)而非容器

公司實況是檔案型交付(jar/war → Liberty/JBoss、.NET publish → IIS),**沒有容器 image**
(見 [[file-artifact-delivery]])。所以驗的是 `cosign verify-blob <artifact>`,不是驗 image。
demo 的 `release-backend` job 因此走 `mvn package → war → sign-blob → verify-blob`,
驗「真的要部署的那個檔」。

## 4. 簽章後端可換（D3 adapter,零浪費）

`ReleaseManifest.spec.signature.mode` 決定信任根,**換後端閘門邏輯零改動**:

| mode | Tier | 信任根 |
|------|------|--------|
| `key-pair` | Tier 1 PoC / 銀行氣隙離線驗 | `cosign.pub`（`--insecure-ignore-tlog`）|
| `keyless` | github OIDC | 簽章憑證 + identity |
| `hashivault` | Tier 2 | Vault transit 公鑰 |
| `pkcs11` | 未來公司 | HSM / CyberArk |

## 5. CMDB 證據鏈（`cmdb_register` / `cmdb_validate`）

驗章通過後登錄一筆 `ReleasedArtifact` CI,串起 **build → scan → sign → verify** 每一段物證;
`cmdb_validate` fail-closed 驗物證存在、digest 有效。版控史 = 發佈史(GitOps 雛形)。

## 6. 怎麼跑

```bash
# CI:supply-chain.yml 的 release-backend job 自動跑(mvn package → … → verify_release → CMDB)
# 本機自測(產臨時 key-pair、簽假 artifact、跑 1 正向 + 6 負向 + CMDB):
bash deploy-governance/tests/selftest.sh
```

## 7. 成熟度銷項

| 環節 | 之前 | 現在 |
|------|------|------|
| 部署 / runtime 驗證(擋未簽/未核可上線)| **L0–1**(沒做)| **L4 機制**(fail-closed 驗章 + 6 道檢查 + self-test) |

## 8. 邊界（後續）

- 前端 / dotnet 的檔案型路線、退役容器 build。
- Tier 2:Vault transit 簽章後端、build-once 多環境 promote(test→uat→prod 逐區重驗)、變更治理、上 ADO。

## See Also
- `deploy-governance/release-contract.md` — 交接契約 schema
- [[file-artifact-delivery]] — 檔案型交付模型
- [[maturity-assessment]] — 整體成熟度（本篇銷掉「部署驗證」缺口）
- `../itops-l4-integration-plan.md` — 整合計畫(Tier 1/2)
