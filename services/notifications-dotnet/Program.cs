// ShopLite notifications service (.NET 8 minimal API).
//
// Tracing: the Datadog .NET tracer is a CLR profiler shipped in the Datadog.Trace.Bundle NuGet
// package and loaded by environment variables (CORECLR_ENABLE_PROFILING, CORECLR_PROFILER,
// CORECLR_PROFILER_PATH_64, DD_DOTNET_TRACER_HOME; see scripts/start-services.ps1). No startup code.
// Tags and errors use the Datadog.Trace API; custom spans use .NET's built-in ActivitySource,
// which the tracer picks up when DD_TRACE_OTEL_ENABLED=true.
using System.Diagnostics;
using Datadog.Trace;

var builder = WebApplication.CreateBuilder(args);
// BIND_HOST=0.0.0.0 inside a container (localhost would be unreachable from other containers).
builder.WebHost.UseUrls($"http://{Environment.GetEnvironmentVariable("BIND_HOST") ?? "localhost"}:{Environment.GetEnvironmentVariable("PORT") ?? "8004"}");
builder.Logging.SetMinimumLevel(LogLevel.Warning);

var activitySource = new ActivitySource("Notifications");

var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new { status = "ok", service = "notifications" }));

app.MapPost("/send", async (SendRequest req) =>
{
    SetTag("order_id", req.OrderId.ToString());
    SetTag("channel", req.Channel);

    using (var span = activitySource.StartActivity("render-template"))
    {
        span?.SetTag("template", "order-confirmation");
        await Task.Delay(Random.Shared.Next(5, 30));
    }

    // Simulated email provider: 12% of sends time out. Handled by the caller (orders),
    // but this service reports a 503 and an error.
    using (activitySource.StartActivity("email-provider send"))
    {
        await Task.Delay(Random.Shared.Next(20, 80));
        if (Random.Shared.Next(100) < 12)
            throw new TimeoutException("Email provider did not answer within 2s");
    }
    return Results.Ok(new { sent = true, req.OrderId, req.Channel });
});

app.MapGet("/error", () => { throw new InvalidOperationException("Deliberate notifications failure (chaos endpoint)"); });

// Turn exceptions into JSON 503s, and mark the request span as an error.
app.Use(async (ctx, next) =>
{
    try { await next(); }
    catch (Exception e)
    {
        Tracer.Instance.ActiveScope?.Span.SetException(e);
        Activity.Current?.SetStatus(ActivityStatusCode.Error, e.Message);
        ctx.Response.StatusCode = 503;
        await ctx.Response.WriteAsJsonAsync(new { error = e.Message });
    }
});

Console.WriteLine("[notifications] listening on http://localhost:8004");
app.Run();

static void SetTag(string key, string value) => Tracer.Instance.ActiveScope?.Span.SetTag(key, value);

record SendRequest(long OrderId, string UserId, string Channel);
