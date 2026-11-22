#!/bin/bash

###############################################################################
# Metadata Quarantine Lifecycle Manager
#
# Audits, restores, and optionally expires run directories created by
# metadata_cleanup.sh and arr_delete_sync_tag.sh under /mnt/user/media/bin.
#
# Usage:
#   quarantine_lifecycle.sh audit
#   quarantine_lifecycle.sh purge
#   quarantine_lifecycle.sh restore RUN_ID movies|series RELATIVE_PATH
###############################################################################

set -uo pipefail
umask 077

readonly SCRIPT_VERSION="1.3.0"
readonly REQUIRED_PURGE_CONFIRMATION="DELETE_EXPIRED_QUARANTINE"

###############################################################################
# CONFIGURATION
###############################################################################

QUARANTINE_ROOT="/mnt/user/media/bin"
MOVIES_ROOT="/mnt/user/media/movies"
SERIES_ROOT="/mnt/user/media/series"

RETENTION_DAYS=45
WARNING_TOTAL_BYTES=$((500 * 1024 * 1024 * 1024))

# Unraid User Scripts normally invokes scheduled scripts without arguments.
# Keep purge as the default so expired runs are handled automatically; use an
# explicit "audit" argument for report-only runs.
DEFAULT_MODE="purge"

# Both positive gates must match before purge can delete anything.
PURGE_ENABLED=true
PURGE_CONFIRMATION="DELETE_EXPIRED_QUARANTINE"

# Bound each scheduled deletion pass. Oldest runs are processed first and any
# remainder is retried by the next scheduled run.
MAX_PURGE_RUNS_PER_EXECUTION=25
MAX_PURGE_BYTES_PER_EXECUTION=$((10 * 1024 * 1024 * 1024))

# Purging through /mnt/user is safe during parity checks, but defer while Mover
# is actively changing user-share placement.
DEFER_PURGE_WHILE_MOVER=true
QUARANTINE_COORDINATION_LOCK="/tmp/arr_metadata_quarantine.lock"
# Newly changed runs are protected even when their run ID is old.
MIN_RUN_IDLE_HOURS=24

LOG_DIR="/mnt/vault/cloud/logs/script/quarantine_lifecycle"
LOG_FILE="${LOG_DIR}/quarantine-lifecycle.log"
INDEX_FILE="${LOG_DIR}/quarantine-index.tsv"
NOTIFICATION_STATE_FILE="${LOG_DIR}/notification-state.json"
OPS_NOTIFICATION_STATE="$NOTIFICATION_STATE_FILE"
# Compact operational logs; full inventories remain in deletion receipts.
LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_BACKUP_FILES=2
LOG_RETENTION_DAYS=30
LOG_LINE_MAX_BYTES=4096

LOG_MAX_BYTES=$((1 * 1024 * 1024))

# A purge receipt is committed to the vault before its corresponding run is
# deleted. The notification stays bounded while the receipt preserves every
# purged path for later review.
PURGE_RECEIPT_DIR="${LOG_DIR}/purge-receipts"
PURGE_RECEIPT_RETENTION_DAYS=365
PURGE_NOTIFICATION_FILE_LIMIT=10

STATUS_DIR="/mnt/vault/cloud/logs/script/user_scripts_status"
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
LOCK_FILE="/run/quarantine_lifecycle.lock"

###############################################################################
# RUNTIME
###############################################################################

START_EPOCH="$(date +%s)"
NOTIFICATION_ATTEMPTED=false
OPS_NOTIFICATION_DELIVERED=false
AUDIT_ATTENTION_DETAILS=""
RESULT_STATUS="FAILED"
RESULT_SUMMARY="Quarantine lifecycle exited before completion"
RECEIPT_WRITTEN=0

RUNS_SCANNED=0
EXPIRED_RUNS=0
FILES_SCANNED=0
TOTAL_BYTES=0
PURGED_RUNS=0
PURGED_BYTES=0
PURGED_FILES=0
UNMANAGED_ENTRIES=0
SCAN_ERRORS=0
PURGE_LIMIT_REACHED=0
PURGE_DEFERRED_REASON=""
REMAINING_EXPIRED_RUNS=0
PURGE_RECEIPT_FILE=""
PURGE_RUN_DETAILS=""
PURGE_FILE_CANDIDATES=""
RUNTIME_DIR=""

INVENTORY_FILE_COUNT=0
INVENTORY_BYTE_COUNT=0
INVENTORY_MOVIE_FILES=0
INVENTORY_SERIES_FILES=0

QUARANTINE_REAL=""
MOVIES_REAL=""
SERIES_REAL=""

###############################################################################
# HELPERS
###############################################################################

OPS_SCRIPT_NAME="quarantine_lifecycle"
OPS_SCRIPT_VERSION="1.3.0"
OPS_RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
OPS_ATTENTION_DETAILS=""
OPS_ATTENTION_FILE=""
OPS_LOG_BYTES=""

# Shared operational logging convention, embedded to keep User Scripts standalone.
# INFO records actions, warnings and one completion summary. DEBUG adds routine
# progress. Numbered backups expire by size, count and age; receipts are separate.
ops_initialize_log() {
    local file suffix bytes now cutoff
    [[ ! -L "$LOG_FILE" ]] || return 1
    now=$(date +%s); cutoff=$((now-LOG_RETENTION_DAYS*86400))
    for file in "$LOG_FILE".[0-9]*; do
        [[ -f "$file" ]] || continue
        suffix=${file##*.}; [[ "$suffix" =~ ^[0-9]+$ ]] || continue
        bytes=$(stat -c '%s' "$file") || return 1
        if (( suffix>LOG_BACKUP_FILES || bytes>LOG_MAX_BYTES || (LOG_RETENTION_DAYS>0 && $(stat -c '%Y' "$file")<=cutoff) )); then
            rm -f -- "$file" || return 1
        fi
    done
    : >>"$LOG_FILE" || return 1
    OPS_LOG_BYTES=$(stat -c '%s' "$LOG_FILE") || return 1
    if (( OPS_LOG_BYTES>LOG_MAX_BYTES*4 )); then : >"$LOG_FILE"; OPS_LOG_BYTES=0; fi
    if (( OPS_LOG_BYTES>=LOG_MAX_BYTES )); then ops_rotate_log || return 1; fi
}

ops_rotate_log() {
    local i
    rm -f -- "$LOG_FILE.$LOG_BACKUP_FILES" || return 1
    for ((i=LOG_BACKUP_FILES-1;i>=1;i--)); do
        [[ ! -f "$LOG_FILE.$i" ]] || mv -f -- "$LOG_FILE.$i" "$LOG_FILE.$((i+1))" || return 1
    done
    [[ ! -f "$LOG_FILE" ]] || mv -f -- "$LOG_FILE" "$LOG_FILE.1" || return 1
    : >"$LOG_FILE" || return 1
    OPS_LOG_BYTES=0
}

ops_log() {
    local level="$1" message line size
    local LC_ALL=C
    shift; message="$*"
    [[ "$level" != DEBUG || "${LOG_LEVEL^^}" == DEBUG ]] || return 0
    case "$level" in
        WARN|WARNING|ERROR|CRITICAL)
            OPS_ATTENTION_DETAILS+="- [$level] $message"$'\n'
            if [[ -n "${OPS_ATTENTION_FILE:-}" ]]; then printf '%s\n' "- [$level] $message" >>"$OPS_ATTENTION_FILE"; fi
            ;;
    esac
    if (( ${#message}>LOG_LINE_MAX_BYTES )); then message="${message:0:LOG_LINE_MAX_BYTES} ... [line truncated]"; fi
    printf -v line '%s | %s | %s v%s | run=%s | %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$OPS_SCRIPT_NAME" "$OPS_SCRIPT_VERSION" "$OPS_RUN_ID" "$message"
    printf '%s\n' "$line" >&2
    [[ -d "${LOG_FILE%/*}" ]] || return 0
    [[ -n "${OPS_LOG_BYTES:-}" ]] || ops_initialize_log || return 1
    size=$(( ${#line}+1 ))
    if (( OPS_LOG_BYTES+size>LOG_MAX_BYTES )); then ops_rotate_log || return 1; fi
    printf '%s\n' "$line" >>"$LOG_FILE" || return 1
    OPS_LOG_BYTES=$(( OPS_LOG_BYTES+size ))
}

# Durable daily outbox. Unsent chunks survive failures, daily limits and caps.
ops_notification_state() {
    local tmp
    [[ ! -L "$OPS_NOTIFICATION_STATE" ]] || return 1
    if [[ ! -e "$OPS_NOTIFICATION_STATE" ]]; then
        tmp=$(mktemp "${LOG_DIR}/.notify-state.XXXXXX") || return 1
        printf '%s\n' '{"version":1,"outbox":[],"attention":{}}' >"$tmp" && mv -f -- "$tmp" "$OPS_NOTIFICATION_STATE" || return 1
    fi
    jq -e 'type=="object" and ((.outbox // [])|type)=="array"' "$OPS_NOTIFICATION_STATE" >/dev/null
}

ops_notify() {
    local importance="$1" subject="$2" description="$3" message="$4" tmp message_file id
    OPS_NOTIFICATION_DELIVERED=false
    ops_notification_state || return 1
    message_file=$(mktemp "${LOG_DIR}/.notify-message.XXXXXX") || return 1
    printf '%s' "$message" >"$message_file" || return 1
    id=$( { printf '%s\n' "$subject" "$description"; cat "$message_file"; } | sha256sum | cut -d ' ' -f1)
    tmp=$(mktemp "${LOG_DIR}/.notify-outbox.XXXXXX") || return 1
    jq --arg id "$id" --arg importance "$importance" --arg subject "$subject" --arg description "$description" \
      --rawfile message "$message_file" --arg at "$(date -Iseconds)" '
      .outbox //= []
      | if any(.outbox[]; .eventId==$id) then . else
          .outbox += [range(0;([$message|length,1]|max);8000) as $offset |
            {eventId:$id,id:($id+":"+($offset|tostring)),importance:$importance,subject:$subject,description:$description,
             message:$message[$offset:$offset+8000],offset:$offset,queuedAt:$at}]
        end
    ' "$OPS_NOTIFICATION_STATE" >"$tmp" && mv -f -- "$tmp" "$OPS_NOTIFICATION_STATE" || { rm -f -- "$tmp" "$message_file"; return 1; }
    rm -f -- "$message_file"
    ops_flush_notifications || return 1
    if ! jq -e --arg id "$id" 'any(.outbox[]?;.eventId==$id)' "$OPS_NOTIFICATION_STATE" >/dev/null; then OPS_NOTIFICATION_DELIVERED=true; fi
}

ops_flush_notifications() {
    local tmp selected body importance subject count today="$(date +%F)" notify_bin="${NOTIFY_BIN:-${NOTIFY:-}}"
    ops_notification_state || return 1
    jq -e '(.outbox // []|length)>0' "$OPS_NOTIFICATION_STATE" >/dev/null || return 0
    [[ "$(jq -r '.lastSentAt // ""' "$OPS_NOTIFICATION_STATE")" != "$today"* ]] || return 0
    selected=$(mktemp "${LOG_DIR}/.notify-selected.XXXXXX") || return 1
    jq '[.outbox | sort_by((if .importance=="alert" then 0 elif .importance=="warning" then 1 else 2 end),.queuedAt,.eventId,(.offset // 0)) | .[0]]' "$OPS_NOTIFICATION_STATE" >"$selected" || return 1
    # Each complete chunk stays below the platform argv limit, including UTF-8.
    body=$(jq -r '.[0] | "Queued: "+.queuedAt+"\n"+.description+"\n\n"+.message' "$selected")
    importance=$(jq -r '.[0].importance' "$selected"); subject=$(jq -r '.[0].subject' "$selected")
    body=$(printf '%s' "$body" | jq -Rsr 'explode | map(select(.!=8205 and .!=8419 and .!=65039 and (. < 9728 or . > 10175) and (. < 126976 or . > 129791))) | implode')
    count=$(jq '.outbox|length' "$OPS_NOTIFICATION_STATE")
    if (( count>1 )); then body+=$'\n\n'"$((count-1)) further report chunk(s) remain queued for a later daily notification."; fi
    if [[ ! -x "$notify_bin" ]] || ! "$notify_bin" -i "$importance" -s "$subject" -d "Operational actions and exceptions" -m "$body" >/dev/null 2>&1; then
        rm -f -- "$selected"
        ops_log ERROR "Notification delivery failed; detailed report retained in the daily outbox."
        return 1
    fi
    tmp=$(mktemp "${LOG_DIR}/.notify-sent.XXXXXX") || return 1
    jq --slurpfile selected "$selected" --arg now "$(date -Iseconds)" \
      '.outbox |= map(. as $event | select(any($selected[0][]; .id==$event.id)|not)) | .lastSentAt=$now' \
      "$OPS_NOTIFICATION_STATE" >"$tmp" && mv -f -- "$tmp" "$OPS_NOTIFICATION_STATE" || return 1
    rm -f -- "$selected"
    ops_log INFO "Delivered one detailed daily notification; remaining report chunks=$((count-1))."
}

log() {
    ops_log "$@"
}

rotate_log() {
    ops_initialize_log
}

notify_unraid() {
    local importance="$1" description="$2" message="$3"
    NOTIFICATION_ATTEMPTED=true
    ops_notify "$importance" "Quarantine Lifecycle v$SCRIPT_VERSION" "$description" "$message"
}

initialize_notification_state() {
    local tmp
    if [[ -f "$NOTIFICATION_STATE_FILE" ]] &&
       jq -e '
           type == "object"
           and ((.attention // {}) | type == "object")
       ' "$NOTIFICATION_STATE_FILE" >/dev/null 2>&1; then
        return 0
    fi

    if [[ -e "$NOTIFICATION_STATE_FILE" ]]; then
        log ERROR "Invalid notification state preserved for review; refusing to discard the durable outbox."
        return 1
    fi
    tmp="$(mktemp "${LOG_DIR}/.notification-state.XXXXXX")" || return 1
    printf '%s\n' '{"version":1,"attention":{},"outbox":[]}' >"$tmp" || {
        rm -f -- "$tmp"
        return 1
    }
    mv -f -- "$tmp" "$NOTIFICATION_STATE_FILE"
}

set_attention_state() {
    local signature="$1" now tmp
    now="$(date -Iseconds)"
    tmp="$(mktemp "${LOG_DIR}/.notification-state.XXXXXX")" || return 1
    if ! jq \
        --arg signature "$signature" \
        --arg now "$now" '
        .version = 1
        | .attention = {
            signature: $signature,
            raisedAt: (.attention.raisedAt // $now),
            updatedAt: $now
          }
        ' "$NOTIFICATION_STATE_FILE" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    mv -f -- "$tmp" "$NOTIFICATION_STATE_FILE"
}

clear_attention_state() {
    local send_resolution="${1:-true}" previous tmp
    previous="$(jq -r '.attention.signature // ""' \
        "$NOTIFICATION_STATE_FILE" 2>/dev/null || true)"
    [[ -n "$previous" ]] || return 0

    if [[ "$send_resolution" == true ]]; then
        notify_unraid normal "Quarantine lifecycle recovered" \
            "Previously reported lifecycle exceptions cleared. Current audit: $RUNS_SCANNED managed runs, $FILES_SCANNED files, $(human_bytes "$TOTAL_BYTES"); expired=$EXPIRED_RUNS, unmanaged=$UNMANAGED_ENTRIES, scan errors=$SCAN_ERRORS. No unreported purge is implied." || return 1
        [[ "$OPS_NOTIFICATION_DELIVERED" == true ]] || return 0
    fi

    tmp="$(mktemp "${LOG_DIR}/.notification-state.XXXXXX")" || return 1
    if ! jq '.attention = {}' "$NOTIFICATION_STATE_FILE" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    mv -f -- "$tmp" "$NOTIFICATION_STATE_FILE"
}

notify_attention_once() {
    local signature="$1" description="$2" message="$3" previous
    previous="$(jq -r '.attention.signature // ""' \
        "$NOTIFICATION_STATE_FILE" 2>/dev/null || true)"
    [[ "$signature" != "$previous" ]] || return 0
    notify_unraid warning "$description" "$message" || return 1
    [[ "$OPS_NOTIFICATION_DELIVERED" != true ]] || set_attention_state "$signature"
}

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " ")
        i=1
        while (b >= 1024 && i < 5) { b/=1024; i++ }
        printf "%.2f %s", b, u[i]
    }'
}

tree_bytes() {
    find "$1" -xdev -type f -printf '%s\n' 2>/dev/null |
        awk '{s+=$1} END {printf "%.0f", s+0}'
}

tree_files() {
    find "$1" -xdev -type f -printf '.' 2>/dev/null | wc -c
}

escape_tsv_field() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//$'\t'/\\t}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\n'/\\n}"
    printf '%s' "$value"
}

initialize_purge_receipt() {
    local tmp stamp

    [[ -n "$PURGE_RECEIPT_FILE" ]] && return 0
    mkdir -p -- "$PURGE_RECEIPT_DIR" 2>/dev/null || return 1
    stamp="$(date '+%Y%m%d_%H%M%S')"
    PURGE_RECEIPT_FILE="${PURGE_RECEIPT_DIR}/purge-${stamp}_$$.tsv"
    [[ ! -e "$PURGE_RECEIPT_FILE" ]] || return 1

    tmp="$(mktemp "${PURGE_RECEIPT_DIR}/.purge-receipt.XXXXXX")" || return 1
    if ! printf '%s\n' \
        $'record_type\tevent_time\trun_id\tage_days\tbucket\trelative_path\titem_type\tsize_bytes\tdeletion_status\tdetails' \
        >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    mv -f -- "$tmp" "$PURGE_RECEIPT_FILE"
}

append_purge_receipt_block() {
    local block="$1" tmp

    [[ -f "$PURGE_RECEIPT_FILE" && -f "$block" ]] || return 1
    tmp="$(mktemp "${PURGE_RECEIPT_DIR}/.purge-receipt.XXXXXX")" || return 1
    if ! cat -- "$PURGE_RECEIPT_FILE" "$block" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    mv -f -- "$tmp" "$PURGE_RECEIPT_FILE"
}

prune_purge_receipts() {
    local receipt removed=0

    mkdir -p -- "$PURGE_RECEIPT_DIR" 2>/dev/null || return 1
    while IFS= read -r -d '' receipt; do
        [[ "$receipt" == "$PURGE_RECEIPT_DIR"/purge-*.tsv ]] || continue
        rm -f -- "$receipt" || return 1
        removed=$((removed + 1))
    done < <(
        find "$PURGE_RECEIPT_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -type f \
            -name 'purge-*.tsv' \
            -mtime "+${PURGE_RECEIPT_RETENTION_DAYS}" \
            -print0 2>/dev/null
    )

    (( removed == 0 )) || \
        log INFO "Removed $removed purge receipt(s) older than $PURGE_RECEIPT_RETENTION_DAYS days"
}

write_run_inventory() {
    local run="$1" run_id="$2" age_days="$3"
    local item_file="$4" candidate_file="$5"
    local event_time record relative_entry item_type item_bytes
    local bucket relative_path escaped_path

    INVENTORY_FILE_COUNT=0
    INVENTORY_BYTE_COUNT=0
    INVENTORY_MOVIE_FILES=0
    INVENTORY_SERIES_FILES=0
    event_time="$(date -Iseconds)"
    : >"$item_file" || return 1
    : >"$candidate_file" || return 1

    local inventory_list="${item_file}.scan"
    if ! find "$run" -xdev -mindepth 1 ! -type d -printf '%P\t%y\t%s\0' >"$inventory_list"; then
        log ERROR "Incomplete inventory for $run_id; purge prohibited."; return 1
    fi
    sort -z "$inventory_list" -o "$inventory_list" || return 1
    while IFS= read -r -d '' record; do
        item_bytes="${record##*$'\t'}"
        record="${record%$'\t'*}"
        item_type="${record##*$'\t'}"
        relative_entry="${record%$'\t'*}"
        [[ "$item_bytes" =~ ^[0-9]+$ ]] || return 1

        bucket="${relative_entry%%/*}"
        relative_path="${relative_entry#*/}"
        [[ "$bucket" == movies || "$bucket" == series ]] || return 1
        [[ "$relative_path" != "$relative_entry" ]] || return 1
        escaped_path="$(escape_tsv_field "$relative_path")"

        printf 'FILE\t%s\t%s\t%s\t%s\t%s\t%s\t%s\trecorded_before_delete\tawait RUN_RESULT\n' \
            "$event_time" "$run_id" "$age_days" "$bucket" \
            "$escaped_path" "$item_type" "$item_bytes" \
            >>"$item_file" || return 1

        if [[ "$item_type" == f ]]; then
            INVENTORY_FILE_COUNT=$((INVENTORY_FILE_COUNT + 1))
            INVENTORY_BYTE_COUNT=$((INVENTORY_BYTE_COUNT + item_bytes))
            if [[ "$bucket" == movies ]]; then
                INVENTORY_MOVIE_FILES=$((INVENTORY_MOVIE_FILES + 1))
            else
                INVENTORY_SERIES_FILES=$((INVENTORY_SERIES_FILES + 1))
            fi
            printf '%s\t%s\t%s/%s\n' \
                "$item_bytes" "$run_id" "$bucket" "$escaped_path" \
                >>"$candidate_file" || return 1
        fi
    done <"$inventory_list"
    rm -f -- "$inventory_list"
}

persist_run_inventory_before_delete() {
    local run="$1" run_id="$2" age_days="$3"
    local expected_files="$4" expected_bytes="$5"
    local items candidates block checksum event_time

    items="${RUNTIME_DIR}/${run_id}.items.tsv"
    candidates="${RUNTIME_DIR}/${run_id}.candidates.tsv"
    block="${RUNTIME_DIR}/${run_id}.inventory-block.tsv"

    write_run_inventory \
        "$run" "$run_id" "$age_days" "$items" "$candidates" || return 1
    if (( INVENTORY_FILE_COUNT != expected_files ||
          INVENTORY_BYTE_COUNT != expected_bytes )); then
        log ERROR "Receipt inventory changed while scanning $run_id; refusing purge"
        return 1
    fi

    initialize_purge_receipt || return 1
    checksum="$(sha256sum -- "$items" | awk '{print $1}')" || return 1
    [[ "$checksum" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    event_time="$(date -Iseconds)"
    {
        printf 'RUN_INVENTORY\t%s\t%s\t%s\t-\t-\t-\t%s\trecorded_before_delete\tfiles=%s movies=%s series=%s inventory_sha256=%s\n' \
            "$event_time" "$run_id" "$age_days" "$expected_bytes" \
            "$expected_files" "$INVENTORY_MOVIE_FILES" \
            "$INVENTORY_SERIES_FILES" "$checksum"
        cat -- "$items"
    } >"$block" || return 1

    append_purge_receipt_block "$block" || return 1
    grep -Fq -- "inventory_sha256=${checksum}" "$PURGE_RECEIPT_FILE" || return 1
}

record_run_purge_result() {
    local run_id="$1" age_days="$2" files="$3" bytes="$4"
    local block event_time

    block="${RUNTIME_DIR}/${run_id}.result-block.tsv"
    event_time="$(date -Iseconds)"
    printf 'RUN_RESULT\t%s\t%s\t%s\t-\t-\t-\t%s\tpurged_and_absence_verified\tfiles=%s\n' \
        "$event_time" "$run_id" "$age_days" "$bytes" "$files" \
        >"$block" || return 1
    append_purge_receipt_block "$block"
}

build_purge_detail() {
    local detail="" item_bytes run_id path shown=0 total_files=0

    detail+="Purged runs:"$'\n'
    detail+="$PURGE_RUN_DETAILS"
    if [[ -s "$PURGE_FILE_CANDIDATES" ]]; then
        total_files="$(wc -l <"$PURGE_FILE_CANDIDATES" | tr -d '[:space:]')"
        detail+=$'\n'"Largest purged files:"$'\n'
        while IFS=$'\t' read -r item_bytes run_id path; do
            [[ "$item_bytes" =~ ^[0-9]+$ && -n "$path" ]] || continue
            (( shown < PURGE_NOTIFICATION_FILE_LIMIT )) || break
            shown=$((shown + 1))
            detail+="- ${path} - $(human_bytes "$item_bytes") (run ${run_id})"$'\n'
        done < <(
            LC_ALL=C sort -t $'\t' -k1,1nr "$PURGE_FILE_CANDIDATES"
        )
        if (( total_files > shown )); then
            detail+="- ...and $((total_files - shown)) more file(s)"$'\n'
        fi
    fi
    detail+=$'\n'"Full receipt: $PURGE_RECEIPT_FILE"
    printf '%s' "$detail"
}

write_receipt() {
    local status="$1" summary="$2" now tmp
    now="$(date +%s)"
    mkdir -p -- "$STATUS_DIR" 2>/dev/null || return 0
    command -v jq >/dev/null 2>&1 || return 0
    tmp="$(mktemp "${STATUS_DIR}/.quarantine_lifecycle.XXXXXX")" || return 0
    if jq -n \
        --arg name "quarantine_lifecycle" \
        --arg status "$status" \
        --arg summary "$summary" \
        --arg log "$LOG_FILE" \
        --argjson epoch "$now" \
        --argjson duration "$((now - START_EPOCH))" \
        '{name:$name,status:$status,summary:$summary,log:$log,epoch:$epoch,duration_seconds:$duration}' \
        >"$tmp"
    then
        mv -f -- "$tmp" "${STATUS_DIR}/quarantine_lifecycle.json"
        RECEIPT_WRITTEN=1
    else
        rm -f -- "$tmp"
    fi
}

cleanup() {
    local rc=$?
    if (( rc!=0 )) && [[ "$NOTIFICATION_ATTEMPTED" != true && -d "$LOG_DIR" ]]; then
        notify_unraid alert "Quarantine lifecycle failed" \
          "Status: $RESULT_STATUS; exit=$rc"$'\n'"$RESULT_SUMMARY"$'\n'"Completed actions: purged $PURGED_RUNS run(s), $PURGED_FILES file(s), $(human_bytes "$PURGED_BYTES")."$'\n'"${OPS_ATTENTION_DETAILS:0:6000}" || true
    elif [[ -d "$LOG_DIR" ]]; then
        ops_flush_notifications || rc=1
    fi
    if (( RECEIPT_WRITTEN == 0 )); then
        write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
    fi
    if [[ -n "$RUNTIME_DIR" &&
          "$RUNTIME_DIR" == /tmp/quarantine_lifecycle.* ]]; then
        rm -rf -- "$RUNTIME_DIR"
    fi
    trap - EXIT
    exit "$rc"
}

validate_configuration() {
    local command boolean_name boolean_value

    for command in awk basename cat date dirname find flock grep jq mkdir \
        mktemp mountpoint mv pgrep readlink realpath rm sha256sum sort stat \
        touch tr wc; do
        command -v "$command" >/dev/null 2>&1 || {
            log ERROR "Required command not found: $command"
            return 1
        }
    done

    [[ "$DEFAULT_MODE" == audit || "$DEFAULT_MODE" == purge ]] || {
        log ERROR "DEFAULT_MODE must be audit or purge"
        return 1
    }
    if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || (( RETENTION_DAYS < 7 )); then
        log ERROR "RETENTION_DAYS must be an integer of at least 7"
        return 1
    fi
    [[ "$WARNING_TOTAL_BYTES" =~ ^[1-9][0-9]*$ ]] || {
        log ERROR "WARNING_TOTAL_BYTES must be a positive integer"
        return 1
    }
    [[ "$MAX_PURGE_RUNS_PER_EXECUTION" =~ ^[1-9][0-9]*$ ]] || {
        log ERROR "MAX_PURGE_RUNS_PER_EXECUTION must be a positive integer"
        return 1
    }
    [[ "$MAX_PURGE_BYTES_PER_EXECUTION" =~ ^[1-9][0-9]*$ ]] || {
        log ERROR "MAX_PURGE_BYTES_PER_EXECUTION must be a positive integer"
        return 1
    }
    [[ "$LOG_MAX_BYTES" =~ ^[1-9][0-9]*$ ]] || {
        log ERROR "LOG_MAX_BYTES must be a positive integer"
        return 1
    }
    [[ "$PURGE_RECEIPT_RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || {
        log ERROR "PURGE_RECEIPT_RETENTION_DAYS must be a positive integer"
        return 1
    }
    [[ "$PURGE_NOTIFICATION_FILE_LIMIT" =~ ^[1-9][0-9]*$ ]] || {
        log ERROR "PURGE_NOTIFICATION_FILE_LIMIT must be a positive integer"
        return 1
    }

    for boolean_name in PURGE_ENABLED DEFER_PURGE_WHILE_MOVER; do
        boolean_value="${!boolean_name}"
        [[ "$boolean_value" == true || "$boolean_value" == false ]] || {
            log ERROR "${boolean_name} must be true or false"
            return 1
        }
    done
}

paths_overlap() {
    local left="${1%/}" right="${2%/}"
    [[ "$left" == "$right" || "$left" == "$right"/* || "$right" == "$left"/* ]]
}

validate_roots() {
    [[ "$QUARANTINE_ROOT" == /mnt/user/* &&
       "$MOVIES_ROOT" == /mnt/user/* &&
       "$SERIES_ROOT" == /mnt/user/* &&
       "$QUARANTINE_ROOT" != "/mnt/user/" &&
       "$MOVIES_ROOT" != "/mnt/user/" &&
       "$SERIES_ROOT" != "/mnt/user/" &&
       "$QUARANTINE_ROOT" != *$'\n'* &&
       "$MOVIES_ROOT" != *$'\n'* &&
       "$SERIES_ROOT" != *$'\n'* ]] || {
        log ERROR "Unsafe quarantine or media root configuration"
        return 1
    }
    [[ ! -L "$QUARANTINE_ROOT" &&
       ! -L "$MOVIES_ROOT" &&
       ! -L "$SERIES_ROOT" ]] || {
        log ERROR "Quarantine and media roots must not be symbolic links"
        return 1
    }
    [[ -d "$MOVIES_ROOT" && -d "$SERIES_ROOT" ]] || {
        log ERROR "Configured media roots must exist"
        return 1
    }
    mkdir -p -- "$QUARANTINE_ROOT" || {
        log ERROR "Unable to create quarantine root: $QUARANTINE_ROOT"
        return 1
    }

    QUARANTINE_REAL="$(realpath -e -- "$QUARANTINE_ROOT")" || return 1
    MOVIES_REAL="$(realpath -e -- "$MOVIES_ROOT")" || return 1
    SERIES_REAL="$(realpath -e -- "$SERIES_ROOT")" || return 1
    [[ "$QUARANTINE_REAL" == /mnt/user/* &&
       "$MOVIES_REAL" == /mnt/user/* &&
       "$SERIES_REAL" == /mnt/user/* ]] || {
        log ERROR "Canonical quarantine or media root escaped /mnt/user"
        return 1
    }
    if paths_overlap "$QUARANTINE_REAL" "$MOVIES_REAL" ||
       paths_overlap "$QUARANTINE_REAL" "$SERIES_REAL" ||
       paths_overlap "$MOVIES_REAL" "$SERIES_REAL"; then
        log ERROR "Quarantine and media roots must not overlap"
        return 1
    fi
}

valid_run_id() {
    [[ "$1" =~ ^[0-9]{8}_[0-9]{6}_[0-9]+$ ]]
}

run_id_epoch() {
    local run_id="$1" date_part time_and_pid time_part formatted normalized
    valid_run_id "$run_id" || return 1
    date_part="${run_id%%_*}"
    time_and_pid="${run_id#*_}"
    time_part="${time_and_pid%%_*}"
    formatted="${date_part:0:4}-${date_part:4:2}-${date_part:6:2} ${time_part:0:2}:${time_part:2:2}:${time_part:4:2}"
    normalized="$(date -d "$formatted" '+%Y%m%d_%H%M%S' 2>/dev/null)" || return 1
    [[ "$normalized" == "${date_part}_${time_part}" ]] || return 1
    date -d "$formatted" '+%s'
}

validate_managed_run_path() {
    local run="$1" run_id="$2" run_real parent_real child child_name
    valid_run_id "$run_id" || return 1
    [[ -d "$run" && ! -L "$run" ]] || return 1
    run_real="$(realpath -e -- "$run" 2>/dev/null)" || return 1
    parent_real="$(realpath -e -- "$(dirname -- "$run")" 2>/dev/null)" || return 1
    [[ "$parent_real" == "$QUARANTINE_REAL" &&
       "$run_real" == "${QUARANTINE_REAL}/${run_id}" ]] || return 1
    ! mountpoint -q -- "$run" || return 1

    while IFS= read -r -d '' child; do
        child_name="$(basename -- "$child")"
        case "$child_name" in
            movies|series)
                [[ -d "$child" && ! -L "$child" ]] || return 1
                ! mountpoint -q -- "$child" || return 1
                ;;
            *)
                return 1
                ;;
        esac
    done < <(find "$run" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

unraid_mover_running() {
    pgrep -f '(^|/)(mover|mover\.old)( |$)|mover\.php' >/dev/null 2>&1
}

valid_relative_path() {
    local relative="$1"
    [[ -n "$relative" &&
       "$relative" != /* &&
       "$relative" != ".." &&
       "$relative" != ../* &&
       "$relative" != */../* &&
       "$relative" != */.. &&
       "$relative" != *$'\n'* ]]
}

###############################################################################
# AUDIT
###############################################################################

reset_audit_counters() {
    RUNS_SCANNED=0
    EXPIRED_RUNS=0
    FILES_SCANNED=0
    TOTAL_BYTES=0
    UNMANAGED_ENTRIES=0
    SCAN_ERRORS=0
    REMAINING_EXPIRED_RUNS=0
}

audit_quarantine() {
    local tmp run run_id created age_days files bytes expired
    reset_audit_counters
    AUDIT_ATTENTION_DETAILS=""
    log DEBUG "Starting quarantine lifecycle audit v$SCRIPT_VERSION"
    tmp="$(mktemp "${LOG_DIR}/.quarantine-index.XXXXXX")" || return 1
    printf 'run_id\tcreated_epoch\tage_days\tfiles\tbytes\texpired\n' >"$tmp"

    local run_list="${RUNTIME_DIR}/audit-runs.list"
    if ! find "$QUARANTINE_REAL" -mindepth 1 -maxdepth 1 -print0 >"$run_list"; then
        rm -f -- "$tmp"; log ERROR "Cannot enumerate quarantine root; previous index preserved."; return 1
    fi
    sort -z "$run_list" -o "$run_list" || return 1
    while IFS= read -r -d '' run; do
        run_id="$(basename "$run")"
        valid_run_id "$run_id" || {
            log WARN "Ignoring non-managed quarantine entry: $run_id"
            AUDIT_ATTENTION_DETAILS+="Unmanaged entry preserved: $run_id"$'\n'
            UNMANAGED_ENTRIES=$((UNMANAGED_ENTRIES + 1))
            continue
        }
        if ! validate_managed_run_path "$run" "$run_id"; then
            log ERROR "Unsafe managed quarantine run was not scanned: $run"
            SCAN_ERRORS=$((SCAN_ERRORS + 1))
            continue
        fi
        if ! created="$(run_id_epoch "$run_id")"; then
            log ERROR "Managed quarantine run has an invalid calendar timestamp: $run_id"
            SCAN_ERRORS=$((SCAN_ERRORS + 1))
            continue
        fi
        if (( created > START_EPOCH + 300 )); then
            log ERROR "Managed quarantine run is dated in the future: $run_id"
            SCAN_ERRORS=$((SCAN_ERRORS + 1))
            continue
        fi
        age_days=$(((START_EPOCH - created) / 86400))
        (( age_days < 0 )) && age_days=0
        local inventory_sizes="${RUNTIME_DIR}/audit-sizes.txt" inventory_summary
        if ! find "$run" -xdev -type f -printf '%s\n' >"$inventory_sizes"; then
            log ERROR "Incomplete file inventory for $run_id; preserving run and prior index."
            rm -f -- "$tmp"; return 1
        fi
        inventory_summary=$(awk '{files++;bytes+=$1} END{printf "%d\t%.0f",files+0,bytes+0}' "$inventory_sizes")
        IFS=$'\t' read -r files bytes <<<"$inventory_summary"
        if ! [[ "$files" =~ ^[[:space:]]*[0-9]+$ && "$bytes" =~ ^[0-9]+$ ]]; then
            log ERROR "Unable to inventory managed quarantine run: $run_id"
            SCAN_ERRORS=$((SCAN_ERRORS + 1))
            continue
        fi
        files="${files//[[:space:]]/}"
        expired=false
        if (( age_days >= RETENTION_DAYS )); then
            expired=true
            EXPIRED_RUNS=$((EXPIRED_RUNS + 1))
        fi
        RUNS_SCANNED=$((RUNS_SCANNED + 1))
        FILES_SCANNED=$((FILES_SCANNED + files))
        TOTAL_BYTES=$((TOTAL_BYTES + bytes))
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$run_id" "$created" "$age_days" "$files" "$bytes" "$expired" >>"$tmp"
    done <"$run_list"

    mv -f -- "$tmp" "$INDEX_FILE"
    REMAINING_EXPIRED_RUNS="$EXPIRED_RUNS"
    log DEBUG "Audit: $RUNS_SCANNED managed runs, $FILES_SCANNED files, $(human_bytes "$TOTAL_BYTES"), $EXPIRED_RUNS expired, $UNMANAGED_ENTRIES unmanaged, $SCAN_ERRORS scan errors"
}

###############################################################################
# RESTORE
###############################################################################

restore_item() {
    local run_id="$1" bucket="$2" relative="$3"
    local run source destination root source_resolved destination_resolved

    valid_run_id "$run_id" || {
        log ERROR "Invalid run ID: $run_id"
        return 1
    }
    valid_relative_path "$relative" || {
        log ERROR "Unsafe relative restore path: $relative"
        return 1
    }
    case "$bucket" in
        movies) root="$MOVIES_REAL" ;;
        series) root="$SERIES_REAL" ;;
        *)
            log ERROR "Restore bucket must be movies or series"
            return 1
            ;;
    esac

    run="${QUARANTINE_REAL}/${run_id}"
    validate_managed_run_path "$run" "$run_id" || {
        log ERROR "Unsafe or unavailable managed quarantine run: $run_id"
        return 1
    }
    source="${run}/${bucket}/${relative}"
    destination="${root}/${relative}"
    source_resolved="$(readlink -m -- "$source")" || return 1
    destination_resolved="$(readlink -m -- "$destination")" || return 1

    [[ "$source_resolved" == "$run"/* &&
       "$destination_resolved" == "$root"/* ]] || {
        log ERROR "Resolved restore path escaped its configured root"
        return 1
    }
    [[ -e "$source" || -L "$source" ]] || {
        log ERROR "Quarantined item does not exist: $source"
        return 1
    }
    [[ ! -e "$destination" && ! -L "$destination" ]] || {
        log ERROR "Restore destination already exists: $destination"
        return 1
    }

    if [[ "$DEFER_PURGE_WHILE_MOVER" == true ]] && unraid_mover_running; then
        log ERROR "Restore deferred while Mover is active: $source -> $destination"; return 1
    fi
    mkdir -p -- "$(dirname "$destination")" || return 1
    mv -- "$source" "$destination" || return 1
    find "$run" -xdev -depth -type d -empty -delete \
        2>/dev/null || true

    RESULT_STATUS="OK"
    RESULT_SUMMARY="Restored $bucket/$relative from $run_id"
    log INFO "$RESULT_SUMMARY -> $destination"
    notify_unraid normal "Quarantined item restored" "$RESULT_SUMMARY"$'\n'"Source: $source"$'\n'"Restored destination: $destination"$'\n'"Existing destination files were not overwritten."
}

###############################################################################
# PURGE
###############################################################################

purge_expired() {
    local run run_id created age_days files bytes

    [[ "$PURGE_ENABLED" == true ]] || {
        log ERROR "Purge is disabled; set PURGE_ENABLED=true after reviewing $INDEX_FILE"
        return 1
    }
    [[ "$PURGE_CONFIRMATION" == "$REQUIRED_PURGE_CONFIRMATION" ]] || {
        log ERROR "PURGE_CONFIRMATION does not match the required confirmation phrase"
        return 1
    }
    if (( EXPIRED_RUNS == 0 )); then
        RESULT_STATUS="OK"
        RESULT_SUMMARY="No quarantine runs have reached ${RETENTION_DAYS}-day retention"
        log INFO "$RESULT_SUMMARY"
        return 0
    fi
    if [[ "$DEFER_PURGE_WHILE_MOVER" == true ]] && unraid_mover_running; then
        PURGE_DEFERRED_REASON="Unraid Mover is active"
        RESULT_STATUS="WARNING"
        RESULT_SUMMARY="Purge deferred: $PURGE_DEFERRED_REASON; $EXPIRED_RUNS expired run(s) remain"
        log WARN "$RESULT_SUMMARY"
        return 0
    fi

    while IFS= read -r -d '' run; do
        run_id="$(basename "$run")"
        valid_run_id "$run_id" || continue
        validate_managed_run_path "$run" "$run_id" || {
            log ERROR "Refusing purge of unsafe managed run path: $run"
            return 1
        }
        created="$(run_id_epoch "$run_id")" || {
            log ERROR "Refusing purge of run with invalid timestamp: $run_id"
            return 1
        }
        (( created <= START_EPOCH + 300 )) || continue
        age_days=$(((START_EPOCH - created) / 86400))
        (( age_days >= RETENTION_DAYS )) || continue
        IFS=$'\t' read -r files bytes < <(awk -F '\t' -v id="$run_id" '$1==id {print $4 "\t" $5}' "$INDEX_FILE")
        [[ "$files" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ ]] || { log ERROR "Invalid audited inventory for $run_id"; return 1; }

        if (( PURGED_RUNS >= MAX_PURGE_RUNS_PER_EXECUTION ||
              PURGED_BYTES + bytes > MAX_PURGE_BYTES_PER_EXECUTION )); then
            PURGE_LIMIT_REACHED=1
            log WARN "Per-run purge limit reached before $run_id; remaining expired runs will be retried"
            break
        fi

        if (( MIN_RUN_IDLE_HOURS>0 )); then
            local idle_check="${RUNTIME_DIR}/idle-check.list"
            find "$run" -xdev -cmin "-$((MIN_RUN_IDLE_HOURS*60))" -print -quit >"$idle_check" || return 1
            if [[ -s "$idle_check" ]]; then
                log WARN "Recently changed run $run_id was preserved; retention alone does not authorize purge."
                continue
            fi
        fi
        if ! persist_run_inventory_before_delete \
            "$run" "$run_id" "$age_days" "$files" "$bytes"; then
            log ERROR "Could not commit a complete purge receipt for $run_id; run was preserved"
            return 1
        fi

        if [[ "$DEFER_PURGE_WHILE_MOVER" == true ]] && unraid_mover_running; then
            PURGE_DEFERRED_REASON="Unraid Mover became active during purge"; break
        fi
        validate_managed_run_path "$run" "$run_id" || return 1
        local changed_file="${RUNTIME_DIR}/recent-changes.list"
        if (( MIN_RUN_IDLE_HOURS>0 )); then
            find "$run" -xdev -cmin "-$((MIN_RUN_IDLE_HOURS*60))" -print -quit >"$changed_file" || return 1
            if [[ -s "$changed_file" ]]; then
                log WARN "Preserved recently changed run $run_id; idle requirement=${MIN_RUN_IDLE_HOURS}h"
                AUDIT_ATTENTION_DETAILS+="Recently changed run preserved: $run_id; requires ${MIN_RUN_IDLE_HOURS}h idle."$'\n'
                continue
            fi
        fi
        log INFO "Purging expired quarantine run: $run_id; files=$files; bytes=$bytes"
        rm -rf --one-file-system -- "$run" || {
            log ERROR "Failed to purge: $run"
            return 1
        }
        [[ ! -e "$run" && ! -L "$run" ]] || {
            log ERROR "Expired quarantine run still exists after purge: $run_id"
            return 1
        }
        if ! record_run_purge_result \
            "$run_id" "$age_days" "$files" "$bytes"; then
            log ERROR "Run $run_id was purged, but its verified result could not be appended to $PURGE_RECEIPT_FILE"
            return 1
        fi
        if ! cat -- "${RUNTIME_DIR}/${run_id}.candidates.tsv" \
            >>"$PURGE_FILE_CANDIDATES"; then
            log WARN "Run $run_id was purged, but its largest-file notification summary could not be prepared; the full receipt remains available"
        fi
        PURGED_RUNS=$((PURGED_RUNS + 1))
        PURGED_FILES=$((PURGED_FILES + files))
        PURGED_BYTES=$((PURGED_BYTES + bytes))
        PURGE_RUN_DETAILS+="- ${run_id} (${age_days} days): ${files} file(s), $(human_bytes "$bytes"); movies=${INVENTORY_MOVIE_FILES}, series=${INVENTORY_SERIES_FILES}"$'\n'
    done < <(awk -F '\t' 'NR>1 && $6=="true" {printf "%s%c", $1, 0}' "$INDEX_FILE" | sort -z | while IFS= read -r -d '' id; do printf '%s\0' "$QUARANTINE_REAL/$id"; done)

    if (( PURGED_RUNS > 0 )); then
        log DEBUG "Refreshing quarantine index after purge"
        audit_quarantine || {
            log ERROR "Purge completed, but the remaining quarantine index could not be refreshed"
            return 1
        }
    else
        REMAINING_EXPIRED_RUNS="$EXPIRED_RUNS"
    fi
    if (( PURGE_LIMIT_REACHED == 1 || REMAINING_EXPIRED_RUNS > 0 || UNMANAGED_ENTRIES > 0 || SCAN_ERRORS > 0 )); then
        RESULT_STATUS="WARNING"
        RESULT_SUMMARY="Purged $PURGED_RUNS run(s), $PURGED_FILES file(s), and $(human_bytes "$PURGED_BYTES"); retained expired=$REMAINING_EXPIRED_RUNS, unmanaged=$UNMANAGED_ENTRIES, scan errors=$SCAN_ERRORS. Safety deferrals and limits are included in this report."
    else
        RESULT_STATUS="OK"
        RESULT_SUMMARY="Purged $PURGED_RUNS run(s), $PURGED_FILES file(s), and $(human_bytes "$PURGED_BYTES")"
    fi
    log INFO "$RESULT_SUMMARY"
}

update_lifecycle_notifications() {
    local signature="" detail="" importance="warning"

    if (( REMAINING_EXPIRED_RUNS > 0 )); then
        signature+="expired;"
        detail+="Expired runs remaining: $REMAINING_EXPIRED_RUNS"$'\n'
    fi
    if (( UNMANAGED_ENTRIES > 0 )); then
        signature+="unmanaged;"
        detail+="Unmanaged entries preserved: $UNMANAGED_ENTRIES"$'\n'
    fi
    if (( SCAN_ERRORS > 0 )); then
        signature+="scan-errors;"
        detail+="Managed runs preserved after scan errors: $SCAN_ERRORS"$'\n'
    fi
    if (( TOTAL_BYTES >= WARNING_TOTAL_BYTES )); then
        signature+="capacity;"
        detail+="Quarantine usage warning: $(human_bytes "$TOTAL_BYTES")"$'\n'
    fi
    if [[ -n "$PURGE_DEFERRED_REASON" ]]; then
        signature+="mover-deferred;"
        detail+="Purge deferred: $PURGE_DEFERRED_REASON"$'\n'
    fi
    if (( PURGE_LIMIT_REACHED == 1 )); then
        signature+="purge-limit;"
        detail+="Per-execution purge limit reached; remaining runs will be retried."$'\n'
    fi
    detail+="${AUDIT_ATTENTION_DETAILS:0:6000}"$'\n'
    detail+="${OPS_ATTENTION_DETAILS:0:6000}"$'\n'
    detail+="Current index: $INDEX_FILE"

    if (( PURGED_RUNS > 0 )); then
        detail="$(build_purge_detail)"$'\n\n'"$detail"
        [[ -z "$signature" ]] && importance="normal"
        notify_unraid "$importance" "Quarantine purge completed" \
            "$RESULT_SUMMARY"$'\n'"$detail" || return 1
        [[ "$OPS_NOTIFICATION_DELIVERED" == true ]] || return 0
        if [[ -n "$signature" ]]; then
            set_attention_state "$signature"
        else
            clear_attention_state false
        fi
    elif [[ -n "$signature" ]]; then
        notify_attention_once "$signature" "Quarantine review required" "$detail"
    else
        clear_attention_state true
    fi
}

###############################################################################
# MAIN
###############################################################################

main() {
    local mode="${1:-$DEFAULT_MODE}" failure_detail=""
    trap cleanup EXIT
    case "$mode" in
      --help|-h) printf '%s\n' 'Usage: /bin/bash SCRIPT [audit|purge|restore RUN_ID movies|series RELATIVE_PATH|--version]' 'audit changes no quarantine payload. purge defaults to scheduled retention with per-run limits.' 'restore never overwrites an existing path. All modes coordinate with the Arr producer.'; RESULT_STATUS=OK; RESULT_SUMMARY="Help displayed"; trap - EXIT; return 0 ;;
      --version) printf 'quarantine_lifecycle.sh %s\n' "$SCRIPT_VERSION"; trap - EXIT; return 0 ;;
    esac
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then RESULT_STATUS=DEFERRED; RESULT_SUMMARY="Another lifecycle run holds the lock"; trap - EXIT; return 0; fi
    exec 8>"$QUARANTINE_COORDINATION_LOCK"
    if ! flock -n 8; then RESULT_STATUS=DEFERRED; RESULT_SUMMARY="Quarantine producer is active; payloads preserved"; trap - EXIT; printf '%s\n' "$RESULT_SUMMARY"; return 0; fi
    if ! mountpoint -q /mnt/vault || ! mountpoint -q /mnt/user; then
        RESULT_SUMMARY="Required mounts are unavailable: /mnt/vault and/or /mnt/user; no purge or restore was attempted"
        printf '%s\n' "$RESULT_SUMMARY" >&2
        if [[ -x "$NOTIFY_BIN" ]]; then "$NOTIFY_BIN" -i alert -s "Quarantine Lifecycle" -d "Required storage unavailable" -m "$RESULT_SUMMARY" >/dev/null 2>&1 || true; NOTIFICATION_ATTEMPTED=true; fi
        return 1
    fi
    mkdir -p -- "$LOG_DIR" || return 1
    rotate_log || return 1
    touch "$LOG_FILE" || return 1
    validate_configuration || return 1
    [[ "$MIN_RUN_IDLE_HOURS" =~ ^[0-9]+$ ]] || { log ERROR "MIN_RUN_IDLE_HOURS must be nonnegative"; return 1; }
    prune_purge_receipts || {
        log ERROR "Unable to apply purge receipt retention"
        return 1
    }
    RUNTIME_DIR="$(mktemp -d /tmp/quarantine_lifecycle.XXXXXX)" || return 1
    PURGE_FILE_CANDIDATES="${RUNTIME_DIR}/purge-candidates.tsv"
    : >"$PURGE_FILE_CANDIDATES" || return 1


    initialize_notification_state || {
        log ERROR "Unable to initialize notification state"
        return 1
    }
    validate_roots || return 1

    case "$mode" in
        audit)
            audit_quarantine || return 1
            if (( TOTAL_BYTES >= WARNING_TOTAL_BYTES ||
                  EXPIRED_RUNS > 0 ||
                  UNMANAGED_ENTRIES > 0 ||
                  SCAN_ERRORS > 0 )); then
                RESULT_STATUS="WARNING"
                RESULT_SUMMARY="$EXPIRED_RUNS expired, $UNMANAGED_ENTRIES unmanaged, $SCAN_ERRORS scan errors; quarantine uses $(human_bytes "$TOTAL_BYTES")"
            else
                RESULT_STATUS="OK"
                RESULT_SUMMARY="$RUNS_SCANNED runs, $FILES_SCANNED files, $(human_bytes "$TOTAL_BYTES")"
            fi
            update_lifecycle_notifications || return 1
            ;;
        purge)
            audit_quarantine || return 1
            if ! purge_expired; then
                RESULT_STATUS="FAILED"
                RESULT_SUMMARY="Quarantine purge stopped after a safety or deletion failure"
                failure_detail="$RESULT_SUMMARY"
                if (( PURGED_RUNS > 0 )); then
                    failure_detail+=$'\n'"Completed before failure: $PURGED_RUNS run(s), $PURGED_FILES file(s), $(human_bytes "$PURGED_BYTES")"
                fi
                if [[ -n "$PURGE_RECEIPT_FILE" ]]; then
                    failure_detail+=$'\n'"Receipt: $PURGE_RECEIPT_FILE"
                fi
                failure_detail+=$'\n'"Log: $LOG_FILE"
                notify_attention_once "purge-failed;" \
                    "Quarantine purge failed" \
                    "$failure_detail" || true
                return 1
            fi
            update_lifecycle_notifications || return 1
            ;;
        restore)
            (( $# == 4 )) || {
                log ERROR "Usage: $0 restore RUN_ID movies|series RELATIVE_PATH"
                return 2
            }
            restore_item "$2" "$3" "$4" || return 1
            ;;
        *)
            log ERROR "Unknown mode: $mode"
            return 2
            ;;
    esac

    log INFO "SUMMARY | status=$RESULT_STATUS | $RESULT_SUMMARY | remaining-expired=$REMAINING_EXPIRED_RUNS | unmanaged=$UNMANAGED_ENTRIES scan-errors=$SCAN_ERRORS | runtime=$(( $(date +%s)-START_EPOCH ))s"
    write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
