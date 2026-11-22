#!/usr/bin/env bash
# Pair the mobile app: show a QR code that carries this server's address, the
# Webapp user name and the password. The app scans it and signs in.
#
#   ./pair.sh         set a new password, restart the stack, show the code
#   ./pair.sh --yes   the same without the confirmation
#
# Only a hash of the password is stored, so the current one cannot be shown
# again: pairing later means a new password. The old one stops working, in
# the browser too, and every device that is signed in has to sign in again.
#
# The code is the password in readable form. It is drawn on the terminal only
# (never into a pipe, a file or the journal) and wiped once you confirm.
#
# What the code holds, as JSON:
#
#   {"v":1,"url":"https://agent.example.com","user":"admin","password":"..."}
#
# setup.sh shows the same code at the end of a first installation, for the
# password chosen there, through:
#
#   ./pair.sh --show  no new password: draw the code for the one given on
#                     stdin (the Webapp has to accept it already)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$REPO_DIR"

show=0
confirmed=0
for arg in "$@"; do
  case "$arg" in
    --show) show=1 ;;
    --yes|-y) confirmed=1 ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# shellcheck source=lib/ui.sh
. "$REPO_DIR/lib/ui.sh"
die()  { printf 'pair: %s\n' "$*" >&2; exit 1; }

env_get() { sed -n "s/^$1=//p" instance/.env 2>/dev/null | tail -n1; }
# The image to run: a published one named in instance/.env or in release.env
# (written by docker/extract.sh), else the one built here from the Dockerfile.
image_ref() {
  local ref
  ref="$(env_get HERMES_BOX_IMAGE)"
  [ -n "$ref" ] || ref="$(sed -n 's/^HERMES_BOX_IMAGE=//p' "$REPO_DIR/release.env" 2>/dev/null | tail -n1)"
  printf '%s' "${ref:-hermes-agent-local}"
}

[ "$(id -u)" -eq 0 ] || die "run as root"
# The code is a password: it goes to a terminal or nowhere.
[ -t 1 ] && [ -r /dev/tty ] || die "needs a terminal: the code is not written into a pipe or a file"
command -v docker >/dev/null || die "Docker is not installed"
command -v python3 >/dev/null || die "python3 is not installed"

DOMAIN="$(env_get HERMES_DOMAIN)"
[ -n "$DOMAIN" ] || die "no HERMES_DOMAIN in instance/.env; run ./setup.sh first"
DATA_DIR="$(env_get HERMES_DATA_DIR)"; DATA_DIR="${DATA_DIR:-/home/hermes}"
RUN_UID="$(env_get HERMES_UID)";       RUN_UID="${RUN_UID:-1000}"
RUN_GID="$(env_get HERMES_GID)";       RUN_GID="${RUN_GID:-1000}"
IMAGE="$(image_ref)"

hermes() {  # run the hermes CLI on the data directory
  docker run --rm --network none \
    -u "$RUN_UID:$RUN_GID" -e HERMES_HOME=/opt/data -e HOME=/opt/data -w /opt/hermes \
    -v "$DATA_DIR/.hermes:/opt/data" --entrypoint /opt/hermes/bin/hermes "$IMAGE" "$@"
}
hermes_quiet() { hermes "$@" >/dev/null 2>&1; }

user="$(hermes config get dashboard.basic_auth.username 2>/dev/null | tail -n1)"
[ -n "$user" ] || die "the Webapp has no user name and password yet; run ./setup.sh first"

# Draw the code for the password on stdin. The QR library is the one Hermes
# ships in its image; the colours are set explicitly, so the code is dark on
# light whatever the terminal's theme is.
draw_code() {
  python3 -c 'import json, sys
print(json.dumps({"v": 1, "url": sys.argv[1], "user": sys.argv[2], "password": sys.stdin.read()},
                 separators=(",", ":")), end="")' "https://$DOMAIN" "$user" |
    docker run --rm -i --network none --entrypoint /opt/hermes/.venv/bin/python "$IMAGE" -c '
import sys, qrcode
qr = qrcode.QRCode(border=3, error_correction=qrcode.constants.ERROR_CORRECT_L)
qr.add_data(sys.stdin.read())
qr.make(fit=True)
rows = qr.get_matrix()
if len(rows) % 2:
    rows.append([False] * len(rows[0]))
half = {(True, True): "█", (True, False): "▀", (False, True): "▄", (False, False): " "}
for top, bottom in zip(rows[0::2], rows[1::2]):
    line = "".join(half[pair] for pair in zip(top, bottom))
    print("    \033[38;5;16;48;5;231m" + line + "\033[0m")
'
}

password=""
generated=0
if [ "$show" -eq 1 ]; then
  IFS= read -r password || true
  [ -n "$password" ] || die "--show reads the password from stdin"
else
  say "Pairing the mobile app"
  note "This sets a new Webapp password for '$user' and restarts the stack."
  note "The current password stops working and every signed-in device is signed out."
  if [ "$confirmed" -eq 0 ]; then
    choose PAIR_CONFIRM "Set a new password?" no \
      yes "Yes — a new password and a QR code" \
      no "No — keep the current one"
    [ "$CHOICE" = yes ] || die "nothing was changed"
  fi
  while :; do
    read -r -s -p "    New password, at least 12 characters (Enter makes a random one): " password </dev/tty; echo
    if [ -z "$password" ]; then
      password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24), end="")')"
      generated=1
      break
    fi
    read -r -s -p "    Once more: " again </dev/tty; echo
    [ "$password" = "$again" ] && [ "${#password}" -ge 12 ] && break
    warn "the passwords differ or are too short"
  done
  unset again

  # Only the scrypt hash is stored; the password goes in on stdin.
  hash="$(printf '%s' "$password" | docker run --rm -i --network none -w /opt/hermes \
    --entrypoint /opt/hermes/.venv/bin/python "$IMAGE" -c \
    'import sys; from plugins.dashboard_auth.basic import hash_password; print(hash_password(sys.stdin.read()))' 2>/dev/null | tail -n1)"
  case "$hash" in scrypt\$*) ;; *) die "could not hash the password; nothing was changed" ;; esac
  hermes_quiet config set dashboard.basic_auth.password_hash "$hash" ||
    die "could not store the password; nothing was changed"
  # A new signing secret ends the sessions opened with the old password.
  hermes_quiet config set dashboard.basic_auth.secret "$(head -c 32 /dev/urandom | base64 | tr -d '\n')" ||
    die "the new password is stored, but the old sessions could not be ended; run ./pair.sh again"

  note "restarting (a running stack reads its configuration only at start)"
  systemctl restart hermes-docker.service || die "the new password is stored, but the stack did not restart; see journalctl -u hermes-docker"
  up=0
  for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:9120/ 2>/dev/null; then up=1; break; fi
    sleep 3
  done
  [ "$up" -eq 1 ] || note "the Webapp does not answer yet; the app can sign in once ./check.sh passes"
fi

say "Scan this code in the mobile app"
printf '%s' "$password" | draw_code || die "could not draw the code (the image has no QR library?)"
echo
note "server:    https://$DOMAIN"
note "user name: $user"
if [ "$generated" -eq 1 ]; then
  note "password:  $password"
  note "The browser needs this password too: put it into your password manager now."
fi
unset password
note "Anyone who sees this code can sign in. It is wiped from the screen next."
read -r -p "    Press Enter when the app has scanned it: " _ </dev/tty || true
# Clear the screen and, where the terminal allows it, what scrolled away.
printf '\033[2J\033[3J\033[H'
note "Paired. To pair again (a lost phone, another device later): ./pair.sh"
