#!/usr/bin/env bash
#
# Deploy from here, because GitHub cannot.
#
# The security group allows SSH from one address - yours - so a GitHub runner cannot reach
# the instance. This does everything the deploy workflow would have: ships the compose files,
# pins the image tag, pulls, optionally migrates, restarts, and checks the result.
#
#   ./tools/deploy.sh                    deploy :latest
#   ./tools/deploy.sh --tag sha-abc123   deploy an immutable tag
#   ./tools/deploy.sh --migrate          run the migration step before switching over
#   ./tools/deploy.sh --env              also push deploy/app.env (secrets - deliberate only)
#
# Host and key are worked out from $APPIP / $SSHKEY, or from the Terraform state.

set -euo pipefail

TAG="latest"
MIGRATE=0
PUSH_ENV=0

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)     TAG="${2:?--tag needs a value}"; shift 2 ;;
    --migrate) MIGRATE=1; shift ;;
    --env)     PUSH_ENV=1; shift ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

REPO=$(git rev-parse --show-toplevel)
cd "$REPO"

# --- work out where we are deploying to -------------------------------------------------
KEY="${SSHKEY:-$HOME/.ssh/exoscale_safelife}"
HOST="${APPIP:-}"
if [ -z "$HOST" ] && [ -d infra ]; then
  TF=$(command -v tofu || command -v terraform || true)
  [ -n "$TF" ] && HOST=$("$TF" -chdir=infra output -raw instance_ip 2>/dev/null || true)
fi

# An empty variable here becomes ubuntu@ and a hostname that cannot be resolved, several
# steps after the real problem. Refuse instead.
[ -n "$HOST" ] || { echo "ERROR: no host. Set APPIP, or run from a checkout with infra/ state." >&2; exit 1; }
[ -f "$KEY" ]  || { echo "ERROR: ssh key not found: $KEY  (set SSHKEY)" >&2; exit 1; }

# Portable: strip any .git suffix, then take the last two path components. BSD sed has no
# non-greedy operator, so do not reach for one here.
OWNER_REPO=$(git remote get-url origin | sed 's#\.git$##' | awk -F'[/:]' '{print tolower($(NF-1) "/" $NF)}')
IMAGE="ghcr.io/${OWNER_REPO}:${TAG}"

SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

echo "host   : $HOST"
echo "image  : $IMAGE"
echo "migrate: $([ $MIGRATE -eq 1 ] && echo yes || echo no)"
echo

"${SSH[@]}" "ubuntu@$HOST" true || { echo "ERROR: cannot reach $HOST. Has your public IP changed? Compare with admin_cidr in infra/terraform.tfvars." >&2; exit 1; }

# --- compose files: copies on the host, so repo edits mean nothing until sent ------------
echo "shipping docker-compose.yml and Caddyfile"
scp -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
    deploy/docker-compose.yml deploy/Caddyfile "ubuntu@$HOST:/tmp/" >/dev/null
"${SSH[@]}" "ubuntu@$HOST" 'sudo mv /tmp/docker-compose.yml /tmp/Caddyfile /opt/safelife/'

# --- secrets, only when asked -----------------------------------------------------------
if [ $PUSH_ENV -eq 1 ]; then
  [ -f deploy/app.env ] || { echo "ERROR: deploy/app.env not found" >&2; exit 1; }
  echo "pushing deploy/app.env"
  "${SSH[@]}" "ubuntu@$HOST" 'sudo tee /etc/safelife/app.env >/dev/null && sudo chmod 600 /etc/safelife/app.env' < deploy/app.env
else
  # Warn rather than act: a stale local file silently overwriting live credentials is worse
  # than a mismatch you were told about.
  LOCAL=$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' deploy/app.env 2>/dev/null | tr -d '=' | sort || true)
  REMOTE=$("${SSH[@]}" "ubuntu@$HOST" "sudo grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' /etc/safelife/app.env | tr -d '='" 2>/dev/null | sort || true)
  if [ -n "$LOCAL" ] && [ "$LOCAL" != "$REMOTE" ]; then
    echo "note: deploy/app.env and the host differ in which keys are set."
    diff <(echo "$LOCAL") <(echo "$REMOTE") | sed 's/^</  only local : /; s/^>/  only host  : /' | grep -E 'only (local|host)' || true
    echo "      run with --env to push the local file."
  fi
fi

# --- pin, pull, migrate, restart --------------------------------------------------------
echo "pinning image on the host"
"${SSH[@]}" "ubuntu@$HOST" "sudo sed -i 's|^IMAGE=.*|IMAGE=${IMAGE}|' /opt/safelife/.env"

echo "pulling"
"${SSH[@]}" "ubuntu@$HOST" 'cd /opt/safelife && sudo docker compose pull app'

if [ $MIGRATE -eq 1 ]; then
  echo "migrating"
  "${SSH[@]}" "ubuntu@$HOST" 'cd /opt/safelife && sudo docker compose run --rm app ./efbundle' \
    || { echo "ERROR: migration failed - the previous version is still serving" >&2; exit 1; }
fi

echo "restarting"
"${SSH[@]}" "ubuntu@$HOST" 'cd /opt/safelife && sudo docker compose up -d --remove-orphans'

# --- did it actually come back? ---------------------------------------------------------
SITE=$("${SSH[@]}" "ubuntu@$HOST" "grep -oP '(?<=^SITE_ADDRESS=).*' /opt/safelife/.env" 2>/dev/null || true)
case "$SITE" in
  ""|:80|:*) URL="http://$HOST" ;;
  *)         URL="https://$SITE" ;;
esac

echo -n "checking $URL/api/health "
for i in $(seq 1 30); do
  if curl -fsS --max-time 5 "$URL/api/health" >/dev/null 2>&1; then
    echo "-> ok after ${i}s"
    curl -fsS "$URL/api/status" 2>/dev/null || true
    echo
    exit 0
  fi
  sleep 1
  echo -n "."
done
echo
echo "ERROR: $URL/api/health did not answer within 30s" >&2
"${SSH[@]}" "ubuntu@$HOST" 'sudo docker logs --tail 30 safelife-app' >&2 || true
exit 1
