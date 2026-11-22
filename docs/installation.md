# Installation in detail

The [README](../README.md) covers the usual case: one command, a few
questions. This page has the rest.

## Requirements

You need a server with Linux (x86_64, with systemd), a domain pointing at its
address, and ports 80 and 443 open. Everything is run as root.

Size: the image is about 5 GB, Firecrawl's images about 6 GB, and a fresh
installation takes about 15 GB of disk; an update needs room for a second
image for a while, so plan for 40 GB or more. When idle, the agent's container
uses about 250 MB of memory and Firecrawl about 2 GB. 4 GB of RAM is a
sensible minimum, and with that little the server needs swap.

To try it out without a domain of your own, use `<address>.sslip.io` as the
host name, for example `203.0.113.7.sslip.io`: it resolves to that address and
gets a certificate like any other name.

## New installation

One command, on a server with nothing installed:

```bash
curl -fsSL https://raw.githubusercontent.com/devrelcz/hermes-box/master/get.sh | sudo bash
```

[`get.sh`](../get.sh) installs Docker when it is missing (with Docker's own
script, <https://get.docker.com>, which covers Debian, Ubuntu, Fedora, CentOS
and RHEL), pulls the published image, extracts `compose.yaml`, the scripts and
the systemd units from it into `/opt/hermes-box` and starts the wizard.
Nothing is built or cloned. Run again on a server that is already installed,
it only starts the wizard again.

Another release or directory is chosen through the environment, and the
wizard's answers can be given the same way, which makes the installation
unattended:

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

On Debian and Ubuntu the wizard installs a missing `curl`, `jq`, `openssl` and
`python3` by itself.

The wizard asks a few questions and performs the whole initial setup:

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

After the installation, store the private key
(`/etc/hermes/credentials/age.key`) and the `instance/` directory off the
server, ideally as a private git repository.

## Pairing the mobile app

[Hermes Hobs](https://github.com/devrelcz/hermes-hobs) signs in to the Webapp
with the same user name and password as the browser. Instead of typing them
on a phone, scan a QR code: it carries the server's address, the user name and
the password.

`setup.sh` offers the code at the end of a first installation, for the
password chosen there. Later:

```bash
cd /opt/hermes-box && ./pair.sh
```

Only a hash of the password is stored, so the current one cannot be shown
again: `pair.sh` sets a new password (your own, or a random one it prints),
restarts the stack and shows the code for it. The old password stops working,
in the browser too, and every signed-in device has to sign in again. That is
also what to do about a lost phone.

The code is the password in readable form. It is drawn on a terminal only,
never in an unattended run, and wiped from the screen once you confirm the
scan. Do not screenshot it. What it holds:

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
