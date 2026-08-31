#!/usr/bin/env bash
# Opens a session and keeps it open, sending a keep-alive line every N seconds.
# Use it to watch "Open sessions" in the UI, and to prove the idle timeout works:
# set the interval longer than SAFELIFE_IDLE_TIMEOUT_SECONDS and the server hangs up.
#
#   ./hold-open.sh <host> [port] [interval-seconds]

set -euo pipefail

HOST="${1:?usage: hold-open.sh <host> [port] [interval]}"
PORT="${2:-9770}"
INTERVAL="${3:-30}"

echo "Holding a session to $HOST:$PORT, keep-alive every ${INTERVAL}s (ctrl-c to stop)"

{
  while true; do
    printf 'keepalive ts=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sleep "$INTERVAL"
  done
} | nc "$HOST" "$PORT"
