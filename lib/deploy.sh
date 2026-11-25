# shellcheck shell=bash
# Restarting a running installation safely. Sourced by deploy/hermes-deploy.sh
# (an installation from git) and update.sh (an installation from the image);
# both define REPO_DIR and env_get (one KEY from the installation's .env).
#
#   wait_for_quiet_moment   return when no cron job of the agent is about to start
#   restart_and_check       restart the stack; succeeds when the Webapp answers
#                           and check.sh --quiet passes (its failures on stdout)

webapp_up() {
  case "$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' http://127.0.0.1:9120/ 2>/dev/null)" in
    200|301|302) return 0 ;; *) return 1 ;;
  esac
}

# Restart the stack and wait until the Webapp answers and the checks pass.
restart_and_check() {
  systemctl restart hermes-docker.service || return 1
  local i
  for i in $(seq 1 100); do webapp_up && break; sleep 3; done
  webapp_up || return 1
  sleep 20   # let the gateway connect to its platforms
  "$REPO_DIR/check.sh" --quiet
}

# Do not cut off a cron job that is about to start; running turns are drained
# by the gateway itself when it stops. Gives up waiting after 10 minutes.
wait_for_quiet_moment() {
  local data jobs _
  data="$(env_get HERMES_DATA_DIR)"; jobs="${data:-/home/hermes}/.hermes/cron/jobs.json"
  for _ in $(seq 1 20); do
    python3 - "$jobs" <<'PY' && return 0
import datetime, json, sys
try:
    jobs = json.load(open(sys.argv[1])).get("jobs", [])
except Exception:
    sys.exit(0)
now = datetime.datetime.now(datetime.timezone.utc)
for job in jobs:
    if not job.get("enabled"):
        continue
    try:
        due = datetime.datetime.fromisoformat(job["next_run_at"])
    except Exception:
        continue
    if -90 <= (due - now).total_seconds() <= 150:
        sys.exit(1)   # a job starts within 2.5 minutes or started just now
PY
    sleep 30
  done
  return 0
}
