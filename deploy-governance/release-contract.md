# 交接契約：ReleaseManifest（檔案型 DeploymentRequest）

> supply-chain 的**左側**（build/scan/sign）做完後,要交給**右側 L4 部署治理**消費什麼?
> 這份契約定義那個交接面。它是「檔案型的 DeploymentRequest」——把已簽章 artifact +
> 全套證據打包成一份宣告,讓環境無關的 `deploy-governance/` 工具組能 fail-closed 驗證它。
>
> 來源:把 `itops_and_caas` 的右側部署治理「畢業」進 supply-chain 當 L4(見
> `../itops-l4-integration-plan.md`)。對齊公司檔案型現實(見 `docs/file-artifact-delivery.md`):
> 交付物是 jar/war/zip,不是容器 image;簽章用 `cosign sign-blob`,部署前 `cosign verify-blob`。

## 為什麼需要一份「契約」

左右兩側若各自重做(itops 重簽一份較弱的簽章),就是冗餘 → 不會被用。
正解是**單向交接**:左側只負責產出「已簽 artifact + 證據」,右側只負責「驗證 + 放行 + 記錄」。
契約把這個交接面寫死成 schema,兩側都對著它寫,不互相重做。

## Schema（`apiVersion: supplychain/v1`, `kind: ReleaseManifest`）

| 欄位 | 必填 | 說明 |
|------|:--:|------|
| `metadata.app` | ✅ | 應用名(如 `supply-chain-backend`) |
| `metadata.component` | ✅ | 元件(`backend` / `frontend` / `dotnet`) |
| `metadata.ecosystem` | ✅ | `java` / `dotnet` / `npm`——決定 artifact 型態與發佈 feed |
| `metadata.requestedBy` |  | 觸發者(CI / 人);稽核用 |
| `metadata.environment` |  | Tier 1 留空;Tier 2 多環境 promote 用 |
| `metadata.serviceRequest` |  | 對應工單(可接 itops × iTop 的 UserRequest) |
| `metadata.change` |  | 變更治理區塊(見下節〈變更治理〉;缺則視為 `standard`,零摩擦)。由 `validate_change_class.py` fail-closed 驗 |
| `spec.artifact.coordinates` | ✅ | 座標:Maven GAV / Universal Package 名 / npm 名@版本 |
| `spec.artifact.type` | ✅ | `jar` / `war` / `zip` / `tgz` / `nupkg` |
| `spec.artifact.path` | ✅ | artifact **檔案**相對路徑(供 `verify-blob` 與 hash 比對) |
| `spec.artifact.digest` | ✅ | `sha256:<64hex>`——artifact **內容**雜湊(不可變身分) |
| `spec.artifact.feed` |  | 發佈目的 feed(Tier 2:Azure Artifacts Maven/Universal/NuGet) |
| `spec.signature.path` | ✅ | `cosign sign-blob` 產的分離式簽章檔(`.sig`) |
| `spec.signature.mode` | ✅ | 簽章後端(D3 adapter):`key-pair`(Tier1)/ `keyless` / `hashivault`(Tier2)/ `pkcs11`(未來 HSM) |
| `spec.signature.certificate` |  | `keyless` 模式的簽章憑證 |
| `spec.evidence.sbom` | ✅ | CycloneDX SBOM 檔(Syft 產) |
| `spec.evidence.scanVerdict` | ✅ | 掃描判定檔(Trivy/Mend),須含 `verdict: pass` |
| `spec.evidence.testReport` | ✅ | 測試證據指紋 `sha256:<64hex>`(surefire 報告雜湊) |
| `spec.evidence.testCount` | ✅ | 測試筆數,須 ≥ 1(防「綠燈空殼」) |
| `spec.evidence.provenance` |  | SLSA build provenance ref(可選) |
| `spec.dataClassification` |  | `internal` / `confidential`…(治理分級) |

## 簽章模型（D3 adapter：換後端只換 mode/key，閘門不動）

| mode | 簽 | 驗(`verify_release.py`) | 用途 |
|------|----|--------------------------|------|
| `key-pair` | `cosign sign-blob --key cosign.key` | `cosign verify-blob --key cosign.pub --insecure-ignore-tlog` | Tier 1 PoC / 銀行氣隙離線驗 |
| `keyless` | `cosign sign-blob`(OIDC) | `cosign verify-blob --certificate … --certificate-identity …` | github demo 既有 keyless |
| `hashivault` | `cosign sign-blob --key hashivault://…` | 公鑰驗(同 key-pair) | Tier 2:Vault transit |
| `pkcs11` | HSM | 公鑰驗 | 未來公司 HSM/CyberArk |

> cosign 把後端抽象掉:**驗的那一端永遠是「對 artifact 檔驗一個分離式簽章」**,
> 只有「拿什麼信任根」隨 mode 改。所以 Tier 1→2→公司換金鑰後端,閘門邏輯零改動。

## 變更治理（`metadata.change`，T2.4：移植 itops Phase E 右側治理）

供應鏈右側的**現實校正層**。真實世界會有急件/插單/補單,但鐵則是
**鬆綁的只能是人工審核的時點/對象/順序,絕不是技術閘門**——簽章/掃描/驗章對所有
`change.type` 一律強制(`validate_change_class.py` 規則 5 偵測並擋下任何「繞過旗標」)。

```yaml
metadata:
  app: supply-chain-backend
  change:
    type: standard        # standard|normal|emergency|retroactive(缺 = standard)
    priority: P3          # P1..P4(可選)
    justification: "..."  # emergency / retroactive 必填:例外要有理由
    pir:                  # emergency / retroactive 必填:事後回顧不可賴帳
      owner: alice
      dueBy: 2026-07-01   # YYYY-MM-DD
    nonconformity: "DRIFT#42"  # retroactive 必填:補單≠漂白,連回不符合事項/漂移單
    expedite:             # 插單(可選);有就必須同時有 by + reason
      by: bob
      reason: "P1 incident hotfix"
```

| `change.type` | 額外必填 | 語意 |
|------|------|------|
| `standard` / `normal` | —(走正常審核) | 預設;零摩擦 |
| `emergency`（急件,先做後審） | `justification` + `pir{owner,dueBy}` | 鬆綁審核**時點**,不鬆綁技術閘門 |
| `retroactive`（補單） | `justification` + `pir` + `nonconformity` | 記錄既成事實 **+ 連回根因**;補單≠漂白 |

| `validate_change_class.py` 規則 | 控制項 |
|------|------|
| 1. type 合法(缺=standard) | A.8.32 |
| 2. priority P1..P4 | ISO 20000 變更管理 |
| 3. emergency/retroactive ⇒ justification | A.8.32 |
| 3b. emergency/retroactive ⇒ pir{owner,dueBy} | A.5.36 |
| 3c. retroactive ⇒ nonconformity（補單≠漂白） | A.5.36 / 矯正措施 |
| 4. expedite ⇒ by + reason（誰批+為何加急） | A.5.3 職責分離 |
| 5. ★ 無繞過旗標（skip/bypass/disable*gate/sign/scan…） | A.8.28 完整性 |

**正式區核准（CAB）**由 `promote.py --approved-by` 把關(晉級到 order 最後一格需核可)。
**發佈漂移對帳**由 `reconcile_release.py` 比對 CMDB 期望態 vs 發佈庫實際態(digest 不一致/
庫內被掉包/記錄聲稱發佈但庫裡沒有 → fail-closed)。

## 驗收（`verify_release.py` 的 fail-closed 檢查）

1. **必要 metadata 齊全**(app/component/ecosystem)。
2. **測試證據**:`testReport` 為有效 sha256、`testCount ≥ 1`(promote what passed test;防空殼)。
3. **digest 有效**:`sha256:<64hex>`。
4. **artifact 完整性**:檔案存在,且其實際 sha256 == 宣告 digest(防交接後被掉包)。
5. **簽章有效**:`cosign verify-blob` 對 artifact 檔驗簽,信任根/憑證依 mode。
6. **證據物證存在**:SBOM 檔存在、掃描判定檔存在且 `verdict == pass`。

任一不過 → exit 1 → CI release-verify job 紅 → **未驗章/未通過的 artifact 發佈不出去**。

## 對應治理控制項

ISO 27001 A.8.28（供應鏈完整性）、A.8.29（開發中測試）、A.8.32（變更管理）、A.5.36（合規審查）;
ISO 20000 發布與部署管理。詳見 `docs/l4-deploy-governance.md`。
