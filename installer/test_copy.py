import json
import tempfile
import threading
import time
import unittest
from http.client import HTTPConnection
from pathlib import Path
from unittest.mock import patch

from server import BoundedServer, Installer, make_handler


class InstallerCopyTest(unittest.TestCase):
    def setUp(self):
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        steps = directory / "steps.sh"
        steps.write_text(
            'case "$1" in\n'
            '  needs) printf "%s\\n" "existing 1" ;;\n'
            '  summary) printf "%s\\n" "url=https://assistant.example.com" "model=yes" ;;\n'
            'esac\n',
            encoding="utf-8",
        )
        with patch("server.server_address", return_value=(None, False)):
            installer = Installer(str(steps))
        page = Path(__file__).with_name("index.html")
        handler = make_handler(installer, "fixture-token", page, lambda: None)
        self.server = self.enterContext(BoundedServer(("127.0.0.1", 0), handler))
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(self.server.shutdown)

    def request(self, method, path, *, signed_in=False):
        connection = HTTPConnection(*self.server.server_address, timeout=3)
        try:
            headers = {"Authorization": "Bearer fixture-token"} if signed_in else {}
            connection.request(method, path, headers=headers)
            response = connection.getresponse()
            return response.status, response.read().decode("utf-8")
        finally:
            connection.close()

    def test_page_uses_product_copy_for_existing_and_completed_installs(self):
        status, html = self.request("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn('data-t="ready.title"', html)
        self.assertIn('data-t="done.open"', html)
        for heading, action in [
            ("HobCrew Box už je nainstalovaný", "Otevřít webové rozhraní"),
            ("HobCrew Box is already installed", "Open the web interface"),
        ]:
            self.assertIn(f'"ready.title": "{heading}"', html)
            self.assertIn(f'"done.open": "{action}"', html)

    def test_existing_installation_can_still_open_the_configured_web_interface(self):
        self.assertEqual(self.request("GET", "/api/state")[0], 401)
        status, body = self.request("GET", "/api/state", signed_in=True)
        self.assertEqual(status, 200)
        state = json.loads(body)
        self.assertEqual(state["install"]["existing"], "1")
        self.assertEqual(state["missing"], [])
        self.assertEqual(self.request("POST", "/api/start", signed_in=True)[0], 202)

        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            status, body = self.request("GET", "/api/state", signed_in=True)
            self.assertEqual(status, 200)
            state = json.loads(body)
            self.assertNotEqual(state["phase"], "failed", state["error"])
            if state["phase"] == "done":
                self.assertEqual(state["summary"]["url"], "https://assistant.example.com")
                return
            time.sleep(0.025)
        self.fail("Installer did not finish the test steps")
