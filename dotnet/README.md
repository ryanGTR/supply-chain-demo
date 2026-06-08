# dotnet — .NET 8 minimal API（NuGet 生態系範例）

最小 .NET 8 service，與 `backend/` 對齊，焦點在**供應鏈治理**而非功能。
存在的目的：讓 demo 涵蓋第三個生態系 **NuGet**，過與 Maven/npm 相同的兩條依賴 gate。

## 端點
- `GET /api/products` — 回三筆商品（用 `Newtonsoft.Json` 序列化）
- `GET /health` — `{ "status": "UP" }`

## 檔案
| 檔案 | 用途 |
|---|---|
| `SupplyChainDemo.csproj` | 專案定義；`RestorePackagesWithLockFile` 產 lock |
| `Program.cs` | minimal API |
| `packages.lock.json` | 鎖定依賴 → 給 `dep-policy-gate` 比對、給 Trivy 掃完整 closure |
| `Dockerfile` | 多階段 build（SDK → ASP.NET runtime）|

## 依賴治理
- **白名單**：`packages.lock.json` 的座標需 ⊆ `dep-policy/nuget-approved.yaml`（`dep-policy-check.sh nuget`）
- **政策掃描**：Trivy 掃 `packages.lock.json` 的 vuln/license（`mend-style-scan.sh dotnet`）
- 新增套件流程見 [`../docs/ecosystem-cases.md`](../docs/ecosystem-cases.md) §5

## 本機跑
```bash
# 改 csproj 的 PackageReference 後，重產 lock（無 host dotnet 可用 docker SDK）
docker run --rm -v "$PWD":/src -w /src mcr.microsoft.com/dotnet/sdk:8.0 dotnet restore

# build + 跑
docker build -t scdemo-dotnet . && docker run --rm -p 8080:8080 scdemo-dotnet
```
