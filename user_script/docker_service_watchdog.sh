#!/bin/bash
clearLog=true
# Docker Service Watchdog v3.13 -- Unraid service availability and bounded recovery.
# Optional schedule: every five minutes. Pi-hole and application-specific health
# remain owned by the DNS and Arr monitors. Recovery follows Hubble's existing
# per-service permissions; VPN/configuration findings never request restarts.
# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="docker_service_watchdog"
# Embedded operations contract v1; generated into standalone User Scripts.
usr_ops_log_line() {
    local level="${1^^}" phase="$2" message="$3" line LC_ALL=C
    case "$level" in WARN) level=WARNING;; ERR|FATAL) level=ERROR;; NOTICE) level=INFO;; esac
    message=${message//$'\r'/};message=${message//$'\n'/ | }
    printf -v line '%s | %s | %s | run=%s | phase=%s | %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$OPS_SCRIPT_ID" "${OPS_RUN_ID:-$$}" "$phase" "$message"
    if ((${#line}>4096));then line="${line:0:4050} ... [truncated]";fi
    printf '%s\n' "$line"
}

# Accept the original command, including its timeout, so producer-specific
# delivery/cooldown/acknowledgement semantics stay with the owning script.
usr_ops_notify() {
    local -a args=("$@")
    local i importance=normal summary='' message='' index=-1 status=UPDATE
    for ((i=0;i<${#args[@]};i++));do
        case "${args[$i]}" in
          -i) importance="${args[$((i+1))]:-normal}";;
          -d) summary="${args[$((i+1))]:-}";;
          -m) index=$((i+1));message="${args[$index]:-}";;
        esac
    done
    case "$importance" in alert|warning) status=ATTENTION;;esac
    if [[ "$message" != 'Status: '* ]];then
        message="Status: $status"$'\n'"Summary: $summary"$'\n\n'"Actions and findings:"$'\n'"${message:-$summary}"
        if ((index>=0));then args[$index]="$message";else args+=(-m "$message");fi
    fi
    # Every notifier has a termination escalation, including legacy callers.
    if [[ "${args[0]##*/}" == timeout ]];then
        if [[ " ${args[*]} " != *' --kill-after'* ]];then args=("${args[0]}" --kill-after=5 "${args[@]:1}");fi
    else args=(timeout --signal=TERM --kill-after=5 30 "${args[@]}");fi
    "${args[@]}"
}

# Bounded local history for scripts previously dependent on the plugin console.
usr_ops_append_log() {
    local file="$1" line="$2" max="${3:-2097152}" i
    [[ -d "${file%/*}" && ! -L "$file" ]] || return 1
    for i in 1 2;do [[ ! -L "$file.$i" ]] || return 1;done
    find "${file%/*}" -maxdepth 1 -type f \( -name "${file##*/}.1" -o -name "${file##*/}.2" \) -mtime +29 -delete || return 1
    if [[ -f "$file" ]] && (( $(stat -c %s "$file")+${#line}+1>max ));then
        rm -f "$file.2";[[ ! -f "$file.1" ]] || mv "$file.1" "$file.2";mv "$file" "$file.1" || return 1
    fi
    printf '%s\n' "$line" >>"$file"
}
# END EMBEDDED OPERATIONS CONTRACT
set -uo pipefail
umask 077
readonly SCRIPT_VERSION="3.13"

###############################################################################
# CONFIGURATION
###############################################################################
# name|HTTP endpoint (optional)|always/on-demand|restart permission (0/1)
# Profiles apply only while installed; confirmed removal retires old monitoring.
# on-demand containers may stop normally without an availability failure.
SERVICE_SPECS=(
    "plex-media-server||always|1"
    "plex-media||always|1"
    "sonarr|http://192.168.50.4:8989/ping|always|1"
    "radarr|http://192.168.50.4:7878/ping|always|1"
    "sabnzbd|http://192.168.50.4:8080/|always|1"
    "qbittorrent|https://qbittorrent.taila4be9.ts.net/api/v2/app/version|always|0"
    "kometa||always|1"
    "recyclarr||always|0"
    "imagemaid||always|0"
    "metafusion||always|1"
    "bazarr||always|1"
    "tautulli||always|0"
    "seerr||always|1"
    "prowlarr||always|1"
    "photoprism||always|0"
    "lumunarr||always|0"
)
# Exact names win; aliases are used only if the primary is absent. If both
# exist the additional container is reported as unclassified, never ignored.
CONTAINER_ALIASES=("kometa|lometa" "tautulli|tautilli")
EXTERNAL_SERVICES=(pihole) # Owned by dns_redundancy_watchdog.sh.
DISABLED_SERVICES=()       # Explicitly ignored, intentionally disabled services.
DISCOVER_UNCLASSIFIED=true
# profile|max completion age hours|max runtime hours|evidence source
# Actual schedule + grace: Wed/Sun Imagemaid -> 120h; four-hour jobs -> 6h.
# Recyclarr: Wed/Sun 06:00; longest gap 96h + 24h grace, two successes per 8 days.
# Sources: runlog:/container/path (Kometa/ImageMaid full native run logs);
# native:/container/path (Metafusion); log:/container/path; a host JSON
# receipt; or docker (one-shot containers only). Change log paths to your mounts.
JOB_RULES=(
    "imagemaid|120|24|runlog:/config/logs/imagemaid.log"
    "kometa|6|24|runlog:/config/logs/meta.log"
    "metafusion|6|24|native:/tmp/metafusion-status.json"
    "recyclarr|120|24|dockerlogs"
)
JOB_FREQUENCY_RULES=("recyclarr|2|192") # profile|min successful runs|rolling hours
JOB_READ_MAX_BYTES=262144
# Stream new native-log bytes only; allow a 70 MB Kometa run plus rotation
# catch-up without copying the log to vault or RAM. Backlogs resume next scan.
JOB_LOG_SCAN_MAX_BYTES=$((128 * 1024 * 1024))
REQUIRE_VERIFIED_JOB_SUCCESS=true
# Preflight owns routine Kometa warnings/errors. Delegate emails only while its
# weekly-report heartbeat/deadline is healthy; operational/fatal alerts stay here.
KOMETA_WEEKLY_REPORTING=true
KOMETA_WEEKLY_STATE="/mnt/vault/cloud/logs/script/media_metadata_audit/weekly-report-state.json"
RECYCLARR_JOB_COMMAND="/cron.sh"
RECYCLARR_JOB_POSITION=0
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
# profile|exact hostname|TCP port|verified IPv4 address
# Per-request DNS overrides; HTTPS still validates the URL hostname/certificate.
# Hubble cannot resolve this MagicDNS name, but this Tailscale route returned
# v5.3.0/HTTP 200. Update/remove the entry if the Tailscale node is recreated.
# These overrides never change system DNS, Docker ports, or VPN configuration.
PROBE_ADDRESS_OVERRIDES=(
    "qbittorrent|qbittorrent.taila4be9.ts.net|443|100.64.251.79"
)
# Read-only VPN evidence for Hubble's Tailscale/Mullvad qBittorrent setup.
# Verify the node ID again if you deliberately change Mullvad location/node.
# Canary requests are tiny HTTPS requests from inside the container; they do
# not read media, edit application settings, or infer privacy from Web UI health.
VPN_EGRESS_CHECK_ENABLED=true
VPN_CONTAINER="qbittorrent"
VPN_EXPECTED_INTERFACE="tailscale0"
VPN_EXPECTED_EXIT_NODE_ID="n4voE47CNTRL"
# Optional per-container files: NAME.headers (curl header-file syntax) and
# NAME.cookies (Netscape cookie jar). Credentials are never printed or placed
# on curl's command line. Supply qBittorrent auth for its protected API.
PROBE_AUTH_DIR="/mnt/vault/cloud/logs/script/docker_service_watchdog/probe-auth"
PROBE_MAX_BYTES=65536
PROBE_UI_MAX_BYTES=1048576 # Bounded web UI recognition needs more than API JSON.
PROBE_MAX_REDIRECTS=3     # Same-origin redirects for UI recognition only.
PROBE_MAX_ROUTES=3        # qBittorrent only: metadata-proven host/loopback/IP.
SHARED_FAILURE_THRESHOLD=3
FLAP_WINDOW_SECONDS=3600
FLAP_TRANSITION_THRESHOLD=4
FLAP_STABLE_SECONDS=1800
HEARTBEAT_FILE="/run/docker-service-watchdog/heartbeat.json"
UPTIME_FILE="/proc/uptime"
VAULT_MOUNT="/mnt/vault"
STATE_DIR="/mnt/vault/cloud/logs/script/docker_service_watchdog"
STATE_FILE="$STATE_DIR/state.json"
STATUS_DIR="/mnt/vault/cloud/logs/script/user_scripts_status"
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
# backup_cache_appdata.sh and media_plex_dbrepair.sh write independent leases here. A shared
# per-container lock serializes lease creation against watchdog recovery.
DOCKER_MAINTENANCE_DIR="${DOCKER_MAINTENANCE_DIR:-/run/docker-service-maintenance}"
MAX_MAINTENANCE_SECONDS=86400
AUTO_RESTART=true
RESTART_STOPPED_CONTAINERS=false # Legacy opt-in; unexpected-exit proof still mandatory.
RECOVER_UNEXPECTED_EXITS=true    # Only known running always-on containers with die events.
STOP_EVENT_MAX_AGE_SECONDS=3600
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
    line=$(usr_ops_log_line "$level" MAIN "$*")
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
            command tail "-c$LOG_MAX_BYTES" -- "$file" >"$tmp" && mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
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
            (.scanned | type == "number" and . >= 0 and . == floor) and (.result | type == "string") and
            ((.history // []) | type == "array" and all(.[]; type == "number" and . >= 0 and . == floor)) and
            ((.logState // {}) | type == "object" and (if has("containerId") then
                (.containerId | type == "string") and (.start | type == "number" and . >= 0 and . == floor) and
                (.iteration | type == "string" and test("^[0-9]*$")) and
                (.failed | type == "boolean") and (.seen | type == "boolean") and (.open | type == "boolean")
                else . == {} end)) and ((.runLog // {}) | type == "object"))) and
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
    local update_journal="${UPDATE_COORDINATOR_STATE_FILE:-/mnt/vault/cloud/logs/script/system_update_coordinator/state.json}"
    if [[ -e "$update_journal" ]];then
      if [[ -L "$update_journal" ]] || ! jq -e '.schema==1 and (.jobs|type)=="object"' "$update_journal" >/dev/null 2>&1;then
        RECOVERY_BLOCKED["$name"]=1
        observe monitor:update-journal WARNING 'Update coordinator journal invalid; automatic restart prohibited until its state is verified' 1 || return 2
      elif jq -e --arg name "$name" 'any(.jobs[];(.kind=="docker" and .name==$name and (.status|IN("INTENT","VERIFYING","ATTENTION"))) or (.kind=="plugin" and (.status|IN("INTENT","ATTENTION"))))' "$update_journal" >/dev/null;then
        return 0
      fi
    fi
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

# Recyclarr's resident scheduler emits authoritative cron-process outcomes.
# Match the configured command/position/iteration, never a per-library
# "Completed at" line. Keep open-run/error context across polling windows.
parse_recyclarr_log() {
    local file="$1" info="$2" old="$3" id context iteration="" start=0 failed=false seen=false open=false
    local line stamp epoch event_iteration command_match=false position_match=false
    id="$(jq -r '.[0].Id' <<<"$info")"
    context="$(jq -c --arg id "$id" '.logState // {} | select(.containerId == $id and (.start | type == "number") and
        (.iteration | type == "string" and test("^[0-9]+$")) and (.failed | type == "boolean") and (.seen | type == "boolean") and (.open | type == "boolean"))' <<<"$old")"
    if [[ -n "$context" ]]; then
        IFS=$'\t' read -r iteration start failed seen open < <(jq -r '[.iteration,.start,.failed,.seen,.open] | @tsv' <<<"$context")
    fi
    JOB_LOG_STARTED=0; JOB_LOG_FINISHED=0; JOB_LOG_SUCCESS=0; JOB_LOG_RESULT=unknown; JOB_LOG_HISTORY='[]'
    while IFS= read -r line; do
        stamp="${line%% *}"
        [[ "$stamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || continue
        epoch="$(epoch_value "$stamp")"
        (( epoch > 0 && epoch <= NOW + 300 )) || continue
        command_match=false; position_match=false
        [[ " $line " != *" job.command=$RECYCLARR_JOB_COMMAND "* && " $line " != *" job.command=\"$RECYCLARR_JOB_COMMAND\" "* ]] || command_match=true
        [[ " $line " != *" job.position=$RECYCLARR_JOB_POSITION "* ]] || position_match=true
        if [[ "$command_match" == true && "$position_match" == true && "$line" =~ iteration=([0-9]+) ]]; then
            event_iteration="${BASH_REMATCH[1]}"
            if [[ "$line" =~ msg=(\"starting\"|starting)[[:space:]] ]]; then
                if (( epoch > start )) || { (( epoch == start )) && [[ "$iteration" != "$event_iteration" ]]; }; then
                    start="$epoch"; iteration="$event_iteration"; failed=false; seen=true; open=true
                fi
                JOB_LOG_STARTED="$start"
            elif [[ "$line" == *'msg="job succeeded"'* || "$line" == *'msg="job failed"'* ]]; then
                (( epoch >= start )) || continue
                (( epoch >= JOB_LOG_FINISHED )) || continue
                JOB_LOG_FINISHED="$epoch"
                if [[ "$line" == *'msg="job failed"'* ]]; then
                    JOB_LOG_RESULT=failed
                elif [[ "$seen" == true && "$event_iteration" == "$iteration" ]] && (( epoch >= start )); then
                    if [[ "$failed" == true ]]; then JOB_LOG_RESULT=failed
                    else
                        JOB_LOG_RESULT=success; JOB_LOG_SUCCESS="$epoch"
                        JOB_LOG_HISTORY="$(jq -c --argjson epoch "$epoch" '. + [$epoch] | unique' <<<"$JOB_LOG_HISTORY")"
                    fi
                else JOB_LOG_RESULT=completed-unverified; fi
                open=false
            fi
        elif [[ "$open" == true ]] && (( epoch >= start )) && [[ "$line" =~ \[(ERR|FTL)\]|level=(error|fatal) ]]; then
            failed=true
        fi
    done <"$file"
    if [[ "$open" == true ]]; then JOB_LOG_STARTED="$start"; fi
    JOB_LOG_STATE="$(jq -nc --arg id "$id" --arg iteration "$iteration" --argjson start "$start" \
        --argjson failed "$failed" --argjson seen "$seen" --argjson open "$open" \
        '{containerId:$id,iteration:$iteration,start:$start,failed:$failed,seen:$seen,open:$open}')"
}

# The two Python applications already provide Python 3 in their images. Run
# this read-only streaming reader there: no host Python dependency/helper file,
# no whole-log copy, no application/configuration/receipt writes. Its compact
# cursor and redacted findings live only in the existing watchdog state.
read_native_run_log() {
    local name="$1" profile="$2" path="$3" info="$4" old="$5" program context id
    context="$(jq -c '.runLog // {}' <<<"$old")" || return 1
    id="$(jq -r '.[0].Id' <<<"$info")" || return 1
    program="$(cat <<'PY'
import copy
import datetime
import functools
import hashlib
import json
import os
import re
import stat
import sys
import time

profile, source, limit, now, container = sys.argv[1:]
limit, now = int(limit), int(now)
if profile not in ("kometa", "imagemaid") or not os.path.isabs(source):
    raise ValueError("Unsupported native run-log profile/path")
if not 1024 <= limit <= 512 * 1024 * 1024:
    raise ValueError("Invalid native log scan limit")
saved = json.load(sys.stdin)
state = saved if isinstance(saved, dict) and saved.get("version") == 1 and saved.get("source") == source else {}
if state.get("containerId") != container or state.get("parserVersion") != 3:
    state.pop("cursor", None)
    state.pop("active", None)
    state["gap"] = False
state.update(version=1, parserVersion=3, source=source, containerId=container)
state.setdefault("completed", {})
state.setdefault("successfulAt", 0)
state.setdefault("gap", False)
budget, deadline = limit, time.monotonic() + 10
# Both upstream fmt_filter functions wrap filename:line and severity in square
# brackets. Also accept the earlier bare-level layout without guessing levels
# from arbitrary message contents.
levels = r"TRACE|DEBUG|INFO|WARNING|WARN|ERROR|CRITICAL|FATAL"
record = re.compile(r"^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)(?:[,.]\d+)?\]\s+\S+\s+(?:\[(" + levels + r")\]|(" + levels + r"))\s+(.*)$")
ansi = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

def redact(message, maximum=240):
    message = re.sub(r"""(?is)(["']?(?:api[_-]?key|token|password|secret|authorization)["']?\s*[:=]\s*)(["'])(.*?)\2""", r'\1"[REDACTED]"', message)
    message = re.sub(r"(?i)authorization[=: ]+(?:bearer\s+|basic\s+)?[^\s,;|]+", "authorization=[REDACTED]", message)
    message = re.sub(r"(?i)(https?://)[^/@\s]+@", r"\1[REDACTED]@", message)
    message = re.sub(r"(?i)(api[_-]?key|token|password|secret)[=: ]+[^\s,;|]+", r"\1=[REDACTED]", message)
    # Arbitrary URL query strings can also contain credentials or signed URLs.
    message = re.sub(r"(https?://[^\s?#|]+)[?#][^\s|]*", r"\1?[REDACTED]", message)
    message = re.sub(r"(?i)([\"']?(?:api[_-]?key|token|password|secret|authorization)[\"']?\s*[:=]\s*)[\"']?[^\s,;|]+", r"\1[REDACTED]", message)
    return message[:maximum]

def new_run(epoch=0, full=False, mode="normal", prelude=None):
    return {"startedAt": epoch, "full": full, "mode": mode, "terminal": False,
            "closed": False, "summary": False, "previousSuccess": state["successfulAt"],
            "findings": copy.deepcopy(prelude or {}),
            "maintenanceContext": {}, "maintenanceFindings": {}, "maintenanceDone": [],
            "maintenanceLoaded": [], "maintenanceSummary": False}

@functools.lru_cache(maxsize=512)
def timestamp(stamp):
    return int(datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S").timestamp())

def finding(run, level, message):
    if not message.strip(" |-=*\t"):
        return
    group = "fatal" if level in ("CRITICAL", "FATAL") else "errors" if level == "ERROR" else "warnings"
    bucket = run["findings"].setdefault(group, {"keys": [], "examples": []})
    key = hashlib.sha256(message.encode()).hexdigest()[:24]
    if key not in bucket["keys"] and len(bucket["keys"]) < 32:
        bucket["keys"].append(key)
        if len(bucket["examples"]) < 3:
            bucket["examples"].append(redact(message))

def outcome(run):
    flags = run["findings"]
    if flags.get("fatal", {}).get("keys"):
        return "failed"
    if flags.get("errors", {}).get("keys"):
        return "completed-errors"
    if not run["full"] or run["mode"] != "normal":
        return "completed-unverified"
    return "completed-warnings" if flags.get("warnings", {}).get("keys") else "success"

# Compact maintenance catalogue: one reader, no second scan/copy of full logs.
# It records observed log context only; missing file/library context stays unknown.
if profile == "kometa":
    maintenance = state.setdefault("maintenance", {"schema": 1, "trackingSince": now, "issues": {}, "runs": [], "dropped": 0})
    if maintenance.get("schema") != 1:
        raise ValueError("Unsupported maintenance catalogue")
    maintenance["lastScanAt"] = now

def maintenance_scope(context):
    return hashlib.sha256(json.dumps(context, sort_keys=True).encode()).hexdigest()[:24]

def maintenance_context(run, banner):
    if profile != "kometa":
        return
    ctx = run.setdefault("maintenanceContext", {})
    loaded = re.match(r"Loading (Collection|Overlay|Metadata|Playlist) File(?:\s+\d+)?(?: File)?:\s*(.+)$", banner)
    external = re.match(r"Loading (Collection|Overlay|Metadata|Playlist) File(?:\s+\d+)? (Default|URL|Git|Repo|Folder):\s*(.+)$", banner)
    library = re.match(r"(?:Loading (?:All .+ from )?Library:|Library:)\s*(.+)$", banner)
    library_banner = re.fullmatch(r"(.+?) Library", banner)
    started = re.fullmatch(r"Running (.+) (Collection|Overlay|Playlist)", banner)
    finished = re.fullmatch(r"Finished (.+) (Collection|Overlay|Playlist)", banner)
    finished_library = re.fullmatch(r"Finished (.+) Library", banner)
    if banner in ("Error Summary", "Warning Summary", "Critical Summary"):
        run["maintenanceSummary"] = True
    if loaded:
        kind, path = loaded.groups()
        ctx = {"library": "", "file": redact(path, 300), "kind": "file", "item": ""}
        run["maintenanceLoaded"] = list(dict.fromkeys(run.get("maintenanceLoaded", []) + [maintenance_scope(ctx)]))[-512:]
    elif external:
        kind, origin, value = external.groups()
        ctx = {"library": "", "file": origin.lower()+":"+redact(value, 260), "kind": "file", "item": ""}
        run["maintenanceLoaded"] = list(dict.fromkeys(run.get("maintenanceLoaded", []) + [maintenance_scope(ctx)]))[-512:]
    elif library:
        ctx = {"library": redact(library.group(1), 180), "file": "", "kind": "library", "item": ""}
    elif library_banner and not re.match(r"(?:Mapping|Loading|Finished|No |Metadata Backup|Scanning|Connecting|Processing|Running)\b", banner):
        ctx = {"library": redact(library_banner.group(1), 180), "file": "", "kind": "library", "item": ""}
    elif started:
        item, kind = started.groups()
        # Previously loaded metadata/overlay files are not necessarily this
        # collection's source file. Do not carry that path across phases.
        ctx = {"library": ctx.get("library", ""), "file": "", "kind": kind.lower(), "item": redact(item, 220)}
    elif finished:
        item, kind = finished.groups()
        if ctx.get("kind") == kind.lower() and ctx.get("item") == redact(item, 220):
            run["maintenanceDone"] = list(dict.fromkeys(run.get("maintenanceDone", []) + [maintenance_scope(ctx)]))[-512:]
        ctx = {"library": ctx.get("library", ""), "file": "", "kind": "library", "item": ""}
    if finished_library and ctx.get("library")==finished_library.group(1):
        library_context = {"library": ctx["library"], "file": "", "kind": "library", "item": ""}
        run["maintenanceDone"] = list(dict.fromkeys(run.get("maintenanceDone", []) + [maintenance_scope(library_context)]))[-512:]
    run["maintenanceContext"] = ctx

def maintenance_finding(run, level, message, epoch):
    if profile != "kometa" or run.get("maintenanceSummary") or run.get("mode") != "normal":
        return
    message = redact(message, 900)
    if not message.strip(" |-=*\t"):
        return
    ctx = copy.deepcopy(run.get("maintenanceContext", {}))
    normalized = re.sub(r"\b\d+(?:\.\d+)?\s*(?:milliseconds|seconds|minutes|ms)\b", "<duration>", message, flags=re.I)
    key = hashlib.sha256((maintenance_scope(ctx) + normalized).encode()).hexdigest()[:24]
    findings = run.setdefault("maintenanceFindings", {})
    if key not in findings and len(findings) >= 128:
        run["maintenanceDropped"] = run.get("maintenanceDropped", 0) + 1
        return
    issue = findings.setdefault(key, {"id": key, "message": message, "context": ctx, "scope": maintenance_scope(ctx),
                                     "severity": level, "firstSeen": epoch, "lastSeen": epoch, "occurrences": 0})
    issue["lastSeen"] = epoch
    issue["occurrences"] += 1
    if level in ("FATAL", "CRITICAL", "ERROR"):
        issue["severity"] = level

def maintenance_finish(run, epoch):
    if profile != "kometa" or not run.get("full") or run.get("mode") != "normal":
        return
    catalogue = state["maintenance"]
    issues = catalogue["issues"]
    run_id = str(run["startedAt"]) + ":" + str(epoch)
    catalogue["runs"] = [r for r in catalogue.get("runs", []) if r["id"] != run_id]
    catalogue["runs"].append({"id": run_id, "started": run["startedAt"], "finished": epoch,
                              "complete": not state.get("gap", False), "result": outcome(run)})
    catalogue["runs"] = sorted([r for r in catalogue["runs"] if r["finished"] >= now - 21*86400], key=lambda r: r["finished"])[-150:]
    findings = run.get("maintenanceFindings", {})
    scopes_with_findings = {issue["scope"] for issue in findings.values()}
    for key, value in findings.items():
        entry = issues.setdefault(key, {**copy.deepcopy(value), "affectedRuns": [], "resolvedAt": 0, "cleanRuns": []})
        entry["lastSeen"] = max(entry.get("lastSeen", 0), value["lastSeen"])
        entry["firstSeen"] = min(entry.get("firstSeen", value["firstSeen"]), value["firstSeen"])
        entry["severity"] = value["severity"]
        entry["affectedRuns"] = sorted(set(entry.get("affectedRuns", []) + [run["startedAt"]]))[-150:]
        entry["resolvedAt"] = 0
        entry["cleanRuns"] = []
        entry["occurrencesInLatestRun"] = value["occurrences"]
    done = set(run.get("maintenanceDone", []))
    if not run.get("findings", {}).get("errors") and not run.get("findings", {}).get("fatal"):
        done.update(run.get("maintenanceLoaded", []))
    if not state.get("gap") and not run.get("maintenanceDropped"):
        for key, entry in issues.items():
            if key not in findings and entry.get("scope") in done and entry["scope"] not in scopes_with_findings and epoch > entry["lastSeen"]:
                entry["cleanRuns"] = sorted(set(entry.get("cleanRuns", []) + [run["startedAt"]]))[-2:]
                if len(entry["cleanRuns"]) >= 2 and not entry.get("resolvedAt"):
                    entry["resolvedAt"] = epoch
    catalogue["dropped"] = catalogue.get("dropped", 0) + run.get("maintenanceDropped", 0)
    catalogue["issues"] = {key: entry for key, entry in issues.items() if not entry.get("resolvedAt") or entry.get("resolvedAt", 0) >= now - 21*86400}
    if len(catalogue["issues"]) > 256:
        ordered = sorted(catalogue["issues"], key=lambda key: catalogue["issues"][key]["lastSeen"], reverse=True)
        catalogue["dropped"] += len(ordered) - 256
        catalogue["issues"] = {key: catalogue["issues"][key] for key in ordered[:256]}

def finish(run, epoch):
    if run["mode"] != "normal":
        return
    result = outcome(run)
    maintenance_finish(run, epoch)
    state["completed"] = {"startedAt": run["startedAt"], "finishedAt": epoch,
                          "result": result, "findings": copy.deepcopy(run["findings"])}
    if result == "success":
        state["successfulAt"] = epoch
    elif state["successfulAt"] == epoch:
        state["successfulAt"] = run["previousSuccess"]
    if run["full"]:
        state["gap"] = False
    run["closed"] = True

def consume(raw):
    text = ansi.sub("", raw.decode("utf-8", errors="replace")).rstrip("\r\n")
    match = record.match(text)
    if not match:
        if re.match(r"^\[\d{4}-\d\d-\d\d ", text):
            state["gap"] = True
            if state.get("active"):
                state["active"]["full"] = False
        return
    stamp, bracket_level, bare_level, message = match.groups()
    level = bracket_level or bare_level
    epoch = timestamp(stamp)
    if not 0 < epoch <= now + 300:
        state["gap"] = True
        state.setdefault("active", new_run())["full"] = False
        return
    message = message.strip().strip("|").strip()
    banner = message.strip(" =-*\t")
    run = state.get("active")
    if run is None:
        state["active"] = run = new_run()
    if profile == "kometa" and re.fullmatch(r"Starting (?:\d{1,2}:\d{2} )?Run", banner):
        prelude = run["findings"] if not run["startedAt"] else None
        previous = run
        state["active"] = run = new_run(epoch, True, prelude=prelude)
        if not previous["startedAt"]:
            for key in ("maintenanceContext", "maintenanceFindings", "maintenanceLoaded", "maintenanceDropped"):
                if key in previous:
                    run[key] = previous[key]
    elif profile == "kometa" and re.fullmatch(r"Starting .+ Run", banner):
        state["active"] = run = new_run(epoch, False, "excluded")
    elif profile == "imagemaid" and banner == "Validating Options":
        state["active"] = run = new_run(epoch, True, prelude=run["findings"] if not run["startedAt"] else None)
    elif profile == "imagemaid" and banner == "Script Started" and not run["startedAt"]:
        run.update(startedAt=epoch, full=True)
    if profile == "imagemaid" and banner in ("Error Report", "Critical Report", "Warning Report"):
        run["summary"] = True
    elif profile == "imagemaid" and banner == "ImageMaid Summary":
        run["summary"] = False
    if level == "INFO":
        maintenance_context(run, banner)
    if level in ("WARNING", "WARN", "ERROR", "CRITICAL", "FATAL") and not run["summary"]:
        maintenance_finding(run, level, message, epoch)
        finding(run, level, message)
        if run["closed"]:
            finish(run, state["completed"].get("finishedAt", epoch))
    terminal = (profile == "kometa" and re.fullmatch(r"Finished (?:\d{1,2}:\d{2} )?Run", banner)) or (profile == "imagemaid" and banner == "ImageMaid Finished")
    if terminal:
        run["terminal"] = True
    footer = (profile == "kometa" and banner.startswith("Start Time:") and "Finished:" in banner and "Run Time:" in banner) or (profile == "imagemaid" and re.match(r"Total Runtime\s*\|", banner))
    if footer and run["terminal"] and not run["closed"]:
        finish(run, epoch)

def identity(path):
    value = os.stat(path, follow_symlinks=False)
    if not stat.S_ISREG(value.st_mode):
        raise ValueError("Native log must be a regular file")
    return f"{value.st_dev}:{value.st_ino}", value.st_size

def anchors(handle, offset):
    handle.seek(0)
    head = handle.read(min(offset, 128))
    handle.seek(max(0, offset - 256))
    tail = handle.read(min(offset, 256))
    return hashlib.sha256(head).hexdigest(), hashlib.sha256(tail).hexdigest()

stem, extension = os.path.splitext(source)
paths = [f"{stem}-{number}{extension}" for number in range(9, 0, -1)] + [source]
files = [(path, *identity(path)) for path in paths if os.path.lexists(path)]
if not files or files[-1][0] != source:
    raise ValueError("Current native log is unavailable")
cursor = state.get("cursor", {})
index = next((i for i, item in enumerate(files) if item[1] == cursor.get("identity")), None)
if index is None:
    if cursor:
        state["gap"] = True
    # Bootstrap the previous run as well, so a currently running job does not
    # hide the most recent completed result. Never scan all nine old runs.
    files = files[-2:]
    state.pop("active", None)
    cursor = {}
else:
    files = files[index:]

backlog = False
for path, expected, snapshot_size in files:
    if budget <= 0 or time.monotonic() >= deadline:
        backlog = True
        break
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as handle:
        current = os.fstat(handle.fileno())
        if f"{current.st_dev}:{current.st_ino}" != expected:
            raise ValueError("Native log rotated during discovery; retry")
        offset = int(cursor.get("offset", 0)) if cursor.get("identity") == expected else 0
        if offset and (offset > snapshot_size or anchors(handle, offset) != (cursor.get("head"), cursor.get("tail"))):
            offset = 0
            state["gap"] = True
            state.pop("active", None)
        if not offset:
            state.pop("active", None)
        handle.seek(offset)
        while offset < snapshot_size and budget > 0 and time.monotonic() < deadline:
            raw = handle.readline(min(65537, budget + 1, snapshot_size - offset))
            if not raw or not raw.endswith(b"\n"):
                # Do not consume a partially written line or a split chunk.
                if len(raw) > 65536:
                    raise ValueError("Native log line exceeds safe parse limit")
                break
            consume(raw)
            offset += len(raw)
            budget -= len(raw)
        head, tail = anchors(handle, offset)
        cursor = {"identity": expected, "offset": offset, "head": head, "tail": tail}
        state["cursor"] = cursor
        if offset < snapshot_size:
            backlog = True
            break
    # A later rotated/current file is a distinct run; its prelude must not
    # inherit warnings/errors from this file.
    if path != source:
        state.pop("active", None)
state["backlog"] = backlog
completed = state["completed"]
active = state.get("active", {})
started = active.get("startedAt", 0) if active.get("mode") == "normal" else 0
print(json.dumps({"reader": state, "started": max(started, completed.get("startedAt", 0)),
                  "finished": completed.get("finishedAt", 0), "success": state["successfulAt"],
                  "result": completed.get("result", "unknown"), "backlog": backlog,
                  "incomplete": state["gap"] or not (started or completed),
                  "findings": completed.get("findings", {}),
                  "activeFatal": active.get("findings", {}).get("fatal", {}) if not active.get("closed") and active.get("mode") == "normal" else {}}))
PY
)" || return 1
    printf '%s' "$context" | docker_cmd exec -i "$name" python3 -c "$program" "$profile" "$path" "$JOB_LOG_SCAN_MAX_BYTES" "$NOW" "$id"
}

job_deadlines() {
    local name="$1" first="$2" started="$3" finished="$4" max_age="$5" runtime="$6" stamp="$4"
    if (( started > finished && runtime > 0 && NOW - started > runtime * 3600 )); then
        observe "$name:job-overrun" CRITICAL "Scheduled job exceeded configured ${runtime}h runtime limit" || return 1
    fi
    (( stamp > 0 )) || stamp="$first"
    if (( max_age > 0 && NOW - stamp > max_age * 3600 )); then
        observe "$name:job-overdue" CRITICAL "No completed scheduled run within ${max_age}h (schedule plus grace); last known completion/start used even when new log evidence is incomplete" || return 1
    fi
}

check_job() {
    local name="$1" info="$2" profile rule max_age runtime source file started=0 finished=0 success=0 result=unknown
    local old first old_finished old_success scan since line stamp read_error=false rc key frequency min_runs hours count receipt_history='[]' log_state='{}' run_log='{}' findings='{}' detail="" retract_success=false replace_unverified=false
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
        runlog:*)
            if read_native_run_log "$name" "$profile" "${source#runlog:}" "$info" "$old" >"$file" 2>/dev/null &&
                jq -e 'type == "object" and (.reader | type == "object" and .version == 1) and
                    (.started | type == "number" and . >= 0 and . == floor) and
                    (.finished | type == "number" and . >= 0 and . == floor) and
                    (.success | type == "number" and . >= 0 and . == floor) and
                    (.backlog | type == "boolean") and (.incomplete | type == "boolean") and
                    (.findings | type == "object") and (.activeFatal | type == "object") and
                    (.result | IN("unknown", "success", "failed", "completed-errors", "completed-warnings", "completed-unverified"))' "$file" >/dev/null; then
                run_log="$(jq -c .reader "$file")"
                mutate --arg name "$name" --slurpfile evidence "$file" --argjson now "$NOW" \
                    '.jobs //= {} | .jobs[$name] = ((.jobs[$name] // {firstSeen:$now,started:0,finished:0,success:0,result:"unknown",scanned:$now,logState:{},history:[]}) | .runLog=$evidence[0].reader)' || return 1
                if [[ "$(jq -r .backlog "$file")" == true ]]; then
                    log INFO "$name: native-log scan in progress; saved cursor, retaining previous job findings" || return 1
                    job_deadlines "$name" "$first" "$(jq -r '.started // 0' <<<"$old")" "$old_finished" "$max_age" "$runtime" || return 1
                    while IFS= read -r key; do FROZEN_KEYS["$key"]=1; done < <(jq -r --arg prefix "$name:job-" '.observations | keys[] | select(startswith($prefix))' "$STATE_WORK")
                    return 0
                fi
                started="$(jq -r .started "$file")"; finished="$(jq -r .finished "$file")"
                success="$(jq -r .success "$file")"; result="$(jq -r .result "$file")"
                findings="$(jq -c .findings "$file")"
                detail="$(jq -r '"Distinct recorded reasons (capped at 32 per severity): fatal=\((.fatal.keys // []) | length), errors=\((.errors.keys // []) | length), warnings=\((.warnings.keys // []) | length). " +
                    ([.fatal.examples[]?, .errors.examples[]?, .warnings.examples[]?] | .[0:5] | join("; "))' <<<"$findings")"
                if [[ "$(jq -r '(.activeFatal.keys // []) | length > 0' "$file")" == true ]]; then
                    observe "$name:job-fatal" CRITICAL "Active native run logged a fatal failure: $(jq -r '.activeFatal.examples | join("; ")' "$file"); processing failure does not trigger a container restart" || return 1
                fi
                [[ "$(jq -r .incomplete "$file")" != true ]] || read_error=true
            else read_error=true; fi ;;
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
                docker_cmd logs --timestamps --since "$since" --tail 2000 "$name" 2>&1 | command tail "-c$JOB_READ_MAX_BYTES" >"$file"; rc=$?
            else
                docker_cmd exec "$name" tail "-c$JOB_READ_MAX_BYTES" -- "${source#log:}" >"$file" 2>/dev/null; rc=$?
            fi
            if (( rc != 0 )); then read_error=true
            else
                sed -E $'s/\033\\[[0-9;]*[[:alpha:]]//g' "$file" >"$file.clean" && mv -f -- "$file.clean" "$file" || return 1
                if [[ "$profile" == recyclarr ]]; then
                    parse_recyclarr_log "$file" "$info" "$old" || return 1
                    started="$JOB_LOG_STARTED"; finished="$JOB_LOG_FINISHED"; success="$JOB_LOG_SUCCESS"; result="$JOB_LOG_RESULT"
                    receipt_history="$JOB_LOG_HISTORY"; log_state="$JOB_LOG_STATE"
                else
                # Only a whole-run banner counts. Collection/playlist/test-run
                # banners do not. A banner proves completion, not success.
                if [[ "$profile" == kometa ]]; then
                    stamp="$(grep -E 'Starting ([0-9]{1,2}:[0-9]{2} )?Run[[:space:]|=]*$' "$file" | command tail -n1 || true)"
                    stamp="${stamp%% *}"
                    [[ ! "$stamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || started="$(epoch_value "$stamp")"
                    line="$(grep -E 'Finished ([0-9]{1,2}:[0-9]{2} )?Run[[:space:]|=]*$' "$file" | command tail -n1 || true)"
                elif [[ "$profile" == imagemaid ]]; then
                    stamp="$(grep -E 'Script Started' "$file" | command tail -n1 || true)"; stamp="${stamp%% *}"
                    [[ ! "$stamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || started="$(epoch_value "$stamp")"
                    line="$(grep -E 'ImageMaid Finished' "$file" | command tail -n1 || true)"
                else line=""; fi
                stamp="${line%% *}"
                if [[ "$stamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then finished="$(epoch_value "$stamp")"; fi
                if (( finished > 0 )); then result=completed-unverified; fi
                fi
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
        observe "$name:job-evidence" WARNING "Job completion evidence unavailable/invalid; source=$source requires review" || return 1
        if [[ "$source" == runlog:* ]]; then
            job_deadlines "$name" "$first" "$(jq -r '.started // 0' <<<"$old")" "$old_finished" "$max_age" "$runtime" || return 1
        fi
        # Keep the last valid evidence; never clear a failure from a bad read.
        while IFS= read -r key; do FROZEN_KEYS["$key"]=1; done < <(jq -r --arg prefix "$name:job-" '.observations | keys[] | select(startswith($prefix))' "$STATE_WORK")
        # Missing run logs cannot mask a Docker availability/health failure.
        # Job evidence never authorizes restarts; Docker recovery has its own
        # permissions, thresholds, maintenance leases and post-restart checks.
        [[ "$source" == runlog:* ]] || RECOVERY_BLOCKED["$name"]=1
        return 0
    fi
    # Docker's receive timestamp can be a few seconds after the native footer.
    # Permit the first complete native result to replace a nearby legacy banner
    # result, including errors; never apply this exception to a prior failure.
    if [[ "$source" == runlog:* && "$result" != unknown && "$result" != completed-unverified &&
        "$(jq -r '.result // "unknown"' <<<"$old")" == completed-unverified &&
        "$(jq -r '.evidenceSource // ""' <<<"$old")" != "$source" ]] &&
        (( finished > 0 && old_finished >= finished && old_finished - finished <= 300 )); then
        replace_unverified=true
    fi
    if [[ "$result" == unknown ]] || { [[ "$replace_unverified" == false ]] && (( finished > 0 && finished < old_finished )); }; then
        result="$(jq -r '.result // "unknown"' <<<"$old")"
    fi
    if [[ "$(jq -r '.result // "unknown"' <<<"$old")" == failed ]] && (( finished <= old_finished )); then
        result=failed
    fi
    (( started > 0 )) || started="$(jq -r '.started // 0' <<<"$old")"
    [[ "$replace_unverified" == true ]] || { (( finished >= old_finished )) || finished="$old_finished"; }
    if [[ "$source" == runlog:* && "$result" != success ]] && (( finished > 0 && finished == old_success && success < old_success )); then
        # A notification/report error appended after the footer can revise the
        # same run. Do not keep its earlier clean timestamp as verified success.
        retract_success=true
    else
        (( success >= old_success )) || success="$old_success"
    fi
    printf '%s' "$run_log" >"$TMP_DIR/$name.reader.json" || return 1
    mutate --arg name "$name" --arg result "$result" --argjson first "$first" --argjson started "$started" \
        --argjson finished "$finished" --argjson success "$success" --argjson scanned "$NOW" --argjson receipt_history "$receipt_history" --argjson log_state "$log_state" \
        --slurpfile run_log_file "$TMP_DIR/$name.reader.json" --argjson retract "$retract_success" --arg evidence_source "$source" \
        '$run_log_file[0] as $run_log | .jobs //= {} | (.jobs[$name].history // []) as $history |
            .jobs[$name]={firstSeen:$first,started:$started,finished:$finished,success:$success,result:$result,scanned:$scanned,logState:$log_state,runLog:$run_log,evidenceSource:$evidence_source,
                history:(($history + $receipt_history + (if $result == "success" and $success > 0 then [$success] else [] end)) | unique | map(select(. >= ($scanned - 28*86400) and (($retract | not) or . != $finished))))}' || return 1
    if [[ "$result" == failed ]]; then
        local error_detail=""
        if [[ "$source" == native:* ]]; then
            error_detail="$(jq -r '(.last_error // "No failure detail recorded") | tostring |
                gsub("(?i)authorization[=: ]+(bearer[ ]+|basic[ ]+)?[^ ,;\\r\\n]+"; "authorization=[REDACTED]") |
                gsub("(?i)https?://[^/@[:space:]]+@"; "[URL-CREDENTIALS-REDACTED]@") |
                gsub("(?i)(api[_-]?key|token|password|authorization)[=: ]+[^ ,;\\n]+"; "[REDACTED]") |
                gsub("[\\r\\n]"; " ") | .[0:500]' "$file")"
        elif [[ "$source" == runlog:* ]]; then
            error_detail="Native run logged a fatal failure. $detail; log=${source#runlog:}"
        fi
        observe "$name:job-failed" CRITICAL "Most recent scheduled job failed; finished_epoch=$finished; last_success_epoch=$success. ${error_detail:-Review the scheduled job log or completion record.} Container availability is checked separately" || return 1
    fi
    if [[ "$source" == runlog:* ]]; then
        if (( started > finished )); then
            log INFO "$name: native scheduled run active; started_epoch=$started; previous_completion_epoch=$finished; previous_result=$result" || return 1
        fi
        if [[ "$result" == completed-errors ]]; then
            observe "$name:job-errors" WARNING "Run completed with processing errors; finished_epoch=$finished. $detail; log=${source#runlog:}. Docker availability is checked separately" || return 1
        elif [[ "$result" == completed-warnings ]]; then
            observe "$name:job-warnings" WARNING "Run completed with warnings; finished_epoch=$finished. $detail; log=${source#runlog:}" || return 1
        elif [[ "$result" == success ]] && (( started <= finished )); then
            log INFO "$name: native run completed without reported errors or warnings; finished_epoch=$finished; log=${source#runlog:}" || return 1
        fi
    fi
    if [[ "$result" == completed-unverified && "$REQUIRE_VERIFIED_JOB_SUCCESS" == true ]]; then
        observe "$name:job-unverified" WARNING "Whole-run completion banner observed; success not established. Configure a producer receipt to verify outcome" || return 1
    fi
    job_deadlines "$name" "$first" "$started" "$finished" "$max_age" "$runtime" || return 1
    for frequency in "${JOB_FREQUENCY_RULES[@]}"; do
        IFS='|' read -r key min_runs hours <<<"$frequency"
        [[ "$key" == "$profile" ]] || continue
        if (( NOW - first >= hours * 3600 )); then
            count="$(jq -r --arg name "$name" --argjson cutoff "$((NOW - hours * 3600))" '[.jobs[$name].history[] | select(. >= $cutoff)] | length' "$STATE_WORK")"
            if (( count < min_runs )); then observe "$name:job-frequency" CRITICAL "Only $count successful runs observed in ${hours}h; expected at least $min_runs" || return 1; fi
        fi
    done
}

# SERVICE_SPECS are reusable installed-app profiles, not a required container list.
# A complete Docker inventory is required before retiring an absent app. Daemon
# errors freeze existing observations and never imply uninstall/recovery.
retire_inventory_service() {
    local name="$1" scans
    mutate --arg name "$name" --argjson now "$NOW" '.inventory //= {} | .inventory[$name]=((.inventory[$name] // {})+{missing:((.inventory[$name].missing // 0)+1),checkedAt:$now})' || return 1
    scans=$(jq -r --arg name "$name" '.inventory[$name].missing' "$STATE_WORK")
    FROZEN["$name"]=1
    ((scans>=2)) || return 0
    mutate --arg name "$name" --argjson now "$NOW" '
      if (.inventory[$name].retiredAt // 0)==0 then
        .inventory[$name].retiredAt=$now |
        .inventoryOutbox //= {} | .inventoryOutbox[$name]={at:$now,message:("Removed from complete Docker inventory on two observations; monitoring retired. No container recreated; prior alerts closed as retired, not recovered.")} |
        .observations |= with_entries(if (.key|startswith($name+":")) then .value.active=false|.value.retired=true else . end) |
        del(.services[$name],.recovery[$name],.jobs[$name],.flapping[$name])
      else . end' || return 1
}

# Read-only scheduler evidence. A scheduler can be healthy while its last job
# reported findings; job outcome remains monitored separately. Update readiness
# additionally requires an idle job so a native recreation does not interrupt it.
scheduler_readiness() {
    local name="$1" purpose="$2" processes file profile="$1"
    processes=$(docker_cmd top "$name" -eo pid,comm,args) || return 1
    if [[ "$name" == recyclarr ]];then
      grep -q 'supercronic' <<<"$processes" || return 1
      docker_cmd exec "$name" sh -c 'test -r /tmp/crontab && recyclarr --version >/dev/null' >/dev/null 2>&1 || return 1
      if [[ "$purpose" == update ]] && grep -Eq '(^|[ /])(cron\.sh|recyclarr[[:space:]]+sync)([[:space:]]|$)' <<<"$processes";then
        jq -n '{ready:false,classification:"busy",source:"native-scheduler",detail:"Recyclarr scheduled sync is active; update deferred"}'
      else jq -n '{ready:true,classification:"ready",source:"native-scheduler",detail:"Recyclarr cron scheduler, crontab and application binary verified; job outcome is monitored separately"}';fi
      return
    fi
    case "$name" in kometa) file=/config/logs/meta.log;;imagemaid) file=/config/logs/imagemaid.log;;*) return 1;;esac
    grep -Eq "(^|[ /])$name\\.py([[:space:]]|$)" <<<"$processes" || return 1
    docker_cmd exec -i "$name" python3 - "$profile" "$file" "$purpose" <<'PY'
import datetime, json, os, re, stat, sys, time
from zoneinfo import ZoneInfo
profile, path, purpose = sys.argv[1:]
fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
with os.fdopen(fd,'rb') as f:
    info=os.fstat(f.fileno());assert stat.S_ISREG(info.st_mode)
    assert 0 <= time.time()-info.st_mtime <= (6 if profile=='kometa' else 120)*3600
    head=f.read(65536).decode('utf-8','replace')
    f.seek(max(0,info.st_size-262144));tail=f.read(262144).decode('utf-8','replace')
zone=ZoneInfo('Asia/Singapore')
def stamp(line):
    m=re.match(r'\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})',line)
    return datetime.datetime.strptime(m[1],'%Y-%m-%d %H:%M:%S').replace(tzinfo=zone).timestamp() if m else 0
started=finished=0;runtime=False
for line in (head+'\n'+tail).splitlines():
    t=stamp(line)
    if profile=='kometa':
        if re.search(r'\|\s*Starting (?:\d{2}:\d{2} )?Run\s*\|',line):started=max(started,t)
        if re.search(r'Start Time:.*Finished:.*Run Time:',line):finished=max(finished,t);runtime=True
    else:
        if 'Validating Options' in line:started=max(started,t)
        if 'ImageMaid Finished' in line:finished=max(finished,t)
        if 'Total Runtime' in line:runtime=True
assert started>0,'Native run start is not recognized'
idle=runtime and finished>=started
ready=idle if purpose=='update' else True
print(json.dumps({'ready':bool(ready),'classification':'ready' if ready else 'busy','source':'native-scheduler',
 'detail':('Scheduler process and native whole-run completion verified; job findings remain independently monitored' if idle else 'Native scheduled job is active or completion is unproven; update deferred')}))
PY
}

plex_sessions_summary() {
    # Parse only decisions/counts; never print session titles, users or tokens.
    php -r '
      $x=@simplexml_load_string(stream_get_contents(STDIN),"SimpleXMLElement",LIBXML_NONET);
      if(!$x||$x->getName()!=="MediaContainer"||!isset($x["size"])||!preg_match("/^[0-9]+$/",(string)$x["size"]))exit(1);
      $total=0;$transcodes=0;$remux=0;$unknown=0;
      foreach($x->children() as $session){
        if(!in_array($session->getName(),["Video","Track","Photo"],true)){ $unknown++;continue; }
        $total++;$transcode=false;$copy=false;$uncertain=false;
        foreach($session->xpath(".//TranscodeSession|.//Media|.//Stream") as $node){
          $isTranscode=$node->getName()==="TranscodeSession";$decisions=[];
          foreach(["videoDecision","audioDecision"] as $key)if(isset($node[$key]))$decisions[]=(string)$node[$key];
          if($node->getName()==="Stream" && in_array((string)$node["streamType"],["1","2"],true) && isset($node["decision"]))$decisions[]=(string)$node["decision"];
          if($isTranscode && !$decisions)$uncertain=true;
          foreach($decisions as $decision){
            $d=strtolower(str_replace([" ","_","-"],"",$decision));
            if($d==="transcode")$transcode=true;
            elseif(!in_array($d,["copy","directplay","directstream","none"],true))$uncertain=true;
          }
          if($isTranscode && $decisions && !$transcode && !$uncertain)$copy=true;
        }
        if($transcode)$transcodes++;elseif($uncertain)$unknown++;elseif($copy)$remux++;
      }
      if($total!==(int)$x["size"])exit(1);
      $processes=(int)$argv[1];$background=max(0,$processes-$transcodes-$remux);
      $ready=$transcodes===0 && $background===0 && $unknown===0;
      echo json_encode(["ready"=>$ready,"classification"=>$ready?"ready":($unknown?"unverified":"busy"),"source"=>"plex-transcode-activity","sessions"=>$total,"transcodingSessions"=>$transcodes,"directStreamSessions"=>$remux,"backgroundTranscoders"=>$background,"unverifiedSessions"=>$unknown,
        "detail"=>$unknown?"Plex playback/transcode decisions are incomplete; update deferred":($ready?"No audio/video transcoding; ".($total-$remux)." direct-play and ".$remux." direct-stream session(s) allowed; playback may briefly reconnect during update":$transcodes." transcoding session(s), ".$background." background transcoder(s); update deferred")]);
    ' "$1"
}
plex_update_readiness() {
    local name="$1" processes output
    output=$(docker_cmd top "$name" -eo pid,comm) || return 1
    processes=$(awk 'NR>1 && /Plex Transcoder/ {n++} END {print n+0}' <<<"$output")
    docker_cmd exec "$name" sh -c '
      token=$(sed -n "s/.*PlexOnlineToken=\"\([^\"]*\)\".*/\1/p" "/config/Library/Application Support/Plex Media Server/Preferences.xml")
      case "$token" in ""|*[!A-Za-z0-9_-]*) exit 1;;esac
      printf "header = \"X-Plex-Token: %s\"\n" "$token" | curl --config - --silent --fail --noproxy "*" --max-time 5 --max-filesize 262144 http://127.0.0.1:32400/status/sessions' 2>/dev/null | plex_sessions_summary "$processes"
}

arr_activity_summary() {
    jq -e '
      if (.commands|type)!="array" or (.queue.records|type)!="array" or (.queue.totalRecords|type)!="number" or .queue.totalRecords>(.queue.records|length) then error("Incomplete Arr activity evidence") else . end |
      [.commands[]|select((.status|ascii_downcase)=="started" or (.status|ascii_downcase)=="queued" or (.status|ascii_downcase)=="running")] as $commands |
      [.queue.records[]|select((.trackedDownloadState // ""|ascii_downcase)=="importing" or (.trackedDownloadState // ""|ascii_downcase)=="processing")] as $imports |
      {ready:($commands|length)==0 and ($imports|length)==0,classification:(if ($commands|length)+($imports|length)>0 then "busy" else "ready" end),source:"native-arr-activity",activeCommands:($commands|length),activeImports:($imports|length),detail:(if ($commands|length)+($imports|length)>0 then "Native Arr command/import operation active; update deferred until completion" else "Native Arr command/import activity idle; queued downloads and import warnings alone do not block updates" end)}'
}
arr_update_readiness() {
    local name="$1"
    # Arr images need only their existing shell/curl; credentials stay inside
    # the container and are supplied through curl stdin, never process arguments.
    docker_cmd exec "$name" sh -c '
      config=/config/config.xml
      key=$(sed -n "s:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p" "$config")
      port=$(sed -n "s:.*<Port>\([^<]*\)</Port>.*:\1:p" "$config")
      base=$(sed -n "s:.*<UrlBase>\([^<]*\)</UrlBase>.*:\1:p" "$config")
      case "$key" in ""|*[!a-zA-Z0-9]*) exit 1;;esac
      case "$port" in ""|*[!0-9]*) exit 1;;esac
      fetch(){ printf "header = \"X-Api-Key: %s\"\n" "$key" | curl --config - --noproxy "*" --silent --fail --connect-timeout 3 --max-time 6 --max-filesize 4194304 "$1"; }
      for version in v3 v5;do
        url="http://127.0.0.1:$port${base%/}/api/$version"
        commands=$(fetch "$url/command") || continue
        queue=$(fetch "$url/queue?page=1&pageSize=1000&includeUnknownMovieItems=true&includeUnknownSeriesItems=true") || exit 1
        printf "{\"commands\":%s,\"queue\":%s}\n" "$commands" "$queue"
        exit 0
      done
      exit 1' | arr_activity_summary
}


sab_readiness() {
    local purpose="$1"
    docker_cmd exec -i sabnzbd /lsiopy/bin/python3 - "$purpose" <<'PY'
import configobj,json,sys,urllib.parse,urllib.request
c=configobj.ConfigObj('/config/sabnzbd.ini',interpolation=False)['misc']
q=urllib.parse.urlencode({'mode':'queue','output':'json','apikey':c['api_key'],'limit':1000})
url='http://127.0.0.1:'+str(c.get('port',8080))+'/api?'+q
with urllib.request.urlopen(url,timeout=5) as r:d=json.load(r)['queue']
assert isinstance(d,dict) and isinstance(d.get('status'),str) and isinstance(d.get('slots'),list)
busy=d['status'].lower()=='downloading' or any(str(s.get('status','')).lower() not in ('queued','paused','completed') for s in d['slots'])
# SAB can post-process while downloads are paused; the native history endpoint
# includes these jobs even when there is no currently downloading queue item.
q=urllib.parse.urlencode({'mode':'history','output':'json','apikey':c['api_key'],'limit':1000})
with urllib.request.urlopen('http://127.0.0.1:'+str(c.get('port',8080))+'/api?'+q,timeout=5) as r:h=json.load(r)['history']
assert isinstance(h.get('slots'),list)
busy=busy or any(str(s.get('status','')).lower() not in ('completed','failed','deleted','queued') for s in h['slots'])
ready=not busy if sys.argv[1]=='update' else True
print(json.dumps({'ready':ready,'classification':'ready' if ready else 'busy','source':'native-sab-api','detail':'Authenticated SAB queue/history verified; active download or post-processing defers installation' if ready else 'SAB download/post-processing active; update deferred'}))
PY
}

vpn_readiness_json() (
    local reason=''
    log(){ :; }
    vpn_finding(){ reason+="$3 "; }
    check_vpn_egress "$1" || reason+='VPN verification could not complete. '
    jq -n --arg reason "$reason" '{ready:($reason==""),classification:(if $reason=="" then "ready" else "unverified" end),source:"native-vpn",detail:(if $reason=="" then "Approved VPN exit node, binding, route and interface-bound egress verified" else $reason end)}'
)

readiness_json() {
    local name="$1" purpose="${2:-health}" info url='' spec health ready=false source=unverified detail='Application readiness unverified' result=unconfigured evidence=''
    valid_service_name "$name" || return 2
    TMP_DIR=$(mktemp -d /tmp/watchdog-readiness.XXXXXX) || return 1
    trap cleanup EXIT
    info=$(docker_cmd inspect "$name" 2>/dev/null) && inspect_valid "$info" || { jq -n --arg name "$name" '{schema:1,name:$name,ready:false,source:"inspection",detail:"Container inspection unavailable"}';return 0; }
    health=$(jq -r '.[0].State.Health.Status // "none"' <<<"$info")
    if jq -e '.[0].State.Running==true and .[0].State.OOMKilled==false and .[0].State.Paused==false' <<<"$info" >/dev/null;then
      if [[ "$health" == healthy ]];then ready=true;source=docker-health;detail='Docker application health is healthy';result=ready
      elif [[ "$health" == none ]];then
        for spec in "${SERVICE_SPECS[@]}";do [[ "${spec%%|*}" != "$name" ]] || { IFS='|' read -r _ url _ <<<"$spec";break; };done
        readiness_probe "$name" "$url" || true
        result="$PROBE_RESULT";detail="$PROBE_MESSAGE";source=application-probe
        [[ "$result" != ready ]] || ready=true
        if [[ "$name" == bazarr && "$ready" == false ]];then
          if docker_cmd exec bazarr sh -c 'for py in /lsiopy/bin/python3 /app/bazarr/bin/python3 python3;do if "$py" -c "import sys;sys.path[:0]=[\"/app/bazarr/bin/libs\",\"/app/bazarr/libs\"];import yaml" >/dev/null 2>&1;then exec "$py" -c "$1";fi;done;exit 1' _ 'import json, pathlib, urllib.request, sys
sys.path[:0]=["/app/bazarr/bin/libs","/app/bazarr/libs"]
import yaml
p=pathlib.Path("/config/config/config.yaml"); c=yaml.safe_load(p.read_text()); g=c.get("general",{}); key=c.get("auth",{}).get("apikey","")
assert isinstance(key,str) and key
base=(g.get("base_url") or "").rstrip("/")
u="http://127.0.0.1:"+str(g.get("port",6767))+base+"/api/system/status"
r=urllib.request.urlopen(urllib.request.Request(u,headers={"X-API-KEY":key}),timeout=5)
d=json.load(r);d=d.get("data",d);assert isinstance(d,dict) and d.get("bazarr_version")
' >/dev/null 2>&1;then ready=true;source=native-bazarr-api;detail='Bazarr authenticated native system status validated';result=ready;fi
        fi
        if [[ "$ready" == false ]];then
          case "$name" in
            kometa|imagemaid|recyclarr) evidence=$(scheduler_readiness "$name" "$purpose" 2>/dev/null) || evidence='{"ready":false,"classification":"unverified","source":"native-scheduler","detail":"Scheduler process/native completion evidence could not be verified; update deferred"}';;
            sabnzbd) evidence=$(sab_readiness "$purpose" 2>/dev/null) || evidence='{"ready":false,"classification":"unverified","source":"native-sab-api","detail":"Authenticated SAB queue/history could not be verified; update deferred"}';;
            photoprism)
              if docker_cmd exec photoprism curl --noproxy '*' --silent --fail --max-time 5 --max-filesize 65536 http://127.0.0.1:2342/api/v1/status 2>/dev/null | jq -e '.status=="operational"' >/dev/null;then
                evidence='{"ready":true,"classification":"ready","source":"native-photoprism-api","detail":"PhotoPrism native status is operational"}'
              else evidence='{"ready":false,"classification":"unverified","source":"native-photoprism-api","detail":"PhotoPrism native status API unavailable/unrecognized; update deferred"}';fi;;
          esac
        fi
      else detail="Docker health: $health";result="$health";fi
      if [[ "$purpose" == update && "$ready" == true ]];then
        case "$name" in
          kometa|imagemaid|recyclarr) [[ -n "$evidence" ]] || evidence=$(scheduler_readiness "$name" "$purpose" 2>/dev/null) || evidence='{"ready":false,"classification":"unverified","source":"native-scheduler","detail":"Scheduler readiness could not be verified"}';;
          sabnzbd) [[ -n "$evidence" ]] || evidence=$(sab_readiness "$purpose" 2>/dev/null) || evidence='{"ready":false,"classification":"unverified","source":"native-sab-api","detail":"SAB activity state could not be verified"}';;
          sonarr|radarr) evidence=$(arr_update_readiness "$name" 2>/dev/null) || evidence='{"ready":false,"classification":"unverified","source":"native-arr-activity","detail":"Native Arr command/import activity unavailable; update deferred"}';;
          plex-media|plex-media-server) evidence=$(plex_update_readiness "$name" 2>/dev/null) || evidence='{"ready":false,"classification":"unverified","source":"plex-sessions","detail":"Plex sessions could not be verified; update deferred"}';;
          metafusion)
            if ! docker_cmd exec metafusion cat /tmp/metafusion-status.json | jq -e '.state=="idle"' >/dev/null 2>&1;then evidence='{"ready":false,"classification":"busy","source":"native-metafusion","detail":"MetaFusion is active or idle state unavailable; update deferred"}';fi;;
          pihole)
            local transport answer
            for transport in udp tcp;do
              local -a dns_args=();[[ "$transport" != tcp ]] || dns_args=(+tcp)
              answer=$(timeout --kill-after=2 5 dig @"${UPDATE_FALLBACK_DNS:-192.168.50.100}" example.com A "${dns_args[@]}" +time=2 +tries=1 +noall +answer) || answer=''
              if ! grep -Eq '[[:space:]]IN[[:space:]]+A[[:space:]]+[0-9]' <<<"$answer";then evidence='{"ready":false,"classification":"unverified","source":"fallback-dns","detail":"Raspberry Pi fallback DNS did not answer both UDP and TCP; primary update deferred"}';fi
            done
            [[ -n "$evidence" ]] || evidence='{"ready":true,"classification":"ready","source":"dns-fallback","detail":"Pi-hole health and independent Raspberry Pi fallback DNS verified over UDP and TCP"}';;
        esac
      fi
      if [[ "$name" == qbittorrent && "$ready" == true ]];then evidence=$(vpn_readiness_json "$name") || evidence='';fi
      if [[ -n "$evidence" ]] && jq -e '(.ready|type)=="boolean" and (.detail|type)=="string"' <<<"$evidence" >/dev/null 2>&1;then
        ready=$(jq -r .ready <<<"$evidence");source=$(jq -r .source <<<"$evidence");detail=$(jq -r .detail <<<"$evidence");result=$(jq -r .classification <<<"$evidence")
      fi
    else detail='Container stopped, paused or OOM-killed';result=unavailable;fi
    jq -n --arg name "$name" --arg source "$source" --arg detail "$detail" --arg result "$result" --argjson ready "$ready" '{schema:1,name:$name,ready:$ready,source:$source,classification:$result,detail:$detail}'
}
valid_service_name(){ [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; }

resolve_inventory() {
    local names name spec profile url expected allowed alias primary actual info owned
    local -A present=() classified=() absence_handled=()
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
        if [[ -z "${present[$actual]+yes}" ]];then
            # Never-installed defaults are optional profiles. Previously observed
            # apps retire after confirmation; no permanent missing-app alarm.
            if jq -e --arg name "$actual" '.services[$name]!=null or .jobs[$name]!=null or .inventory[$name]!=null or any(.observations|keys[];startswith($name+":"))' "$STATE_WORK" >/dev/null;then retire_inventory_service "$actual" || return 1;fi
            absence_handled["$actual"]=1
            continue
        fi
        mutate --arg name "$actual" --argjson now "$NOW" '.inventory //= {} | .inventory[$name]={missing:0,checkedAt:$now}' || return 1
        classified["$actual"]=1
        PROFILE_BY_NAME["$actual"]="$profile"
        EFFECTIVE_SPECS+=("$actual|$url|$expected|$allowed")
    done
    for name in "${EXTERNAL_SERVICES[@]}" "${DISABLED_SERVICES[@]}"; do classified["$name"]=1; done
    while read -r name;do
      [[ -z "${present[$name]+yes}" && -z "${absence_handled[$name]+yes}" ]] || continue
      retire_inventory_service "$name" || return 1
    done < <(jq -r '(.inventory // {})|keys[]' "$STATE_WORK")
    [[ "$DISCOVER_UNCLASSIFIED" == true ]] || return 0
    for name in "${!present[@]}"; do
        [[ -z "${classified[$name]+yes}" ]] || continue
        # An explicit ownership label can delegate a new container without
        # granting this script any restart permission.
        info="$(docker_cmd inspect "$name")" || return 1
        owned="$(jq -r '.[0].Config.Labels["com.ray-cys.watchdog.owner"] // ""' <<<"$info")" || return 1
        [[ "$owned" != external && "$owned" != disabled ]] || continue
        mutate --arg name "$name" --argjson now "$NOW" '.inventory //= {} | .inventory[$name]={missing:0,checkedAt:$now}' || return 1
        observe "$name:unclassified" WARNING "Discovered container has no application-specific policy; availability remains visible; no restart permission granted" || return 1
    done
}

probe_rule() {
    local rule profile="${PROFILE_BY_NAME[$1]:-$1}"
    for rule in "${PROBE_RULES[@]}"; do [[ "${rule%%|*}" != "$profile" ]] || { printf '%s\n' "$rule"; return 0; }; done
    return 1
}

probe_routes() {
    local name="$1" info="$2" port="$3" path="$4" host mapped mode profile env_port peer bound_host ip
    profile="${PROFILE_BY_NAME[$name]:-$name}"
    # qBittorrent images commonly change the internal port via WEBUI_PORT.
    # A VPN companion may own the actual published mapping/network namespace.
    if [[ "$profile" == qbittorrent ]]; then
        env_port="$(jq -r '[.[0].Config.Env[]? | select(startswith("WEBUI_PORT=")) | split("=")[1]] | last // ""' <<<"$info")"
        if [[ -n "$env_port" ]]; then
            [[ "$env_port" =~ ^[1-9][0-9]{0,4}$ ]] && (( env_port <= 65535 )) || return 1
            port="$env_port"
        fi
    fi
    mode="$(jq -r '.[0].HostConfig.NetworkMode // ""' <<<"$info")"
    if [[ "$mode" == container:* ]]; then
        peer="${mode#container:}"
        info="$(docker_cmd inspect "$peer" 2>/dev/null)" && inspect_valid "$info" || return 1
    fi
    mapped="$(jq -r --arg port "$port/tcp" '. [0].NetworkSettings.Ports[$port][0] // {} | [(.HostIp // ""),(.HostPort // "")] | join("|")' <<<"$info")" || return 1
    host="${mapped%%|*}"; mapped="${mapped#*|}"
    if [[ -n "$mapped" ]]; then
        bound_host="$host"
        [[ "$host" != 0.0.0.0 && "$host" != :: && -n "$host" ]] || host="$DOCKER_HOST_IP"
        [[ "$host" != *:* ]] || host="[$host]"
        printf 'http://%s:%s%s\n' "$host" "$mapped" "$path"
        if [[ "$profile" == qbittorrent ]]; then
            # Alternate routes are derived from this container/namespace only.
            # No port scan, Docker restart, firewall edit or VPN reconfiguration.
            if [[ "$bound_host" == 0.0.0.0 ]]; then printf 'http://127.0.0.1:%s%s\n' "$mapped" "$path"
            elif [[ "$bound_host" == :: ]]; then printf 'http://[::1]:%s%s\n' "$mapped" "$path"; fi
            while IFS= read -r ip; do
                [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
                printf 'http://%s:%s%s\n' "$ip" "$port" "$path"
            done < <(jq -r '[.[0].NetworkSettings.Networks[]?.IPAddress | select(length > 0)] | unique[]' <<<"$info")
        fi
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

probe_url() {
    probe_routes "$@" | sed -n '1p'
}

safe_probe_target() {
    printf '%s\n' "$1" | sed -E 's#(https?://)[^/@]*@#\1[REDACTED]@#; s/[?#].*$//'
}

probe_address_args() {
    local name="$1" url="$2" profile authority host port rule owner rule_host rule_port address extra octet matched=0
    local -a octets=()
    PROBE_ADDRESS_ARGS=(); PROBE_ADDRESS_NOTE=""
    profile="${PROFILE_BY_NAME[$name]:-$name}"
    [[ "$url" =~ ^https?://([^/?#]+) ]] || return 0
    authority="${BASH_REMATCH[1]##*@}"
    host="${authority%%:*}"; host="${host,,}"
    if [[ "$authority" == *:* ]]; then port="${authority##*:}"
    elif [[ "$url" == https://* ]]; then port=443
    else port=80; fi
    for rule in "${PROBE_ADDRESS_OVERRIDES[@]}"; do
        IFS='|' read -r owner rule_host rule_port address extra <<<"$rule"
        [[ "$owner" == "$profile" ]] || continue
        [[ -z "$extra" && "$rule_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ &&
            "$rule_port" =~ ^[1-9][0-9]{0,4}$ && "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
        (( rule_port <= 65535 )) || return 1
        IFS='.' read -r -a octets <<<"$address"
        for octet in "${octets[@]}"; do
            # Reject ambiguous leading-zero forms as well as invalid octets.
            [[ "$octet" == 0 || "$octet" != 0* ]] && (( 10#$octet <= 255 )) || return 1
        done
        [[ "$host" == "${rule_host,,}" && "$port" == "$rule_port" ]] || continue
        matched=$((matched + 1)); (( matched == 1 )) || return 1
        PROBE_ADDRESS_ARGS=(--resolve "$host:$port:$address")
        PROBE_ADDRESS_NOTE="; address override=$address"
    done
}

readiness_probe() {
    local name="$1" url="$2" rule profile port path kind pattern info body code rc response redirect origin target_origin redirects=0 limit target route_index=0
    local -a args=() routes=()
    PROBE_RESULT=unconfigured; PROBE_MESSAGE='No readiness probe configured'
    rule="$(probe_rule "$name")" || rule=""
    if [[ -z "$rule" && -z "$url" ]]; then return 0; fi
    IFS='|' read -r profile port path kind pattern <<<"$rule"
    kind="${kind:-reachable}"
    if [[ -z "$url" ]]; then
        info="$(docker_cmd inspect "$name" 2>/dev/null)" && inspect_valid "$info" || { PROBE_RESULT=inspection; PROBE_MESSAGE='Probe inspection failed'; return 1; }
        mapfile -t routes < <(probe_routes "$name" "$info" "$port" "$path")
        (( ${#routes[@]} > 0 )) || { PROBE_MESSAGE='Unable to resolve published/custom-IP endpoint; configure an explicit URL'; return 0; }
        url="${routes[0]}"
    else
        routes=("$url")
    fi
    body="$TMP_DIR/$name.probe"
    limit="$PROBE_MAX_BYTES"
    [[ "$kind" != recognize ]] || limit="$PROBE_UI_MAX_BYTES"
    [[ ! -f "$PROBE_AUTH_DIR/$name.headers" ]] || args+=(--header "@$PROBE_AUTH_DIR/$name.headers")
    [[ ! -f "$PROBE_AUTH_DIR/$name.cookies" ]] || args+=(--cookie "$PROBE_AUTH_DIR/$name.cookies")
    [[ "$url" =~ ^(https?://[^/?#]+) ]] || { PROBE_MESSAGE='Probe URL has no supported origin'; return 0; }
    origin="${BASH_REMATCH[1]}"
    while :; do
        target="$(safe_probe_target "$url")"
        if ! probe_address_args "$name" "$url"; then
            PROBE_RESULT=unconfigured; PROBE_MESSAGE='Invalid or duplicate probe address override; review PROBE_ADDRESS_OVERRIDES'; return 0
        fi
        target+="$PROBE_ADDRESS_NOTE"
        response="$(curl --silent --noproxy '*' --proto '=http,https' --output "$body" \
            --connect-timeout "$HTTP_CONNECT_TIMEOUT" --max-time "$HTTP_MAX_TIME" \
            --max-filesize "$limit" --write-out '%{http_code}\n%{redirect_url}' "${args[@]}" "${PROBE_ADDRESS_ARGS[@]}" "$url")"; rc=$?
        code="${response%%$'\n'*}"; redirect=""
        [[ "$response" != *$'\n'* ]] || redirect="${response#*$'\n'}"
        if (( rc == 3 || rc == 60 || rc == 63 || rc == 77 )); then PROBE_RESULT=unconfigured; PROBE_MESSAGE="Probe URL/TLS/response-size configuration requires review (curl=$rc; limit=${limit}B; target=$target)"; return 0; fi
        if (( rc != 0 )); then
            if (( (rc == 7 || rc == 28 || rc == 52 || rc == 56) && route_index + 1 < ${#routes[@]} && route_index + 1 < PROBE_MAX_ROUTES )); then
                route_index=$((route_index + 1)); url="${routes[$route_index]}"
                [[ "$url" =~ ^(https?://[^/?#]+) ]] || return 1
                origin="${BASH_REMATCH[1]}"; redirects=0
                continue
            fi
            PROBE_RESULT=transport; PROBE_MESSAGE="HTTP transport failed (curl=$rc; last target=$target; attempted routes=$((route_index + 1)))"; return 1
        fi
        if [[ "$code" =~ ^3[0-9][0-9]$ && "$kind" == recognize && -n "$redirect" ]]; then
            [[ "$redirect" =~ ^(https?://[^/?#]+) ]] || { PROBE_RESULT=unconfigured; PROBE_MESSAGE='Redirect target invalid'; return 0; }
            target_origin="${BASH_REMATCH[1]}"
            if [[ "$target_origin" != "$origin" ]] || (( redirects >= PROBE_MAX_REDIRECTS )); then
                PROBE_RESULT=unconfigured; PROBE_MESSAGE='Cross-origin redirect or redirect limit reached; configure the final application URL'; return 0
            fi
            redirects=$((redirects + 1)); url="$redirect"
            continue
        fi
        break
    done
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
            PROBE_RESULT=reachable; PROBE_MESSAGE="Application UI recognized (${redirects} same-origin redirects); backend readiness requires Docker health or a stronger configured probe"; return 0 ;;
        reachable) PROBE_RESULT=reachable; PROBE_MESSAGE='HTTP reachable; application readiness not verified'; return 0 ;;
        *) PROBE_RESULT=unconfigured; PROBE_MESSAGE='Unknown probe validation mode'; return 0 ;;
    esac
    PROBE_RESULT=ready; PROBE_MESSAGE="Application readiness response validated (target=$target; route=$((route_index + 1)))"
}

endpoint_healthy() {
    readiness_probe "${2:-service}" "$1"
}

diagnose_service() {
    local name="$1" url="${2:-}" info rule profile port path kind pattern resolved spec configured_profile configured_url _configured_rest
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 2
    TMP_DIR="$(mktemp -d /tmp/docker-watchdog-diagnose.XXXXXX)" || return 1
    trap cleanup EXIT
    info="$(docker_cmd inspect "$name" 2>/dev/null)" && inspect_valid "$info" || { printf 'Inspection failed: %s\n' "$name" >&2; return 1; }
    printf 'Watchdog: %s\nContainer: %s\n' "$SCRIPT_VERSION" "$name"
    jq -r '.[0] | "State: \(.State.Status); health: \(.State.Health.Status // "none")\nNetwork mode: \(.HostConfig.NetworkMode // "unknown")\nPublished ports: \(.NetworkSettings.Ports // {})"' <<<"$info"
    rule="$(probe_rule "$name" || true)"
    IFS='|' read -r profile port path kind pattern <<<"$rule"
    if [[ -z "$url" ]]; then
        for spec in "${SERVICE_SPECS[@]}"; do
            IFS='|' read -r configured_profile configured_url _configured_rest <<<"$spec"
            [[ "$configured_profile" == "${PROFILE_BY_NAME[$name]:-$name}" ]] || continue
            url="$configured_url"; break
        done
    fi
    resolved="$url"
    if [[ -z "$resolved" && -n "$rule" ]]; then resolved="$(probe_url "$name" "$info" "$port" "$path" || true)"; fi
    printf 'Resolved probe: %s\n' "$(safe_probe_target "${resolved:-not configured}")"
    readiness_probe "$name" "$url" || true
    printf 'Probe classification: %s\nEvidence: %s\n' "$PROBE_RESULT" "$PROBE_MESSAGE"
    printf 'No monitoring state, notifications, or container actions were performed.\n'
}

inspect_valid() {
    jq -e 'type == "array" and length == 1 and (.[0].State.Status | type == "string") and
        (.[0].State.OOMKilled | type == "boolean") and
        ((.[0].State.Health.Status // "none") | type == "string") and
        (.[0].RestartCount | type == "number" and . >= 0 and . == floor) and
        (.[0].Id | type == "string")' <<<"$1" >/dev/null 2>&1
}

verify_service() {
    local info health
    VERIFY_MESSAGE=""
    info="$(docker_cmd inspect "$1" 2>/dev/null)" && inspect_valid "$info" || return 1
    jq -e '.[0].State | .Status == "running" and ((.Health.Status // "none") == "none" or .Health.Status == "healthy")' <<<"$info" >/dev/null || return 1
    endpoint_healthy "$2" "$1" || return 1
    health="$(jq -r '.[0].State.Health.Status // "none"' <<<"$info")"
    if [[ "$PROBE_RESULT" == ready ]]; then VERIFY_MESSAGE='Docker running and application readiness validated'
    elif [[ ( "$PROBE_RESULT" == reachable || "$PROBE_RESULT" == unconfigured ) && "$health" == healthy ]]; then
        VERIFY_MESSAGE='Docker running and Docker health=healthy'
    elif [[ "$PROBE_RESULT" == unconfigured && "$health" == none && -z "$2" && -z "$(probe_rule "$1" || true)" ]]; then
        VERIFY_MESSAGE='Docker running; no Docker healthcheck or application readiness probe is configured; scheduled-job outcome remains independently monitored'
    else return 1; fi
}

# Docker autostart is not crash recovery. Use native event evidence rather than
# assuming that any stopped container should be started. Explicit stop/kill
# events are retained as stop intent; missing/expired evidence prohibits action.
unexpected_exit_proven() {
    local name="$1" info="$2" finished epoch id known last events="$TMP_DIR/exit-events.jsonl"
    [[ "$RECOVER_UNEXPECTED_EXITS" == true || "$RESTART_STOPPED_CONTAINERS" == true ]] || return 1
    [[ $(jq -r '.[0].State.Status' <<<"$info") == exited ]] || return 1
    id=$(jq -r '.[0].Id' <<<"$info")
    known=$(jq -r --arg n "$name" '.services[$n].id // ""' "$STATE_WORK")
    last=$(jq -r --arg n "$name" '.services[$n].lastRunningAt // 0' "$STATE_WORK")
    [[ "$last" =~ ^[0-9]+$ && "$id" == "$known" ]] && (( last>0 )) || return 1
    finished=$(jq -r '.[0].State.FinishedAt // ""' <<<"$info")
    epoch=$(epoch_value "$finished")
    (( epoch>0 && epoch<=NOW && NOW-epoch<=STOP_EVENT_MAX_AGE_SECONDS && last<=epoch )) || return 1
    # Native Docker history is volatile. If it cannot prove the event, preserve
    # the stopped state. Read only the small time window around this exact exit.
    if ! docker_cmd events --since "$((epoch-5))" --until "$((epoch+5<NOW ? epoch+5 : NOW))" \
        --filter "container=$id" --filter type=container --format '{{json .}}' | head -c 65537 >"$events"; then return 1; fi
    (( $(stat -c %s "$events")<=65536 )) || return 1
    jq -es --arg id "$id" --argjson t "$epoch" '
      all(.[]; type=="object") and
      ([.[] | select((.Actor.ID // .id // "")==$id and (.time // 0)>=$t-5 and (.time // 0)<=$t+5)] as $events |
       any($events[]; (.Action // .status)=="die") and
       (any($events[]; (.Action // .status)=="stop" or (.Action // .status)=="kill")|not))' "$events" >/dev/null
}

attempt_recovery() {
    local name="$1" url="$2" status="$3" permitted="$4" count last window attempts fd elapsed=0 latest lease_rc
    [[ "$AUTO_RESTART" == true && "$RECOVERY_SAFE" == true && "$permitted" == 1 ]] || return 0
    local platform_version
    if [[ -r "${UNRAID_VERSION_FILE:-/etc/unraid-version}" ]]; then
        platform_version=$(sed -n 's/^version="\([^"]*\)"/\1/p' "${UNRAID_VERSION_FILE:-/etc/unraid-version}")
        [[ "$platform_version" == 7.* ]] || { log WARNING 'Unvalidated Unraid major; Docker recovery prohibited; availability monitoring continues'; return 0; }
    fi
    [[ -z "${RECOVERY_BLOCKED[$name]+yes}" ]] || return 0
    # Initial eligibility is rechecked from fresh inspection under the lease lock.
    [[ "$status" == running || "$RECOVER_UNEXPECTED_EXITS" == true || "$RESTART_STOPPED_CONTAINERS" == true ]] || return 0
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
    local recovery_command=restart
    if [[ "$(jq -r '.[0].State.Status' <<<"$latest")" != running ]]; then
        if ! unexpected_exit_proven "$name" "$latest"; then
            log INFO "$name: stopped state preserved; no proof of an unexpected exit (manual stop/kill, missing event history or unknown container)"
            exec {fd}>&-; return 0
        fi
        recovery_command=start
    fi
    if [[ "$recovery_command" == restart && -n "$(probe_rule "$name" || true)" ]]; then
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
    if docker_cmd "$recovery_command" "$name" >/dev/null 2>&1; then
        while (( elapsed <= RECOVERY_TIMEOUT_SECONDS )); do
            if verify_service "$name" "$url"; then
                observe "$name:recovery-action" WARNING "Container $recovery_command completed; $VERIFY_MESSAGE; awaiting stable recovery scans" 1
                exec {fd}>&-
                return 0
            fi
            sleep "$RECOVERY_POLL_SECONDS"
            elapsed=$((elapsed + RECOVERY_POLL_SECONDS))
        done
    fi
    observe "$name:recovery-failed" CRITICAL "Container $recovery_command failed or service did not pass post-restart verification; attempt budget consumed" 1
    exec {fd}>&-
}

# Read-only VPN audit. It never changes Docker, qBittorrent, Tailscale, or routes.
# The canary proves only a small request bound to the configured interface, not
# every torrent socket. Mullvad's endpoint supplies attribution, not a geo-IP guess.
collect_vpn_evidence() {
    local name="$1" family="$2" interface="$3"
    docker_cmd exec "$name" sh -c '
      case "$1" in
        status) tailscale status --json ;;
        prefs) tailscale debug prefs ;;
        binding) sed -n "s/^Session\\\\Interface=//p" /config/config/qBittorrent.conf /config/qBittorrent.conf /config/qBittorrent/qBittorrent.conf /config/qBittorrent/config/qBittorrent.conf 2>/dev/null | head -n 1 ;;
        dns) getent ahostsv4 am.i.mullvad.net | head -n 1 | cut -d " " -f 1 ;;
        route4) ip -j route get 1.1.1.1 ;;
        route6) ip -j -6 route get 2606:4700:4700::1111 ;;
        canary4|canary6)
          family=-4; [ "$1" != canary6 ] || family=-6
          curl "$family" --noproxy "*" --interface "$2" --proto "=https" \
            --connect-timeout 2 --max-time 4 --max-filesize 4096 --silent --fail \
            https://am.i.mullvad.net/json ;;
      esac' sh "$family" "$interface" 2>/dev/null
}

vpn_finding() {
    RECOVERY_BLOCKED["${1%%:*}"]=1
    observe "$@"
}

diagnose_vpn() (
    # Isolated output-only diagnostic: no state, notifications, or actions.
    log() { shift; printf '%s\n' "$*"; }
    vpn_finding() { printf '%s [%s] %s\n' "$1" "$2" "$3"; }
    printf 'Watchdog: %s; read-only VPN audit\n' "$SCRIPT_VERSION"
    check_vpn_egress "$VPN_CONTAINER"
)

check_vpn_egress() {
    local name="$1" ts prefs binding route device canary family ipv6 dns result=""
    [[ "$VPN_EGRESS_CHECK_ENABLED" == true && "$name" == "$VPN_CONTAINER" ]] || return 0
    if ! ts=$(collect_vpn_evidence "$name" status "") ||
       ! prefs=$(collect_vpn_evidence "$name" prefs "") ||
       ! jq -e 'type=="object" and .BackendState=="Running" and .ExitNodeStatus.Online==true' <<<"$ts" >/dev/null; then
        vpn_finding "$name:vpn-exit" WARNING 'VPN exit-node evidence unavailable or node offline; torrent egress unverified. No configuration or container action performed.'
        return
    fi
    if ! jq -e --arg id "$VPN_EXPECTED_EXIT_NODE_ID" '.ExitNodeStatus.ID==$id' <<<"$ts" >/dev/null ||
       ! jq -e --arg id "$VPN_EXPECTED_EXIT_NODE_ID" '.ExitNodeID==$id and .WantRunning==true' <<<"$prefs" >/dev/null; then
        vpn_finding "$name:vpn-exit" WARNING 'Selected exit node differs from the approved Mullvad node; verify Tailscale settings. No automatic reconfiguration performed.' || return 1
    fi
    binding=$(collect_vpn_evidence "$name" binding "") || binding=""
    if [[ ! "$binding" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
        vpn_finding "$name:vpn-binding" WARNING 'qBittorrent interface binding missing or unreadable; explicit VPN binding required. Torrent egress unverified.'
        return
    fi
    route=$(collect_vpn_evidence "$name" route4 "") || route='[]'
    device=$(jq -r '.[0].dev // "unknown"' <<<"$route" 2>/dev/null) || device=unknown
    if [[ "$binding" != "$VPN_EXPECTED_INTERFACE" || "$device" != "$VPN_EXPECTED_INTERFACE" ]]; then
        vpn_finding "$name:vpn-binding" WARNING "qBittorrent binds $binding; default IPv4 route=$device; expected=$VPN_EXPECTED_INTERFACE. Set qBittorrent Advanced > Network interface to $VPN_EXPECTED_INTERFACE and leave Optional IP address on All addresses. A working Web UI does not verify torrent routing." || return 1
    fi
    dns=$(collect_vpn_evidence "$name" dns "") || dns=""
    case "$dns" in
      ""|0.0.0.0|127.*)
        vpn_finding "$name:vpn-canary-dns" WARNING "Mullvad check hostname resolves to ${dns:-no address} inside qBittorrent. DNS blocking/override prevents egress verification; allow am.i.mullvad.net in the responsible resolver if intended. Watchdog does not bypass DNS policy or infer a VPN leak."
        return ;;
    esac
    for family in 4 6; do
        if [[ "$family" == 6 ]]; then
            if ! ipv6=$(collect_vpn_evidence "$name" route6 "") || ! jq -e 'length>0' <<<"$ipv6" >/dev/null 2>&1; then
                log INFO "$name: IPv6 has no usable route; IPv6 egress not tested"
                continue
            fi
            if ! jq -e --arg dev "$VPN_EXPECTED_INTERFACE" '.[0].dev==$dev' <<<"$ipv6" >/dev/null; then
                vpn_finding "$name:vpn-ipv6" WARNING 'IPv6 route bypasses the expected VPN interface; review IPv6 before relying on VPN isolation.' || return 1
            fi
        fi
        if ! canary=$(collect_vpn_evidence "$name" "canary$family" "$binding") ||
           ! jq -e 'type=="object" and (.mullvad_exit_ip|type)=="boolean"' <<<"$canary" >/dev/null 2>&1; then
            vpn_finding "$name:vpn-egress$family" WARNING "IPv$family interface-bound Mullvad canary unavailable; DNS/TLS/routing or endpoint may be unavailable. Egress is unverified; this does not prove a leak." || return 1
        elif ! jq -e '.mullvad_exit_ip==true' <<<"$canary" >/dev/null; then
            vpn_finding "$name:vpn-egress$family" CRITICAL "IPv$family request bound to $binding was not identified as Mullvad egress. Review torrent binding and VPN routing; watchdog made no container or network changes." || return 1
        else
            result+=" IPv$family=Mullvad"
        fi
    done
    if [[ -n "$result" ]]; then
        log INFO "$name: VPN canary results:$result; binding=$binding default-route=$device (torrent sockets not inspected)"
    fi
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
        --arg status "$status" --argjson now "$NOW" \
        'if (.services[$name].id // "")!=$id then .services[$name]={lastRunningAt:0} else . end |
         .services[$name]=((.services[$name] // {})+{id:$id,restartCount:$count,oom:$oom,failures:$failures}) |
         if $status=="running" then .services[$name].lastRunningAt=$now else . end' || return 1
    if [[ "$status" == running ]]; then check_vpn_egress "$name" || return 1; fi
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

kometa_weekly_delegate_ready() {
    [[ "$KOMETA_WEEKLY_REPORTING" == true && -f "$KOMETA_WEEKLY_STATE" && ! -L "$KOMETA_WEEKLY_STATE" ]] || return 1
    jq -e --argjson now "$NOW" '.schema==1 and (.kometaEvidenceOk != false) and (.lastCheckedAt|type=="number") and (.nextDue|type=="number") and
      .lastCheckedAt<=($now+300) and .lastCheckedAt>=($now-8*3600) and .nextDue>=($now-8*3600)' "$KOMETA_WEEKLY_STATE" >/dev/null 2>&1
}

notify_changes() {
    local current previous body importance=normal description delegate=false
    kometa_weekly_delegate_ready && delegate=true
    current="$(jq -cS --argjson delegate "$delegate" '. as $state | .observations | with_entries(select(.value.active) |
        select(($delegate and (.key|test("^(kometa|lometa):job-(errors|warnings)$")))|not) |
        select((.key | test(":(availability|missing)$") | not) or
            (($state.flapping[(.key | split(":")[0])].unstable // false | not) and
             ($state.observations["monitor:shared-dependency"].active // false | not)))) | map_values(.severity)' "$STATE_WORK")" || return 1
    previous="$(jq -cS --argjson delegate "$delegate" '.notification.issues | with_entries(select(($delegate and (.key|test("^(kometa|lometa):job-(errors|warnings)$")))|not))' "$STATE_WORK")" || return 1
    local retired_pending
    retired_pending=$(jq -r '(.inventoryOutbox // {})|length' "$STATE_WORK")
    if [[ "$current" == "$previous" && "$retired_pending" == 0 ]]; then mutate --argjson current "$current" '.notification.issues=$current'; return $?; fi
    description="Docker watchdog UPDATED"
    [[ "$current" != '{}' ]] || description="Docker watchdog findings cleared"
    ((retired_pending==0)) || description='Docker monitoring inventory updated'
    if jq -e 'any(.[]; . == "CRITICAL")' <<<"$current" >/dev/null; then importance=alert
    elif [[ "$current" != '{}' ]]; then importance=warning; fi
    body="$(jq -r --argjson now "$NOW" --argjson current "$current" '.observations | to_entries[] | .key as $key | select($current|has($key)) |
        "[\(.value.severity)] \(.key)\n  Condition: \(.value.message)\n  Observed duration: \(($now - .value.first) / 60 | floor)m; consecutive failures: \(.value.bad)"' "$STATE_WORK")"
    body+=$'\n'"$(jq -r --argjson current "$current" --argjson previous "$previous" '
        (.inventory // {}) as $inventory | ($previous|keys)-($current|keys)|.[]|. as $key|
        if ($inventory[($key|split(":")[0])].retiredAt // 0)>0 then "Retired alert: "+$key else "Resolved: "+$key end' "$STATE_WORK")"
    body+=$'\n'"$(jq -r '(.inventoryOutbox // {})|to_entries[]|"Retired monitoring: "+.key+"; "+.value.message' "$STATE_WORK")"
    body+=$'\n'"State: $STATE_FILE; log: $LOG_FILE"
    if [[ ! -x "$NOTIFY_BIN" ]] || ! usr_ops_notify timeout 30 "$NOTIFY_BIN" -i "$importance" -s "Docker Service Watchdog" -d "$description" -m "$body"; then
        log ERROR "Notification failed; delivery checkpoint unchanged"
        return 1
    fi
    mutate --argjson current "$current" '.notification.issues=$current | .inventoryOutbox={}'
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
    case "${1:-}" in --readiness|--update-readiness|--diagnose|--diagnose-vpn|--version|--help|-h|--maintenance) ;;
        *) exec {STATE_EXPORT_FD}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || return 1
           if ! flock -s -n "$STATE_EXPORT_FD"; then printf 'State export active; watchdog invocation deferred.\n'; return 0; fi;;
    esac
    local spec name url expected allowed uptime status=OK failed=false command
    case "${1:-}" in
        --help|-h) printf '%s\n' 'Usage: bash docker_service_watchdog.sh [--readiness CONTAINER|--update-readiness CONTAINER|--version|--diagnose-vpn|--diagnose CONTAINER [URL]|--maintenance CONTAINER MINUTES REASON|--record-job PROFILE EXIT_CODE [START_EPOCH]]'
            printf '%s\n' 'Schedule every five minutes. Recovery requires global AND per-service permission.' \
                'Maintenance suppresses availability checks/restarts, freezes active findings, and expires within 24h.' \
                'Remove /run/docker-service-maintenance/CONTAINER.manual.json to end a manual lease early.' \
                'Healthy/unchanged runs stay silent. Failures and recovery require consecutive scans.' \
                'Internal schedulers need native status, timestamped whole-run evidence, or producer receipts.' \
                'Run docker_watchdog_liveness.sh independently every five minutes to monitor this script.' \
                '--diagnose-vpn prints read-only binding, exit-node, DNS and egress evidence; no state or notifications.'; return 0 ;;
        --readiness|--update-readiness) [[ $# == 2 ]] || return 2;local purpose=health;[[ "$1" != --update-readiness ]] || purpose=update;readiness_json "$2" "$purpose";return $?;;
        --version) printf 'docker_service_watchdog.sh %s\n' "$SCRIPT_VERSION"; return 0 ;;
        --diagnose-vpn) [[ $# == 1 ]] || return 2; diagnose_vpn; return $? ;;
        --diagnose) [[ $# == 2 || $# == 3 ]] || return 2; diagnose_service "$2" "${3:-}"; return $? ;;
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
        "$SHARED_FAILURE_THRESHOLD" "$FLAP_WINDOW_SECONDS" "$FLAP_TRANSITION_THRESHOLD" "$FLAP_STABLE_SECONDS" "$PROBE_UI_MAX_BYTES" "$PROBE_MAX_ROUTES" "$JOB_LOG_SCAN_MAX_BYTES"; do
        [[ "$number" =~ ^[1-9][0-9]*$ ]] || return 2
    done
    (( JOB_LOG_SCAN_MAX_BYTES >= 1024 && JOB_LOG_SCAN_MAX_BYTES <= 512 * 1024 * 1024 )) || return 2
    for number in "$BOOT_GRACE_SECONDS" "$CONTAINER_GRACE_SECONDS" "$LOG_SIZE_WARNING_BYTES" "$PROBE_MAX_REDIRECTS"; do [[ "$number" =~ ^[0-9]+$ ]] || return 2; done
    for flag in "$AUTO_RESTART" "$RESTART_STOPPED_CONTAINERS" "$RECOVER_UNEXPECTED_EXITS" "$CHECK_LOG_SIZE" "$DISCOVER_UNCLASSIFIED" "$REQUIRE_VERIFIED_JOB_SUCCESS" "$KOMETA_WEEKLY_REPORTING" "$VPN_EGRESS_CHECK_ENABLED"; do [[ "$flag" == true || "$flag" == false ]] || return 2; done
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
