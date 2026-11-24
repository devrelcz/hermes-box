#!/usr/bin/env bash
# One-command installation on an empty server. Nothing has to be on the
# server beforehand except curl:
#
#   curl -fsSL https://raw.githubusercontent.com/hobcrew-com/hobcrew-box/master/get.sh | sudo bash
#
# It installs what the installer itself needs (python3, openssl), starts the
# installer on this server and prints its address. The installer is an HTTPS
# API with a page on top (installer/server.py, installer/index.html): the
# page shows how far the installation is and asks for what is still needed.
# It installs Docker when it is missing, takes the files out of the published
# image and runs ./setup.sh. Nothing else changes on the server before the
# installation is started there.
#
# The installer is temporary: its certificate is made for this run (the
# browser warns about it once; the fingerprint is printed here to compare),
# its address carries a one-time token that is good for two hours, and it
# stops when the installation is finished. It runs as the systemd unit
# hobcrew-box-installer, so it survives a lost SSH connection.
#
# The installer's files are downloaded from the same release as this script
# and checked against the SHA-256 written below (installer/sums.sh); files
# that differ are not run.
#
# Options go after `bash -s --`:
#
#   ... | sudo bash -s -- --terminal   ask in the terminal instead (./setup.sh's menus)
#   ... | sudo bash -s -- --update     new files from the image, then ./install.sh --restart
#   ... | sudo bash -s -- --no-start   terminal only: passed on to ./setup.sh
#   ... | sudo bash -s -- --verbose    show every command's output, not a progress line
#   ... | sudo bash -s -- --yes        terminal only: do not ask before starting
#
# With SETUP_DOMAIN set the installation is unattended and runs in the
# terminal as well. Run on a server that already has an installation, the
# installer offers only what was skipped so far; the files change only with
# --update.
#
# The output of the long steps goes to /var/log/hobcrew-box-setup.log.
#
# Settings, through the environment (`sudo VAR=value bash`):
#
#   INSTALL_IMAGE=ghcr.io/hobcrew-com/hobcrew-box:1   which release, e.g. :1.0.0
#   INSTALL_DIR=/opt/hobcrew-box                      where the files go
#   INSTALL_PORT=8443                                the installer's port
#   INSTALL_BIND=0.0.0.0                             127.0.0.1: reachable through an SSH tunnel only
#   INSTALL_REF=v1.4.0                               the release the installer's files come from;
#                                                    by default the one INSTALL_IMAGE names, else master
#   INSTALL_SOURCE=<url or directory>                the same, as a whole address or a directory
#   SETUP_*                                          answers for ./setup.sh, see its header
#
# Docker is installed with Docker's own script (https://get.docker.com), which
# covers Debian, Ubuntu, Fedora, CentOS, RHEL and their relatives.

set -euo pipefail

# Everything is in a function that is called on the last line: a download cut
# off halfway then runs nothing instead of half of the script.
main() {
  local image="${INSTALL_IMAGE:-ghcr.io/hobcrew-com/hobcrew-box:1}"
  local dir="${INSTALL_DIR:-/opt/hobcrew-box}"
  local update=0 confirmed=0 terminal=0 arg
  local -a setup_args=()

  for arg in "$@"; do
    case "$arg" in
      --update) update=1; terminal=1 ;;
      --terminal) terminal=1 ;;
      --no-start) setup_args+=("$arg"); terminal=1 ;;
      -v|--verbose) UI_VERBOSE=1 ;;
      -y|--yes) confirmed=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "get: unknown option: $arg" >&2; exit 2 ;;
    esac
  done

  [ "$(uname -s)" = Linux ] || die "this installs on a Linux server, not on $(uname -s)"
  [ "$(uname -m)" = x86_64 ] || die "the image is built for x86_64 only, this machine is $(uname -m)"
  [ "$(id -u)" -eq 0 ] || die "run as root: curl ... | sudo bash"
  command -v systemctl >/dev/null || die "systemd is required (the stack runs as systemd units)"
  case "$dir" in /*) ;; *) die "INSTALL_DIR has to be an absolute path" ;; esac

  local existing=0
  [ -f "$dir/instance/.env" ] && existing=1

  # Answers given in advance mean an unattended installation: nobody is there
  # to open a page.
  [ -z "${SETUP_DOMAIN:-}" ] || terminal=1
  if [ "$terminal" -eq 0 ]; then
    web_installer "$image" "$dir"
    exit 0
  fi

  # ── What is about to happen ───────────────────────────────────────────────
  if [ "$existing" -eq 1 ] && [ "$update" -eq 1 ]; then
    printf '\n  %sHobCrew Box%s %s· update%s\n\n' "$UI_B" "$UI_N" "$UI_D" "$UI_N"
    note "The installation in $dir gets the files of $image"
    note "and restarts: about a minute without the agent. Settings and data stay."
    hint "A backup first is a good idea: systemctl start hermes-backup"
    confirm "Update now?" "Update" || die "nothing was changed"
  elif [ "$existing" -eq 1 ]; then
    printf '\n  %sHobCrew Box%s %s· already installed in %s%s\n' "$UI_B" "$UI_N" "$UI_D" "$dir" "$UI_N"
    note "The wizard starts again and offers only what was skipped so far."
    note "To update to a newer release, run this with --update."
  else
    intro "$dir" "${SETUP_DATA_DIR:-/home/hermes}"
    confirm "Install HobCrew Box on this server?" "Install" || die "nothing was changed"
  fi
  log_start
  export HOBCREW_BOX_LOG="$UI_LOG" HOBCREW_BOX_VERBOSE="$UI_VERBOSE" HOBCREW_BOX_INTRO_SHOWN=1

  # ── Docker ────────────────────────────────────────────────────────────────
  say "Docker"
  if ! command -v docker >/dev/null; then
    local script
    script="$(mktemp)"
    fetch https://get.docker.com "$script"
    step "Installing Docker" sh "$script"
    rm -f "$script"
  fi
  if ! docker compose version >/dev/null 2>&1; then
    step "Installing the Docker compose plugin" install_compose
  fi
  systemctl enable --now --quiet docker 2>/dev/null || true
  docker info >/dev/null 2>&1 || die "Docker is installed but not running (systemctl status docker)"
  ok "$(docker --version)"

  # ── Files from the image ──────────────────────────────────────────────────
  if [ "$existing" -eq 0 ] || [ "$update" -eq 1 ]; then
    say "HobCrew Box"
    mkdir -p "$dir"
    step "Downloading $image (about 5 GB)" docker pull --quiet "$image"
    step "Unpacking the files into $dir" \
      docker run --rm --network none -v "$dir:/out" --entrypoint hobcrew-box-extract "$image"
    hint "release $(sed -n 's/^HOBCREW_BOX_IMAGE=//p' "$dir/release.env" 2>/dev/null | tail -n1)"
  fi

  cd "$dir"
  if [ "$existing" -eq 1 ] && [ "$update" -eq 1 ]; then
    step "Updating the services and restarting" ./install.sh --restart
    say "Updated"
    note "Webapp:  https://$(sed -n 's/^HERMES_DOMAIN=//p' instance/.env | tail -n1)"
    note "Check:   cd $dir && ./check.sh   (give it a minute or two after the restart)"
    exit 0
  fi

  # ── Wizard ────────────────────────────────────────────────────────────────
  # Piped from curl, stdin is the script itself. The wizard asks its questions
  # on the terminal, so give it the terminal back when there is one.
  if [ ! -t 0 ] && (: </dev/tty) 2>/dev/null; then
    exec ./setup.sh ${setup_args[@]+"${setup_args[@]}"} </dev/tty
  fi
  if [ ! -t 0 ] && [ -z "${SETUP_DOMAIN:-}" ] && [ "$existing" -eq 0 ]; then
    die "no terminal to ask on: set SETUP_DOMAIN (and the other SETUP_* answers), or run: cd $dir && ./setup.sh"
  fi
  exec ./setup.sh ${setup_args[@]+"${setup_args[@]}"}
}

usage() {
  cat <<'EOF'
Installs Hermes Agent in Docker on this server.

  curl -fsSL https://raw.githubusercontent.com/hobcrew-com/hobcrew-box/master/get.sh | sudo bash

It starts a temporary installer on this server (an HTTPS API and a page)
and prints its address; the installation is started and watched there.

  --terminal   ask in the terminal instead of the page
  --update     new files from the image, then ./install.sh --restart
  --no-start   terminal only: set everything up, do not start the stack
  --verbose    show every command's output, not a progress line
  --yes        terminal only: do not ask before starting

Environment: INSTALL_IMAGE (default ghcr.io/hobcrew-com/hobcrew-box:1),
INSTALL_DIR (default /opt/hobcrew-box), INSTALL_PORT (default 8443),
INSTALL_BIND (default 0.0.0.0), INSTALL_REF (the release the installer's
files come from), SETUP_* (answers for the wizard; with SETUP_DOMAIN the
installation is unattended).
EOF
}

# ── The installer: an HTTPS API and its page ──────────────────────────────────
WEB_STATE=/var/lib/hobcrew-box-installer
WEB_UNIT=hobcrew-box-installer
# What the installer's files have to be: they run as root, so files that
# differ from the ones this script was released with are refused.
# installer-sums: begin (written by installer/sums.sh)
WEB_SUMS="
b16966a40dfbe5eecb023706fef390b7ee85869f666f825072527dc30aad9296  server.py
6e856dc1fc9dd5221f52732c849f60f85680b83e3b7a3e3ffb77555ff25845f3  steps.sh
5dc930805007bef4659843ed3c69f2593f5006fa5073e2119d77db250d098b29  index.html
"
# installer-sums: end

# This server's address on the way out; empty without the ip tool or a route.
server_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1
}

install_packages() {  # <package>...
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  elif command -v dnf >/dev/null; then
    dnf install -y -q "$@"
  elif command -v yum >/dev/null; then
    yum install -y -q "$@"
  else
    echo "no apt-get, dnf or yum here: install $* and run this again"
    return 1
  fi
}

# The release the installer's files are taken from: the one named, else the
# one the image names (ghcr.io/...:1.4.0 is the tag v1.4.0), else master.
web_ref() {  # <image>
  local version="${1##*:}"
  if [ -n "${INSTALL_REF:-}" ]; then
    printf '%s' "$INSTALL_REF"
  elif printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf 'v%s' "$version"
  else
    printf 'master'
  fi
}

# The installer's own files: from GitHub, or from a directory (a git
# checkout). Each has to have the checksum this script carries.
web_files() {  # <source>
  local file want have
  for file in server.py steps.sh index.html; do
    rm -f "$WEB_STATE/$file"
    case "$1" in
      /*) cp "$1/$file" "$WEB_STATE/$file.new" ;;
      *) fetch "$1/$file" "$WEB_STATE/$file.new" ;;
    esac || { echo "could not get $file from $1"; web_mismatch; return 1; }
    want="$(printf '%s\n' "$WEB_SUMS" | sed -n "s/^\([0-9a-f]\{64\}\)  $file\$/\1/p")"
    have="$(sha256sum "$WEB_STATE/$file.new" | cut -d' ' -f1)"
    if [ -z "$want" ] || [ "$want" != "$have" ]; then
      rm -f "$WEB_STATE/$file.new"
      echo "$file from $1 is not the file this script was released with"
      echo "  expected sha256 ${want:-(none)}"
      echo "  got             $have"
      web_mismatch
      return 1
    fi
    mv "$WEB_STATE/$file.new" "$WEB_STATE/$file"
  done
}
web_mismatch() {
  echo "This script and the installer's files have to come from the same release."
  echo "Take get.sh from that release as well, for example:"
  echo "  curl -fsSL https://raw.githubusercontent.com/hobcrew-com/hobcrew-box/v<version>/get.sh | sudo INSTALL_IMAGE=ghcr.io/hobcrew-com/hobcrew-box:<version> bash"
  echo "A release older than the installer has none: add --terminal."
}

# A certificate for this run only: nobody can sign one for a bare address, so
# the browser warns once. The fingerprint printed below is what to compare.
web_certificate() {  # <address>
  local names="IP:127.0.0.1,DNS:localhost"
  [ -z "$1" ] || names="IP:$1,$names"
  (umask 077; openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -subj "/CN=HobCrew Box installer" -addext "subjectAltName=$names" \
    -keyout "$WEB_STATE/tls.key" -out "$WEB_STATE/tls.crt")
}

web_address() {  # <address> <port> <bind>
  local token fingerprint host="$1"
  token="$(cat "$WEB_STATE/token")"
  fingerprint="$(openssl x509 -in "$WEB_STATE/tls.crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')"
  say "Open the installer"
  if [ "$3" = 127.0.0.1 ] || [ -z "$host" ]; then
    note "It listens on this server only. From your computer:"
    note "  ssh -L $2:127.0.0.1:$2 root@<this server>"
    printf '\n    %shttps://localhost:%s/#%s%s\n\n' "$UI_B" "$2" "$token" "$UI_N"
  else
    printf '\n    %shttps://%s:%s/#%s%s\n\n' "$UI_B" "$host" "$2" "$token" "$UI_N"
    hint "Port $2 has to be reachable (firewall, the provider's security group)."
    hint "Or through SSH: ssh -L $2:127.0.0.1:$2 root@$host, then https://localhost:$2/ with the same #token"
  fi
  note "The browser warns about the certificate: it was made on this server a"
  note "moment ago. Continue when its SHA-256 fingerprint is:"
  note "  $fingerprint"
  hint "The address is the key to the installer. It is good for two hours and"
  hint "stops by itself when the installation is done."
  hint "The API alone, with the certificate copied over SSH so that curl can check it:"
  hint "  scp root@${host:-<this server>}:$WEB_STATE/tls.crt hobcrew-box.crt"
  hint "  curl --cacert hobcrew-box.crt -H 'Authorization: Bearer <token>' https://${host:-localhost}:$2/api/state"
  hint "Watch: journalctl -fu $WEB_UNIT    Stop: systemctl stop $WEB_UNIT"
}

web_installer() {  # <image> <installation directory>
  local port="${INSTALL_PORT:-8443}" bind="${INSTALL_BIND:-0.0.0.0}"
  local source
  source="${INSTALL_SOURCE:-https://raw.githubusercontent.com/hobcrew-com/hobcrew-box/$(web_ref "$1")/installer}"
  local address tool missing="" up=0
  local -a pass=()
  address="$(server_ip || true)"

  printf '\n  %sHobCrew Box%s %s· Hermes Agent on your own server%s\n' "$UI_B" "$UI_N" "$UI_D" "$UI_N"
  if systemctl is-active --quiet "$WEB_UNIT" 2>/dev/null && [ -s "$WEB_STATE/token" ]; then
    note "The installer is already running."
    web_address "$address" "$(cat "$WEB_STATE/port" 2>/dev/null || echo "$port")" "$(cat "$WEB_STATE/bind" 2>/dev/null || echo "$bind")"
    return 0
  fi
  note "This starts a temporary installer on port $port and prints its address."
  note "Nothing else changes here until the installation is started on that page."
  log_start

  say "Installer"
  for tool in python3 openssl; do
    command -v "$tool" >/dev/null || missing="$missing $tool"
  done
  command -v sha256sum >/dev/null || missing="$missing coreutils"
  if [ -n "$missing" ]; then
    # shellcheck disable=SC2086  # a list of package names
    step "Installing$missing" install_packages $missing
  fi
  (umask 077; mkdir -p "$WEB_STATE")
  chmod 700 "$WEB_STATE"
  step "Getting the installer's files" web_files "$source"
  step "Making a certificate for this run" web_certificate "$address"
  (umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > "$WEB_STATE/token")
  printf '%s\n' "$port" > "$WEB_STATE/port"
  printf '%s\n' "$bind" > "$WEB_STATE/bind"

  # A unit of its own: the installation goes on when this SSH session ends.
  [ -z "${SETUP_DATA_DIR:-}" ] || pass+=("--setenv=SETUP_DATA_DIR=$SETUP_DATA_DIR")
  systemctl reset-failed "$WEB_UNIT" 2>/dev/null || true
  systemd-run --quiet --unit="$WEB_UNIT" --collect --description="HobCrew Box installer" \
    --setenv=INSTALL_IMAGE="$1" --setenv=INSTALL_DIR="$2" ${pass[@]+"${pass[@]}"} \
    python3 "$WEB_STATE/server.py" --bind "$bind" --port "$port" \
    --cert "$WEB_STATE/tls.crt" --key "$WEB_STATE/tls.key" --token-file "$WEB_STATE/token" ||
    die "could not start the installer (systemd-run)"
  for _ in $(seq 1 30); do
    if python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1).close()' "$port" 2>/dev/null; then
      up=1; break
    fi
    sleep 0.5
  done
  [ "$up" -eq 1 ] || die "the installer did not start: journalctl -u $WEB_UNIT"
  ok "running as the service $WEB_UNIT"
  web_address "$address" "$port" "$bind"
}

# ── Terminal output ───────────────────────────────────────────────────────────
# A copy of the pieces of lib/ui.sh this script needs before the files are on
# the server (see there); keep the two alike.
UI_LOG="${HOBCREW_BOX_LOG:-/var/log/hobcrew-box-setup.log}"
UI_VERBOSE="${HOBCREW_BOX_VERBOSE:-0}"
UI_PID=""
UI_TTY=0
if [ -t 1 ] && (: </dev/tty) 2>/dev/null; then UI_TTY=1; fi
if [ "$UI_TTY" -eq 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
  UI_B=$'\033[1m' UI_D=$'\033[2m' UI_G=$'\033[32m' UI_R=$'\033[31m' UI_C=$'\033[36m' UI_N=$'\033[0m'
else
  UI_B='' UI_D='' UI_G='' UI_R='' UI_C='' UI_N=''
fi

say()  { printf '\n%s==>%s %s%s%s\n' "$UI_C" "$UI_N" "$UI_B" "$*" "$UI_N"; }
note() { printf '    %s\n' "$*"; }
hint() { printf '    %s%s%s\n' "$UI_D" "$*" "$UI_N"; }
ok()   { printf '    %s✓%s %s\n' "$UI_G" "$UI_N" "$*"; }
fail() { printf '    %s✗%s %s\n' "$UI_R" "$UI_N" "$*"; }
die()  { printf '\nget: %s\n' "$*" >&2; exit 1; }

ui_cursor_off() { [ "$UI_TTY" -eq 0 ] || printf '\033[?25l' >/dev/tty; }
ui_cursor_on()  { [ "$UI_TTY" -eq 0 ] || printf '\033[?25h' >/dev/tty; }
ui_kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do ui_kill_tree "$child"; done
  kill "$1" 2>/dev/null || true
}
interrupted() {
  trap - INT TERM
  [ -z "$UI_PID" ] || ui_kill_tree "$UI_PID"
  ui_cursor_on
  [ "$UI_TTY" -eq 0 ] || stty echo </dev/tty 2>/dev/null || true
  printf '\n\n    Interrupted. Run the same command again to continue.\n'
  exit 130
}
trap interrupted INT TERM
trap ui_cursor_on EXIT

log_start() {
  (umask 077; touch "$UI_LOG") 2>/dev/null || UI_LOG=/dev/null
  printf '\n===== get.sh, %s\n' "$(date '+%F %T')" >>"$UI_LOG"
}
duration() {
  if [ "$1" -ge 60 ]; then printf '%dm %02ds' $(($1 / 60)) $(($1 % 60)); else printf '%ds' "$1"; fi
}

# step <title> <command...>: the output goes to the log, the terminal shows a
# spinner; a failure shows the end of the log and stops the script.
step() {
  local title="$1" started="$SECONDS" i=0 status=0 frames
  frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  shift
  printf '\n--- %s (%s)\n' "$title" "$*" >>"$UI_LOG"
  UI_LOG_FROM=$(($(wc -l <"$UI_LOG") + 1))
  if [ "$UI_VERBOSE" -eq 1 ]; then
    note "$title"
    ( set -o pipefail; "$@" 2>&1 | tee -a "$UI_LOG" ) &
    UI_PID=$!
  else
    ( "$@" ) >>"$UI_LOG" 2>&1 </dev/null &
    UI_PID=$!
    if [ "$UI_TTY" -eq 1 ]; then
      ui_cursor_off
      while kill -0 "$UI_PID" 2>/dev/null; do
        printf '\r\033[K    %s%s%s %s %s%s%s' "$UI_C" "${frames[i++ % 10]}" "$UI_N" "$title" \
          "$UI_D" "$(duration $((SECONDS - started)))" "$UI_N"
        sleep 0.1
      done
      printf '\r\033[K'
      ui_cursor_on
    fi
  fi
  wait "$UI_PID" || status=$?
  UI_PID=""
  printf -- '--- exit %s after %ss\n' "$status" $((SECONDS - started)) >>"$UI_LOG"
  if [ "$status" -eq 0 ]; then
    ok "$title ${UI_D}$(duration $((SECONDS - started)))${UI_N}"
    return 0
  fi
  fail "$title"
  if [ "$UI_VERBOSE" -ne 1 ] && [ "$UI_LOG" != /dev/null ]; then
    printf '\n'
    tail -n "+$UI_LOG_FROM" "$UI_LOG" | sed '/^--- exit /d' | tail -n 25 | sed 's/^/      /'
  fi
  printf '\n    The whole output is in %s.\n' "$UI_LOG"
  exit 1
}

# confirm <question> <what yes does>: a menu on the terminal; without one, or
# with --yes, the answer is yes.
confirm() {
  local sel=0 key rest
  [ "$confirmed" -eq 0 ] && [ "$UI_TTY" -eq 1 ] || return 0
  printf '\n  %s?%s %s%s%s\n' "$UI_C" "$UI_N" "$UI_B" "$1" "$UI_N" >/dev/tty
  confirm_draw() {
    if [ "$sel" -eq 0 ]; then
      printf '\033[2K    %s❯ %s%s%s\n\033[2K      Cancel\n' "$UI_C" "$UI_B" "$2" "$UI_N"
    else
      printf '\033[2K      %s\n\033[2K    %s❯ %sCancel%s\n' "$2" "$UI_C" "$UI_B" "$UI_N"
    fi
    printf '\033[2K      %s↑/↓ and Enter, or the number%s\n' "$UI_D" "$UI_N"
  }
  ui_cursor_off
  confirm_draw "$@" >/dev/tty
  while :; do
    key=""
    IFS= read -rsn1 key </dev/tty || break
    if [ "$key" = $'\033' ]; then
      rest=""
      IFS= read -rsn2 -t 0.1 rest </dev/tty || true
      key+="$rest"
    fi
    case "$key" in
      $'\033[A'|$'\033OA'|$'\033[B'|$'\033OB'|k|j) sel=$((1 - sel)) ;;
      1) sel=0; break ;;
      2) sel=1; break ;;
      '') break ;;
      *) continue ;;
    esac
    printf '\033[3A' >/dev/tty
    confirm_draw "$@" >/dev/tty
  done
  if [ "$sel" -eq 0 ]; then
    printf '\033[3A\033[J    %s%s%s\n' "$UI_C" "$2" "$UI_N" >/dev/tty
  else
    printf '\033[3A\033[J    %sCancel%s\n' "$UI_C" "$UI_N" >/dev/tty
  fi
  ui_cursor_on
  [ "$sel" -eq 0 ]
}

# What HobCrew Box is and what is about to happen. setup.sh shows the same
# text (lib/ui.sh, ui_intro) when it is started on its own.
intro() {  # <installation directory> <data directory>
  cat <<EOF

  ${UI_B}HobCrew Box${UI_N} ${UI_D}· Hermes Agent on your own server${UI_N}

  Hermes Agent (by Nous Research) is an AI assistant that works on its own:
  it keeps a memory, runs scheduled jobs, searches the web and uses a browser.
  You talk to it in a web app on your own address and in the mobile app.
  Its data and the key to its secrets stay on this server.

  ${UI_B}What happens now${UI_N}
    1. Docker is installed, if it is missing.
    2. HobCrew Box is downloaded: about 5 GB, the longest part.
    3. A few questions: the web address, a user name and password, the model.
    4. Everything is set up and started: HTTPS, a daily backup, a health check.
    It takes 10 to 20 minutes. Running it again skips the finished steps.

  ${UI_B}What it puts on this server${UI_N}
    $(printf '%-28s' "$1")scripts and this installation's settings
    $(printf '%-28s' "$2")the agent's data and its backups
    $(printf '%-28s' /etc/hermes/credentials)the key that encrypts secrets and backups
    $(printf '%-28s' "services hermes-*")the web on ports 80 and 443, the backup timer

  ${UI_B}What you need${UI_N}
    a domain that points at this server (or none: <address>.sslip.io works)
    an account with an AI model provider and its API key
EOF
}

# fetch <url> <file>: with curl or wget, whichever the server has.
fetch() {
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
# docker-compose-v2 in Ubuntu's.
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
    { echo "the Docker compose plugin is missing; install it (https://docs.docker.com/compose/install/linux/) and run this again"; return 1; }
}

main "$@"
