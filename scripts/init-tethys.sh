#!/usr/bin/env bash
set -euo pipefail

# Compose init -- mirrors the k8s init Job, reusing the SAME three scripts so the
# two deployments stay in lockstep. Settings + branding are declarative now (they
# live in the mounted portal_config.yml), so this script no longer enumerates
# `tethys settings --set` or translates SITE_* env vars into `tethys site` flags.
#
#   1. portal-config.sh    copy the mounted /config/portal_config.yml into TETHYS_HOME
#                          and inject the secrets + DB host (SECRET_KEY, DB PASSWORD/HOST)
#   2. db-migrations.sh    tethys db migrate
#   3. portal-bootstrap.sh create the portal superuser + apply site/branding
#                          (`tethys site -f` reads the site_settings: block)
#
# Handled elsewhere (same as k8s), so intentionally NOT here:
#   - DB + roles -> Postgres on first boot (conf/postgres-initdb/10-create-tethys-db.sh)
#   - static     -> jsDelivr CDN (scripts/publish-static.sh + STATIC_URL in portal_config.yml)
#
# All three steps are idempotent, so this runs cleanly on every `docker compose up`
# and picks up edits to conf/portal_config.yml (no init_complete guard needed).

/usr/local/bin/portal-config.sh
/usr/local/bin/db-migrations.sh
/usr/local/bin/portal-bootstrap.sh

echo "Tethys init complete"
