"""hobcrew-box web backend: SearXNG search + page reading on this server. Copied into
/opt/hermes/plugins/web/hobcrew_box by the Dockerfile, so it loads like a bundled backend."""
from __future__ import annotations
from plugins.web.hobcrew_box.provider import HobCrewBoxWebProvider


def register(ctx) -> None:
    ctx.register_web_search_provider(HobCrewBoxWebProvider())
