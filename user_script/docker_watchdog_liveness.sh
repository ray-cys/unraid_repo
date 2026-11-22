#!/bin/bash

###############################################################################
# Docker Watchdog Liveness v1.1
#
# Independent execution monitoring for docker_service_watchdog.sh. Deploy as a
# second Unraid User Script, optionally scheduled every five minutes. This file
# does not install schedules, restart containers, or terminate watchdog processes.
# It remains usable when vault is unavailable because its state lives in /run.
###############################################################################

set -uo pipefail
umask 077
readonly SCRIPT_VERSION="1.1"

###############################################################################
# CONFIGURATION
###############################################################################

# Produced by the MAIN watchdog. Read only: never modify this file here.
HEARTBEAT_FILE="/run/docker-service-watchdog/heartbeat.json"
# Also bounds notification-state validation and retained invalid-state evidence.
HEARTBEAT_MAX_BYTES=65536

# Small RAM-backed state/log files; notification history resets after reboot.
STATE_DIR="/run/docker-watchdog-liveness"
STATE_FILE="$STATE_DIR/state.json"
LOG_FILE="$STATE_DIR/liveness.log"
LOCK_FILE="/run/docker_watchdog_liveness.lock"
LOG_MAX_BYTES=65536                 # Per log file; retain one rotated backup.
LOG_LINE_MAX_BYTES=4096

NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
NOTIFICATION_TIMEOUT_SECONDS=30
BOOT_GRACE_SECONDS=300              # Suppress checks during initial startup.
MAX_SUCCESS_AGE_SECONDS=900          # Last completed monitor scan: 15 minutes.
MAX_RUNNING_SECONDS=600             # Single monitor execution: 10 minutes.
MAX_CONSECUTIVE_FAILURES=3
CLOCK_TOLERANCE_SECONDS=300          # Allow small clock corrections.
UPTIME_FILE="/proc/uptime"

###############################################################################
# RUNTIME
###############################################################################

BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)"
NOW="$(date +%s)"
HEARTBEAT_JSON=""
HEARTBEAT_READ_ERROR=""
HEARTBEAT_EVIDENCE="Not available."
ISSUES=()
declare -A ISSUE_FINDINGS=() ISSUE_ACTIONS=()
TEMP_FILES=()
TEMP_FILE=""

###############################################################################
# VALIDATION AND FILE HANDLING
###############################################################################

require_dependencies() {
    local dependency missing=false

    for dependency in jq flock timeout stat head tail mktemp mv rm mkdir date; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            printf 'Required command unavailable: %s\n' "$dependency" >&2
            missing=true
        fi
    done

    [[ "$missing" == false ]]
}

validate_configuration() {
    local value path

    for value in "$HEARTBEAT_MAX_BYTES" "$LOG_MAX_BYTES" "$LOG_LINE_MAX_BYTES" \
        "$NOTIFICATION_TIMEOUT_SECONDS" "$MAX_SUCCESS_AGE_SECONDS" \
        "$MAX_RUNNING_SECONDS" "$MAX_CONSECUTIVE_FAILURES"; do
        if [[ ! "$value" =~ ^[1-9][0-9]{0,8}$ ]]; then
            printf 'Configuration error: size, timeout, and failure limits must be integers from 1 to 999999999.\n' >&2
            return 1
        fi
    done

    for value in "$BOOT_GRACE_SECONDS" "$CLOCK_TOLERANCE_SECONDS"; do
        if [[ ! "$value" =~ ^(0|[1-9][0-9]{0,8})$ ]]; then
            printf 'Configuration error: boot grace and clock tolerance must be integers from 0 to 999999999.\n' >&2
            return 1
        fi
    done

    if (( HEARTBEAT_MAX_BYTES > 1048576 )); then
        printf 'Configuration error: HEARTBEAT_MAX_BYTES must not exceed 1 MiB.\n' >&2
        return 1
    fi

    if (( LOG_LINE_MAX_BYTES < 256 || LOG_LINE_MAX_BYTES >= LOG_MAX_BYTES )); then
        printf 'Configuration error: LOG_LINE_MAX_BYTES must be >= 256 and smaller than LOG_MAX_BYTES.\n' >&2
        return 1
    fi

    for path in "$STATE_DIR" "$STATE_FILE" "$LOG_FILE" "$LOCK_FILE" "$HEARTBEAT_FILE" "$UPTIME_FILE" "$NOTIFY_BIN"; do
        if [[ "$path" != /* || "$path" == *$'\n'* ]]; then
            printf 'Configuration error: paths must be absolute and contain no newline: %s\n' "$path" >&2
            return 1
        fi
    done

    if [[ "$STATE_FILE" != "$STATE_DIR/"* || "$LOG_FILE" != "$STATE_DIR/"* ||
          "$STATE_FILE" == "$LOG_FILE" || "$HEARTBEAT_FILE" == "$STATE_FILE" ||
          "$HEARTBEAT_FILE" == "$LOG_FILE" || "$HEARTBEAT_FILE" == "$LOCK_FILE" ]]; then
        printf 'Configuration error: state/log paths must be separate from each other and the producer heartbeat.\n' >&2
        return 1
    fi
}

create_temporary_file() {
    TEMP_FILE="$(mktemp "$STATE_DIR/.liveness.XXXXXX")" || return 1
    TEMP_FILES+=("$TEMP_FILE")
}

cleanup() {
    local file

    for file in "${TEMP_FILES[@]}"; do
        [[ ! -f "$file" ]] || rm -f -- "$file"
    done
}

log() {
    local level="$1" line size
    local LC_ALL=C
    shift

    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] [DOCKER-LIVENESS] $*"
    if (( ${#line} > LOG_LINE_MAX_BYTES )); then
        line="${line:0:LOG_LINE_MAX_BYTES-24} ... [line truncated]"
    fi

    printf '%s\n' "$line"
    size="$(stat -c %s "$LOG_FILE" 2>/dev/null || printf 0)"
    if (( size + ${#line} + 1 > LOG_MAX_BYTES )); then
        mv -f -- "$LOG_FILE" "$LOG_FILE.1" || return 1
    fi
    printf '%s\n' "$line" >>"$LOG_FILE"
}

initialize_logging() {
    local file size temp

    for file in "$LOG_FILE" "$LOG_FILE.1"; do
        [[ -f "$file" ]] || continue
        size="$(stat -c %s "$file")" || return 1
        if (( size > LOG_MAX_BYTES )); then
            create_temporary_file || return 1
            temp="$TEMP_FILE"
            tail -c "$LOG_MAX_BYTES" -- "$file" >"$temp" && mv -f -- "$temp" "$file" || return 1
        fi
    done

    : >>"$LOG_FILE"
}

###############################################################################
# HEARTBEAT SNAPSHOT AND CLASSIFICATION
###############################################################################

read_heartbeat_snapshot() {
    local LC_ALL=C

    HEARTBEAT_READ_ERROR=""
    HEARTBEAT_JSON=""
    if [[ ! -f "$HEARTBEAT_FILE" ]]; then
        HEARTBEAT_READ_ERROR="Heartbeat file missing: $HEARTBEAT_FILE"
        return 1
    fi

    # Open/read once. Validation and all measurements use this same snapshot,
    # even if the producer atomically replaces its heartbeat during our scan.
    if ! HEARTBEAT_JSON="$(head -c "$((HEARTBEAT_MAX_BYTES + 1))" -- "$HEARTBEAT_FILE")"; then
        HEARTBEAT_READ_ERROR="Heartbeat read failed: $HEARTBEAT_FILE"
        return 1
    fi
    if (( ${#HEARTBEAT_JSON} > HEARTBEAT_MAX_BYTES )); then
        HEARTBEAT_READ_ERROR="Heartbeat exceeds configured $HEARTBEAT_MAX_BYTES-byte limit."
        return 1
    fi
}

heartbeat_valid() {
    jq -e 'type == "object" and .version == 1 and
        (.boot | type == "string" and length > 0) and
        (.firstSeen | type == "number" and . > 0 and . == floor) and
        (.lastSuccessful | type == "number" and . >= 0 and . == floor) and
        (.started | type == "number" and . > 0 and . == floor) and
        ((.finished // 0) | type == "number" and . >= 0 and . == floor) and
        (.failures | type == "number" and . >= 0 and . == floor) and
        (.lockSkips | type == "number" and . >= 0 and . == floor) and
        (.phase == "running" or .phase == "completed") and
        (.firstSeen <= .started) and
        (.lastSuccessful <= (.finished // 0)) and
        (if .phase == "completed" then (.finished >= .started) else true end)' \
        <<<"$HEARTBEAT_JSON" >/dev/null 2>&1
}

add_issue() {
    ISSUES+=("$1")
    ISSUE_FINDINGS["$1"]="$2"
    ISSUE_ACTIONS["$1"]="$3"
}

check_heartbeat() {
    local boot started finished success failures first phase skips age runtime

    ISSUES=()
    ISSUE_FINDINGS=()
    ISSUE_ACTIONS=()
    HEARTBEAT_EVIDENCE="Not available."

    if ! read_heartbeat_snapshot || ! heartbeat_valid; then
        add_issue heartbeat-missing-or-invalid \
            "${HEARTBEAT_READ_ERROR:-Heartbeat schema or timestamp sequence invalid.}" \
            'Verify the main watchdog is scheduled and can write its heartbeat; inspect its User Scripts output.'
        return 0
    fi

    IFS=$'\t' read -r boot started finished success failures first phase skips < <(
        jq -r '[.boot,.started,(.finished // 0),.lastSuccessful,.failures,.firstSeen,.phase,.lockSkips] | @tsv' <<<"$HEARTBEAT_JSON"
    )
    HEARTBEAT_EVIDENCE="Phase=$phase; started=$started; finished=$finished; last successful scan=$success; consecutive execution failures=$failures; cumulative skipped-lock runs=$skips."

    if [[ "$boot" != "$BOOT_ID" ]]; then
        add_issue heartbeat-from-previous-boot 'Heartbeat boot identity differs from the current Unraid boot.' \
            'Confirm the main watchdog has executed since this reboot and both scripts use the same heartbeat path.'
        return 0
    fi

    if (( started > NOW + CLOCK_TOLERANCE_SECONDS || finished > NOW + CLOCK_TOLERANCE_SECONDS ||
          success > NOW + CLOCK_TOLERANCE_SECONDS || first > NOW + CLOCK_TOLERANCE_SECONDS )); then
        add_issue heartbeat-clock-invalid "Heartbeat timestamp exceeds current time by more than ${CLOCK_TOLERANCE_SECONDS}s." \
            'Check Unraid time synchronization and the producer heartbeat before relying on age measurements.'
        return 0
    fi

    # One dominant failure prevents extra emails merely because an existing
    # stuck run also crosses the successful-execution freshness threshold.
    runtime=$((NOW - started))
    if [[ "$phase" == running ]] && (( runtime > MAX_RUNNING_SECONDS )); then
        add_issue execution-stuck-or-lock-contention "Execution has no completion checkpoint after ${runtime}s; limit=${MAX_RUNNING_SECONDS}s. Process activity/lock ownership is not verified by this check." \
            'Inspect the main watchdog process, its lock and last log entry; determine whether it is stalled or was terminated. No automatic termination is performed.'
    elif (( failures >= MAX_CONSECUTIVE_FAILURES )); then
        add_issue repeated-execution-failures "Consecutive execution failures=$failures; threshold=$MAX_CONSECUTIVE_FAILURES." \
            'Inspect the main watchdog execution log for configuration, command, storage or notification errors; correct the failure and rerun it.'
    elif (( success <= 0 )); then
        age=$((NOW - first))
        if (( age > MAX_SUCCESS_AGE_SECONDS )); then
            add_issue no-successful-execution "No successful monitor execution since initial tracking ${age}s ago; limit=${MAX_SUCCESS_AGE_SECONDS}s." \
                'Confirm the main watchdog schedule and complete one successful monitoring execution.'
        fi
    else
        age=$((NOW - success))
        if (( age > MAX_SUCCESS_AGE_SECONDS )); then
            add_issue successful-execution-overdue "Last successful monitoring execution was ${age}s ago; limit=${MAX_SUCCESS_AGE_SECONDS}s." \
                'Check the User Scripts schedule and recent execution output, including skipped runs or an unavailable vault mount.'
        fi
    fi
}

###############################################################################
# NOTIFICATION STATE AND OPERATIONAL REPORT
###############################################################################

notification_state_valid() {
    local size

    size="$(stat -c %s "$1" 2>/dev/null)" || return 1
    (( size <= HEARTBEAT_MAX_BYTES )) || return 1
    jq -e 'type == "object" and .version == 1 and
        (.issues | type == "array" and all(.[]; type == "string"))' "$1" >/dev/null 2>&1
}

build_notification_body() {
    local previous="$1" issue

    printf 'Docker Watchdog Liveness v%s\nChecked: %s\n\n' "$SCRIPT_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')"
    if (( ${#ISSUES[@]} == 0 )); then
        printf 'Result: Previously reported execution conditions are no longer detected.\n'
    fi
    for issue in "${ISSUES[@]}"; do
        printf 'Condition: %s\nEvidence: %s\nAction: %s\n\n' \
            "$issue" "${ISSUE_FINDINGS[$issue]}" "${ISSUE_ACTIONS[$issue]}"
    done
    jq -r --argjson current "$(printf '%s\n' "${ISSUES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')" \
        '. - $current | .[] | "Cleared condition: " + .' <<<"$previous"
    printf '\nExecution snapshot: %s\nHeartbeat: %s\nLiveness log: %s\n' "$HEARTBEAT_EVIDENCE" "$HEARTBEAT_FILE" "$LOG_FILE"
}

notify_changes() {
    local current previous='[]' temp description importance=alert body

    if [[ -e "$STATE_FILE" ]]; then
        if notification_state_valid "$STATE_FILE"; then
            previous="$(jq -c '.issues | unique' "$STATE_FILE")" || return 1
        else
            # Preserve corrupt state for review before replacing it after a
            # successful notification. No successful delivery is assumed.
            create_temporary_file || return 1
            temp="$TEMP_FILE"
            head -c "$HEARTBEAT_MAX_BYTES" -- "$STATE_FILE" >"$temp" && mv -f -- "$temp" "$STATE_FILE.invalid" || return 1
            add_issue liveness-state-invalid "Notification state failed schema validation; bounded original content retained at $STATE_FILE.invalid." \
                'Review the retained state; this checker will rebuild its notification checkpoint after successful delivery.'
        fi
    fi

    current="$(printf '%s\n' "${ISSUES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')" || return 1
    [[ "$current" != "$previous" ]] || return 0

    if [[ "$current" == '[]' ]]; then
        description='Docker watchdog EXECUTION RECOVERED'
        importance=normal
    else
        description='Docker watchdog EXECUTION FAILED'
    fi
    body="$(build_notification_body "$previous")" || return 1

    if [[ ! -x "$NOTIFY_BIN" ]]; then
        log ERROR "Notification command unavailable: $NOTIFY_BIN; delivery checkpoint unchanged"
        return 1
    fi
    if ! timeout "$NOTIFICATION_TIMEOUT_SECONDS" "$NOTIFY_BIN" -i "$importance" \
        -s 'Docker Watchdog Liveness' -d "$description" -m "$body"; then
        log ERROR 'Notification delivery failed or timed out; delivery checkpoint unchanged'
        return 1
    fi

    create_temporary_file || return 1
    temp="$TEMP_FILE"
    if ! jq -n --argjson issues "$current" '{version:1,issues:$issues}' >"$temp" ||
       ! notification_state_valid "$temp" || ! mv -f -- "$temp" "$STATE_FILE"; then
        rm -f -- "$temp"
        log ERROR 'Notification sent, but checkpoint commit failed; a later run may repeat the notification'
        return 1
    fi
}

###############################################################################
# MAIN
###############################################################################

print_help() {
    printf '%s\n' \
        'Usage: bash docker_watchdog_liveness.sh [--help|--version]' \
        'Deploy independently of docker_service_watchdog.sh; optional schedule: */5 * * * *.' \
        'Defaults: 5-minute boot grace, 15-minute completion age, 10-minute runtime, 3 failed executions.' \
        'Configure the paths and thresholds in CONFIGURATION before enabling.' \
        'Healthy/unchanged runs stay silent; changed conditions and recovery notify once.' \
        'Notification failures retry without advancing the delivered-state checkpoint.' \
        'State/logs live in /run, reset at reboot, and do not depend on vault availability.' \
        'This script does not restart/terminate anything or install schedules.'
}

main() {
    local uptime uptime_seconds

    case "${1:-}" in
        --help|-h) print_help; return 0 ;;
        --version) printf 'docker_watchdog_liveness.sh %s\n' "$SCRIPT_VERSION"; return 0 ;;
        '') ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; return 2 ;;
    esac

    require_dependencies && validate_configuration || return 1
    exec 9>"$LOCK_FILE" || return 1
    flock -n 9 || return 0
    mkdir -p -- "$STATE_DIR" || return 1
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    initialize_logging || return 1

    if ! read -r uptime _ <"$UPTIME_FILE" || [[ ! "$uptime" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        log ERROR "Uptime unavailable or invalid: $UPTIME_FILE"
        return 1
    fi
    uptime_seconds=$((10#${uptime%%.*}))
    if (( uptime_seconds < BOOT_GRACE_SECONDS )); then
        log INFO 'Initial boot grace active; liveness checks deferred'
        return 0
    fi
    if [[ "$BOOT_ID" == unknown || -z "$BOOT_ID" ]]; then
        log ERROR 'Current boot identity unavailable; heartbeat comparison aborted'
        return 1
    fi

    check_heartbeat && notify_changes || return 1
    log INFO "Liveness v$SCRIPT_VERSION complete; execution_conditions=${#ISSUES[@]}" || return 1
    (( ${#ISSUES[@]} == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
