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

# Apply Tethys site (home page / branding) settings from env. These are DB-backed,
# so they must run after migrations -- hence here, not in portal-config.sh.
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

echo "Portal user bootstrap complete!"
