#!/usr/bin/env bash
# Steady-rate HTTP probe with a live success/failure tally.
#
# Run this in one terminal, then disrupt the web pods in another (rollout restart,
# delete a pod, scale). The point of an HA demo isn't throughput -- it's that the
# FAIL counter stays at 0 while pods are being replaced.
#
#   2xx / 3xx          = success (3xx = a redirect, e.g. -> /accounts/login/)
#   5xx / 000 / timeout = real downtime  <-- this must stay 0 for zero-downtime
#
# Usage:  scripts/ha-probe.sh [URL] [interval-seconds]
#   default URL:      http://localhost:8080/accounts/login/   (hits ASGI -> Django -> DB)
#   default interval: 0.1s
set -uo pipefail

URL="${1:-http://localhost:8080/accounts/login/}"
INTERVAL="${2:-0.1}"

ok=0; redir=0; fail=0; start=$(date +%s)
trap 'echo; echo "── ok=$ok  redirect=$redir  FAIL=$fail  over $(( $(date +%s) - start ))s"; exit 0' INT

echo "probing $URL every ${INTERVAL}s  (Ctrl-C to stop)"
while true; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL" 2>/dev/null || echo 000)
  case "$code" in
    2*) ok=$((ok + 1)) ;;
    3*) redir=$((redir + 1)) ;;
    *)  fail=$((fail + 1)); printf '\n%s  DOWN -> %s\n' "$(date +%T)" "$code" ;;
  esac
  printf '\rok=%d  redirect=%d  FAIL=%d  (last=%s)   ' "$ok" "$redir" "$fail" "$code"
  sleep "$INTERVAL"
done
