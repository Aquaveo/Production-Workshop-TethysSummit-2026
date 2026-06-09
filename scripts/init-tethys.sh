#!/usr/bin/env bash
set -euo pipefail

if [ -f "$TETHYS_HOME/init_complete" ]; then
  echo "Tethys already initialized, skipping setup"
  exit 0
fi

export TETHYS_HOME="${TETHYS_HOME:-/home/tethys/portal}"
export STATIC_ROOT="${STATIC_ROOT:-/home/tethys/persist/static}"
export MEDIA_ROOT="${MEDIA_ROOT:-/home/tethys/persist/media}"
export TETHYS_WORKSPACES_ROOT="${TETHYS_WORKSPACES_ROOT:-/home/tethys/persist/workspaces}"

readonly TETHYS_SITE_VARS=(
  SITE_TITLE FAVICON BRAND_TEXT BRAND_IMAGE BRAND_IMAGE_HEIGHT BRAND_IMAGE_WIDTH
  BRAND_IMAGE_PADDING APPS_LIBRARY_TITLE PRIMARY_COLOR SECONDARY_COLOR
  PRIMARY_TEXT_COLOR PRIMARY_TEXT_HOVER_COLOR SECONDARY_TEXT_COLOR
  SECONDARY_TEXT_HOVER_COLOR BACKGROUND_COLOR COPYRIGHT HERO_TEXT BLURB_TEXT
  FEATURE_1_HEADING FEATURE_1_BODY FEATURE_1_IMAGE FEATURE_2_HEADING
  FEATURE_2_BODY FEATURE_2_IMAGE FEATURE_3_HEADING FEATURE_3_BODY FEATURE_3_IMAGE
  CALL_TO_ACTION CALL_TO_ACTION_BUTTON PORTAL_BASE_CSS HOME_PAGE_CSS
  APPS_LIBRARY_CSS ACCOUNTS_BASE_CSS LOGIN_CSS REGISTER_CSS USER_BASE_CSS
  HOME_PAGE_TEMPLATE APPS_LIBRARY_TEMPLATE LOGIN_PAGE_TEMPLATE
  REGISTER_PAGE_TEMPLATE USER_PAGE_TEMPLATE USER_SETTINGS_PAGE_TEMPLATE
)

mkdir -p "$TETHYS_HOME" "$STATIC_ROOT" "$MEDIA_ROOT" "$TETHYS_WORKSPACES_ROOT"

if [ ! -f "$TETHYS_HOME/portal_config.yml" ]; then
  echo "Generating $TETHYS_HOME/portal_config.yml"
  tethys gen portal_config
fi

echo "Configuring Tethys portal settings"
echo "${ALLOWED_HOSTS}"
tethys settings \
  --set SECRET_KEY "${TETHYS_SECRET_KEY:-change-me-for-production}" \
  --set DEBUG "${TETHYS_DEBUG:-False}" \
  --set ALLOWED_HOSTS "${ALLOWED_HOSTS:-['localhost','127.0.0.1']}" \
  --set CSRF_TRUSTED_ORIGINS "${CSRF_TRUSTED_ORIGINS:-['http://localhost:8080']}" \
  --set STATIC_ROOT "$STATIC_ROOT" \
  --set STATIC_URL "${STATIC_URL:-/static/}" \
  --set MEDIA_ROOT "$MEDIA_ROOT" \
  --set TETHYS_WORKSPACES_ROOT "$TETHYS_WORKSPACES_ROOT" \
  --set DATABASES.default.ENGINE django.db.backends.postgresql \
  --set DATABASES.default.NAME "${TETHYS_DB_NAME:-tethys_platform}" \
  --set DATABASES.default.USER "${TETHYS_DB_USERNAME:-tethys}" \
  --set DATABASES.default.PASSWORD "${TETHYS_DB_PASSWORD:-pass}" \
  --set DATABASES.default.HOST "${TETHYS_DB_HOST:-postgres}" \
  --set DATABASES.default.PORT "${TETHYS_DB_PORT:-5432}" \
  --set CHANNEL_LAYERS.default.BACKEND channels_redis.core.RedisChannelLayer \
  --set CHANNEL_LAYERS.default.CONFIG.hosts "[['${REDIS_URL}']]"

# App-specific installs or settings can go here. Examples:
#   pip install /app/path/to/tethysapp_my_app
#   tethys install -d /app/path/to/tethysapp_my_app
#   tethys services create persistent ...
#   tethys app_settings set ...
#
# NOTE: the database, the owner role (tethys_default) and the superuser role
# (tethys_super) are created by Postgres itself on first boot, via
# conf/postgres-initdb/10-create-tethys-db.sh -- the Compose equivalent of
# CloudNativePG's bootstrap.initdb + managed.roles. `tethys db create` is
# intentionally NOT run here; Tethys no longer manages roles/databases.

if [ "${RUN_DB_MIGRATIONS:-true}" = "true" ]; then
  echo "Running database migrations"
  tethys db migrate
fi

if [ "${CREATE_SUPERUSER:-true}" = "true" ]; then
  echo "Creating portal superuser . . ."
  tethys db createsuperuser --pn "${PORTAL_SUPERUSER_NAME:-admin}" --pp "${PORTAL_SUPERUSER_PASSWORD:-pass}" --pe "${PORTAL_SUPERUSER_EMAIL}"
fi

# Static files are served by the jsDelivr CDN (see STATIC_URL above and
# scripts/publish-static.sh), published ahead of time -- same as k8s. So we do
# NOT run `tethys manage collectstatic` at startup. To (re)publish assets after
# changing them, run scripts/publish-static.sh and update STATIC_URL.

site_args=()
for site_var in "${TETHYS_SITE_VARS[@]}"; do
  site_value="${!site_var:-}"
  if [ -n "$site_value" ]; then
    site_key="--$(printf '%s' "$site_var" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
    site_args+=("$site_key" "$site_value")
  fi
done

if [ "${#site_args[@]}" -gt 0 ]; then
  echo "Setting up Tethys Site Configuration"
  tethys site "${site_args[@]}"
fi

touch "$TETHYS_HOME/init_complete"
echo "Tethys init complete"
