#!/bin/bash
# Docker Service Watchdog v3.0 -- Unraid service availability and bounded recovery.
# Optional schedule: every five minutes. Pi-hole and application-specific health
# remain owned by the DNS and Arr monitors. All recovery is disabled by default.
set -uo pipefail
umask 077
readonly SCRIPT_VERSION="3.0"

###############################################################################
# CONFIGURATION
###############################################################################
# name|HTTP endpoint (optional)|always/on-demand|restart permission (0/1)
# on-demand containers may stop normally, but must remain installed.
SERVICE_SPECS=(
    "plex-media-server||always|0"
    "plex-media||always|0"
    "sonarr|http://192.168.50.4:8989/ping|always|0"
    "radarr|http://192.168.50.4:7878/ping|always|0"
    "sabnzbd|http://192.168.50.4:8080/|always|0"
    "qbittorrent||always|0"
    "kometa||always|0"
    "recyclarr||always|0"
    "imagemaid||always|0"
    "metafusion||always|0"
    "bazarr||always|0"
    "tautulli||always|0"
    "seerr||always|0"
    "prowlarr||always|0"
    "photoprism||always|0"
)
# Exact names win; aliases are used only if the primary is absent. If both
# exist the additional container is reported as unclassified, never ignored.
CONTAINER_ALIASES=("kometa|lometa" "tautulli|tautilli")
EXTERNAL_SERVICES=(pihole) # Owned by dns_redundancy_watchdog.sh.
DISABLED_SERVICES=()       # Explicitly ignored, intentionally disabled services.
DISCOVER_UNCLASSIFIED=true
# profile|max completion age hours|max runtime hours|evidence source
# User schedule + grace: weekly Imagemaid -> 192h; 4-hour jobs -> 6h.
# Recyclarr: two weekly runs, checked over 8 days without assuming spaced days.
# Sources: native:/container/path (Metafusion); log:/container/path; a host JSON
# receipt; or docker (one-shot containers only). Change log paths to your mounts.
JOB_RULES=(
    "imagemaid|192|24|dockerlogs"
    "kometa|6|24|dockerlogs"
    "metafusion|6|24|native:/tmp/metafusion-status.json"
    "recyclarr|192|24|receipt"
)
JOB_FREQUENCY_RULES=("recyclarr|2|192") # profile|min successful runs|rolling hours
JOB_READ_MAX_BYTES=262144
REQUIRE_VERIFIED_JOB_SUCCESS=true
# profile|container TCP port|readiness path|validation type|expected body
# Override an explicit URL in SERVICE_SPECS for custom paths/ports. Otherwise
# published-port mappings or a custom Docker IP are inspected, not guessed.
PROBE_RULES=(
    "plex-media-server|32400|/identity|plex|"
    "plex-media|32400|/identity|plex|"
    "sonarr|8989|/ping|ping|"
    "radarr|7878|/ping|ping|"
    "prowlarr|9696|/ping|ping|"
    "qbittorrent|8080|/api/v2/app/version|version|"
    "seerr|5055|/api/v1/status|version-json|"
    # Web UI recognition verifies identity/reachability only, not backend health.
    "sabnzbd|8080|/|recognize|SABnzbd"
    "bazarr|6767|/|recognize|[Bb]azarr"
    "tautulli|8181|/|recognize|[Tt]autulli"
    "photoprism|2342|/|recognize|[Pp]hoto[Pp]rism"
)
DOCKER_HOST_IP="192.168.50.4"
# Optional per-container files: NAME.headers (curl header-file syntax) and
# NAME.cookies (Netscape cookie jar). Credentials are never printed or placed
# on curl's command line. Supply qBittorrent auth for its protected API.
PROBE_AUTH_DIR="/mnt/vault/cloud/logs/docker_service_watchdog/probe-auth"
PROBE_MAX_BYTES=65536
SHARED_FAILURE_THRESHOLD=3
FLAP_WINDOW_SECONDS=3600
FLAP_TRANSITION_THRESHOLD=4
FLAP_STABLE_SECONDS=1800
HEARTBEAT_FILE="/run/docker-service-watchdog/heartbeat.json"
UPTIME_FILE="/proc/uptime"
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
declare -A SEEN=() FROZEN=() FROZEN_KEYS=() RECOVERY_BLOCKED=() PROFILE_BY_NAME=() PROBE_FAILURES=()
EFFECTIVE_SPECS=()
RECOVERY_CANDIDATES=()
SHARED_FAILURE=false
PROBE_RESULT=""
PROBE_MESSAGE=""
EXECUTION_COMPLETE=false
HEARTBEAT_STARTED=false

heartbeat_event() {
    local event="$1" rc="${2:-0}" fd temp existing='{}' now
    now="$(date +%s)"
    mkdir -p -- "${HEARTBEAT_FILE%/*}" || return 1
    exec {fd}>"$HEARTBEAT_FILE.lock" || return 1
    flock -w 2 "$fd" || { exec {fd}>&-; return 1; }
    if [[ -f "$HEARTBEAT_FILE" ]] && jq -e 'type == "object"' "$HEARTBEAT_FILE" >/dev/null 2>&1; then existing="$(cat "$HEARTBEAT_FILE")"; fi
    temp="$(mktemp "${HEARTBEAT_FILE%/*}/.heartbeat.XXXXXX")" || { exec {fd}>&-; return 1; }
    jq -n --argjson old "$existing" --arg boot "$BOOT_ID" --arg event "$event" --argjson now "$now" \
        --argjson pid "$$" --argjson rc "$rc" --argjson complete "$EXECUTION_COMPLETE" '
        (if $old.boot == $boot then $old else {boot:$boot,firstSeen:$now,lastSuccessful:0,failures:0,lockSkips:0} end) |
        .version=1 |
        if $event == "start" then .started=$now | .pid=$pid | .phase="running"
        elif $event == "skip" then .lastSkipped=$now | .lockSkips += 1
        else .finished=$now | .exitCode=$rc | .phase="completed" | .executionComplete=$complete |
            if $complete then .lastSuccessful=$now | .failures=0 else .failures += 1 end end' >"$temp" &&
        mv -f -- "$temp" "$HEARTBEAT_FILE"
    local result=$?
    [[ "$result" == 0 ]] || rm -f -- "$temp"
    exec {fd}>&-
    return "$result"
}

finish_watchdog() {
    local rc="$1"
    trap - EXIT
    if [[ "$HEARTBEAT_STARTED" == true ]]; then heartbeat_event finish "$rc" || rc=1; fi
    cleanup
    exit "$rc"
}

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
        ((.jobs // {}) | type == "object" and all(.[];
            (.firstSeen | type == "number" and . >= 0 and . == floor) and
            (.started | type == "number" and . >= 0 and . == floor) and
            (.finished | type == "number" and . >= 0 and . == floor) and
            (.success | type == "number" and . >= 0 and . == floor) and
            (.scanned | type == "number" and . >= 0 and . == floor) and (.result | type == "string"))) and
        ((.flapping // {}) | type == "object" and all(.[];
            (.down | type == "boolean") and (.unstable | type == "boolean") and
            (.last | type == "number" and . >= 0 and . == floor) and
            (.history | type == "array" and all(.[]; type == "number" and . >= 0 and . == floor)))) and
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

freeze_service_observations() {
    local name
    while IFS= read -r name; do FROZEN["$name"]=1; done < <(
        jq -r '.observations | keys[] | split(":")[0] | select(. != "monitor")' "$STATE_WORK"
    )
}

finish_observations() {
    local key service
    while IFS= read -r key; do
        [[ -z "${SEEN[$key]+yes}" ]] || continue
        service="${key%%:*}"
        [[ -z "${FROZEN[$service]+yes}" ]] || continue
        [[ -z "${FROZEN_KEYS[$key]+yes}" ]] || continue
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
epoch_value() {
    [[ -n "$1" && "$1" != null ]] || { printf '0\n'; return; }
    if [[ "$1" =~ ^[0-9]+$ ]]; then printf '%s\n' "$1"
    else date -d "$1" +%s 2>/dev/null || printf '0\n'; fi
}

record_job() {
    local name="$1" code="$2" started="${3:-0}" temp fd old='{}' rule primary alias found=false
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$code" =~ ^(0|[1-9][0-9]*)$ && "$started" =~ ^(0|[1-9][0-9]*)$ ]] || return 2
    for rule in "${CONTAINER_ALIASES[@]}"; do IFS='|' read -r primary alias <<<"$rule"; [[ "$name" != "$alias" ]] || name="$primary"; done
    for rule in "${JOB_RULES[@]}"; do [[ "${rule%%|*}" != "$name" ]] || found=true; done
    [[ "$found" == true ]] || return 2
    (( code <= 255 && started <= NOW )) || return 2
    mountpoint -q "$VAULT_MOUNT" || return 1
    mkdir -p -- "$STATE_DIR/jobs" || return 1
    exec {fd}>"$STATE_DIR/jobs/$name.lock" || return 1
    flock -w 10 "$fd" || { exec {fd}>&-; return 1; }
    if [[ -e "$STATE_DIR/jobs/$name.json" ]]; then
        old="$(jq -ce 'select(type == "object")' "$STATE_DIR/jobs/$name.json")" || { exec {fd}>&-; return 1; }
    fi
    temp="$(mktemp "$STATE_DIR/jobs/.receipt.XXXXXX")" || { exec {fd}>&-; return 1; }
    jq -n --argjson old "$old" --argjson now "$NOW" --argjson code "$code" --argjson started "$started" \
        '{startedAt:$started,finishedAt:$now,successfulAt:(if $code == 0 then $now else 0 end),exitCode:$code,
          successfulRuns:((($old.successfulRuns // []) + (if $code == 0 then [$now] else [] end)) | unique | map(select(. >= ($now-28*86400))))}' >"$temp" &&
        mv -f -- "$temp" "$STATE_DIR/jobs/$name.json"
    local rc=$?
    exec {fd}>&-
    return "$rc"
}

check_job() {
    local name="$1" info="$2" profile rule max_age runtime source file started=0 finished=0 success=0 result=unknown
    local old first old_finished old_success scan since line stamp read_error=false rc key frequency min_runs hours count receipt_history='[]'
    profile="${PROFILE_BY_NAME[$name]:-$name}"
    rule=""
    for line in "${JOB_RULES[@]}"; do [[ "${line%%|*}" != "$profile" ]] || rule="$line"; done
    [[ -n "$rule" ]] || return 0
    IFS='|' read -r profile max_age runtime source <<<"$rule"
    [[ -n "$source" ]] || { log INFO "$name: job completion source/deadline not configured"; return 0; }
    old="$(jq -c --arg name "$name" '.jobs[$name] // {}' "$STATE_WORK")"
    first="$(jq -r --argjson now "$NOW" '.firstSeen // $now' <<<"$old")"
    old_finished="$(jq -r '.finished // 0' <<<"$old")"; old_success="$(jq -r '.success // 0' <<<"$old")"
    scan="$(jq -r '.scanned // 0' <<<"$old")"
    file="$TMP_DIR/$name.job"
    # An explicit producer receipt takes precedence over inference from logs.
    if [[ -f "$STATE_DIR/jobs/$profile.json" ]]; then source="$STATE_DIR/jobs/$profile.json"; fi
    case "$source" in
        receipt)
            observe "$name:job-evidence" WARNING "Internal scheduler needs producer receipts: --record-job $profile EXIT_CODE START_EPOCH; no completion/success is inferred from container uptime" || return 1
            return 0 ;;
        native:*)
            docker_cmd exec "$name" head -c "$JOB_READ_MAX_BYTES" -- "${source#native:}" >"$file" 2>/dev/null || read_error=true
            if [[ "$read_error" == false ]] && jq -e 'type == "object" and (.state | type == "string") and
                (.heartbeat_at | type == "string") and (.pid | type == "number" and . > 0) and
                ((.last_run_status // "unknown") | . == "unknown" or . == "success" or . == "failed")' "$file" >/dev/null 2>&1; then
                started="$(epoch_value "$(jq -r '.last_run_started // ""' "$file")")"
                finished="$(epoch_value "$(jq -r '.last_run_finished // ""' "$file")")"
                success="$(epoch_value "$(jq -r '.last_success // ""' "$file")")"
                result="$(jq -r '.last_run_status // "unknown"' "$file")"
            else read_error=true; fi ;;
        dockerlogs|log:*)
            since=$((scan > 0 ? scan - 300 : NOW - (max_age > 0 ? max_age * 3600 : 86400)))
            if [[ "$source" == dockerlogs ]]; then
                docker_cmd logs --timestamps --since "$since" --tail 2000 "$name" 2>&1 | tail -c "$JOB_READ_MAX_BYTES" >"$file"; rc=$?
            else
                docker_cmd exec "$name" tail -c "$JOB_READ_MAX_BYTES" -- "${source#log:}" >"$file" 2>/dev/null; rc=$?
            fi
            if (( rc != 0 )); then read_error=true
            else
                sed -E $'s/\033\\[[0-9;]*[[:alpha:]]//g' "$file" >"$file.clean" && mv -f -- "$file.clean" "$file" || return 1
                # Only a whole-run banner counts. Collection/playlist/test-run
                # banners do not. A banner proves completion, not success.
                if [[ "$profile" == kometa ]]; then
                    stamp="$(grep -E 'Starting ([0-9]{1,2}:[0-9]{2} )?Run[[:space:]|=]*$' "$file" | tail -n 1 || true)"
                    stamp="${stamp%% *}"
                    [[ ! "$stamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || started="$(epoch_value "$stamp")"
                    line="$(grep -E 'Finished ([0-9]{1,2}:[0-9]{2} )?Run[[:space:]|=]*$' "$file" | tail -n 1 || true)"
                elif [[ "$profile" == imagemaid ]]; then
                    stamp="$(grep -E 'Script Started' "$file" | tail -n 1 || true)"; stamp="${stamp%% *}"
                    [[ ! "$stamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || started="$(epoch_value "$stamp")"
                    line="$(grep -E 'ImageMaid Finished' "$file" | tail -n 1 || true)"
                else line=""; fi
                stamp="${line%% *}"
                if [[ "$stamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then finished="$(epoch_value "$stamp")"; fi
                if (( finished > 0 )); then result=completed-unverified; fi
            fi ;;
        docker)
            started="$(epoch_value "$(jq -r '.[0].State.StartedAt // ""' <<<"$info")")"
            if [[ "$(jq -r '.[0].State.Status' <<<"$info")" == exited ]]; then
                finished="$(epoch_value "$(jq -r '.[0].State.FinishedAt // ""' <<<"$info")")"
                if [[ "$(jq -r '.[0].State.ExitCode' <<<"$info")" == 0 ]]; then success="$finished"; result=success; else result=failed; fi
            fi ;;
        /*)
            if head -c "$JOB_READ_MAX_BYTES" -- "$source" >"$file" && jq -e 'type == "object" and
                (.startedAt | type == "number" and . >= 0 and . == floor) and
                (.finishedAt | type == "number" and . > 0 and . == floor) and
                (.successfulAt | type == "number" and . >= 0 and . == floor) and
                (.exitCode | type == "number" and . >= 0 and . <= 255 and . == floor) and
                ((.successfulRuns // []) | type == "array" and all(.[]; type == "number" and . >= 0 and . == floor))' "$file" >/dev/null 2>&1; then
                started="$(jq -r .startedAt "$file")"; finished="$(jq -r .finishedAt "$file")"; success="$(jq -r .successfulAt "$file")"
                if [[ "$(jq -r .exitCode "$file")" == 0 ]]; then result=success; else result=failed; fi
                receipt_history="$(jq -c '.successfulRuns // []' "$file")"
                jq -e --argjson now "$NOW" 'all(.[]; . <= ($now+300))' <<<"$receipt_history" >/dev/null || read_error=true
            else read_error=true; fi ;;
        *) read_error=true ;;
    esac
    if [[ "$result" == success ]] && (( finished <= 0 || success != finished )); then read_error=true; fi
    if [[ "$read_error" == true ]] || (( started > NOW + 300 || finished > NOW + 300 || success > NOW + 300 || started < 0 || finished < 0 || success < 0 || success > finished )); then
        observe "$name:job-evidence" WARNING "Job completion evidence unavailable/invalid; configured source requires review" || return 1
        # Keep the last valid evidence; never clear a failure from a bad read.
        while IFS= read -r key; do FROZEN_KEYS["$key"]=1; done < <(jq -r --arg prefix "$name:job-" '.observations | keys[] | select(startswith($prefix))' "$STATE_WORK")
        RECOVERY_BLOCKED["$name"]=1
        return 0
    fi
    if [[ "$result" == unknown ]]; then result="$(jq -r '.result // "unknown"' <<<"$old")"; fi
    (( started > 0 )) || started="$(jq -r '.started // 0' <<<"$old")"
    (( finished >= old_finished )) || finished="$old_finished"
    (( success >= old_success )) || success="$old_success"
    mutate --arg name "$name" --arg result "$result" --argjson first "$first" --argjson started "$started" \
        --argjson finished "$finished" --argjson success "$success" --argjson scanned "$NOW" --argjson receipt_history "$receipt_history" \
        '.jobs //= {} | (.jobs[$name].history // []) as $history |
            .jobs[$name]={firstSeen:$first,started:$started,finished:$finished,success:$success,result:$result,scanned:$scanned,
                history:(($history + $receipt_history + (if $result == "success" and $success > 0 then [$success] else [] end)) | unique | map(select(. >= ($scanned - 28*86400))))}' || return 1
    if [[ "$result" == failed ]]; then observe "$name:job-failed" CRITICAL "Most recent scheduled job failed; container remains independently monitored" || return 1; fi
    if [[ "$result" == completed-unverified && "$REQUIRE_VERIFIED_JOB_SUCCESS" == true ]]; then
        observe "$name:job-unverified" WARNING "Whole-run completion banner observed; success not established. Configure a producer receipt to verify outcome" || return 1
    fi
    if (( started > finished )); then
        if (( runtime > 0 && NOW - started > runtime * 3600 )); then
            observe "$name:job-overrun" CRITICAL "Scheduled job exceeded configured ${runtime}h runtime limit" || return 1
        fi
    elif (( max_age > 0 )); then
        stamp="$finished"; (( stamp > 0 )) || stamp="$first"
        if (( NOW - stamp > max_age * 3600 )); then
            observe "$name:job-overdue" CRITICAL "No completed scheduled run within ${max_age}h (schedule plus grace); container running is not completion evidence" || return 1
        fi
    fi
    for frequency in "${JOB_FREQUENCY_RULES[@]}"; do
        IFS='|' read -r key min_runs hours <<<"$frequency"
        [[ "$key" == "$profile" ]] || continue
        if (( NOW - first >= hours * 3600 )); then
            count="$(jq -r --arg name "$name" --argjson cutoff "$((NOW - hours * 3600))" '[.jobs[$name].history[] | select(. >= $cutoff)] | length' "$STATE_WORK")"
            if (( count < min_runs )); then observe "$name:job-frequency" CRITICAL "Only $count successful runs observed in ${hours}h; expected at least $min_runs" || return 1; fi
        fi
    done
}

resolve_inventory() {
    local names name spec profile url expected allowed alias primary actual info owned
    local -A present=() classified=()
    names="$(docker_cmd container ls -a --format '{{.Names}}')" || return 1
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 1
        present["$name"]=1
    done <<<"$names"
    EFFECTIVE_SPECS=()
    for spec in "${SERVICE_SPECS[@]}"; do
        IFS='|' read -r profile url expected allowed <<<"$spec"
        actual="$profile"
        if [[ -z "${present[$profile]+yes}" ]]; then
            for alias in "${CONTAINER_ALIASES[@]}"; do
                IFS='|' read -r primary name <<<"$alias"
                [[ "$primary" != "$profile" || -z "${present[$name]+yes}" ]] || { actual="$name"; break; }
            done
        fi
        classified["$actual"]=1
        PROFILE_BY_NAME["$actual"]="$profile"
        EFFECTIVE_SPECS+=("$actual|$url|$expected|$allowed")
    done
    for name in "${EXTERNAL_SERVICES[@]}" "${DISABLED_SERVICES[@]}"; do classified["$name"]=1; done
    [[ "$DISCOVER_UNCLASSIFIED" == true ]] || return 0
    for name in "${!present[@]}"; do
        [[ -z "${classified[$name]+yes}" ]] || continue
        # An explicit ownership label can delegate a new container without
        # granting this script any restart permission.
        info="$(docker_cmd inspect "$name")" || return 1
        owned="$(jq -r '.[0].Config.Labels["com.ray-cys.watchdog.owner"] // ""' <<<"$info")" || return 1
        [[ "$owned" != external && "$owned" != disabled ]] || continue
        observe "$name:unclassified" WARNING "Discovered container has no policy; add SERVICE_SPECS or explicitly delegate/disable monitoring" || return 1
    done
}

probe_rule() {
    local rule profile="${PROFILE_BY_NAME[$1]:-$1}"
    for rule in "${PROBE_RULES[@]}"; do [[ "${rule%%|*}" != "$profile" ]] || { printf '%s\n' "$rule"; return 0; }; done
    return 1
}

probe_url() {
    local name="$1" info="$2" port="$3" path="$4" host mapped mode
    mapped="$(jq -r --arg port "$port/tcp" '. [0].NetworkSettings.Ports[$port][0] // {} | [(.HostIp // ""),(.HostPort // "")] | join("|")' <<<"$info")" || return 1
    host="${mapped%%|*}"; mapped="${mapped#*|}"
    if [[ -n "$mapped" ]]; then
        [[ "$host" != 0.0.0.0 && "$host" != :: && -n "$host" ]] || host="$DOCKER_HOST_IP"
        [[ "$host" != *:* ]] || host="[$host]"
        printf 'http://%s:%s%s\n' "$host" "$mapped" "$path"
        return 0
    fi
    mode="$(jq -r '.[0].HostConfig.NetworkMode // ""' <<<"$info")"
    if [[ "$mode" == host ]]; then host="$DOCKER_HOST_IP"
    elif [[ "$mode" != bridge && "$mode" != default && "$mode" != container:* ]]; then
        host="$(jq -r '[.[0].NetworkSettings.Networks[]?.IPAddress | select(length > 0)] | if length == 1 then .[0] else "" end' <<<"$info")"
    else host=""; fi
    [[ -n "$host" ]] || return 1
    printf 'http://%s:%s%s\n' "$host" "$port" "$path"
}

readiness_probe() {
    local name="$1" url="$2" rule profile port path kind pattern info body code rc
    local -a args=()
    PROBE_RESULT=unconfigured; PROBE_MESSAGE='No readiness probe configured'
    rule="$(probe_rule "$name")" || rule=""
    if [[ -z "$rule" && -z "$url" ]]; then return 0; fi
    IFS='|' read -r profile port path kind pattern <<<"$rule"
    kind="${kind:-reachable}"
    if [[ -z "$url" ]]; then
        info="$(docker_cmd inspect "$name" 2>/dev/null)" && inspect_valid "$info" || { PROBE_RESULT=inspection; PROBE_MESSAGE='Probe inspection failed'; return 1; }
        url="$(probe_url "$name" "$info" "$port" "$path")" || { PROBE_MESSAGE='Unable to resolve published/custom-IP endpoint; configure an explicit URL'; return 0; }
    fi
    body="$TMP_DIR/$name.probe"
    [[ ! -f "$PROBE_AUTH_DIR/$name.headers" ]] || args+=(--header "@$PROBE_AUTH_DIR/$name.headers")
    [[ ! -f "$PROBE_AUTH_DIR/$name.cookies" ]] || args+=(--cookie "$PROBE_AUTH_DIR/$name.cookies")
    code="$(curl --silent --output "$body" --connect-timeout "$HTTP_CONNECT_TIMEOUT" --max-time "$HTTP_MAX_TIME" \
        --max-filesize "$PROBE_MAX_BYTES" --write-out '%{http_code}' "${args[@]}" "$url")"; rc=$?
    if (( rc == 3 || rc == 60 || rc == 63 || rc == 77 )); then PROBE_RESULT=unconfigured; PROBE_MESSAGE="Probe URL/TLS/response-size configuration requires review (curl=$rc)"; return 0; fi
    if (( rc != 0 )); then PROBE_RESULT=transport; PROBE_MESSAGE="HTTP transport failed (curl=$rc)"; return 1; fi
    if [[ "$code" == 401 || "$code" == 403 ]]; then PROBE_RESULT=authentication; PROBE_MESSAGE='Endpoint reachable; authentication required/rejected; readiness unverified'; return 0; fi
    if [[ "$code" =~ ^3[0-9][0-9]$ ]]; then PROBE_RESULT=authentication; PROBE_MESSAGE='HTTP redirect; readiness unverified (check login or base URL)'; return 0; fi
    if [[ "$code" == 400 || "$code" == 404 || "$code" == 429 ]]; then PROBE_RESULT=unconfigured; PROBE_MESSAGE="Probe endpoint/parameters/rate limit requires review (HTTP $code)"; return 0; fi
    if [[ "$code" == 503 ]]; then PROBE_RESULT=starting; PROBE_MESSAGE='Application reports unavailable/starting (HTTP 503)'; return 1; fi
    if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then PROBE_RESULT=response; PROBE_MESSAGE="Unexpected HTTP status $code"; return 1; fi
    PROBE_RESULT=unexpected; PROBE_MESSAGE='Endpoint responded with unrecognized application content'
    case "$kind" in
        plex) grep -Eq '<MediaContainer[^>]*machineIdentifier=' "$body" || return 1 ;;
        ping) jq -e '.status == "OK"' "$body" >/dev/null 2>&1 || return 1 ;;
        version) grep -Eq '^v?[0-9]+\.[0-9]+' "$body" || return 1 ;;
        version-json) jq -e '.version | type == "string" and length > 0' "$body" >/dev/null 2>&1 || return 1 ;;
        recognize)
            grep -Eq -- "$pattern" "$body" || return 1
            PROBE_RESULT=reachable; PROBE_MESSAGE='Application UI recognized; backend readiness requires Docker health or a stronger configured probe'; return 0 ;;
        reachable) PROBE_RESULT=reachable; PROBE_MESSAGE='HTTP reachable; application readiness not verified'; return 0 ;;
        *) PROBE_RESULT=unconfigured; PROBE_MESSAGE='Unknown probe validation mode'; return 0 ;;
    esac
    PROBE_RESULT=ready; PROBE_MESSAGE='Application readiness response validated'
}

endpoint_healthy() {
    readiness_probe "${2:-service}" "$1"
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
    jq -e '.[0].State | .Status == "running" and ((.Health.Status // "none") == "none" or .Health.Status == "healthy")' <<<"$info" >/dev/null || return 1
    endpoint_healthy "$2" "$1" || return 1
    [[ "$PROBE_RESULT" == ready ]] || { [[ "$PROBE_RESULT" == reachable || "$PROBE_RESULT" == unconfigured ]] && jq -e '.[0].State.Health.Status == "healthy"' <<<"$info" >/dev/null; }
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
    if [[ "$(jq -r '.[0].Id' <<<"$latest")" != "$(jq -r --arg name "$name" '.services[$name].id // ""' "$STATE_WORK")" ]]; then exec {fd}>&-; return 0; fi
    # A service may have been stopped manually since the observation.
    if [[ "$(jq -r '.[0].State.Status' <<<"$latest")" != running && "$RESTART_STOPPED_CONTAINERS" != true ]]; then exec {fd}>&-; return 0; fi
    if [[ -n "$(probe_rule "$name" || true)" ]]; then
        readiness_probe "$name" "$url" || true
        if [[ "$PROBE_RESULT" == authentication || "$PROBE_RESULT" == unconfigured || "$PROBE_RESULT" == inspection ]]; then
            observe "$name:probe-configuration" WARNING "$PROBE_MESSAGE; recovery skipped" || { exec {fd}>&-; return 1; }
            exec {fd}>&-
            return 0
        fi
    fi
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
            observe "$name:missing" CRITICAL "Configured container not found (policy=$expected)"
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
        if [[ "$status" == exited && "$(jq -r '.[0].State.ExitCode // 0' <<<"$info")" != 0 ]]; then
            observe "$name:job-exit" CRITICAL "On-demand container exited with nonzero status" || return 1
        fi
        check_job "$name" "$info" || return 1
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
    else
        PROBE_RESULT=unconfigured
        if ! endpoint_healthy "$url" "$name"; then
            observe "$name:availability" CRITICAL "Readiness probe failed: $PROBE_MESSAGE" || return 1; bad=true
            [[ "$PROBE_RESULT" != transport ]] || PROBE_FAILURES["$name"]=1
        elif [[ "$PROBE_RESULT" == authentication || ( "$PROBE_RESULT" == unconfigured && -n "$(probe_rule "$name" || true)" ) ]]; then
            RECOVERY_BLOCKED["$name"]=1
            observe "$name:probe-configuration" WARNING "$PROBE_MESSAGE; automatic recovery prohibited" || return 1
        else log INFO "$name: $PROBE_MESSAGE" || return 1; fi
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
    check_job "$name" "$info" || return 1
    if [[ "$bad" == true ]]; then RECOVERY_CANDIDATES+=("$name|$url|$status|$allowed"); fi
}

###############################################################################
# GROUPED NOTIFICATIONS AND MAIN
###############################################################################
apply_flapping() {
    local spec name down unstable last
    for spec in "${EFFECTIVE_SPECS[@]}"; do
        name="${spec%%|*}"
        [[ -z "${FROZEN[$name]+yes}" ]] || continue
        down="$(jq -r --arg name "$name" '[.observations | to_entries[] | select(.key == ($name+":availability") or .key == ($name+":missing")) | .value.active] | any' "$STATE_WORK")"
        mutate --arg name "$name" --argjson down "$down" --argjson now "$NOW" --argjson window "$FLAP_WINDOW_SECONDS" --argjson threshold "$FLAP_TRANSITION_THRESHOLD" \
            --argjson stable "$FLAP_STABLE_SECONDS" '
            .flapping //= {} |
            .flapping[$name] = ((.flapping[$name] // {down:$down,history:[],last:$now,unstable:false}) |
                .history |= map(select(. >= ($now-$window))) |
                if .down != $down then .down=$down | .last=$now | .history += [$now] else . end |
                if (.history | length) >= $threshold then .unstable=true else . end |
                if .unstable and ($now - .last >= $stable) then .unstable=false | .history=[] else . end)' || return 1
        unstable="$(jq -r --arg name "$name" '.flapping[$name].unstable' "$STATE_WORK")"
        last="$(jq -r --arg name "$name" '.flapping[$name].last' "$STATE_WORK")"
        if [[ "$unstable" == true ]]; then
            RECOVERY_BLOCKED["$name"]=1
            observe "$name:unstable" WARNING "Repeated availability transitions; grouped unstable incident active. Last transition epoch=$last; require ${FLAP_STABLE_SECONDS}s stable before closing" 1 || return 1
        fi
    done
}

evaluate_shared_failure() {
    local name count="${#PROBE_FAILURES[@]}" persisted
    SHARED_FAILURE=false
    if (( count >= SHARED_FAILURE_THRESHOLD )); then
        SHARED_FAILURE=true
        observe monitor:shared-dependency CRITICAL "$count independent HTTP probes failed transport in one scan; shared network/host cause suspected, not proven; restarts suspended" || return 1
    fi
    persisted="$(jq -r '.observations["monitor:shared-dependency"].active // false' "$STATE_WORK")"
    [[ "$persisted" != true ]] || SHARED_FAILURE=true
    mutate --argjson shared "$SHARED_FAILURE" '.sharedFailure=$shared' || return 1
    if [[ "$SHARED_FAILURE" == true ]]; then
        for name in "${RECOVERY_CANDIDATES[@]}"; do RECOVERY_BLOCKED["${name%%|*}"]=1; done
    fi
}

notify_changes() {
    local current previous body importance=normal description
    current="$(jq -cS '. as $state | .observations | with_entries(select(.value.active) |
        select((.key | test(":(availability|missing)$") | not) or
            (($state.flapping[(.key | split(":")[0])].unstable // false | not) and
             ($state.observations["monitor:shared-dependency"].active // false | not)))) | map_values(.severity)' "$STATE_WORK")" || return 1
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
        --help|-h) printf '%s\n' 'Usage: bash docker_service_watchdog.sh [--version|--maintenance CONTAINER MINUTES REASON|--record-job PROFILE EXIT_CODE [START_EPOCH]]'
            printf '%s\n' 'Schedule every five minutes. Recovery requires global AND per-service permission.' \
                'Maintenance suppresses availability checks/restarts, freezes active findings, and expires within 24h.' \
                'Remove /run/docker-service-maintenance/CONTAINER.manual.json to end a manual lease early.' \
                'Healthy/unchanged runs stay silent. Failures and recovery require consecutive scans.' \
                'Internal schedulers need native status, timestamped whole-run evidence, or producer receipts.' \
                'Run docker_watchdog_liveness.sh independently every five minutes to monitor this script.'; return 0 ;;
        --version) printf 'docker_service_watchdog.sh %s\n' "$SCRIPT_VERSION"; return 0 ;;
        --maintenance) [[ $# == 4 ]] || return 2; set_manual_maintenance "$2" "$3" "$4"; return $? ;;
        --record-job) [[ $# == 3 || $# == 4 ]] || return 2; record_job "$2" "$3" "${4:-0}"; return $? ;;
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
        "$RECOVERY_TIMEOUT_SECONDS" "$RECOVERY_POLL_SECONDS" "$MAX_MAINTENANCE_SECONDS" "$LOG_MAX_BYTES" "$PROBE_MAX_BYTES" "$JOB_READ_MAX_BYTES" \
        "$SHARED_FAILURE_THRESHOLD" "$FLAP_WINDOW_SECONDS" "$FLAP_TRANSITION_THRESHOLD" "$FLAP_STABLE_SECONDS"; do
        [[ "$number" =~ ^[1-9][0-9]*$ ]] || return 2
    done
    for number in "$BOOT_GRACE_SECONDS" "$CONTAINER_GRACE_SECONDS" "$LOG_SIZE_WARNING_BYTES"; do [[ "$number" =~ ^[0-9]+$ ]] || return 2; done
    for flag in "$AUTO_RESTART" "$RESTART_STOPPED_CONTAINERS" "$CHECK_LOG_SIZE" "$DISCOVER_UNCLASSIFIED" "$REQUIRE_VERIFIED_JOB_SUCCESS"; do [[ "$flag" == true || "$flag" == false ]] || return 2; done
    local profile max_age runtime source
    for spec in "${JOB_RULES[@]}"; do
        IFS='|' read -r profile max_age runtime source <<<"$spec"
        [[ "$profile" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$max_age" =~ ^(0|[1-9][0-9]*)$ && "$runtime" =~ ^(0|[1-9][0-9]*)$ ]] || return 2
    done
    local min_runs hours port path kind pattern
    for spec in "${JOB_FREQUENCY_RULES[@]}"; do
        IFS='|' read -r profile min_runs hours <<<"$spec"
        [[ "$profile" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$min_runs" =~ ^[1-9][0-9]*$ && "$hours" =~ ^[1-9][0-9]*$ ]] || return 2
    done
    for spec in "${PROBE_RULES[@]}"; do
        IFS='|' read -r profile port path kind pattern <<<"$spec"
        [[ "$profile" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$port" =~ ^[1-9][0-9]*$ && "$path" == /* ]] || return 2
        (( port <= 65535 )) || return 2
        case "$kind" in plex|ping|version|version-json|reachable) ;; recognize) [[ -n "$pattern" ]] || return 2;; *) return 2;; esac
    done
    exec 9>"$LOCK_FILE" || return 1
    flock -n 9 || { heartbeat_event skip; return 0; }
    heartbeat_event start || return 1
    HEARTBEAT_STARTED=true
    trap 'finish_watchdog "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mountpoint -q "$VAULT_MOUNT" || return 1
    mkdir -p -- "$STATE_DIR" "$STATUS_DIR" "$DOCKER_MAINTENANCE_DIR" || return 1
    bound_existing_logs || return 1
    TMP_DIR="$(mktemp -d /tmp/docker-watchdog.XXXXXX)" || return 1
    STATE_WORK="$TMP_DIR/state.json"
    load_state || return 1
    read -r uptime _ <"$UPTIME_FILE" || return 1
    if (( ${uptime%%.*} < BOOT_GRACE_SECONDS )); then
        log INFO "Boot grace active; checks deferred"
        write_receipt WARNING
        EXECUTION_COMPLETE=true
        return 0
    fi
    if docker_cmd info >/dev/null 2>&1; then
        if resolve_inventory; then
            for spec in "${EFFECTIVE_SPECS[@]}"; do check_service "$spec" || { failed=true; break; }; done
        else failed=true; RECOVERY_SAFE=false; fi
    else
        RECOVERY_SAFE=false
        freeze_service_observations
        for spec in "${SERVICE_SPECS[@]}"; do FROZEN["${spec%%|*}"]=1; done
        observe monitor:docker CRITICAL "Docker daemon unavailable or timed out; container recovery prohibited" || return 1
    fi
    if [[ "$failed" == true ]]; then
        RECOVERY_SAFE=false
        freeze_service_observations
        observe monitor:execution CRITICAL "Monitoring/state operation failed; remaining service observations deferred" 1 || return 1
        for spec in "${SERVICE_SPECS[@]}"; do FROZEN["${spec%%|*}"]=1; done
    fi
    finish_observations || return 1
    apply_flapping && evaluate_shared_failure || return 1
    if [[ "$failed" != true ]]; then
        for spec in "${RECOVERY_CANDIDATES[@]}"; do
            IFS='|' read -r name url status allowed <<<"$spec"
            attempt_recovery "$name" "$url" "$status" "$allowed" || { failed=true; break; }
        done
    fi
    status=OK
    notify_changes || failed=true
    if jq -e 'any(.observations[]; .active and .severity == "CRITICAL")' "$STATE_WORK" >/dev/null; then status=CRITICAL
    elif jq -e 'any(.observations[]; .active)' "$STATE_WORK" >/dev/null; then status=WARNING; fi
    [[ "$failed" != true ]] || status=FAILED
    save_state && write_receipt "$status" || return 1
    [[ "$failed" != true ]] || EXECUTION_COMPLETE=false
    [[ "$failed" == true ]] || EXECUTION_COMPLETE=true
    log INFO "Watchdog v$SCRIPT_VERSION complete; status=$status"
    [[ "$status" != CRITICAL && "$status" != FAILED ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
