#!/bin/bash
# Release version: bump for every deployed code change; descriptions stay user-owned.
readonly SCRIPT_VERSION="1.4.2"
# Version lookup exits before logging, locks, state, Docker or network activity.
if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == --version ]]; then
    printf 'dns_redundancy_watchdog.sh %s\n' "$SCRIPT_VERSION"
    exit 0
fi
# BEGIN CURRENT OPERATIONAL PURPOSE
# PURPOSE: Monitor Unraid Pi-hole as the primary DNS resolver and the Raspberry Pi as the
#   independent fallback.
# WORKFLOW: Probe configured DNS answers over UDP/TCP, separate resolver failures from
#   transport/host-access issues, then apply only the configured bounded recovery policy.
# COORDINATION: Docker DNS monitoring is delegated here by docker_service_watchdog. Resolver and
#   host/network evidence distinguish an application outage from a broader Hubble problem.
# LIMITS: A running container is not proof of working DNS. Unknown host-to-custom-IP access or
#   probe configuration must not become a blind restart decision.
# REPORTING: Group resolver failures, recovery actions and restoration using consecutive
#   observations and cooldowns.
# Commands and side effects: docs/user-scripts-cli.md in ray-cys/unraid_repo.
# END CURRENT OPERATIONAL PURPOSE
clearLog=true

###############################################################################
# Dual Pi-hole DNS Redundancy Watchdog
#
# Monitors Pi-hole on Unraid as the primary resolver and a Raspberry Pi as the
# independent fallback. DNS answers are the health authority; ping, Docker,
# and SSH provide diagnostics and controlled recovery only.
#
# Recommended User Scripts schedule: */2 * * * *
###############################################################################

# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="dns_redundancy_watchdog"
# shellcheck shell=bash
# Shared operational logs, notifications and execution receipts.
usr_ops_log_line() {
    local level="${1^^}" phase="$2" message="$3" line LC_ALL=C
    case "$level" in WARN) level=WARNING;; ERR|FATAL) level=ERROR;; NOTICE) level=INFO;; esac
    message=${message//$'\r'/};message=${message//$'\n'/ | }
    printf -v line '%s | %s | %s | run=%s | phase=%s | %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$OPS_SCRIPT_ID" "${OPS_RUN_ID:-$$}" "$phase" "$message"
    if ((${#line}>4096));then line="${line:0:4050} ... [truncated]";fi
    printf '%s\n' "$line"
}

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
    local delivery_rc=0
    "${args[@]}" || delivery_rc=$?
    return "$delivery_rc"
}

usr_ops_execution_record() (
    local phase="$1" started="$2" pid="$3" rc="${4:-0}" process_start root="${USR_OPS_EXECUTION_ROOT:-/run/user-script-execution}" file tmp now boot old='{}' status
    [[ "${OPS_SCRIPT_ID:-}" =~ ^[a-z0-9_]+$ && ! -L "$root" ]] || return 1
    mkdir -p "$root" || return 1;file="$root/$OPS_SCRIPT_ID.json"
    [[ ! -L "$file" ]] || return 1
    if [[ -f "$file" ]];then old=$(jq -c 'select(.schema==1)' "$file") || old='{}';fi
    [[ -n "$old" ]] || old='{}'
    now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)
    process_start=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')
    [[ "$phase" != finish ]] || process_start=$(jq -r '.processStart // ""' <<<"$old")
    status=RUNNING;[[ "$phase" != finish ]] || { status=COMPLETED;((rc==0)) || status=FAILED; }
    tmp=$(mktemp "$root/.execution.XXXXXX") || return 1;trap 'rm -f -- "$tmp"' EXIT
    jq -n --argjson old "$old" --arg processStart "$process_start" --arg name "$OPS_SCRIPT_ID" --arg boot "$boot" --arg status "$status" --argjson started "$started" --argjson at "$now" --argjson pid "$pid" --argjson rc "$rc" \
      '$old+{schema:1,name:$name,boot:$boot,executionStatus:$status,startedAt:$started,observedAt:$at,pid:$pid,processStart:$processStart,lastExitCode:$rc} |
       if $status!="RUNNING" then .finishedAt=$at|.durationSeconds=($at-$started)|.lastCompletedAt=$at|if $rc==0 then .lastSuccessAt=$at else . end
       else .previousRun={startedAt:$old.startedAt,finishedAt:$old.finishedAt,status:$old.executionStatus,exitCode:$old.lastExitCode,durationSeconds:$old.durationSeconds}|.finishedAt=null|.durationSeconds=null|.lastExitCode=null end' >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file" || return 1
    local persistent="${USR_OPS_EXECUTION_PERSISTENT_ROOT:-/mnt/vault/cloud/logs/script/user_scripts_status/execution}" fd export_fd
    mountpoint -q "${USR_OPS_VAULT_MOUNT:-/mnt/vault}" || return 0
    [[ ! -L "$persistent" && $(realpath -m "$persistent") == "$persistent" ]] || return 1
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}";flock -s -n "$export_fd" || return 0
    mkdir -p "$persistent" || return 1
    tmp=$(mktemp "$persistent/.execution.XXXXXX") || return 1
    cp "$file" "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$persistent/$OPS_SCRIPT_ID.json"
)

usr_ops_supervise() {
    local script="$1" started pid='' interrupted='' rc=0 receipt_fd record_owner=false
    # Repository/fixture executions must never publish production evidence.
    # Explicit test roots opt into supervision for isolated regression checks.
    case "$script" in
      /boot/config/plugins/user.scripts/scripts/*/script|/tmp/user.scripts/tmpScripts/*/script) ;;
      *) if [[ -z "${USR_OPS_EXECUTION_ROOT:-}" ]];then USR_OPS_SUPERVISED="$OPS_SCRIPT_ID" /bin/bash "$script";return $?;fi;;
    esac
    local execution_root="${USR_OPS_EXECUTION_ROOT:-/run/user-script-execution}"
    if [[ ! -L "$execution_root" ]] && mkdir -p "$execution_root";then
        exec {receipt_fd}>"$execution_root/$OPS_SCRIPT_ID.lock"
        flock -n "$receipt_fd" && record_owner=true
    fi
    # Register forwarding before launch or receipt I/O. Background Bash may
    # inherit ignored SIGINT, so interactive cancellation uses its TERM cleanup.
    trap 'interrupted=TERM;[[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true' TERM HUP
    trap 'interrupted=INT;[[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true' INT
    started=$(date +%s)
    USR_OPS_SUPERVISED="$OPS_SCRIPT_ID" OPS_RUN_ID="${OPS_RUN_ID:-${started}_$$}" /bin/bash "$script" &
    pid=$!
    [[ -z "$interrupted" ]] || kill -TERM "$pid" 2>/dev/null || true
    [[ "$record_owner" != true ]] || usr_ops_execution_record start "$started" "$pid" || printf 'Execution receipt unavailable for %s; workflow continues.\n' "$OPS_SCRIPT_ID" >&2
    wait "$pid" || rc=$?
    # A signal can interrupt wait while the producer is still restoring state.
    if kill -0 "$pid" 2>/dev/null;then wait "$pid" || rc=$?;fi
    if [[ "$interrupted" == INT ]];then rc=130;elif [[ "$interrupted" == TERM ]];then rc=143;fi
    [[ "$record_owner" != true ]] || usr_ops_execution_record finish "$started" "$pid" "$rc" || printf 'Completion receipt unavailable for %s (exit=%s).\n' "$OPS_SCRIPT_ID" "$rc" >&2
    trap - TERM HUP INT
    return "$rc"
}
# END EMBEDDED OPERATIONS CONTRACT
# BEGIN SCHEDULED EXECUTION SUPERVISOR
if [[ "${BASH_SOURCE[0]}" == "$0" && $# == 0 && "${USR_OPS_SUPERVISED:-}" != "$OPS_SCRIPT_ID" ]];then
    usr_ops_supervise "$0";exit $?
fi
# END SCHEDULED EXECUTION SUPERVISOR
set -uo pipefail
umask 077


###############################################################################
# CONFIGURATION
###############################################################################

# Primary Pi-hole on Unraid. The IP must be the address used by LAN clients,
# not a Docker-internal address.
PRIMARY_DNS_IP="${PRIMARY_DNS_IP:-192.168.50.101}"
PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pihole}"

# Independent Raspberry Pi fallback.
FALLBACK_DNS_IP="${FALLBACK_DNS_IP:-192.168.50.100}"
FALLBACK_SSH_USER="${FALLBACK_SSH_USER:-admin}"

# pi.hole is answered locally by Pi-hole and therefore distinguishes a live
# FTL service from a shared internet/upstream failure. For stricter checking,
# create the same custom record on both Pi-holes and set expected addresses.
LOCAL_TEST_DOMAIN="${LOCAL_TEST_DOMAIN:-pi.hole}"
PRIMARY_LOCAL_EXPECTED="${PRIMARY_LOCAL_EXPECTED:-}"
FALLBACK_LOCAL_EXPECTED="${FALLBACK_LOCAL_EXPECTED:-}"

# External resolution is tested over both UDP and TCP.
EXTERNAL_TEST_DOMAIN="${EXTERNAL_TEST_DOMAIN:-example.com}"
DNS_TIMEOUT_SECONDS="${DNS_TIMEOUT_SECONDS:-3}"

# Optional daily consistency checks. Leave empty until the record/rule exists
# on both Pi-holes. Answers must match exactly when enabled.
CONSISTENCY_TEST_DOMAIN="${CONSISTENCY_TEST_DOMAIN:-}"
BLOCK_TEST_DOMAIN="${BLOCK_TEST_DOMAIN:-}"

PRIMARY_FAIL_THRESHOLD="${PRIMARY_FAIL_THRESHOLD:-2}"
FALLBACK_FAIL_THRESHOLD="${FALLBACK_FAIL_THRESHOLD:-3}"
BOTH_FAIL_THRESHOLD="${BOTH_FAIL_THRESHOLD:-2}"

ENABLE_PRIMARY_RECOVERY="${ENABLE_PRIMARY_RECOVERY:-true}"
ENABLE_FALLBACK_RECOVERY="${ENABLE_FALLBACK_RECOVERY:-true}"
RECOVERY_COOLDOWN_SECONDS="${RECOVERY_COOLDOWN_SECONDS:-3600}"
PRIMARY_RESTART_WAIT_SECONDS="${PRIMARY_RESTART_WAIT_SECONDS:-15}"
FALLBACK_RESTART_WAIT_SECONDS="${FALLBACK_RESTART_WAIT_SECONDS:-15}"

# Avoid boot/update noise while Unraid and containers are still starting.
BOOT_GRACE_SECONDS="${BOOT_GRACE_SECONDS:-300}"
CONTAINER_START_GRACE_SECONDS="${CONTAINER_START_GRACE_SECONDS:-120}"

# Unresolved incidents receive at most one reminder per day.
REMINDER_SECONDS="${REMINDER_SECONDS:-86400}"

# Raspberry Pi storage, temperature, FTL, configuration, and DNS consistency.
DEEP_CHECK_INTERVAL_SECONDS="${DEEP_CHECK_INTERVAL_SECONDS:-86400}"
DEEP_FAILURE_RECHECK_SECONDS="${DEEP_FAILURE_RECHECK_SECONDS:-3600}"
FALLBACK_DISK_WARNING_PERCENT="${FALLBACK_DISK_WARNING_PERCENT:-85}"
FALLBACK_TEMPERATURE_WARNING_C="${FALLBACK_TEMPERATURE_WARNING_C:-75}"

SSH_TIMEOUT_SECONDS="${SSH_TIMEOUT_SECONDS:-5}"

STATE_DIR="${STATE_DIR:-/mnt/vault/cloud/logs/script/dns_redundancy_watchdog}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/state.json}"
MAINTENANCE_DIR="${MAINTENANCE_DIR:-${STATE_DIR}/maintenance}"
LOG_FILE="${LOG_FILE:-${STATE_DIR}/dns-redundancy-watchdog.log}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-5242880}"

# Create maintenance/all, maintenance/primary, or maintenance/fallback to
# suppress notifications and recovery for planned work on that target.

STATUS_DIR="${STATUS_DIR:-/mnt/vault/cloud/logs/script/user_scripts_status}"
NOTIFY_BIN="${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}"
LOCK_FILE="${LOCK_FILE:-/run/dns_redundancy_watchdog.lock}"
REQUIRE_VAULT_MOUNT="${REQUIRE_VAULT_MOUNT:-true}"
VAULT_MOUNT="${VAULT_MOUNT:-/mnt/vault}"

###############################################################################
# RUNTIME
###############################################################################

START_EPOCH="$(date +%s)"
RESULT_STATUS="FAILED"
RESULT_SUMMARY="DNS redundancy watchdog exited before completion"
RECEIPT_WRITTEN=0
TMP_DIR=""
STATE_WORK=""

PRIMARY_UDP_OK=false
PRIMARY_TCP_OK=false
PRIMARY_LOCAL_OK=false
PRIMARY_DNS_OK=false
PRIMARY_UDP_REASON="not checked"
PRIMARY_TCP_REASON="not checked"
PRIMARY_LOCAL_REASON="not checked"
PRIMARY_UDP_MS=-1
PRIMARY_TCP_MS=-1

FALLBACK_UDP_OK=false
FALLBACK_TCP_OK=false
FALLBACK_LOCAL_OK=false
FALLBACK_DNS_OK=false
FALLBACK_UDP_REASON="not checked"
FALLBACK_TCP_REASON="not checked"
FALLBACK_LOCAL_REASON="not checked"
FALLBACK_UDP_MS=-1
FALLBACK_TCP_MS=-1
FALLBACK_PING_OK="not checked"

PRIMARY_CONTAINER_STATUS="unknown"
PRIMARY_CONTAINER_HEALTH="unknown"
PRIMARY_CONTAINER_OOM="false"
PRIMARY_CONTAINER_RESTART_COUNT=0
PRIMARY_CONTAINER_AGE_SECONDS=-1

PRIMARY_FAILURES=0
FALLBACK_FAILURES=0
PRIMARY_LAST_ACTION=0
FALLBACK_LAST_ACTION=0
PREVIOUS_CONTAINER_RESTART_COUNT=0
LAST_DEEP_EPOCH=0

PREVIOUS_NOTIFY_SIGNATURE="HEALTHY"
PREVIOUS_NOTIFY_CLASSIFICATION="HEALTHY"
PREVIOUS_NOTIFY_EPOCH=0

CLASSIFICATION="UNKNOWN"
CURRENT_SIGNATURE=""
NOTIFICATION_SENT=false
IN_BOOT_GRACE=false
PRIMARY_STARTING=false
PRIMARY_IN_MAINTENANCE=false

QUERY_OK=false
QUERY_REASON=""
QUERY_STATUS=""
QUERY_ANSWERS=""
QUERY_TIME_MS=-1

DEEP_FINDINGS=()
RUNTIME_FINDINGS=()
ACTIONS=()
EVENTS=()

###############################################################################
# GENERIC HELPERS
###############################################################################

log() {
    local level="$1"
    shift
    local line=""

    line=$(usr_ops_log_line "$level" MAIN "$*")
    printf '%s\n' "$line"
    [[ -d "$STATE_DIR" ]] &&
        printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}


rotate_log() {
    local size=0

    [[ -f "$LOG_FILE" ]] || return 0
    size="$(stat -c '%s' "$LOG_FILE" 2>/dev/null || printf '0')"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0

    if (( size >= LOG_MAX_BYTES )); then
        mv -f -- "$LOG_FILE" "${LOG_FILE}.1"
        : >"$LOG_FILE"
    fi
}


notify_unraid() {
    local importance="$1"
    local description="$2"
    local message="$3"

    [[ -x "$NOTIFY_BIN" ]] || {
        log WARN "Unraid notification helper unavailable: $NOTIFY_BIN"
        return 1
    }

    usr_ops_notify "$NOTIFY_BIN" \
        -i "$importance" \
        -s "DNS Redundancy Watchdog" \
        -d "$description" \
        -m "$message" \
        >/dev/null 2>&1
}


write_receipt() {
    local status="$1"
    local summary="$2"
    local now=""
    local tmp=""

    if [[ "$REQUIRE_VAULT_MOUNT" == true ]] &&
       ! mountpoint -q -- "$VAULT_MOUNT" 2>/dev/null
    then
        return 0
    fi

    now="$(date +%s)"
    mkdir -p -- "$STATUS_DIR" 2>/dev/null || return 0
    tmp="$(mktemp "${STATUS_DIR}/.dns_redundancy_watchdog.XXXXXX")" ||
        return 0

    if jq -n \
        --arg name "dns_redundancy_watchdog" \
        --arg status "$status" \
        --arg summary "$summary" \
        --arg log "$LOG_FILE" \
        --argjson epoch "$now" \
        --argjson duration "$((now - START_EPOCH))" \
        '{
            name:$name,
            status:$status,
            summary:$summary,
            log:$log,
            epoch:$epoch,
            duration_seconds:$duration
        }' >"$tmp"
    then
        mv -f -- "$tmp" "${STATUS_DIR}/dns_redundancy_watchdog.json"
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


bool_valid() {
    [[ "$1" == true || "$1" == false ]]
}


integer_at_least() {
    local value="$1"
    local minimum="$2"
    [[ "$value" =~ ^[0-9]+$ ]] && (( value >= minimum ))
}


maintenance_active() {
    local target="$1" lease boot pid start actual expires now
    [[ -e "${MAINTENANCE_DIR}/all" || -e "${MAINTENANCE_DIR}/${target}" ]] && return 0
    [[ "$target" == primary ]] || return 1
    local journal="${UPDATE_COORDINATOR_STATE_FILE:-/mnt/vault/cloud/logs/script/system_update_coordinator/state.json}"
    if [[ -e "$journal" ]];then
      if [[ -L "$journal" ]] || ! jq -e '.schema==1 and (.jobs|type)=="object"' "$journal" >/dev/null 2>&1;then return 0;fi
      if jq -e --arg name "$PRIMARY_CONTAINER" 'any(.jobs[];(.kind=="docker" and .name==$name and (.status|IN("INTENT","VERIFYING","ATTENTION"))) or (.kind=="plugin" and (.status|IN("INTENT","ATTENTION"))))' "$journal" >/dev/null;then return 0;fi
    fi
    [[ "$PRIMARY_IN_MAINTENANCE" != true ]] || return 0
    boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true); now=$(date +%s)
    for lease in "${DOCKER_MAINTENANCE_DIR:-/run/docker-service-maintenance}/$PRIMARY_CONTAINER."*.json; do
        [[ -f "$lease" && ! -L "$lease" ]] || continue
        jq -e '(.boot|type)=="string" and (.pid|type)=="number" and (.expires|type)=="number"' "$lease" >/dev/null 2>&1 || continue
        [[ $(jq -r .boot "$lease") == "$boot" ]] || continue
        pid=$(jq -r .pid "$lease"); expires=$(jq -r .expires "$lease")
        [[ "$pid" =~ ^[0-9]+$ && "$expires" =~ ^[0-9]+$ ]] || continue
        if (( pid==0 && expires>now && expires<=now+86400 )); then return 0; fi
        if (( pid>0 )) && kill -0 "$pid" 2>/dev/null; then
            start=$(jq -r '.processStart // ""' "$lease")
            actual=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')
            # An overlong but live producer must never be restarted mid-archive.
            [[ -n "$actual" && "$actual" == "$start" ]] && return 0
        fi
    done
    return 1
}

primary_maintenance_gate() {
    # Only Pi-hole's own lease suppresses primary checks. Unrelated appdata
    # archives must not hide DNS failures for the entire backup duration.
    if maintenance_active primary; then PRIMARY_IN_MAINTENANCE=true; fi
}


ssh_options() {
    printf '%s\n' \
        -o BatchMode=yes \
        -o "ConnectTimeout=${SSH_TIMEOUT_SECONDS}" \
        -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=1
}


fallback_ssh() {
    local -a options=()
    mapfile -t options < <(ssh_options)
    # Commands passed here are fixed strings owned by this script.
    # shellcheck disable=SC2029
    ssh "${options[@]}" \
        "${FALLBACK_SSH_USER}@${FALLBACK_DNS_IP}" "$@"
}

###############################################################################
# CONFIGURATION AND STATE
###############################################################################

validate_configuration() {
    local command=""

    for command in dig docker flock grep jq mountpoint ping sed sha256sum ssh; do
        command -v "$command" >/dev/null 2>&1 || {
            log ERROR "Required command not found: $command"
            return 1
        }
    done

    [[ -n "$PRIMARY_DNS_IP" && -n "$FALLBACK_DNS_IP" ]] || {
        log ERROR "Both DNS server addresses must be configured"
        return 1
    }

    [[ "$PRIMARY_DNS_IP" != "$FALLBACK_DNS_IP" ]] || {
        log ERROR "Primary and fallback DNS addresses must differ"
        return 1
    }

    [[ -n "$PRIMARY_CONTAINER" && -n "$LOCAL_TEST_DOMAIN" &&
       -n "$EXTERNAL_TEST_DOMAIN" ]] || {
        log ERROR "Container and DNS test names must not be empty"
        return 1
    }

    if ! integer_at_least "$DNS_TIMEOUT_SECONDS" 1 ||
       ! integer_at_least "$PRIMARY_FAIL_THRESHOLD" 1 ||
       ! integer_at_least "$FALLBACK_FAIL_THRESHOLD" 1 ||
       ! integer_at_least "$BOTH_FAIL_THRESHOLD" 1 ||
       ! integer_at_least "$RECOVERY_COOLDOWN_SECONDS" 0 ||
       ! integer_at_least "$REMINDER_SECONDS" 1 ||
       ! integer_at_least "$DEEP_CHECK_INTERVAL_SECONDS" 1 ||
       ! integer_at_least "$DEEP_FAILURE_RECHECK_SECONDS" 1
    then
        log ERROR "One or more numeric settings are invalid"
        return 1
    fi

    if ! bool_valid "$ENABLE_PRIMARY_RECOVERY" ||
       ! bool_valid "$ENABLE_FALLBACK_RECOVERY" ||
       ! bool_valid "$REQUIRE_VAULT_MOUNT"
    then
        log ERROR "Boolean configuration values must be true or false"
        return 1
    fi

    if [[ "$REQUIRE_VAULT_MOUNT" == true ]] &&
       ! mountpoint -q -- "$VAULT_MOUNT" 2>/dev/null
    then
        log ERROR "Vault pool is not mounted: $VAULT_MOUNT"
        return 1
    fi

    return 0
}


initialize_state() {
    local initial_signature=""

    initial_signature="$(printf 'HEALTHY\n\n\n' | sha256sum | awk '{print $1}')"
    STATE_WORK="${TMP_DIR}/state.json"

    if [[ -s "$STATE_FILE" ]] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
        cp -- "$STATE_FILE" "$STATE_WORK"
    else
        jq -n --arg signature "$initial_signature" '{
          schema:1,
          primary:{failures:0,last_action_epoch:0,restart_count:0},
          fallback:{failures:0,last_action_epoch:0},
          deep:{epoch:0,findings:[]},
          notification:{
            signature:$signature,
            classification:"HEALTHY",
            epoch:0
          },
          last_classification:"HEALTHY"
        }' >"$STATE_WORK"
    fi

    PRIMARY_FAILURES="$(jq -r '.primary.failures // 0' "$STATE_WORK")"
    FALLBACK_FAILURES="$(jq -r '.fallback.failures // 0' "$STATE_WORK")"
    PRIMARY_LAST_ACTION="$(jq -r '.primary.last_action_epoch // 0' "$STATE_WORK")"
    FALLBACK_LAST_ACTION="$(jq -r '.fallback.last_action_epoch // 0' "$STATE_WORK")"
    PREVIOUS_CONTAINER_RESTART_COUNT="$(jq -r '.primary.restart_count // 0' "$STATE_WORK")"
    LAST_DEEP_EPOCH="$(jq -r '.deep.epoch // 0' "$STATE_WORK")"
    PREVIOUS_NOTIFY_SIGNATURE="$(jq -r '.notification.signature // "HEALTHY"' "$STATE_WORK")"
    PREVIOUS_NOTIFY_CLASSIFICATION="$(jq -r '.notification.classification // "HEALTHY"' "$STATE_WORK")"
    PREVIOUS_NOTIFY_EPOCH="$(jq -r '.notification.epoch // 0' "$STATE_WORK")"

    if [[ "$PREVIOUS_NOTIFY_SIGNATURE" == HEALTHY &&
          "$PREVIOUS_NOTIFY_EPOCH" == 0 ]]; then
        PREVIOUS_NOTIFY_SIGNATURE="$initial_signature"
    fi

    mapfile -t DEEP_FINDINGS < <(jq -r '.deep.findings[]? // empty' "$STATE_WORK")

    integer_at_least "$PRIMARY_FAILURES" 0 || PRIMARY_FAILURES=0
    integer_at_least "$FALLBACK_FAILURES" 0 || FALLBACK_FAILURES=0
    integer_at_least "$PRIMARY_LAST_ACTION" 0 || PRIMARY_LAST_ACTION=0
    integer_at_least "$FALLBACK_LAST_ACTION" 0 || FALLBACK_LAST_ACTION=0
    integer_at_least "$PREVIOUS_CONTAINER_RESTART_COUNT" 0 ||
        PREVIOUS_CONTAINER_RESTART_COUNT=0
    integer_at_least "$LAST_DEEP_EPOCH" 0 || LAST_DEEP_EPOCH=0
    integer_at_least "$PREVIOUS_NOTIFY_EPOCH" 0 || PREVIOUS_NOTIFY_EPOCH=0
}


commit_state() {
    local deep_json=""
    local tmp="${STATE_DIR}/.state.json.tmp"
    local notify_signature="$PREVIOUS_NOTIFY_SIGNATURE"
    local notify_classification="$PREVIOUS_NOTIFY_CLASSIFICATION"
    local notify_epoch="$PREVIOUS_NOTIFY_EPOCH"

    deep_json="$(jq -cn '$ARGS.positional' --args "${DEEP_FINDINGS[@]}")" ||
        return 1

    if [[ "$NOTIFICATION_SENT" == true ]]; then
        notify_signature="$CURRENT_SIGNATURE"
        notify_classification="$CLASSIFICATION"
        notify_epoch="$START_EPOCH"
    fi

    if jq -n \
        --argjson primary_failures "$PRIMARY_FAILURES" \
        --argjson primary_action "$PRIMARY_LAST_ACTION" \
        --argjson restart_count "$PRIMARY_CONTAINER_RESTART_COUNT" \
        --argjson fallback_failures "$FALLBACK_FAILURES" \
        --argjson fallback_action "$FALLBACK_LAST_ACTION" \
        --argjson deep_epoch "$LAST_DEEP_EPOCH" \
        --argjson deep_findings "$deep_json" \
        --arg notify_signature "$notify_signature" \
        --arg notify_classification "$notify_classification" \
        --argjson notify_epoch "$notify_epoch" \
        --arg last_classification "$CLASSIFICATION" '
        {
          schema:1,
          primary:{
            failures:$primary_failures,
            last_action_epoch:$primary_action,
            restart_count:$restart_count
          },
          fallback:{
            failures:$fallback_failures,
            last_action_epoch:$fallback_action
          },
          deep:{epoch:$deep_epoch,findings:$deep_findings},
          notification:{
            signature:$notify_signature,
            classification:$notify_classification,
            epoch:$notify_epoch
          },
          last_classification:$last_classification
        }' >"$tmp"
    then
        mv -f -- "$tmp" "$STATE_FILE"
        return 0
    fi

    rm -f -- "$tmp"
    return 1
}

###############################################################################
# DNS CHECKS
###############################################################################

dns_query() {
    local server="$1"
    local domain="$2"
    local transport="$3"
    local expected="${4:-}"
    local output=""
    local -a transport_args=()

    QUERY_OK=false
    QUERY_REASON=""
    QUERY_STATUS=""
    QUERY_ANSWERS=""
    QUERY_TIME_MS=-1

    [[ "$transport" == tcp ]] && transport_args+=(+tcp)

    if ! output="$(
        dig \
            @"$server" \
            "$domain" \
            A \
            "${transport_args[@]}" \
            +time="$DNS_TIMEOUT_SECONDS" \
            +tries=1 \
            +noall \
            +comments \
            +answer \
            +stats \
            2>&1
    )"
    then
        QUERY_REASON="query timeout or transport failure"
        return 1
    fi

    QUERY_STATUS="$(
        sed -n 's/.*status: \([^,]*\),.*/\1/p' <<<"$output" |
            head -n 1
    )"
    QUERY_ANSWERS="$(
        awk '$4 == "A" {print $5}' <<<"$output" |
            sort -u
    )"
    QUERY_TIME_MS="$(
        sed -n 's/^;; Query time: \([0-9][0-9]*\) msec$/\1/p' \
            <<<"$output" |
            head -n 1
    )"
    [[ "$QUERY_TIME_MS" =~ ^[0-9]+$ ]] || QUERY_TIME_MS=-1

    if [[ "$QUERY_STATUS" != NOERROR ]]; then
        QUERY_REASON="DNS status ${QUERY_STATUS:-missing}"
        return 1
    fi

    if [[ -z "$QUERY_ANSWERS" ]]; then
        QUERY_REASON="NOERROR response contained no IPv4 answer"
        return 1
    fi

    if [[ -n "$expected" ]] &&
       ! grep -Fxq -- "$expected" <<<"$QUERY_ANSWERS"
    then
        QUERY_REASON="answer mismatch; expected $expected"
        return 1
    fi

    QUERY_OK=true
    QUERY_REASON="NOERROR with IPv4 answer"
    return 0
}


check_dns_endpoint() {
    local prefix="$1"
    local server="$2"
    local local_expected="$3"
    local udp_ok=false
    local tcp_ok=false
    local local_ok=false
    local reason=""
    local answers=""
    local query_ms=-1

    dns_query "$server" "$EXTERNAL_TEST_DOMAIN" udp || true
    udp_ok="$QUERY_OK"
    reason="$QUERY_REASON"
    query_ms="$QUERY_TIME_MS"
    printf -v "${prefix}_UDP_OK" '%s' "$udp_ok"
    printf -v "${prefix}_UDP_REASON" '%s' "$reason"
    printf -v "${prefix}_UDP_MS" '%s' "$query_ms"

    dns_query "$server" "$EXTERNAL_TEST_DOMAIN" tcp || true
    tcp_ok="$QUERY_OK"
    reason="$QUERY_REASON"
    query_ms="$QUERY_TIME_MS"
    printf -v "${prefix}_TCP_OK" '%s' "$tcp_ok"
    printf -v "${prefix}_TCP_REASON" '%s' "$reason"
    printf -v "${prefix}_TCP_MS" '%s' "$query_ms"

    dns_query "$server" "$LOCAL_TEST_DOMAIN" udp "$local_expected" || true
    local_ok="$QUERY_OK"
    reason="$QUERY_REASON"
    answers="$QUERY_ANSWERS"
    printf -v "${prefix}_LOCAL_OK" '%s' "$local_ok"
    printf -v "${prefix}_LOCAL_REASON" '%s' \
        "${reason}; answer=${answers:-none}"

    if [[ "$udp_ok" == true && "$tcp_ok" == true ]]; then
        printf -v "${prefix}_DNS_OK" '%s' true
    else
        printf -v "${prefix}_DNS_OK" '%s' false
    fi
}


inspect_primary_container() {
    local inspect=""
    local started_at=""
    local started_epoch=0
    local candidate=""
    local -a candidates=()

    PRIMARY_CONTAINER_STATUS="unavailable"
    PRIMARY_CONTAINER_HEALTH="unknown"
    PRIMARY_CONTAINER_OOM="false"
    PRIMARY_CONTAINER_RESTART_COUNT=0
    PRIMARY_CONTAINER_AGE_SECONDS=-1
    PRIMARY_STARTING=false

    if ! inspect="$(docker inspect "$PRIMARY_CONTAINER" 2>/dev/null)"; then
        mapfile -t candidates < <(
            docker ps -a \
                --format '{{.Names}}|{{.Image}}' 2>/dev/null |
                awk -F '|' 'tolower($2) ~ /(^|\/)pihole\/pihole/ {print $1}'
        )

        if (( ${#candidates[@]} != 1 )); then
            return 1
        fi

        candidate="${candidates[0]}"
        log WARN \
            "Configured container '${PRIMARY_CONTAINER}' was not found; using discovered Pi-hole container '${candidate}'"
        PRIMARY_CONTAINER="$candidate"
        inspect="$(docker inspect "$PRIMARY_CONTAINER" 2>/dev/null)" || return 1
    fi

    PRIMARY_CONTAINER_STATUS="$(jq -r '.[0].State.Status // "unknown"' <<<"$inspect")"
    PRIMARY_CONTAINER_HEALTH="$(jq -r '.[0].State.Health.Status // "none"' <<<"$inspect")"
    PRIMARY_CONTAINER_OOM="$(jq -r '.[0].State.OOMKilled // false' <<<"$inspect")"
    PRIMARY_CONTAINER_RESTART_COUNT="$(jq -r '.[0].RestartCount // 0' <<<"$inspect")"
    started_at="$(jq -r '.[0].State.StartedAt // empty' <<<"$inspect")"

    [[ "$PRIMARY_CONTAINER_RESTART_COUNT" =~ ^[0-9]+$ ]] ||
        PRIMARY_CONTAINER_RESTART_COUNT=0

    if [[ -n "$started_at" ]]; then
        started_epoch="$(date -d "$started_at" +%s 2>/dev/null || printf '0')"
        if [[ "$started_epoch" =~ ^[0-9]+$ ]] && (( started_epoch > 0 )); then
            PRIMARY_CONTAINER_AGE_SECONDS=$((START_EPOCH - started_epoch))
            (( PRIMARY_CONTAINER_AGE_SECONDS < 0 )) && PRIMARY_CONTAINER_AGE_SECONDS=0
            if (( PRIMARY_CONTAINER_AGE_SECONDS < CONTAINER_START_GRACE_SECONDS )); then
                PRIMARY_STARTING=true
            fi
        fi
    fi

    if (( PRIMARY_CONTAINER_RESTART_COUNT > PREVIOUS_CONTAINER_RESTART_COUNT )); then
        EVENTS+=(
            "Primary container restart count increased from ${PREVIOUS_CONTAINER_RESTART_COUNT} to ${PRIMARY_CONTAINER_RESTART_COUNT}"
        )
    fi

    return 0
}


collect_runtime_findings() {
    RUNTIME_FINDINGS=()

    if [[ "$PRIMARY_DNS_OK" == true ]]; then
        [[ "$PRIMARY_CONTAINER_STATUS" == running ]] ||
            RUNTIME_FINDINGS+=(
                "Primary DNS answers, but container '${PRIMARY_CONTAINER}' reports state=${PRIMARY_CONTAINER_STATUS}"
            )

        [[ "$PRIMARY_CONTAINER_HEALTH" != unhealthy ]] ||
            RUNTIME_FINDINGS+=(
                "Primary DNS answers, but Docker health reports unhealthy"
            )

        [[ "$PRIMARY_CONTAINER_OOM" != true ]] ||
            RUNTIME_FINDINGS+=(
                "Primary DNS answers, but Docker reports OOMKilled=true"
            )
    fi

    if [[ "$PRIMARY_DNS_OK" == true && "$PRIMARY_LOCAL_OK" != true ]]; then
        RUNTIME_FINDINGS+=(
            "Primary external DNS works, but local check '${LOCAL_TEST_DOMAIN}' failed"
        )
    fi

    if [[ "$FALLBACK_DNS_OK" == true && "$FALLBACK_LOCAL_OK" != true ]]; then
        RUNTIME_FINDINGS+=(
            "Fallback external DNS works, but local check '${LOCAL_TEST_DOMAIN}' failed"
        )
    fi
}


classify_dns_state() {
    if [[ "$PRIMARY_IN_MAINTENANCE" == true ]]; then
        if [[ "$FALLBACK_DNS_OK" == true ]]; then CLASSIFICATION=PRIMARY_MAINTENANCE; else CLASSIFICATION=FALLBACK_FAILED; fi
        return 0
    fi
    if [[ "$PRIMARY_DNS_OK" == true && "$FALLBACK_DNS_OK" == true ]]; then
        CLASSIFICATION="HEALTHY"
    elif [[ "$PRIMARY_DNS_OK" != true && "$FALLBACK_DNS_OK" == true ]]; then
        CLASSIFICATION="PRIMARY_FAILED"
    elif [[ "$PRIMARY_DNS_OK" == true && "$FALLBACK_DNS_OK" != true ]]; then
        CLASSIFICATION="FALLBACK_FAILED"
    elif [[ "$PRIMARY_LOCAL_OK" == true && "$FALLBACK_LOCAL_OK" == true ]]; then
        CLASSIFICATION="SHARED_UPSTREAM_FAILURE"
    else
        CLASSIFICATION="BOTH_FAILED"
    fi
}


update_failure_counters() {
    if [[ "$IN_BOOT_GRACE" == true ]]; then
        PRIMARY_FAILURES=0
        FALLBACK_FAILURES=0
        return
    fi

    if [[ "$PRIMARY_IN_MAINTENANCE" == true ]]; then
        : # Preserve earlier primary failures; planned downtime is no evidence.
    elif [[ "$PRIMARY_DNS_OK" == true || "$PRIMARY_STARTING" == true ]]; then
        PRIMARY_FAILURES=0
    else
        PRIMARY_FAILURES=$((PRIMARY_FAILURES + 1))
    fi

    if [[ "$FALLBACK_DNS_OK" == true ]]; then
        FALLBACK_FAILURES=0
    else
        FALLBACK_FAILURES=$((FALLBACK_FAILURES + 1))
    fi
}

###############################################################################
# CONTROLLED RECOVERY
###############################################################################

primary_recovery_needed() {
    [[ "$PRIMARY_DNS_OK" != true ]] || return 1

    [[ "$PRIMARY_LOCAL_OK" != true ||
       "$PRIMARY_CONTAINER_STATUS" != running ||
       "$PRIMARY_CONTAINER_HEALTH" == unhealthy ||
       "$PRIMARY_CONTAINER_OOM" == true ]]
}


fallback_recovery_needed() {
    [[ "$FALLBACK_DNS_OK" != true && "$FALLBACK_LOCAL_OK" != true ]]
}


recover_primary() {
    maintenance_active primary && return 0
    local action="restart"
    local success=false

    PRIMARY_LAST_ACTION="$START_EPOCH"

    if [[ "$PRIMARY_CONTAINER_STATUS" != running ]]; then
        action="start"
    fi

    if ! docker info >/dev/null 2>&1; then
        ACTIONS+=("Primary recovery failed: Docker service is unavailable")
        return 1
    fi

    log WARN "Attempting primary Pi-hole container ${action}"

    if [[ "$action" == start ]]; then
        docker start "$PRIMARY_CONTAINER" >/dev/null 2>&1 || true
    else
        docker restart "$PRIMARY_CONTAINER" >/dev/null 2>&1 || true
    fi

    sleep "$PRIMARY_RESTART_WAIT_SECONDS"
    inspect_primary_container || true
    if [[ "$PRIMARY_IN_MAINTENANCE" == true ]]; then
        PRIMARY_UDP_REASON="planned maintenance; not tested"; PRIMARY_TCP_REASON="$PRIMARY_UDP_REASON"; PRIMARY_LOCAL_REASON="$PRIMARY_UDP_REASON"
        log INFO 'Primary planned maintenance; primary checks/recovery deferred; fallback remains monitored'
    else
        check_dns_endpoint PRIMARY "$PRIMARY_DNS_IP" "$PRIMARY_LOCAL_EXPECTED"
    fi

    if [[ "$PRIMARY_DNS_OK" == true ]]; then
        PRIMARY_FAILURES=0
        success=true
        ACTIONS+=("Primary: container ${action} restored UDP and TCP DNS")
    else
        ACTIONS+=("Primary: container ${action} completed but DNS remains unavailable")
    fi

    [[ "$success" == true ]]
}


recover_fallback() {
    local success=false

    FALLBACK_LAST_ACTION="$START_EPOCH"
    log WARN "Attempting Raspberry Pi pihole-FTL restart"

    if ! fallback_ssh "true" >/dev/null 2>&1; then
        ACTIONS+=("Fallback recovery failed: SSH is unavailable")
        return 1
    fi

    if ! fallback_ssh \
        "sudo -n systemctl restart pihole-FTL" >/dev/null 2>&1
    then
        ACTIONS+=("Fallback recovery failed: pihole-FTL restart command failed")
        return 1
    fi

    sleep "$FALLBACK_RESTART_WAIT_SECONDS"
    check_dns_endpoint FALLBACK "$FALLBACK_DNS_IP" "$FALLBACK_LOCAL_EXPECTED"

    if [[ "$FALLBACK_DNS_OK" == true ]]; then
        FALLBACK_FAILURES=0
        success=true
        ACTIONS+=("Fallback: pihole-FTL restart restored UDP and TCP DNS")
    else
        ACTIONS+=("Fallback: pihole-FTL restarted but DNS remains unavailable")
    fi

    [[ "$success" == true ]]
}


run_recovery_actions() {
    local primary_due=false
    local fallback_due=false

    [[ "$IN_BOOT_GRACE" == true || "$CLASSIFICATION" == SHARED_UPSTREAM_FAILURE ]] &&
        return 0

    if [[ "$ENABLE_PRIMARY_RECOVERY" == true &&
          "$PRIMARY_STARTING" != true ]] &&
       (( PRIMARY_FAILURES >= PRIMARY_FAIL_THRESHOLD )) &&
       (( START_EPOCH - PRIMARY_LAST_ACTION >= RECOVERY_COOLDOWN_SECONDS )) &&
       ! maintenance_active primary &&
       primary_recovery_needed
    then
        primary_due=true
    fi

    if [[ "$ENABLE_FALLBACK_RECOVERY" == true ]] &&
       (( FALLBACK_FAILURES >= FALLBACK_FAIL_THRESHOLD )) &&
       (( START_EPOCH - FALLBACK_LAST_ACTION >= RECOVERY_COOLDOWN_SECONDS )) &&
       ! maintenance_active fallback &&
       fallback_recovery_needed
    then
        fallback_due=true
    fi

    [[ "$primary_due" == true ]] && recover_primary || true
    [[ "$fallback_due" == true ]] && recover_fallback || true

    classify_dns_state
}

###############################################################################
# DAILY DEEP HEALTH AND CONSISTENCY
###############################################################################

normalized_dns_answer() {
    local server="$1"
    local domain="$2"

    dig @"$server" "$domain" A \
        +time="$DNS_TIMEOUT_SECONDS" +tries=1 +short 2>/dev/null |
        sort -u
}


dns_fingerprint() {
    local server="$1"
    local domain="$2"
    local output=""
    local status=""
    local answers=""

    output="$(
        dig @"$server" "$domain" A \
            +time="$DNS_TIMEOUT_SECONDS" +tries=1 \
            +noall +comments +answer 2>/dev/null || true
    )"
    status="$(sed -n 's/.*status: \([^,]*\),.*/\1/p' <<<"$output" | head -n 1)"
    answers="$(awk '$4 == "A" {print $5}' <<<"$output" | sort -u | tr '\n' ',')"
    printf '%s|%s\n' "${status:-transport-failure}" "${answers:-none}"
}


run_deep_check() {
    local deep_output=""
    local ftl=""
    local disk_percent=""
    local temperature=""
    local primary_answer=""
    local fallback_answer=""
    local primary_block=""
    local fallback_block=""
    local primary_upstreams=""
    local fallback_upstreams=""

    DEEP_FINDINGS=()
    LAST_DEEP_EPOCH="$START_EPOCH"

    if deep_output="$(
        fallback_ssh \
            "printf 'ftl='; systemctl is-active pihole-FTL 2>/dev/null || true; printf 'disk='; df -Pk / | awk 'NR==2 {gsub(/%/,\"\",\$5); print \$5}'; printf 'temp='; vcgencmd measure_temp 2>/dev/null | sed -n 's/.*=\([0-9.]*\).*/\1/p'" \
            2>/dev/null
    )"
    then
        ftl="$(sed -n 's/^ftl=//p' <<<"$deep_output" | head -n 1)"
        disk_percent="$(sed -n 's/^disk=//p' <<<"$deep_output" | head -n 1)"
        temperature="$(sed -n 's/^temp=//p' <<<"$deep_output" | head -n 1)"

        [[ "$ftl" == active ]] ||
            DEEP_FINDINGS+=("Fallback FTL service is not active")

        if [[ "$disk_percent" =~ ^[0-9]+$ ]] &&
           (( disk_percent >= FALLBACK_DISK_WARNING_PERCENT )); then
            DEEP_FINDINGS+=("Fallback root filesystem usage is ${disk_percent}%")
        fi

        if [[ "$temperature" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
           awk -v value="$temperature" -v limit="$FALLBACK_TEMPERATURE_WARNING_C" \
               'BEGIN { exit !(value >= limit) }'
        then
            DEEP_FINDINGS+=("Fallback temperature is ${temperature} C")
        fi
    else
        DEEP_FINDINGS+=("Fallback SSH is unavailable for the daily deep-health check")
    fi

    if [[ -n "$CONSISTENCY_TEST_DOMAIN" ]]; then
        primary_answer="$(normalized_dns_answer "$PRIMARY_DNS_IP" "$CONSISTENCY_TEST_DOMAIN")"
        fallback_answer="$(normalized_dns_answer "$FALLBACK_DNS_IP" "$CONSISTENCY_TEST_DOMAIN")"

        if [[ -z "$primary_answer" || "$primary_answer" != "$fallback_answer" ]]; then
            DEEP_FINDINGS+=(
                "DNS consistency mismatch for ${CONSISTENCY_TEST_DOMAIN}: primary=${primary_answer:-none}, fallback=${fallback_answer:-none}"
            )
        fi
    fi

    if [[ -n "$BLOCK_TEST_DOMAIN" ]]; then
        primary_block="$(dns_fingerprint "$PRIMARY_DNS_IP" "$BLOCK_TEST_DOMAIN")"
        fallback_block="$(dns_fingerprint "$FALLBACK_DNS_IP" "$BLOCK_TEST_DOMAIN")"

        if [[ "$primary_block" != "$fallback_block" ]]; then
            DEEP_FINDINGS+=(
                "Blocking-policy mismatch for ${BLOCK_TEST_DOMAIN}: primary=${primary_block}, fallback=${fallback_block}"
            )
        fi
    fi

    if grep -Eq "^[[:space:]]*nameserver[[:space:]]+${PRIMARY_DNS_IP//./\\.}([[:space:]]|$)" \
        /etc/resolv.conf 2>/dev/null &&
       ! grep -Eq "^[[:space:]]*nameserver[[:space:]]+${FALLBACK_DNS_IP//./\\.}([[:space:]]|$)" \
        /etc/resolv.conf 2>/dev/null
    then
        DEEP_FINDINGS+=(
            "Unraid system DNS depends on the primary Pi-hole without the Raspberry Pi fallback"
        )
    fi

    primary_upstreams="$(
        docker exec "$PRIMARY_CONTAINER" \
            pihole-FTL --config dns.upstreams 2>/dev/null || true
    )"
    fallback_upstreams="$(
        fallback_ssh \
            "sudo -n pihole-FTL --config dns.upstreams" 2>/dev/null || true
    )"

    if grep -Fq -- "$FALLBACK_DNS_IP" <<<"$primary_upstreams"; then
        DEEP_FINDINGS+=("Primary Pi-hole forwards upstream queries to the fallback Pi-hole")
    fi

    if grep -Fq -- "$PRIMARY_DNS_IP" <<<"$fallback_upstreams"; then
        DEEP_FINDINGS+=("Fallback Pi-hole forwards upstream queries to the primary Pi-hole")
    fi
}


deep_check_due() {
    local interval="$DEEP_CHECK_INTERVAL_SECONDS"

    if (( ${#DEEP_FINDINGS[@]} > 0 )); then
        interval="$DEEP_FAILURE_RECHECK_SECONDS"
    fi

    (( START_EPOCH - LAST_DEEP_EPOCH >= interval ))
}

###############################################################################
# NOTIFICATION LIFECYCLE
###############################################################################

classification_notifiable() {
    [[ "$IN_BOOT_GRACE" == true ]] && return 1

    case "$CLASSIFICATION" in
        HEALTHY)
            (( ${#DEEP_FINDINGS[@]} > 0 || ${#EVENTS[@]} > 0 ||
               ${#RUNTIME_FINDINGS[@]} > 0 || ${#ACTIONS[@]} > 0 )) ||
                [[ "$PREVIOUS_NOTIFY_CLASSIFICATION" != HEALTHY ]] ||
                [[ "$PREVIOUS_NOTIFY_EPOCH" -gt 0 &&
                   "$CURRENT_SIGNATURE" != "$PREVIOUS_NOTIFY_SIGNATURE" ]]
            ;;
        PRIMARY_FAILED)
            (( PRIMARY_FAILURES >= PRIMARY_FAIL_THRESHOLD ))
            ;;
        FALLBACK_FAILED)
            (( FALLBACK_FAILURES >= FALLBACK_FAIL_THRESHOLD ))
            ;;
        BOTH_FAILED|SHARED_UPSTREAM_FAILURE)
            (( PRIMARY_FAILURES >= BOTH_FAIL_THRESHOLD &&
               FALLBACK_FAILURES >= BOTH_FAIL_THRESHOLD ))
            ;;
        *)
            return 1
            ;;
    esac
}


notification_suppressed_by_maintenance() {
    maintenance_active all && return 0

    case "$CLASSIFICATION" in
        PRIMARY_FAILED) maintenance_active primary ;;
        FALLBACK_FAILED) maintenance_active fallback ;;
        BOTH_FAILED|SHARED_UPSTREAM_FAILURE)
            maintenance_active primary && maintenance_active fallback
            ;;
        *) return 1 ;;
    esac
}


build_signature() {
    {
        printf '%s\n' "$CLASSIFICATION"
        printf '%s\n' "${DEEP_FINDINGS[@]}"
        printf '%s\n' "${RUNTIME_FINDINGS[@]}"
    } | sha256sum | awk '{print $1}'
}


notification_due() {
    (( ${#ACTIONS[@]} > 0 || ${#EVENTS[@]} > 0 )) && return 0
    classification_notifiable || return 1
    notification_suppressed_by_maintenance && return 1

    [[ "$CURRENT_SIGNATURE" != "$PREVIOUS_NOTIFY_SIGNATURE" ]] && return 0
    (( START_EPOCH - PREVIOUS_NOTIFY_EPOCH >= REMINDER_SECONDS ))
}


append_array_block() {
    local label="$1"
    shift
    local item=""

    (( $# > 0 )) || return 0
    printf '%s:\n' "$label"
    for item in "$@"; do
        printf -- '- %s\n' "$item"
    done
}


build_notification_body() {
    local body=""

    body+="Classification: ${CLASSIFICATION}"$'\n'
    body+=$'\n'
    body+="Primary maintenance: ${PRIMARY_IN_MAINTENANCE}"$'\n'
    body+="Primary Unraid Pi-hole (${PRIMARY_DNS_IP}): ${PRIMARY_DNS_OK}"$'\n'
    body+="  UDP: ${PRIMARY_UDP_OK} (${PRIMARY_UDP_REASON}, ${PRIMARY_UDP_MS} ms)"$'\n'
    body+="  TCP: ${PRIMARY_TCP_OK} (${PRIMARY_TCP_REASON}, ${PRIMARY_TCP_MS} ms)"$'\n'
    body+="  Local: ${PRIMARY_LOCAL_OK} (${PRIMARY_LOCAL_REASON})"$'\n'
    body+="  Container: ${PRIMARY_CONTAINER_STATUS}, health=${PRIMARY_CONTAINER_HEALTH}, OOM=${PRIMARY_CONTAINER_OOM}"$'\n'
    body+="  Consecutive failures: ${PRIMARY_FAILURES}"$'\n'
    body+=$'\n'
    body+="Fallback Raspberry Pi (${FALLBACK_DNS_IP}): ${FALLBACK_DNS_OK}"$'\n'
    body+="  UDP: ${FALLBACK_UDP_OK} (${FALLBACK_UDP_REASON}, ${FALLBACK_UDP_MS} ms)"$'\n'
    body+="  TCP: ${FALLBACK_TCP_OK} (${FALLBACK_TCP_REASON}, ${FALLBACK_TCP_MS} ms)"$'\n'
    body+="  Local: ${FALLBACK_LOCAL_OK} (${FALLBACK_LOCAL_REASON})"$'\n'
    body+="  Ping diagnostic: ${FALLBACK_PING_OK}"$'\n'
    body+="  Consecutive failures: ${FALLBACK_FAILURES}"$'\n'

    if (( ${#ACTIONS[@]} > 0 )); then
        body+=$'\n'
        body+="$(append_array_block "Automatic actions" "${ACTIONS[@]}")"
    fi

    if (( ${#EVENTS[@]} > 0 )); then
        body+=$'\n'
        body+="$(append_array_block "Events" "${EVENTS[@]}")"
    fi

    if (( ${#DEEP_FINDINGS[@]} > 0 )); then
        body+=$'\n'
        body+="$(append_array_block "Deep-health findings" "${DEEP_FINDINGS[@]}")"
    fi

    if (( ${#RUNTIME_FINDINGS[@]} > 0 )); then
        body+=$'\n'
        body+="$(append_array_block "Runtime findings" "${RUNTIME_FINDINGS[@]}")"
    fi

    printf '%s' "$body"
}


send_lifecycle_notification() {
    local importance="warning"
    local description="DNS redundancy degraded"
    local body=""

    CURRENT_SIGNATURE="$(build_signature)"
    notification_due || return 0
    body="$(build_notification_body)"

    case "$CLASSIFICATION" in
        HEALTHY)
            if (( ${#ACTIONS[@]} > 0 )); then
                importance="normal"
                description="DNS redundancy automatically recovered"
            elif [[ "$PREVIOUS_NOTIFY_CLASSIFICATION" != HEALTHY &&
                    ${#DEEP_FINDINGS[@]} -eq 0 &&
                    ${#RUNTIME_FINDINGS[@]} -eq 0 ]]; then
                importance="normal"
                description="DNS redundancy restored"
            elif [[ "$CURRENT_SIGNATURE" != "$PREVIOUS_NOTIFY_SIGNATURE" &&
                    ${#DEEP_FINDINGS[@]} -eq 0 &&
                    ${#RUNTIME_FINDINGS[@]} -eq 0 &&
                    ${#EVENTS[@]} -eq 0 ]]; then
                importance="normal"
                description="DNS watchdog findings cleared"
            else
                importance="warning"
                description="DNS watchdog findings"
            fi
            ;;
        PRIMARY_FAILED)
            importance="warning"
            description="Primary DNS failed; fallback available"
            ;;
        FALLBACK_FAILED)
            importance="warning"
            description="DNS fallback redundancy lost"
            ;;
        SHARED_UPSTREAM_FAILURE)
            importance="alert"
            description="Both Pi-holes have an upstream DNS failure"
            ;;
        BOTH_FAILED)
            importance="alert"
            description="Both DNS resolvers are unavailable"
            ;;
    esac

    if [[ "$CURRENT_SIGNATURE" == "$PREVIOUS_NOTIFY_SIGNATURE" &&
          "$CLASSIFICATION" != HEALTHY ]]; then
        description="${description} - reminder"
    fi

    if notify_unraid "$importance" "$description" "$body"; then
        NOTIFICATION_SENT=true
        log INFO "Notification sent: $description"
    else
        log ERROR "Notification failed: $description"
    fi
}

###############################################################################
# MAIN
###############################################################################

record_dns_latency() {
    local path="$STATE_DIR/latency.json" temp
    [[ -f "$path" ]] || printf '{"schema":1,"samples":[]}' >"$path"
    temp=$(mktemp "$STATE_DIR/.latency.XXXXXX") || return 1
    jq --argjson at "$(date +%s)" --argjson pu "$PRIMARY_UDP_MS" --argjson pt "$PRIMARY_TCP_MS" --argjson fu "$FALLBACK_UDP_MS" --argjson ft "$FALLBACK_TCP_MS" '
      .samples=((.samples+[{at:$at,primaryUDP:$pu,primaryTCP:$pt,fallbackUDP:$fu,fallbackTCP:$ft}])|.[-720:]) |
      . as $s|.trends=(["primaryUDP","primaryTCP","fallbackUDP","fallbackTCP"]|map(. as $k|($s.samples|map(.[$k]|select(.>=0))|sort) as $v|{key:$k,value:{samples:($v|length),p95ms:(if ($v|length)>0 then $v[((($v|length)-1)*0.95|floor)] else null end)}})|from_entries)' "$path" >"$temp" && mv "$temp" "$path"
}

main() {
    local uptime_seconds=0

    if ! validate_configuration; then
        RESULT_STATUS="CRITICAL"
        RESULT_SUMMARY="Configuration or required-command validation failed"
        return 1
    fi

    mkdir -p -- "$STATE_DIR" "$MAINTENANCE_DIR" "$STATUS_DIR" || return 1
    rotate_log
    touch "$LOG_FILE" || return 1

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        RESULT_STATUS="WARNING"
        RESULT_SUMMARY="Another DNS watchdog run is active"
        log WARN "$RESULT_SUMMARY"
        return 0
    fi

    exec {STATE_EXPORT_FD}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || return 1
    if ! flock -s -n "$STATE_EXPORT_FD"; then printf 'State export active; DNS scan deferred.\n'; return 0; fi
    primary_maintenance_gate || return 1
    TMP_DIR="$(mktemp -d /tmp/dns-redundancy-watchdog.XXXXXX)" || return 1
    initialize_state

    uptime_seconds="$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || printf '0')"
    [[ "$uptime_seconds" =~ ^[0-9]+$ ]] || uptime_seconds=0
    if (( uptime_seconds > 0 && uptime_seconds < BOOT_GRACE_SECONDS )); then
        IN_BOOT_GRACE=true
        log INFO "Unraid boot grace is active (${uptime_seconds}s/${BOOT_GRACE_SECONDS}s)"
    fi

    log INFO "Starting DNS redundancy watchdog v${SCRIPT_VERSION}"

    check_dns_endpoint PRIMARY "$PRIMARY_DNS_IP" "$PRIMARY_LOCAL_EXPECTED"
    check_dns_endpoint FALLBACK "$FALLBACK_DNS_IP" "$FALLBACK_LOCAL_EXPECTED"

    if [[ "$FALLBACK_DNS_OK" != true ]]; then
        if ping -c 2 -W 2 "$FALLBACK_DNS_IP" >/dev/null 2>&1; then
            FALLBACK_PING_OK="true"
        else
            FALLBACK_PING_OK="false"
        fi
    fi

    if [[ "$PRIMARY_IN_MAINTENANCE" != true ]]; then
        inspect_primary_container || log WARN "Unable to inspect primary container: $PRIMARY_CONTAINER"
    fi

    classify_dns_state
    update_failure_counters

    log INFO \
        "Initial classification=${CLASSIFICATION}; primary=${PRIMARY_DNS_OK} (${PRIMARY_FAILURES}), fallback=${FALLBACK_DNS_OK} (${FALLBACK_FAILURES})"

    local platform_version
    if [[ -r "${UNRAID_VERSION_FILE:-/etc/unraid-version}" ]]; then
        platform_version=$(sed -n 's/^version="\([^"]*\)"/\1/p' "${UNRAID_VERSION_FILE:-/etc/unraid-version}")
        if [[ "$platform_version" != 7.* ]]; then ENABLE_PRIMARY_RECOVERY=false; ENABLE_FALLBACK_RECOVERY=false; log WARN 'Unvalidated Unraid major; DNS recovery prohibited; probes continue'; fi
    fi
    run_recovery_actions

    record_dns_latency || log WARN 'Latency trend checkpoint unavailable; DNS answers remain authoritative'
    collect_runtime_findings

    if [[ "$IN_BOOT_GRACE" != true && "$PRIMARY_IN_MAINTENANCE" != true ]] && deep_check_due; then
        run_deep_check
    fi

    send_lifecycle_notification

    if ! commit_state; then
        RESULT_STATUS="CRITICAL"
        RESULT_SUMMARY="Unable to commit DNS watchdog state"
        log ERROR "$RESULT_SUMMARY"
        return 1
    fi

    case "$CLASSIFICATION" in
        PRIMARY_MAINTENANCE) RESULT_STATUS="MAINTENANCE" ;;
        HEALTHY)
            if (( ${#DEEP_FINDINGS[@]} > 0 || ${#RUNTIME_FINDINGS[@]} > 0 )); then
                RESULT_STATUS="WARNING"
            else
                RESULT_STATUS="OK"
            fi
            ;;
        PRIMARY_FAILED|FALLBACK_FAILED)
            RESULT_STATUS="WARNING"
            ;;
        BOTH_FAILED|SHARED_UPSTREAM_FAILURE)
            RESULT_STATUS="CRITICAL"
            ;;
        *)
            RESULT_STATUS="FAILED"
            ;;
    esac

    local primary_report="$PRIMARY_DNS_OK"
    [[ "$PRIMARY_IN_MAINTENANCE" != true ]] || primary_report="maintenance (not tested)"
    RESULT_SUMMARY="${CLASSIFICATION}; primary=${primary_report}; fallback=${FALLBACK_DNS_OK}; actions=${#ACTIONS[@]}; findings=$(( ${#DEEP_FINDINGS[@]} + ${#RUNTIME_FINDINGS[@]} ))"
    log INFO "$RESULT_SUMMARY"
    write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"

    [[ "$RESULT_STATUS" != CRITICAL && "$RESULT_STATUS" != FAILED ]]
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
