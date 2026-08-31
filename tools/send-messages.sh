#!/usr/bin/env bash
# Fire test messages at the SafeLife TCP listener.
#
#   ./send-messages.sh <host> [port] [count]
#
# Each line sent becomes one message. The server answers with its greeting banner
# on connect, which is also a quick way to prove the port is open at all.

set -euo pipefail

HOST="${1:?usage: send-messages.sh <host> [port] [count]}"
PORT="${2:-9770}"
COUNT="${3:-5}"

command -v nc >/dev/null || { echo "netcat (nc) is required" >&2; exit 1; }

echo "Sending $COUNT message(s) to $HOST:$PORT"

{
  for i in $(seq 1 "$COUNT"); do
    printf 'device-%03d alarm=none battery=%d ts=%s\n' \
      "$i" "$(( 60 + RANDOM % 40 ))" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sleep 0.2
  done
  # Hold the socket briefly so the server reads the last line before FIN.
  sleep 1
} | nc "$HOST" "$PORT"

echo "Done. Check the web UI, or: curl -s http://$HOST/api/messages | head"
