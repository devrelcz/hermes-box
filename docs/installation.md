# Installation in detail

The [README](../README.md) covers the usual case: one command, a few
questions. This page has the rest.

## Requirements

You need a server with Linux (x86_64, with systemd), a domain pointing at its
address, and ports 80 and 443 open. Everything is run as root.

Size: the image is about 5 GB, and a fresh installation takes about 9 GB of
disk; an update needs room for a second image for a while, so plan for 40 GB
or more. When idle, the agent's container uses about 250 MB of memory and
SearXNG, for web search, about 120 MB; a browser the agent opens, and a bot's
screen, take much more. 4 GB of RAM is a sensible minimum, and with that
little the server needs swap.

To try it out without a domain of your own, use `<address>.sslip.io` as the
host name, for example `203.0.113.7.sslip.io`: it resolves to that address and
gets a certificate like any other name.

## New installation

One command, on a server with nothing installed:

```bash
curl -fsSL https://raw.githubusercontent.com/devrelcz/hermes-box/master/get.sh | sudo bash
```

[`get.sh`](../get.sh) installs `python3` and `openssl` when they are missing,
starts the [installer](#the-installers-api) as the systemd unit
`hermes-box-installer` and prints its address. The installer does the rest,
started and watched from its page: it installs Docker when it is missing
(with Docker's own script, <https://get.docker.com>, which covers Debian,
Ubuntu, Fedora, CentOS and RHEL), pulls the published image, extracts
`compose.yaml`, the scripts and the systemd units from it into
`/opt/hermes-box` and runs `setup.sh` with the answers given on the page.
Nothing is built or cloned. Run again on a server that is already installed,
the installer offers only what was skipped so far.

With `--terminal` there is no installer: `get.sh` does the same steps itself
and `setup.sh` asks its questions in the terminal, in menus.

Another release or directory is chosen through the environment, and the
answers can be given the same way, which makes the installation unattended
(it then runs in the terminal, without the installer):

```bash
curl -fsSL https://raw.githubusercontent.com/devrelcz/hermes-box/master/get.sh | sudo INSTALL_IMAGE=ghcr.io/devrelcz/hermes-box:1.0.0 SETUP_DOMAIN=agent.example.com bash
```

The same by hand, when Docker is already there and you would rather not pipe
a script into a shell:

```bash
docker run --rm -v /opt/hermes-box:/out --entrypoint hermes-box-extract ghcr.io/devrelcz/hermes-box:1
```

```bash
cd /opt/hermes-box && ./setup.sh
```

The `:1` tag is the latest release of the 1 series. The installation remembers
the exact version it received (`release.env`) and does not change by itself;
see [Updating](../README.md#updating).

On Debian and Ubuntu `setup.sh` installs a missing `curl`, `jq`, `openssl` and
`python3` by itself.

In the terminal, the wizard asks its questions first (in menus: arrow keys or the item's
number, then Enter), so the long part afterwards runs without anybody watching.
Only Hermes' own model wizard comes after the download, because it runs from
the image. Then it performs the whole initial setup:

1. the Webapp domain → `instance/.env`,
2. user, data directories, the server's private key,
3. the first encrypted secrets, including a random backup password,
4. model and provider: runs Hermes's own wizard,
5. Webapp login: a user name and password,
6. installation of the services, start, first backup and check,
7. a QR code that signs the [mobile app](#pairing-the-mobile-app) in.

It can be run again, also on a server that is already running; finished
steps are skipped. This is how the model or the Webapp login is added later;
the stack is restarted when something was added. The questions can be
answered in advance with the `SETUP_*` variables (see the header of
`setup.sh`), in which case it runs without prompting; step 4 needs a terminal
and is skipped without one.

Each long step shows one progress line. What the commands print goes to
`/var/log/hermes-box-setup.log`; when a step fails, its last lines are shown.
`--verbose` (for `get.sh` and `setup.sh`) shows everything as it runs, and
`--yes` (`get.sh`) skips the question before the installation starts.

After the installation, store the private key
(`/etc/hermes/credentials/age.key`) and the `instance/` directory off the
server, ideally as a private git repository.

## The installer's API

The installer ([`installer/server.py`](../installer/server.py)) is an HTTPS
API; the page is one client of it. It exists only for the installation:

- **Certificate.** `get.sh` makes one for this run and prints its SHA-256
  fingerprint. Nobody signs a certificate for a bare address, so a browser
  warns once; continue only when the fingerprint it shows is the printed
  one. A program should check the certificate too: copy it over SSH, which
  already knows the server, and give it to `curl` with `--cacert` (below).
  Do not switch the check off with `-k`: the token and the new password
  would go to whoever sits in between.
- **Token.** Every call except `/api/health` needs
  `Authorization: Bearer <token>`. The token is the part of the printed
  address after `#`; a browser never sends that part to the server. It is
  good for two hours from the start, whatever the installation is doing (a
  step that is running is allowed to end); then the installer stops.
- **Lifetime.** It stops on `POST /api/finish`, or by itself 15 minutes
  after the installation is done, and deletes the certificate and the token;
  nothing listens on its port afterwards.
  `systemctl stop hermes-box-installer` stops it at any time; running
  `get.sh` again starts a new one, or prints the address of a running one.
- **Password.** It is kept in memory for `setup.sh` and for the mobile app's
  code, and forgotten 15 minutes after the installation; `GET /api/pair`
  works only until then.
- **Where it listens.** On every address, port 8443. `INSTALL_PORT` changes
  the port; `INSTALL_BIND=127.0.0.1` makes it reachable through an SSH tunnel
  only (`ssh -L 8443:127.0.0.1:8443 root@<server>`). It serves at most 48
  connections at a time and 8 from one address; more are refused before
  they cost anything.
- **Its files.** `get.sh` downloads them from the same release as the image
  (`INSTALL_IMAGE=...:1.4.0` is the tag `v1.4.0`; `INSTALL_REF` names another)
  and runs them only when their SHA-256 is the one it carries. Take `get.sh`
  from the same release: `.../hermes-box/v1.4.0/get.sh`.

| Call | What it does |
|---|---|
| `GET /api/health` | `{"ok": true}`; no token |
| `GET /api/state?log_from=N` | the phase, the steps, what is still needed, the log from line N |
| `POST /api/start` | begins the installation; the body may carry answers already |
| `POST /api/answers` | `{"domain": ..., "user": ..., "password": ...}`, any subset |
| `GET /api/domain?name=...` | where a host name points, and whether that is this server |
| `POST /api/retry` | runs a failed step again |
| `GET /api/pair` | the mobile app's QR code, as rows of 0 and 1 |
| `POST /api/finish` | stops the installer |

The phases in the state are `idle` (nothing has changed yet), `running`,
`waiting` (an answer is missing; `missing` names it: `domain`, `login`),
`failed` (`error` says which step; the log says why) and `done` (`summary`
has the Webapp's address). The steps are `docker`, `download`, `extract` and
`setup`; the last one lists the steps of `setup.sh` as they run. The answers
can be sent at any time before `setup` starts; without them the installation
runs up to there and waits.

A whole installation with `curl`. First the certificate, over SSH:

```bash
scp root@203.0.113.7:/var/lib/hermes-box-installer/tls.crt hermes-box.crt
```

```bash
curl --cacert hermes-box.crt -H "Authorization: Bearer $TOKEN" -X POST https://203.0.113.7:8443/api/start -d '{"domain": "agent.example.com", "user": "admin", "password": "at least 12 characters"}'
```

```bash
curl --cacert hermes-box.crt -H "Authorization: Bearer $TOKEN" https://203.0.113.7:8443/api/state
```

The model is not part of the installation: it is chosen afterwards, in the
Webapp or with Hermes' own wizard (README, Model and provider).

The page asks for the user name and the password only. Where the server has
a public address, it sends `<address>.sslip.io` as the domain unless a domain
of your own is filled in; behind NAT it asks for the domain as well. It shows
the progress as one bar and keeps the log for the case that a step fails.

## Pairing the mobile app

[Hermes Hobs](https://github.com/devrelcz/hermes-hobs) signs in to the Webapp
with the same user name and password as the browser. Instead of typing them
on a phone, scan a QR code: it carries the server's address, the user name and
the password.

The installer's page shows the code at the end of a first installation, for
the password chosen there (`setup.sh` in the terminal offers it too). Later:

```bash
cd /opt/hermes-box && ./pair.sh
```

Only a hash of the password is stored, so the current one cannot be shown
again: `pair.sh` sets a new password (your own, or a random one it prints),
restarts the stack and shows the code for it. The old password stops working,
in the browser too, and every signed-in device has to sign in again. That is
also what to do about a lost phone.

The code is the password in readable form. It is drawn on a terminal or on
the installer's page only, never in an unattended run, and wiped from the
terminal once you confirm the scan. Do not screenshot it. What it holds:

```json
{"v":1,"url":"https://agent.example.com","user":"admin","password":"..."}
```

## Existing installation, restore, another server

Extract the files from the image as for a new installation, clone your
instance repository into `/opt/hermes-box/instance/` and run:

```bash
./install.sh
```

The script checks the prerequisites, creates the user and directories, pulls or
builds the image, verifies the key and secrets, configures the Webapp and the browser in
`config.yaml`, installs the systemd units and starts the stack. It can be run
repeatedly; it does not change existing data. It leaves a running stack alone
unless it is given `--restart`. On a new server it creates a key and prints its
public part; that has to be added to the recipients of the secrets (see
[Secrets](secrets.md)).

## Settings in `instance/.env`

| Variable | Default | Meaning |
| --- | --- | --- |
| `HERMES_DOMAIN` | – | public address of the Webapp; DNS must point at the server |
| `SOPS_AGE_KEY_FILE` | `/etc/hermes/credentials/age.key` | the server's private key |
| `BACKUP_EXTRA_PATHS` | empty | further paths in the data directory to back up, separated by spaces |
| `AUTO_DEPLOY` | off | `true`: the server deploys new commits by itself |
| `HERMES_DATA_DIR` | `/home/hermes` | where all state lives |
| `HERMES_UID`, `HERMES_GID` | `1000` | owner of the data |
| `HERMES_BOX_IMAGE` | from `release.env` | an image other than the one the installation came with |
| `HERMES_IMAGE_TAG` | the version in the `Dockerfile` | only when building yourself: another Hermes version, e.g. `v0.23.3` for an image without Bot Desktop |

The `.env` file in the root is only a link to `instance/.env`, created by
`install.sh`.

## Updating by hand

A new version is a new image. The [README](../README.md#updating) has the
one-command update. By hand: extract the files from the new image over the
existing ones and deploy:

```bash
docker run --rm -v /opt/hermes-box:/out --entrypoint hermes-box-extract ghcr.io/devrelcz/hermes-box:1
```

```bash
cd /opt/hermes-box && ./install.sh --restart
```

Neither `instance/` nor the data changes. It is a good idea to run a backup
before updating (`systemctl start hermes-backup`).

Going back to a previous version is the same with its exact tag, e.g. `:1.0.0`.
Which version is running: `cat /opt/hermes-box/release.env`.

## Installing from git

For development, and for a server that should follow a branch: clone the
repository instead of extracting it from the image. Without `release.env`,
`install.sh` builds the image itself from the `Dockerfile` (named
`hermes-agent-local`) and `AUTO_DEPLOY` can be enabled.

```bash
git clone https://github.com/devrelcz/hermes-box.git /opt/hermes-box
```

```bash
cd /opt/hermes-box && ./setup.sh
```

## Deploying a change

This applies to an installation from git (see
[Installing from git](#installing-from-git)); an installation from the image is
changed as described in [Updating](../README.md#updating).

**Automatically** (`AUTO_DEPLOY=true` in `instance/.env`): a `git push` is
enough, whether to this repository or to the instance repository. Every
5 minutes the server checks the remote branch and deploys a new commit by
itself (`deploy/hermes-deploy.sh`):

1. it fetches the commit (fast-forward only), validates the configuration, and
   if needed builds the image and updates the units,
2. it restarts the stack only when something that runs in the containers has
   changed (`compose.yaml`, `Dockerfile`, `docker/`, `caddy/`, `instance/.env`,
   `instance/compose.yaml`, `instance/secrets/`); it waits until no cron job
   is about to start,
3. it runs `check.sh`; if that fails, it rolls back to the previous commit and
   image,
4. it writes the result to the journal (`journalctl -u hermes-deploy`) and
   hands it to `instance/notify.sh`, if there is one.

A commit whose deployment failed is not retried; fix it with a new commit.
To retry the same one: `rm /var/lib/hermes-deploy/failed-commit`.

Two builds of the image are kept: the running one and the one before it, for
the rollback. Older builds, and a build that was rolled back, are removed after
each build, because each takes several GB and `check.sh` fails a deploy once
the disk is 85% full.

To run it immediately without waiting for the timer:
`systemctl start hermes-deploy`.

To pause the automation, for example during manual work on the server:

```bash
touch deploy/PAUSE
```

Whoever can push to the deployed branch runs code on the server as root.
Protect the branch on GitHub and keep two-factor authentication on the account.

**Manually:**

```bash
git pull --ff-only && ./install.sh --restart
```

A restart means about a minute of downtime, including the web.
Without `--restart` only the image is built and the units are updated.

## Releasing a new version

The Hermes version is pinned in the `Dockerfile` (the `pinned` stage).
Upgrading Hermes is a change of that tag; CI builds and tests the image in
every pull request, so a version the `Dockerfile` does not fit will not pass.
Dependabot (`.github/dependabot.yml`) checks daily and opens that pull request
when Hermes publishes a new version; merging it and releasing stay manual.

A release is a tag of the form `v1.2.3`:

```bash
git tag v1.2.3 && git push origin v1.2.3
```

CI publishes `ghcr.io/devrelcz/hermes-box:1.2.3` and moves `:1.2` and `:1`.
A tag with a suffix (`v1.2.3-rc.1`) publishes only itself.
