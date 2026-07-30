import json
import os
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

import webhook_notify


class WebhookNotifyTests(unittest.TestCase):
    def test_reads_single_url_file(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "webhook.url"
            path.write_text("https://notify.example.test/codex/token\n", encoding="utf-8")
            with patch.dict(
                os.environ,
                {"CODEX_NOTIFY_URL_FILE": str(path)},
                clear=True,
            ):
                self.assertEqual(
                    webhook_notify.configured_url(),
                    "https://notify.example.test/codex/token",
                )

    def test_rejects_non_http_url(self):
        with self.assertRaises(ValueError):
            webhook_notify.validate_url("file:///tmp/result")

    def test_payload_contains_final_result(self):
        payload = webhook_notify.make_payload(
            {
                "session_id": "session-1",
                "turn_id": "turn-1",
                "model": "gpt-test",
                "cwd": "/workspace/demo",
                "last_assistant_message": "任务完成。",
            }
        )
        self.assertEqual(payload["event"], "codex.task.completed")
        self.assertEqual(payload["task"]["project"], "demo")
        self.assertEqual(payload["task"]["result"], "任务完成。")
        json.dumps(payload)

    def test_posts_json_to_server(self):
        received = {}

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers["Content-Length"])
                received["headers"] = self.headers
                received["payload"] = json.loads(self.rfile.read(length))
                self.send_response(204)
                self.end_headers()

            def log_message(self, format, *args):
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.handle_request)
        thread.start()
        try:
            status = webhook_notify.post_json(
                f"http://127.0.0.1:{server.server_port}/notify",
                {"event": "codex.task.completed"},
            )
        finally:
            thread.join(timeout=2)
            server.server_close()

        self.assertEqual(status, 204)
        self.assertEqual(received["payload"]["event"], "codex.task.completed")
        self.assertEqual(
            received["headers"]["X-Codex-Event"], "codex.task.completed"
        )


if __name__ == "__main__":
    unittest.main()
