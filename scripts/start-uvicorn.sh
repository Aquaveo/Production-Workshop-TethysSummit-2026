#!/usr/bin/env bash
set -euo pipefail

export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-tethys_portal.settings}"

exec uvicorn \
  tethys_portal.asgi:application \
  --host 0.0.0.0 \
  --port "${PORT:-8000}" \
  --workers "${ASGI_PROCESSES:-1}" \
  --proxy-headers \
  --forwarded-allow-ips="${FORWARDED_ALLOW_IPS:-*}"