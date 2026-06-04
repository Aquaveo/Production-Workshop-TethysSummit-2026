#!/bin/bash

echo_status() {
  local args="${@}"
  tput setaf 4
  tput bold
  echo -e "- $args"
  tput sgr0
}

db_max_count=24;
no_daemon=true;
skip_perm=false;
test=false;
db_engine=${TETHYS_DB_ENGINE} # Get the DB engine from environment variable
skip_db_setup=${SKIP_DB_SETUP} # Get the DB setup flag from environment variable
USAGE="USAGE: . run.sh [options]
OPTIONS:
--background              \t run supervisord in background.
--skip-perm               \t skip fixing permissions step.
--db-max-count <INT>      \t number of attempt to connect to the database. Default is at 24.
--test                    \t only run test.
"

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-perm)
      skip_perm=true;
    ;;
    --background)
      no_daemon=false;
    ;;
    --db-max-count)
      shift # shift from key to value
      db_max_count=$1;
    ;;
    --test)
      test=true;
    ;;
    *)
      echo -e "${USAGE}"
      return 0
  esac
  shift
done

echo_status "Starting up..."

echo_status "Setting up Tethys... (This might take a bit)"

./init-tethys.sh

echo_status "Tethys setup complete"