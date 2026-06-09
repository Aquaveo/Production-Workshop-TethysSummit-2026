#!/usr/bin/env bash
set -euo pipefail

# Runs once, in the Job's main container, AFTER the migrate initContainer.
# Safe to do DB writes here (tables exist) and it never runs in web pods.

# tethys db createsuperuser is idempotent (it catches IntegrityError when the
# user already exists and exits 0), so this is safe to re-run on Job retries.
if [ "${CREATE_SUPERUSER:-true}" = "true" ]; then
  echo "Creating portal superuser . . ."
  tethys db createsuperuser --pn "${PORTAL_SUPERUSER_NAME:-admin}" --pp "${PORTAL_SUPERUSER_PASSWORD:-pass}" --pe "${PORTAL_SUPERUSER_EMAIL:-}"
fi

# Apply site/branding settings from portal_config.yml (the `site_settings:` block).
# These are DB-backed, so they run after migrations. `tethys site -f` reads
# $TETHYS_HOME/portal_config.yml; empty values are skipped, and it's idempotent.
echo "Applying site settings from portal_config.yml"
tethys site -f

echo "Portal bootstrap complete!"
