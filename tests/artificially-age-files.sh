#!/bin/bash
set -u; set -e; set -o pipefail

export DB_NAME="foo_db"
export TARGET_DIR="/tmp/mysql-backups-simulation/$DB_NAME"

usage () {
  echo "Usage: "
  echo "$(basename "$0") N <minute|hour|day>"
}

main () {
  if [ $# -ne 2 ]; then
    usage
    exit 0
  fi

  HOW_MANY="${1:-}"
  OF_WHAT="${2:-}"

  ONE_MINUTE=60
  ONE_HOUR=3600
  ONE_DAY=86400

  while IFS= read -r -d '' FILE; do
    EPOCH_TIME=$(stat --format %Y "${FILE}")
    if [[ "$OF_WHAT" == "hour" ]]; then
      NEW_DATE=$((EPOCH_TIME - (HOW_MANY * ONE_HOUR)))
    elif [[ "$OF_WHAT" == "minute" ]]; then
      NEW_DATE=$((EPOCH_TIME - (HOW_MANY * ONE_MINUTE)))
    elif [[ "$OF_WHAT" == "day" ]]; then
      NEW_DATE=$((EPOCH_TIME - (HOW_MANY * ONE_DAY)))
    else
      usage
      exit 1
    fi
    NEW_FILE_NAME="${DB_NAME}.$(date -d "@$NEW_DATE" "+%Y-%m-%d-%H%M")"
    touch -d "@${NEW_DATE}" "${FILE}"
    mv "$FILE" "$TARGET_DIR/${NEW_FILE_NAME}.sql.gz"
  done < <(find "$TARGET_DIR"  -maxdepth 1 -name '*.????-??-??-????.sql.gz' -type f -print0 |sort -r -z)

}

main "$@"
