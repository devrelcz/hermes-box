#!/bin/sh
# Decrypts the app secrets into memory, where the hobcrew_secrets plugin
# reads them: passwords and tokens the customer gave their Hobs on
# hobcrew.com (or put into the file by hand with ./sops.sh).
#
# Runs at container start (secrets-entrypoint) and again, without a restart,
# when the file changed: `docker exec hermes hobcrew-apps-secrets`.
#
# The file is instance/secrets/apps/apps.enc.yaml on the host, mounted at
# /etc/hermes/apps. Decrypted it looks like:
#
#   request_url: https://hobcrew.com/crews/<id>/secrets   (optional)
#   env:                       variables for the Hobs' commands
#     GITHUB_TOKEN: {value: ..., description: ...}
#   logins:                    sign-ins the browser fills in for the Hobs
#     github: {label: GitHub, origin: https://github.com, username: ..., password: ...}
#
# In /run/hermes-secrets/apps (a tmpfs, owned by the agent's user):
#   meta.json        names, descriptions, labels, origins, user names; no values
#   values/NAME      one value per file, mode 0400
#   logins/ID        one password per file, mode 0400
# "apps" is a symlink to a fresh directory each time, swapped atomically, so
# a reader never sees half of an update. No file: no app secrets, not an error.
set -eu

KEY_FILE=/run/secrets/age_key
APPS_FILE="${HOBCREW_APPS_SECRETS_FILE:-/etc/hermes/apps/apps.enc.yaml}"
BASE=/run/hermes-secrets

[ "$(id -u)" = 0 ] || { echo "[apps-secrets] run as root" >&2; exit 1; }
grep -q " $BASE tmpfs " /proc/mounts ||
  { echo "[apps-secrets] $BASE is not a tmpfs" >&2; exit 78; }

if [ -r "$APPS_FILE" ]; then
  plain="$(SOPS_AGE_KEY_FILE="$KEY_FILE" SOPS_DISABLE_VERSION_CHECK=1 \
    sops decrypt --output-type json "$APPS_FILE")" ||
    { echo "[apps-secrets] could not decrypt $APPS_FILE" >&2; exit 78; }
else
  plain='{}'
fi

printf '%s' "$plain" | BASE="$BASE" /opt/hermes/.venv/bin/python3 -c '
import json, os, re, shutil, sys, tempfile

base = os.environ["BASE"]
uid, gid = int(os.environ.get("HERMES_UID", 1000)), int(os.environ.get("HERMES_GID", 1000))
data = json.load(sys.stdin) or {}
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]{0,127}")
ID = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")

def text(value):
    return value if isinstance(value, str) else ("" if value is None else str(value))

meta = {"request_url": text(data.get("request_url")) or None, "env": {}, "logins": {}}
values, logins = {}, {}
for name, item in (data.get("env") or {}).items():
    if not NAME.fullmatch(name) or name.upper().startswith("HERMES_"):
        sys.exit(f"[apps-secrets] not a usable variable name: {name!r}")
    item = item if isinstance(item, dict) else {"value": item}
    value = text(item.get("value"))
    if not value:
        continue
    values[name] = value
    meta["env"][name] = {"description": text(item.get("description"))}
for ident, item in (data.get("logins") or {}).items():
    if not ID.fullmatch(ident) or not isinstance(item, dict):
        sys.exit(f"[apps-secrets] not a usable login id: {ident!r}")
    password, origin = text(item.get("password")), text(item.get("origin")).rstrip("/")
    if not password or not origin.startswith("https://"):
        continue
    logins[ident] = password
    meta["logins"][ident] = {"label": text(item.get("label")) or ident, "origin": origin,
                             "username": text(item.get("username")) or None}

new = tempfile.mkdtemp(prefix=".apps-", dir=base)
for sub, items in (("values", values), ("logins", logins)):
    os.mkdir(os.path.join(new, sub), 0o500)
    for name, value in items.items():
        path = os.path.join(new, sub, name)
        with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400), "w") as fh:
            fh.write(value)
        os.chown(path, uid, gid)
    os.chown(os.path.join(new, sub), uid, gid)
with open(os.open(os.path.join(new, "meta.json"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400), "w") as fh:
    json.dump(meta, fh)
os.chown(os.path.join(new, "meta.json"), uid, gid)
os.chmod(new, 0o500)
os.chown(new, uid, gid)

link = os.path.join(base, "apps")
old = os.path.realpath(link) if os.path.islink(link) else None
tmp_link = link + ".new"
if os.path.lexists(tmp_link):
    os.unlink(tmp_link)
os.symlink(os.path.basename(new), tmp_link)
os.replace(tmp_link, link)
if old and old != new and os.path.dirname(old) == base:
    shutil.rmtree(old, ignore_errors=True)
print(f"[apps-secrets] {len(values)} variables, {len(logins)} logins")
'
