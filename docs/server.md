# What runs on the server

How the installation is put together, and what can be changed about it.

It has two parts:

- **this repository** – the same for every installation, contains nothing
  personal,
- **the `instance/` directory** – the settings and encrypted secrets of one
  installation, and anything else only that installation runs: containers of
  its own, checks, the way alerts are delivered (see
  [Your own additions](#your-own-additions)). It is not part of this
  repository; a template and description are in
  [`instance.example/`](../instance.example/README.md).

## What runs

Seven containers. The first two use the `host` network mode:

| Container | Image | What it does | Where it listens |
| --- | --- | --- | --- |
| `hermes` | `ghcr.io/devrelcz/hermes-box:<version>`, or `hermes-agent-local` built from the `Dockerfile` | gateway: agent, cron, sessions, Bots; plus the Webapp and dashboard | Webapp `127.0.0.1:9120`, dashboard `127.0.0.1:9119` |
| `hermes-caddy` | `caddy:2.11` | TLS and reverse proxy | `80`, `443` |
| `hermes-firecrawl` and four `hermes-firecrawl-*` (Playwright, Redis, RabbitMQ, Postgres) | see `compose.yaml` | web search and page reading for the agent | API `127.0.0.1:3002`; the rest only on a network of their own |

- The **Webapp** runs at `https://<HERMES_DOMAIN>` behind a login with
  the user name and password chosen during setup.
- The **Dashboard** (administration) is not exposed. Access it through an SSH
  tunnel:

  ```bash
  ssh -L 9119:127.0.0.1:9119 <server>
  ```

  and then <http://127.0.0.1:9119>.

The containers are started by the systemd unit `hermes-docker.service` with
`docker compose up`. The `hermes` container has `restart: on-failure:5`, so
Docker brings it back up after a crash.

## Data

All state is in `HERMES_DATA_DIR`. The image is stateless.

| Path in the data directory | Contents | In the `hermes` container |
| --- | --- | --- |
| `.hermes` | config, sessions, cron, skills, profiles, `state.db` | `/opt/data` and `/home/hermes/.hermes` |
| `openknowledge` | Obsidian repository | `/home/hermes/openknowledge` |
| `projects` | projects | `/home/hermes/projects` |
| `.config/himalaya` | mail settings (the passwords are in the secrets) | `/opt/data/.config/himalaya` |
| `.local/bin` | the agent's helper scripts, e.g. an SSH wrapper for git | `/home/hermes/.local/bin` |
| `backups` | backups | not mounted |

Outside the data directory:

- the repository including `instance/`
- the server's private key
- the Docker volumes `hermes_caddy-data` and `hermes_caddy-config` –
  certificates; if lost, they are issued again

Three things that are not obvious at first sight:

- Cron jobs and skills refer to the absolute paths `/home/hermes/...`. Inside
  the container these paths therefore stay the same wherever `HERMES_DATA_DIR`
  is. The `write_file` and `patch` tools may write only into the directories in
  `HERMES_WRITE_SAFE_ROOT`. The image allows only `/opt/data`, which is why
  `compose.yaml` also adds mounts under `/home/hermes/...`. A new writable
  mount has to be added there as well.
- The home directory of the tools in the container is `/opt/data`
  (`terminal.home_mode: real` in `config.yaml`; set by `install.sh`).
  The value in `config.yaml` takes precedence over the `TERMINAL_HOME_MODE`
  variable from `compose.yaml`. With the default `auto`, scripts in the
  container would get `HOME=/opt/data/home` and would not find
  `~/.config/himalaya`. The path `~/.hermes/...` works thanks to the symlink
  `.hermes/.hermes -> .`, created by `install.sh`. It also follows that
  `~/.ssh` = `.hermes/.ssh`; `install.sh` carries `known_hosts` over there from
  the original installation.
- Both Docker and `hermes-docker.service` wait for the data disk to be mounted.
  When the disk is missing, Docker does not start at all. This is intentional:
  otherwise the containers would come up over empty directories.

## Files

| File | Purpose |
| --- | --- |
| `get.sh` | one-command installation: Docker, the files from the image, then `setup.sh` |
| `setup.sh` | first-installation wizard |
| `lib/ui.sh` | what the wizard shows: progress lines, menus (used by `setup.sh` and `pair.sh`) |
| `pair.sh` | QR code that signs the mobile app in; sets a new Webapp password |
| `install.sh` | installation and deployment of changes |
| `compose.yaml` | definition of the containers |
| `Dockerfile` | the official Hermes image + `sops`, `age`, `uv` and `himalaya`; also carries the files in this table |
| `docker/extract.sh` | extracts the files from the image onto the server (`hermes-box-extract`) |
| `release.env` | only for an installation from the image: which image is running |
| `.github/workflows/image.yml` | image build and check, release on a `v*` tag |
| `docker/secrets-entrypoint.sh` | on start, decrypts the secrets into the environment and into in-memory files |
| `instance.example/` | template of the `instance/` directory |
| `sops.sh` | `sops` from Docker, for editing secrets without an installation |
| `caddy/Caddyfile` | domain → Webapp |
| `skin/default.yaml` | CSS for the Webapp on touch screens; see [Look of the Webapp](#look-of-the-webapp) |
| `backup/hermes-backup.sh` | daily backup |
| `check.sh` | health check of the whole solution |
| `monitor/hermes-monitor.sh` | periodic check and alerts |
| `deploy/hermes-deploy.sh` | automatic deployment of new commits |
| `server/` | systemd unit templates; installed by `install.sh` |
| `docs/` | this documentation |

## Your own additions

What only your installation needs does not belong in this repository. Put it
in `instance/`; these four places are picked up when they exist:

| In `instance/` | What it does |
| --- | --- |
| `compose.yaml` | more containers, or changes to the ones here. `install.sh` links it as `compose.override.yaml`, which Compose merges into `compose.yaml`. Paths are relative to the repository directory; variables come from `instance/.env`. Apply with `./install.sh --restart`. |
| `check.d/*.sh` | one more line in `./check.sh` per script, named after the file: it passes when the script exits 0, and the last line the script printed is shown when it fails. The scripts get `REPO_DIR` and `DATA_DIR`. |
| `notify.sh` | delivery of alerts. Must be executable; gets the message as its only argument. Called by the monitor and by the automatic deployment. |
| `BACKUP_EXTRA_PATHS` in `.env` | paths inside the data directory to add to the backup, for example the state of your own container. |

A messenger daemon the gateway talks to is a typical case: its container goes
into `instance/compose.yaml`, a check that it answers into `instance/check.d/`,
its data into `BACKUP_EXTRA_PATHS`, and `instance/notify.sh` can send the
alerts through it. Create the directory for its data yourself, owned by
`HERMES_UID`; Docker would create a missing one as root.

Everything in `instance/` runs as root on the server, like this repository.

## Monitoring

`hermes-monitor.timer` runs `check.sh` every 10 minutes, and immediately after
a failed backup. When the result changes, it writes that to the journal
(`journalctl -u hermes-monitor`): one message when something breaks, and one
when everything is fine again.

To be told somewhere else, add `instance/notify.sh` (see
[Your own additions](#your-own-additions)). Whatever that script uses, it runs
on this server: when the whole server is down, nothing arrives; only an
external check of the public address covers that (UptimeRobot and the like).

## Web and browser

The agent has two ways to the web, and they are set separately in
`config.yaml`:

- **`web_search` and `web_extract`** go through a backend. Here that is the
  Firecrawl on this server, for both; see below. Another backend can be
  chosen for either half. Some only search (`brave-free`, `ddgs`, `searxng`)
  and cannot read a page; reading needs one that also extracts (`firecrawl`,
  `tavily`, `exa`, `parallel`):

  ```bash
  docker exec -u 1000:1000 -e HOME=/opt/data hermes hermes config set web.search_backend brave-free
  ```

  The keys of such a backend (`BRAVE_SEARCH_API_KEY`, `TAVILY_API_KEY`, …)
  belong in `secrets/hermes.enc.yaml`; see [Secrets](secrets.md#secrets).
- **The browser** is the Chromium that the Hermes image ships; nothing else
  has to be installed. `install.sh` sets `browser.cloud_provider: local`
  unless a provider is already chosen, and enables the `browser` and
  `terminal` toolsets for cron jobs (the browser tool is offered only together
  with the terminal). A cron job that lists its own `enabled_toolsets` has to
  name both. Other platforms are set with
  `hermes tools enable browser --platform <name>`.

### Firecrawl on this server

Searching and reading pages need no account: a Firecrawl runs here, in five
containers (API, Playwright, Redis, RabbitMQ, Postgres), and `compose.yaml`
gives the agent its address (`FIRECRAWL_API_URL`). `install.sh` sets
`web.backend: firecrawl` in `config.yaml`, which makes it the backend for both
halves; what it cannot read is left to the browser. `web.search_backend` and
`web.extract_backend` take precedence over `web.backend` and are not touched,
so a different choice for one half goes there. Hermes installs its Firecrawl
client into the data directory the first time the agent uses it. `check.sh`
watches the five containers and the API. To try it on the server:

```bash
curl -s -X POST http://127.0.0.1:3002/v2/scrape -H 'Content-Type: application/json' -d '{"url":"https://example.com","formats":["markdown"]}'
```

The API has no authentication, which is why it listens on loopback only.
Nothing in it is worth backing up: its two volumes hold a job queue. While
Firecrawl does not answer, Hermes reads pages through the free tiers of public
services instead (`web.keyless_rescue`, on by default; `false` keeps the
requests on this server and lets them fail). The versions are pinned in
`compose.yaml`; the Playwright and Postgres images are published without
version numbers, so they are pinned to a build and updated by hand together
with the API.

The browser is slower and costs more tokens than `web_extract`; it is for
pages that need JavaScript or a sign-in.

## A screen for a bot (Bot Desktop)

A bot can have a desktop of its own, with a browser that keeps its profile
between runs. You watch it in the Webapp and can take the keyboard and mouse
over, for example to sign in to a site that wants a person; the session then
stays in the bot's browser profile, and cron jobs of that bot use it.

The image has what this needs (Xvnc, Xfce, Chromium); nothing is installed on
the server. In the Webapp: **Bots**, right-click a bot, **Open Screen**,
**Start screen**, then **Take over** and, when done, **Hand back**. From a
shell:

```bash
docker exec -u 1000:1000 -e HOME=/opt/data hermes hermes computer-use screen status
```

- A screen is started only on request and stops after 30 minutes without use
  (`bot_desktop.idle_stop_minutes`). With a browser open it takes 1 to 1.5 GB
  of memory, and Hermes does not start one with less than about 1.5 GB free
  (`bot_desktop.min_free_memory_mb`).
- No port is opened. The picture goes over the Webapp's own connection, behind
  its sign-in; Xvnc listens on a socket in the data directory only.
- The bot's desktop state and browser profile are in `bot-desktop/` in the
  data directory, and so in the backup.

## Look of the Webapp

The Webapp is Hermes Desktop in a browser, and many of its controls are sized
for a mouse. `skin/default.yaml` makes them larger on a phone or tablet:
buttons, the entries of the left panel and of menus, form fields, the status
bar and the text of a conversation. `install.sh` copies it to
`<data>/.hermes/skins/default.yaml`; Hermes puts the `customCSS` of that file
into the page, and the Webapp picks a change up on the next page load.

- All rules sit in one media query for touch screens; with a mouse nothing
  changes.
- The skin is named `default`, so it keeps the colours of Hermes and applies
  without any setting. It applies while the Webapp uses its default theme; a
  different theme chosen in the Webapp's settings does not carry it.
- To change the look, edit `skin/default.yaml` and deploy. Only CSS is
  possible, up to 32 KiB.
- To keep a `default.yaml` of your own on the server, remove its first line
  (`# hermes-box: managed …`); `install.sh` then leaves the file alone.
- The selectors follow the Webapp of the pinned Hermes version. After
  [upgrading Hermes](installation.md#releasing-a-new-version), open the Webapp on a phone
  and check that the controls are still large.
