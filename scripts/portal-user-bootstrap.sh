#!/usr/bin/env bash
set -euo pipefail

# tethys db createsuperuser is idempotent (it catches IntegrityError when the
# user already exists and exits 0), so this is safe to re-run on Job retries.
if [ "${CREATE_SUPERUSER:-true}" = "true" ]; then
  echo "Creating portal superuser . . ."
  tethys db createsuperuser --pn "${PORTAL_SUPERUSER_NAME:-admin}" --pp "${PORTAL_SUPERUSER_PASSWORD:-pass}" --pe "${PORTAL_SUPERUSER_EMAIL}"
fi

echo "Portal user bootstrap complete!"
