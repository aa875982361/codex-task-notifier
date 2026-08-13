#!/usr/bin/env python3
"""Manually-run bridge that resumes Codex jobs assigned to this Hook token."""

from __future__ import annotations

import json
import os
import platform
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

AGENT_VERSION = "0.1.0"


def configured_url() -> str:
    value = os.environ.get("CODEX_NOTIFY_WEBHOOK_URL", "").strip()
    if value:
        return value
    path = Path.home() / ".codex" / "codex-task-notifier.url"
    return path.read_text(encoding="utf-8").strip() if path.is_file() else ""


def agent_base_and_token(webhook_url: str) -> tuple[str, str]:
    parsed = urlparse(webhook_url)
    parts = [part for part in parsed.path.split("/") if part]
    try:
        hook_index = parts.index("hooks")
        if parts[hook_index + 1] != "codex":
            raise ValueError
        token = parts[hook_index + 2]
    except (ValueError, IndexError):
        raise ValueError("Webhook URL does not contain /hooks/codex/<token>") from None
    prefix = "/".join(parts[:hook_index])
    base_path = f"/{prefix}/agent" if prefix else "/agent"
    return f"{parsed.scheme}://{parsed.netloc}{base_path}", token


def request_json(url: str, token: str, payload: dict, timeout: float = 15):
    request = Request(url, data=json.dumps(payload, ensure_ascii=False).encode(), method="POST", headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/json; charset=utf-8",
        "User-Agent": f"codex-hook-agent/{AGENT_VERSION}",
    })
    try:
        with urlopen(request, timeout=timeout) as response:
            body = response.read()
            return response.status, json.loads(body) if body else None
    except HTTPError as error:
        body = error.read()
        detail = json.loads(body) if body else {"error": f"HTTP {error.code}"}
        return error.code, detail


def codex_version() -> str:
    try:
        result = subprocess.run(["codex", "--version"], capture_output=True, text=True, timeout=10, check=False)
        return (result.stdout or result.stderr).strip()[:80]
    except (OSError, subprocess.SubprocessError):
        return "unavailable"


def fail_job(base: str, token: str, job_id: str, code: str, message: str) -> None:
    request_json(f"{base}/jobs/{job_id}/failed", token, {"failure_code": code, "failure_message": message[:500]})


def execute_job(base: str, token: str, job: dict) -> None:
    cwd = Path(str(job.get("cwd") or ""))
    if not cwd.is_dir():
        fail_job(base, token, job["id"], "cwd_not_found", "原任务工作目录不存在")
        return
    output = tempfile.NamedTemporaryFile(prefix="codex-hook-agent-", suffix=".txt", delete=False)
    output.close()
    env = os.environ.copy()
    env["CODEX_REMOTE_RESUME_REQUEST_ID"] = job["id"]
    env["CODEX_REMOTE_SOURCE_TASK_ID"] = job["source_task_id"]
    try:
        result = subprocess.run(
            ["codex", "exec", "resume", job["session_id"], "-", "--output-last-message", output.name],
            input=job["prompt"], text=True, encoding="utf-8", cwd=str(cwd), env=env, check=False,
        )
        if result.returncode != 0:
            fail_job(base, token, job["id"], "codex_failed", f"Codex 退出码：{result.returncode}")
    except FileNotFoundError:
        fail_job(base, token, job["id"], "codex_not_found", "未找到 Codex CLI")
    except OSError as error:
        fail_job(base, token, job["id"], "codex_failed", str(error))
    finally:
        try:
            Path(output.name).unlink(missing_ok=True)
        except OSError:
            pass


def main() -> int:
    try:
        webhook_url = configured_url()
        if not webhook_url:
            raise ValueError("请先配置 codex-task-notifier Webhook URL")
        base, token = agent_base_and_token(webhook_url)
    except (ValueError, OSError) as error:
        print(f"Codex Hook Agent 无法启动：{error}", file=sys.stderr)
        return 1
    metadata = {"platform": "windows" if os.name == "nt" else "macos" if sys.platform == "darwin" else platform.system().lower(), "agent_version": AGENT_VERSION, "codex_version": codex_version()}
    print("Codex Hook Agent 已启动。关闭此窗口即可停止远程操作。")
    while True:
        try:
            status, detail = request_json(f"{base}/heartbeat", token, metadata)
            if status == 403:
                print("此配置未启用远程操作，Agent 已停止。", file=sys.stderr)
                return 2
            if status >= 400:
                raise RuntimeError(detail)
            status, detail = request_json(f"{base}/jobs/claim", token, metadata)
            if status == 200 and detail and detail.get("job"):
                print(f"正在执行请求 {detail['job']['id']}…")
                execute_job(base, token, detail["job"])
            time.sleep(5)
        except KeyboardInterrupt:
            print("\nCodex Hook Agent 已停止。")
            return 0
        except (URLError, OSError, RuntimeError) as error:
            print(f"连接失败：{error}", file=sys.stderr)
            time.sleep(10)


if __name__ == "__main__":
    raise SystemExit(main())
