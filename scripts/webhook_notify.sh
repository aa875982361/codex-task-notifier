#!/bin/sh

# Codex notification hooks for macOS/Linux. Runtime dependencies: POSIX sh and curl.

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

privacy_mode=false
case "$configured_url" in
    */private|*/private\?*) privacy_mode=true ;;
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

event_name=''
if grep -Eq '(^|[,{[:space:]])"hook_event_name"[[:space:]]*:[[:space:]]*"UserPromptSubmit"' "$event_file"; then
    event_name='UserPromptSubmit'
elif grep -Eq '(^|[,{[:space:]])"hook_event_name"[[:space:]]*:[[:space:]]*"Stop"' "$event_file"; then
    event_name='Stop'
else
    exit 0
fi

# Ignore recursive Stop events without transmitting the original JSON.
if [ "$event_name" = 'Stop' ] && grep -Eq '(^|[,{[:space:]])"stop_hook_active"[[:space:]]*:[[:space:]]*true' "$event_file"; then
    exit 0
fi

session_id=$(sed -n 's/.*[,{][[:space:]]*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9._:-]*\)".*/\1/p' "$event_file" | sed -n '1p')

payload_type='hook-input'
event_header='codex.task.completed'
if [ "$event_name" = 'UserPromptSubmit' ]; then
    if [ -z "$session_id" ]; then
        log_delivery 'skipped' 'UserPromptSubmit did not include a valid session ID'
        exit 0
    fi
    if ! printf '{"schema_version":"1","event":"codex.session.active","session_id":"%s"}\n' \
        "$session_id" > "$event_file"; then
        log_delivery 'failed' 'could not create session activity payload'
        exit 0
    fi
    payload_type='activity-minimal'
    event_header='codex.session.active'
elif [ "$privacy_mode" = true ]; then
    occurred_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '1970-01-01T00:00:00Z')
    delivery_id="$(date -u '+%s' 2>/dev/null || printf '0')-$$-${event_file##*.}"
    if ! printf '{"schema_version":"1","event":"codex.task.completed","privacy_mode":true,"session_id":"%s","delivery_id":"%s","occurred_at":"%s"}\n' \
        "$session_id" "$delivery_id" "$occurred_at" > "$event_file"; then
        log_delivery 'failed' 'could not create privacy payload'
        exit 0
    fi
    payload_type='privacy-minimal'
fi

default_timeout=7
default_attempts=2
if [ "$event_name" = 'UserPromptSubmit' ]; then
    default_timeout=2
    default_attempts=1
fi

timeout=${CODEX_NOTIFY_TIMEOUT:-$default_timeout}
case "$timeout" in
    ''|*[!0-9]*) timeout=$default_timeout ;;
esac
if [ "$timeout" -lt 1 ] 2>/dev/null; then timeout=$default_timeout; fi

attempts=${CODEX_NOTIFY_ATTEMPTS:-$default_attempts}
case "$attempts" in
    1|2|3) ;;
    *) attempts=$default_attempts ;;
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
        --header "X-Codex-Event: $event_header" \
        --header "X-Codex-Payload: $payload_type" \
        --header "X-Codex-Resume-Request-Id: ${CODEX_REMOTE_RESUME_REQUEST_ID:-}" \
        --header "X-Codex-Source-Task-Id: ${CODEX_REMOTE_SOURCE_TASK_ID:-}" \
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
