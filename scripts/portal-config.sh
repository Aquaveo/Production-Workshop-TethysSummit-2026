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

export TETHYS_HOME="${TETHYS_HOME:-/home/tethys/portal}"
export TETHYS_PERSIST="${TETHYS_PERSIST:-/home/tethys/persist}"
export STATIC_ROOT="${STATIC_ROOT:-/home/tethys/persist/static}"
export MEDIA_ROOT="${MEDIA_ROOT:-/home/tethys/persist/media}"
export TETHYS_WORKSPACES_ROOT="${TETHYS_WORKSPACES_ROOT:-/home/tethys/persist/workspaces}"

# Where the ConfigMap is mounted (see the configure initContainer volumeMount).
PORTAL_CONFIG_SRC="${PORTAL_CONFIG_SRC:-/config/portal_config.yml}"

mkdir -p "$TETHYS_HOME" 

echo "Applying portal config from $PORTAL_CONFIG_SRC"
cp "$PORTAL_CONFIG_SRC" "$TETHYS_HOME/portal_config.yml"

# Inject the values that must NOT live in the ConfigMap -- secrets, plus the
# environment-specific DB host (Job -> direct primary; web pods -> pooler).
#
# Built as one `tethys settings` invocation on purpose: each call cold-boots all of
# Tethys/Django (seconds), and this script runs in the k8s `configure` initContainer
# on EVERY web pod start, so we boot once, not once-per-setting.
set_args=(
  --set SECRET_KEY "${TETHYS_SECRET_KEY:?TETHYS_SECRET_KEY is required (from tethys-secret)}"
  --set DATABASES.default.PASSWORD "${TETHYS_DB_PASSWORD:?TETHYS_DB_PASSWORD is required (from tethys-db-app)}"
)
if [ -n "${TETHYS_DB_HOST:-}" ]; then
  set_args+=(--set DATABASES.default.HOST "$TETHYS_DB_HOST")
fi

tethys settings "${set_args[@]}"

echo "Tethys portal config applied."
