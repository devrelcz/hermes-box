"""hermes-box web backend: search through the SearXNG on this server, read pages on this server.

web_search goes to SearXNG (``SEARXNG_URL``), the same call as Hermes' own ``searxng``
backend. web_extract fetches each page itself and turns it into markdown: HTML with
trafilatura (or markdownify for pages that are not one article), PDF with pypdf, text
as it is. No outside service sees the URLs.

What it cannot do is run JavaScript: a page that builds its text in the browser comes
back with an error that points the agent to the browser tool.

The fetch uses Hermes' SSRF-safe client, so every connection, redirects included, is
checked against private and internal addresses; the final URL is reported, so Hermes
re-checks a redirect target against the website policy as well.
"""

from __future__ import annotations

import io
import logging
import re
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Optional

import httpx

from plugins.web._common import (
    BaseWebSearchProvider, document, page_error, run_extract, run_search, setup_schema, with_origin_status,
)

logger = logging.getLogger(__name__)

MAX_BYTES = 10 * 1024 * 1024  # what is read of one response; larger pages are cut
MAX_PDF_PAGES = 300
MIN_TEXT_CHARS = 200  # less than this from a whole HTML page: its text is built by JavaScript
WORKERS = 4  # pages fetched at the same time
TIMEOUT = httpx.Timeout(30.0, connect=10.0)
HEADERS = {
    "Accept": "text/html,application/xhtml+xml,application/pdf;q=0.9,text/*;q=0.8,*/*;q=0.5",
}

_TEXT_TYPES = {
    "text/plain", "text/markdown", "text/x-markdown", "text/csv", "text/xml",
    "application/json", "application/xml", "application/rss+xml", "application/atom+xml",
}
_HTML_TYPES = {"text/html", "application/xhtml+xml"}
_NEEDS_BROWSER = ("the page has no readable text; it probably builds it with JavaScript. "
                  "Open it with the browser tool instead.")


def _content_type(response: httpx.Response, body: bytes) -> str:
    declared = response.headers.get("content-type", "").split(";")[0].strip().lower()
    if declared and declared not in ("application/octet-stream", "binary/octet-stream"):
        return declared
    head = body[:1024].lstrip().lower()
    if head.startswith(b"%pdf"):
        return "application/pdf"
    if head.startswith((b"<!doctype html", b"<html", b"<head", b"<body")):
        return "text/html"
    return declared or "application/octet-stream"


def _decode(response: httpx.Response, body: bytes) -> str:
    encoding = response.charset_encoding or "utf-8"
    try:
        return body.decode(encoding, errors="replace")
    except LookupError:
        return body.decode("utf-8", errors="replace")


def _html_to_markdown(body: bytes, url: str) -> tuple[str, str]:
    """``(title, markdown)``; markdown is "" when the page has too little text of its own.

    trafilatura finds an article's text and leaves out menus and footers. On a page that
    is not one article (a price list, a news front page, an index) it keeps one block
    and drops the rest, tables included; when its text is less than half of the page's
    visible text, the whole page is converted instead, minus menus, scripts and footers.
    """
    import trafilatura

    main = trafilatura.extract(
        body, url=url, output_format="markdown", include_links=True, include_tables=True,
        include_images=False, include_comments=False, favor_recall=True,
    ) or ""
    visible = len(trafilatura.html2txt(body) or "")
    text = main
    if visible > 2 * len(main):
        text = _whole_page_markdown(body, url) or main
    metadata = trafilatura.extract_metadata(body, default_url=url)
    title = (getattr(metadata, "title", None) or "") if metadata is not None else ""
    return title, text if len(text) >= MIN_TEXT_CHARS else ""


# Left out of a whole page: never text, or the site's frame around the content.
_DROP = ("//script | //style | //noscript | //template | //svg | //iframe | //nav | //aside"
         " | //header[not(ancestor::article or ancestor::main)]"
         " | //footer[not(ancestor::article or ancestor::main)]"
         " | //*[@aria-hidden='true'] | //*[@hidden] | //*[@role='navigation']")


def _whole_page_markdown(body: bytes, url: str) -> str:
    from lxml import html as lxml_html
    from markdownify import markdownify
    from trafilatura.utils import decode_file

    tree = lxml_html.fromstring(decode_file(body))
    for element in tree.xpath(_DROP):
        element.drop_tree()
    tree.make_links_absolute(url, resolve_base_href=True)
    markdown = markdownify(lxml_html.tostring(tree, encoding="unicode"), heading_style="ATX",
                           strip=["img", "button"])
    return re.sub(r"\n[ \t]*(\n[ \t]*)+", "\n\n", markdown).strip()


def _pdf_to_text(body: bytes) -> tuple[str, str]:
    from pypdf import PdfReader

    reader = PdfReader(io.BytesIO(body))
    pages = []
    for number, page in enumerate(reader.pages):
        if number >= MAX_PDF_PAGES:
            pages.append(f"[hermes-box: the PDF has more than {MAX_PDF_PAGES} pages; the rest was not read]")
            break
        pages.append(page.extract_text() or "")
    title = ""
    try:
        title = (reader.metadata.title or "") if reader.metadata else ""
    except Exception:  # a broken info dictionary leaves only the title out
        pass
    return str(title), "\n\n".join(pages).strip()


def _read(client: httpx.Client, url: str, format: Optional[str]) -> dict[str, Any]:
    try:
        with client.stream("GET", url) as response:
            chunks, size, cut = [], 0, False
            for chunk in response.iter_bytes():
                if size + len(chunk) > MAX_BYTES:
                    chunks.append(chunk[: MAX_BYTES - size])
                    cut = True
                    break
                chunks.append(chunk)
                size += len(chunk)
        body = b"".join(chunks)
    except httpx.TimeoutException:
        return page_error(url, f"the page did not answer within {TIMEOUT.read:.0f} s")
    except httpx.TooManyRedirects:
        return page_error(url, "too many redirects")
    except Exception as exc:  # SSRF refusals, DNS, TLS, connection errors: the message says which
        return page_error(url, f"could not fetch the page: {exc}")

    final_url = str(response.url)
    kind = _content_type(response, body)
    try:
        if kind in _HTML_TYPES and format == "html":
            title, content = "", _decode(response, body)
        elif kind in _HTML_TYPES:
            title, content = _html_to_markdown(body, final_url)
            if not content and response.status_code < 400:
                return page_error(url, _NEEDS_BROWSER)
        elif kind == "application/pdf":
            if cut:
                return page_error(url, f"the PDF is larger than {MAX_BYTES // 2**20} MB")
            title, content = _pdf_to_text(body)
            if not content:
                return page_error(url, "the PDF has no text layer (a scan?)")
        elif kind in _TEXT_TYPES or kind.startswith("text/"):
            title, content = "", _decode(response, body)
        else:
            return with_origin_status(page_error(url, f"cannot read content of type {kind}"),
                                      response.status_code, _reason(response))
    except Exception as exc:
        logger.warning("hermes-box: reading %s failed: %s", final_url, exc)
        return page_error(url, f"could not read the {kind} content: {exc}")

    if cut and content:
        content += f"\n\n[hermes-box: the response is larger than {MAX_BYTES // 2**20} MB; only its beginning was read]"
    if final_url != url:  # the redirect target, with the requested URL as source, like Keenable
        entry = document(final_url, title, content, source_url=url)
    else:
        entry = document(url, title, content)
    return with_origin_status(entry, response.status_code, _reason(response))


def _reason(response: httpx.Response) -> str:
    """The status text, with a hint where a site turns away readers that are not browsers
    (Cloudflare's "Just a moment..." page answers 403 or 503)."""
    reason = response.reason_phrase or ""
    if response.status_code in (403, 429, 503):
        reason += " (the site may turn away automated readers; the browser tool may get through)"
    return reason


class HermesBoxWebProvider(BaseWebSearchProvider):
    """Search with SearXNG on this server, read pages on this server."""

    NAME = "hermes-box"
    DISPLAY_NAME = "hermes-box (on this server)"
    KEY_ENV = "SEARXNG_URL"
    EXTRACT = True

    def is_available(self) -> bool:
        return True  # reading needs nothing; search reports a missing SEARXNG_URL itself

    def search(self, query: str, limit: int = 5) -> dict[str, Any]:
        from plugins.web.searxng.provider import SearXNGWebSearchProvider

        return run_search("hermes-box", logger, lambda: SearXNGWebSearchProvider().search(query, limit))

    def extract(self, urls: list[str], **kwargs: Any) -> list[dict[str, Any]]:
        format = kwargs.get("format")

        def _body() -> list[dict[str, Any]]:
            from tools.url_safety import create_ssrf_safe_client

            logger.info("hermes-box extract: %d URL(s)", len(urls))
            with create_ssrf_safe_client(follow_redirects=True, max_redirects=10, timeout=TIMEOUT,
                                         headers=HEADERS) as client:
                with ThreadPoolExecutor(max_workers=max(1, min(WORKERS, len(urls)))) as pool:
                    return list(pool.map(lambda u: _read(client, u, format), urls))

        return run_extract("hermes-box", logger, urls, _body)

    def get_setup_schema(self) -> dict[str, Any]:
        return setup_schema(
            "hermes-box (on this server)", "free · on this server",
            "Searches through the SearXNG on this server and reads pages here; no outside service.",
            "SEARXNG_URL", "SearXNG instance URL (set by hermes-box)", "",
        )
