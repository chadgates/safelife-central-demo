using SafeLife.Central;

var options = AppOptions.FromEnvironment();

var builder = WebApplication.CreateBuilder(args);

// One Kestrel port; Caddy terminates TLS in front of it.
builder.WebHost.ConfigureKestrel(k => k.ListenAnyIP(options.HttpPort));

builder.Services.AddSingleton(options);
builder.Services.AddSingleton<MessageStore>();
builder.Services.AddSingleton<TcpIngestService>();

// Registered as singletons above so the API can read their state, and started here.
builder.Services.AddHostedService(sp => sp.GetRequiredService<MessageStore>());
builder.Services.AddHostedService(sp => sp.GetRequiredService<TcpIngestService>());

var app = builder.Build();

var store = app.Services.GetRequiredService<MessageStore>();
var log = app.Services.GetRequiredService<ILogger<Program>>();

// Create the table on first boot. A real service would run migrations as a deploy job;
// for a dummy this keeps the deployment to a single container.
try
{
    await store.EnsureSchemaAsync(CancellationToken.None);
}
catch (Exception ex)
{
    log.LogCritical(ex, "Cannot reach Postgres - check PGHOST/PGUSER/PGPASSWORD and the DBaaS IP filter");
    throw;
}

app.UseDefaultFiles();
app.UseStaticFiles();

app.MapGet("/api/messages", async (MessageStore s, int? limit, CancellationToken ct) =>
{
    var take = Math.Clamp(limit ?? 100, 1, 100);   // the UI always asks for the last 100
    return Results.Ok(await s.GetLatestAsync(take, ct));
});

// Lets you prove the pipeline from a browser or curl, without a TCP client.
app.MapPost("/api/messages", (MessageStore s, HttpContext ctx, MessageInput input) =>
{
    if (string.IsNullOrWhiteSpace(input.Body)) return Results.BadRequest("body is required");
    var source = ctx.Connection.RemoteIpAddress?.ToString() ?? "http";
    s.Enqueue($"http:{source}", input.Body.Trim());
    return Results.Accepted();
});

app.MapGet("/api/status", async (MessageStore s, TcpIngestService tcp, AppOptions o, CancellationToken ct) =>
    Results.Ok(new
    {
        greeting = "Hello SafeLife Central",
        tcpPort = o.TcpPort,
        activeSessions = tcp.ActiveConnections,
        stored = await s.CountAsync(ct),
        utc = DateTimeOffset.UtcNow,
    }));

// Cheap liveness probe - no database round trip, so a database blip does not
// get the container killed by a health check.
app.MapGet("/api/health", () => Results.Ok(new { status = "ok" }));

// Anything not matched above is the Angular app (client-side routing).
app.MapFallbackToFile("index.html");

log.LogInformation("Hello SafeLife Central - HTTP on :{Http}, TCP on :{Tcp}",
    options.HttpPort, options.TcpPort);

app.Run();

internal sealed record MessageInput(string Body);
