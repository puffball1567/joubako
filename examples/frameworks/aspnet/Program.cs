var builder = WebApplication.CreateBuilder(args);
var port = Environment.GetEnvironmentVariable("PORT") ?? "8083";
builder.WebHost.UseUrls($"http://127.0.0.1:{port}");

var app = builder.Build();

app.MapGet("/api/health", () => Results.Json(new
{
    ok = true,
    framework = "ASP.NET Core",
}));

app.MapGet("/api/users/{id:int}", (int id) =>
{
    if (id != 1)
    {
        return Results.Json(new { error = "user not found" }, statusCode: 404);
    }

    return Results.Json(new
    {
        id,
        name = "ASP.NET Core User",
        email = "aspnet@example.test",
    });
});

app.MapPost("/api/messages", (MessageRequest request, HttpRequest httpRequest) =>
{
    if (string.IsNullOrEmpty(request.Text) ||
        request.Text.Length > 200 ||
        request.Priority is < 1 or > 5)
    {
        return Results.Json(new { error = "invalid message" }, statusCode: 422);
    }

    var client = httpRequest.Headers["X-Joubako-Demo"].FirstOrDefault() ?? "unknown";
    return Results.Json(new
    {
        accepted = true,
        text = request.Text,
        priority = request.Priority,
        framework = "ASP.NET Core",
        client,
    }, statusCode: 201);
});

app.Run();

internal sealed record MessageRequest(string Text, int Priority);
