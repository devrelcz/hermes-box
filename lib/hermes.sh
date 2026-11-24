# shellcheck shell=bash
# The hermes CLI against the data directory, several commands at once: one
# container and one Python process for all of them (lib/hermes-batch.py),
# instead of a few seconds of loading Hermes for each. Sourced by install.sh
# and setup.sh, which set IMAGE, RUN_UID, RUN_GID, DATA_DIR and REPO_DIR.
#
#   hermes_batch "config get webapp.enabled" "config set terminal.home_mode real"
#   batch_out "config get webapp.enabled"   what that command printed
#   batch_ok "config set terminal.home_mode real" || ...   whether it exited with 0
#
# Each argument is one command without "hermes", read the way a shell reads
# it; quote values with shq. Offline: no command gets the network. Not at the
# end of a pipe: HERMES_BATCH would be set in a subshell and lost.

HERMES_BATCH="[]"

hermes_batch() {  # <command>...
  HERMES_BATCH="$(printf '%s\n' "$@" | docker run --rm -i --init --network none \
    -u "$RUN_UID:$RUN_GID" -e HERMES_HOME=/opt/data -e HOME=/opt/data \
    -v "$DATA_DIR/.hermes:/opt/data" \
    -v "$REPO_DIR/lib/hermes-batch.py:/opt/hermes-batch.py:ro" \
    --entrypoint /opt/hermes/.venv/bin/python "$IMAGE" -P /opt/hermes-batch.py 2>/dev/null)" ||
    { HERMES_BATCH="[]"; return 1; }
}

# The result of one command of the last batch, found by its line as given,
# exactly as printed (-j: no newline of its own added).
batch_field() {  # <field> <line>
  jq -j --arg line "$2" --arg field "$1" \
    'first(.[] | select(.line == $line)) | .[$field] // empty' <<<"$HERMES_BATCH"
}
batch_out() { batch_field out "$1"; }
batch_err() { batch_field err "$1"; }
batch_ok() { [ "$(batch_field code "$1")" = 0 ]; }

# A value in single quotes, for a line of hermes_batch.
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
