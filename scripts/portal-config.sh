#!/usr/bin/env bash
set -euo pipefail

# Render the portal config for this pod.
#
# The portal config is now declarative: it comes from the mounted tethys-portal-config
# ConfigMap (portal_config.yml). This script only:
#   1. copies that file into TETHYS_HOME, and
#   2. injects the values that must NOT live in a ConfigMap - secrets, plus the
#      environment-specific DB host (the init Job sets TETHYS_DB_HOST=tethys-postgres-rw
#      to bypass the transaction-mode pooler for migrations).
#
# => Changing any Django/portal setting is just an edit to portal_config.yml + re-apply.
#    No image rebuild, because this script never enumerates settings.

export TETHYS_HOME="${TETHYS_HOME:-/var/lib/tethys}"
export TETHYS_PERSIST="${TETHYS_PERSIST:-/var/lib/tethys_persist}"
export STATIC_ROOT="${STATIC_ROOT:-/var/www/tethys/static}"
export MEDIA_ROOT="${MEDIA_ROOT:-/var/www/tethys/media}"
export TETHYS_WORKSPACES_ROOT="${TETHYS_WORKSPACES_ROOT:-/var/www/tethys/workspaces}"

# Where the ConfigMap is mounted (see the configure initContainer volumeMount).
PORTAL_CONFIG_SRC="${PORTAL_CONFIG_SRC:-/config/portal_config.yml}"

mkdir -p "$TETHYS_HOME" "$TETHYS_PERSIST" "$STATIC_ROOT" "$MEDIA_ROOT" "$TETHYS_WORKSPACES_ROOT"

echo "Applying portal config from $PORTAL_CONFIG_SRC"
cp "$PORTAL_CONFIG_SRC" "$TETHYS_HOME/portal_config.yml"

# Inject secrets (never stored in the ConfigMap).
tethys settings \
  --set SECRET_KEY "${TETHYS_SECRET_KEY:?TETHYS_SECRET_KEY is required (from tethys-secret)}" \
  --set DATABASES.default.PASSWORD "${TETHYS_DB_PASSWORD:?TETHYS_DB_PASSWORD is required (from tethys-db-app)}"

# Environment-specific DB host override (Job -> direct primary; web pods -> pooler).
if [ -n "${TETHYS_DB_HOST:-}" ]; then
  tethys settings --set DATABASES.default.HOST "$TETHYS_DB_HOST"
fi

echo "Tethys portal config applied."
