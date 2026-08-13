#!/bin/sh
set -eu

webhook_url=${CODEX_NOTIFY_WEBHOOK_URL:-}
if [ -z "$webhook_url" ]; then
    config_path="$HOME/.codex/codex-task-notifier.url"
    [ -f "$config_path" ] || exit 0
    webhook_url=$(sed -n '1p' "$config_path")
fi

case "$webhook_url" in
    ''|*/private|*/private/) exit 0 ;;
esac

log_directory="$HOME/.codex/logs"
mkdir -p "$log_directory"
nohup sh "$(dirname "$0")/start_agent.sh" </dev/null \
    >>"$log_directory/codex-task-notifier-agent.log" 2>&1 &
exit 0
