#!/usr/bin/env bash
# Update an installation made from the published image to another release,
# without questions, and go back to the previous release if the new one does
# not come up healthy. Run as root on the server:
#
#   ./update.sh                 the newest release of the same major version (1.x)
#   ./update.sh --to 1.8.1      exactly this release (an older one goes back to it)
#   ./update.sh --check         only say what runs and what is available;
#                               exit 0 up to date, 10 a newer release exists
#   ./update.sh --json          end with one line of JSON, for a program
#   ./update.sh --no-backup     skip the backup taken before anything changes
#
# What it does:
#
#   1. finds the target release in the registry and pulls its image
#      (nothing has changed on the server until here)
#   2. runs a backup (hermes-backup.service)
#   3. waits until no cron job of the agent is about to start
#   4. puts the release's files in place (docker/extract.sh), runs ./install.sh
#      and restarts the stack
#   5. runs check.sh; if it fails, puts the previous release's files and image
#      back the same way and restarts again
#   6. removes the previous image (about 5 GB) when the new one passed
#
# The result goes to stdout, the journal of whoever ran it and, when the
# installation has one, instance/notify.sh. The monitor stays quiet while it
# runs (/run/hermes-deploying).
#
# Exit codes: 0 updated or up to date, 1 failed with nothing changed,
# 2 wrong usage, 3 failed and rolled back (the previous release runs),
# 4 failed and the previous release did not come back healthy either,
# 10 (--check only) a newer release exists.
#
# An installation from git (no release.env) is updated with git instead; see
# docs/installation.md, Deploying a change.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
env_get() { [ -f "$REPO_DIR/instance/.env" ] && sed -n "s/^$1=//p" "$REPO_DIR/instance/.env" | tail -n1 || true; }
# shellcheck source=monitor/notify.sh
. "$REPO_DIR/monitor/notify.sh"
# shellcheck source=lib/deploy.sh
. "$REPO_DIR/lib/deploy.sh"

LOCK=/run/hobcrew-box-update.lock
DEPLOYING=/run/hermes-deploying   # tells the monitor to stay quiet

json=0
# notify writes its text to stdout as well; with --json only the JSON goes there.
say_notify() { if [ "$json" -eq 1 ]; then notify "$1" >&2; else notify "$1"; fi; }
log() { if [ "$json" -eq 1 ]; then printf 'update: %s\n' "$*" >&2; else printf 'update: %s\n' "$*"; fi; }

# release.env as the image wrote it: HOBCREW_BOX_IMAGE, and since 1.8.2 also
# HOBCREW_BOX_VERSION and HERMES_VERSION.
release_get() { sed -n "s/^$1=//p" "$REPO_DIR/release.env" 2>/dev/null | tail -n1; }

# The releases published for <repository> (ghcr.io/owner/name), one per line:
# only plain versions (1.2.3), no pre-releases, no moving tags (:1, :1.2).
registry_versions() {  # <repository>
  local repo="${1#ghcr.io/}" token
  case "$1" in ghcr.io/*) ;; *) echo "only images on ghcr.io can be looked up: $1" >&2; return 1 ;; esac
  token="$(curl -fsS --max-time 20 "https://ghcr.io/token?scope=repository:$repo:pull" | jq -r .token)" || return 1
  [ -n "$token" ] && [ "$token" != null ] || return 1
  curl -fsS --max-time 20 -H "Authorization: Bearer $token" "https://ghcr.io/v2/$repo/tags/list?n=10000" |
    jq -r '.tags[]?' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V
}

# The Hermes version an image carries, without starting the agent: from its
# release.env (1.8.2 and later), else from asking its hermes command.
image_hermes() {  # <image>
  local version
  version="$(docker run --rm --network none --entrypoint sh "$1" -c \
    'sed -n "s/^HERMES_VERSION=//p" /opt/hobcrew-box/release.env 2>/dev/null' 2>/dev/null | tail -n1)"
  [ -n "$version" ] || version="$(docker run --rm --network none -e HOME=/tmp --entrypoint /opt/hermes/bin/hermes "$1" \
    --version 2>/dev/null | grep -o 'v[0-9][0-9.]*' | head -n1)"
  printf '%s' "$version"
}

# One JSON line with the result (--json), then the exit code.
finish() {  # <exit code> <result> <message>
  running="$(docker inspect -f '{{.Config.Image}}' hermes 2>/dev/null || true)"
  if [ "$json" -eq 1 ]; then
    jq -cn --arg result "$2" --arg message "$3" --arg from "${from:-}" --arg to "${to:-}" \
      --arg latest "${latest:-}" --arg hermes "${hermes:-}" --arg running "${running:-}" \
      '{result: $result, from: $from, to: $to, latest: $latest, running: $running,
        hermes: $hermes, message: $message} | with_entries(select(.value != ""))'
  else
    log "$3"
  fi
  exit "$1"
}

main() {
  local target="" check=0 backup=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) target="${2:-}"; shift ;;
      --to=*) target="${1#--to=}" ;;
      --check) check=1 ;;
      --json) json=1 ;;
      --no-backup) backup=0 ;;
      -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
      *) echo "update: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
  done
  target="${target#v}"
  if [ -n "$target" ] && ! [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    echo "update: --to takes a release such as 1.8.1, not $target" >&2; exit 2
  fi

  [ "$(id -u)" -eq 0 ] || finish 1 failed "run as root"
  cd "$REPO_DIR" || exit 1
  local current repo pinned
  current="$(release_get HOBCREW_BOX_IMAGE)"
  [ -n "$current" ] ||
    finish 1 failed "this installation has no release.env: it is built from git; update it with git (docs/installation.md, Deploying a change)"
  repo="${current%:*}"
  from="${current##*:}"
  running="$(docker inspect -f '{{.Config.Image}}' hermes 2>/dev/null || true)"
  hermes="$(release_get HERMES_VERSION)"
  [ -n "$hermes" ] || [ -z "$running" ] || hermes="$(image_hermes "$running")"
  # An installation may name its image in instance/.env; that one wins.
  pinned="$(env_get HOBCREW_BOX_IMAGE)"
  if [ -n "$pinned" ]; then from="${pinned##*:}"; repo="${pinned%:*}"; current="$pinned"; fi

  # ── What to update to ─────────────────────────────────────────────────────
  local versions major
  major="${from%%.*}"
  if versions="$(registry_versions "$repo")" && [ -n "$versions" ]; then
    latest="$(grep -E "^$major\." <<<"$versions" | tail -n1)"
  else
    latest=""
    [ -n "$target" ] || finish 1 failed "could not read the releases of $repo from the registry"
  fi
  if [ -n "$target" ]; then
    to="$target"
    if [ -n "$versions" ] && [[ "$target" != *-* ]] && ! grep -qx "$target" <<<"$versions"; then
      finish 1 failed "there is no release $target of $repo"
    fi
  else
    to="$latest"
  fi

  if [ "$check" -eq 1 ]; then
    if [ -n "$latest" ] && [ "$latest" != "$from" ] &&
       [ "$(printf '%s\n%s\n' "$from" "$latest" | sort -V | tail -n1)" = "$latest" ]; then
      finish 10 available "HobCrew Box $from runs (Hermes ${hermes:-unknown}); $latest is available: ./update.sh"
    fi
    finish 0 up_to_date "HobCrew Box $from runs (Hermes ${hermes:-unknown}); it is the newest ${major}.x release"
  fi
  if [ "$to" = "$from" ] && [ "$running" = "$current" ]; then
    finish 0 up_to_date "HobCrew Box $from is the newest ${major}.x release and runs"
  fi

  exec 9>"$LOCK"
  flock -n 9 || finish 1 failed "another update is running"
  [ ! -f "$DEPLOYING" ] || finish 1 failed "a deployment is running ($DEPLOYING)"

  local new="$repo:$to" host
  host="$(hostname)"
  log "updating HobCrew Box $from to $to"

  # ── 1. Image (nothing changes on the server until it is here) ─────────────
  docker pull --quiet "$new" >/dev/null || finish 1 failed "could not pull $new; nothing was changed"
  # The previous image stays until the new one passed: it is the way back.
  docker image inspect "$current" >/dev/null 2>&1 || docker pull --quiet "$current" >/dev/null 2>&1 || true

  # ── 2. Backup ─────────────────────────────────────────────────────────────
  if [ "$backup" -eq 1 ]; then
    log "backup"
    systemctl start hermes-backup.service ||
      finish 1 failed "the backup failed (journalctl -u hermes-backup); nothing was changed. --no-backup skips it"
  fi

  # ── 3. A quiet moment ─────────────────────────────────────────────────────
  touch "$DEPLOYING"
  trap 'rm -f "$DEPLOYING"' EXIT
  wait_for_quiet_moment

  # ── 4. Files, units and restart ───────────────────────────────────────────
  # put_release <image>: its files over the installation's, the pin in
  # instance/.env (if there is one) moved along, the units updated.
  put_release() {
    docker run --rm --network none -v "$REPO_DIR:/out" --entrypoint hobcrew-box-extract "$1" >/dev/null || return 1
    if [ -n "$pinned" ]; then
      sed -i "s#^HOBCREW_BOX_IMAGE=.*#HOBCREW_BOX_IMAGE=$1#" instance/.env || return 1
    fi
    ./install.sh --no-build >/dev/null
  }
  local out failures=""
  if out="$(put_release "$new" 2>&1)"; then
    failures="$(restart_and_check)" && {
      hermes="$(image_hermes "$new")"
      docker image rm "$current" >/dev/null 2>&1 || true
      say_notify "HobCrew Box on $host: updated $from to $to (Hermes ${hermes:-unknown}); all checks pass."
      finish 0 updated "updated $from to $to (Hermes ${hermes:-unknown}); all checks pass"
    }
    failures="after the restart: $(echo "${failures:-the Webapp did not come up}" | head -n3 | sed 's/^FAIL  //' | paste -sd ';' - | sed 's/;/; /g')"
  else
    failures="install: $(echo "$out" | tail -n1)"
  fi

  # ── 5. Back to the previous release ───────────────────────────────────────
  log "$to failed ($failures); going back to $from"
  if put_release "$current" >/dev/null 2>&1 && restart_and_check >/dev/null 2>&1; then
    docker image rm "$new" >/dev/null 2>&1 || true
    say_notify "HobCrew Box on $host: updating to $to FAILED ($failures). $from runs again."
    finish 3 rolled_back "updating to $to failed ($failures); $from runs again"
  fi
  say_notify "HobCrew Box on $host: updating to $to FAILED ($failures) and $from did not come back healthy. Needs attention: ./check.sh"
  finish 4 broken "updating to $to failed ($failures) and $from did not come back healthy; run ./check.sh"
}

# Everything runs from main: the update replaces this file while it runs, and
# bash has to have read all of it before that.
main "$@"
exit
