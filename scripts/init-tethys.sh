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
#   - static     -> jsDelivr CDN (dev/publish-static.sh + STATIC_URL in portal_config.yml)
#
# All three steps are idempotent, so this runs cleanly on every `docker compose up`
# and picks up edits to conf/portal_config.yml (no init_complete guard needed).

/usr/local/bin/portal-config.sh        # renders with DB host = TETHYS_DB_HOST (postgres, direct)
/usr/local/bin/db-migrations.sh        # migrations/DDL run DIRECT (bypass the txn-mode pooler)
/usr/local/bin/portal-bootstrap.sh

# Point the web tier at the transaction-mode pooler. The DDL above ran direct against
# Postgres; web (which reads this same shared portal_config.yml) now goes through PgBouncer.
# Mirrors k8s, where the web pods' configure step sets HOST=<pooler> while the init Job uses
# the direct primary. Skip the flip if no pooler is configured.
if [ -n "${TETHYS_POOLER_HOST:-}" ]; then
  echo "Repointing portal_config.yml DB host at the pooler (${TETHYS_POOLER_HOST}) for the web tier"
  tethys settings --set DATABASES.default.HOST "${TETHYS_POOLER_HOST}"
fi

echo "Tethys init complete"
