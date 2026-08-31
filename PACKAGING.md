# Packaging brief for the SafeLife Central service

**For:** the developer building the SafeLife/TWIG service
**From:** the team operating it on Exoscale
**Status:** requirements, not suggestions — the deployment is already built against them

We run your image on a Swiss Exoscale host with managed PostgreSQL, a reserved public IP for
the devices, and Caddy terminating TLS. We do not need your source code. We need **one
container image** that behaves as described below.

A working reference implementation of every requirement here is public:
**https://github.com/chadgates/safelife-central-demo** — a dummy app with the same shape
(TCP listener + API + AngularJS page + Postgres), verified running on Exoscale. When a
requirement below is unclear, that repository is the answer.

---

## How to use this file with Claude

Drop this file into your repository root and point Claude Code at it:

> Read PACKAGING.md. Audit this repository against every requirement R1–R34 and produce a
> table of pass / fail / not-applicable with the file and line for each finding. Do not
> change anything yet.

Then, once you agree with its assessment:

> Implement the failing requirements from PACKAGING.md. Start with the R1–R8 group
> (container and configuration), then R9–R16 (the device listener), then R25–R34 (the
> messaging channels). Show me the diff for each group before moving on.

The requirements are numbered so you and Claude can refer to them precisely, and so our
acceptance check (bottom of this file) maps one-to-one onto them. R1–R24 are the service
itself; R25–R34 cover the Twilio SMS and SendGrid email channels.

---

## 1. Shape

**R1 — One image, one process.** A single ASP.NET Core host serves the HTTP API, serves the
built frontend as static files, and runs the device listener as an `IHostedService` /
`BackgroundService`. One PID, one log stream, one health signal. No `supervisord`, no `s6`, no
two processes in one container.

*If you believe this must be split into separate containers, say so early with your reasoning
— it changes our deployment, so we need to know before you build it, not after.*

**R2 — Multi-stage Dockerfile at the repository root.** We build from source in CI; we never
need the .NET SDK, Node, or your toolchain locally. The frontend build stage must produce its
output into the app's `wwwroot`.

**R3 — No network access at runtime beyond Postgres and outbound HTTPS.** Specifically: the
frontend must not fetch libraries from a CDN at page load. Bundle or vendor them. The demo
vendors `angular.min.js` into `wwwroot/vendor/` for exactly this reason.

**R4 — Non-root.** Use the base image's app user (`USER $APP_UID` on .NET 8+). Both listening
ports are above 1024, so root is never required.

**R5 — .NET 10.** .NET 9 left support in May 2026. Target `net10.0` and use the
`mcr.microsoft.com/dotnet/sdk:10.0` / `aspnet:10.0` images.

**R6 — `.dockerignore`** excluding `bin/`, `obj/`, `.git/`, and anything else that has no
business in the build context.

---

## 2. Configuration — the interface we depend on

**R7 — Everything from environment variables.** No secrets in the image, no environment-specific
`appsettings.*.json` baked in. We inject an env file at deploy time.

**R8 — These exact variable names.** Our deployment already writes them. Renaming one means
changing our infrastructure, so treat them as fixed:

| Variable | Meaning | Default if unset |
|---|---|---|
| `PGHOST` | Postgres hostname | `localhost` |
| `PGPORT` | Postgres port | `5432` |
| `PGDATABASE` | database name | `defaultdb` |
| `PGUSER` | username | — |
| `PGPASSWORD` | password | — |
| `PGSSLMODE` | `Require` in every deployed environment | `Require` |
| `PGTRUSTSERVERCERT` | `true` — see R20 | `true` |
| `PGMAXPOOL` | Npgsql maximum pool size | `8` |
| `SAFELIFE_HTTP_PORT` | HTTP port for API + frontend | `8080` |
| `SAFELIFE_TCP_PORT` | device listener port | `9770` |
| `SAFELIFE_IDLE_TIMEOUT_SECONDS` | drop a silent session after this | `300` |
| `SAFELIFE_MAX_CONNECTIONS` | hard cap on concurrent sessions | `2500` |

Read them with sane defaults so the container also runs on a developer laptop with nothing
set but the `PG*` values.

---

## 3. The device listener — where the real risk is

The devices open **raw TCP** sessions and hold them open for hours. Trial scale is ~100
devices; other deployments run **~2000 devices per port**. Four of the requirements below sit
right at that number, and each one is cheap now and painful to retrofit.

**R9 — Bind `0.0.0.0:$SAFELIFE_TCP_PORT`.** Not localhost.

**R10 — Fully async, never a thread per connection.** `AcceptTcpClientAsync`, `ReadAsync`, and
never `Task.Run` wrapped around a synchronous read. 2000 blocking reads means 2000 threads and
roughly 2 GB of thread stacks — more memory than the host has. Done properly, 2000 sessions
costs tens of megabytes.

**R11 — Never await the per-connection handler inside the accept loop.** That serialises
everything.

**R12 — Frame messages properly.** One read is not one message: a message can arrive split
across two reads, and two messages can arrive in one read. Use `System.IO.Pipelines`
(`PipeReader` + `SequenceReader`) or an equivalent buffered framer. Confirm with TWIG whether
the delimiter is newline, a length prefix, or something else — the demo assumes newline.

**R13 — Explicit accept backlog.** `TcpListener.Start()` defaults to 512. A power cut or
carrier blip reconnects the whole fleet in one burst and the tail gets connection-refused.
Pass an explicit backlog of at least 1024. We set `net.core.somaxconn` on the host to match.

**R14 — Idle read timeout.** Devices vanish without sending FIN — flat battery, no coverage.
Without a read deadline the server holds half-open sessions forever and the descriptor count
only grows. Reset the deadline on every read; drop the session past
`SAFELIFE_IDLE_TIMEOUT_SECONDS`. Ask TWIG for the device keep-alive interval and make sure
the default is comfortably longer than it.

**R15 — Hard connection cap** at `SAFELIFE_MAX_CONNECTIONS`, so a bug cannot exhaust the host.

**R16 — Capture the real client IP per session** and attach it to every stored message and log
line. We run the container on the host network specifically so this survives — do not
undermine it by taking the address from a proxy header.

**R17 — Pooled buffers.** A dedicated 8 KB read buffer per connection is 16 MB of idle memory
at 2000 devices, and worse with a write buffer too. `ArrayPool<byte>` or Pipelines' own
buffers.

**R18 — A per-connection log scope** carrying the device identifier or source address, so a
single device's traffic can be followed in the logs.

---

## 4. Database

**R19 — Build the connection string from the parts in R8.** Do **not** try to parse a
`postgres://` URI — Npgsql does not accept one, and that is the single most common first-run
failure with managed Postgres.

**R20 — TLS is mandatory and the certificate is provider-signed.** Managed Postgres refuses
plaintext, and the CA does not match the hostname, so hostname verification must be off:
`SSL Mode=Require;Trust Server Certificate=true`. If you would rather pin the CA, we can
mount it — tell us and we will.

**R21 — Batch writes; respect a small connection pool.** Entry-tier managed Postgres allows
about 20 connections *in total*, shared across the app, the listener and any migration run.
At 2000 devices sending every 30 seconds that is ~66 inserts/second — trivial in batches,
but one `INSERT` per message per session will fight over the pool and stall the accept loop.
Push parsed messages onto a `Channel` and have one or two consumers insert in batches.

**R22 — Migrations as a separate one-shot command in the same image.** Either
`dotnet ef migrations bundle` producing an `efbundle` executable, or an entrypoint flag such
as `--migrate`. We run it before switching traffic, so a failed migration leaves the previous
version running. Do **not** migrate on startup in every replica.

**R23 — Nothing durable on local disk.** The container filesystem is ephemeral and small. If
the service needs to store files (uploads, exports, generated documents), tell us — that
needs object storage, and it changes the deployment.

**R24 — Graceful shutdown and an honest health endpoint.** Honour `SIGTERM`: stop accepting,
let in-flight work finish, close cleanly. Expose a liveness endpoint that does **not** touch
the database, so a database blip does not get the container killed and restarted in a loop.

---

## 4b. Messaging channels — Twilio SMS and SendGrid email

SMS is the backup path when a device's TCP session is dead; email is a notification channel.
The deployment already carries the variables below — read them, do not invent new names for
the same things.

**R25 — These exact variable names.**

| Variable | Meaning |
|---|---|
| `PUBLIC_BASE_URL` | the address the outside world reaches us on, scheme included |
| `TWILIO_ACCOUNT_SID` | account SID |
| `TWILIO_AUTH_TOKEN` | account auth token — required for webhook signature validation |
| `TWILIO_API_KEY_SID` / `TWILIO_API_KEY_SECRET` | preferred credentials for outbound REST calls |
| `TWILIO_MESSAGING_SERVICE_SID` | messaging service, preferred over a fixed number |
| `TWILIO_FROM_NUMBER` | E.164 sender, used only when no messaging service is set |
| `TWILIO_VALIDATE_SIGNATURES` | `true` everywhere except a local dev box |
| `SENDGRID_API_KEY` | SendGrid key, scoped to Mail Send only |
| `SENDGRID_FROM_EMAIL` / `SENDGRID_FROM_NAME` | sender identity |

**R26 — Prefer API keys for sending, but still require the auth token.** Inbound webhook
signatures are HMAC-SHA1 keyed on the *account auth token* specifically — an API key cannot
verify them. So: API key for the REST client where present, auth token for validation. Fall
back to account SID + auth token for sending if no API key is configured.

**R27 — Validate every inbound webhook signature.** Use the Twilio SDK's own validator, never
a hand-rolled HMAC. Reject with 403 on failure. Twilio publishes no webhook source IP ranges —
they are deliberately dynamic — so the signature is the *only* access control on that endpoint.
Honour `TWILIO_VALIDATE_SIGNATURES` so it can be disabled locally, and make the application log
loudly at startup when it is off.

**R28 — Compute the signature against `PUBLIC_BASE_URL`, not the incoming request.** We
terminate TLS at Caddy, so the application sees `http://localhost:8080` and would build the
wrong URL — `https` versus `http` alone breaks validation. Either construct the validation URL
from `PUBLIC_BASE_URL` + path + query, or configure
`ForwardedHeadersOptions` (`XForwardedProto`, `XForwardedHost`) and verify the result matches.
This is the single most common inbound-webhook failure.

**R29 — Inbound webhook path: `POST /api/sms/inbound`.** Form-encoded, as Twilio sends it.
Respond `204` or valid TwiML quickly — Twilio times out, and slow handlers become retries.
Do the real work off the request path (queue it, as with the TCP ingest in R21). Tell us if you
need a different path so we can confirm it before the number is configured.

**R30 — Delivery status webhook: `POST /api/sms/status`,** same validation rules. Without it
you cannot distinguish "sent" from "delivered", which matters when SMS is the fallback for a
device that is already unreachable.

**R31 — Treat both channels as unavailable at any moment.** Twilio and SendGrid are third
parties on the far side of the internet. Timeouts, retries with backoff, and a circuit breaker
— and never block a device session or an HTTP request on an outbound message send.

**R32 — Never log or echo the credentials.** No secrets in log lines, error messages, or any
API response. Where it helps to show configuration state, report *presence* only — the demo's
`/api/status` shows `"sms": "configured (api key)"` and never a value.

**R33 — Idempotency on inbound.** Twilio retries on timeout or a non-2xx response, so the same
message can arrive more than once. Deduplicate on `MessageSid`.

**R34 — Store the phone number as an identity, not a display string.** E.164, normalised on the
way in. And say clearly how a device maps to a number, because the SMS path has no TCP session
to attribute a message to — this is a data-model question we should agree together.

---

## 5. What you deliver

1. **A repository** containing the source, the `Dockerfile`, and a CI workflow that builds
   and pushes the image on every push to your main branch.
2. **The image in a registry we can pull from.** GHCR is what we are set up for. If your
   repository is private — we assume it will be — we need either:
   - read access on the *package* for a GitHub account we nominate, or
   - a **classic** personal access token scoped to `read:packages` only.
     (Fine-grained tokens do not work with GHCR: they have no `read:packages` scope and the
     pull fails with 403.)
   Tell us which, and whether the package inherits permissions from the repository or uses
   granular per-package access — they behave differently and it decides what we ask for.
3. **A tagging scheme.** `latest` on the main branch plus an immutable tag per commit
   (`sha-<full-sha>` or a semver tag). We deploy immutable tags and keep `latest` for
   convenience.
4. **The env var contract**, if you need anything beyond R8. New variables are fine; we just
   have to know about them before the deploy, not during.
5. **A way to send a synthetic device message** — a script or documented byte sequence — so
   we can prove the path end to end without real hardware.
6. **Migration command**, exactly as we should invoke it (R22).
7. **The webhook paths** you settle on (R29, R30), so we can configure the Twilio number and
   confirm TLS is in place before the first message is sent to it. Inbound SMS makes a real
   hostname with a certificate mandatory rather than optional.

## 6. What we provide

The Exoscale instance and its firewall, managed PostgreSQL with credentials, the reserved
public IP the devices connect to, Caddy with automatic TLS, log rotation, host kernel tuning
for the connection count, and the deployment runbook. You should never need to touch the
server.

---

## 7. How we will check the image

Run against a throwaway Postgres, before it goes near the real host. This is the whole
acceptance test — nothing hidden:

```bash
IMAGE='ghcr.io/you/your-service:latest'      # quoted: bare <angle-brackets> are shell redirection

docker run -d --name pg -e POSTGRES_PASSWORD=dev -p 5432:5432 postgres:17

docker run -d --name app \
  -e PGHOST=host.docker.internal -e PGDATABASE=postgres \
  -e PGUSER=postgres -e PGPASSWORD=dev \
  -e PGSSLMODE=Disable -e PGTRUSTSERVERCERT=false \
  -p 8080:8080 -p 9770:9770 "$IMAGE"

docker exec app id                      # R4  - not root
curl -s localhost:8080/api/health       # R24 - ok without touching the database
curl -s localhost:8080/                 # R2  - the frontend is served

printf 'hello\n' | nc localhost 9770    # R9  - the listener accepts
curl -s localhost:8080/api/messages     # R19/R21 - the message was stored

# R12 - framing: 150 messages in one burst must all arrive
{ for i in $(seq 1 150); do printf 'bulk-%03d\n' $i; done; sleep 1; } | nc localhost 9770

# R10/R11/R15 - 200 concurrent sessions, all counted, none leaked
for i in $(seq 1 200); do { printf 'session-%03d\n' $i; sleep 8; } | nc localhost 9770 & done

# R14 - a session idle past the timeout is dropped by the server, not left half-open

# R25/R32 - credentials arrive and are never echoed. Presence only in the response.
docker rm -f app >/dev/null; docker run -d --name app \
  -e PGHOST=host.docker.internal -e PGDATABASE=postgres -e PGUSER=postgres -e PGPASSWORD=dev \
  -e PGSSLMODE=Disable -e PGTRUSTSERVERCERT=false \
  -e PUBLIC_BASE_URL=https://example.test \
  -e TWILIO_ACCOUNT_SID=ACtest -e TWILIO_AUTH_TOKEN=tok_secret \
  -e SENDGRID_API_KEY=SG.secret \
  -p 8080:8080 -p 9770:9770 "$IMAGE"
sleep 8
curl -s localhost:8080/api/status | grep -c 'tok_secret\|SG.secret'   # must be 0

# R27/R28 - an unsigned POST to the webhook must be rejected
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/api/sms/inbound \
  -d 'From=%2B41000000000&Body=test&MessageSid=SMtest'                 # must be 403
```

If the 150-message burst loses messages, R12 is not implemented. If the 200 concurrent
sessions balloon memory, R10 is not implemented. Those two are the ones that pass a casual
test and fail in the field.

---

## 8. Open questions we need answered with you

These are not packaging decisions but they shape the code, so raise them early:

- **The wire protocol.** Message delimiter, maximum message size, character encoding, and
  whether the device expects an application-level acknowledgement or treats the TCP write as
  delivery.
- **Keep-alive interval**, which sets the idle timeout in R14.
- **Reconnect behaviour** on the device side: immediate retry, backoff, buffered messages? It
  decides whether a host restart loses data or merely delays it.
- **Message rate and payload size per device.** Our storage sizing currently assumes ~200
  bytes every 30 seconds; at 2000 devices that is roughly 1.2 GB and 5.8 million rows a day,
  which needs daily partitioning and a retention policy.
- **Alarm versus telemetry.** The demo drops the oldest queued rows if the database is
  unreachable — the honest failure mode for telemetry and the wrong one for alarms. If any
  message is an alarm, we need to agree what "delivered" means before it is built.
- **When SMS takes over from TCP.** What counts as a dead session, how long we wait, whether
  the device or the platform decides, and whether a message can arrive on both paths and need
  deduplicating. This is the actual design of the backup channel, and it is not a packaging
  question.
- **How a phone number maps to a device** (R34). The SMS path has no TCP session to attribute
  a message to, so the identity has to come from somewhere.
