# Backup and restore

The backup CronJob (`backup.enabled=true`) runs nightly:

1. `mariadb-dump --single-transaction` of the Mautic database (no table
   locks), using the same image as the bundled MariaDB (override with
   `backup.dumpImage`).
2. `restic backup` of the dump, `config/` and `media/` into
   `backup.repository` — encrypted, deduplicated and compressed.
3. `restic forget --prune` with the configured retention, then
   `restic check --read-data-subset=1%`.

It works the same with the bundled MariaDB and with `externalDatabase`.

## Setup (S3)

```bash
kubectl -n mautic create secret generic mautic-backup \
  --from-literal=RESTIC_PASSWORD="$(openssl rand -base64 32)" \
  --from-literal=AWS_ACCESS_KEY_ID=... \
  --from-literal=AWS_SECRET_ACCESS_KEY=...
```

```yaml
backup:
  enabled: true
  repository: s3:https://s3.eu-central-1.amazonaws.com/my-backups/mautic
  existingSecret: mautic-backup
```

**Store `RESTIC_PASSWORD` somewhere else as well** — without it the backups
cannot be decrypted. Any restic backend works (B2, Azure, GCS, SFTP, REST
server); see the restic documentation for the variables each one needs.

Run a backup now:

```bash
kubectl -n mautic create job --from=cronjob/mautic-backup backup-manual
```

## Restore

```bash
# 1. stop Mautic
kubectl -n mautic scale deploy/mautic deploy/mautic-worker --replicas=0

# 2. restore the latest snapshot into a scratch volume / your machine
restic -r s3:https://s3.eu-central-1.amazonaws.com/my-backups/mautic restore latest --target ./restore

# 3. load the dump
mariadb -h <db-host> -u mautic -p mautic < ./restore/backup/database.sql

# 4. copy config/ and media/ back into the data volume
#    (e.g. kubectl cp into a temporary pod that mounts the PVC)

# 5. start Mautic again
kubectl -n mautic scale deploy/mautic deploy/mautic-worker --replicas=1
```

Test restores regularly — a backup you have never restored is a hope, not a
backup.
