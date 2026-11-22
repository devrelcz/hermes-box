# Secrets

They are in `instance/secrets/*.enc.yaml`, encrypted with
[SOPS](https://getsops.io) for [age](https://age-encryption.org) keys. The
names are readable, the values are not, so the files belong in git (in the
instance repository). The commands below are run in the `instance/` directory;
`./sops.sh` from the root of this repository works there by itself.

- `secrets/hermes.enc.yaml` – everything the agent receives (mail passwords,
  deploy keys, tokens). The `hermes` container decrypts the file into memory on
  start; the values are neither on disk nor in `docker inspect`.
  - A single-line value is the environment variable `NAME`.
  - A multi-line value (SSH key, JSON) is the file
    `/run/hermes-secrets/NAME`, readable only by the agent's user; the
    environment holds only the path to it in `NAME_FILE`. Otherwise a
    line-by-line listing of the environment (`printenv | cut -d= -f1`) would
    print the second and following lines of such a value in full, and the agent
    has already sent keys to the model provider this way.
- `secrets/backup.enc.yaml` – `RESTIC_PASSWORD`. Only the backup script reads
  it; the agent never receives it.

Anyone whose public key is in `instance/.sops.yaml` can decrypt them: the
server (private key in `/etc/hermes/credentials/age.key`) and whoever manages
the secrets. Without the key or the file the container exits with code 78 and
does not restart.

**Keep a copy of at least one private key off the server**, for example in a
password manager. Losing all the keys means losing the secrets and access to
the backups.

## Once, on your own computer

```bash
brew install sops age
```

On macOS `sops` looks for the key in
`~/Library/Application Support/sops/age/keys.txt` (on Linux in
`~/.config/sops/age/keys.txt`):

```bash
mkdir -p ~/Library/Application\ Support/sops/age && age-keygen -o ~/Library/Application\ Support/sops/age/keys.txt
```

A different location can be passed in the `SOPS_AGE_KEY_FILE` variable.

Add the printed public key (`age1…`) to `.sops.yaml`. Only someone who can
already decrypt the existing files can add it to their recipients (so the first
time, the server).

## Changing or adding a value

```bash
sops secrets/hermes.enc.yaml
```

This opens an editor with the decrypted contents and re-encrypts the file on
save. Then commit, push, and on the server
`git pull --ff-only && ./install.sh --restart`.

## Without installing: `sops` from Docker

`./sops.sh` runs `sops` from its official image, so Docker and the private key
are enough. The arguments are the same as for `sops`; paths are written
relative to the repository root:

```bash
./sops.sh secrets/hermes.enc.yaml
```

The editor is `vi`. The container runs without network access and the decrypted
contents exist only inside it. The key is taken from `SOPS_AGE_KEY_FILE`,
otherwise from the locations listed above. The script does not create a new
key; that requires `age-keygen`.

## New recipient (another server, another person)

Add the public key to `.sops.yaml` and re-encrypt:

```bash
sops updatekeys secrets/hermes.enc.yaml
```

```bash
sops updatekeys secrets/backup.enc.yaml
```

Removing a recipient works the same way; in addition, the values they have
already seen need to be changed at their source.
