#!/bin/bash
###############################################################################
# Remove backups according to the config at /etc/acro/mysql-backups.conf
# {{ ansible_managed }}
###############################################################################
set -u; set -e; set -o pipefail

# Constants
MINUTES_IN_AN_HOUR=60
MINUTES_IN_A_DAY=$((MINUTES_IN_AN_HOUR * 24))
MINUTES_IN_A_WEEK=$((MINUTES_IN_A_DAY * 7))
MINUTES_IN_A_MONTH=$((MINUTES_IN_A_DAY * 31))

main () {
  # Require the name of the database to prune backups for from the command line
  DB_NAME="${1:-}"
  test -z "$DB_NAME" && {
    err "What database do you want to prune backups for?"
    exit 1
  }

  # Set VERBOSE=1 as environment variable to see extra info
  VERBOSE="${VERBOSE:-0}"

  # Some other systems use a different filename extension.
  SQLTARGZ="${SQLTARGZ:-0}"

  # Defiing this here prevents typing mistakes - it's used a lot of places
  if [ "$SQLTARGZ" -eq 1 ]; then
    FILENAME_PATTERN_FOR_FIND="${DB_NAME}.????-??-??*.sql.tar.gz"
  else
    FILENAME_PATTERN_FOR_FIND="${DB_NAME}.????-??-??*.sql.gz"
  fi

  # This allows the script to work by itself, as opposed to being part of the mysql-backup package.
  STANDALONE="${STANDALONE:-0}"

  if [ "$STANDALONE" -eq 1 ]; then
    true
  else
    CONFIG="${CONFIG:-/etc/acro/mysql-backups.conf}"
    if [ ! -f "$CONFIG" ]; then
      err "Could not find config file: $CONFIG"
      exit 1
    fi
    source "$CONFIG" || {
      err "Could not load $CONFIG"
      exit 1
    }
  fi

  BACKUP_DIR="${BACKUP_DIR:-'/var/backups/mysql'}"
  DB_DUMP_DIR="${DB_DUMP_DIR:-"${BACKUP_DIR}/${DB_NAME}"}"
  if ! test -d "$DB_DUMP_DIR" ; then
    err "Directory does not exist: $DB_DUMP_DIR"
    exit 1
  fi
  export DB_DUMP_DIR

  echo "##############################################################"
  echo "# $(basename "$0") starting at $(date "+%Y-%m-%d %H:%M:%S %z")"
  echo "##############################################################"

  # On existing/older installations, default to the "KEEPFOR" variable if it's present. Otherwise, set our new default.
  KEEP_LAST_DAILY_DEFAULT="${KEEPFOR:-6}"

  # Set sane default values for anything that wasn't either set in the config file, or set from environment variables
  export KEEP_LAST_HOURLY="${KEEP_LAST_HOURLY:-4}"
  export KEEP_LAST_DAILY="${KEEP_LAST_DAILY:-$KEEP_LAST_DAILY_DEFAULT}"
  export KEEP_LAST_WEEKLY="${KEEP_LAST_WEEKLY:-3}"
  export KEEP_LAST_MONTHLY="${KEEP_LAST_MONTHLY:-11}"

  export BORDER_END_HOURLY=$(( (KEEP_LAST_HOURLY) * MINUTES_IN_AN_HOUR ))
  export BORDER_END_DAILY=$(( BORDER_END_HOURLY + ( (KEEP_LAST_DAILY) * MINUTES_IN_A_DAY ) ))
  export BORDER_END_WEEKLY=$(( BORDER_END_DAILY + ( (KEEP_LAST_WEEKLY) * MINUTES_IN_A_WEEK ) ))
  export BORDER_END_MONTHLY=$(( BORDER_END_WEEKLY + ( (KEEP_LAST_MONTHLY) * MINUTES_IN_A_MONTH ) ))

  # Don't even fire up if there are less than this many backups ....
  KEEP_LAST_MINIMUM_DEFAULT=7
  export KEEP_LAST_MINIMUM="${KEEP_LAST_MINIMUM:-$KEEP_LAST_MINIMUM_DEFAULT}"

  echo "KEEP_LAST_MINIMUM: $KEEP_LAST_MINIMUM"
  echo "KEEP_LAST_HOURLY: $KEEP_LAST_HOURLY"
  echo "KEEP_LAST_DAILY: $KEEP_LAST_DAILY"
  echo "KEEP_LAST_WEEKLY: $KEEP_LAST_WEEKLY"
  echo "KEEP_LAST_MONTHLY: $KEEP_LAST_MONTHLY"
  echo "BACKUP_DIR: $BACKUP_DIR"
  echo "DB_NAME: $DB_NAME"
  echo "DB_DUMP_DIR: $DB_DUMP_DIR"
  echo "FILENAME_PATTERN_FOR_FIND: $FILENAME_PATTERN_FOR_FIND"

  EXISTING_BACKUP_COUNT="$(find "/${DB_DUMP_DIR}/" -maxdepth 1  -type f -name "${FILENAME_PATTERN_FOR_FIND}" | wc -l)"
  if [ "$EXISTING_BACKUP_COUNT" -le "$KEEP_LAST_MINIMUM" ]; then
    echo "Exiting: Not enough backups to bother with. Existing = ${EXISTING_BACKUP_COUNT}, Keep minimum = $KEEP_LAST_MINIMUM"
    return 0
  fi

  BEFORE="$(get_dir_listing)"
  prune_backups
  AFTER="$(get_dir_listing)"

  if [ "$VERBOSE" -eq 1 ]; then
    verbose "### Diff: before <-> after"
    diff -W "$(tput cols)" -y <(echo "$BEFORE") <(echo "$AFTER") || true
    verbose ""
    verbose "### Resulting dir list"
    ls -laF "$DB_DUMP_DIR"
  fi
}

get_dir_listing () {
  # shellcheck disable=SC2012
  ls -l "$DB_DUMP_DIR" | tail -n +2
}

prune_backups() {
  prune_hourly
  prune_daily
  prune_weekly
  prune_monthly
  prune_oldest
}

# Keep a backup from from each hour in $KEEP_LAST_HOURLY hours
prune_hourly () {
  verbose "### Prune hourly"
  local HOUR_INDEX
  for (( HOUR_INDEX=0; HOUR_INDEX < KEEP_LAST_HOURLY; HOUR_INDEX++ )); do
    MINUTES_AGO_WINDOW_BEGIN=$((HOUR_INDEX * MINUTES_IN_AN_HOUR))
    MINUTES_AGO_WINDOW_END=$((MINUTES_AGO_WINDOW_BEGIN + MINUTES_IN_AN_HOUR))
    prune_by_window ${MINUTES_AGO_WINDOW_BEGIN} ${MINUTES_AGO_WINDOW_END}
  done
  verbose ""
}

# Keep a backup from each 24 hour period in $KEEP_LAST_DAILY days
prune_daily () {
  verbose "### Prune daily"
  local DAY_INDEX
  for (( DAY_INDEX=0; DAY_INDEX < KEEP_LAST_DAILY; DAY_INDEX++ )); do
    local MINUTES_AGO_WINDOW_BEGIN=$(( BORDER_END_HOURLY + (DAY_INDEX * MINUTES_IN_A_DAY) ))
    local MINUTES_AGO_WINDOW_END=$((MINUTES_AGO_WINDOW_BEGIN + MINUTES_IN_A_DAY))
    prune_by_window ${MINUTES_AGO_WINDOW_BEGIN} ${MINUTES_AGO_WINDOW_END}
  done
  verbose ""
}

prune_by_window () {
  local MINUTES_AGO_WINDOW_BEGIN="$1"
  local MINUTES_AGO_WINDOW_END="$2"
  verbose "### +${MINUTES_AGO_WINDOW_BEGIN} -${MINUTES_AGO_WINDOW_END}"
  find "/${DB_DUMP_DIR}/" -maxdepth 1 -name "${FILENAME_PATTERN_FOR_FIND}" -type f -mmin "+${MINUTES_AGO_WINDOW_BEGIN}" -mmin "-${MINUTES_AGO_WINDOW_END}" -printf '%T@ %p\n'| sort -n | tail -n +2 | awk '{print $2}' | xargs --no-run-if-empty rm -v
  wait
  find "/${DB_DUMP_DIR}/" -maxdepth 1 -name "${FILENAME_PATTERN_FOR_FIND}" -type f -mmin "+${MINUTES_AGO_WINDOW_BEGIN}" -mmin "-${MINUTES_AGO_WINDOW_END}" -printf '%T@ %p\n'| sort -n | awk -v q="'" '{print "kept", q $2 q}' || true
  wait
}

# Keep a backup from each 7 day period in $KEEP_LAST_WEEKLY weeks
prune_weekly () {
  verbose "### Prune weekly"
  local WEEK_INDEX
  for (( WEEK_INDEX=0; WEEK_INDEX < KEEP_LAST_WEEKLY; WEEK_INDEX++ )); do
    local MINUTES_AGO_WINDOW_BEGIN=$(( BORDER_END_DAILY + (WEEK_INDEX * MINUTES_IN_A_WEEK) ))
    local MINUTES_AGO_WINDOW_END=$((MINUTES_AGO_WINDOW_BEGIN + MINUTES_IN_A_WEEK))
    prune_by_window ${MINUTES_AGO_WINDOW_BEGIN} ${MINUTES_AGO_WINDOW_END}
  done
  verbose ""
}

# Keep a backup from each 31 day period, going back $KEEP_LAST_MONTHLY weeks
prune_monthly () {
  verbose "### Prune monthly"
  local MONTH_INDEX
  for (( MONTH_INDEX=0; MONTH_INDEX < KEEP_LAST_MONTHLY; MONTH_INDEX++ )); do
    local MINUTES_AGO_WINDOW_BEGIN=$(( BORDER_END_WEEKLY + (MONTH_INDEX * MINUTES_IN_A_MONTH) ))
    local MINUTES_AGO_WINDOW_END=$((MINUTES_AGO_WINDOW_BEGIN + MINUTES_IN_A_MONTH))
    prune_by_window ${MINUTES_AGO_WINDOW_BEGIN} ${MINUTES_AGO_WINDOW_END}
  done
  verbose ""
}

prune_oldest () {
  verbose "### Prune oldest"
  local MINUTES_AGO_WINDOW_BEGIN
  MINUTES_AGO_WINDOW_BEGIN="$BORDER_END_MONTHLY"
  find "/${DB_DUMP_DIR}/" -maxdepth 1 -name "${FILENAME_PATTERN_FOR_FIND}" -type f -mmin +${MINUTES_AGO_WINDOW_BEGIN} -printf '%T@ %p\n'| sort -nr | awk '{print $2}' | xargs --no-run-if-empty rm -v
  verbose ""
}

verbose () {
  if [ "$VERBOSE" -eq 1 ]; then
    echo "$*"
  fi
}

err () {
  >&2 echo "ERROR ($(basename "$0")): $*"
}

warn () {
  >&2 echo "WARNING ($(basename "$0")): $*"
}

main "$@"
