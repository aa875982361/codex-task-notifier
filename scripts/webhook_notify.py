#!/usr/bin/env python3
"""Codex Stop hook that forwards the final task result to one webhook URL."""

from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Mapping
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


PLUGIN_NAME = "codex-task-notifier"
SCHEMA_VERSION = "1"
DEFAULT_URL_FILE = Path.home() / ".codex" / f"{PLUGIN_NAME}.url"


def hook_result() -> None:
    json.dump({"continue": True}, sys.stdout)
    sys.stdout.write("\n")


def configured_url() -> str:
    """Resolve the URL from one environment value or one single-line file."""
    environment_url = os.environ.get("CODEX_NOTIFY_WEBHOOK_URL", "").strip()
    if environment_url:
        return validate_url(environment_url)

    candidates = []
    explicit_path = os.environ.get("CODEX_NOTIFY_URL_FILE", "").strip()
    if explicit_path:
        candidates.append(Path(explicit_path).expanduser())

    plugin_data = os.environ.get("PLUGIN_DATA", "").strip()
    if plugin_data:
        candidates.append(Path(plugin_data) / "webhook.url")

    candidates.append(DEFAULT_URL_FILE)
    for path in candidates:
        if path.is_file():
            value = path.read_text(encoding="utf-8").strip()
            if value:
                return validate_url(value)
    return ""


def validate_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("webhook URL must be an absolute http:// or https:// URL")
    return value


def make_payload(event: Mapping[str, Any]) -> dict[str, Any]:
    cwd = str(event.get("cwd") or "")
    return {
        "schema_version": SCHEMA_VERSION,
        "event": "codex.task.completed",
        "occurred_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "task": {
            "session_id": event.get("session_id"),
            "turn_id": event.get("turn_id"),
            "model": event.get("model"),
            "project": Path(cwd).name if cwd else None,
            "cwd": cwd or None,
            "result": event.get("last_assistant_message"),
        },
    }


def post_json(url: str, payload: Mapping[str, Any], timeout: float = 7) -> int:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = Request(
        url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "Accept": "application/json",
            "User-Agent": f"{PLUGIN_NAME}/0.1.0",
            "X-Codex-Event": "codex.task.completed",
        },
    )
    with urlopen(request, timeout=timeout) as response:
        status = int(response.status)
        response.read(1024)
    if status < 200 or status >= 300:
        raise RuntimeError(f"webhook returned HTTP {status}")
    return status


def log_delivery(status: str, event: Mapping[str, Any], detail: str = "") -> None:
    plugin_data = os.environ.get("PLUGIN_DATA", "").strip()
    if not plugin_data:
        return
    try:
        directory = Path(plugin_data)
        directory.mkdir(parents=True, exist_ok=True)
        record = {
            "time": datetime.now().astimezone().isoformat(timespec="seconds"),
            "status": status,
            "session_id": event.get("session_id"),
            "turn_id": event.get("turn_id"),
            "detail": detail[:300],
        }
        with (directory / "deliveries.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass


def main() -> int:
    event: Mapping[str, Any] = {}
    try:
        event = json.load(sys.stdin)
        if event.get("hook_event_name") != "Stop" or event.get("stop_hook_active"):
            return 0

        url = configured_url()
        if not url:
            log_delivery("skipped", event, "webhook URL is not configured")
            return 0

        payload = make_payload(event)
        timeout = float(os.environ.get("CODEX_NOTIFY_TIMEOUT", "7"))
        attempts = max(1, min(3, int(os.environ.get("CODEX_NOTIFY_ATTEMPTS", "2"))))
        last_error: Exception | None = None
        for attempt in range(attempts):
            try:
                status = post_json(url, payload, timeout=timeout)
                log_delivery("sent", event, f"HTTP {status}")
                return 0
            except (HTTPError, URLError, OSError, RuntimeError) as exc:
                last_error = exc
                if attempt + 1 < attempts:
                    time.sleep(0.5)
        raise RuntimeError(f"delivery failed after {attempts} attempt(s): {last_error}")
    except Exception as exc:
        log_delivery("failed", event, str(exc))
        print(f"Codex task notification failed: {exc}", file=sys.stderr)
    finally:
        hook_result()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
