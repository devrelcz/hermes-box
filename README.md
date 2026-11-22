# Hermes Agent in Docker

Runs [Hermes Agent](https://github.com/NousResearch/hermes-agent) on your own
server: the agent with its cron jobs, the Webapp (Hermes Desktop in a browser,
including Bots) on your domain, and a daily backup.

One command installs it on an empty server. The server ends up with Docker
and one private key; the secrets are encrypted files, so no outside service
holds them.

## What you need

- A Linux server (x86_64, with systemd) and root on it.
- A domain that points at the server, with ports 80 and 443 open.
- 4 GB of RAM (with swap) and 40 GB of disk.

No domain yet? Use `<address>.sslip.io` as the host name, for example
`203.0.113.7.sslip.io`. It resolves to that address and gets a certificate
like any other name.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/devrelcz/hermes-box/master/get.sh | sudo bash
```

The script first says what it is about to do and what it puts on the server,
and asks before it changes anything. Then it installs Docker when it is
missing, downloads the image (several GB) and asks, in menus you move through
with the arrow keys:

1. the host name of the Webapp (or `<address>.sslip.io` without a domain),
2. a user name and password for the Webapp,
3. whether to choose the model now (Hermes' own wizard, after the download).

Then it starts everything, runs the first backup and checks the result. The
Webapp is at `https://<your host name>`. The long steps show a single progress
line; their output is in `/var/log/hermes-box-setup.log`, and `--verbose`
(`... | sudo bash -s -- --verbose`) shows it as it runs.

Two things to do right after the installation:

- Copy the private key `/etc/hermes/credentials/age.key` off the server, for
  example into a password manager. Without it the secrets and the backups
  cannot be read.
- Keep the directory `/opt/hermes-box/instance/` off the server too, best as
  a private git repository. It holds this installation's settings and
  encrypted secrets.

The wizard can be run again at any time (`cd /opt/hermes-box && ./setup.sh`);
it skips what is already done. For an unattended installation, an
installation without piping a script into a shell, or one from git, see
[Installation in detail](docs/installation.md).

## Mobile app

[Hermes Hobs](https://github.com/devrelcz/hermes-hobs) signs in with the same
user name and password as the browser. Instead of typing them on a phone,
scan a QR code. The wizard offers the code at the end of the installation.
Later:

```bash
cd /opt/hermes-box && ./pair.sh
```

`pair.sh` sets a new Webapp password, because the server stores only a hash
of the current one and cannot show it again. The old password stops working,
in the browser too, and every signed-in device has to sign in again. Run it
also when a phone is lost.

The code is the password in readable form. Do not screenshot it.

## Model and provider

Until a model is chosen, the agent does not answer; `./check.sh` says so. To
choose one, or to change it later:

```bash
docker exec -it -u 1000:1000 -e HOME=/opt/data hermes hermes setup model
```

```bash
systemctl restart hermes-docker
```

Use `hermes setup model`, not `hermes setup`: the full Hermes setup asks about
much more than the model.

## Everyday commands

Run them as root in `/opt/hermes-box`.

Check everything at once (services, containers, web, certificate, backup,
disk space). It exits with an error when something is wrong:

```bash
./check.sh
```

Agent logs:

```bash
docker logs -f --tail 100 hermes
```

Restart everything (about a minute of downtime):

```bash
systemctl restart hermes-docker
```

Add or change a secret the agent receives, such as an API key or a mail
password:

```bash
SOPS_AGE_KEY_FILE=/etc/hermes/credentials/age.key ./sops.sh secrets/hermes.enc.yaml
```

```bash
./install.sh --restart
```

The `hermes` command inside the container:

```bash
docker exec -it -u 1000:1000 -e HOME=/opt/data hermes hermes --help
```

## Updating

```bash
curl -fsSL https://raw.githubusercontent.com/devrelcz/hermes-box/master/get.sh | sudo bash -s -- --update
```

This fetches the latest release and restarts the stack. Your settings and
data stay as they are. Run a backup first: `systemctl start hermes-backup`.

Which version is running: `cat /opt/hermes-box/release.env`. To go back to an
earlier one, or to update by hand, see
[Installation in detail](docs/installation.md#updating-by-hand).

## Backup

A backup runs daily at 03:30 and keeps 7 daily, 4 weekly and 3 monthly
snapshots. It is stored on the same disk as the data: it protects against
deletion and a broken database, not against losing the disk. Restoring files
or a whole server is described in [Backup and restore](docs/backup.md).

## More

| Page | What is in it |
| --- | --- |
| [Installation in detail](docs/installation.md) | unattended and manual installation, settings in `instance/.env`, another server, installing from git, automatic deployment, releasing |
| [What runs on the server](docs/server.md) | containers, data and files, your own containers and checks, alerts, web search and the browser, a screen for a bot, the look of the Webapp |
| [Secrets](docs/secrets.md) | how secrets are encrypted, edited and shared with another person or server |
| [Backup and restore](docs/backup.md) | what is backed up, restoring files, restoring the server |

## Licence

[MIT](LICENSE). Hermes Agent itself, Caddy and the other tools used have their
own licences.
