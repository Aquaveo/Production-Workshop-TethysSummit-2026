#!/usr/bin/env bash
set -euo pipefail

echo "Running database migrations"
tethys db migrate

echo "Migrations have been completed"
