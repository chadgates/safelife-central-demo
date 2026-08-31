# SafeLife Central — deployment demo

A deliberately small stand-in for the real TWIG service, built so the **deployment** can be
proven end to end while the application source is still with the developer. Every shape
decision here matches what the real system will need; only the business logic is a dummy.

```
   TWIG device                      ┌─────────────────────────────────────┐
   (or netcat)  ──── raw TCP ──────▶│  one container, one .NET process    │
                     :9770          │                                     │
                                    │   TcpIngestService  (BackgroundSvc) │
   Browser ──── HTTPS ──▶ Caddy ───▶│   Minimal API       (/api/*)        │──▶ Managed
                          :80/443   │   AngularJS SPA     (wwwroot)       │    Postgres
                                    └─────────────────────────────────────┘    (Exoscale)
```

## What it does

- **TCP listener on port 9770.** Newline-delimited messages, one session per device.
  Answers every new connection with `Hello SafeLife Central`.
- **Backend API** storing each message in PostgreSQL and serving the last 100.
- **AngularJS front end** polling every 2 seconds, always showing the last 100 messages.
- **One container.** The .NET app is compiled during the Docker build, so nobody needs
  the SDK locally, and GitHub Actions pushes the image to GHCR.

Port 9770 was picked because it is unassigned by IANA and sits below the Linux ephemeral
range (32768–60999), so it cannot collide with an outbound socket's source port.

## Verified

Built and run end to end on 30 August 2026 against PostgreSQL 17, on .NET 10 (LTS —
.NET 9 left support in May 2026):

| Check | Result |
|---|---|
| `dotnet build -c Release` | 0 warnings, 0 errors |
| `docker build` | 371 MB image, runs as non-root (uid 1654) |
| TCP greeting on connect | `Hello SafeLife Central` |
| 150 messages in one burst | all parsed — framing survives a split read |
| `/api/messages?limit=100` | returns exactly 100, newest first, of 155 stored |
| 100 concurrent sessions | all counted, all stored, back to 0 with no leak |
| SPA + assets + fallback route | 200 |

## Repository layout

```
src/SafeLife.Central/
  Program.cs             API endpoints, DI, static files
  TcpIngestService.cs    the device listener
  MessageStore.cs        batched writes + last-100 query
  AppOptions.cs          all configuration, from environment variables
  wwwroot/               AngularJS 1.8.3 (vendored — no npm step)
deploy/
  RUNBOOK.md             ← the Exoscale deployment, copy-pasteable
  cloud-init.yaml        Docker, firewall, TCP sysctls
  docker-compose.yml     app + Caddy, host networking
  Caddyfile              reverse proxy, automatic HTTPS
  app.env.example        database credentials template
tools/
  send-messages.sh       fire N test messages
  hold-open.sh           hold a session open / prove the idle timeout
.github/workflows/       build and push to ghcr.io
```

## Getting it running

**1. Push this repo to GitHub.** The workflow builds on every push to `main` and publishes
`ghcr.io/chadgates/safelife-central-demo:latest`. Make the package public (Packages → settings →
visibility)
so the server can pull without credentials.

**2. Follow [`deploy/RUNBOOK.md`](deploy/RUNBOOK.md).** About fifteen minutes, ~CHF 69/month
if left running, hourly billing if not.

**3. Send it something.**

```bash
./tools/send-messages.sh <host> 9770 5
printf 'hello from the field\n' | nc <host> 9770
curl -s http://<host>/api/messages | head
```

### Running it locally instead

Any Postgres will do — the app creates its own table on first boot.

```bash
docker run -d --name pg -e POSTGRES_PASSWORD=dev -p 5432:5432 postgres:17

PGHOST=localhost PGDATABASE=postgres PGUSER=postgres PGPASSWORD=dev \
PGSSLMODE=Disable PGTRUSTSERVERCERT=false \
dotnet run --project src/SafeLife.Central
```

Then <http://localhost:8080>, and `printf 'local test\n' | nc localhost 9770`.

## The parts that are not dummy

These exist because they are the things that break at 2000 concurrent sessions, and they
are far cheaper to build in now than to retrofit:

| | Why |
|---|---|
| `PipeReader` framing | A message split across two reads still parses. One read ≠ one message. |
| Explicit accept backlog (1024) | A carrier blip reconnects the whole fleet at once; the default 512 refuses the tail. |
| `nofile` 65535 in compose | Docker's default soft limit is often 1024 — it starts refusing connections at ~1000 devices. |
| Host networking | Docker's userland proxy can rewrite the device's source IP to the bridge gateway. |
| Idle read timeout | Devices vanish without sending FIN; half-open sessions otherwise accumulate forever. |
| Connection cap | A bug cannot exhaust the box. |
| Batched writes via a `Channel` | ~66 inserts/second at fleet scale, through a pool of 8, without stalling the accept loop. |
| Connection string built from parts | Npgsql does not parse the `postgres://` URI that managed providers hand you. |
| `Trust Server Certificate=true` | Managed Postgres refuses plaintext and presents a certificate from its own CA. |

## What this demo deliberately leaves out

- **Migrations.** The table is created at startup. A real service runs migrations as a
  deploy step, not on every replica.
- **Retention.** 2000 devices produce roughly 1.2 GB/day. Production needs daily
  partitions and a retention job — the `hobbyist-2` database here holds about a week.
- **Authentication.** The API and the page are open. Put Caddy basic auth in front, or a
  real identity provider, before this is reachable by anyone who matters.
- **Backpressure to the device.** Messages are acknowledged by being read, not by being
  stored. If the database is down the queue drops the oldest rows rather than blocking
  the listener — the honest failure mode for telemetry, the wrong one for alarms.
