#!/bin/bash

set -uo pipefail

DAY=$(date +"%d")
S3CMD="/usr/local/bin/s3cmd"
BACKUP_START=$(date +%s)

# configurable rate limit (default: 1 MB/s), set to 0 to disable
RATE_LIMIT="${BACKUP_RATE_LIMIT:-1m}"

# discord webhook for notifications (leave empty to disable)
DISCORD_WEBHOOK_URL="%DISCORD_WEBHOOK_URL%"

# collect errors in a temp file so subshells (piped while-read loops) can append to it
ERRORS_FILE=$(mktemp)
trap "rm -f $ERRORS_FILE" EXIT

# run backups at lowest CPU and I/O priority so production traffic is unaffected
NICE="nice -n 19"
IONICE=""
if command -v ionice &> /dev/null; then
  IONICE="ionice -c3"
fi

# prefer pigz (parallel gzip) over gzip; use compression level 6 (default)
# level 9 is 3-4x slower than level 6 with only ~2-5% smaller output
if command -v pigz &> /dev/null; then
  COMPRESS="pigz -6"
else
  COMPRESS="gzip -6"
fi

# check required dependencies

MISSING=()

command -v $COMPRESS &> /dev/null || MISSING+=("gzip or pigz")
command -v pv &> /dev/null || MISSING+=("pv")
command -v tar &> /dev/null || MISSING+=("tar")
[[ -x "$S3CMD" ]] || MISSING+=("s3cmd ($S3CMD)")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: Missing required dependencies: ${MISSING[*]}" >&2
  exit 1
fi

# upload helper with retry logic (exponential backoff)
upload_to_s3() {
  local s3_path="$1"
  local max_retries=3
  local attempt=0
  local wait_time=2

  while read -r chunk; do
    echo -n "$chunk"
  done | while true; do
    attempt=$((attempt + 1))

    if pv -L "$RATE_LIMIT" -q | $S3CMD --acl-private put - "$s3_path"; then
      return 0
    fi

    if [[ $attempt -ge $max_retries ]]; then
      echo "ERROR: S3 upload failed after $max_retries attempts: $s3_path" >&2
      return 1
    fi

    echo "WARN: S3 upload attempt $attempt failed, retrying in ${wait_time}s..." >&2
    sleep $wait_time
    wait_time=$((wait_time * 2))
  done
}

# mysql databases

if command -v mysql &> /dev/null; then

  echo "SHOW DATABASES;" | \
    mysql --user=%MYSQL_USER% --password=%MYSQL_PASSWORD% | \
    grep -v -E "^(Database|mysql|sys|information_schema|performance_schema)$" | \
    while read DATABASE; do

      echo "Backing up MySQL database: $DATABASE"
      START=$(date +%s)

      $IONICE $NICE mysqldump --user=%MYSQL_USER% --password=%MYSQL_PASSWORD% \
        --add-drop-table \
        --extended-insert \
        --single-transaction \
        --quick \
        --skip-comments \
        --routines \
        --events \
        --no-tablespaces \
        "$DATABASE" | \
        $IONICE $NICE $COMPRESS | \
        pv -L "$RATE_LIMIT" -q | \
        $S3CMD --acl-private put - s3://rocketeers/backups/%SERVER%/$DATABASE/databases/$DAY.sql.gz

      PIPE_STATUS=("${PIPESTATUS[@]}")
      ELAPSED=$(( $(date +%s) - START ))

      if [[ ${PIPE_STATUS[0]} -ne 0 ]]; then
        echo "ERROR: mysqldump failed for database: $DATABASE" >&2
        echo "mysqldump failed for MySQL database: $DATABASE" >> "$ERRORS_FILE"
      elif [[ ${PIPE_STATUS[1]} -ne 0 ]]; then
        echo "ERROR: Compression failed for database: $DATABASE" >&2
        echo "Compression failed for MySQL database: $DATABASE" >> "$ERRORS_FILE"
      elif [[ ${PIPE_STATUS[3]} -ne 0 ]]; then
        echo "ERROR: S3 upload failed for database: $DATABASE" >&2
        echo "S3 upload failed for MySQL database: $DATABASE" >> "$ERRORS_FILE"
      else
        echo "Successfully backed up MySQL database: $DATABASE (${ELAPSED}s)"
      fi

    done

else
  echo "MySQL not installed, skipping MySQL backups"
fi

# postgresql databases

if command -v psql &> /dev/null; then

  psql --user=%POSTGRES_USER% -t -A -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres')" | \
    while read DATABASE; do

      echo "Backing up PostgreSQL database: $DATABASE"
      START=$(date +%s)

      $IONICE $NICE pg_dump --user=%POSTGRES_USER% \
        --no-owner \
        --no-acl \
        "$DATABASE" | \
        $IONICE $NICE $COMPRESS | \
        pv -L "$RATE_LIMIT" -q | \
        $S3CMD --acl-private put - s3://rocketeers/backups/%SERVER%/$DATABASE/databases/$DAY.sql.gz

      PIPE_STATUS=("${PIPESTATUS[@]}")
      ELAPSED=$(( $(date +%s) - START ))

      if [[ ${PIPE_STATUS[0]} -ne 0 ]]; then
        echo "ERROR: pg_dump failed for database: $DATABASE" >&2
        echo "pg_dump failed for PostgreSQL database: $DATABASE" >> "$ERRORS_FILE"
      elif [[ ${PIPE_STATUS[1]} -ne 0 ]]; then
        echo "ERROR: Compression failed for database: $DATABASE" >&2
        echo "Compression failed for PostgreSQL database: $DATABASE" >> "$ERRORS_FILE"
      elif [[ ${PIPE_STATUS[3]} -ne 0 ]]; then
        echo "ERROR: S3 upload failed for database: $DATABASE" >&2
        echo "S3 upload failed for PostgreSQL database: $DATABASE" >> "$ERRORS_FILE"
      else
        echo "Successfully backed up PostgreSQL database: $DATABASE (${ELAPSED}s)"
      fi

    done

else
  echo "PostgreSQL not installed, skipping PostgreSQL backups"
fi

# sites

for DIR in /var/www/*; do

  SITE=$(basename "$DIR")
  [[ $SITE = "default" ]] && continue

  echo "Backing up site: $SITE"
  START=$(date +%s)

  $IONICE $NICE tar -cpf - \
    --ignore-failed-read \
    --exclude="$DIR/persistent/storage/app/public/cache" \
    "$DIR/.env" \
    "$DIR/certs" \
    "$DIR/conf" \
    "$DIR/persistent" | \
    $IONICE $NICE $COMPRESS | \
    pv -L "$RATE_LIMIT" -q | \
    $S3CMD --acl-private put - s3://rocketeers/backups/%SERVER%/$SITE/files/$DAY.tar.gz

  PIPE_STATUS=("${PIPESTATUS[@]}")
  ELAPSED=$(( $(date +%s) - START ))

  if [[ ${PIPE_STATUS[0]} -ne 0 ]]; then
    echo "ERROR: tar failed for site: $SITE" >&2
    echo "tar failed for site: $SITE" >> "$ERRORS_FILE"
  elif [[ ${PIPE_STATUS[1]} -ne 0 ]]; then
    echo "ERROR: Compression failed for site: $SITE" >&2
    echo "Compression failed for site: $SITE" >> "$ERRORS_FILE"
  elif [[ ${PIPE_STATUS[3]} -ne 0 ]]; then
    echo "ERROR: S3 upload failed for site: $SITE" >&2
    echo "S3 upload failed for site: $SITE" >> "$ERRORS_FILE"
  else
    echo "Successfully backed up site: $SITE (${ELAPSED}s)"
  fi

done

# discord notifications

notify_discord() {
  local color="$1"
  local title="$2"
  local description="$3"

  local payload
  payload=$(cat <<PAYLOAD
{
  "embeds": [{
    "title": "$title",
    "description": "$description",
    "color": $color,
    "footer": { "text": "%SERVER%" },
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  }]
}
PAYLOAD
  )

  curl -sf -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" > /dev/null
}

if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then

  BACKUP_DURATION=$(( $(date +%s) - BACKUP_START ))
  DURATION_HOURS=$(( BACKUP_DURATION / 3600 ))
  DURATION_MINUTES=$(( (BACKUP_DURATION % 3600) / 60 ))
  DURATION_DISPLAY="${DURATION_HOURS}h ${DURATION_MINUTES}m"
  AMSTERDAM_TIME=$(TZ="Europe/Amsterdam" date +"%H:%M")
  AMSTERDAM_HOUR=$(TZ="Europe/Amsterdam" date +"%H")

  REASONS=()

  # backup took more than 5 hours
  if [[ $BACKUP_DURATION -ge 18000 ]]; then
    REASONS+=("Backup took **${DURATION_DISPLAY}** (threshold: 5h)")
  fi

  # completed after 05:00 Europe/Amsterdam
  if [[ $AMSTERDAM_HOUR -ge 5 ]] && [[ $AMSTERDAM_HOUR -lt 12 ]]; then
    REASONS+=("Completed at **${AMSTERDAM_TIME}** Amsterdam time (after 05:00)")
  fi

  # errors occurred
  if [[ -s "$ERRORS_FILE" ]]; then
    ERROR_LIST=""
    while IFS= read -r line; do
      ERROR_LIST="${ERROR_LIST}• ${line}\\n"
    done < "$ERRORS_FILE"
    REASONS+=("**Errors:**\\n${ERROR_LIST}")
  fi

  if [[ ${#REASONS[@]} -gt 0 ]]; then
    DESCRIPTION=""
    for reason in "${REASONS[@]}"; do
      DESCRIPTION="${DESCRIPTION}${reason}\\n\\n"
    done
    DESCRIPTION="${DESCRIPTION}Total duration: ${DURATION_DISPLAY}"

    if [[ -s "$ERRORS_FILE" ]]; then
      notify_discord 16711680 "Backup completed with errors" "$DESCRIPTION"
    else
      notify_discord 16744448 "Backup completed (warning)" "$DESCRIPTION"
    fi
  fi

fi
