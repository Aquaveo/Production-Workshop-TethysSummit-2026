#!/usr/bin/env bash
set -euo pipefail

# Provision a Tethys persistent store with a LEAST-PRIVILEGE role (Option B).
#
# Tethys uses ONE service for both the privileged DDL (`syncstores` -> CREATE DATABASE)
# and the app's runtime queries. If you provision with a superuser, the app then RUNS as
# that superuser. Instead we use `tethys_app`: a role with CREATEDB but NOT superuser, so
# `syncstores` can create the store database, the app OWNS its own tables, and at runtime
# the app connects as a non-privileged role -- no superuser, no post-hoc GRANTs.
#
# Usage:
#   provision-persistent-store.sh <app_package> <ps_database_setting_name>
# Example:
#   provision-persistent-store.sh my_loadtest_app demo_db
#
# Prereqsuisites:
#   - The app declares a PersistentStoreDatabaseSetting named <ps_database_setting_name>
#     in app.py (spatial=False -- a spatial store would need a superuser for CREATE EXTENSION).
#   - Migrations have run (the portal DB holds the services/links tables).
#   - Run it where the portal config + DB are reachable, e.g.:
#       docker compose exec tethys-web provision-persistent-store.sh <app> <setting>
#       kubectl -n tethys-k8 exec deploy/tethys-web -- provision-persistent-store.sh <app> <setting>
#
# IMPORTANT: connects DIRECT to Postgres, never the pooler. `syncstores` runs CREATE
# DATABASE (DDL the transaction-mode pooler can't carry), and the new store DB name
# isn't routed by the pooler anyway. (Runtime pooling of the store is optional and not
# done here -- the store's SQLAlchemy engine already pools per process.)

APP="${1:?usage: provision-persistent-store.sh <app_package> <ps_database_setting_name>}"
SETTING="${2:?usage: provision-persistent-store.sh <app_package> <ps_database_setting_name>}"

SERVICE_NAME="${TETHYS_APP_PS_SERVICE:-tethys_app_ps}"
DB_USER="${TETHYS_APP_DB_USERNAME:-tethys_app}"
DB_PASS="${TETHYS_APP_DB_PASSWORD:-pass}"
DB_HOST="${TETHYS_APP_DB_HOST:-${TETHYS_DB_HOST:-postgres}}"   # DIRECT primary, not the pooler
DB_PORT="${TETHYS_DB_PORT:-5432}"

echo "==> 1/3 Persistent-store service '${SERVICE_NAME}' -> ${DB_USER}@${DB_HOST}:${DB_PORT} (direct)"
# Idempotent-ish: creating a service that already exists errors; don't abort the run for that.
tethys services create persistent \
  -n "${SERVICE_NAME}" \
  -c "${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}" \
  || echo "    (service '${SERVICE_NAME}' may already exist -- continuing)"

echo "==> 2/3 Linking service to ${APP}:ps_database:${SETTING}"
tethys link "persistent:${SERVICE_NAME}" "${APP}:ps_database:${SETTING}" \
  || echo "    (link may already exist -- continuing)"

echo "==> 3/3 syncstores ${APP}  (creates <app>_${SETTING}, owned by ${DB_USER})"
tethys syncstores "${APP}"

echo "Done. '${APP}' persistent store provisioned with least-privilege role '${DB_USER}' (no superuser)."
