#!/bin/bash

set -uo pipefail

DAY=`date +"%d"`
S3CMD="/usr/local/bin/s3cmd"

# databases

echo "SHOW DATABASES;" | \
  mysql --user=%MYSQL_USER% --password=%MYSQL_PASSWORD% | \
  grep -v -E "^(Database|mysql|sys|information_schema|performance_schema)$" | \
  while read DATABASE; do

    echo "Backing up database: $DATABASE"

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
      echo "ERROR: Failed to backup database: $DATABASE" >&2
    else
      echo "Successfully backed up database: $DATABASE"
    fi

  done

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
