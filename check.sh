#!/usr/bin/env bash
# Health check of the whole setup. Prints one line per check and exits 1 if
# anything failed. Run as root from anywhere:
#
#   ./check.sh            all lines
#   ./check.sh --quiet    only failures (used by monitor/hermes-monitor.sh)

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
env_get() { [ -f "$REPO_DIR/.env" ] && sed -n "s/^$1=//p" "$REPO_DIR/.env" | tail -n1 || true; }

DATA_DIR="$(env_get HERMES_DATA_DIR)"; DATA_DIR="${DATA_DIR:-/home/hermes}"
DOMAIN="$(env_get HERMES_DOMAIN)"
quiet=0; [ "${1:-}" = "--quiet" ] && quiet=1
failed=0

ok()   { [ "$quiet" -eq 1 ] || printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failed=1; }
# Worth knowing, but not a failure: no alert, exit code unchanged.
warn() { [ "$quiet" -eq 1 ] || printf 'warn  %s\n' "$1"; }
# check <name> <command...>: passes when the command succeeds
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name"; fi; }

# With a certificate of your own (instance/tls/ca.pem, its authority) the
# Webapp is reached through a proxy of yours, and its name need not resolve
# anywhere: it is checked on this server, against that authority.
CA_FILE="$REPO_DIR/instance/tls/ca.pem"
curl_tls=(); tls_target="$DOMAIN:443"
if [ -f "$CA_FILE" ] && [ -n "$DOMAIN" ]; then
  curl_tls=(--cacert "$CA_FILE" --resolve "$DOMAIN:443:127.0.0.1"); tls_target="127.0.0.1:443"
fi
http_code() { curl -s -o /dev/null --max-time 15 -w '%{http_code}' "${curl_tls[@]}" "$1" 2>/dev/null; }
is_up()     { case "$(http_code "$1")" in 200|301|302) return 0 ;; *) return 1 ;; esac; }

# ── Release ──────────────────────────────────────────────────────────────────
# Which release the files are from (release.env) and whether the container
# runs the same one. An installation from git has no release.env.
release_get() { sed -n "s/^$1=//p" "$REPO_DIR/release.env" 2>/dev/null | tail -n1; }
release_image="$(env_get HOBCREW_BOX_IMAGE)"; [ -n "$release_image" ] || release_image="$(release_get HOBCREW_BOX_IMAGE)"
if [ -n "$release_image" ]; then
  hermes_version="$(release_get HERMES_VERSION)"
  ok "HobCrew Box ${release_image##*:}${hermes_version:+, Hermes $hermes_version}"
  running_image="$(docker inspect -f '{{.Config.Image}}' hermes 2>/dev/null || true)"
  if [ -n "$running_image" ] && [ "$running_image" != "$release_image" ]; then
    warn "the files are of ${release_image##*:} but the container runs ${running_image##*:}: ./install.sh --restart"
  fi
else
  ok "HobCrew Box built from git ($(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown))"
fi

# ── Data ─────────────────────────────────────────────────────────────────────
check "data directory holds Hermes data ($DATA_DIR)" test -f "$DATA_DIR/.hermes/config.yaml"
for path in / "$DATA_DIR"; do
  used="$(df --output=pcent "$path" | tail -n1 | tr -dc 0-9)"
  if [ "${used:-100}" -lt 85 ]; then ok "disk $path ${used}% full"; else fail "disk $path ${used}% full"; fi
done

# ── Services ─────────────────────────────────────────────────────────────────
check "hermes-docker.service is active" systemctl is-active --quiet hermes-docker.service
check "hermes-backup.timer is active"   systemctl is-active --quiet hermes-backup.timer
for name in hermes hermes-caddy; do
  state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
  if [ "$state" = running ]; then ok "container $name is running"; else fail "container $name is $state"; fi
done
health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' hermes 2>/dev/null || echo missing)"
case "$health" in
  healthy|starting|none) ok "container hermes health: $health" ;;
  *) fail "container hermes health: $health" ;;
esac
restarts="$(docker inspect -f '{{.RestartCount}}' hermes 2>/dev/null || echo 0)"
if [ "$restarts" -eq 0 ]; then ok "container hermes has not crashed"
else fail "container hermes was restarted ${restarts}x after a crash"; fi

# SearXNG: the agent's web search. Only its own health, no search: a search
# asks outside engines, and this check runs every few minutes.
state="$(docker inspect -f '{{.State.Status}}' hermes-searxng 2>/dev/null || echo missing)"
if [ "$state" = running ]; then ok "container hermes-searxng is running"; else fail "container hermes-searxng is $state"; fi
# It can come up later than the Webapp after a restart, and a deployment runs
# this check right then; give it a minute before calling it down.
searxng_up() {
  local i
  for i in $(seq 1 12); do is_up http://127.0.0.1:8888/healthz && return 0; sleep 5; done
  return 1
}
check "SearXNG answers on 127.0.0.1:8888" searxng_up
if docker ps -a --format '{{.Names}}' | grep -q '^hermes-firecrawl'; then
  warn "Firecrawl containers are left over from an earlier version; ./install.sh removes them"
fi

# ── Agent ────────────────────────────────────────────────────────────────────
if grep -Eqs '^model:' "$DATA_DIR/.hermes/config.yaml"; then ok "a model is configured"
else warn "no model is configured: the agent will not answer (see README, Model and provider)"; fi
check "Webapp answers on 127.0.0.1:9120" is_up http://127.0.0.1:9120/
exposed="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':(9119|9120)$' | grep -v -E '^(127\.|\[::1\]|\[::ffff:127\.)' | tr '\n' ' ')"
if [ -z "$exposed" ]; then ok "dashboard and Webapp listen on loopback only"
else fail "listening on a public address: $exposed"; fi

# ── Public ───────────────────────────────────────────────────────────────────
if [ -n "$DOMAIN" ]; then
  check "https://$DOMAIN answers" is_up "https://$DOMAIN/"
  cert_ok() {
    echo | openssl s_client -connect "$tls_target" -servername "$DOMAIN" 2>/dev/null |
      openssl x509 -noout -checkend $((14 * 86400))
  }
  check "certificate is valid for at least 14 more days" cert_ok
fi

# ── Backup ───────────────────────────────────────────────────────────────────
result="$(systemctl show hermes-backup.service -p Result --value 2>/dev/null)"
if [ "$result" = success ]; then ok "last backup run did not fail"; else fail "last backup run: $result"; fi
stamp="$DATA_DIR/backups/last-success"
if [ -f "$stamp" ]; then
  age_h=$(( ( $(date +%s) - $(stat -c %Y "$stamp") ) / 3600 ))
  if [ "$age_h" -lt 26 ]; then ok "last successful backup ${age_h} h ago"
  else fail "last successful backup ${age_h} h ago"; fi
else
  fail "no successful backup recorded yet"
fi

# ── Updates of the system ────────────────────────────────────────────────────
# Only where install.sh set them up (HOST_AUTO_UPDATES=true). A reboot that an
# update asked for happens the same night; one still waiting after two days
# means the nightly run does not get through.
reboot_flag=/var/run/reboot-required
if [ "$(env_get HOST_AUTO_UPDATES)" = "true" ] && command -v apt-get >/dev/null; then
  check "automatic updates of the system are set up" test -f /etc/apt/apt.conf.d/52hobcrew-box-updates
  check "apt-daily-upgrade.timer is active" systemctl is-active --quiet apt-daily-upgrade.timer
  # exec-condition: the run was skipped because an update of HobCrew Box was
  # in progress (server/host-updates-service.conf).
  result="$(systemctl show apt-daily-upgrade.service -p Result --value 2>/dev/null)"
  case "$result" in
    success|exec-condition|"") ok "last update of the system did not fail" ;;
    *) fail "last update of the system: $result (journalctl -u apt-daily-upgrade)" ;;
  esac
  # apt's script ends successfully whatever unattended-upgrade did, so a
  # package that did not install shows only in unattended-upgrades' own log:
  # its last run, from the last "Starting" line on. Every run writes to it,
  # also one with nothing to do. A new server has an empty one (from the
  # distribution's image, as old as that) until its first night.
  uu_log=/var/log/unattended-upgrades/unattended-upgrades.log
  if [ -s "$uu_log" ]; then
    if awk '/Starting unattended upgrades script/ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' "$uu_log" |
       grep -qE ' (ERROR|CRITICAL) '; then
      fail "the last nightly update of the system reported errors ($uu_log)"
    else
      ok "the last nightly update of the system reported no errors"
    fi
    if [ -n "$(find "$uu_log" -mmin +2880 2>/dev/null)" ]; then
      fail "the system has not run its nightly update for more than two days"
    fi
  fi
  if [ -n "$(find "$reboot_flag" -mmin +2880 2>/dev/null)" ]; then
    fail "the system has waited for a reboot for more than two days"
  else
    ok "no reboot is overdue"
  fi
elif [ -f "$reboot_flag" ]; then
  warn "the system needs a reboot to finish an update"
fi

# ── The installation's own checks ────────────────────────────────────────────
# Every instance/check.d/*.sh is one check, named after its file: it passes
# when the script exits 0; the last line it printed is shown with a failure.
for script in "$REPO_DIR"/instance/check.d/*.sh; do
  [ -f "$script" ] || continue
  name="$(basename "$script" .sh)"
  if output="$(REPO_DIR="$REPO_DIR" DATA_DIR="$DATA_DIR" bash "$script" 2>&1)"; then ok "$name"
  else fail "$name: $(printf '%s' "$output" | tail -n1)"; fi
done

[ "$quiet" -eq 1 ] || { [ "$failed" -eq 0 ] && echo "all checks passed" || echo "some checks FAILED"; }
exit "$failed"
