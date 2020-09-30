#!/bin/bash
set -u; set -e; set -o pipefail

main () {
  TODAYS_DATE="$(date "+%Y-%m-%d %H:%M:%S")"
  echo "TODAYS_DATE: $TODAYS_DATE"

  DB_NAME="foo_db"
  TARGET_DIR="/tmp/mysql-backups-simulation/${DB_NAME}"
  mkdir -pv "${TARGET_DIR}"
  echo -n "Generating test files "

  generate_last_600_days_worth
  generate_last_48_hours_worth

  echo ""
  echo "Files were generated in $TARGET_DIR"
}

generate_last_600_days_worth () {
  for i in {0..600}; do
     PREVIOUS_DATE=$(date +%Y-%m-%d-%H%M -d "-${i} day")
     TOUCHTIME=$(date +%Y%m%d%H%M -d "-${i} day")
     touch "${TARGET_DIR}/${DB_NAME}.${PREVIOUS_DATE}.sql.gz" -t "$TOUCHTIME"
     echo -n '.'
  done
}

generate_last_48_hours_worth () {
  for i in {0..48}; do
    PREVIOUS_DATE=$(date +%Y-%m-%d-%H%M -d "-${i} hour")
    TOUCHTIME=$(date +%Y%m%d%H%M -d "-${i} hour")
    touch "${TARGET_DIR}/${DB_NAME}.${PREVIOUS_DATE}.sql.gz" -t "$TOUCHTIME"
    echo -n '.'
  done
}

main "$@"
