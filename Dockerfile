# syntax=docker/dockerfile:1
#
# Multi-stage build:
#   base    - shared ENV only (inherited by builder AND runtime -> no duplication)
#   builder - toolchain (uv/git/gcc) + Python venv + Tethys + apps  (discarded)
#   runtime - slim image: just the venv + interpreter + runtime libs

###############################################################################
# base - shared environment (both stages FROM this)
###############################################################################
FROM debian:trixie-slim AS base

# Paths + venv layout (mimics the conda layout Tethys expects)
ENV TETHYS_HOME="/usr/lib/tethys" \
    TETHYS_LOG="/var/log/tethys" \
    TETHYS_PERSIST="/var/lib/tethys_persist" \
    TETHYS_APPS_ROOT="/var/www/tethys/apps" \
    TETHYS_MANAGE="/usr/lib/tethys/tethys/tethys_portal/manage.py" \
    BASH_PROFILE=".bashrc" \
    CONDA_HOME="/opt/conda" \
    CONDA_ENV_NAME="tethys" \
    ENV_NAME="tethys" \
    VIRTUAL_ENV="/opt/conda/envs/tethys" \
    CONDA_PREFIX="/opt/conda/envs/tethys" \
    LD_LIBRARY_PATH="/opt/conda/envs/tethys/lib" \
    PATH="/opt/conda/envs/tethys/bin:${PATH}"

# Static / media / workspace roots (reference TETHYS_PERSIST from the block above)
ENV STATIC_ROOT="${TETHYS_PERSIST}/static" \
    STATIC_ROOT_CLEAR="True" \
    WORKSPACE_ROOT="${TETHYS_PERSIST}/workspaces" \
    MEDIA_ROOT="${TETHYS_PERSIST}/media" \
    MEDIA_URL="/media/"

# DB + portal defaults (consumed by the Docker-Compose path / init-tethys.sh).
# In k8s these come from tethys-config.env + portal_config.yml instead.
ENV TETHYS_PORT=8000 \
    POSTGRES_PASSWORD="pass" \
    SKIP_DB_SETUP=false \
    TETHYS_DB_ENGINE="django.db.backends.postgresql" \
    TETHYS_DB_NAME="tethys_platform" \
    TETHYS_DB_USERNAME="tethys_default" \
    TETHYS_DB_PASSWORD="pass" \
    TETHYS_DB_HOST="db" \
    TETHYS_DB_PORT=5432 \
    TETHYS_DB_SUPERUSER="tethys_super" \
    TETHYS_DB_SUPERUSER_PASS="pass" \
    PORTAL_SUPERUSER_NAME="" \
    PORTAL_SUPERUSER_EMAIL="" \
    PORTAL_SUPERUSER_PASSWORD="" \
    ASGI_PROCESSES=1 \
    CLIENT_MAX_BODY_SIZE="75M" \
    DEBUG="False" \
    ALLOWED_HOSTS="\"[localhost, 127.0.0.1]\"" \
    CSRF_TRUSTED_ORIGINS="\"[http://localhost, http://127.0.0.1]\"" \
    BYPASS_TETHYS_HOME_PAGE="True" \
    ADD_DJANGO_APPS="\"[]\"" \
    SESSION_WARN=1500 \
    SESSION_EXPIRE=1800 \
    QUOTA_HANDLERS="\"[]\"" \
    DJANGO_ANALYTICAL="\"{}\"" \
    ADD_BACKENDS="\"[]\"" \
    OAUTH_OPTIONS="\"{}\"" \
    CHANNEL_LAYERS_BACKEND="channels.layers.InMemoryChannelLayer" \
    CHANNEL_LAYERS_CONFIG="\"{}\"" \
    RECAPTCHA_PRIVATE_KEY="" \
    RECAPTCHA_PUBLIC_KEY="" \
    OTHER_SETTINGS=""

# Site / branding defaults (Compose `tethys site` knobs)
ENV SITE_TITLE="" FAVICON="" BRAND_TEXT="" BRAND_IMAGE="" BRAND_IMAGE_HEIGHT="" \
    BRAND_IMAGE_WIDTH="" BRAND_IMAGE_PADDING="" APPS_LIBRARY_TITLE="" PRIMARY_COLOR="" \
    SECONDARY_COLOR="" PRIMARY_TEXT_COLOR="" PRIMARY_TEXT_HOVER_COLOR="" SECONDARY_TEXT_COLOR="" \
    SECONDARY_TEXT_HOVER_COLOR="" BACKGROUND_COLOR="" COPYRIGHT="" HERO_TEXT="" BLURB_TEXT="" \
    FEATURE_1_HEADING="" FEATURE_1_BODY="" FEATURE_1_IMAGE="" FEATURE_2_HEADING="" \
    FEATURE_2_BODY="" FEATURE_2_IMAGE="" FEATURE_3_HEADING="" FEATURE_3_BODY="" FEATURE_3_IMAGE="" \
    CALL_TO_ACTION="" CALL_TO_ACTION_BUTTON="" PORTAL_BASE_CSS="" HOME_PAGE_CSS="" \
    APPS_LIBRARY_CSS="" ACCOUNTS_BASE_CSS="" LOGIN_CSS="" REGISTER_CSS="" USER_BASE_CSS="" \
    HOME_PAGE_TEMPLATE="" APPS_LIBRARY_TEMPLATE="" LOGIN_PAGE_TEMPLATE="" REGISTER_PAGE_TEMPLATE="" \
    USER_PAGE_TEMPLATE="" USER_SETTINGS_PAGE_TEMPLATE=""

###############################################################################
# builder - everything heavy; nothing here ends up in the final image
###############################################################################
FROM base AS builder

# uv binary (build-time only; the runtime never needs it)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# build deps: git (clone + pip git+), gcc + libpq-dev (compile psycopg2 if no wheel),
# ca-certificates (HTTPS for git/pip)
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates git gcc libpq-dev \
  && rm -rf /var/lib/apt/lists/*

ENV UV_PYTHON_PREFERENCE=only-managed \
    UV_PYTHON_INSTALL_DIR=/opt/python \
    UV_COMPILE_BYTECODE=1

WORKDIR ${TETHYS_HOME}
COPY pyproject.toml .

# Python interpreter + venv + Tethys platform + extra deps
RUN uv python install 3.12 \
  && uv venv "${VIRTUAL_ENV}" --python 3.12 \
  && uv pip install --no-cache "tethys-platform @ git+https://github.com/tethysplatform/tethys.git" \
  && uv pip install --no-cache -r pyproject.toml \
  && tethys gen portal_config

# Workshop app (installed into the venv; the clone is build-only)
RUN git clone https://github.com/tethysplatform/tethysapp-population_viewer.git \
      "${TETHYS_APPS_ROOT}/tethysapp-population_viewer" \
  && uv pip install --no-cache \
      "${TETHYS_APPS_ROOT}/tethysapp-population_viewer/tethysapp-population_app"

# world-readable so it works even if the image is ever run as non-root
RUN chmod -R a+rX /opt/python /opt/conda

###############################################################################
# runtime - slim final image (no uv, no git, no gcc, no build caches)
###############################################################################
FROM base AS runtime

# runtime libs only: certs (outbound HTTPS), curl (Compose healthcheck),
# postgresql-client (psql/createdb for Compose `tethys db create`, + libpq for psycopg2)
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl postgresql-client \
  && rm -rf /var/lib/apt/lists/*

# The interpreter AND the venv -- copy BOTH at the SAME paths: the venv's pyvenv.cfg
# hardcodes /opt/python, so the venv is dead without it.
COPY --from=builder /opt/python /opt/python
COPY --from=builder /opt/conda  /opt/conda
# Baked default portal_config.yml (Compose uses it; k8s overwrites it at startup)
COPY --from=builder ${TETHYS_HOME}/portal_config.yml ${TETHYS_HOME}/portal_config.yml

# Runtime dirs + the venv-activating entrypoint shim
RUN mkdir -p "${TETHYS_HOME}/tethys" "${TETHYS_PERSIST}" "${TETHYS_APPS_ROOT}" \
      "${WORKSPACE_ROOT}" "${MEDIA_ROOT}" "${STATIC_ROOT}" "${TETHYS_LOG}" \
  && printf '#!/bin/bash\nexport VIRTUAL_ENV=%s\nexport PATH="${VIRTUAL_ENV}/bin:${PATH}"\nexport CONDA_PREFIX="${VIRTUAL_ENV}"\nexport LD_LIBRARY_PATH="${VIRTUAL_ENV}/lib:${LD_LIBRARY_PATH}"\nexec "$@"\n' "${VIRTUAL_ENV}" > /usr/local/bin/_entrypoint.sh \
  && chmod +x /usr/local/bin/_entrypoint.sh

COPY scripts/*.sh /usr/local/bin/

VOLUME ["${TETHYS_PERSIST}", "${TETHYS_HOME}/keys"]
WORKDIR ${TETHYS_HOME}
CMD ["/usr/local/bin/start-uvicorn.sh"]
