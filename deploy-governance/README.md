# deploy-governance — 環境無關的 L4 部署治理工具組

> 供應鏈的**右側**:在 build/scan/sign 之後,負責「**發佈前驗章 → 記錄組態 → 證據鏈**」。
> 把 `itops_and_caas` 的部署治理邏輯**畢業**進 supply-chain,抽成環境無關、檔案型(jar/war/zip)
> 的 Python 工具組,github / ADO pipeline 共用同一套(不再 per-platform 重寫)。
> 整合計畫見 `../itops-l4-integration-plan.md`;檔案型交付模型見 `docs/file-artifact-delivery.md`。

## 為什麼存在(補上 L4 缺口)

supply-chain 左側(SAST/secret/dep-policy/SCA/sign)做得很滿,但**右側部署生命週期治理是空的**
(maturity-assessment 的 L4 缺口)。itops 唯一獨有且完整的就是這塊。整合後是一條
**source → build → scan → sign →〔verify-before-release → CMDB 證據鏈〕→ 發佈** 的完整供應鏈治理鏈。

## 元件

| 檔案 | 角色 |
|------|------|
| `release-contract.md` | **交接契約**:左側簽完輸出給 L4 的 `ReleaseManifest` schema(檔案型 DeploymentRequest) |
| `examples/release-manifest.example.yaml` | 契約範例 |
| `verify_release.py` | **L4 發佈前驗章閘門**(fail-closed):metadata / 測試證據 / digest / artifact 完整性 / 簽章 / SBOM+掃描判定 |
| `cmdb_register.py` | 驗章通過後,登錄「已發佈 artifact」CI + 端到端證據鏈(build→scan→sign→verify) |
| `cmdb_validate.py` | fail-closed 驗 CI 結構與證據鏈物證存在、digest 有效 |
| `tests/selftest.sh` | 1 正向 + 6 負向(未簽/竄改/缺證據/掃描 fail/空測試/壞 digest)+ CMDB 驗證 |

## 本機跑

```bash
bash deploy-governance/tests/selftest.sh          # 自我測試(需 cosign + PyYAML)

# 對一份真 manifest 驗章(信任根 = trust/cosign.pub)
python3 deploy-governance/verify_release.py --manifest release.yaml --pubkey trust/cosign.pub --root .
# 通過後登錄 CMDB + 驗證
python3 deploy-governance/cmdb_register.py --manifest release.yaml --cmdb-dir cmdb
python3 deploy-governance/cmdb_validate.py --cmdb-dir cmdb --root .
```

## 簽章後端可換(D3 adapter)

`ReleaseManifest.spec.signature.mode` 決定信任根:`key-pair`(Tier1 PoC)/ `keyless`(github OIDC)/
`hashivault`(Tier2 Vault transit)/ `pkcs11`(未來公司 HSM)。**換後端只改 mode/key,閘門邏輯零改動。**

## 狀態

- ✅ Tier 1 工具組 + self-test(本目錄)。CI self-test:`.github/workflows/deploy-governance.yml`。
- ⏳ T1.4 接進 `supply-chain.yml` 的真 release 流程(含 demo 容器→檔案型路線的取捨,待定)。
- ⏳ Tier 2:Vault 簽章後端、build-once 多環境 promote、上 ADO(見整合計畫)。

對應治理控制項:ISO 27001 A.8.28 / A.8.29 / A.8.32 / A.5.36;ISO 20000 發布與部署管理。
