#!/bin/bash
# Docker Watchdog Liveness v1.0. Independent process, optional */5 * * * *.
# Deploy as a SECOND Unraid User Script. This file does not install schedules.
# Monitors watchdog execution only; container incidents belong to the watchdog.
set -uo pipefail
umask 077
readonly SCRIPT_VERSION="1.0"
HEARTBEAT_FILE="/run/docker-service-watchdog/heartbeat.json"
STATE_DIR="/run/docker-watchdog-liveness"
STATE_FILE="$STATE_DIR/state.json"
LOG_FILE="$STATE_DIR/liveness.log"
LOG_MAX_BYTES=65536
LOCK_FILE="/run/docker_watchdog_liveness.lock"
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
BOOT_GRACE_SECONDS=300
MAX_SUCCESS_AGE_SECONDS=900
MAX_RUNNING_SECONDS=600
MAX_CONSECUTIVE_FAILURES=3
UPTIME_FILE="/proc/uptime"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)"
NOW="$(date +%s)"
ISSUES=()

log() {
    local line size
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    size="$(stat -c %s "$LOG_FILE" 2>/dev/null || printf 0)"
    if (( size + ${#line} + 1 > LOG_MAX_BYTES )); then mv -f -- "$LOG_FILE" "$LOG_FILE.1" || return 1; fi
    printf '%s\n' "$line" | tee -a "$LOG_FILE"
}

heartbeat_valid() {
    jq -e '.version == 1 and (.boot | type == "string") and
        (.firstSeen | type == "number" and . >= 0 and . == floor) and
        (.lastSuccessful | type == "number" and . >= 0 and . == floor) and
        (.started | type == "number" and . >= 0 and . == floor) and
        ((.finished // 0) | type == "number" and . >= 0 and . == floor) and
        (.failures | type == "number" and . >= 0 and . == floor) and
        (.lockSkips | type == "number" and . >= 0 and . == floor) and
        (.phase == "running" or .phase == "completed")' "$HEARTBEAT_FILE" >/dev/null 2>&1
}

check_heartbeat() {
    local boot started finished success failures first phase
    if ! heartbeat_valid; then ISSUES+=(heartbeat-missing-or-invalid); return 0; fi
    boot="$(jq -r .boot "$HEARTBEAT_FILE")"
    if [[ "$boot" != "$BOOT_ID" ]]; then ISSUES+=(heartbeat-from-previous-boot); return 0; fi
    read -r started finished success failures first phase < <(jq -r '[.started,(.finished // 0),.lastSuccessful,.failures,.firstSeen,.phase] | @tsv' "$HEARTBEAT_FILE")
    if (( started > NOW + 300 || finished > NOW + 300 || success > NOW + 300 || first > NOW + 300 )); then ISSUES+=(heartbeat-clock-invalid); return 0; fi
    # Report the dominant execution failure without sending another email just
    # because the same stuck run also crosses a freshness threshold.
    if [[ "$phase" == running ]] && (( NOW - started > MAX_RUNNING_SECONDS )); then ISSUES+=(execution-stuck-or-lock-contention); return 0; fi
    if (( failures >= MAX_CONSECUTIVE_FAILURES )); then ISSUES+=(repeated-execution-failures); return 0; fi
    if (( success <= 0 )); then
        (( NOW - first <= MAX_SUCCESS_AGE_SECONDS )) || ISSUES+=(no-successful-execution)
    elif (( NOW - success > MAX_SUCCESS_AGE_SECONDS )); then ISSUES+=(successful-execution-overdue); fi
}

notify_changes() {
    local current previous='[]' temp description importance=alert body
    current="$(printf '%s\n' "${ISSUES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')" || return 1
    if [[ -e "$STATE_FILE" ]]; then
        if jq -e '.issues | type == "array" and all(.[]; type == "string")' "$STATE_FILE" >/dev/null 2>&1; then
            previous="$(jq -c '.issues | unique' "$STATE_FILE")"
        else current="$(jq -c '. + ["liveness-state-invalid"] | unique' <<<"$current")"; fi
    fi
    [[ "$current" != "$previous" ]] || return 0
    description='Docker watchdog EXECUTION FAILED'
    [[ "$current" != '[]' ]] || { description='Docker watchdog EXECUTION RECOVERED'; importance=normal; }
    body="Execution conditions: $current"$'\n'"Heartbeat: $HEARTBEAT_FILE"$'\n'"Action: Check the main watchdog schedule, User Scripts output, mount readiness, and execution log. This checker performs no container recovery."
    [[ -x "$NOTIFY_BIN" ]] && timeout 30 "$NOTIFY_BIN" -i "$importance" -s 'Docker Watchdog Liveness' -d "$description" -m "$body" || { log 'Notification delivery failed; transition remains pending'; return 1; }
    temp="$(mktemp "$STATE_DIR/.state.XXXXXX")" || return 1
    jq -n --argjson issues "$current" '{version:1,issues:$issues}' >"$temp" && mv -f -- "$temp" "$STATE_FILE"
}

main() {
    local uptime command
    case "${1:-}" in
        --help|-h) printf '%s\n' 'Deploy separately from docker_service_watchdog.sh; schedule every five minutes.' \
            'Detects missing/stale completion, stuck executions, and repeated monitor failures.' \
            'Healthy/unchanged runs are silent; notification failures retry next run.' \
            'Does not depend on vault availability; state/logs live in /run and reset at reboot.'; return 0 ;;
        --version) printf 'docker_watchdog_liveness.sh %s\n' "$SCRIPT_VERSION"; return 0 ;;
        '') ;;
        *) return 2 ;;
    esac
    for command in jq flock timeout stat; do command -v "$command" >/dev/null || return 1; done
    exec 9>"$LOCK_FILE" || return 1
    flock -n 9 || return 0
    mkdir -p -- "$STATE_DIR" || return 1
    read -r uptime _ <"$UPTIME_FILE" || return 1
    (( ${uptime%%.*} >= BOOT_GRACE_SECONDS )) || return 0
    check_heartbeat || return 1
    notify_changes || return 1
    log "Liveness v$SCRIPT_VERSION complete; execution_conditions=${#ISSUES[@]}" || return 1
    (( ${#ISSUES[@]} == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
