#!/usr/bin/env bash
# Docker-Compose one-shot setup for a VM (or laptop).
#
#   1. checks Docker Engine + the `docker compose` v2 plugin are installed and the daemon is up
#   2. creates .env from .env.example (and generates a real TETHYS_SECRET_KEY) if missing
#   3. builds the image and brings the stack up (init Job first, so you see migrations/provisioning)
#   4. waits for the portal and prints the URL
#
# Runnable from anywhere; it resolves the repo root from its own location.
# Re-runnable: an existing .env is left untouched, and `docker compose up` is idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # dev/vm
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"                 # repo root (docker-compose.yml + .env.example)
cd "$REPO_ROOT"

PORT="8080"   # nginx publishes 8080:8080 in docker-compose.yml

# ---------------------------------------------------------------------------
# 1. Prerequisites -- check only; never auto-install (that needs sudo + is OS-specific).
# ---------------------------------------------------------------------------
missing=0

if command -v docker >/dev/null 2>&1; then
  echo "✓ docker:         $(docker --version)"
else
  echo "✗ docker is NOT installed."
  echo "    Install Docker Engine: https://docs.docker.com/engine/install/"
  echo "    (Linux quick install:  curl -fsSL https://get.docker.com | sh)"
  missing=1
fi

# `docker compose` (v2 plugin) -- NOT the legacy `docker-compose` v1 binary.
if docker compose version >/dev/null 2>&1; then
  echo "✓ docker compose: $(docker compose version --short 2>/dev/null || docker compose version | head -1)"
else
  echo "✗ the 'docker compose' v2 plugin is NOT available."
  echo "    Install it: https://docs.docker.com/compose/install/linux/"
  echo "    (If you only have the old 'docker-compose' v1, install the v2 plugin instead.)"
  missing=1
fi

# Daemon reachable? (only worth checking if the docker binary exists)
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    echo "✓ docker daemon:  running"
  else
    echo "✗ the Docker daemon is not reachable."
    echo "    - macOS / Windows-WSL2: start Docker Desktop (enable WSL integration for your distro)."
    echo "    - native Linux/WSL2 engine: 'sudo systemctl start docker', and add your user to the"
    echo "      'docker' group ('sudo usermod -aG docker \$USER', then log out/in) or re-run with sudo."
    missing=1
  fi
fi

if [ "$missing" -ne 0 ]; then
  echo
  echo "Resolve the items marked ✗ above, then re-run: dev/vm/setup.sh"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. .env -- create from the template and generate a secret key if it doesn't exist.
# ---------------------------------------------------------------------------
if [ -f .env ]; then
  echo "✓ .env already exists -- leaving it untouched."
else
  echo "Creating .env from .env.example . . ."
  cp .env.example .env
  # Generate a real SECRET_KEY (openssl, with a /dev/urandom fallback). Drop the template
  # line and append a fresh one so we never depend on sed-escaping the base64 value.
  if command -v openssl >/dev/null 2>&1; then
    secret="$(openssl rand -base64 48)"
  else
    secret="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
  fi
  grep -v '^TETHYS_SECRET_KEY=' .env > .env.tmp && mv .env.tmp .env
  printf 'TETHYS_SECRET_KEY="%s"\n' "$secret" >> .env
  echo "✓ .env created (generated a fresh TETHYS_SECRET_KEY)."
fi

# ---------------------------------------------------------------------------
# 3. Build + bring up. Run tethys-init in the FOREGROUND first so migrations + the
#    persistent-store provisioning are visible and fail fast; then start the rest.
# ---------------------------------------------------------------------------
echo
echo "Building the image (docker compose build) . . ."
docker compose build

echo
echo "Running the init job (migrations, superuser, site config, persistent store) . . ."
docker compose up tethys-init

echo
echo "Starting the rest of the stack (docker compose up -d) . . ."
docker compose up -d

# ---------------------------------------------------------------------------
# 4. Wait for the portal, then report.
# ---------------------------------------------------------------------------
admin="$(grep -E '^PORTAL_SUPERUSER_NAME=' .env | cut -d= -f2- | tr -d '"')"
login_hint="(login: ${admin:-admin} / the PORTAL_SUPERUSER_PASSWORD in .env)"

if command -v curl >/dev/null 2>&1; then
  echo
  echo -n "Waiting for the portal at http://localhost:${PORT}/ "
  ok=0
  for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null "http://localhost:${PORT}/" 2>/dev/null; then ok=1; break; fi
    echo -n "."; sleep 2
  done
  echo
  if [ "$ok" -eq 1 ]; then
    echo "All set! Open http://localhost:${PORT}    ${login_hint}"
  else
    echo "Portal didn't answer yet. Check the logs:"
    echo "    docker compose ps"
    echo "    docker compose logs -f tethys-web nginx"
  fi
else
  # curl is the only readiness check we have; without it just report and point at the logs.
  echo "Stack started (curl not found, so readiness wasn't polled)."
  echo "Open http://localhost:${PORT}    ${login_hint}"
  echo "Check status: docker compose ps"
fi
