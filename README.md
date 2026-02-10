# Backup

Automated daily backup script for databases and sites to S3.

## What it does

- Dumps all MySQL databases (excluding system databases) and uploads them gzipped to S3
- Archives site files (`/var/www/*/`) including `.env`, `certs`, `conf`, and `persistent` directories and uploads them gzipped to S3
- Backups rotate on a 31-day cycle based on day of month
- Uploads are rate-limited to 1 MB/s via `pv`

## S3 structure

```
s3://rocketeers/backups/{server}/{name}/databases/{day}.sql.gz
s3://rocketeers/backups/{server}/{name}/files/{day}.tar.gz
```

## Requirements

- `mysql` / `mysqldump`
- `s3cmd` (at `/usr/local/bin/s3cmd`)
- `pv`
- `gzip`

## Configuration

The following placeholders in `backup.sh` must be replaced before deployment:

| Placeholder | Description |
| --- | --- |
| `%MYSQL_USER%` | MySQL username |
| `%MYSQL_PASSWORD%` | MySQL password |
| `%SERVER%` | Server identifier for S3 |

## Usage

```bash
# typically run via cron, e.g. daily at 3:00 AM
0 3 * * * /path/to/backup.sh >> /var/log/backup.log 2>&1
```

## TODO

- [ ] Discord notifications on success/failure
- [ ] Slack notifications on success/failure
- [ ] Telegram notifications on success/failure
