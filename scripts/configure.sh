#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
    printf '%s\n' "Usage: sh scripts/configure.sh <webhook-url>" >&2
    exit 2
fi

case "$1" in
    http://*|https://*) ;;
    *)
        printf '%s\n' "Webhook URL must be an absolute http:// or https:// URL" >&2
        exit 2
        ;;
esac

umask 077
config_directory=$HOME/.codex
config_path=$config_directory/codex-task-notifier.url
mkdir -p "$config_directory"
printf '%s\n' "$1" > "$config_path"
chmod 600 "$config_path"
printf 'Webhook URL saved to %s\n' "$config_path"
