#!/bin/bash
# Postgres bootstrap for the Compose path -- the equivalent of CloudNativePG's
# bootstrap.initdb + managed.roles in k8s (k8s/base/10-cnpg-postgres.yaml).
#
# The official postgres/postgis image runs every script in
# /docker-entrypoint-initdb.d/ exactly ONCE, on first boot (empty data dir),
# as the POSTGRES_USER superuser. That is where DB/role creation belongs --
# NOT `tethys db create`. Tethys then only migrates + creates the portal admin.
#
# Creates, mirroring CNPG:
#   - role  tethys_default  (login; owns the database)          <- initdb.owner
#   - role  tethys_super    (login; SUPERUSER; CREATEDB)        <- managed.roles
#   - db    tethys_platform (owned by tethys_default)
#
# Values come from the same env vars the rest of the stack uses (.env), passed
# to the postgres service in docker-compose.yml. psql :"ident" / :'literal'
# interpolation keeps role names and passwords correctly quoted.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v owner="${TETHYS_DB_USERNAME}"        -v owner_pw="${TETHYS_DB_PASSWORD}" \
  -v super="${TETHYS_DB_SUPERUSER}"       -v super_pw="${TETHYS_DB_SUPERUSER_PASS}" \
  -v dbname="${TETHYS_DB_NAME}" <<-'EOSQL'
    CREATE ROLE :"owner" WITH LOGIN PASSWORD :'owner_pw';
    CREATE ROLE :"super" WITH LOGIN SUPERUSER CREATEDB PASSWORD :'super_pw';
    CREATE DATABASE :"dbname" OWNER :"owner";
EOSQL

echo "Bootstrapped database '${TETHYS_DB_NAME}' (owner ${TETHYS_DB_USERNAME}, superuser ${TETHYS_DB_SUPERUSER})"
