#!/bin/bash

###############################################################################
# Docker Service Watchdog
#
# Stateful health and availability monitoring for this personal Unraid Docker
# stack. Automatic restarts are opt-in, require consecutive failures, respect a
# per-container maintenance marker, and never restart stopped containers unless
# explicitly enabled.
###############################################################################

set -uo pipefail
umask 077

readonly SCRIPT_VERSION="1.0"

###############################################################################
# CONFIGURATION
###############################################################################

# container|optional HTTP endpoint|restart allowed (0/1)
SERVICE_SPECS=(
    "plex-media-server||0"
    "plex-media||0"
    "sonarr|http://192.168.50.4:8989/ping|0"
    "radarr|http://192.168.50.4:7878/ping|0"
    "sabnzbd|http://192.168.50.4:8080/|0"
    "qbittorrent||0"
    "kometa||0"
    "recyclarr||0"
)

HTTP_CONNECT_TIMEOUT=4
HTTP_MAX_TIME=10

CHECK_LOG_SIZE=true
LOG_SIZE_WARNING_BYTES=$((1024 * 1024 * 1024))

AUTO_RESTART=false
RESTART_STOPPED_CONTAINERS=false
CONSECUTIVE_FAILURES_BEFORE_RESTART=3
RESTART_COOLDOWN_SECONDS=$((6 * 60 * 60))
POST_RESTART_WAIT_SECONDS=10

# Create STATE_DIR/maintenance/<container> to suppress restart actions.
STATE_DIR="/mnt/vault/cloud/logs/docker_service_watchdog"
STATE_FILE="${STATE_DIR}/state.json"
MAINTENANCE_DIR="${STATE_DIR}/maintenance"
LOG_FILE="${STATE_DIR}/docker-service-watchdog.log"
LOG_MAX_BYTES=$((5 * 1024 * 1024))

STATUS_DIR="/mnt/vault/cloud/logs/user_scripts_status"
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
NOTIFY_COOLDOWN_HOURS=6
LOCK_FILE="/run/docker_service_watchdog.lock"

###############################################################################
# RUNTIME
###############################################################################

START_EPOCH="$(date +%s)"
RESULT_STATUS="FAILED"
RESULT_SUMMARY="Docker watchdog exited before completion"
RECEIPT_WRITTEN=0

STATE_WORK=""
TMP_DIR=""

SERVICES_CHECKED=0
SERVICES_HEALTHY=0
WARNING_COUNT=0
CRITICAL_COUNT=0
RESTART_ACTIONS=0

FINDINGS=()
CURRENT_SIGNATURE=""

###############################################################################
# HELPERS
###############################################################################

log() {
    local level="$1"
    shift
    local line
    printf -v line '%s [%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
    printf '%s\n' "$line"
    [[ -d "$STATE_DIR" ]] && printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}

rotate_log() {
    local size
    [[ -f "$LOG_FILE" ]] || return 0
    size="$(stat -c '%s' "$LOG_FILE" 2>/dev/null || printf 0)"
    (( size < LOG_MAX_BYTES )) || {
        mv -f -- "$LOG_FILE" "${LOG_FILE}.1"
        : >"$LOG_FILE"
    }
}

notify_unraid() {
    local importance="$1" description="$2" message="$3"
    [[ -x "$NOTIFY_BIN" ]] || return 1
    "$NOTIFY_BIN" -i "$importance" -s "Docker Service Watchdog" \
        -d "$description" -m "$message" >/dev/null 2>&1
}

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " ")
        i=1
        while (b >= 1024 && i < 5) { b/=1024; i++ }
        printf "%.2f %s", b, u[i]
    }'
}

write_receipt() {
    local status="$1" summary="$2" now tmp
    now="$(date +%s)"
    mkdir -p -- "$STATUS_DIR" 2>/dev/null || return 0
    tmp="$(mktemp "${STATUS_DIR}/.docker_service_watchdog.XXXXXX")" || return 0
    if jq -n \
        --arg name "docker_service_watchdog" \
        --arg status "$status" \
        --arg summary "$summary" \
        --arg log "$LOG_FILE" \
        --argjson epoch "$now" \
        --argjson duration "$((now - START_EPOCH))" \
        '{name:$name,status:$status,summary:$summary,log:$log,epoch:$epoch,duration_seconds:$duration}' \
        >"$tmp"
    then
        mv -f -- "$tmp" "${STATUS_DIR}/docker_service_watchdog.json"
        RECEIPT_WRITTEN=1
    else
        rm -f -- "$tmp"
    fi
}

cleanup() {
    local rc=$?
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"
    if (( RECEIPT_WRITTEN == 0 )); then
        write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
    fi
    trap - EXIT
    exit "$rc"
}
trap cleanup EXIT

add_finding() {
    local severity="$1"
    shift
    FINDINGS+=("$severity|$*")
    case "$severity" in
        CRITICAL) CRITICAL_COUNT=$((CRITICAL_COUNT + 1)) ;;
        WARNING) WARNING_COUNT=$((WARNING_COUNT + 1)) ;;
    esac
}

state_value() {
    local name="$1" field="$2" default="$3"
    jq -r --arg name "$name" --arg field "$field" --arg default "$default" '
        .services[$name][$field] // $default
    ' "$STATE_WORK"
}

state_set_service() {
    local name="$1" failures="$2" restart_count="$3" last_restart="$4"
    local status="$5" reason="$6" next
    next="$(mktemp "${TMP_DIR}/state.XXXXXX")" || return 1
    if jq \
        --arg name "$name" \
        --arg status "$status" \
        --arg reason "$reason" \
        --argjson failures "$failures" \
        --argjson restart_count "$restart_count" \
        --argjson last_restart "$last_restart" \
        --argjson checked "$(date +%s)" '
        .services //= {}
        | .services[$name] = {
            consecutive_failures:$failures,
            restart_count:$restart_count,
            last_restart_epoch:$last_restart,
            last_status:$status,
            last_reason:$reason,
            checked_epoch:$checked
          }
    ' "$STATE_WORK" >"$next"
    then
        mv -f -- "$next" "$STATE_WORK"
    else
        rm -f -- "$next"
        return 1
    fi
}

endpoint_healthy() {
    local url="$1" code
    [[ -n "$url" ]] || return 0
    code="$(curl --silent --show-error --output /dev/null \
        --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
        --max-time "$HTTP_MAX_TIME" \
        --write-out '%{http_code}' "$url" 2>/dev/null)" || return 1
    [[ "$code" =~ ^[23][0-9][0-9]$ || "$code" == 401 || "$code" == 403 ]]
}

###############################################################################
# SERVICE CHECK
###############################################################################

check_service() {
    local spec="$1" name url restart_allowed
    local inspect status health oom restart_count log_path log_size
    local previous_failures previous_restart previous_action_epoch
    local failures=0 reason="" service_status="OK"
    local can_restart=0

    IFS='|' read -r name url restart_allowed <<<"$spec"
    SERVICES_CHECKED=$((SERVICES_CHECKED + 1))

    inspect="$(docker inspect "$name" 2>/dev/null)" || {
        previous_failures="$(state_value "$name" consecutive_failures 0)"
        failures=$((previous_failures + 1))
        reason="container not found"
        add_finding CRITICAL "$name: $reason"
        state_set_service "$name" "$failures" 0 0 "CRITICAL" "$reason"
        log ERROR "$name: $reason"
        return
    }

    status="$(jq -r '.[0].State.Status // "unknown"' <<<"$inspect")"
    health="$(jq -r '.[0].State.Health.Status // "none"' <<<"$inspect")"
    oom="$(jq -r '.[0].State.OOMKilled // false' <<<"$inspect")"
    restart_count="$(jq -r '.[0].RestartCount // 0' <<<"$inspect")"
    log_path="$(jq -r '.[0].LogPath // empty' <<<"$inspect")"

    previous_failures="$(state_value "$name" consecutive_failures 0)"
    previous_restart="$(state_value "$name" restart_count "$restart_count")"
    previous_action_epoch="$(state_value "$name" last_restart_epoch 0)"

    if [[ "$status" != "running" ]]; then
        service_status="CRITICAL"
        reason="container state=$status"
    elif [[ "$health" == "unhealthy" ]]; then
        service_status="CRITICAL"
        reason="Docker health=unhealthy"
    elif [[ "$oom" == "true" ]]; then
        service_status="CRITICAL"
        reason="OOMKilled=true"
    elif ! endpoint_healthy "$url"; then
        service_status="CRITICAL"
        reason="endpoint unavailable: $url"
    fi

    if [[ "$service_status" == "CRITICAL" ]]; then
        failures=$((previous_failures + 1))
        add_finding CRITICAL "$name: $reason (failure ${failures}/${CONSECUTIVE_FAILURES_BEFORE_RESTART})"
        log ERROR "$name: $reason"
    else
        failures=0
        SERVICES_HEALTHY=$((SERVICES_HEALTHY + 1))
        log INFO "$name: running, health=$health"
    fi

    if [[ "$restart_count" =~ ^[0-9]+$ &&
          "$previous_restart" =~ ^[0-9]+$ &&
          "$restart_count" -gt "$previous_restart" ]]; then
        add_finding WARNING "$name: restart count increased from $previous_restart to $restart_count"
    fi

    if [[ "$CHECK_LOG_SIZE" == true && -n "$log_path" && -f "$log_path" ]]; then
        log_size="$(stat -c '%s' "$log_path" 2>/dev/null || printf 0)"
        if (( log_size >= LOG_SIZE_WARNING_BYTES )); then
            add_finding WARNING "$name: Docker log is $(human_bytes "$log_size")"
        fi
    fi

    if [[ "$AUTO_RESTART" == true &&
          "$restart_allowed" == 1 &&
          "$service_status" == "CRITICAL" &&
          "$failures" -ge "$CONSECUTIVE_FAILURES_BEFORE_RESTART" &&
          ! -e "${MAINTENANCE_DIR}/${name}" &&
          $((START_EPOCH - previous_action_epoch)) -ge RESTART_COOLDOWN_SECONDS ]]; then
        if [[ "$status" == "running" || "$RESTART_STOPPED_CONTAINERS" == true ]]; then
            can_restart=1
        fi
    fi

    if (( can_restart == 1 )); then
        log WARN "Restarting $name after $failures consecutive failures"
        if docker restart "$name" >/dev/null 2>&1; then
            RESTART_ACTIONS=$((RESTART_ACTIONS + 1))
            previous_action_epoch="$START_EPOCH"
            sleep "$POST_RESTART_WAIT_SECONDS"
            add_finding WARNING "$name: automatic restart action completed"
        else
            add_finding CRITICAL "$name: automatic restart action failed"
        fi
    fi

    state_set_service "$name" "$failures" "$restart_count" \
        "$previous_action_epoch" "$service_status" "${reason:-healthy}"
}

###############################################################################
# NOTIFICATION LIFECYCLE
###############################################################################

build_findings_body() {
    local item body=""
    for item in "${FINDINGS[@]}"; do
        body+="[${item%%|*}] ${item#*|}"$'\n'
    done
    printf '%s' "$body"
}

notification_due() {
    local previous_signature previous_epoch now
    previous_signature="$(jq -r '.notification.signature // ""' "$STATE_WORK")"
    previous_epoch="$(jq -r '.notification.epoch // 0' "$STATE_WORK")"
    now="$(date +%s)"

    [[ "$CURRENT_SIGNATURE" != "$previous_signature" ]] && return 0
    (( now - previous_epoch >= NOTIFY_COOLDOWN_HOURS * 3600 ))
}

commit_notification_state() {
    local next
    next="$(mktemp "${TMP_DIR}/notify.XXXXXX")" || return 1
    jq --arg signature "$CURRENT_SIGNATURE" --argjson epoch "$(date +%s)" '
        .notification = {signature:$signature,epoch:$epoch}
    ' "$STATE_WORK" >"$next" &&
        mv -f -- "$next" "$STATE_WORK"
}

send_lifecycle_notification() {
    local previous_signature body importance description
    previous_signature="$(jq -r '.notification.signature // ""' "$STATE_WORK")"

    if (( ${#FINDINGS[@]} == 0 )); then
        CURRENT_SIGNATURE=""
        if [[ -n "$previous_signature" ]]; then
            notify_unraid normal "Docker services recovered" \
                "All ${SERVICES_CHECKED} configured services are healthy." &&
                commit_notification_state
        fi
        return
    fi

    CURRENT_SIGNATURE="$(
        printf '%s\n' "${FINDINGS[@]}" | sort | sha256sum | awk '{print $1}'
    )"
    notification_due || return 0

    body="$(build_findings_body)"
    if (( CRITICAL_COUNT > 0 )); then
        importance="alert"
        description="Docker service failures"
    else
        importance="warning"
        description="Docker service warnings"
    fi
    if notify_unraid "$importance" "$description" "$body"; then
        commit_notification_state
    fi
}

###############################################################################
# MAIN
###############################################################################

main() {
    local spec
    if ! mountpoint -q /mnt/vault; then
        printf 'Vault pool is not mounted: /mnt/vault\n' >&2
        return 1
    fi
    mkdir -p -- "$STATE_DIR" "$MAINTENANCE_DIR" || return 1
    rotate_log
    touch "$LOG_FILE" || return 1

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        RESULT_SUMMARY="Another Docker watchdog run is active"
        log ERROR "$RESULT_SUMMARY"
        return 1
    fi

    for command in docker jq curl flock sha256sum; do
        command -v "$command" >/dev/null 2>&1 || {
            log ERROR "Required command not found: $command"
            return 1
        }
    done
    if ! docker info >/dev/null 2>&1; then
        RESULT_STATUS="CRITICAL"
        RESULT_SUMMARY="Docker service is unavailable"
        add_finding CRITICAL "$RESULT_SUMMARY"
        log ERROR "$RESULT_SUMMARY"
        notify_unraid alert "Docker service unavailable" "$RESULT_SUMMARY"
        write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
        return 1
    fi

    TMP_DIR="$(mktemp -d /tmp/docker-watchdog.XXXXXX)" || return 1
    log INFO "Starting Docker service watchdog v$SCRIPT_VERSION"
    STATE_WORK="${TMP_DIR}/state.json"
    if [[ -s "$STATE_FILE" ]] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
        cp -- "$STATE_FILE" "$STATE_WORK"
    else
        printf '{"services":{},"notification":{"signature":"","epoch":0}}\n' >"$STATE_WORK"
    fi

    for spec in "${SERVICE_SPECS[@]}"; do
        check_service "$spec" || {
            add_finding CRITICAL "Internal watchdog state update failed"
            break
        }
    done

    send_lifecycle_notification

    if ! cp -- "$STATE_WORK" "${STATE_FILE}.tmp" ||
       ! mv -f -- "${STATE_FILE}.tmp" "$STATE_FILE"; then
        log ERROR "Unable to commit watchdog state"
        return 1
    fi

    if (( CRITICAL_COUNT > 0 )); then
        RESULT_STATUS="CRITICAL"
    elif (( WARNING_COUNT > 0 )); then
        RESULT_STATUS="WARNING"
    else
        RESULT_STATUS="OK"
    fi
    RESULT_SUMMARY="${SERVICES_HEALTHY}/${SERVICES_CHECKED} healthy; critical=${CRITICAL_COUNT}, warnings=${WARNING_COUNT}, restarts=${RESTART_ACTIONS}"
    log INFO "$RESULT_SUMMARY"
    write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
    (( CRITICAL_COUNT == 0 ))
}

main "$@"
