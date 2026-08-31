using System.Buffers;
using System.IO.Pipelines;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace SafeLife.Central;

/// <summary>
/// The device-facing listener. Newline-delimited messages, one session per device, held
/// open for hours. Written the way the real one has to be written:
///   - fully async, never a thread per connection
///   - PipeReader framing, so a message split across reads still parses
///   - an idle deadline, because devices vanish without sending FIN
///   - a hard connection cap
///   - the real client IP captured per session
/// </summary>
public sealed class TcpIngestService : BackgroundService
{
    private static readonly byte[] Greeting =
        Encoding.UTF8.GetBytes("Hello SafeLife Central\r\n");

    private readonly AppOptions _options;
    private readonly MessageStore _store;
    private readonly ILogger<TcpIngestService> _log;
    private readonly SemaphoreSlim _slots;

    private int _active;
    public int ActiveConnections => Volatile.Read(ref _active);

    public TcpIngestService(AppOptions options, MessageStore store, ILogger<TcpIngestService> log)
    {
        _options = options;
        _store = store;
        _log = log;
        _slots = new SemaphoreSlim(options.MaxConnections, options.MaxConnections);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var listener = new TcpListener(IPAddress.Any, _options.TcpPort);

        // Explicit backlog: the default is 512, and a carrier blip reconnects the whole
        // fleet at once. Pair this with net.core.somaxconn on the host.
        listener.Start(backlog: 1024);
        _log.LogInformation("TWIG listener accepting on 0.0.0.0:{Port}", _options.TcpPort);

        stoppingToken.Register(listener.Stop);

        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(stoppingToken);

                // Never await the handler here - that would serialise the accept loop.
                _ = HandleClientAsync(client, stoppingToken);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            // Normal shutdown.
        }
        finally
        {
            listener.Stop();
            _log.LogInformation("TWIG listener stopped");
        }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken stoppingToken)
    {
        var remote = (client.Client.RemoteEndPoint as IPEndPoint)?.Address.ToString() ?? "unknown";

        if (!await _slots.WaitAsync(TimeSpan.Zero, stoppingToken))
        {
            _log.LogWarning("Connection cap reached, refusing {Remote}", remote);
            client.Close();
            return;
        }

        Interlocked.Increment(ref _active);
        using var scope = _log.BeginScope("device={Remote}", remote);
        _log.LogInformation("Session opened ({Active} active)", ActiveConnections);

        try
        {
            client.NoDelay = true;
            using (client)
            await using (var stream = client.GetStream())
            {
                await stream.WriteAsync(Greeting, stoppingToken);
                await ReadLoopAsync(stream, remote, stoppingToken);
            }
        }
        catch (OperationCanceledException)
        {
            _log.LogInformation("Session closed (idle timeout or shutdown)");
        }
        catch (IOException)
        {
            _log.LogInformation("Session closed by peer");
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Session failed");
        }
        finally
        {
            Interlocked.Decrement(ref _active);
            _slots.Release();
        }
    }

    private async Task ReadLoopAsync(Stream stream, string remote, CancellationToken stoppingToken)
    {
        var reader = PipeReader.Create(stream);

        while (true)
        {
            // Reset the idle deadline on every read: a device that keeps talking stays open,
            // one that goes quiet past the timeout is dropped rather than leaked.
            using var idle = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
            idle.CancelAfter(_options.IdleTimeout);

            var result = await reader.ReadAsync(idle.Token);
            var buffer = result.Buffer;

            while (TryReadLine(ref buffer, out var line))
            {
                var text = Encoding.UTF8.GetString(line).TrimEnd('\r');
                if (text.Length == 0) continue;

                if (text.Length > _options.MaxMessageBytes)
                {
                    _log.LogWarning("Message over {Max} bytes, dropping session",
                        _options.MaxMessageBytes);
                    return;
                }

                _log.LogInformation("Message: {Body}", text);
                _store.Enqueue(remote, text);
            }

            reader.AdvanceTo(buffer.Start, buffer.End);

            if (result.IsCompleted) break;
        }

        await reader.CompleteAsync();
    }

    /// <summary>Pulls one newline-terminated frame out of the (possibly segmented) buffer.</summary>
    private static bool TryReadLine(ref ReadOnlySequence<byte> buffer, out ReadOnlySequence<byte> line)
    {
        var position = buffer.PositionOf((byte)'\n');
        if (position is null)
        {
            line = default;
            return false;
        }

        line = buffer.Slice(0, position.Value);
        buffer = buffer.Slice(buffer.GetPosition(1, position.Value));
        return true;
    }
}
