#!/usr/bin/env python3
"""Configure the plugin by saving one webhook URL."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
from urllib.parse import urlparse


DEFAULT_URL_FILE = Path.home() / ".codex" / "codex-task-notifier.url"


def validate_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise argparse.ArgumentTypeError(
            "URL must be an absolute http:// or https:// URL"
        )
    return value


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Save the single webhook URL used by Codex Task Notifier."
    )
    parser.add_argument("url", type=validate_url)
    parser.add_argument(
        "--file",
        type=Path,
        default=DEFAULT_URL_FILE,
        help=argparse.SUPPRESS,
    )
    args = parser.parse_args()

    destination = args.file.expanduser()
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(args.url.strip() + "\n", encoding="utf-8")
    os.chmod(destination, 0o600)
    print(f"Webhook URL saved to {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
