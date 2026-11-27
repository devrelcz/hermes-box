#!/usr/bin/env bash
# The steps of an installation, one per call. installer/server.py runs them in
# this order and shows their output; each is safe to run again.
#
#   steps.sh docker     install Docker and the compose plugin when missing
#   steps.sh download   pull the published image
#   steps.sh extract    copy the files out of the image into INSTALL_DIR
#   steps.sh setup      ./setup.sh, with the answers in SETUP_* (see its header)
#
# and what the server asks in between:
#
#   steps.sh needs      which answers this server still needs
#   steps.sh summary    where the finished installation is
#   steps.sh pair       the mobile app's QR code for the JSON on stdin, as rows of 0 and 1
#   steps.sh model      configure the provider, model and key supplied as JSON on stdin
#
# Settings, through the environment, as for get.sh: INSTALL_IMAGE, INSTALL_DIR,
# SETUP_DATA_DIR.

set -euo pipefail

IMAGE="${INSTALL_IMAGE:-ghcr.io/hobcrew-com/hobcrew-box:1}"
DIR="${INSTALL_DIR:-/opt/hobcrew-box}"

die() { printf 'installer: %s\n' "$*" >&2; exit 1; }

# An installation that already has its settings keeps its files: they change
# only with get.sh --update.
existing() { [ -f "$DIR/instance/.env" ]; }
env_get() { sed -n "s/^$1=//p" "$DIR/instance/.env" 2>/dev/null | tail -n1; }
data_dir() {
  local dir
  dir="$(env_get HERMES_DATA_DIR)"
  printf '%s' "${dir:-${SETUP_DATA_DIR:-/home/hermes}}"
}
# The image this installation runs, as install.sh works it out.
image_ref() {
  local ref
  ref="$(env_get HOBCREW_BOX_IMAGE)"
  [ -n "$ref" ] || ref="$(sed -n 's/^HOBCREW_BOX_IMAGE=//p' "$DIR/release.env" 2>/dev/null | tail -n1)"
  printf '%s' "${ref:-$IMAGE}"
}

fetch() {  # <url> <file>
  if command -v curl >/dev/null; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null; then
    wget -qO "$2" "$1"
  else
    die "neither curl nor wget is installed"
  fi
}

# Docker that came from the distribution's own packages has no compose plugin.
# The package is docker-compose-plugin in Docker's repository and
# docker-compose-v2 in Ubuntu's. get.sh has the same for its terminal mode.
install_compose() {
  local package
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
    for package in docker-compose-plugin docker-compose-v2; do
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$package" || continue
      docker compose version >/dev/null 2>&1 && return 0
    done
  elif command -v dnf >/dev/null; then
    dnf install -y -q docker-compose-plugin || true
  elif command -v yum >/dev/null; then
    yum install -y -q docker-compose-plugin || true
  fi
  docker compose version >/dev/null 2>&1 ||
    die "the Docker compose plugin is missing; install it (https://docs.docker.com/compose/install/linux/) and try again"
}

step_docker() {
  local script
  if ! command -v docker >/dev/null; then
    echo "Installing Docker with Docker's own script (https://get.docker.com)"
    script="$(mktemp)"
    fetch https://get.docker.com "$script"
    sh "$script"
    rm -f "$script"
  fi
  if ! docker compose version >/dev/null 2>&1; then
    echo "Installing the Docker compose plugin"
    install_compose
  fi
  systemctl enable --now --quiet docker 2>/dev/null || true
  docker info >/dev/null 2>&1 || die "Docker is installed but not running (systemctl status docker)"
  docker --version
}

step_download() {
  if existing; then
    echo "Already installed in $DIR: the image is left as it is (get.sh --update gets a newer one)"
    return 0
  fi
  echo "Pulling $IMAGE (about 5 GB)"
  docker pull "$IMAGE"
}

step_extract() {
  if existing; then
    echo "Already installed in $DIR: the files are left as they are"
    return 0
  fi
  mkdir -p "$DIR"
  docker run --rm --network none -v "$DIR:/out" --entrypoint hobcrew-box-extract "$IMAGE"
}

step_setup() {
  cd "$DIR"
  # The model is chosen in Hermes' own wizard, which needs a terminal; the
  # code for the mobile app is drawn by the page.
  HOBCREW_BOX_INTRO_SHOWN=1 SETUP_MODEL=skip SETUP_PAIR=no exec ./setup.sh
}

# One line per fact: "need domain", "need login", then "<key> <value>".
needs() {
  local config
  config="$(data_dir)/.hermes/config.yaml"
  [ -n "$(env_get HERMES_DOMAIN)" ] || echo "need domain"
  # The sign-in is a user name and the hash of a password in Hermes' config.
  grep -Eqs '^[[:space:]]+password_hash:[[:space:]]*[^[:space:]]' "$config" || echo "need login"
  if existing; then echo "existing 1"; else echo "existing 0"; fi
  echo "image $(image_ref)"
  echo "dir $DIR"
  echo "data_dir $(data_dir)"
  echo "key_file $(key_file)"
}

key_file() {
  local file
  file="$(env_get SOPS_AGE_KEY_FILE)"
  printf '%s' "${file:-/etc/hermes/credentials/age.key}"
}

summary() {
  local config
  config="$(data_dir)/.hermes/config.yaml"
  echo "url=https://$(env_get HERMES_DOMAIN)"
  echo "dir=$DIR"
  echo "instance=$DIR/instance"
  echo "key_file=$(key_file)"
  if grep -Eqs '^model:' "$config"; then echo "model=yes"; else echo "model=no"; fi
}

step_model() {
  local uid gid
  uid="$(env_get HERMES_UID)"
  gid="$(env_get HERMES_GID)"
  docker exec -i -u "${uid:-1000}:${gid:-1000}" -e HOME=/opt/data -e HERMES_HOME=/opt/data \
    -w /opt/hermes hermes /opt/hermes/.venv/bin/python -c '
import json
import sys
from hermes_cli.config import read_raw_config, save_config, save_env_value_secure

answers = json.load(sys.stdin)
provider = answers["provider"]
key_name = {
    "openai": "OPENAI_API_KEY",
    "anthropic": "ANTHROPIC_API_KEY",
    "openrouter": "OPENROUTER_API_KEY",
}[provider]
save_env_value_secure(key_name, answers["api_key"])
config = dict(read_raw_config())
config["model"] = {"provider": provider, "default": answers["model"]}
save_config(config)
' >/dev/null 2>&1 || die "could not save the provider and model in Hermes"
  docker restart --timeout 15 hermes >/dev/null
}

# The QR library is the one Hermes ships in its image.
pair() {
  docker run --rm -i --network none --entrypoint /opt/hermes/.venv/bin/python "$(image_ref)" -c '
import sys, qrcode
qr = qrcode.QRCode(border=3, error_correction=qrcode.constants.ERROR_CORRECT_L)
qr.add_data(sys.stdin.read())
qr.make(fit=True)
for row in qr.get_matrix():
    print("".join("1" if cell else "0" for cell in row))
'
}

case "${1:-}" in
  docker)   step_docker ;;
  download) step_download ;;
  extract)  step_extract ;;
  setup)    step_setup ;;
  needs)    needs ;;
  summary)  summary ;;
  pair)     pair ;;
  model)    step_model ;;
  *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
