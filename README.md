# Backup

Automated daily backup script for databases and sites to S3.

## What it does

- Dumps all MySQL databases (excluding system databases) and uploads them compressed to S3 (if MySQL is installed)
- Dumps all PostgreSQL databases (excluding `postgres`) and uploads them compressed to S3 (if PostgreSQL is installed)
- Archives site files (`/var/www/*/`) including `.env`, `certs`, `conf`, and `persistent` directories and uploads them compressed to S3
- Backups rotate on a 31-day cycle based on day of month
- Uploads are rate-limited to 1 MB/s via `pv` (configurable)

## Performance

The script is designed to minimize impact on the host server:

- **Low process priority** — runs with `nice -n 19` (lowest CPU priority) and `ionice -c3` (idle I/O class) so production workloads always take precedence
- **Parallel compression** — uses `pigz` (parallel gzip) when available, falling back to `gzip`
- **Moderate compression level** — uses level 6 instead of 9, which is 3-4x faster with only ~2-5% larger output
- **Streaming dumps** — `mysqldump --quick` streams rows directly instead of buffering entire tables in memory
- **Rate-limited uploads** — prevents network saturation (configurable via `BACKUP_RATE_LIMIT`)
- **Per-backup timing** — logs duration for each backup to help identify bottlenecks

## S3 structure

```
s3://rocketeers/backups/{server}/{name}/databases/{day}.sql.gz
s3://rocketeers/backups/{server}/{name}/files/{day}.tar.gz
```

## Requirements

- `mysql` / `mysqldump` (optional)
- `psql` / `pg_dump` (optional)
- `s3cmd` (at `/usr/local/bin/s3cmd`)
- `pv`
- `gzip` or `pigz` (recommended)

## Configuration

The following placeholders in `backup.sh` must be replaced before deployment:

| Placeholder | Description |
| --- | --- |
| `%MYSQL_USER%` | MySQL username |
| `%MYSQL_PASSWORD%` | MySQL password |
| `%SERVER%` | Server identifier for S3 |
| `%POSTGRES_USER%` | PostgreSQL username |

### Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `BACKUP_RATE_LIMIT` | `1m` | Upload rate limit passed to `pv -L` (e.g. `5m` for 5 MB/s, `0` to disable) |

## Usage

```bash
# typically run via cron, e.g. daily at 3:00 AM
0 3 * * * /path/to/backup.sh >> /var/log/backup.log 2>&1

# with a custom rate limit
0 3 * * * BACKUP_RATE_LIMIT=5m /path/to/backup.sh >> /var/log/backup.log 2>&1
```

## TODO

- [ ] Discord notifications on success/failure
- [ ] Slack notifications on success/failure
- [ ] Telegram notifications on success/failure
