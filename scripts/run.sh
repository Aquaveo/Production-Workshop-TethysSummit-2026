#!/bin/bash

tail_file() {
  echo "tailing file $1"
  ALIGN=27
  LENGTH=`echo $1 | wc -c`
  PADDING=`expr ${ALIGN} - ${LENGTH}`
  PREFIX=$1`perl -e "print ' ' x $PADDING;"`
  file="/var/log/$1"
  # each tail runs in the background but prints to stdout
  # sed outputs each line from tail prepended with the filename+padding
  tail -qF $file | sed --unbuffered "s|^|${PREFIX}:|g" &
}

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

./init_tethys.sh

if [[ $test = false ]]; then

  # Watch Logs
  echo_status "Watching logs. You can ignore errors from either apache (httpd) or nginx depending on which one you are using."

  log_files=("tethys/tethys.log")

  # When this exits, exit all background tail processes
  trap 'kill $(jobs -p)' EXIT
  for log_file in "${log_files[@]}"; do
    tail_file "${log_file}"
  done

  # Read output from tail; wait for kill or stop command (docker waits here)
  wait
fi