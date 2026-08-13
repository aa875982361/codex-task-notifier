import json
import os
import subprocess
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
import codex_hook_agent


class WebhookNotifyTests(unittest.TestCase):
    def test_posix_hook_has_no_language_runtime_dependency(self):
        plugin_root = Path(__file__).resolve().parents[1]
        hooks = json.loads(
            (plugin_root / "hooks" / "hooks.json").read_text(encoding="utf-8")
        )
        command = hooks["hooks"]["Stop"][0]["hooks"][0]["command"]
        activity_command = hooks["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"]

        self.assertEqual(command, 'sh "$PLUGIN_ROOT/scripts/webhook_notify.sh"')
        self.assertEqual(activity_command, command)
        self.assertNotIn("python", command.lower())
        self.assertNotIn("node", command.lower())
        self.assertNotIn("jq", command.lower())

    def test_posix_hook_forwards_original_json_with_curl(self):
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
        event = {
            "hook_event_name": "Stop",
            "stop_hook_active": False,
            "session_id": "session-shell",
            "turn_id": "turn-shell",
            "cwd": "/workspace/demo",
            "last_assistant_message": '完成，包含"引号"和\n换行。',
        }
        plugin_root = Path(__file__).resolve().parents[1]
        try:
            with TemporaryDirectory() as directory:
                environment = {
                    **os.environ,
                    "PLUGIN_DATA": directory,
                    "CODEX_NOTIFY_WEBHOOK_URL": (
                        f"http://127.0.0.1:{server.server_port}/notify"
                    ),
                }
                result = subprocess.run(
                    ["sh", str(plugin_root / "scripts" / "webhook_notify.sh")],
                    input=json.dumps(event, ensure_ascii=False),
                    text=True,
                    capture_output=True,
                    env=environment,
                    check=True,
                )
        finally:
            thread.join(timeout=2)
            server.server_close()

        self.assertEqual(json.loads(result.stdout), {"continue": True})
        self.assertEqual(received["payload"], event)
        self.assertEqual(received["headers"]["X-Codex-Payload"], "hook-input")

    def test_posix_hook_forwards_remote_resume_linkage_headers(self):
        received = {}

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                received["resume"] = self.headers.get("X-Codex-Resume-Request-Id")
                received["source"] = self.headers.get("X-Codex-Source-Task-Id")
                self.rfile.read(int(self.headers["Content-Length"]))
                self.send_response(204)
                self.end_headers()

            def log_message(self, format, *args):
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.handle_request)
        thread.start()
        plugin_root = Path(__file__).resolve().parents[1]
        try:
            subprocess.run(
                ["sh", str(plugin_root / "scripts" / "webhook_notify.sh")],
                input=json.dumps({"hook_event_name": "Stop", "session_id": "session"}),
                text=True, capture_output=True, check=True,
                env={**os.environ, "CODEX_NOTIFY_WEBHOOK_URL": f"http://127.0.0.1:{server.server_port}/notify", "CODEX_REMOTE_RESUME_REQUEST_ID": "resume-1", "CODEX_REMOTE_SOURCE_TASK_ID": "task-1"},
            )
        finally:
            thread.join(timeout=2)
            server.server_close()
        self.assertEqual(received, {"resume": "resume-1", "source": "task-1"})

    def test_posix_privacy_hook_never_transmits_task_content(self):
        received = {}

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers["Content-Length"])
                received["headers"] = self.headers
                received["body"] = self.rfile.read(length)
                self.send_response(204)
                self.end_headers()

            def log_message(self, format, *args):
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.handle_request)
        thread.start()
        sensitive = "TOP-SECRET-TASK-CONTENT"
        event = {
            "hook_event_name": "Stop",
            "stop_hook_active": False,
            "session_id": "session-private",
            "turn_id": f"turn-{sensitive}",
            "model": f"model-{sensitive}",
            "cwd": f"/workspace/{sensitive}",
            "last_assistant_message": sensitive,
        }
        plugin_root = Path(__file__).resolve().parents[1]
        try:
            with TemporaryDirectory() as directory:
                result = subprocess.run(
                    ["sh", str(plugin_root / "scripts" / "webhook_notify.sh")],
                    input=json.dumps(event),
                    text=True,
                    capture_output=True,
                    env={
                        **os.environ,
                        "PLUGIN_DATA": directory,
                        "CODEX_NOTIFY_WEBHOOK_URL": (
                            f"http://127.0.0.1:{server.server_port}/notify/private"
                        ),
                    },
                    check=True,
                )
        finally:
            thread.join(timeout=2)
            server.server_close()

        self.assertEqual(json.loads(result.stdout), {"continue": True})
        self.assertEqual(received["headers"]["X-Codex-Payload"], "privacy-minimal")
        self.assertNotIn(sensitive.encode(), received["body"])
        payload = json.loads(received["body"])
        self.assertEqual(
            set(payload),
            {"schema_version", "event", "privacy_mode", "session_id", "delivery_id", "occurred_at"},
        )
        self.assertTrue(payload["privacy_mode"])
        self.assertEqual(payload["session_id"], "session-private")
        self.assertTrue(payload["delivery_id"])

    def test_posix_user_prompt_uploads_only_session_activity(self):
        received = {}

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers["Content-Length"])
                received["headers"] = self.headers
                received["body"] = self.rfile.read(length)
                self.send_response(204)
                self.end_headers()

            def log_message(self, format, *args):
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.handle_request)
        thread.start()
        sensitive_prompt = '不要上传这个 prompt，包含 "session_id":"fake-session"'
        event = {
            "hook_event_name": "UserPromptSubmit",
            "session_id": "session-active",
            "turn_id": "turn-new",
            "prompt": sensitive_prompt,
        }
        plugin_root = Path(__file__).resolve().parents[1]
        try:
            with TemporaryDirectory() as directory:
                result = subprocess.run(
                    ["sh", str(plugin_root / "scripts" / "webhook_notify.sh")],
                    input=json.dumps(event, ensure_ascii=False),
                    text=True,
                    capture_output=True,
                    env={
                        **os.environ,
                        "PLUGIN_DATA": directory,
                        "CODEX_NOTIFY_WEBHOOK_URL": (
                            f"http://127.0.0.1:{server.server_port}/notify/private"
                        ),
                    },
                    check=True,
                )
        finally:
            thread.join(timeout=2)
            server.server_close()

        self.assertEqual(json.loads(result.stdout), {"continue": True})
        self.assertNotIn(sensitive_prompt.encode(), received["body"])
        self.assertEqual(
            json.loads(received["body"]),
            {
                "schema_version": "1",
                "event": "codex.session.active",
                "session_id": "session-active",
            },
        )
        self.assertEqual(received["headers"]["X-Codex-Payload"], "activity-minimal")

    def test_posix_hook_fails_open_when_curl_is_missing(self):
        plugin_root = Path(__file__).resolve().parents[1]
        environment = {
            "PATH": "",
            "CODEX_NOTIFY_WEBHOOK_URL": "https://notify.example.test/hook/token",
        }
        result = subprocess.run(
            ["/bin/sh", str(plugin_root / "scripts" / "webhook_notify.sh")],
            input='{"hook_event_name":"Stop"}',
            text=True,
            capture_output=True,
            env=environment,
            check=True,
        )

        self.assertEqual(json.loads(result.stdout), {"continue": True})
        self.assertIn("curl is not available", result.stderr)

    def test_posix_privacy_hook_ignores_recursive_stop(self):
        plugin_root = Path(__file__).resolve().parents[1]
        result = subprocess.run(
            ["sh", str(plugin_root / "scripts" / "webhook_notify.sh")],
            input=json.dumps({"hook_event_name": "Stop", "stop_hook_active": True}),
            text=True,
            capture_output=True,
            env={
                **os.environ,
                "CODEX_NOTIFY_WEBHOOK_URL": "http://127.0.0.1:9/hook/private",
                "CODEX_NOTIFY_ATTEMPTS": "1",
            },
            check=True,
        )
        self.assertEqual(json.loads(result.stdout), {"continue": True})
        self.assertEqual(result.stderr, "")

    def test_windows_hook_has_no_python_runtime_dependency(self):
        plugin_root = Path(__file__).resolve().parents[1]
        hooks = json.loads(
            (plugin_root / "hooks" / "hooks.json").read_text(encoding="utf-8")
        )
        handler = hooks["hooks"]["Stop"][0]["hooks"][0]
        activity_handler = hooks["hooks"]["UserPromptSubmit"][0]["hooks"][0]
        windows_command = handler["commandWindows"]

        self.assertIn("powershell.exe", windows_command)
        self.assertIn(
            "-Command \"& (Join-Path $env:PLUGIN_ROOT 'scripts\\webhook_notify.ps1')\"",
            windows_command,
        )
        self.assertNotIn("%PLUGIN_ROOT%", windows_command)
        self.assertNotIn("python", windows_command.lower())
        self.assertEqual(activity_handler["commandWindows"], windows_command)
        self.assertTrue((plugin_root / "scripts" / "webhook_notify.ps1").is_file())

        powershell = (plugin_root / "scripts" / "webhook_notify.ps1").read_text(
            encoding="utf-8"
        )
        for required_contract in (
            '@("Stop", "UserPromptSubmit")',
            "stop_hook_active",
            '"X-Codex-Event" = $eventHeader',
            '"X-Codex-Payload" = $payloadType',
            'event = "codex.session.active"',
            'session_id = [string] $eventData.session_id',
            "[Console]::OpenStandardInput()",
            "New-Object Text.UTF8Encoding($false, $true)",
            "GetBytes($payloadText)",
            "[Net.SecurityProtocolType]::Tls12",
            'Write-HookResult',
            'Write-DeliveryLog "sent"',
            'EndsWith(\'/private\'',
            '"privacy-minimal"',
            "[Guid]::NewGuid()",
        ):
            self.assertIn(required_contract, powershell)

        self.assertNotIn("[Console]::In.ReadToEnd()", powershell)

    def test_windows_agent_supports_codex_wrappers_and_stops_when_disabled(self):
        plugin_root = Path(__file__).resolve().parents[1]
        agent_path = plugin_root / "scripts" / "start_agent.ps1"
        agent_bytes = agent_path.read_bytes()

        # Windows PowerShell 5.1 decodes BOM-less scripts with the active ANSI
        # code page. Keeping this entry point ASCII makes -File reliable on all
        # Windows locales and does not depend on a BOM surviving packaging.
        self.assertTrue(agent_bytes.isascii())
        agent = agent_bytes.decode("ascii")
        self.assertIn('@(".cmd", ".bat")', agent)
        self.assertIn('$extension -eq ".ps1"', agent)
        self.assertNotIn("$start.StandardInputEncoding", agent)
        self.assertIn("Text.UTF8Encoding($false)", agent)
        self.assertIn("$process.StandardInput.BaseStream", agent)
        self.assertIn("$inputStream.Write($promptBytes, 0, $promptBytes.Length)", agent)
        self.assertIn('RemoteControlDisabled', agent)
        self.assertIn('break', agent)

    def test_session_start_hook_launches_single_instance_agent(self):
        plugin_root = Path(__file__).resolve().parents[1]
        hooks = json.loads(
            (plugin_root / "hooks" / "hooks.json").read_text(encoding="utf-8")
        )
        handler_group = hooks["hooks"]["SessionStart"][0]
        handler = handler_group["hooks"][0]

        self.assertEqual(handler_group["matcher"], "^(startup|resume)$")
        self.assertIn("ensure_agent.sh", handler["command"])
        self.assertIn("ensure_agent.ps1", handler["commandWindows"])
        self.assertIn("Join-Path $env:PLUGIN_ROOT", handler["commandWindows"])
        self.assertNotIn("%PLUGIN_ROOT%", handler["commandWindows"])
        self.assertNotIn("start_agent", handler["command"])
        self.assertNotIn("start_agent", handler["commandWindows"])
        self.assertLessEqual(handler["timeout"], 5)

        windows_launcher = (
            plugin_root / "scripts" / "ensure_agent.ps1"
        ).read_bytes()
        self.assertTrue(windows_launcher.isascii())
        self.assertIn(
            "ProcessWindowStyle]::Hidden", windows_launcher.decode("ascii")
        )
        self.assertIn(
            "codex-task-notifier-agent.log", windows_launcher.decode("ascii")
        )

    @unittest.skipIf(os.name == "nt", "POSIX lock implementation")
    def test_posix_agent_allows_only_one_instance(self):
        with TemporaryDirectory() as directory, patch.dict(
            os.environ, {"HOME": directory}
        ):
            first_lock = codex_hook_agent.acquire_single_instance_lock()
            self.assertIsNotNone(first_lock)
            try:
                self.assertIsNone(codex_hook_agent.acquire_single_instance_lock())
            finally:
                first_lock.close()

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

    def test_python_privacy_payload_is_minimal(self):
        self.assertTrue(webhook_notify.is_privacy_url("https://example.test/hook/private"))
        self.assertFalse(webhook_notify.is_privacy_url("https://example.test/hook/token"))
        payload = webhook_notify.make_privacy_payload("session-private")
        self.assertEqual(
            set(payload),
            {"schema_version", "event", "privacy_mode", "session_id", "delivery_id", "occurred_at"},
        )
        self.assertTrue(payload["privacy_mode"])
        self.assertEqual(payload["session_id"], "session-private")

    def test_python_activity_payload_excludes_prompt(self):
        payload = webhook_notify.make_activity_payload("session-active")
        self.assertEqual(
            payload,
            {
                "schema_version": "1",
                "event": "codex.session.active",
                "session_id": "session-active",
            },
        )

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
