# shellcheck shell=bash
# shellcheck disable=SC2034  # CHOICE and STEP_STATUS are read by the scripts that source this
# What the installer shows on the terminal, shared by setup.sh and pair.sh:
# headings, one progress line per long step (its output goes to a log), and
# menus. get.sh carries its own copy of the few pieces it needs, because it
# runs before these files are on the server; keep the two alike.
#
# Settings, through the environment:
#
#   HERMES_BOX_VERBOSE=1     show every command's output instead of a progress line
#   HERMES_BOX_LOG=<file>    where that output goes (default /var/log/hermes-box-setup.log)
#   HERMES_BOX_EVENTS=1      announce every step on stdout, for the installer's API
#   NO_COLOR=1               no colours

UI_LOG="${HERMES_BOX_LOG:-/var/log/hermes-box-setup.log}"
UI_VERBOSE="${HERMES_BOX_VERBOSE:-0}"
# What an interrupted run tells the user; the script sets its own.
UI_INTERRUPT_HINT=""
UI_PID=""

# A terminal to draw on and to read answers from.
UI_TTY=0
if [ -t 1 ] && (: </dev/tty) 2>/dev/null; then UI_TTY=1; fi
if [ "$UI_TTY" -eq 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
  UI_B=$'\033[1m' UI_D=$'\033[2m' UI_G=$'\033[32m' UI_R=$'\033[31m' UI_Y=$'\033[33m' UI_C=$'\033[36m' UI_N=$'\033[0m'
else
  UI_B='' UI_D='' UI_G='' UI_R='' UI_Y='' UI_C='' UI_N=''
fi

say()  { printf '\n%s==>%s %s%s%s\n' "$UI_C" "$UI_N" "$UI_B" "$*" "$UI_N"; }
note() { printf '    %s\n' "$*"; }
hint() { printf '    %s%s%s\n' "$UI_D" "$*" "$UI_N"; }
ok()   { printf '    %s✓%s %s\n' "$UI_G" "$UI_N" "$*"; }
warn() { printf '    %s!%s %s\n' "$UI_Y" "$UI_N" "$*"; }
fail() { printf '    %s✗%s %s\n' "$UI_R" "$UI_N" "$*"; }

ui_cursor_off() { [ "$UI_TTY" -eq 0 ] || printf '\033[?25l' >/dev/tty; }
ui_cursor_on()  { [ "$UI_TTY" -eq 0 ] || printf '\033[?25h' >/dev/tty; }

# Stop a step that is running in the background, with what it started.
ui_kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do ui_kill_tree "$child"; done
  kill "$1" 2>/dev/null || true
}
ui_interrupted() {
  trap - INT TERM
  [ -z "$UI_PID" ] || ui_kill_tree "$UI_PID"
  ui_cursor_on
  [ "$UI_TTY" -eq 0 ] || stty echo </dev/tty 2>/dev/null || true
  printf '\n\n    Interrupted.%s\n' "${UI_INTERRUPT_HINT:+ $UI_INTERRUPT_HINT}"
  exit 130
}
trap ui_interrupted INT TERM
trap ui_cursor_on EXIT

# Start the log of this run; everything the steps print goes there.
ui_log_start() {  # <name of the script>
  (umask 077; mkdir -p "$(dirname "$UI_LOG")"; touch "$UI_LOG") 2>/dev/null || UI_LOG=/dev/null
  printf '\n===== %s, %s\n' "$1" "$(date '+%F %T')" >>"$UI_LOG"
}

ui_duration() {  # <seconds>
  if [ "$1" -ge 60 ]; then printf '%dm %02ds' $(($1 / 60)) $(($1 % 60)); else printf '%ds' "$1"; fi
}

# For a program that runs the script and shows its progress (the installer's
# API, installer/server.py): with HERMES_BOX_EVENTS=1 every step is announced
# on stdout as "@@step start|<title>" and "@@step end|<status>|<title>".
ui_event() { [ "${HERMES_BOX_EVENTS:-0}" != 1 ] || printf '@@step %s\n' "$1"; }

# Run one step: its output goes to the log, the terminal shows a spinner and
# how long it has taken. step stops the script when the step fails, after
# showing the end of the log; step_try only sets STEP_STATUS. With
# HERMES_BOX_VERBOSE=1 the output is shown as well.
STEP_STATUS=0
step_try() {  # <title> <command...>
  local title="$1" started="$SECONDS" i=0 frames
  frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  shift
  STEP_STATUS=0
  printf '\n--- %s (%s)\n' "$title" "$*" >>"$UI_LOG"
  UI_LOG_FROM=$(($(wc -l <"$UI_LOG") + 1))
  ui_event "start|$title"
  if [ "$UI_VERBOSE" -eq 1 ]; then
    say "$title"
    ( set -o pipefail; "$@" 2>&1 | tee -a "$UI_LOG" ) &
    UI_PID=$!
  else
    ( "$@" ) >>"$UI_LOG" 2>&1 </dev/null &
    UI_PID=$!
    if [ "$UI_TTY" -eq 1 ]; then
      ui_cursor_off
      while kill -0 "$UI_PID" 2>/dev/null; do
        printf '\r\033[K    %s%s%s %s %s%s%s' "$UI_C" "${frames[i++ % 10]}" "$UI_N" "$title" \
          "$UI_D" "$(ui_duration $((SECONDS - started)))" "$UI_N"
        sleep 0.1
      done
      printf '\r\033[K'
      ui_cursor_on
    fi
  fi
  wait "$UI_PID" || STEP_STATUS=$?
  UI_PID=""
  if [ "$STEP_STATUS" -eq 0 ]; then
    ok "$title ${UI_D}$(ui_duration $((SECONDS - started)))${UI_N}"
  else
    fail "$title"
  fi
  printf -- '--- exit %s after %ss\n' "$STEP_STATUS" $((SECONDS - started)) >>"$UI_LOG"
  ui_event "end|$STEP_STATUS|$title"
  return 0
}
step() {  # <title> <command...>
  step_try "$@"
  [ "$STEP_STATUS" -eq 0 ] && return 0
  if [ "$UI_VERBOSE" -ne 1 ] && [ "$UI_LOG" != /dev/null ]; then
    printf '\n'
    tail -n "+$UI_LOG_FROM" "$UI_LOG" | sed '/^--- exit /d' | tail -n 25 | sed 's/^/      /'
  fi
  printf '\n    The whole output is in %s.\n' "$UI_LOG"
  [ -z "$UI_INTERRUPT_HINT" ] || printf '    %s\n' "$UI_INTERRUPT_HINT"
  exit 1
}

# choose <ENV_NAME> <question> <default> <value> <label> [<value> <label>]...
#
# Sets CHOICE to one of the values: the one in $ENV_NAME when that is set
# (yes/no accept the usual spellings), else the one picked in a menu (arrow
# keys or the item's number, then Enter), else the default when there is no
# terminal. A label may go on with " — " and a description, shown dimmed.
CHOICE=""
choose() {
  local env="$1" question="$2" default="$3"
  shift 3
  local -a values=() labels=()
  while [ $# -ge 2 ]; do values+=("$1"); labels+=("$2"); shift 2; done
  local n=${#values[@]} sel=0 i key rest preset="${!env:-}"
  for i in "${!values[@]}"; do [ "${values[$i]}" != "$default" ] || sel=$i; done

  if [ -n "$preset" ]; then
    case "$preset" in
      y|Y|yes|YES|Yes|true|ano|a) preset=yes ;;
      n|N|no|NO|No|false|ne) preset=no ;;
    esac
    CHOICE="$preset"
    return 0
  fi
  if [ "$UI_TTY" -eq 0 ]; then CHOICE="${values[$sel]}"; return 0; fi

  printf '\n  %s?%s %s%s%s\n' "$UI_C" "$UI_N" "$UI_B" "$question" "$UI_N" >/dev/tty
  if [ "${TERM:-dumb}" = dumb ]; then  # no cursor movement: a numbered list
    for i in "${!labels[@]}"; do printf '    %d) %s\n' $((i + 1)) "${labels[$i]}" >/dev/tty; done
    while :; do
      read -r -p "    Number [$((sel + 1))]: " key </dev/tty || key=""
      [ -n "$key" ] || break
      case "$key" in *[!0-9]*) continue ;; esac
      if [ "$key" -ge 1 ] && [ "$key" -le "$n" ]; then sel=$((key - 1)); break; fi
    done
    CHOICE="${values[$sel]}"
    return 0
  fi

  ui_menu_draw() {
    local j title desc
    for j in "${!labels[@]}"; do
      title="${labels[$j]%% — *}" desc=""
      [ "$title" = "${labels[$j]}" ] || desc=" — ${labels[$j]#* — }"
      if [ "$j" -eq "$sel" ]; then
        printf '\033[2K    %s❯ %s%s%s%s%s%s\n' "$UI_C" "$UI_B" "$title" "$UI_N" "$UI_D" "$desc" "$UI_N"
      else
        printf '\033[2K      %s%s%s%s\n' "$title" "$UI_D" "$desc" "$UI_N"
      fi
    done
    printf '\033[2K      %s↑/↓ and Enter, or the number%s\n' "$UI_D" "$UI_N"
  }
  ui_cursor_off
  ui_menu_draw >/dev/tty
  while :; do
    key=""
    IFS= read -rsn1 key </dev/tty || break
    if [ "$key" = $'\033' ]; then
      rest=""
      IFS= read -rsn2 -t 0.1 rest </dev/tty || true
      key+="$rest"
    fi
    case "$key" in
      $'\033[A'|$'\033OA'|k) sel=$(((sel + n - 1) % n)) ;;
      $'\033[B'|$'\033OB'|j) sel=$(((sel + 1) % n)) ;;
      [1-9]) [ "$key" -gt "$n" ] || { sel=$((key - 1)); break; } ;;
      '') break ;;
      *) continue ;;
    esac
    printf '\033[%dA' $((n + 1)) >/dev/tty
    ui_menu_draw >/dev/tty
  done
  # The menu gives way to the answer.
  printf '\033[%dA\033[J    %s%s%s\n' $((n + 1)) "$UI_C" "${labels[$sel]%% — *}" "$UI_N" >/dev/tty
  ui_cursor_on
  CHOICE="${values[$sel]}"
}

# ask <ENV_NAME> <question> [default]: the preset value, else the answer
# typed on the terminal, else the default.
ask() {
  local preset="${!1:-}" answer=""
  if [ -n "$preset" ]; then printf '%s' "$preset"; return; fi
  if [ "$UI_TTY" -eq 1 ]; then
    if [ -n "${3:-}" ]; then
      read -r -p "    $2 [$3]: " answer </dev/tty || true
    else
      read -r -p "    $2: " answer </dev/tty || true
    fi
  fi
  printf '%s' "${answer:-${3:-}}"
}

# The first screen of a new installation: what Hermes Box is, what is about
# to happen and what ends up on the server. get.sh shows the same text.
ui_intro() {  # <installation directory> <data directory> <key file>
  cat <<EOF

  ${UI_B}Hermes Box${UI_N} ${UI_D}· Hermes Agent on your own server${UI_N}

  Hermes Agent (by Nous Research) is an AI assistant that works on its own:
  it keeps a memory, runs scheduled jobs, searches the web and uses a browser.
  You talk to it in a web app on your own address and in the mobile app.
  Its data and the key to its secrets stay on this server.

  ${UI_B}What happens now${UI_N}
    1. Docker is installed, if it is missing.
    2. Hermes Box is downloaded: about 5 GB, the longest part.
    3. A few questions: the web address, a user name and password, the model.
    4. Everything is set up and started: HTTPS, a daily backup, a health check.
    It takes 10 to 20 minutes. Running it again skips the finished steps.

  ${UI_B}What it puts on this server${UI_N}
    $(printf '%-28s' "$1")scripts and this installation's settings
    $(printf '%-28s' "$2")the agent's data and its backups
    $(printf '%-28s' "$(dirname "$3")")the key that encrypts secrets and backups
    $(printf '%-28s' "services hermes-*")the web on ports 80 and 443, the backup timer

  ${UI_B}What you need${UI_N}
    a domain that points at this server (or none: <address>.sslip.io works)
    an account with an AI model provider and its API key
EOF
}
