# Exoscale deployment runbook — SafeLife Central demo

Everything below is copy-pasteable. Zone is `ch-dk-2` (Zurich, Equinix) throughout; the
other Swiss zone is `ch-gva-2` (Geneva). Keep the database and the instance in the same
zone — cross-zone traffic is neither free nor low-latency, and an Elastic IP can only
attach to instances within its own zone.

Prices are CHF/month excl. VAT, from Exoscale's published price list.

| Resource | Choice | CHF/mo |
|---|---|---|
| Compute instance | `standard.small` — 2 vCPU / 2 GiB | 16.80 |
| Managed Postgres | `hobbyist-2` — 2 vCPU / 2 GiB / 8 GiB disk | 41.84 |
| Elastic IP | one, reserved to the organisation | 10.00 |
| **Total** | | **68.64** |

Add the Network Load Balancer (25.00) when you move to the production shape in step 9.

---

## 0. Prerequisites

```bash
# macOS
brew install exoscale/tap/cli

exo config          # paste API key + secret from the Exoscale portal (IAM → Keys)
exo zone            # sanity check: ch-dk-2 should be listed
```

Set some shell variables so the rest is copy-paste:

```bash
export ZONE=ch-dk-2
export NAME=safelife
export MYIP=$(curl -s https://ifconfig.me)     # your current public address
```

---

## 1. SSH key

```bash
exo compute ssh-key register ${NAME}-key ~/.ssh/id_ed25519.pub
```

## 2. Security group

The edge filter. Port 9770 is the device listener — open it to the world only until
TWIG give you their source ranges, then narrow it.

```bash
exo compute security-group create ${NAME}-sg

# SSH: your address only.
exo compute security-group rule add ${NAME}-sg \
  --flow ingress --protocol tcp --port 22 --network ${MYIP}/32 \
  --description "admin ssh"

# Web UI + ACME challenge.
exo compute security-group rule add ${NAME}-sg \
  --flow ingress --protocol tcp --port 80 --network 0.0.0.0/0 --description "http"
exo compute security-group rule add ${NAME}-sg \
  --flow ingress --protocol tcp --port 443 --network 0.0.0.0/0 --description "https"

# The device port. Replace 0.0.0.0/0 with TWIG's ranges when you have them.
exo compute security-group rule add ${NAME}-sg \
  --flow ingress --protocol tcp --port 9770 --network 0.0.0.0/0 \
  --description "TWIG device listener"
```

## 3. Managed Postgres

```bash
exo dbaas create pg hobbyist-2 ${NAME}-db --zone $ZONE --pg-ip-filter ${MYIP}/32
```

Creation takes a couple of minutes. Then read the connection details:

```bash
exo dbaas show ${NAME}-db --zone $ZONE
exo dbaas show ${NAME}-db --zone $ZONE --uri     # full postgres:// URI
```

> The URI is for `psql`. The application builds its connection string from the
> individual parts, because **Npgsql does not parse a `postgres://` URI** — that is the
> single most common first-run failure with any managed Postgres.

## 4. Instance

```bash
exo compute instance create ${NAME}-app \
  --zone $ZONE \
  --instance-type standard.small \
  --template "Linux Ubuntu 24.04 LTS 64-bit" \
  --disk-size 20 \
  --ssh-key ${NAME}-key \
  --security-group ${NAME}-sg \
  --cloud-init deploy/cloud-init.yaml

exo compute instance show ${NAME}-app --zone $ZONE     # note the public IP
export APPIP=<the public IP>
```

Cloud-init installs Docker, applies the firewall and the TCP sysctls, and registers a
`safelife` systemd unit. Give it two or three minutes.

## 5. Let the database accept the instance

The DBaaS IP filter currently allows only your laptop.

```bash
exo dbaas update ${NAME}-db --zone $ZONE --pg-ip-filter ${MYIP}/32,${APPIP}/32
```

## 6. Configure and start

```bash
# Deployment files
scp deploy/docker-compose.yml deploy/Caddyfile ubuntu@$APPIP:/tmp/
ssh ubuntu@$APPIP 'sudo mv /tmp/docker-compose.yml /tmp/Caddyfile /opt/safelife/'

# Image + site address
ssh ubuntu@$APPIP 'sudo tee /opt/safelife/.env >/dev/null' <<EOF
IMAGE=ghcr.io/chadgates/safelife-central-demo:latest
SITE_ADDRESS=:80
EOF

# Database credentials — from step 3. Keep this file 0600.
ssh ubuntu@$APPIP 'sudo tee /etc/safelife/app.env >/dev/null && sudo chmod 600 /etc/safelife/app.env' < deploy/app.env   # your filled-in copy

# Pull and run
ssh ubuntu@$APPIP 'cd /opt/safelife && sudo docker compose pull && sudo systemctl start safelife'
```

### Registry authentication

**This demo's package is public, so the pull above works with no credentials.** The real
image will not be — the developer's repository will be private — so this step is the
production path, not a fallback. Do it before the `docker compose pull`:

```bash
# Keep the token in a local file, mode 600 - never on a command line, never in
# shell history, and never visible in ps output on either machine.
printf '%s' 'ghp_xxxxxxxxxxxxxxxxxxxx' > ~/.ghcr-token && chmod 600 ~/.ghcr-token

ssh ubuntu@$APPIP 'sudo docker login ghcr.io -u x-access-token --password-stdin' < ~/.ghcr-token
```

Four things that decide whether this works on the day:

**Use a classic PAT.** GitHub Packages authenticates only with a *personal access token
(classic)*. Fine-grained tokens do not work — they have no `read:packages` scope at all and
the pull fails with 403. Create it at Settings → Developer settings → Tokens (classic).

**Scope it to `read:packages` and nothing else.** The token sits on a server. It should not
be able to touch code, and it should not be anyone's personal token — issue a dedicated one
for this host.

**`-u x-access-token` rather than a username.** It works for both personal and
organisation-owned packages, so the same command survives the image moving from the
developer's account into a company org.

**Mind the expiry.** A classic PAT with an expiry date will make a future
`docker compose pull` fail — quietly, because the running container keeps serving until
something restarts it. Either issue it without an expiry (acceptable only because the scope
is read-only) or diarise the rotation.

The credential persists in `/root/.docker/config.json`, so reboots and
`systemctl restart safelife` keep working without logging in again. Note it is stored
**base64-encoded, not encrypted** — anyone with root on this box can read it, which is the
reason for the narrow scope above.

### Getting access to the developer's package

If the image lives in the developer's account or org rather than yours, a token alone is not
enough — the package has to grant your account read access. This is the step most likely to
block the first real deployment, so raise it early:

- **Their side:** package → Package settings → Manage access → add your account (or a shared
  machine account) with *Read*.
- **Or:** they issue a `read:packages` token from an account that already has access, and you
  use that. Simpler to arrange, harder to rotate cleanly.
- **Ask which it will be as part of the commercial agreement**, alongside who owns the
  registry namespace long term. Moving the image later means re-pointing `IMAGE=` on every
  host and re-issuing tokens.

## 7. Prove it works

```bash
curl -s http://$APPIP/api/health           # {"status":"ok"}
curl -s http://$APPIP/api/status           # greeting, tcpPort, activeSessions, stored

./tools/send-messages.sh $APPIP 9770 5     # five messages over TCP
open http://$APPIP                         # the Angular page, refreshing every 2s
```

Watch the logs while you do it:

```bash
ssh ubuntu@$APPIP 'sudo docker logs -f safelife-app'
```

Two behaviours worth checking deliberately, because they are the ones that matter at
fleet scale:

```bash
./tools/hold-open.sh $APPIP 9770 30     # session stays open, "Open sessions" shows 1
./tools/hold-open.sh $APPIP 9770 400    # exceeds the 300s idle timeout: server hangs up
```

## 8. A real hostname and HTTPS

Point an A record at `$APPIP`, then:

```bash
ssh ubuntu@$APPIP "sudo sed -i 's|SITE_ADDRESS=:80|SITE_ADDRESS=safelife.example.ch|' /opt/safelife/.env"
ssh ubuntu@$APPIP 'cd /opt/safelife && sudo docker compose up -d'
```

Caddy obtains and renews the certificate on its own. Nothing else changes — it is
already reverse-proxying to the app.

---

## 9. The production shape: an address that outlives the machine

Everything above puts the device port on the *instance's* public IP. That address dies
with the instance, which is unacceptable once the address is written into device
configurations in the field.

Exoscale Elastic IPs are **created for the organisation and stay until you delete them** —
they are not a property of any instance. That is the property Nine does not offer at all,
and it is the reason to be here.

```bash
# A managed EIP: Exoscale health-checks the backends and only routes to healthy ones.
# No configuration inside the VM (a manual EIP would need the address on the NIC).
exo compute elastic-ip create --zone $ZONE \
  --healthcheck-mode tcp \
  --healthcheck-port 9770 \
  --healthcheck-interval 10 \
  --healthcheck-timeout 5 \
  --healthcheck-strikes-fail 3 \
  --healthcheck-strikes-ok 2

export EIP=<the address it printed>
exo compute instance elastic-ip attach ${NAME}-app $EIP --zone $ZONE
```

**Give TWIG `$EIP`, never the instance IP.** To replace the box later: build the new
instance, attach the same EIP, detach the old one. The fleet never learns anything changed.

For real redundancy, move to an Instance Pool behind a Network Load Balancer — a genuine
Layer 4 TCP balancer that keeps a given source IP pinned to one backend, which is what you
want for long-lived sessions. Two constraints to design around: an NLB targets **Instance
Pools only**, not an arbitrary list of instances, and its address counts against your
Elastic IP quota.

```bash
exo compute instance-pool create ${NAME}-pool \
  --zone $ZONE --size 2 \
  --instance-type standard.small \
  --template "Linux Ubuntu 24.04 LTS 64-bit" \
  --disk-size 20 --ssh-key ${NAME}-key \
  --security-group ${NAME}-sg --cloud-init deploy/cloud-init.yaml

exo compute load-balancer create ${NAME}-nlb --zone $ZONE
exo compute load-balancer service add ${NAME}-nlb twig \
  --zone $ZONE --instance-pool ${NAME}-pool \
  --port 9770 --target-port 9770 --protocol tcp \
  --healthcheck-mode tcp --healthcheck-port 9770

exo compute load-balancer show ${NAME}-nlb --zone $ZONE    # the device-facing IP
```

**Confirm with Exoscale support before provisioning devices:** whether an existing Elastic
IP can front an NLB, or whether the NLB always brings its own address — and whether that
address survives the NLB being deleted and recreated. It is a five-minute question with a
very expensive wrong answer.

---

## Teardown

```bash
exo compute instance delete ${NAME}-app --zone $ZONE
exo dbaas delete ${NAME}-db --zone $ZONE
exo compute elastic-ip delete $EIP --zone $ZONE
exo compute security-group delete ${NAME}-sg
```

Billing is hourly, so a demo left running over a weekend costs a couple of francs.
