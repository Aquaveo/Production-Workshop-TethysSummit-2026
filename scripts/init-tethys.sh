#!/usr/bin/env bash
set -euo pipefail

export TETHYS_HOME="${TETHYS_HOME:-/var/lib/tethys}"
export STATIC_ROOT="${STATIC_ROOT:-/var/www/tethys/static}"
export MEDIA_ROOT="${MEDIA_ROOT:-/var/www/tethys/media}"
export TETHYS_WORKSPACES_ROOT="${TETHYS_WORKSPACES_ROOT:-/var/www/tethys/workspaces}"

mkdir -p "$TETHYS_HOME" "$STATIC_ROOT" "$MEDIA_ROOT" "$TETHYS_WORKSPACES_ROOT"

if [ ! -f "$TETHYS_HOME/portal_config.yml" ]; then
  echo "Generating $TETHYS_HOME/portal_config.yml"
  tethys gen portal_config
fi

echo "Configuring Tethys portal settings"
tethys settings \
  --set SECRET_KEY "${TETHYS_SECRET_KEY:-change-me-for-production}" \
  --set DEBUG "${TETHYS_DEBUG:-False}" \
  --set ALLOWED_HOSTS "${ALLOWED_HOSTS:-['localhost','127.0.0.1']}" \
  --set CSRF_TRUSTED_ORIGINS "${CSRF_TRUSTED_ORIGINS:-['http://localhost:8080']}" \
  --set STATIC_ROOT "$STATIC_ROOT" \
  --set MEDIA_ROOT "$MEDIA_ROOT" \
  --set TETHYS_WORKSPACES_ROOT "$TETHYS_WORKSPACES_ROOT" \
  --set DATABASES.default.ENGINE django.db.backends.postgresql \
  --set DATABASES.default.NAME "${TETHYS_DB_NAME:-tethys_platform}" \
  --set DATABASES.default.USER "${TETHYS_DB_USERNAME:-tethys}" \
  --set DATABASES.default.PASSWORD "${TETHYS_DB_PASSWORD:-pass}" \
  --set DATABASES.default.HOST "${TETHYS_DB_HOST:-postgres}" \
  --set DATABASES.default.PORT "${TETHYS_DB_PORT:-5432}" \
  --set CHANNEL_LAYERS.default.BACKEND channels_redis.core.RedisChannelLayer \
  --set CHANNEL_LAYERS.default.CONFIG.hosts "[['${REDIS_HOST:-redis}', ${REDIS_PORT:-6379}]]"

# App-specific installs or settings can go here. Examples:
#   pip install /app/path/to/tethysapp_my_app
#   tethys install -d /app/path/to/tethysapp_my_app
#   tethys services create persistent ...
#   tethys app_settings set ...
if [ "${TETHYS_DB_ENGINE}" = "django.db.backends.postgresql" ]; then
        PGPASSWORD="${POSTGRES_PASSWORD:-postgres}" tethys db create
        -n "${TETHYS_DB_USERNAME:-tethys_default}" \
        -p "${TETHYS_DB_PASSWORD:-pass}"
        -N "${TETHYS_DB_SUPERUSER:-tethys_super}"
        -P "${TETHYS_DB_SUPERUSER_PASS:-pass}"
fi

if [ "${RUN_DB_MIGRATIONS:-true}" = "true" ]; then
  echo "Running database migrations"
  tethys db migrate
fi

if [ "${CREATE_SUPERUSER:-true}" = "true" ]; then
  echo "Creating portal superuser . . ."
  tethys db createsuperuser --pn "${PORTAL_SUPERUSER_NAME:-tethys_super}" --pp "${PORTAL_SUPERUSER_PASSWORD:-pass}" --pe "${PORTAL_SUPERUSER_EMAIL}"
fi

if [ "${COLLECT_STATIC:-true}" = "true" ]; then
  echo "Collecting static files"
  tethys manage collectstatic --noinput --clear
fi

if [ "${TETHYS_SITE_CONTENT}" ]; then
  echo "Setting up Tethys Site Configuration"
  tethys site "${TETHYS_SITE_CONTENT}"
fi

touch "$TETHYS_HOME/init_complete"
echo "Tethys init complete"
