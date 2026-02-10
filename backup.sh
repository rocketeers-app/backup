#!/bin/bash

set -uo pipefail

DAY=`date +"%d"`
S3CMD="/usr/local/bin/s3cmd"

# mysql databases

if command -v mysql &> /dev/null; then

  echo "SHOW DATABASES;" | \
    mysql --user=%MYSQL_USER% --password=%MYSQL_PASSWORD% | \
    grep -v -E "^(Database|mysql|sys|information_schema|performance_schema)$" | \
    while read DATABASE; do

      echo "Backing up MySQL database: $DATABASE"

      mysqldump --user=%MYSQL_USER% --password=%MYSQL_PASSWORD% \
        --add-drop-table \
        --extended-insert \
        --single-transaction \
        --skip-comments \
        --routines \
        --events \
        --no-tablespaces \
        "$DATABASE" | \
        gzip -9 | \
        pv -L 1m -q | \
        $S3CMD --acl-private put - s3://rocketeers/backups/%SERVER%/$DATABASE/databases/$DAY.sql.gz

      if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to backup MySQL database: $DATABASE" >&2
      else
        echo "Successfully backed up MySQL database: $DATABASE"
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

      pg_dump --user=%POSTGRES_USER% \
        --no-owner \
        --no-acl \
        "$DATABASE" | \
        gzip -9 | \
        pv -L 1m -q | \
        $S3CMD --acl-private put - s3://rocketeers/backups/%SERVER%/$DATABASE/databases/$DAY.sql.gz

      if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to backup PostgreSQL database: $DATABASE" >&2
      else
        echo "Successfully backed up PostgreSQL database: $DATABASE"
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

  tar -cpf - \
    --ignore-failed-read \
    --exclude="$DIR/persistent/storage/app/public/cache" \
    "$DIR/.env" \
    "$DIR/certs" \
    "$DIR/conf" \
    "$DIR/persistent" | \
    gzip -9 | \
    pv -L 1m -q | \
    $S3CMD --acl-private put - s3://rocketeers/backups/%SERVER%/$SITE/files/$DAY.tar.gz

  if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to backup site: $SITE" >&2
  else
    echo "Successfully backed up site: $SITE"
  fi

done
