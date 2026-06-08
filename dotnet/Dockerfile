# 多階段 build：SDK build → ASP.NET runtime（對齊 backend 多階段風格）
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY *.csproj .
# 用 lock file 還原（--locked-mode：lock 與 csproj 不一致就失敗，確保可重現）
RUN dotnet restore --locked-mode
COPY . .
RUN dotnet publish -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
COPY --from=build /app .
EXPOSE 8080
ENTRYPOINT ["dotnet", "SupplyChainDemo.dll"]
