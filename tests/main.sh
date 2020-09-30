#!/bin/bash
set -u; set -e; set -o pipefail

main() {
  export DB_NAME="foo_db"
  export TARGET_DIR="/tmp/mysql-backups-simulation/$DB_NAME"
  export DB_DUMP_DIR="$TARGET_DIR" # Required for Prune script

  LOGFILE="/tmp/prune-backups.$(date --iso-8601=ns).log"; touch "$LOGFILE"
  echo "Will send prune script output to: $LOGFILE"
  export LOGFILE

  purge_test_files
  recreate_target_dir

  # Control test options with env variables
  GENERATE_PREVIOUS="${GENERATE_PREVIOUS:-0}"
  echo "GENERATE_PREVIOUS: $GENERATE_PREVIOUS"
  SIMULATE_HOURLY="${SIMULATE_HOURLY:-0}"
  echo "SIMULATE_HOURLY: $SIMULATE_HOURLY"
  SIMULATE_DAILY="${SIMULATE_DAILY:-1}" # < Default test mode. Set SIMULATE_HOURLY=0 to turn off.
  echo "SIMULATE_DAILY: $SIMULATE_DAILY"

  if [ "${GENERATE_PREVIOUS}" -eq 1 ]; then
    ./generate-fake-backup-files.sh
  fi

  if [ "${SIMULATE_HOURLY}" -eq 1 ]; then
    simulate_hourly_backup_cycle
  fi

  # Default test.
  if [ "${SIMULATE_DAILY}" -eq 1 ]; then
    simulate_daily_backup_cycle
  fi

  ## Unused
  # cycle_mins
  # cycle_mins
  # cycle_hours
  # cycle_days

}

simulate_hourly_backup_cycle () {
  echo "About to run 'hourly backup' simulation:"
  echo "- Use CTRL+C at any time to terminate the simulation "
  echo "- Use CTRL+Z to pause the simulation "
  echo -n "Press any key to continue: "
  read -r DRAMATIC_PAUSE
  trap "trap_ctrl_c" INT     # sigint_will only get called when ctrl + c happens
  count_files
  local COUNT=0
  while true; do
    COUNT=$((COUNT+1))
    echo "Hour ${COUNT}:"
    ./artificially-age-files.sh 55 minute
    prune_backups
    simulate_new_backup
    ./artificially-age-files.sh 5 minute
  done
}

simulate_daily_backup_cycle () {
  echo "About to run 'daily backup' simulation:"
  echo "- Use CTRL+C at any time to terminate the simulation "
  echo "- Use CTRL+Z to pause the simulation "
  echo -n "Press any key to continue: "
  read -r DRAMATIC_PAUSE
  trap "trap_ctrl_c" INT     # sigint_will only get called when ctrl + c happens
  count_files
  local COUNT=0
  while true; do
    COUNT=$((COUNT+1))
    echo "Day ${COUNT}:"
    ./artificially-age-files.sh 23 hour
    prune_backups
    simulate_new_backup
    ./artificially-age-files.sh 1 hour
  done
}

function trap_ctrl_c() {
  echo "Trapped CTRL+C. Exiting."
  exit 0
}

purge_test_files () {
  test -d $TARGET_DIR && rm -rf $TARGET_DIR && echo "Purged $TARGET_DIR"
}

recreate_target_dir () {
  mkdir -pv "${TARGET_DIR}"
}

cycle_mins () {
  local DECREMENT=5
  for i in {1..6}; do
    age_backups_by_x_minutes $DECREMENT
    prune_backups
  done
  simulate_new_backup
}

cycle_hours () {
  for i in {1..24}; do
    age_by_one_hour
    prune_backups
    simulate_new_backup
  done
}

cycle_days () {
  for i in {1..60}; do
    age_by_one_day
    prune_backups
    simulate_new_backup
  done
}
age_backups_by_x_minutes () {
  local DECREMENT="$1"
  echo "Aging backups by $DECREMENT minute(s)... "
  ./artificially-age-files.sh "$DECREMENT" day

}

age_by_one_day () {
  echo "Aging backups by 1 day... "
  ./artificially-age-files.sh 1 day
}

age_by_one_hour () {
  echo "Aging backups by 1 hour... "
  ./artificially-age-files.sh 1 hour
}

simulate_new_backup () {
  local PATH_TO_NEW_BACKUP
  PATH_TO_NEW_BACKUP="${TARGET_DIR}/${DB_NAME}.$(date +%Y-%m-%d-%H%M).sql.gz"
  echo -n "Simulating new backup at $PATH_TO_NEW_BACKUP ... "
  touch "$PATH_TO_NEW_BACKUP"
  echo "created $PATH_TO_NEW_BACKUP" >> "$LOGFILE"
  count_files
}

count_files () {
  echo "$(find "$TARGET_DIR" -type f|wc -l) files remain."
}

prune_backups () {
  echo -n "Pruning backups ... "
  ../scripts/prune-backups.sh >> "$LOGFILE"
  count_files
}
main "$@"
