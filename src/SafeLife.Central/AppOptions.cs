namespace SafeLife.Central;

/// <summary>
/// Everything the app needs, read from the environment. The deployment sets these in
/// /etc/safelife/app.env - nothing is baked into the image.
/// </summary>
public sealed class AppOptions
{
    /// <summary>
    /// Port the device listener binds. 9770 is unassigned by IANA and sits below the
    /// Linux ephemeral range (32768-60999), so it cannot collide with an outbound
    /// socket's source port. Change it here and in the security group together.
    /// </summary>
    public int TcpPort { get; init; } = 9770;

    /// <summary>HTTP port for the API and the SPA. Caddy reverse-proxies to this.</summary>
    public int HttpPort { get; init; } = 8080;

    /// <summary>Close a device session that has sent nothing for this long.</summary>
    public TimeSpan IdleTimeout { get; init; } = TimeSpan.FromMinutes(5);

    /// <summary>Hard cap on concurrent sessions, so a bug cannot exhaust the box.</summary>
    public int MaxConnections { get; init; } = 2500;

    /// <summary>Longest single message accepted before the connection is dropped.</summary>
    public int MaxMessageBytes { get; init; } = 8 * 1024;

    public string ConnectionString { get; init; } = "";

    /// <summary>
    /// Public address the outside world reaches us on. Twilio signs the exact URL it was
    /// configured with, and behind Caddy the app only sees http://localhost:8080 - so
    /// webhook signature validation needs this told to it explicitly.
    /// </summary>
    public string PublicBaseUrl { get; init; } = "";

    /// <summary>
    /// Whether each optional channel has credentials present. Presence only - this app is a
    /// dummy and sends nothing. Deliberately never exposes the values themselves.
    /// </summary>
    public bool SmsConfigured { get; init; }
    public bool SmsUsesApiKey { get; init; }
    public bool SmsSignatureValidation { get; init; }
    public bool EmailConfigured { get; init; }

    public static AppOptions FromEnvironment()
    {
        static string Env(string key, string fallback = "") =>
            Environment.GetEnvironmentVariable(key) is { Length: > 0 } v ? v : fallback;

        static int EnvInt(string key, int fallback) =>
            int.TryParse(Env(key), out var v) ? v : fallback;

        // Built from parts on purpose: Npgsql does not parse a postgres:// URI, which is
        // the shape most managed providers hand you - Exoscale's DBaaS included.
        var host = Env("PGHOST", "localhost");
        var port = EnvInt("PGPORT", 5432);
        var database = Env("PGDATABASE", "defaultdb");
        var user = Env("PGUSER", "postgres");
        var password = Env("PGPASSWORD");

        // Managed Postgres refuses plaintext. Exoscale presents a certificate from its own
        // CA, so either trust it (default here) or mount the CA and switch to VerifyCA.
        var sslMode = Env("PGSSLMODE", "Require");
        var trustCert = Env("PGTRUSTSERVERCERT", "true");

        var connectionString =
            $"Host={host};Port={port};Database={database};Username={user};Password={password};" +
            $"SSL Mode={sslMode};Trust Server Certificate={trustCert};" +
            // Deliberately well under the ~20-connection limit of entry-tier managed Postgres.
            $"Maximum Pool Size={EnvInt("PGMAXPOOL", 8)};Timeout=10;Command Timeout=30";

        // Twilio: an account SID plus either the auth token or an API key pair.
        // The auth token is separately required for inbound webhook signature validation,
        // which is HMAC-SHA1 keyed on the token specifically - an API key will not do.
        var twilioSid = Env("TWILIO_ACCOUNT_SID");
        var twilioToken = Env("TWILIO_AUTH_TOKEN");
        var twilioKeySid = Env("TWILIO_API_KEY_SID");
        var twilioKeySecret = Env("TWILIO_API_KEY_SECRET");
        var hasApiKey = twilioKeySid.Length > 0 && twilioKeySecret.Length > 0;

        return new AppOptions
        {
            PublicBaseUrl = Env("PUBLIC_BASE_URL"),
            SmsConfigured = twilioSid.Length > 0 && (twilioToken.Length > 0 || hasApiKey),
            SmsUsesApiKey = hasApiKey,
            SmsSignatureValidation =
                Env("TWILIO_VALIDATE_SIGNATURES", "true").Equals("true", StringComparison.OrdinalIgnoreCase),
            EmailConfigured = Env("SENDGRID_API_KEY").Length > 0,

            TcpPort = EnvInt("SAFELIFE_TCP_PORT", 9770),
            HttpPort = EnvInt("SAFELIFE_HTTP_PORT", 8080),
            IdleTimeout = TimeSpan.FromSeconds(EnvInt("SAFELIFE_IDLE_TIMEOUT_SECONDS", 300)),
            MaxConnections = EnvInt("SAFELIFE_MAX_CONNECTIONS", 2500),
            MaxMessageBytes = EnvInt("SAFELIFE_MAX_MESSAGE_BYTES", 8 * 1024),
            ConnectionString = connectionString,
        };
    }
}
