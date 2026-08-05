#!/bin/sh

# Codex Stop hook for macOS/Linux. Runtime dependencies: POSIX sh and curl.

plugin_name='codex-task-notifier'
event_file=''

finish() {
    if [ -n "$event_file" ]; then
        rm -f "$event_file"
    fi
    printf '%s\n' '{"continue":true}'
}
trap finish 0

log_delivery() {
    status=$1
    detail=$2
    if [ -z "${PLUGIN_DATA:-}" ]; then
        return
    fi
    umask 077
    if ! mkdir -p "$PLUGIN_DATA" 2>/dev/null; then
        return
    fi
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown')
    printf '{"time":"%s","status":"%s","detail":"%s"}\n' \
        "$timestamp" "$status" "$detail" >> "$PLUGIN_DATA/deliveries.jsonl" 2>/dev/null || true
}

read_url_file() {
    candidate=$1
    if [ -f "$candidate" ]; then
        IFS= read -r configured_url < "$candidate" || true
        if [ -n "$configured_url" ]; then
            printf '%s' "$configured_url"
            return 0
        fi
    fi
    return 1
}

configured_url=${CODEX_NOTIFY_WEBHOOK_URL:-}
if [ -z "$configured_url" ] && [ -n "${CODEX_NOTIFY_URL_FILE:-}" ]; then
    configured_url=$(read_url_file "$CODEX_NOTIFY_URL_FILE") || configured_url=''
fi
if [ -z "$configured_url" ] && [ -n "${PLUGIN_DATA:-}" ]; then
    configured_url=$(read_url_file "$PLUGIN_DATA/webhook.url") || configured_url=''
fi
if [ -z "$configured_url" ]; then
    configured_url=$(read_url_file "$HOME/.codex/$plugin_name.url") || configured_url=''
fi

case "$configured_url" in
    http://*|https://*) ;;
    '')
        log_delivery 'skipped' 'webhook URL is not configured'
        exit 0
        ;;
    *)
        log_delivery 'failed' 'webhook URL must use http or https'
        exit 0
        ;;
esac

if ! command -v curl >/dev/null 2>&1; then
    log_delivery 'failed' 'curl is not available'
    printf '%s\n' 'Codex task notification failed: curl is not available' >&2
    exit 0
fi

temporary_base=${TMPDIR:-/tmp}
event_file=$(mktemp "$temporary_base/codex-task-notifier.XXXXXX" 2>/dev/null) || {
    log_delivery 'failed' 'could not create a temporary event file'
    exit 0
}
chmod 600 "$event_file" 2>/dev/null || true
if ! cat > "$event_file"; then
    log_delivery 'failed' 'could not read hook input'
    exit 0
fi

timeout=${CODEX_NOTIFY_TIMEOUT:-7}
case "$timeout" in
    ''|*[!0-9]*) timeout=7 ;;
esac
if [ "$timeout" -lt 1 ] 2>/dev/null; then timeout=7; fi

attempts=${CODEX_NOTIFY_ATTEMPTS:-2}
case "$attempts" in
    1|2|3) ;;
    *) attempts=2 ;;
esac

attempt=1
last_detail='delivery failed'
while [ "$attempt" -le "$attempts" ]; do
    http_code=$(curl \
        --silent \
        --output /dev/null \
        --write-out '%{http_code}' \
        --request POST \
        --max-time "$timeout" \
        --header 'Content-Type: application/json; charset=utf-8' \
        --header 'Accept: application/json' \
        --header 'X-Codex-Event: codex.task.completed' \
        --header 'X-Codex-Payload: hook-input' \
        --user-agent "$plugin_name/0.1.0" \
        --data-binary "@$event_file" \
        "$configured_url" 2>/dev/null)
    curl_status=$?

    case "$http_code" in
        2??)
            log_delivery 'sent' "HTTP $http_code"
            exit 0
            ;;
    esac
    if [ "$curl_status" -ne 0 ]; then
        last_detail="curl exit $curl_status"
    else
        last_detail="HTTP ${http_code:-unknown}"
    fi
    if [ "$attempt" -lt "$attempts" ]; then
        sleep 1
    fi
    attempt=$((attempt + 1))
done

log_delivery 'failed' "$last_detail"
printf '%s\n' "Codex task notification failed: $last_detail" >&2
exit 0
