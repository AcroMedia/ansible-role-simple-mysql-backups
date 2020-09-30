#!/bin/bash -ue
#################################################################
# mysql-backups.sh
# {{ ansible_managed }}
#################################################################
# Dump MySQL databases according to the config at /etc/acro/mysql-backups.conf.
#
# Designed to be run as a nightly cron job on non-clustered servers.
#
# Script is silent unless there is a problem.
#
# Depends on the 'user', 'password', and 'host' (if necessary)
# login credentials stored in the executing user's ~/.my.cnf file.
#
#################################################################


function main () {

  require_script '/usr/bin/ionice'

  CONFIG="/etc/acro/mysql-backups.conf"
  source "$CONFIG" || {
    err "Could not load $CONFIG"
    exit 1
  }

  # Root required.
  if [[ $EUID -ne 0 ]]; then
     err "This script must be run as root"
     exit 1
  fi

  # Touch the log file to make sure we can write to it.
  touch "$ACTIVITY_LOG" || {
     err "Could not write to log file: ${ACTIVITY_LOG}. Aborting."
     exit 1
  }

  # Prune log was added in 2018 - We need to provide a default when it hasn't been specified.
  PRUNE_LOG="${PRUNE_LOG:-/var/log/mysql-backups-pruned.log}"
  touch "$PRUNE_LOG" || {
     echo "Could not write to prune log: ${PRUNE_LOG}. Aborting."
     exit 1
  }

  DB_LIST="$(mysql -Bse 'show databases')" || {
    echo "ERROR: Could not retrieve list of databases" | >&2 tee -a "$ACTIVITY_LOG"
    exit 1
  }

  # Backups can contain sensitive info. Make sure files we create are only readable by us.
  umask 077

  if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -pv "$BACKUP_DIR" >> "$ACTIVITY_LOG" || {
      echo "ERROR: Could not create dir: $BACKUP_DIR" | >&2 tee -a "$ACTIVITY_LOG"
      exit 1
    }
  fi

  # create unique file names so we can keep more than just the most recent copy.
  DATE_TIME="$( /bin/date +%Y-%m-%dT%H:%M:%S%z )"
  STARTTIME=$(date +%s)
  local DEFAULT_NO_BACKUPS_FOR='^information_schema$|^performance_schema$'
  NO_BACKUPS_FOR="${NO_BACKUPS_FOR:-"${DEFAULT_NO_BACKUPS_FOR}"}"
  {
  echo ""
  echo "--------------------------------------------------------------------------------"
  echo "$(basename "$0") starting at $(date "+%Y-%m-%d %H:%M:%S")"
  echo "--------------------------------------------------------------------------------"
  echo "Abort threshold: $SPACE_ABORT_THRESHOLD percent"
  echo "Don't back up: '$NO_BACKUPS_FOR'"
  } >> "$ACTIVITY_LOG"

  # Collect some stats on activity
  ENCOUNTERED=0  # ENCOUNTERED = IGNORED + ATTEMPTED + ERRORS
  IGNORED=0      # On purpose / by configuration
  ATTEMPTED=0
  BACKED_UP=0
  ERRORS=0       # Could not back up for whatever reason
  FS_1KBL_FREE_BEGIN="$(df -kP "$BACKUP_DIR"| grep / | awk '{print $4}')"
  set +e
  FS_BYTES_FREE_BEGIN=$((FS_1KBL_FREE_BEGIN * 1024))
  set -e
  for db in $DB_LIST; do

    echo "---[ $db ]---" >> "$ACTIVITY_LOG"

    ENCOUNTERED=$((ENCOUNTERED+1))

    if echo "$db" | grep -qE "$NO_BACKUPS_FOR"; then
      echo "Skipped: excluded by configuration."  >> "$ACTIVITY_LOG"
      IGNORED=$((IGNORED+1))

    else

      if [ -d "$BACKUP_DIR/$db" ]; then
        echo -n "Pruning backups for '${db}' (see ${PRUNE_LOG}) ... " >> "$ACTIVITY_LOG"
        if /opt/acro/mysql-backups/prune-backups.sh "$db" >> "$PRUNE_LOG"; then
          echo "OK" >> "$ACTIVITY_LOG"
        else
          echo "ERROR" >> "$ACTIVITY_LOG"
        fi
      else
        local NOT_PRUNING_MESSAGE="Not pruning backups for '${db}'; backup dir does not exist for it. If this is the first time you've seen this warning for this DB, you can safely ignore it. The dir should be created as part of the backup cycle."
        if db_ignored_when_empty "${db}"; then
          echo "NOTICE: $NOT_PRUNING_MESSAGE" >> "$ACTIVITY_LOG"
          echo "NOTICE: Warnings about ${db} are ignored by configuration: IGNORE_EMPTY_DB_PATTERN='$IGNORE_EMPTY_DB_PATTERN'." >> "$ACTIVITY_LOG"
        else
          echo "WARN: $NOT_PRUNING_MESSAGE" | >&2 tee -a  "$ACTIVITY_LOG"
        fi
      fi

      if ! disk_space_is_good; then
        exit 1
      fi

      ATTEMPTED=$((ATTEMPTED+1))

      # PREDICTED_DUMP_KB="$(mysql -ss -e "SELECT CEILING((sum(data_length)) / POWER(1024,1)) as Data_KB FROM information_schema.tables WHERE table_schema = '$db'")"
      PREDICTED_DUMP_BYTES="$(mysql -ss -e "SELECT sum(data_length) as Data_BB FROM information_schema.tables WHERE table_schema = '$db'")" || {
        echo "ERROR: Could not retreive size of database: ${db}." | >&2 tee -a  "$ACTIVITY_LOG"
        ERRORS=$((ERRORS+1))
        continue
      }
      if [[ "$PREDICTED_DUMP_BYTES" == "NULL" ]]; then
        local EMPTY_DB_MESSAGE="Skipping ${db}; it appears to have no tables."
        if db_ignored_when_empty "${db}"; then
          echo "NOTICE: $EMPTY_DB_MESSAGE" >> "$ACTIVITY_LOG"
          echo "NOTICE: Warnings about ${db} are ignored by configuration: IGNORE_EMPTY_DB_PATTERN='$IGNORE_EMPTY_DB_PATTERN'." >> "$ACTIVITY_LOG"
          ERRORS=$((ERRORS+1))
        else
          echo "ERROR: $EMPTY_DB_MESSAGE" | >&2 tee -a  "$ACTIVITY_LOG"
          ERRORS=$((ERRORS+1))
        fi
        continue
      fi
      if ! is_positive_integer "$PREDICTED_DUMP_BYTES" ; then
        echo "ERROR: Unexpected error trying to determine PREDICTED_DUMP_BYTES for ${db}" | >&2 tee -a  "$ACTIVITY_LOG"
        ERRORS=$((ERRORS+1))
        continue
      fi
      PREDICTED_DUMP_KB=$((PREDICTED_DUMP_BYTES/1024))
      # echo "Predicted dump kB: $PREDICTED_DUMP_KB" >> "$ACTIVITY_LOG"
      PREDICTED_DB_DUMP_MB=$((PREDICTED_DUMP_BYTES/1024/1024))
      echo "Predicted dump size (uncompressed): ${PREDICTED_DB_DUMP_MB}M" >> "$ACTIVITY_LOG"

      KB_FREE_ON_DISK="$(df -kP "$BACKUP_DIR"| grep / | awk '{print $4}')"
      echo "Disk free: $(df -kPH "$BACKUP_DIR" | grep / | awk '{print $4}')" >> "$ACTIVITY_LOG"
      if ! is_positive_integer "$KB_FREE_ON_DISK"; then
        echo "ERROR: Unexpected error trying to find free disk space for ${db}." | >&2 tee -a  "$ACTIVITY_LOG"
        ERRORS=$((ERRORS+1))
        continue
      fi
      if [ $PREDICTED_DUMP_KB -ge "$KB_FREE_ON_DISK" ]; then
        echo "ERROR: The predicted (uncompressed) mysql dump size ($PREDICTED_DUMP_KB kB) of database '${db}' exceeds available disk space ($KB_FREE_ON_DISK kB). Skipping and moving to next." | >&2 tee -a  "$ACTIVITY_LOG"
        ERRORS=$((ERRORS+1))
        continue
      fi

      backup_filename="$BACKUP_DIR/$db/$db.${DATE_TIME}.sql"
      backup_zipped="$backup_filename.gz"

      # If a file already exists, it needs to be removed before we can make a backup.
      if [ -f "$backup_zipped" ]; then
        rm -v "$backup_zipped" >> "$ACTIVITY_LOG"
      fi

      if [ ! -d "$BACKUP_DIR/$db" ]; then
        mkdir -pv "$BACKUP_DIR/$db" >> "$ACTIVITY_LOG"
      fi

      # Older versions of mysqldump don't understand the events flag
      if mysqldump --events --version > /dev/null 2>&1; then
        EVENTSFLAG="--events"
      else
        EVENTSFLAG=""
      fi

      echo "Saving to ${backup_filename}.gz..." >> "$ACTIVITY_LOG"
      ## Back up the database ##
      # nice -n 19     : run a process with low CPU priority
      # ionice -c2 -n7 : run a process with low I/O priority
      # --single-transaction : keeps innodb tables consistent with the point in time when the backup was started
      # --quick : useful for dumping large tables. It forces mysqldump to retrieve rows for a table from the server a row at a time rather than retrieving the entire row set and buffering it in memory before writing it out.
      #  --events --ignore-table=mysql.events : Prevents mysqldump from emitting a useless warning. See https://bugs.mysql.com/bug.php?id=68376
      # Login credentials come from the [client] or [mysqldump] section of ~/.my.cnf.

      if mysql_is_aurora and [[ "$db" == 'mysql' ]]; then
        # When the DB engine is RDS Auorora, we don't have permission to read the stored procedures, so skip it. It just produces error messages we can't do anything about.
        ROUTINES_FLAG=''
      else
        ROUTINES_FLAG='--routines'
      fi

      set -o pipefail
      if nice -n 19 ionice -c2 -n7 mysqldump --force --single-transaction --quick $EVENTSFLAG  $ROUTINES_FLAG --triggers --ignore-table=mysql.events "$db" | nice -n 19 ionice -c2 -n7 gzip > "$backup_zipped"; then
        set +o pipefail
        # shellcheck disable=SC2012
        echo "Compressed file is $(ls -laFh "$backup_zipped" |awk '{print $5}') bytes." >> "$ACTIVITY_LOG"
        BACKED_UP=$((BACKED_UP+1))
      else
        set +o pipefail
        echo "WARNING: Backup of database '${db}' reported errors." | >&2 tee -a "$ACTIVITY_LOG"
        ERRORS=$((ERRORS+1))
      fi

    fi
    echo "" >> "$ACTIVITY_LOG"
  done

  set +e
  ENDTIME=$(date +%s)
  FS_1KBL_FREE_END="$(df -kP "$BACKUP_DIR"| grep / | awk '{print $4}')"
  FS_BYTES_FREE_END=$((FS_1KBL_FREE_END * 1024))
  FS_BYTES_CONSUMED=$((FS_BYTES_FREE_BEGIN - FS_BYTES_FREE_END))
  FS_CONSUMED_PRETTY="$(human_print_bytes "$FS_BYTES_CONSUMED")"
  {
  echo ""
  echo "All done. Statistics:"
  echo " - Elapsed time: $((ENDTIME - STARTTIME))s" >> "$ACTIVITY_LOG"
  echo " - Disk space consumed: $FS_CONSUMED_PRETTY"
  echo " - Databases detected: $ENCOUNTERED"
  echo " - Databases ignored: $IGNORED"
  echo " - Backups attempted: $ATTEMPTED"
  echo " - Backups completed: $BACKED_UP"
  echo " - Errors: $ERRORS"
  } >> "$ACTIVITY_LOG"

}

function disk_space_is_good () {
  # Don't continue if we are at critical drive space levels
  local used_space_percent
  used_space_percent=$(df -kP "$BACKUP_DIR" | grep / | awk '{print $5}' | sed 's/.$//')
  #echo "disk use %: $used_space_percent" >> "$ACTIVITY_LOG"
  local space_left
  space_left=$(df -kPH "$BACKUP_DIR" | grep / | awk '{print $4}')
  #echo "space left: $space_left" >> "$ACTIVITY_LOG"
  local DEFAULT_SPACE_ABORT_THRESHOLD=75
  # Should be configured from settings file
  SPACE_ABORT_THRESHOLD="${SPACE_ABORT_THRESHOLD:-"${DEFAULT_SPACE_ABORT_THRESHOLD}"}"
  if [ "$used_space_percent" -ge "$SPACE_ABORT_THRESHOLD" ]; then
    echo "ERROR: Drive is $used_space_percent% full. Abort Threshold: $SPACE_ABORT_THRESHOLD%. $space_left remaining." | >&2 tee -a "$ACTIVITY_LOG"
    false
  else
    true
  fi
}

function is_positive_integer() {
  local WHAT="$*"
  if [[ "$WHAT" =~ ^[0-9]+$ ]]; then
    true
  else
    false
  fi
}

function is_integer() {
  local WHAT="$*"
  if [[ "$WHAT" =~ ^-?[0-9]+$ ]]; then
    true
  else
    false
  fi
}

function require_script () {
  type "$1" > /dev/null  2>&1 || {
    >&2 echo "The following is not installed or not in path: $1"
    exit 1
  }
}

function human_print_bytes () {
  ############################
  # Warning: Number comparisons produce errors if they are larger than the
  # integer limit for bash on the system. (64 bits for bash => 4).
  # [ X -lt 9223372036854775807 ] == OK
  # [ X -lt 9223372036854775808 ] == "integer expression expected" error
  ############################
  local B KB MB GB TB PB
  B="$1"
  chrlen="${#B}"
  if [ "$chrlen" -gt 16 ]; then
    >&2 printf "human_print_bytes() Warning: This function can't be trusted with numbers approaching 64 bits in length.\n"
  fi
  if ! is_integer "${B}"; then
    >&2 echo "ERR: human_print_bytes(): Invalid argument: ${B}"
    return 1
  fi
  local POSNEG=''
  if [ "${B}" -lt 0 ]; then
    POSNEG='-'
    B=$((0 - B))
  fi
  [ "$B" -lt 1024 ] && echo "${POSNEG}${B} B" && return
  KB=$(((B+512)/1024))
  [ "$KB" -lt 1024 ] && echo "${POSNEG}${KB} kiB" && return
  MB=$(((KB+512)/1024))
  [ "$MB" -lt 1024 ] && echo "${POSNEG}${MB} MiB" && return
  GB=$(((MB+512)/1024))
  [ "$GB" -lt 1024 ] && echo "${POSNEG}${GB} GiB" && return
  TB=$(((GB+512)/1024))
  [ "$TB" -lt 1024 ] && echo "${POSNEG}${TB} TiB" && return
  PB=$(((TB+512)/1024))
  echo "${POSNEG}${PB} PiB"
}


#
function mysql_is_aurora () {
  local QRESULT
  QRESULT=$(mysql -Bse "show variables like 'aurora_version';")  # When defined, will return something like "aurora_version	2.03"
  if echo "$QRESULT" |grep -wq aurora_version; then
    true
  else
    false
  fi
}

function db_ignored_when_empty () {
  local WHICH_DB="$1"
  if [ -z "$WHICH_DB" ]; then
    err "Unexpected zero length argument: WHICH_DB='$WHICH_DB'"
    exit 1
  fi
  # IGNORE_EMPTY_DB_PATTERN was added to mysql-backups.conf 2019-03-08. It may not exist in this server's config.
  local IGNORE_EMPTY=${IGNORE_EMPTY_DB_PATTERN:-}
  if [ -z "${IGNORE_EMPTY:-}" ] ; then
    # IGNORE_EMPTY_DB_PATTERN is either unconfigured, or it's a zero length string. Either way, no empty databases are ignored.
    cerr "IGNORE_EMPTY_DB_PATTERN is empty"
    false
    return
  fi
  if echo "${WHICH_DB}" | grep -E "$IGNORE_EMPTY" >> /dev/null; then
    true  # The database in question matches the ignore pattern. Ignore empties.
  else
    false  # The DB in question did not match the pattern. Notify that it's empty.
  fi
}

function err () {
  cerr "ERROR: $*"
}

function cerr () {
  >&2 echo "$@"
}


main "$@"
