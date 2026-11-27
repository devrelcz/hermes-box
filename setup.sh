#!/usr/bin/env bash
# First-time setup of a new installation, from an empty server to a running
# agent. Says what it is about to do, asks its few questions first, then:
#
#   1. writes instance/.env
#   2. gets the image (pulled or built), creates the user, the data directories and the age key
#   3. creates the first encrypted secrets (including the backup password)
#   4. lets Hermes' own wizard pick the model and provider
#   5. sets up the sign-in for the Webapp
#   6. installs the services and starts everything (./install.sh)
#   7. shows a QR code that signs the mobile app in (./pair.sh shows one later)
#
# Safe to run again: finished steps are skipped, so a later run adds what was
# skipped the first time (the model, the sign-in) and restarts the
# stack if it changed anything. Everything else about an existing installation
# is updated with ./install.sh.
#
#   ./setup.sh             interactive
#   ./setup.sh --no-start  everything except step 6
#   ./setup.sh --verbose   show every command's output instead of a progress line
#
# The output of the long steps goes to /var/log/hobcrew-box-setup.log.
#
# Every question can be answered in advance through the environment, which
# also allows an unattended setup (step 4 needs a terminal and is skipped
# without one):
#
#   SETUP_DOMAIN=agent.example.com      public host name of the Webapp
#   SETUP_DATA_DIR=/home/hermes         where all state lives
#   SETUP_MODEL=wizard|skip             run Hermes' model wizard
#   SETUP_WEBAPP_LOGIN=skip             leave the Webapp sign-in for later
#   SETUP_WEBAPP_USER=admin  SETUP_WEBAPP_PASSWORD=...
#   SETUP_PAIR=yes|no                   show the QR code for the mobile app (terminal only)
#   SETUP_SWAP=auto|skip                create swap if the server has none (default: auto)
#   SETUP_AUTO_DEPLOY=yes|no
#   SETUP_HOST_UPDATES=yes|no           update the system by itself at night (HOST_AUTO_UPDATES)
#   SETUP_TRUSTED_PROXIES=203.0.113.7   a proxy in front of the Webapp (HERMES_TRUSTED_PROXIES)
#   SETUP_TLS_CERT=<PEM> SETUP_TLS_KEY=<PEM> [SETUP_TLS_CA=<PEM>]
#                                       a certificate of your own instead of Let's Encrypt's

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$REPO_DIR"

start=1
for arg in "$@"; do
  case "$arg" in
    --no-start) start=0 ;;
    -v|--verbose) export HOBCREW_BOX_VERBOSE=1 ;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# shellcheck source=lib/ui.sh
. "$REPO_DIR/lib/ui.sh"
die() { printf '\nsetup: %s\n' "$*" >&2; exit 1; }
UI_INTERRUPT_HINT="Run ./setup.sh again to continue; finished steps are skipped."

# Questions are read from the terminal (/dev/tty), so stdin does not matter.
interactive="$UI_TTY"

env_get() { [ ! -f instance/.env ] || sed -n "s/^$1=//p" instance/.env | tail -n1; }
# The image to run: a published one named in instance/.env or in release.env
# (written by docker/extract.sh), else the one built here from the Dockerfile.
image_ref() {
  local ref
  ref="$(env_get HOBCREW_BOX_IMAGE)"
  [ -n "$ref" ] || ref="$(sed -n 's/^HOBCREW_BOX_IMAGE=//p' "$REPO_DIR/release.env" 2>/dev/null | tail -n1)"
  printf '%s' "${ref:-hermes-agent-local}"
}
# Set KEY=value in instance/.env: replace the line (also a commented-out one) or append.
env_set() {
  local key="$1" value="$2" file=instance/.env tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    !done && ($0 ~ "^" k "=" || $0 ~ "^# *" k "=") { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' "$file" > "$tmp"
  cat "$tmp" > "$file"; rm -f "$tmp"
}

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v docker >/dev/null || die "Docker is not installed (get.sh installs it, see README; or https://docs.docker.com/engine/install/)"
ui_log_start setup.sh

# What exists so far. The settings may not be there yet; then the defaults.
DATA_DIR="$(env_get HERMES_DATA_DIR)"; DATA_DIR="${DATA_DIR:-${SETUP_DATA_DIR:-/home/hermes}}"
KEY_FILE="$(env_get SOPS_AGE_KEY_FILE)"; KEY_FILE="${KEY_FILE:-/etc/hermes/credentials/age.key}"
# A run on a server that is already set up only adds what is still missing.
existing=0
changed=0
if [ -f "$DATA_DIR/.hermes/config.yaml" ] && [ -f instance/secrets/hermes.enc.yaml ] &&
   systemctl is-enabled --quiet hermes-docker.service 2>/dev/null; then
  existing=1
fi
# Hermes writes the chosen model as a top-level "model:" entry. The file alone
# says nothing: this script creates it even when the wizard is skipped.
model_set() { grep -Eqs '^model:' "$DATA_DIR/.hermes/config.yaml"; }

# ── What is about to happen ──────────────────────────────────────────────────
if [ "$existing" -eq 1 ]; then
  printf '\n  %sHobCrew Box%s %s· already set up: https://%s%s\n' "$UI_B" "$UI_N" "$UI_D" "$(env_get HERMES_DOMAIN)" "$UI_N"
  note "This run offers only the steps skipped so far. Everything else about"
  note "the installation is updated with ./install.sh."
elif [ "${HOBCREW_BOX_INTRO_SHOWN:-0}" != 1 ]; then
  # get.sh has shown this already and asked.
  ui_intro "$REPO_DIR" "$DATA_DIR" "$KEY_FILE"
  if [ "$interactive" -eq 1 ]; then
    choose SETUP_CONFIRM "Set up HobCrew Box on this server?" yes yes "Set it up" no "Cancel"
    [ "$CHOICE" = yes ] || die "nothing was changed"
  fi
fi

# The few host tools check.sh and the backup use; Docker is the only thing
# that has to be there beforehand.
missing=""
for tool in curl jq openssl python3; do
  command -v "$tool" >/dev/null || missing="$missing $tool"
done
if [ -n "$missing" ]; then
  command -v apt-get >/dev/null || die "not installed:$missing (install them and run ./setup.sh again)"
  install_tools() {
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    # shellcheck disable=SC2086  # a list of package names
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $missing
  }
  say "Tools"
  step "Installing$missing" install_tools
fi

# ── Questions ────────────────────────────────────────────────────────────────
# All of them come first, so the long part afterwards runs without anybody
# watching. Only the model wizard (Hermes' own) comes later: it needs the image.

# This server's public IPv4 address, when the route out says so; behind NAT
# or without the ip tool, nothing.
public_ipv4() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)" || true
  case "$ip" in
    ''|10.*|127.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 1 ;;
  esac
  printf '%s' "$ip"
}

# The host name of the Webapp, checked against DNS on a terminal.
ask_domain() {
  local ip domain="" resolved
  if [ -n "${SETUP_DOMAIN:-}" ]; then
    printf '%s' "$SETUP_DOMAIN"
    return
  fi
  [ "$interactive" -eq 1 ] || die "a host name is required (SETUP_DOMAIN)"
  ip="$(public_ipv4 || true)"
  {
    say "Web address"
    hint "The Webapp gets its own HTTPS address. Its DNS record has to point at"
    hint "this server${ip:+ ($ip)}, and ports 80 and 443 have to be open."
  } >/dev/tty
  if [ -n "$ip" ]; then
    choose SETUP_DOMAIN_KIND "Which address?" own \
      own "A domain of my own — for example agent.example.com" \
      sslip "$ip.sslip.io — no domain needed, good for trying it out"
    if [ "$CHOICE" = sslip ]; then printf '%s' "$ip.sslip.io"; return; fi
  fi
  while :; do
    domain="$(ask SETUP_DOMAIN_INPUT "Host name")"
    case "$domain" in
      '') continue ;;
      *://*|*/*|*' '*) warn "only the host name, without https:// or a path" >/dev/tty; continue ;;
    esac
    resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR == 1 { print $1 }')" || true
    if [ -z "$resolved" ]; then
      warn "$domain does not resolve yet; HTTPS works only once its DNS record points here" >/dev/tty
    elif [ -n "$ip" ] && [ "$resolved" != "$ip" ]; then
      warn "$domain points at $resolved, this server is $ip" >/dev/tty
    else
      break
    fi
    choose SETUP_DOMAIN_KEEP "Use $domain anyway?" yes yes "Use it — the DNS record will be fixed" no "Type another one"
    [ "$CHOICE" = no ] || break
  done
  printf '%s' "$domain"
}

if [ ! -f instance/.env ]; then
  mkdir -p instance/secrets
  cp instance.example/env.example instance/.env
  [ -f instance/README.md ] || cp instance.example/README.md instance/README.md
  chmod 640 instance/.env
fi
if [ -z "$(env_get HERMES_DOMAIN)" ]; then
  domain="$(ask_domain)"
  [ -n "$domain" ] || die "a host name is required (SETUP_DOMAIN)"
  case "$domain" in *://*|*/*|*' '*) die "give the bare host name, without https:// or a path" ;; esac
  env_set HERMES_DOMAIN "$domain"
fi
DOMAIN="$(env_get HERMES_DOMAIN)"
if [ -n "${SETUP_DATA_DIR:-}" ] && [ -z "$(env_get HERMES_DATA_DIR)" ]; then
  env_set HERMES_DATA_DIR "$SETUP_DATA_DIR"
fi
if [ -n "${SETUP_TRUSTED_PROXIES:-}" ] && [ -z "$(env_get HERMES_TRUSTED_PROXIES)" ]; then
  env_set HERMES_TRUSTED_PROXIES "$SETUP_TRUSTED_PROXIES"
fi
# A certificate of your own: Caddy serves it and asks Let's Encrypt for none,
# e.g. when only a proxy that checks it against its own authority reaches the
# Webapp. Given again, it replaces the one there.
if [ -n "${SETUP_TLS_CERT:-}${SETUP_TLS_KEY:-}" ]; then
  [ -n "${SETUP_TLS_CERT:-}" ] && [ -n "${SETUP_TLS_KEY:-}" ] ||
    die "SETUP_TLS_CERT and SETUP_TLS_KEY go together"
  grep -q -- '-----BEGIN CERTIFICATE-----' <<<"$SETUP_TLS_CERT" || die "SETUP_TLS_CERT is not a PEM certificate"
  grep -q -- '-----BEGIN .*PRIVATE KEY-----' <<<"$SETUP_TLS_KEY" || die "SETUP_TLS_KEY is not a PEM private key"
  [ -z "${SETUP_TLS_CA:-}" ] || grep -q -- '-----BEGIN CERTIFICATE-----' <<<"$SETUP_TLS_CA" ||
    die "SETUP_TLS_CA is not a PEM certificate"
  (
    umask 077
    mkdir -p instance/tls
    printf '%s\n' "$SETUP_TLS_KEY" > instance/tls/key.pem
    printf '%s\n' "$SETUP_TLS_CERT" > instance/tls/cert.pem
    if [ -n "${SETUP_TLS_CA:-}" ]; then printf '%s\n' "$SETUP_TLS_CA" > instance/tls/ca.pem
    else rm -f instance/tls/ca.pem; fi
    # The key is not encrypted like the secrets: keep it out of the instance repository.
    printf 'key.pem\n' > instance/tls/.gitignore
    printf '%s\n' "# Written by setup.sh (SETUP_TLS_CERT): this certificate instead of Let's Encrypt's." \
      "tls /etc/caddy/tls/cert.pem /etc/caddy/tls/key.pem" > instance/tls/own.caddy
  )
  chmod 644 instance/tls/cert.pem instance/tls/own.caddy instance/tls/.gitignore
  [ ! -f instance/tls/ca.pem ] || chmod 644 instance/tls/ca.pem
  # A running Caddy reads certificate files only when it starts.
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx hermes-caddy; then
    docker restart hermes-caddy >/dev/null || die "could not restart Caddy for the new certificate"
  fi
fi
DATA_DIR="$(env_get HERMES_DATA_DIR)"; DATA_DIR="${DATA_DIR:-/home/hermes}"
RUN_UID="$(env_get HERMES_UID)";       RUN_UID="${RUN_UID:-1000}"
RUN_GID="$(env_get HERMES_GID)";       RUN_GID="${RUN_GID:-1000}"

# The Webapp's user name and password. Asked here on a new server; on one
# that has a configuration already, once the image can say whether it has a
# sign-in (step 5).
login_user=""
pair_password=""
ask_login() {
  local password="" again=""
  case "${SETUP_WEBAPP_LOGIN:-password}" in
    password) ;;
    *) return 0 ;;
  esac
  if [ "$interactive" -eq 1 ]; then
    say "Sign-in for the Webapp"
    hint "You sign in at https://$DOMAIN and in the mobile app with these."
    hint "The server keeps only a hash of the password."
  fi
  login_user="$(ask SETUP_WEBAPP_USER "User name" admin)"
  password="${SETUP_WEBAPP_PASSWORD:-}"
  if [ -z "$password" ] && [ "$interactive" -eq 1 ]; then
    while :; do
      read -r -s -p "    Password (at least 12 characters): " password </dev/tty; echo
      read -r -s -p "    Once more: " again </dev/tty; echo
      [ "$password" = "$again" ] && [ "${#password}" -ge 12 ] && break
      warn "the passwords differ or are too short"
    done
  fi
  [ "${#password}" -ge 12 ] || die "a password of at least 12 characters is required (SETUP_WEBAPP_PASSWORD)"
  # Kept until the end of this run: it is hashed in step 5, and the mobile
  # app's QR code carries it (step 7).
  pair_password="$password"
}
login_asked=0
if [ ! -f "$DATA_DIR/.hermes/config.yaml" ]; then
  ask_login
  login_asked=1
fi

# The model: Hermes' own wizard asks for the provider and its key.
model_wizard=0
if ! model_set; then
  if [ "$interactive" -eq 1 ]; then
    say "AI model"
    hint "The agent needs a model to think with. Hermes' own wizard asks for the"
    hint "provider and its API key; it runs once the download is done."
    choose SETUP_MODEL "Choose the model in this run?" wizard \
      wizard "Yes — after the download" \
      skip "Later — the agent does not answer until a model is chosen"
    [ "$CHOICE" != wizard ] || model_wizard=1
  fi
fi

# Only a git checkout can follow its remote; an installation from a published
# image is updated by extracting a newer image (see README).
if [ -d .git ] && [ -z "$(env_get AUTO_DEPLOY)" ]; then
  choose SETUP_AUTO_DEPLOY "Deploy new commits from git automatically?" no \
    yes "Yes — every few minutes, from the branch checked out here" \
    no "No — update by hand"
  [ "$CHOICE" != yes ] || env_set AUTO_DEPLOY true
fi

# The system under the containers: security updates of the distribution and
# of Docker, and the reboot a new kernel needs (docs/server.md, Updates of
# the system). Off unless chosen: it restarts the stack and the server.
if command -v apt-get >/dev/null && [ -z "$(env_get HOST_AUTO_UPDATES)" ]; then
  choose SETUP_HOST_UPDATES "Keep the system updated automatically?" no \
    yes "Yes — security updates at night, with a reboot when one is needed" \
    no "No — I update the system myself"
  [ "$CHOICE" != yes ] || env_set HOST_AUTO_UPDATES true
fi

# ── 1.–3. Server, image, secrets ─────────────────────────────────────────────
if [ "$existing" -eq 0 ]; then
  say "Setting up — this takes a while, mostly the download"
else
  say "Checking the installation"
fi
if [ "${SETUP_SWAP:-auto}" != skip ]; then
  # shellcheck source=lib/swap.sh
  . "$REPO_DIR/lib/swap.sh"
  step_try "Preparing swap for the server" ensure_swap /hobcrew-box.swap /etc/fstab /proc/swaps
  if [ "$STEP_STATUS" -ne 0 ]; then
    warn "Could not set up swap. If the server runs out of memory, the assistant may stop."
  fi
fi
step "Downloading the images and preparing the server" ./install.sh --prepare
IMAGE="$(image_ref)"

# Tools from the image; nothing else is installed on the host.
sops_encrypt() {  # <name>: JSON on stdin -> instance/secrets/<name>.enc.yaml
  local out="instance/secrets/$1.enc.yaml"
  docker run --rm -i --network none -e SOPS_DISABLE_VERSION_CHECK=1 \
    -v "$REPO_DIR/instance:/work:ro" -w /work --entrypoint sops "$IMAGE" \
    encrypt --input-type json --output-type yaml --filename-override "secrets/$1.enc.yaml" /dev/stdin > "$out.new"
  [ -s "$out.new" ] || { rm -f "$out.new"; die "could not encrypt $out"; }
  mv "$out.new" "$out"; chmod 644 "$out"
}
hermes() {  # run the hermes CLI on the data directory; HERMES_TTY=1 attaches the terminal
  local tty=()
  if [ "${HERMES_TTY:-0}" -eq 1 ]; then tty=(-it); fi
  docker run --rm ${tty[@]+"${tty[@]}"} --network "${HERMES_NET:-none}" \
    -u "$RUN_UID:$RUN_GID" -e HERMES_HOME=/opt/data -e HOME=/opt/data -w /opt/hermes \
    -v "$DATA_DIR/.hermes:/opt/data" --entrypoint /opt/hermes/bin/hermes "$IMAGE" "$@"
}

# The agent's secrets start with a harmless marker; add real ones later with
# ./sops.sh secrets/hermes.enc.yaml (one NAME: value per line). The backup
# gets a random password.
make_secrets() {
  if [ ! -f instance/secrets/hermes.enc.yaml ]; then
    python3 -c 'import json,sys; print(json.dumps({"HERMES_INSTANCE": sys.argv[1]}))' "$DOMAIN" | sops_encrypt hermes
    echo "created instance/secrets/hermes.enc.yaml"
  fi
  if [ ! -f instance/secrets/backup.enc.yaml ]; then
    [ ! -d "$DATA_DIR/backups/restic-repo" ] ||
      die "a backup repository exists in $DATA_DIR/backups but its password (instance/secrets/backup.enc.yaml) does not; restore that file instead of creating a new password"
    head -c 32 /dev/urandom | base64 | tr -d '\n' |
      python3 -c 'import json,sys; print(json.dumps({"RESTIC_PASSWORD": sys.stdin.read()}))' | sops_encrypt backup
    echo "created instance/secrets/backup.enc.yaml (a random backup password)"
  fi
}
if [ ! -f instance/secrets/hermes.enc.yaml ] || [ ! -f instance/secrets/backup.enc.yaml ]; then
  step "Encrypting the first secrets" make_secrets
fi

# ── 4. Model and provider (Hermes' own wizard) ───────────────────────────────
if [ "$model_wizard" -eq 1 ]; then
  say "AI model"
  hint "Hermes' own wizard follows: pick a provider, paste its API key, pick a model."
  printf '\n'
  if HERMES_TTY=1 HERMES_NET=host hermes setup model </dev/tty && model_set; then
    ok "model chosen"
    changed=1
  else
    warn "the wizard did not finish; repeat it later (README, Model and provider)"
  fi
fi
# Make sure the configuration file exists; install.sh fills in the rest.
# The hermes commands here go in two batches (lib/hermes.sh): each one
# started on its own takes seconds.
# shellcheck source=lib/hermes.sh
. "$REPO_DIR/lib/hermes.sh"
first=()
[ -f "$DATA_DIR/.hermes/config.yaml" ] || first+=("config set webapp.enabled true")
hermes_batch ${first[@]+"${first[@]}"} "config get dashboard.basic_auth.username" ||
  die "could not run the hermes CLI from $IMAGE"
[ -f "$DATA_DIR/.hermes/config.yaml" ] || die "could not create $DATA_DIR/.hermes/config.yaml"

# ── 5. Sign-in for the Webapp ────────────────────────────────────────────────
# The user name and password are the only sign-in. A server that used a Nous
# Portal account counts as not set up, and setting the password removes that
# sign-in: Hermes would otherwise offer both. The Nous account itself stays
# logged in, so a model served by Nous Portal keeps working. The rest of that
# (config unset dashboard.oauth.client_id) goes with the new sign-in's batch.
drop_nous_login() {
  local env="$DATA_DIR/.hermes/.env" tmp
  if grep -qs '^HERMES_DASHBOARD_OAUTH_CLIENT_ID=' "$env"; then
    tmp="$(mktemp)"
    grep -v '^HERMES_DASHBOARD_OAUTH_CLIENT_ID=' "$env" > "$tmp" || true
    cat "$tmp" > "$env"; rm -f "$tmp"
  fi
  rm -f "$DATA_DIR/.hermes/webapp/sign-in-registration.json"
}
existing_user="$(batch_out "config get dashboard.basic_auth.username" | tail -n1)"
if [ -n "$existing_user" ]; then
  login_user=""
  pair_password=""
else
  [ "$login_asked" -eq 1 ] || ask_login
  if [ -n "$login_user" ]; then
    # Only the scrypt hash is stored; the password goes in on stdin.
    hash="$(printf '%s' "$pair_password" | docker run --rm -i --network none -w /opt/hermes \
      --entrypoint /opt/hermes/.venv/bin/python "$IMAGE" -c \
      'import sys; from plugins.dashboard_auth.basic import hash_password; print(hash_password(sys.stdin.read()))' 2>/dev/null | tail -n1)"
    case "$hash" in scrypt\$*) ;; *) die "could not hash the password" ;; esac
    sign_in=(
      "config set dashboard.basic_auth.username $(shq "$login_user")"
      "config set dashboard.basic_auth.password_hash $(shq "$hash")"
      "config set dashboard.basic_auth.secret $(shq "$(head -c 32 /dev/urandom | base64 | tr -d '\n')")"
    )
    hermes_batch "${sign_in[@]}" "config unset dashboard.oauth.client_id" ||
      die "could not run the hermes CLI from $IMAGE"
    for line in "${sign_in[@]}"; do
      batch_ok "$line" || die "could not save the Webapp sign-in: $(batch_err "$line" | tail -n1)"
    done
    unset sign_in hash
    drop_nous_login
    ok "Webapp sign-in for '$login_user'"
    changed=1
  fi
fi

# ── 6. Start ─────────────────────────────────────────────────────────────────
if [ "$start" -eq 0 ]; then
  unset pair_password
  say "Prepared. Start everything with ./install.sh"
  note "then pair the mobile app with ./pair.sh (it sets a new password)"
  exit 0
fi

if [ "$existing" -eq 1 ] && [ "$changed" -eq 1 ]; then
  # A running stack reads its configuration only at start.
  step "Restarting with the new settings" ./install.sh --restart
elif [ "$existing" -eq 1 ]; then
  step "Checking the services" ./install.sh
else
  step "Installing the services and starting" ./install.sh
fi
if [ "$existing" -eq 0 ]; then
  step_try "Running the first backup" systemctl start hermes-backup.service
  [ "$STEP_STATUS" -eq 0 ] || hint "see journalctl -u hermes-backup; the next one runs tonight"
fi

# Right after a start some parts take a minute or two to answer; wait for
# them before calling anything broken.
health="$(mktemp)"
wait_healthy() {
  local until=$((SECONDS + 240))
  while ! ./check.sh --quiet > "$health" 2>&1; do
    [ "$SECONDS" -lt "$until" ] || { cat "$health"; return 1; }
    sleep 10
  done
}
step_try "Waiting for everything to answer" wait_healthy
if [ "$STEP_STATUS" -ne 0 ]; then
  sed 's/^/      /' "$health"
  hint "run ./check.sh again in a few minutes; with a fresh DNS record HTTPS may take a while"
fi
rm -f "$health"

# ── Done ─────────────────────────────────────────────────────────────────────
# Shown again after the QR code: pair.sh wipes the screen, scrollback included.
summary() {
  say "HobCrew Box is running"
  note "Webapp     https://$DOMAIN"
  if [ -n "$login_user" ]; then
    note "Sign in    as '$login_user' with the password you chose"
  elif [ -n "$existing_user" ]; then
    note "Sign in    as '$existing_user'"
  else
    warn "no sign-in yet: Hermes does not serve the Webapp publicly without one (./setup.sh adds it)"
  fi
  if model_set; then
    note "Model      chosen (to change it: README, Model and provider)"
  else
    warn "no model yet: the agent does not answer until one is chosen"
    hint "  docker exec -it -u 1000:1000 -e HOME=/opt/data hermes hermes setup model"
  fi
  note "Health     ./check.sh"
  note "Log        $UI_LOG"
  if [ "$existing" -eq 0 ]; then
    printf '\n    %sKeep two things somewhere other than this server:%s\n' "$UI_B" "$UI_N"
    note "  1. the private key $KEY_FILE"
    hint "     without it the secrets and the backups cannot be read"
    note "  2. the directory $REPO_DIR/instance/"
    hint "     best as a private git repository (see instance/README.md)"
  fi
}
summary

# ── 7. Mobile app ────────────────────────────────────────────────────────────
# The code carries the password, so it is offered on a terminal only and only
# while this run still knows the password. Later, ./pair.sh sets a new one.
if [ -n "$pair_password" ] && [ "$interactive" -eq 1 ]; then
  choose SETUP_PAIR "Sign the mobile app in with a QR code?" yes \
    yes "Show the code now — it holds the password, do not screenshot it" \
    no "Not now — ./pair.sh shows one later (it sets a new password)"
  if [ "$CHOICE" = yes ]; then
    printf '%s\n' "$pair_password" | ./pair.sh --show || warn "could not show the code; pair later with ./pair.sh"
    summary
  fi
else
  hint "Mobile app: ./pair.sh shows a QR code that signs it in (it sets a new password)"
fi
unset pair_password
