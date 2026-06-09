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

# Paths + venv layout (mimics the conda layout Tethys expects).
# All Tethys state lives under /home/tethys (the service user's home) so a non-root
# user owns it WITHOUT chowning system dirs -- see `useradd` in the runtime stage.
# (TETHYS_MANAGE was dropped: it pointed at a manage.py under TETHYS_HOME that never
#  existed -- the real one ships inside the venv -- and nothing reads it.)
ENV HOME="/home/tethys" \
    TETHYS_HOME="/home/tethys/portal" \
    TETHYS_LOG="/home/tethys/log" \
    TETHYS_PERSIST="/home/tethys/persist" \
    TETHYS_APPS_ROOT="/home/tethys/apps" \
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
#
# NOTE: password/secret values are intentionally NOT baked here -- doing so writes
# them into a permanent image layer (readable via `docker history`), which trips
# BuildKit's SecretsUsedInArgOrEnv lint. They are supplied at runtime instead:
#   - k8s    -> Secrets (tethys-db-app, tethys-secret)
#   - Compose -> .env / `environment:` in docker-compose.yml
# and every consuming script already defaults them (e.g. "${TETHYS_DB_PASSWORD:-pass}").
ENV TETHYS_PORT=8000 \
    SKIP_DB_SETUP=false \
    TETHYS_DB_ENGINE="django.db.backends.postgresql" \
    TETHYS_DB_NAME="tethys_platform" \
    TETHYS_DB_USERNAME="tethys_default" \
    TETHYS_DB_HOST="db" \
    TETHYS_DB_PORT=5432 \
    TETHYS_DB_SUPERUSER="tethys_super" \
    PORTAL_SUPERUSER_NAME="" \
    PORTAL_SUPERUSER_EMAIL="" \
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
# postgresql-client (psql client + libpq for psycopg2)
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl postgresql-client \
  && rm -rf /var/lib/apt/lists/*

# Non-root service user. --create-home makes /home/tethys owned by uid 1000, which is
# what lets every Tethys dir below it be created AS the user (no chown anywhere). The
# passwd entry also keeps getpwuid()/expanduser("~") happy for the venv + Django.
RUN useradd --uid 1000 --create-home --home-dir /home/tethys --shell /bin/bash tethys

# The interpreter AND the venv -- copy BOTH at the SAME paths: the venv's pyvenv.cfg
# hardcodes /opt/python, so the venv is dead without it. (Already world-readable via
# `chmod a+rX` in the builder, so uid 1000 can execute it read-only.)
COPY --from=builder /opt/python /opt/python
COPY --from=builder /opt/conda  /opt/conda

# venv-activating entrypoint shim (root-owned, world-executable) + the scripts
RUN printf '#!/bin/bash\nexport VIRTUAL_ENV=%s\nexport PATH="${VIRTUAL_ENV}/bin:${PATH}"\nexport CONDA_PREFIX="${VIRTUAL_ENV}"\nexport LD_LIBRARY_PATH="${VIRTUAL_ENV}/lib:${LD_LIBRARY_PATH}"\nexec "$@"\n' "${VIRTUAL_ENV}" > /usr/local/bin/_entrypoint.sh \
  && chmod +x /usr/local/bin/_entrypoint.sh
COPY --chmod=0755 scripts/*.sh /usr/local/bin/

USER 1000:1000

# Everything lives under /home/tethys (owned by 1000), so these are created AS the
# user -- zero chown. (TETHYS_PERSIST is created implicitly by its subdirs.)
RUN mkdir -p "${TETHYS_HOME}/keys" "${TETHYS_HOME}/tethys" \
      "${STATIC_ROOT}" "${MEDIA_ROOT}" "${WORKSPACE_ROOT}" \
      "${TETHYS_APPS_ROOT}" "${TETHYS_LOG}"

# Baked default portal_config.yml (Compose uses it; k8s overwrites it at startup)
COPY --chown=1000:1000 --from=builder ${TETHYS_HOME}/portal_config.yml ${TETHYS_HOME}/portal_config.yml

VOLUME ["${TETHYS_PERSIST}", "${TETHYS_HOME}/keys"]
WORKDIR ${TETHYS_HOME}
CMD ["/usr/local/bin/start-uvicorn.sh"]
