#!/usr/bin/env bash
set -euo pipefail

export TETHYS_HOME="${TETHYS_HOME:-/var/lib/tethys}"
export TETHYS_PERSIST="${TETHYS_PERSIST:-/var/lib/tethys_persist}"
export STATIC_ROOT="${STATIC_ROOT:-/var/www/tethys/static}"
export MEDIA_ROOT="${MEDIA_ROOT:-/var/www/tethys/media}"
export TETHYS_WORKSPACES_ROOT="${TETHYS_WORKSPACES_ROOT:-/var/www/tethys/workspaces}"

if [ -f "$TETHYS_HOME/portal_setup_complete" ]; then
  echo "Tethys portal setup already completed, skipping setup"
  exit 0
fi

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

mkdir -p "$TETHYS_HOME" "$TETHYS_PERSIST" "$STATIC_ROOT" "$MEDIA_ROOT" "$TETHYS_WORKSPACES_ROOT"

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
  --set DATABASES.default.DISABLE_SERVER_SIDE_CURSORS "${DISABLE_SERVER_SIDE_CURSORS:-True}" \
  --set DATABASES.default.CONN_MAX_AGE "${CONN_MAX_AGE:-0}" \
  --set CHANNEL_LAYERS.default.BACKEND channels_redis.core.RedisChannelLayer \
  --set CHANNEL_LAYERS.default.CONFIG.hosts "[['${REDIS_URL}']]"

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

touch "$TETHYS_HOME/portal_setup_complete"
echo "Tethys portal setup complete!"
exit 0
