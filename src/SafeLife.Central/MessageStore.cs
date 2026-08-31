using System.Threading.Channels;
using Npgsql;

namespace SafeLife.Central;

public sealed record Message(long Id, DateTimeOffset ReceivedAt, string Source, string Body);

/// <summary>
/// Writes are queued on a channel and flushed in batches by a single background writer.
/// At 2000 devices sending every 30s that is ~66 inserts/second - trivial in batches, but
/// a stall waiting for the pool if you insert one row per message per session.
/// </summary>
public sealed class MessageStore : BackgroundService
{
    private const int BatchSize = 200;
    private static readonly TimeSpan FlushInterval = TimeSpan.FromMilliseconds(500);

    private readonly Channel<(string Source, string Body)> _queue =
        Channel.CreateBounded<(string, string)>(new BoundedChannelOptions(50_000)
        {
            // Never block a device session on the database. If we are this far behind,
            // shedding the oldest queued row is the honest failure mode.
            FullMode = BoundedChannelFullMode.DropOldest,
        });

    private readonly NpgsqlDataSource _dataSource;
    private readonly ILogger<MessageStore> _log;

    public MessageStore(AppOptions options, ILogger<MessageStore> log)
    {
        _log = log;
        _dataSource = new NpgsqlDataSourceBuilder(options.ConnectionString).Build();
    }

    /// <summary>Non-blocking: enqueue a message for the batch writer.</summary>
    public void Enqueue(string source, string body) => _queue.Writer.TryWrite((source, body));

    public async Task EnsureSchemaAsync(CancellationToken ct)
    {
        await using var cmd = _dataSource.CreateCommand("""
            CREATE TABLE IF NOT EXISTS messages (
                id          bigserial     PRIMARY KEY,
                received_at timestamptz   NOT NULL DEFAULT now(),
                source      text          NOT NULL,
                body        text          NOT NULL
            );
            CREATE INDEX IF NOT EXISTS messages_id_desc_idx ON messages (id DESC);
            """);
        await cmd.ExecuteNonQueryAsync(ct);
        _log.LogInformation("Schema ready");
    }

    public async Task<IReadOnlyList<Message>> GetLatestAsync(int limit, CancellationToken ct)
    {
        await using var cmd = _dataSource.CreateCommand(
            "SELECT id, received_at, source, body FROM messages ORDER BY id DESC LIMIT $1");
        cmd.Parameters.AddWithValue(limit);

        var results = new List<Message>(limit);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            results.Add(new Message(
                reader.GetInt64(0),
                reader.GetFieldValue<DateTimeOffset>(1),
                reader.GetString(2),
                reader.GetString(3)));
        }
        return results;
    }

    public async Task<long> CountAsync(CancellationToken ct)
    {
        await using var cmd = _dataSource.CreateCommand("SELECT count(*) FROM messages");
        return (long)(await cmd.ExecuteScalarAsync(ct) ?? 0L);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var batch = new List<(string Source, string Body)>(BatchSize);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                // Wait for at least one item, then drain up to BatchSize without blocking.
                if (!await _queue.Reader.WaitToReadAsync(stoppingToken)) break;

                batch.Clear();
                while (batch.Count < BatchSize && _queue.Reader.TryRead(out var item))
                    batch.Add(item);

                if (batch.Count > 0) await FlushAsync(batch, stoppingToken);

                await Task.Delay(FlushInterval, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                // A database blip must not kill the writer, or ingest silently stops.
                _log.LogError(ex, "Batch insert failed; retrying shortly");
                await Task.Delay(TimeSpan.FromSeconds(2), CancellationToken.None);
            }
        }
    }

    private async Task FlushAsync(List<(string Source, string Body)> batch, CancellationToken ct)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);

        foreach (var (source, body) in batch)
        {
            await using var cmd = new NpgsqlCommand(
                "INSERT INTO messages (source, body) VALUES ($1, $2)", conn, tx);
            cmd.Parameters.AddWithValue(source);
            cmd.Parameters.AddWithValue(body);
            await cmd.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
        _log.LogDebug("Flushed {Count} message(s)", batch.Count);
    }

    public override void Dispose()
    {
        _dataSource.Dispose();
        base.Dispose();
    }
}
