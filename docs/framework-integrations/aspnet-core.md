# Joubako with ASP.NET Core

This integration connects Joubako to an ASP.NET Core Minimal API. Anonymous
objects and a request record map directly to Joubako's typed JSON request and
response models.

## Backend implementation

```csharp
app.MapGet("/api/health", () => Results.Json(new
{
    ok = true,
    framework = "ASP.NET Core",
}));

app.MapPost("/api/messages", (MessageRequest request, HttpRequest httpRequest) =>
{
    if (string.IsNullOrEmpty(request.Text) || request.Priority is < 1 or > 5)
    {
        return Results.Json(new { error = "invalid message" }, statusCode: 422);
    }

    return Results.Json(new
    {
        accepted = true,
        text = request.Text,
        priority = request.Priority,
        framework = "ASP.NET Core",
    }, statusCode: 201);
});
```

See the complete [`Program.cs`](../../examples/frameworks/aspnet/Program.cs).

## Run ASP.NET Core

The .NET 8 SDK or newer is required.

```sh
cd examples/frameworks/aspnet
dotnet run --configuration Release
```

## Call ASP.NET Core from Joubako

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:8083/ \
  JOUBAKO_DEMO_EXPECTED_FRAMEWORK="ASP.NET Core" \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

The integration is built and executed in CI with both ARC and ORC Joubako
clients.

## Production notes

Use the application's normal authentication and authorization handlers,
request-size limits, HTTPS configuration, rate limiting, and structured
logging. Keep server cancellation connected to request aborts for long-running
operations.
