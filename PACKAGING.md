# Packaging brief for the SafeLife Central service

**For:** the developer building the SafeLife/TWIG service
**From:** the team operating it on Exoscale
**Status:** the deployment is already built against these. Where one turns out to be about
your design rather than ours, say so and we will drop it — several already have been.

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

> Read PACKAGING.md. Audit this repository against every requirement R1–R38 and produce a
> table of pass / fail / not-applicable with the file and line for each finding. Do not
> change anything yet.

Then, once you agree with its assessment:

> Implement the failing requirements from PACKAGING.md. Start with R1–R8 (container and
> configuration), then R9–R18 (the device listener), then R25–R33 (messaging) and R34–R38
> (authentication). Show me the diff for each group before moving on.

The requirements are numbered so you and Claude can refer to them precisely, and so our
acceptance check (bottom of this file) maps one-to-one onto them. R1–R24 are the service
itself, R25–R33 the Twilio and SendGrid channels, R34–R38 user authentication.

Where a requirement reads like we are designing your application, we are not — say so and we
will drop it. The test is whether it changes what the deployment has to do.

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

**R8 — You name them; tell us what they are.** An earlier version of this brief dictated flat
names (`PGHOST`, `TWILIO_AUTH_TOKEN`). That was overreach — the deployment writes
`KEY=value` lines into an env file, and it does not care what the keys are called. Use the
.NET convention if that is what fits your code:

```
ConnectionStrings__SafeLife = Host=...;Port=...;Database=...;Username=...;Password=...;SSL Mode=Require;Trust Server Certificate=true
Twilio__AccountSid          = ...
Twilio__AuthToken           = ...
Twilio__From                = ...
SendGrid__ApiKey            = ...
SendGrid__From              = ...
```

Verified end to end: mixed case, the `__` separator, and values containing `;`, `=`, `.` and
spaces all pass through an `env_file` into the container unaltered. Nothing needs escaping.

What we do need from you is **the list**: every key, what it is for, and which service reads
it. We write them into a `0600` file on the host and nothing else. Two asks that are about the
deployment rather than your design:

- **Defaults for everything non-secret**, so the container starts on a laptop with only the
  connection strings set.
- **Fail fast and loudly on a missing secret.** A service that starts happily and only fails
  when the first SMS is sent turns a config typo into a production incident.



---

## 3. The device listener — capacity, not design

How you parse the protocol and what you do with a message is entirely yours. What we care
about is that the service fits the host we sized: the devices open **raw TCP** sessions and
hold them open for hours, at ~100 devices for the trial and **~2000 per port** in real
deployments.

So read R9–R18 as a **capacity budget**: 2000 concurrent sessions inside roughly 300 MB of
working set, surviving a whole-fleet reconnect. The specific techniques are how our reference
implementation hits that budget, and you are free to hit it another way — but four of them sit
right at the 2000 mark, which is why they are called out rather than left implicit.

**R9 — Bind `0.0.0.0` on the configured device port.** Not localhost.

**R10 — Fully async, never a thread per connection.** `AcceptTcpClientAsync`, `ReadAsync`, and
never `Task.Run` wrapped around a synchronous read. 2000 blocking reads means 2000 threads and
roughly 2 GB of thread stacks — more memory than the host has. Done properly, 2000 sessions
costs tens of megabytes.

**R11 — Never await the per-connection handler inside the accept loop.** That serialises
everything.

**R12 — Frame messages properly.** One read is not one message: a message can arrive split
across two reads, and two messages can arrive in one read. Use `System.IO.Pipelines`
(`PipeReader` + `SequenceReader`) or an equivalent buffered framer. The protocol itself is
yours; the demo assumes newline delimiters purely as an example.

**R13 — Explicit accept backlog.** `TcpListener.Start()` defaults to 512. A power cut or
carrier blip reconnects the whole fleet in one burst and the tail gets connection-refused.
Pass an explicit backlog of at least 1024. We set `net.core.somaxconn` on the host to match.

**R14 — Idle read timeout.** Devices vanish without sending FIN — flat battery, no coverage.
Without a read deadline the server holds half-open sessions forever and the descriptor count
only grows. Reset the deadline on every read and drop the session once it expires. Make the
timeout configurable — we set it from TWIG's keep-alive interval, and it must be comfortably
longer than that.

**R15 — Hard connection cap**, configurable, so a bug cannot exhaust the host.

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

**R19 — The database connection string is ours to supply, not yours to compose.** We run the
Postgres, so we hand you a finished Npgsql connection string to drop under whichever
`ConnectionStrings__*` key you use. `tofu output -raw connection_string_dotnet` emits it,
already carrying the three settings that are easy to get wrong:

```
Host=…;Port=…;Database=…;Username=…;Password=…;
SSL Mode=Require;Trust Server Certificate=true;Maximum Pool Size=8
```

**Use `ConnectionStrings__SafeLife` for now.** R8 leaves naming to you, and that still holds —
but a working default beats a placeholder, so take this one unless your code wants otherwise.
It is generated, not typed: the key comes from the `connection_string_name` variable in our
Terraform, so changing it later is one variable and a re-run, not a negotiation.

Do **not** compose one from a `postgres://` URI — Npgsql does not parse that form, and it is
the single most common first-run failure with managed Postgres. If the service also needs to
reach a database we do not run, tell us early: that is an egress and firewall question, and
possibly a data-residency one.

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

**R25 — Same rule as R8: your names, told to us.** One deployable service, so the container
gets the union of the keys below. *SmsGateway* and *AlertForwarder* name the two outbound
channels inside the application, not two things we deploy:

| Channel | Keys |
|---|---|
| SMS (Twilio) | `Twilio__AccountSid`, `Twilio__AuthToken`, `Twilio__From` |
| Email (SendGrid) | `SendGrid__ApiKey`, `SendGrid__From` |
| Database | one `ConnectionStrings__*` entry — **value supplied by us**, see R19 |

Plus one the deployment has to add, because only we know it: the **public base URL** the
service is reached on. Name it whatever suits — `PublicBaseUrl` alongside the rest would be
consistent. Twilio signs the exact URL it was configured with, and behind our reverse proxy
the application sees `http://localhost:8080`, so it cannot work this out for itself. See R28.

**R26 — Prefer API keys for sending, but still require the auth token.** Inbound webhook
signatures are HMAC-SHA1 keyed on the *account auth token* specifically — an API key cannot
verify them. So: API key for the REST client where present, auth token for validation. Fall
back to account SID + auth token for sending if no API key is configured.

**R27 — Validate every inbound webhook signature.** Use the Twilio SDK's own validator, never
a hand-rolled HMAC. Reject with 403 on failure. Twilio publishes no webhook source IP ranges —
they are deliberately dynamic — so the signature is the *only* access control on that endpoint.
Make it switchable so it can be disabled on a developer laptop, and log loudly at startup
whenever it is off.

**R28 — Compute the signature against the configured public base URL, not the incoming request.** We
terminate TLS at Caddy, so the application sees `http://localhost:8080` and would build the
wrong URL — `https` versus `http` alone breaks validation. Either construct the validation URL
from the configured base URL + path + query, or configure
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

**R33 — Survive Twilio's retries.** Twilio re-sends on timeout or a non-2xx response, so the
same webhook can arrive more than once. How you deduplicate is yours — `MessageSid` is the
obvious key. We mention it only because we configure the webhook, and therefore cause the
retries.

---

## 4c. User authentication — Microsoft Entra External ID

Azure AD B2C closed to new customers on **1 May 2025**, so the CIAM product is **Microsoft
Entra External ID**, in an **external tenant** (not a workforce tenant). We register the app
and supply the configuration; you consume it.

**R34 — Configuration keys.** External tenants use `Authority` against the `ciamlogin` host —
*not* `Instance` + `TenantId`, which is the workforce-tenant shape and the most common early
mistake:

| Key | Value |
|---|---|
| `AzureAd__Authority` | `https://<tenant>.ciamlogin.com/<tenant-id>` |
| `AzureAd__ClientId` | supplied by us |
| `AzureAd__ClientSecret` | supplied by us, in the `0600` env file |
| `AzureAd__CallbackPath` | `/signin-oidc` |
| `AzureAd__SignedOutCallbackPath` | `/signout-callback-oidc` |

Rename the section if your code prefers something else — tell us what, per R8.

**R35 — Honour the reverse proxy, or sign-in cannot work.** We terminate TLS at Caddy and
proxy to the container over plain HTTP, so the app sees `http://localhost:8080`. Left alone,
ASP.NET Core builds a `redirect_uri` of `http://localhost:8080/signin-oidc`, which matches
nothing registered and fails the flow. Configure `ForwardedHeadersOptions` for
`XForwardedProto` and `XForwardedHost`, with `KnownProxies` or `KnownNetworks` set so the
headers are only trusted from our proxy. This is the same trap as the Twilio webhook URL in
R28 — one cause, two symptoms.

**R36 — Persist the data protection key ring in the database.** ASP.NET Core encrypts auth
cookies with keys that default to the container filesystem, which is ephemeral: every deploy
regenerates them and signs every user out.

The obvious fix is a mounted volume, and it is the wrong one here. **A named volume lives on
one instance, and the instance is disposable by design** — the whole architecture rests on the
Elastic IP outliving the machine, so that a rebuild is routine. A key ring on the instance dies
with it, taking every session with it. The same applies the moment there is a second instance:
one cannot decrypt a cookie issued by the other.

So use `PersistKeysToDbContext` against the Postgres we already run. It survives instance
replacement and multiple instances alike, and adds no infrastructure.

If you deliberately choose the filesystem instead, say so — we then need to add a volume to
the compose file *and* a writable directory owned by the app user in your image, because a
volume mounted onto a path absent from the image is created root-owned and a non-root app
cannot write to it.

**R37 — Cookies.** `HttpOnly`, `Secure`, `SameSite=Lax` — `Lax` rather than `Strict` because
the OIDC redirect arrives as a cross-site top-level navigation and `Strict` drops the
correlation cookie, producing a sign-in loop that is thoroughly unpleasant to debug.

**R38 — Sign-out must be federated.** Clearing the local cookie leaves the Entra session
intact, so the next sign-in completes silently and the user appears not to have signed out at
all. Redirect to the end-session endpoint.

### A recommendation, not a requirement

The frontend is AngularJS 1.x. MSAL's Angular wrapper supports Angular 2+ only, so
browser-side authentication means `msal-browser` plus hand-rolled PKCE, silent renew and token
storage in a framework from 2010.

Since the same .NET process already serves the SPA from the same origin, the
**backend-for-frontend** shape is both simpler and stronger: the backend runs the OIDC code
flow and issues an encrypted `HttpOnly` cookie, and the SPA calls `/api/*` on the same origin
with no token in JavaScript at all. It is your call — we mention it because it removes work
rather than adding it.

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
CS='Host=host.docker.internal;Port=5432;Database=postgres;Username=postgres;Password=dev;SSL Mode=Disable'

docker run -d --name pg -e POSTGRES_PASSWORD=dev -p 5432:5432 postgres:17

docker run -d --name app \
  -e "ConnectionStrings__SafeLife=$CS" \
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

# R25/R32 - credentials arrive and are never echoed anywhere in a response
docker rm -f app >/dev/null
docker run -d --name app \
  -e "ConnectionStrings__SafeLife=$CS" \
  -e PublicBaseUrl=https://example.test \
  -e Twilio__AccountSid=ACtest -e Twilio__AuthToken=tok_secret \
  -e SendGrid__ApiKey=SG.secret \
  -p 8080:8080 -p 9770:9770 "$IMAGE"
sleep 8
curl -s localhost:8080/api/status | grep -c 'tok_secret\|SG.secret'   # must be 0

# R27/R28 - an unsigned POST to the webhook must be rejected
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/api/sms/inbound \
  -d 'From=%2B41000000000&Body=test&MessageSid=SMtest'                 # must be 403

# R35 - behind a proxy the app must build https://... redirect URIs, not http://localhost:8080
curl -s -o /dev/null -w '%{redirect_url}\n' \
  -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-Host: example.test' \
  localhost:8080/signin-oidc
```

If the 150-message burst loses messages, R12 is not implemented. If the 200 concurrent
sessions balloon memory, R10 is not implemented. Those two are the ones that pass a casual
test and fail in the field.

---

## 8. What we need to know to configure the deployment

Not design questions — these are the values we type into infrastructure. Everything else about
how the service works is yours.

| We need | Because it sets |
|---|---|
| **Device port** | the Exoscale security group rule, and the port we configure |
| **Device source IP ranges**, if TWIG will give them | whether the device port is open to the world or narrowed |
| **Device keep-alive interval** | the idle-read timeout, which must be comfortably longer |
| **Peak concurrent sessions** per deployment | instance size, `nofile`, accept backlog, the connection cap |
| **Message rate and stored size per device** | the database tier, disk, and retention policy |
| **Whether anything is written to disk** | whether we need object storage — the container filesystem is ephemeral |
| **Webhook paths** for inbound SMS and status | what we configure on the Twilio number, and it makes TLS mandatory |
| **Migration command**, verbatim | the deploy step |
| **Any env vars beyond R8 and R25** | the env file we write on the host |

Our current sizing assumes ~200 bytes per message every 30 seconds per device, and 2000
devices per port. At that rate it is roughly 1.2 GB and 5.8 million rows a day, which needs
daily partitioning and a retention policy. If your real numbers differ by much, tell us —
that is a database tier decision, not a code one.
