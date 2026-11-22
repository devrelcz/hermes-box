#!/usr/bin/env bash
# One-command installation on an empty server: installs Docker when it is
# missing, takes the files out of the published image and starts the wizard
# (./setup.sh). Nothing has to be on the server beforehand except curl:
#
#   curl -fsSL https://raw.githubusercontent.com/devrelcz/hermes-box/master/get.sh | sudo bash
#
# Options go after `bash -s --`:
#
#   ... | sudo bash -s -- --update     new files from the image, then ./install.sh --restart
#   ... | sudo bash -s -- --no-start   passed on to ./setup.sh
#   ... | sudo bash -s -- --verbose    show every command's output, not a progress line
#   ... | sudo bash -s -- --yes        do not ask before starting
#
# Run on a server that already has an installation, it only starts the wizard
# again (finished steps are skipped); the files change only with --update.
#
# It first says what it is about to do and asks before changing anything. The
# output of the long steps goes to /var/log/hermes-box-setup.log.
#
# Settings, through the environment (`sudo VAR=value bash`):
#
#   INSTALL_IMAGE=ghcr.io/devrelcz/hermes-box:1   which release, e.g. :1.0.0
#   INSTALL_DIR=/opt/hermes-box                      where the files go
#   SETUP_*                                          answers for ./setup.sh, see its header
#
# Docker is installed with Docker's own script (https://get.docker.com), which
# covers Debian, Ubuntu, Fedora, CentOS, RHEL and their relatives.

set -euo pipefail

# Everything is in a function that is called on the last line: a download cut
# off halfway then runs nothing instead of half of the script.
main() {
  local image="${INSTALL_IMAGE:-ghcr.io/devrelcz/hermes-box:1}"
  local dir="${INSTALL_DIR:-/opt/hermes-box}"
  local update=0 confirmed=0 arg
  local -a setup_args=()

  for arg in "$@"; do
    case "$arg" in
      --update) update=1 ;;
      --no-start) setup_args+=("$arg") ;;
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

  # ── What is about to happen ───────────────────────────────────────────────
  if [ "$existing" -eq 1 ] && [ "$update" -eq 1 ]; then
    printf '\n  %sHermes Box%s %s· update%s\n\n' "$UI_B" "$UI_N" "$UI_D" "$UI_N"
    note "The installation in $dir gets the files of $image"
    note "and restarts: about a minute without the agent. Settings and data stay."
    hint "A backup first is a good idea: systemctl start hermes-backup"
    confirm "Update now?" "Update" || die "nothing was changed"
  elif [ "$existing" -eq 1 ]; then
    printf '\n  %sHermes Box%s %s· already installed in %s%s\n' "$UI_B" "$UI_N" "$UI_D" "$dir" "$UI_N"
    note "The wizard starts again and offers only what was skipped so far."
    note "To update to a newer release, run this with --update."
  else
    intro "$dir" "${SETUP_DATA_DIR:-/home/hermes}"
    confirm "Install Hermes Box on this server?" "Install" || die "nothing was changed"
  fi
  log_start
  export HERMES_BOX_LOG="$UI_LOG" HERMES_BOX_VERBOSE="$UI_VERBOSE" HERMES_BOX_INTRO_SHOWN=1

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
    say "Hermes Box"
    mkdir -p "$dir"
    step "Downloading $image (about 5 GB)" docker pull --quiet "$image"
    step "Unpacking the files into $dir" \
      docker run --rm --network none -v "$dir:/out" --entrypoint hermes-box-extract "$image"
    hint "release $(sed -n 's/^HERMES_BOX_IMAGE=//p' "$dir/release.env" 2>/dev/null | tail -n1)"
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

  curl -fsSL https://raw.githubusercontent.com/devrelcz/hermes-box/master/get.sh | sudo bash

  --update     new files from the image, then ./install.sh --restart
  --no-start   set everything up, do not start the stack
  --verbose    show every command's output, not a progress line
  --yes        do not ask before starting

Environment: INSTALL_IMAGE (default ghcr.io/devrelcz/hermes-box:1),
INSTALL_DIR (default /opt/hermes-box), SETUP_* (answers for the wizard).
EOF
}

# ── Terminal output ───────────────────────────────────────────────────────────
# A copy of the pieces of lib/ui.sh this script needs before the files are on
# the server (see there); keep the two alike.
UI_LOG="${HERMES_BOX_LOG:-/var/log/hermes-box-setup.log}"
UI_VERBOSE="${HERMES_BOX_VERBOSE:-0}"
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

# What Hermes Box is and what is about to happen. setup.sh shows the same
# text (lib/ui.sh, ui_intro) when it is started on its own.
intro() {  # <installation directory> <data directory>
  cat <<EOF

  ${UI_B}Hermes Box${UI_N} ${UI_D}· Hermes Agent on your own server${UI_N}

  Hermes Agent (by Nous Research) is an AI assistant that works on its own:
  it keeps a memory, runs scheduled jobs, searches the web and uses a browser.
  You talk to it in a web app on your own address and in the mobile app.
  Its data and the key to its secrets stay on this server.

  ${UI_B}What happens now${UI_N}
    1. Docker is installed, if it is missing.
    2. Hermes Box is downloaded: about 11 GB, the longest part.
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
