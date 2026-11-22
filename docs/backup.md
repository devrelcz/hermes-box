# Backup and restore

`hermes-backup.timer` runs `backup/hermes-backup.sh` daily at 03:30:

1. it copies all SQLite databases through the backup API (consistent even while
   running),
2. it stores them, together with the Hermes state, `BACKUP_EXTRA_PATHS`,
   `openknowledge`, `projects`, the tool configuration and this repository
   including `instance/` and the encrypted secrets, in the restic repository
   `<data>/backups/restic-repo`,
3. it keeps 7 daily, 4 weekly and 3 monthly snapshots and verifies the
   repository.

It leaves out everything Hermes can download or build again.

Manual run and result:

```bash
systemctl start hermes-backup && journalctl -u hermes-backup -n 30 --no-pager
```

**Limitation:** the repository is on the same disk as the data. It protects
against deletion, file corruption and a broken database, not against losing the
disk. An off-server copy can be added with `restic copy`.

The repository password is `RESTIC_PASSWORD` in
`instance/secrets/backup.enc.yaml`. The server's private key is not in the
backup.

## Restoring files from a backup

As root in the repository directory (paths for the default `HERMES_DATA_DIR`):

```bash
mkdir -p /restore
```

```bash
export RESTIC_PASSWORD="$(docker run --rm --network none -e SOPS_AGE_KEY_FILE=/age.key -v /etc/hermes/credentials/age.key:/age.key:ro -v "$PWD/instance/secrets:/secrets:ro" --entrypoint sops "$(docker inspect -f '{{.Config.Image}}' hermes)" decrypt --extract '["RESTIC_PASSWORD"]' /secrets/backup.enc.yaml)"
```

```bash
docker run --rm -e RESTIC_PASSWORD -e RESTIC_REPOSITORY=/repo -v /home/hermes/backups/restic-repo:/repo -v /restore:/restore restic/restic:0.18.1 restore latest --target /restore
```

Files are restored to `/restore/<original path>`, databases to
`/restore/home/hermes/backups/sqlite-dump/<path in the data>`. For a snapshot
other than the latest: instead of `latest`, use its ID from the `snapshots`
command. Stop `hermes-docker` before copying anything back.

## Restoring the server

When the server is gone and the data disk survives:

1. New server.
2. Mount the data disk at `HERMES_DATA_DIR` and add it to `/etc/fstab`.
   With a Hetzner Volume **do not run `mkfs`** from their instructions; it
   would erase the data.
3. Follow the [installation](installation.md#existing-installation-restore-another-server); clone `instance/` from your repository or
   take it from a backup. Either restore the private key from a copy to
   `/etc/hermes/credentials/age.key`, or let `install.sh` create a new one and
   add it to the recipients.
4. Point DNS at the new address. Caddy issues the certificate by itself.

When the data disk is gone too, the data is lost; see the backup limitation
above.
