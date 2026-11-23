#!/usr/bin/env bash
# get.sh downloads the installer's files and runs them as root, so it carries
# their SHA-256 and refuses files that differ. This keeps the two alike:
#
#   installer/sums.sh          write the checksums of the files into get.sh
#   installer/sums.sh --check  fail when get.sh has other ones (run by CI)
#
# Run it after every change to server.py, steps.sh or index.html.

set -euo pipefail

cd "$(dirname "$0")/.."

sha() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

block="$(for file in server.py steps.sh index.html; do printf '%s  %s\n' "$(sha "installer/$file")" "$file"; done)"
current="$(sed -n '/^# installer-sums: begin/,/^# installer-sums: end/p' get.sh | grep -E '^[0-9a-f]{64}  ' || true)"

if [ "${1:-}" = --check ]; then
  [ "$block" = "$current" ] && exit 0
  echo "get.sh has other checksums than the files in installer/; run installer/sums.sh" >&2
  exit 1
fi

tmp="$(mktemp)"
sums="$(mktemp)"
printf '%s\n' "$block" > "$sums"
awk -v sums="$sums" '
  /^# installer-sums: begin/ {
    print; print "WEB_SUMS=\""
    while ((getline line < sums) > 0) print line
    print "\""; skip = 1; next
  }
  /^# installer-sums: end/ { skip = 0 }
  !skip { print }' get.sh > "$tmp"
cat "$tmp" > get.sh
rm -f "$tmp" "$sums"
echo "get.sh: checksums updated"
