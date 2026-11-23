"""hermes-box web backend: SearXNG search + page reading on this server. Copied into
/opt/hermes/plugins/web/hermes_box by the Dockerfile, so it loads like a bundled backend."""
from __future__ import annotations
from plugins.web.hermes_box.provider import HermesBoxWebProvider


def register(ctx) -> None:
    ctx.register_web_search_provider(HermesBoxWebProvider())
