#!/bin/sh
set -eu
exec python3 "$(dirname "$0")/codex_hook_agent.py"
