#!/usr/bin/env python3
"""The installer's API, and the page that drives it.

get.sh starts this on a new server, over HTTPS with a certificate made for
the occasion. It runs the installation step by step (installer/steps.sh),
reports how far it is, and takes the few answers the installation needs. The
page (installer/index.html) is one client of the API; anything that can send
HTTPS requests is another.

Every /api/ call except /api/health needs the token get.sh printed:

    Authorization: Bearer <token>

    GET  /api/health           {"ok": true}; no token
    GET  /api/state?log_from=N the phase, the steps, what is still needed, the log from line N
    POST /api/start            begin; the body may carry answers already
    POST /api/answers          {"domain": ..., "user": ..., "password": ...}, any subset
    GET  /api/domain?name=...  where a host name points, and whether that is this server
    POST /api/retry            run a failed step again
    GET  /api/pair             the mobile app's QR code, as rows of 0 and 1
    POST /api/finish           stop the installer

Phases: idle (nothing changed yet), running, waiting (an answer is missing,
see "missing" in the state), failed (see "error"; retry), done.

Only the Python standard library is used: this runs before anything else is
on the server.
"""

import argparse
import hmac
import ipaddress
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

STEPS = [
    ("docker", "Docker"),
    ("download", "Downloading Hermes Box"),
    ("extract", "Unpacking the files"),
    ("setup", "Setting up and starting"),
]
DOMAIN_RE = re.compile(r"^(?=.{4,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")
USER_RE = re.compile(r"^[A-Za-z0-9._@-]{1,64}$")
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
EVENT = "@@step "
LOG_KEEP = 5000
LOG_PAGE = 500
MAX_BODY = 64 * 1024


class BadRequest(Exception):
    pass


def server_address():
    """This server's address on the way out, and whether it is a public one."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("1.1.1.1", 80))
            ip = probe.getsockname()[0]
    except OSError:
        return None, False
    return ip, ipaddress.ip_address(ip).is_global


class Installer:
    def __init__(self, steps_script):
        self.steps_script = steps_script
        self.cond = threading.Condition()
        self.phase = "idle"
        self.error = None
        self.steps = [
            {"id": step, "title": title, "status": "pending", "started": None, "finished": None, "substeps": []}
            for step, title in STEPS
        ]
        self.answers = {"domain": "", "user": "", "password": ""}
        self.needs = []
        self.missing = []
        self.info = {}
        self.summary = None
        self.finished = None
        self.log = []
        self.log_base = 0
        self.thread = None
        self.ip, self.public = server_address()
        self._inspect()

    # ── What steps.sh says ────────────────────────────────────────────────────
    def _script(self, command, stdin=None):
        result = subprocess.run(
            ["bash", self.steps_script, command], input=stdin, capture_output=True, text=True, timeout=120
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or f"steps.sh {command} failed")
        return result.stdout

    def _inspect(self):
        """Which answers this server still needs; an installed one may need none."""
        needs, info = [], {}
        for line in self._script("needs").splitlines():
            key, _, value = line.partition(" ")
            if key == "need":
                needs.append(value)
            elif key:
                info[key] = value
        with self.cond:
            self.needs, self.info = needs, info
            self.missing = self._missing()
        return self.missing

    def _missing(self):
        missing = []
        if "domain" in self.needs and not self.answers["domain"]:
            missing.append("domain")
        if "login" in self.needs and not (self.answers["user"] and self.answers["password"]):
            missing.append("login")
        return missing

    # ── Answers ───────────────────────────────────────────────────────────────
    def answer(self, body):
        if not isinstance(body, dict):
            raise BadRequest("a JSON object is expected")
        new = {}
        for key in ("domain", "user", "password"):
            if key in body and body[key] not in (None, ""):
                if not isinstance(body[key], str):
                    raise BadRequest(f"{key} has to be a string")
                new[key] = body[key]
        if "domain" in new:
            new["domain"] = new["domain"].strip().lower()
            if not DOMAIN_RE.match(new["domain"]):
                raise BadRequest("domain: only the host name, for example agent.example.com")
        if "user" in new and not USER_RE.match(new["user"]):
            raise BadRequest("user: letters, digits and . _ @ - only, at most 64 characters")
        if "password" in new:
            if len(new["password"]) < 12:
                raise BadRequest("password: at least 12 characters")
            if "\n" in new["password"] or "\r" in new["password"] or "\0" in new["password"]:
                raise BadRequest("password: one line only")
        with self.cond:
            setup = self.steps[-1]
            if new and setup["status"] in ("running", "done"):
                raise BadRequest("the settings are already being applied; they cannot be changed here any more")
            self.answers.update(new)
            self.missing = self._missing()
            self.cond.notify_all()

    # ── Running ───────────────────────────────────────────────────────────────
    def start(self):
        with self.cond:
            if self.phase == "idle":
                self._spawn()

    def retry(self):
        with self.cond:
            if self.phase != "failed":
                raise BadRequest("nothing has failed")
            for step in self.steps:
                if step["status"] == "failed":
                    step.update(status="pending", started=None, finished=None, substeps=[])
            self._spawn()

    def _spawn(self):
        self.phase, self.error = "running", None
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        try:
            for step in self.steps:
                if step["status"] == "done":
                    continue
                if step["id"] == "setup":
                    self._wait_for_answers()
                if not self._run_step(step):
                    with self.cond:
                        self.phase = "failed"
                        self.error = f"{step['title']} failed. The end of the log says why."
                    return
            summary = dict(
                line.split("=", 1) for line in self._script("summary").splitlines() if "=" in line
            )
            self._inspect()  # nothing is needed any more; say so
            with self.cond:
                self.summary, self.phase, self.finished = summary, "done", time.time()
        except Exception as error:  # a broken step script must not leave "running" forever
            with self.cond:
                self.phase, self.error = "failed", f"the installer itself failed: {error}"

    def _wait_for_answers(self):
        # The files are on the server now, so an existing installation can be
        # told from a new one for certain.
        self._inspect()
        with self.cond:
            while self._missing():
                self.missing = self._missing()
                self.phase = "waiting"
                self.cond.wait()
            self.missing = []
            self.phase = "running"

    def _run_step(self, step):
        env = dict(os.environ, HERMES_BOX_VERBOSE="1", HERMES_BOX_EVENTS="1", NO_COLOR="1", TERM="dumb")
        with self.cond:
            step.update(status="running", started=time.time(), finished=None, substeps=[])
            self._log(f"── {step['title']}")
            if step["id"] == "setup":
                if self.answers["domain"]:
                    env["SETUP_DOMAIN"] = self.answers["domain"]
                if self.answers["user"] and self.answers["password"]:
                    env["SETUP_WEBAPP_USER"] = self.answers["user"]
                    env["SETUP_WEBAPP_PASSWORD"] = self.answers["password"]
        process = subprocess.Popen(
            ["bash", self.steps_script, step["id"]],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env=env, text=True, errors="replace",
        )
        for line in process.stdout:
            line = ANSI_RE.sub("", line.rstrip("\n")).split("\r")[-1]
            with self.cond:
                if line.startswith(EVENT):
                    self._event(step, line[len(EVENT):])
                elif line.strip():
                    self._log(line)
        status = process.wait()
        with self.cond:
            for sub in step["substeps"]:
                if sub["status"] == "running":
                    sub.update(status="done" if status == 0 else "failed", finished=time.time())
            step.update(status="done" if status == 0 else "failed", finished=time.time())
        return status == 0

    def _event(self, step, text):
        """A line lib/ui.sh prints around each of its steps: start|<title>, end|<status>|<title>."""
        kind, _, rest = text.partition("|")
        if kind == "start":
            step["substeps"].append({"title": rest, "status": "running", "started": time.time(), "finished": None})
        elif kind == "end":
            status, _, title = rest.partition("|")
            for sub in reversed(step["substeps"]):
                if sub["title"] == title and sub["status"] == "running":
                    sub.update(status="done" if status == "0" else "failed", finished=time.time())
                    break

    def _log(self, line):
        self.log.append(line)
        if len(self.log) > LOG_KEEP:
            drop = len(self.log) - LOG_KEEP
            del self.log[:drop]
            self.log_base += drop

    # ── What the API shows ────────────────────────────────────────────────────
    def state(self, log_from):
        with self.cond:
            start = max(log_from, self.log_base)
            lines = self.log[start - self.log_base:][:LOG_PAGE]
            return {
                "phase": self.phase,
                "error": self.error,
                "steps": self.steps,
                "needs": self.needs,
                "missing": self.missing,
                "answers": {
                    "domain": self.answers["domain"],
                    "user": self.answers["user"],
                    "password_set": bool(self.answers["password"]),
                },
                "server": {
                    "ip": self.ip,
                    "public": self.public,
                    "sslip": f"{self.ip}.sslip.io" if self.public else None,
                },
                "install": self.info,
                "summary": self.summary,
                "can_pair": self.phase == "done" and bool(self.answers["user"] and self.answers["password"]),
                "now": time.time(),
                "log": {"from": start, "next": start + len(lines), "lines": lines},
            }

    def domain(self, name):
        name = name.strip().lower()
        if not DOMAIN_RE.match(name):
            raise BadRequest("only the host name, for example agent.example.com")
        try:
            found = sorted({item[4][0] for item in socket.getaddrinfo(name, None, socket.AF_INET)})
        except OSError:
            found = []
        return {
            "name": name,
            "addresses": found,
            "server": self.ip,
            # Behind NAT the server cannot know its public address; then nothing is claimed.
            "matches": (self.ip in found) if self.public else None,
        }

    def pair(self):
        with self.cond:
            if self.phase != "done" or not (self.answers["user"] and self.answers["password"]):
                raise BadRequest("the code can be shown only for a password set in this run; later, ./pair.sh")
            payload = json.dumps(
                {"v": 1, "url": self.summary["url"], "user": self.answers["user"], "password": self.answers["password"]},
                separators=(",", ":"),
            )
        rows = [row for row in self._script("pair", stdin=payload).split() if set(row) <= {"0", "1"}]
        if not rows:
            raise RuntimeError("could not draw the code")
        return {"rows": rows}


def make_handler(installer, token, page, cleanup):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "hermes-box-installer"
        sys_version = ""
        timeout = 30

        def log_message(self, *args):
            pass

        def send(self, status, body, content_type="application/json"):
            if not isinstance(body, bytes):
                body = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.end_headers()
            self.wfile.write(body)

        def authorized(self):
            given = self.headers.get("Authorization", "")
            return given.startswith("Bearer ") and hmac.compare_digest(given[7:].encode(), token.encode())

        def body(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY:
                raise BadRequest("the request is too large")
            raw = self.rfile.read(length) if length else b""
            if not raw.strip():
                return {}
            try:
                return json.loads(raw)
            except ValueError:
                raise BadRequest("the body is not JSON") from None

        def handle_api(self, method):
            url = urlsplit(self.path)
            query = parse_qs(url.query)
            route = (method, url.path)
            if route == ("GET", "/api/health"):
                return self.send(200, {"ok": True})
            if not url.path.startswith("/api/"):
                if method == "GET" and url.path in ("/", "/index.html"):
                    with open(page, "rb") as file:
                        content = file.read()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Content-Length", str(len(content)))
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("X-Content-Type-Options", "nosniff")
                    self.send_header("Referrer-Policy", "no-referrer")
                    self.send_header("X-Frame-Options", "DENY")
                    self.send_header(
                        "Content-Security-Policy",
                        "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; "
                        "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
                    )
                    self.end_headers()
                    self.wfile.write(content)
                    return None
                return self.send(404, {"error": "not found"})
            if not self.authorized():
                return self.send(401, {"error": "the token is missing or wrong; use the address get.sh printed"})
            if route == ("GET", "/api/state"):
                try:
                    log_from = int(query.get("log_from", ["0"])[0])
                except ValueError:
                    raise BadRequest("log_from is a line number") from None
                return self.send(200, installer.state(log_from))
            if route == ("GET", "/api/domain"):
                return self.send(200, installer.domain(query.get("name", [""])[0]))
            if route == ("GET", "/api/pair"):
                return self.send(200, installer.pair())
            if route == ("POST", "/api/start"):
                installer.answer(self.body())
                installer.start()
                return self.send(202, installer.state(0))
            if route == ("POST", "/api/answers"):
                installer.answer(self.body())
                return self.send(200, installer.state(0))
            if route == ("POST", "/api/retry"):
                self.body()
                installer.retry()
                return self.send(202, installer.state(0))
            if route == ("POST", "/api/finish"):
                self.body()
                if installer.phase == "running":
                    raise BadRequest("the installation is running; stopping the installer now would break it off")
                self.send(200, {"ok": True})
                threading.Timer(0.5, cleanup).start()
                return None
            return self.send(404, {"error": "not found"})

        def dispatch(self, method):
            try:
                self.handle_api(method)
            except BadRequest as error:
                self.send(400, {"error": str(error)})
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError, socket.timeout):
                self.close_connection = True
            except Exception as error:
                self.send(500, {"error": str(error)})

        def do_GET(self):
            self.dispatch("GET")

        def do_POST(self):
            self.dispatch("POST")

    return Handler


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description="The Hermes Box installer's API.")
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--steps", default=os.path.join(here, "steps.sh"))
    parser.add_argument("--page", default=os.path.join(here, "index.html"))
    parser.add_argument("--linger", type=int, default=3600,
                        help="seconds the installer stays up after the installation is done")
    args = parser.parse_args()

    with open(args.token_file, encoding="ascii") as file:
        token = file.read().strip()
    if len(token) < 32:
        sys.exit("installer: the token is too short")

    installer = Installer(args.steps)

    def cleanup():
        # The certificate and the token were for this run only.
        for path in (args.key, args.cert, args.token_file):
            try:
                os.remove(path)
            except OSError:
                pass
        os._exit(0)

    def linger():
        while True:
            time.sleep(30)
            if installer.finished and time.time() - installer.finished > args.linger:
                cleanup()

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.cert, args.key)
    server = ThreadingHTTPServer((args.bind, args.port), make_handler(installer, token, args.page, cleanup))
    server.daemon_threads = True
    # Port scanners break connections off all the time; that is not worth a traceback.
    server.handle_error = lambda request, client_address: None
    # The handshake happens in the connection's own thread, on its first read:
    # a client that stalls it then holds up nobody else.
    server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    threading.Thread(target=linger, daemon=True).start()
    print(f"installer: listening on {args.bind}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
