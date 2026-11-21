#!/bin/bash
# Docker Service Watchdog v2.0 -- Unraid service availability and bounded recovery.
# Optional schedule: every five minutes. Pi-hole and application-specific health
# remain owned by the DNS and Arr monitors. All recovery is disabled by default.
set -uo pipefail
umask 077
readonly SCRIPT_VERSION="2.0"

###############################################################################
# CONFIGURATION
###############################################################################
# name|HTTP endpoint (optional)|always/on-demand|restart permission (0/1)
# on-demand containers may be stopped or absent without an availability alert.
SERVICE_SPECS=(
    "plex-media-server||always|0"
    "plex-media||always|0"
    "sonarr|http://192.168.50.4:8989/ping|always|0"
    "radarr|http://192.168.50.4:7878/ping|always|0"
    "sabnzbd|http://192.168.50.4:8080/|always|0"
    "qbittorrent||always|0"
    "kometa||on-demand|0"
    "recyclarr||on-demand|0"
)
VAULT_MOUNT="/mnt/vault"
STATE_DIR="/mnt/vault/cloud/logs/docker_service_watchdog"
STATE_FILE="$STATE_DIR/state.json"
STATUS_DIR="/mnt/vault/cloud/logs/user_scripts_status"
LOG_FILE="$STATE_DIR/docker-service-watchdog.log"
LOG_MAX_BYTES=$((1024 * 1024))
LOCK_FILE="/run/docker_service_watchdog.lock"
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
COMMAND_TIMEOUT_SECONDS=20
HTTP_CONNECT_TIMEOUT=4
HTTP_MAX_TIME=10
BOOT_GRACE_SECONDS=300
CONTAINER_GRACE_SECONDS=120
FAILURE_CONFIRM_SCANS=2
RECOVERY_CONFIRM_SCANS=2
CHECK_LOG_SIZE=true
LOG_SIZE_WARNING_BYTES=$((1024 * 1024 * 1024))
# A maintenance lease suppresses availability observations AND restart actions.
# appdata_backup.sh and plex_dbrepair.sh write independent leases here. A shared
# per-container lock serializes lease creation against watchdog recovery.
DOCKER_MAINTENANCE_DIR="${DOCKER_MAINTENANCE_DIR:-/run/docker-service-maintenance}"
MAX_MAINTENANCE_SECONDS=86400
AUTO_RESTART=false
RESTART_STOPPED_CONTAINERS=false
CONSECUTIVE_FAILURES_BEFORE_RESTART=3
RESTART_COOLDOWN_SECONDS=21600
RESTART_BUDGET_WINDOW_SECONDS=86400
MAX_RESTART_ATTEMPTS=2
RECOVERY_TIMEOUT_SECONDS=90
RECOVERY_POLL_SECONDS=5

###############################################################################
# RUNTIME AND DURABLE STATE
###############################################################################
NOW="$(date +%s)"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)"
TMP_DIR=""
STATE_WORK=""
RECOVERY_SAFE=true
declare -A SEEN=() FROZEN=() RECOVERY_BLOCKED=()

log() {
    local level="$1" line size
    local LC_ALL=C
    shift
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
    (( ${#line} <= 4096 )) || line="${line:0:4070} ... [line truncated]"
    printf '%s\n' "$line"
    size="$(stat -c %s "$LOG_FILE" 2>/dev/null || printf 0)"
    if (( size + ${#line} + 1 > LOG_MAX_BYTES )); then
        mv -f -- "$LOG_FILE" "$LOG_FILE.1" || return 1
    fi
    printf '%s\n' "$line" >>"$LOG_FILE"
}

docker_cmd() { timeout --signal=TERM --kill-after=5 "$COMMAND_TIMEOUT_SECONDS" docker "$@"; }
cleanup() { [[ -z "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"; }

bound_existing_logs() {
    local file size tmp
    for file in "$LOG_FILE" "$LOG_FILE.1"; do
        [[ -f "$file" ]] || continue
        size="$(stat -c %s "$file")" || return 1
        if (( size > LOG_MAX_BYTES )); then
            tmp="$(mktemp "$STATE_DIR/.log-tail.XXXXXX")" || return 1
            tail -c "$LOG_MAX_BYTES" -- "$file" >"$tmp" && mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
        fi
    done
}

state_valid() {
    jq -e '.version == 2 and (.services | type == "object" and all(.[];
            (.id | type == "string") and (.oom | type == "boolean") and
            (.restartCount | type == "number" and . >= 0 and . == floor) and
            (.failures | type == "number" and . >= 0 and . == floor))) and
        (.recovery | type == "object" and all(.[];
            (.attempts | type == "number" and . >= 0 and . == floor) and
            (.last | type == "number" and . >= 0 and . == floor) and
            (.window | type == "number" and . >= 0 and . == floor))) and
        (.observations | type == "object" and all(.[];
            (.bad | type == "number" and . >= 0 and . == floor) and
            (.good | type == "number" and . >= 0 and . == floor) and
            (.first | type == "number" and . >= 0 and . == floor) and
            (.active | type == "boolean") and (.message | type == "string") and
            (.severity == "CRITICAL" or .severity == "WARNING"))) and
        (.notification | type == "object") and
        (.notification.issues | type == "object" and all(.[]; . == "CRITICAL" or . == "WARNING"))' "$1" >/dev/null 2>&1
}

save_state() {
    local next
    next="$(mktemp "$STATE_DIR/.state.XXXXXX")" || return 1
    cp -- "$STATE_WORK" "$next" && state_valid "$next" && mv -f -- "$next" "$STATE_FILE" || { rm -f -- "$next"; return 1; }
}

mutate() {
    local next="$TMP_DIR/next.json"
    jq "$@" "$STATE_WORK" >"$next" && mv -f -- "$next" "$STATE_WORK"
}

load_state() {
    if state_valid "$STATE_FILE"; then
        cp -- "$STATE_FILE" "$STATE_WORK" || return 1
        cp -- "$STATE_FILE" "$STATE_FILE.bak" || return 1
    elif [[ -e "$STATE_FILE" ]]; then
        RECOVERY_SAFE=false
        cp -- "$STATE_FILE" "$STATE_FILE.invalid" || return 1
        if state_valid "$STATE_FILE.bak"; then
            cp -- "$STATE_FILE.bak" "$STATE_WORK" || return 1
        else
            printf '{"version":2,"services":{},"recovery":{},"observations":{},"notification":{"issues":{}}}\n' >"$STATE_WORK"
        fi
        observe monitor:state WARNING "State invalid or legacy schema; recovery disabled for this run; prior file retained as state.json.invalid" 1
    else
        RECOVERY_SAFE=false
        printf '{"version":2,"services":{},"recovery":{},"observations":{},"notification":{"issues":{}}}\n' >"$STATE_WORK"
    fi
    # Never carry scan counters or monotonic Docker restart counts across boots.
    if [[ "$(jq -r '.bootId // ""' "$STATE_WORK")" != "$BOOT_ID" ]]; then
        RECOVERY_SAFE=false
        mutate --arg boot "$BOOT_ID" '.bootId=$boot | .services={} | .observations |= with_entries(.value.bad=0 | .value.good=0)' || return 1
    fi
}

# Stable keys exclude counters, age, changing log size, and message text.
observe() {
    local key="$1" severity="$2" message="$3" threshold="${4:-$FAILURE_CONFIRM_SCANS}"
    SEEN["$key"]=1
    log "$severity" "$key: $message" || return 1
    mutate --arg key "$key" --arg severity "$severity" --arg message "$message" --argjson now "$NOW" --argjson threshold "$threshold" '
        .observations[$key] = ((.observations[$key] // {bad:0,good:0,active:false,first:$now}) |
            .bad += 1 | .good=0 | .severity=$severity | .message=$message |
            .active = (.active or .bad >= $threshold))'
}

finish_observations() {
    local key service
    while IFS= read -r key; do
        [[ -z "${SEEN[$key]+yes}" ]] || continue
        service="${key%%:*}"
        [[ -z "${FROZEN[$service]+yes}" ]] || continue
        mutate --arg key "$key" --argjson threshold "$RECOVERY_CONFIRM_SCANS" '
            .observations[$key].bad=0 | .observations[$key].good += 1 |
            if .observations[$key].good >= $threshold then del(.observations[$key]) else . end' || return 1
    done < <(jq -r '.observations | keys[]' "$STATE_WORK")
}

###############################################################################
# EXPIRING MAINTENANCE LEASES
###############################################################################
maintenance_active() {
    local name="$1" lease expires pid boot active=1 wall_now process_start actual_start owner_alive=false
    wall_now="$(date +%s)"
    for lease in "$DOCKER_MAINTENANCE_DIR/$name."*.json; do
        [[ -f "$lease" && ! -L "$lease" ]] || continue
        if ! jq -e '(.expires | type == "number" and . == floor) and
            (.pid | type == "number" and . >= 0 and . == floor) and (.boot | type == "string")' "$lease" >/dev/null 2>&1; then
            observe "$name:maintenance-invalid" WARNING "Invalid lease: $lease; suppression disabled" 1 || return 2
            RECOVERY_BLOCKED["$name"]=1
            continue
        fi
        read -r expires pid boot < <(jq -r '[.expires,.pid,.boot] | @tsv' "$lease")
        owner_alive=false
        if (( pid > 0 )) && [[ "$boot" == "$BOOT_ID" ]] && kill -0 "$pid" 2>/dev/null; then
            process_start="$(jq -r '.processStart // ""' "$lease")"
            actual_start="$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')"
            if [[ -n "$actual_start" && "$process_start" == "$actual_start" ]]; then owner_alive=true; fi
        fi
        if [[ "$boot" == "$BOOT_ID" ]] && (( expires > wall_now && expires <= wall_now + MAX_MAINTENANCE_SECONDS )) &&
            { (( pid == 0 )) || [[ "$owner_alive" == true ]]; }; then
            active=0
        elif [[ "$owner_alive" == true ]]; then
            # An overlong backup must become visible, but never restart a
            # database while its verified maintenance process still owns it.
            RECOVERY_BLOCKED["$name"]=1
            observe "$name:maintenance-overrun" WARNING "Maintenance lease exceeded its limit; owner still active; recovery prohibited" 1 || return 2
        elif [[ "$lease" == *.manual.json ]]; then
            observe "$name:maintenance-expired" WARNING "Manual maintenance lease expired or invalid for this boot: $lease; suppression disabled" 1 || return 2
        fi
    done
    return "$active"
}

set_manual_maintenance() {
    local name="$1" minutes="$2" reason="$3" fd tmp
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$minutes" =~ ^[1-9][0-9]*$ ]] &&
        (( minutes <= MAX_MAINTENANCE_SECONDS / 60 )) || return 2
    mkdir -p -- "$DOCKER_MAINTENANCE_DIR" || return 1
    exec {fd}>"$DOCKER_MAINTENANCE_DIR/$name.lock" || return 1
    flock -w 30 "$fd" || { exec {fd}>&-; return 1; }
    tmp="$(mktemp "$DOCKER_MAINTENANCE_DIR/.lease.XXXXXX")" || { exec {fd}>&-; return 1; }
    jq -n --arg boot "$BOOT_ID" --arg reason "$reason" --argjson expires "$((NOW + minutes * 60))" \
        '{boot:$boot,pid:0,expires:$expires,reason:$reason}' >"$tmp" &&
        mv -f -- "$tmp" "$DOCKER_MAINTENANCE_DIR/$name.manual.json"
    local rc=$?
    exec {fd}>&-
    return "$rc"
}

###############################################################################
# SERVICE OBSERVATION AND RECOVERY
###############################################################################
endpoint_healthy() {
    local code
    [[ -n "$1" ]] || return 0
    code="$(curl --silent --output /dev/null --connect-timeout "$HTTP_CONNECT_TIMEOUT" --max-time "$HTTP_MAX_TIME" --write-out '%{http_code}' "$1")" || return 1
    [[ "$code" =~ ^[23][0-9][0-9]$ || "$code" == 401 || "$code" == 403 ]]
}

inspect_valid() {
    jq -e 'type == "array" and length == 1 and (.[0].State.Status | type == "string") and
        (.[0].State.OOMKilled | type == "boolean") and
        ((.[0].State.Health.Status // "none") | type == "string") and
        (.[0].RestartCount | type == "number" and . >= 0 and . == floor) and
        (.[0].Id | type == "string")' <<<"$1" >/dev/null 2>&1
}

verify_service() {
    local info
    info="$(docker_cmd inspect "$1" 2>/dev/null)" && inspect_valid "$info" || return 1
    jq -e '.[0].State | .Status == "running" and ((.Health.Status // "none") == "none" or .Health.Status == "healthy")' <<<"$info" >/dev/null && endpoint_healthy "$2"
}

attempt_recovery() {
    local name="$1" url="$2" status="$3" permitted="$4" count last window attempts fd elapsed=0 latest lease_rc
    [[ "$AUTO_RESTART" == true && "$RECOVERY_SAFE" == true && "$permitted" == 1 ]] || return 0
    [[ -z "${RECOVERY_BLOCKED[$name]+yes}" ]] || return 0
    [[ "$status" == running || "$RESTART_STOPPED_CONTAINERS" == true ]] || return 0
    count="$(jq -r --arg name "$name" '.services[$name].failures // 0' "$STATE_WORK")"
    (( count >= CONSECUTIVE_FAILURES_BEFORE_RESTART )) || return 0
    read -r last window attempts < <(jq -r --arg name "$name" '(.recovery[$name] // {last:0,window:0,attempts:0}) | [.last,.window,.attempts] | @tsv' "$STATE_WORK")
    if (( NOW - window >= RESTART_BUDGET_WINDOW_SECONDS )); then window="$NOW"; attempts=0; fi
    if (( attempts >= MAX_RESTART_ATTEMPTS )); then
        observe "$name:recovery-budget" CRITICAL "Automatic recovery budget exhausted ($attempts attempts); operator action required" 1
        return
    fi
    (( NOW - last >= RESTART_COOLDOWN_SECONDS )) || return 0
    exec {fd}>"$DOCKER_MAINTENANCE_DIR/$name.lock" || return 1
    flock -n "$fd" || { exec {fd}>&-; return 0; }
    # Recheck under the same lock used by lease writers to close the
    # maintenance-vs-restart race. Never act on an old inspection alone.
    maintenance_active "$name"; lease_rc=$?
    if (( lease_rc == 0 )); then exec {fd}>&-; return 0; fi
    if (( lease_rc != 1 )); then exec {fd}>&-; return 1; fi
    [[ -z "${RECOVERY_BLOCKED[$name]+yes}" ]] || { exec {fd}>&-; return 0; }
    latest="$(docker_cmd inspect "$name" 2>/dev/null)" && inspect_valid "$latest" || { exec {fd}>&-; return 0; }
    # A service may have been stopped manually since the observation.
    if [[ "$(jq -r '.[0].State.Status' <<<"$latest")" != running && "$RESTART_STOPPED_CONTAINERS" != true ]]; then exec {fd}>&-; return 0; fi
    if verify_service "$name" "$url"; then exec {fd}>&-; return 0; fi
    mutate --arg name "$name" --argjson now "$NOW" --argjson window "$window" --argjson attempts "$((attempts + 1))" \
        '.recovery[$name]={last:$now,window:$window,attempts:$attempts}' && save_state || { exec {fd}>&-; return 1; }
    # Reserve the attempt durably BEFORE executing Docker, even on timeout or
    # failure. An interrupted watchdog cannot create an unlimited restart loop.
    if docker_cmd restart "$name" >/dev/null 2>&1; then
        while (( elapsed <= RECOVERY_TIMEOUT_SECONDS )); do
            if verify_service "$name" "$url"; then
                observe "$name:recovery-action" WARNING "Container restarted; Docker health and configured endpoint verified; awaiting stable recovery scans" 1
                exec {fd}>&-
                return 0
            fi
            sleep "$RECOVERY_POLL_SECONDS"
            elapsed=$((elapsed + RECOVERY_POLL_SECONDS))
        done
    fi
    observe "$name:recovery-failed" CRITICAL "Restart failed or service did not pass post-restart verification; attempt budget consumed" 1
    exec {fd}>&-
}

check_service() {
    local name url expected allowed info status health id previous_id previous_count count oom previous_oom
    local started epoch uptime log_path size failures bad=false missing rc
    IFS='|' read -r name url expected allowed <<<"$1"
    maintenance_active "$name"; rc=$?
    if (( rc == 0 )); then
        FROZEN["$name"]=1
        log INFO "$name: maintenance active; availability/recovery suspended"
        return
    fi
    (( rc == 1 )) || return 1
    info="$(docker_cmd inspect "$name" 2>/dev/null)"; rc=$?
    if (( rc != 0 )); then
        missing="$(docker_cmd container ls -a --filter "name=^/${name}$" --format '{{.Names}}' 2>/dev/null)"; rc=$?
        if (( rc == 0 )) && [[ -z "$missing" ]]; then
            [[ "$expected" != on-demand ]] || return 0
            observe "$name:missing" CRITICAL "Configured always-running container not found"
        else
            observe "$name:inspection" CRITICAL "Container inspection failed or timed out; recovery prohibited"
        fi
        return
    fi
    if ! inspect_valid "$info"; then
        observe "$name:inspection" CRITICAL "Malformed Docker inspection; recovery prohibited"
        return
    fi
    read -r status health count oom id < <(jq -r '.[0] | [.State.Status,(.State.Health.Status // "none"),.RestartCount,.State.OOMKilled,.Id] | @tsv' <<<"$info")
    if [[ "$expected" == on-demand && ( "$status" == exited || "$status" == created ) ]]; then
        log INFO "$name: expected on-demand stop"
        return
    fi
    started="$(jq -r '.[0].State.StartedAt // ""' <<<"$info")"
    epoch="$(date -d "$started" +%s 2>/dev/null || printf 0)"
    uptime=$((NOW - epoch))
    if [[ "$status" == running ]] && (( epoch > 0 && uptime >= 0 && uptime < CONTAINER_GRACE_SECONDS )); then
        FROZEN["$name"]=1
        log INFO "$name: startup grace (${uptime}s)"
        return
    fi
    previous_id="$(jq -r --arg name "$name" '.services[$name].id // ""' "$STATE_WORK")"
    previous_count="$(jq -r --arg name "$name" '.services[$name].restartCount // 0' "$STATE_WORK")"
    previous_oom="$(jq -r --arg name "$name" '.services[$name].oom // false' "$STATE_WORK")"
    if [[ "$id" == "$previous_id" ]] && (( count > previous_count )); then
        observe "$name:restart-event" WARNING "Docker restart count increased ($previous_count -> $count)" 1 || return 1
    fi
    if [[ "$oom" == true && ( "$id" != "$previous_id" || "$previous_oom" != true ) ]]; then
        observe "$name:oom-event" WARNING "Docker recorded an out-of-memory termination; inspect memory limits and workload" 1 || return 1
    fi
    if [[ "$status" != running ]]; then
        observe "$name:availability" CRITICAL "Container status=$status" || return 1; bad=true
    elif [[ "$health" != healthy && "$health" != none ]]; then
        observe "$name:availability" CRITICAL "Docker health=$health after startup grace" || return 1; bad=true
    elif ! endpoint_healthy "$url"; then
        observe "$name:availability" CRITICAL "HTTP endpoint unavailable: $url" || return 1; bad=true
    fi
    log_path="$(jq -r '.[0].LogPath // ""' <<<"$info")"
    if [[ "$CHECK_LOG_SIZE" == true && -n "$log_path" && -f "$log_path" ]]; then
        size="$(stat -c %s "$log_path" 2>/dev/null || printf 0)"
        if (( size >= LOG_SIZE_WARNING_BYTES )); then
            observe "$name:log-size" WARNING "Docker log exceeds limit (${size} bytes); configure Docker log rotation" || return 1
        fi
    fi
    failures="$(jq -r --arg name "$name" '.services[$name].failures // 0' "$STATE_WORK")"
    if [[ "$id" != "$previous_id" ]]; then failures=0; fi
    if [[ "$bad" == true ]]; then failures=$((failures + 1)); else failures=0; fi
    mutate --arg name "$name" --arg id "$id" --argjson count "$count" --argjson oom "$oom" --argjson failures "$failures" \
        '.services[$name]={id:$id,restartCount:$count,oom:$oom,failures:$failures}' || return 1
    [[ "$bad" != true ]] || attempt_recovery "$name" "$url" "$status" "$allowed"
}

###############################################################################
# GROUPED NOTIFICATIONS AND MAIN
###############################################################################
notify_changes() {
    local current previous body importance=normal description
    current="$(jq -cS '.observations | with_entries(select(.value.active)) | map_values(.severity)' "$STATE_WORK")" || return 1
    previous="$(jq -cS '.notification.issues' "$STATE_WORK")" || return 1
    [[ "$current" != "$previous" ]] || return 0
    description="Docker watchdog UPDATED"
    [[ "$current" != '{}' ]] || description="Docker watchdog RESOLVED"
    if jq -e 'any(.[]; . == "CRITICAL")' <<<"$current" >/dev/null; then importance=alert
    elif [[ "$current" != '{}' ]]; then importance=warning; fi
    body="$(jq -r --argjson now "$NOW" '.observations | to_entries[] | select(.value.active) |
        "[\(.value.severity)] \(.key)\n  Condition: \(.value.message)\n  Observed duration: \(($now - .value.first) / 60 | floor)m; consecutive failures: \(.value.bad)"' "$STATE_WORK")"
    body+=$'\n'"$(jq -nr --argjson current "$current" --argjson previous "$previous" \
        '($previous | keys) - ($current | keys) | .[] | "Resolved: " + .')"
    body+=$'\n'"State: $STATE_FILE; log: $LOG_FILE"
    if [[ ! -x "$NOTIFY_BIN" ]] || ! timeout 30 "$NOTIFY_BIN" -i "$importance" -s "Docker Service Watchdog" -d "$description" -m "$body"; then
        log ERROR "Notification failed; delivery checkpoint unchanged"
        return 1
    fi
    mutate --argjson current "$current" '.notification.issues=$current'
}

write_receipt() {
    local status="$1" tmp
    tmp="$(mktemp "$STATUS_DIR/.docker-watchdog.XXXXXX")" || return 1
    jq -n --arg name docker_service_watchdog --arg status "$status" --arg version "$SCRIPT_VERSION" \
        --arg summary "Watchdog execution complete; status=$status; recovery_enabled=$AUTO_RESTART" --arg log "$LOG_FILE" --argjson epoch "$NOW" \
        '{name:$name,status:$status,scriptVersion:$version,summary:$summary,log:$log,epoch:$epoch}' >"$tmp" &&
        mv -f -- "$tmp" "$STATUS_DIR/docker_service_watchdog.json"
}

main() {
    local spec name url expected allowed uptime status=OK failed=false command
    case "${1:-}" in
        --help|-h) printf '%s\n' 'Usage: bash docker_service_watchdog.sh [--version|--maintenance CONTAINER MINUTES REASON]'
            printf '%s\n' 'Schedule every five minutes. Recovery requires global AND per-service permission.' \
                'Maintenance suppresses availability checks/restarts, freezes active findings, and expires within 24h.' \
                'Remove /run/docker-service-maintenance/CONTAINER.manual.json to end a manual lease early.' \
                'Healthy/unchanged runs stay silent. Failures and recovery require consecutive scans.'; return 0 ;;
        --version) printf 'docker_service_watchdog.sh %s\n' "$SCRIPT_VERSION"; return 0 ;;
        --maintenance) [[ $# == 4 ]] || return 2; set_manual_maintenance "$2" "$3" "$4"; return $? ;;
        '') ;;
        *) return 2 ;;
    esac
    for command in docker jq curl flock timeout sha256sum date stat; do command -v "$command" >/dev/null || return 1; done
    local -A configured=()
    for spec in "${SERVICE_SPECS[@]}"; do
        IFS='|' read -r name url expected allowed <<<"$spec"
        [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && ( "$expected" == always || "$expected" == on-demand ) && "$allowed" =~ ^[01]$ ]] || return 2
        [[ -z "$url" || "$url" =~ ^https?:// ]] || return 2
        [[ -z "${configured[$name]+yes}" ]] || return 2
        configured["$name"]=1
    done
    local number flag
    for number in "$COMMAND_TIMEOUT_SECONDS" "$HTTP_CONNECT_TIMEOUT" "$HTTP_MAX_TIME" "$FAILURE_CONFIRM_SCANS" "$RECOVERY_CONFIRM_SCANS" \
        "$CONSECUTIVE_FAILURES_BEFORE_RESTART" "$RESTART_COOLDOWN_SECONDS" "$RESTART_BUDGET_WINDOW_SECONDS" "$MAX_RESTART_ATTEMPTS" \
        "$RECOVERY_TIMEOUT_SECONDS" "$RECOVERY_POLL_SECONDS" "$MAX_MAINTENANCE_SECONDS" "$LOG_MAX_BYTES"; do
        [[ "$number" =~ ^[1-9][0-9]*$ ]] || return 2
    done
    for number in "$BOOT_GRACE_SECONDS" "$CONTAINER_GRACE_SECONDS" "$LOG_SIZE_WARNING_BYTES"; do [[ "$number" =~ ^[0-9]+$ ]] || return 2; done
    for flag in "$AUTO_RESTART" "$RESTART_STOPPED_CONTAINERS" "$CHECK_LOG_SIZE"; do [[ "$flag" == true || "$flag" == false ]] || return 2; done
    mountpoint -q "$VAULT_MOUNT" || return 1
    exec 9>"$LOCK_FILE" || return 1
    flock -n 9 || return 0
    mkdir -p -- "$STATE_DIR" "$STATUS_DIR" "$DOCKER_MAINTENANCE_DIR" || return 1
    bound_existing_logs || return 1
    TMP_DIR="$(mktemp -d /tmp/docker-watchdog.XXXXXX)" || return 1
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    STATE_WORK="$TMP_DIR/state.json"
    load_state || return 1
    read -r uptime _ </proc/uptime
    if (( ${uptime%%.*} < BOOT_GRACE_SECONDS )); then
        log INFO "Boot grace active; checks deferred"
        write_receipt WARNING
        return 0
    fi
    if docker_cmd info >/dev/null 2>&1; then
        for spec in "${SERVICE_SPECS[@]}"; do check_service "$spec" || { failed=true; break; }; done
    else
        RECOVERY_SAFE=false
        for spec in "${SERVICE_SPECS[@]}"; do FROZEN["${spec%%|*}"]=1; done
        observe monitor:docker CRITICAL "Docker daemon unavailable or timed out; container recovery prohibited" || return 1
    fi
    if [[ "$failed" == true ]]; then
        observe monitor:execution CRITICAL "Monitoring/state operation failed; remaining service observations deferred" 1 || return 1
        for spec in "${SERVICE_SPECS[@]}"; do FROZEN["${spec%%|*}"]=1; done
    fi
    finish_observations || return 1
    notify_changes || failed=true
    if jq -e 'any(.observations[]; .active and .severity == "CRITICAL")' "$STATE_WORK" >/dev/null; then status=CRITICAL
    elif jq -e 'any(.observations[]; .active)' "$STATE_WORK" >/dev/null; then status=WARNING; fi
    [[ "$failed" != true ]] || status=FAILED
    save_state && write_receipt "$status" || return 1
    log INFO "Watchdog v$SCRIPT_VERSION complete; status=$status"
    [[ "$status" != CRITICAL && "$status" != FAILED ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
