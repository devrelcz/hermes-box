"""hobcrew-secrets: the app passwords and tokens a customer gave their Hobs on hobcrew.com.

They reach the server encrypted (instance/secrets/apps/apps.enc.yaml, SOPS + age) and are
decrypted into memory by docker/apps-secrets.sh. This plugin hands them out without putting them
in front of the model:

- variables (``env``) go into the environment of each command a Hob runs
  (``ctx.register_session_env``), not into the agent's own environment or prompt;
- sign-ins (``logins``) are a login backend of the browser vault: the model sees a handle, the
  password is filled into the page on the server (``browser_vault`` fill);
- every known value is replaced by ``[secret:NAME]`` in terminal output and tool results;
- the tool ``hobcrew_secrets`` lists what exists (never values) and gives the link where the
  customer adds a missing one, so no one types a password into the chat.

Copied into /opt/hermes/plugins/hobcrew/secrets by the Dockerfile, so it loads like a bundled
backend in every profile (Hob).
"""
from __future__ import annotations

import json
import logging
import os
import threading
from typing import Any, Optional
from urllib.parse import urlencode

logger = logging.getLogger(__name__)

STORE = os.environ.get("HOBCREW_APPS_DIR", "/run/hermes-secrets/apps")
BACKEND = "hobcrew"
# Shorter values would mask ordinary words and numbers in the output.
MIN_REDACT = 6


class Store:
    """What apps-secrets.sh wrote, re-read when it swaps in a new directory."""

    def __init__(self, path: str = STORE):
        self.path = path
        self._lock = threading.Lock()
        self._seen: Optional[str] = None
        self.meta: dict[str, Any] = {"request_url": None, "env": {}, "logins": {}}
        self.values: dict[str, str] = {}
        self._redact: list[tuple[str, str]] = []
        # Values removed since the start stay masked: a revoked token may still work elsewhere.
        self._past: dict[str, str] = {}

    def refresh(self) -> bool:
        """Re-reads after a change; True when something changed."""
        current = os.path.realpath(self.path) if os.path.isdir(self.path) else None
        if current == self._seen:
            return False
        with self._lock:
            if current == self._seen:
                return False
            meta: dict[str, Any] = {"request_url": None, "env": {}, "logins": {}}
            values: dict[str, str] = {}
            passwords: dict[str, str] = {}
            if current:
                try:
                    with open(os.path.join(current, "meta.json"), encoding="utf-8") as fh:
                        meta.update(json.load(fh))
                    for name in meta["env"]:
                        values[name] = _read(os.path.join(current, "values", name))
                    for ident in meta["logins"]:
                        passwords[ident] = _read(os.path.join(current, "logins", ident))
                except (OSError, ValueError) as err:
                    # Never the error text: it could name a value's file, not hold it, but stay safe.
                    logger.warning("hobcrew-secrets: cannot read %s (%s)", current, type(err).__name__)
                    meta, values, passwords = {"request_url": None, "env": {}, "logins": {}}, {}, {}
            redact = dict(self._past)
            redact.update({v: n for n, v in values.items()})
            redact.update({v: meta["logins"][i].get("label") or i for i, v in passwords.items()})
            self._past = redact
            self.meta, self.values, self._passwords = meta, values, passwords
            self._redact = sorted(((v, n) for v, n in redact.items() if len(v) >= MIN_REDACT),
                                  key=lambda pair: -len(pair[0]))
            self._seen = current
            return True

    def password(self, ident: str) -> str:
        self.refresh()
        return self._passwords[ident]

    def redact(self, text: str) -> str:
        for value, name in self._redact:
            if value in text:
                text = text.replace(value, f"[secret:{name}]")
        return text


def blocked_names(names) -> set[str]:
    """Names Hermes keeps out of every command's environment (provider and tool keys such as
    OPENAI_API_KEY or GITHUB_TOKEN, which it manages itself). A value under such a name never
    reaches a command, so the customer should pick another name."""
    try:
        from tools.environments.local import _scrub_credentials
        kept = _scrub_credentials({n: "x" for n in names}, inherit_credentials=False)
    except Exception:
        return set()
    return set(names) - set(kept)


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


store = Store()


# -- browser vault ---------------------------------------------------------------------------

def _login_backend():
    from agent.vault_backends.base import LoginBackend
    from agent.vault_store import VaultItemMeta

    class HobCrewLogins(LoginBackend):
        name = BACKEND
        display_name = "HobCrew"
        prefix = BACKEND + ":"

        def _meta(self, ident: str, item: dict) -> VaultItemMeta:
            return VaultItemMeta(
                id=self.prefix + ident, kind="login", label=item.get("label") or ident,
                origin=item["origin"], created_at="", identifier=item.get("username"),
                identifier_type="username" if item.get("username") else None,
                allowed_origins=(item["origin"],),
            )

        def list_items(self):
            store.refresh()
            return [self._meta(i, item) for i, item in sorted(store.meta["logins"].items())]

        def get_meta(self, handle):
            store.refresh()
            item = store.meta["logins"].get(handle[len(self.prefix):])
            return None if item is None else self._meta(handle[len(self.prefix):], item)

        def resolve_password(self, handle):
            return store.password(handle[len(self.prefix):])

    return HobCrewLogins()


# -- tool ------------------------------------------------------------------------------------

SCHEMA = {
    "name": "hobcrew_secrets",
    "description": (
        "Passwords, tokens and sign-ins the customer gave you on hobcrew.com. action=list shows what "
        "exists: variables (already set in the environment of every command you run, use them as "
        "$NAME and never print them) and sign-ins (fill them with browser_vault, handle "
        "'hobcrew:<id>'). Values are never shown. action=request returns a link where the customer "
        "adds a missing one: send them the link and never ask for a password or token in the chat."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["list", "request"]},
            "name": {"type": "string", "description": "request: variable name, e.g. GITHUB_TOKEN, or a sign-in id"},
            "kind": {"type": "string", "enum": ["env", "login"], "description": "request: variable or browser sign-in"},
            "description": {"type": "string", "description": "request: what it is for, shown to the customer"},
            "origin": {"type": "string", "description": "request, kind=login: the site, e.g. https://github.com"},
        },
        "required": ["action"],
    },
}


def _tool(args: dict, **_kwargs) -> str:
    store.refresh()
    action = (args or {}).get("action")
    if action == "list":
        blocked = blocked_names(store.meta["env"])
        return json.dumps({
            "variables": [{"name": n, "description": m.get("description") or ""}
                          | ({"in_commands": False, "note": "Hermes keeps this name out of commands; ask the "
                              "customer to rename it on hobcrew.com"} if n in blocked else {})
                          for n, m in sorted(store.meta["env"].items())],
            "sign_ins": [{"handle": f"{BACKEND}:{i}", "label": m.get("label"), "origin": m.get("origin"),
                          "username": m.get("username")} for i, m in sorted(store.meta["logins"].items())],
        }, ensure_ascii=False)
    if action == "request":
        url = store.meta.get("request_url") or os.environ.get("HOBCREW_SECRETS_URL")
        if not url:
            return json.dumps({"message": "Ask the customer to add it on hobcrew.com, in this crew's "
                                          "'Passwords and keys'. Never ask for the value in the chat."})
        query = {k: str(args[k])[:200] for k in ("name", "kind", "description", "origin") if args.get(k)}
        link = url + ("&" if "?" in url else "?") + urlencode(query) if query else url
        return json.dumps({"link": link, "message": "Send this link to the customer. They enter the value "
                                                    "there; it reaches you within a minute or two."})
    return json.dumps({"error": "action must be list or request"})


# -- registration ----------------------------------------------------------------------------

def register(ctx) -> None:
    lock = threading.Lock()
    state: dict[str, Any] = {"names": None, "release": None}

    def resolve(_session_id: str) -> dict[str, Optional[str]]:
        store.refresh()
        return {n: store.values.get(n) for n in state["names"] or ()}

    def sync_env() -> None:
        """Declares the current variable names; new names need a new registration."""
        store.refresh()
        names = frozenset(store.values)
        with lock:
            if names == state["names"] or not names and state["names"] is None:
                return
            if state["release"] is not None:
                state["release"].dispose()
                state["release"] = None
            state["names"] = names
            if names:
                state["release"] = ctx.register_session_env(sorted(names), resolve)

    def on_pre_tool_call(**_kwargs):
        try:
            sync_env()
        except Exception as err:  # never block a tool on our account
            logger.warning("hobcrew-secrets: %s", type(err).__name__)
        return None

    def on_terminal_output(output: str = "", **_kwargs):
        if isinstance(output, str):
            store.refresh()
            masked = store.redact(output)
            if masked != output:
                return masked
        return None

    def on_tool_result(result: Any = None, **_kwargs):
        if isinstance(result, str):
            store.refresh()
            masked = store.redact(result)
            if masked != result:
                return masked
        return None

    sync_env()
    ctx.register_hook("pre_tool_call", on_pre_tool_call)
    ctx.register_hook("transform_terminal_output", on_terminal_output)
    ctx.register_hook("transform_tool_result", on_tool_result)
    ctx.register_tool(name="hobcrew_secrets", toolset="hobcrew", schema=SCHEMA, handler=_tool,
                      description=SCHEMA["description"], emoji="🔑")
    ctx.register_login_backend(_login_backend())
    ctx.register_system_prompt_section(
        "hobcrew.secrets",
        "Passwords, tokens and sign-ins for apps come from the customer through hobcrew.com, never "
        "through the chat. Use the hobcrew_secrets tool to see which exist and to get a link for a "
        "missing one. Variables are set in the environment of your commands ($NAME); do not print, "
        "copy or write their values anywhere.",
    )
