using Newtonsoft.Json;

// 最小 .NET service，對齊 backend 的 /api/products，焦點在供應鏈治理而非功能。
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var products = new[]
{
    new { id = 1, name = "Coffee", price = 120 },
    new { id = 2, name = "Bagel", price = 90 },
    new { id = 3, name = "Sandwich", price = 150 },
};

// 用 Newtonsoft.Json 序列化，確保該 NuGet 依賴真的被使用（不會被裁掉）
app.MapGet("/api/products", () =>
    Results.Text(JsonConvert.SerializeObject(products), "application/json"));

app.MapGet("/health", () => Results.Ok(new { status = "UP" }));

app.Run();
