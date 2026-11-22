#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/cleanup-checkpoint.XXXXXX); fixture=$(realpath "$fixture")
trap 'rm -rf -- "$fixture"' EXIT
# The fixture has no mounted descendants; Unraid provides mountpoint itself.
mountpoint() { return 1; }
for script in quarantine_lifecycle sabnzbd_cleanup; do
(
    source "$repo/user_script/$script.sh"
    trap - EXIT INT TERM
    LOG_DIR="$fixture/$script/log"; LOG_FILE="$LOG_DIR/operations.log"
    OPS_NOTIFICATION_STATE="$LOG_DIR/notification-state.json"
    OPS_QUARANTINE_ROOT="$fixture/$script/bin"
    OPS_RESTORE_ROOTS=("$fixture/$script/media")
    mkdir -p "$LOG_DIR" "$OPS_QUARANTINE_ROOT" "${OPS_RESTORE_ROOTS[0]}"
    OPS_PENDING_OPERATIONS_FILE="$LOG_DIR/pending-operations.json"
    OPS_OPERATION_AUDIT_FILE="$LOG_DIR/operation-recovery.jsonl"
    proof="$LOG_DIR/proof.json"; printf '{"intent":"fixture"}\n' >"$proof"
    source_dir="$OPS_QUARANTINE_ROOT/old-run"; mkdir "$source_dir"; printf 'metadata\n' >"$source_dir/poster.jpg"
    id=$(ops_operation_begin purge "$source_dir" '' "$proof")
    rm -rf -- "$source_dir"
    ops_recover_operations
    jq -e '.operations|length==0' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null
    [[ "$OPS_RECOVERED_COUNT" == 1 && "$OPS_RECOVERY_DETAILS" == *'No new deletion'* ]]
    # A rename completed before an interruption is identified without repeating it.
    source_file="$OPS_QUARANTINE_ROOT/poster.jpg"; destination="${OPS_RESTORE_ROOTS[0]}/poster.jpg"
    printf 'artwork\n' >"$source_file"
    id=$(ops_operation_begin restore "$source_file" "$destination" "$proof")
    mv -T -n -- "$source_file" "$destination"
    ops_recover_operations
    jq -e '.operations|length==0' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null
    [[ "$OPS_RECOVERED_COUNT" == 1 && -f "$destination" ]]
    # A failed flush prevents a destructive action from obtaining its intent.
    printf 'preserve\n' >"$source_file"
    mkdir -p "$OPS_QUARANTINE_ROOT/flush-blocked"
    ( sync() { return 1; }; if ops_operation_begin purge "$OPS_QUARANTINE_ROOT/flush-blocked" '' "$proof"; then exit 1; fi )
    jq -e '.operations|length==0' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null
    [[ -f "$source_file" ]]
    id=$(ops_operation_begin restore "$source_file" "${OPS_RESTORE_ROOTS[0]}/ambiguous.jpg" "$proof")
    printf 'other copy\n' >"${OPS_RESTORE_ROOTS[0]}/ambiguous.jpg"
    if ops_recover_operations; then echo 'ambiguous restore incorrectly cleared' >&2; exit 1; fi
    jq -e '.operations|length==1' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null
    [[ -f "$source_file" && -f "${OPS_RESTORE_ROOTS[0]}/ambiguous.jpg" ]]
    ops_receipt_in_use "$proof"
    ops_resolve_operation "$id" 'Verified both copies and elected to keep them'
    [[ -f "$source_file" && -f "${OPS_RESTORE_ROOTS[0]}/ambiguous.jpg" ]]
    # Multiple sections fit one daily email; queued obsolete attention becomes
    # resolved while completed-action records remain intact.
    NOTIFY_BIN="$fixture/$script/notify"; NOTIFY="$NOTIFY_BIN"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$fixture/$script/email.txt" >"$NOTIFY_BIN"; chmod +x "$NOTIFY_BIN"
    ops_notification_state
    jq --arg day "$(date -Iseconds)" '.lastSentAt=$day' "$OPS_NOTIFICATION_STATE" >"$LOG_DIR/next.json"; mv "$LOG_DIR/next.json" "$OPS_NOTIFICATION_STATE"
    ops_set_topic fixture attention 'Waiting for API'
    ops_notify warning Fixture 'API unavailable' 'No payload was deleted; API could not be checked.' fixture attention
    ops_notify normal Fixture 'Action completed' 'Moved Example Movie into quarantine.' fixture action
    ops_set_topic fixture healthy 'API recovered; all current checks passed'
    jq -e 'any(.outbox[];.kind=="resolved") and any(.outbox[];.kind=="action") and all(.outbox[];.kind!="attention")' "$OPS_NOTIFICATION_STATE" >/dev/null
    jq 'del(.lastSentAt)' "$OPS_NOTIFICATION_STATE" >"$LOG_DIR/next.json"; mv "$LOG_DIR/next.json" "$OPS_NOTIFICATION_STATE"
    ops_flush_notifications
    jq -e '.outbox|length==0' "$OPS_NOTIFICATION_STATE" >/dev/null
    grep -q 'Moved Example Movie' "$fixture/$script/email.txt"
    grep -q 'resolved before delivery' "$fixture/$script/email.txt"
    [[ "$(grep -c '^-i ' "$fixture/$script/email.txt")" == 1 ]]
    jq -n '[range(0;9000)|"漢"]|join("")' >"$LOG_DIR/utf8-message.json"
    jq -n --slurpfile message "$LOG_DIR/utf8-message.json" --arg at "$(date -Iseconds)" '{version:1,outbox:[{eventId:"legacy",id:"legacy:0",importance:"normal",subject:"Fixture",description:"Legacy action report",message:$message[0],queuedAt:$at,offset:0}]}' >"$OPS_NOTIFICATION_STATE"
    ops_notification_state
    jq -e '(.outbox|length)==5 and all(.outbox[];(.message|utf8bytelength)<=8000)' "$OPS_NOTIFICATION_STATE" >/dev/null
    ops_flush_notifications
    jq -e '(.outbox|length)>0' "$OPS_NOTIFICATION_STATE" >/dev/null
    before=$(grep -c '^-i ' "$fixture/$script/email.txt")
    ops_flush_notifications
    [[ "$(grep -c '^-i ' "$fixture/$script/email.txt")" == "$before" ]]
    jq 'del(.lastSentAt)' "$OPS_NOTIFICATION_STATE" >"$LOG_DIR/next.json"; mv "$LOG_DIR/next.json" "$OPS_NOTIFICATION_STATE"
    ops_flush_notifications
    jq -e '(.outbox|length)==0' "$OPS_NOTIFICATION_STATE" >/dev/null
    [[ "$(jq -Rs '[scan("漢")]|length' "$fixture/$script/email.txt")" == 9000 ]]
)
done
# Oversized runs cannot block smaller expired runs.
(
    source "$repo/user_script/quarantine_lifecycle.sh"
    LOG_DIR="$fixture/limits/log"; LOG_FILE="$LOG_DIR/log"
    RUNTIME_DIR="$fixture/limits/work"; QUARANTINE_REAL="$fixture/limits/bin"
    MOVIES_REAL="$fixture/limits/movies"; SERIES_REAL="$fixture/limits/series"
    INDEX_FILE="$LOG_DIR/index.tsv"; PURGE_RECEIPT_DIR="$LOG_DIR/receipts"; PURGE_FILE_CANDIDATES="$RUNTIME_DIR/candidates"
    OPS_PENDING_OPERATIONS_FILE="$LOG_DIR/pending-operations.json"; OPS_OPERATION_AUDIT_FILE="$LOG_DIR/operation-recovery.jsonl"
    mkdir -p "$LOG_DIR" "$RUNTIME_DIR" "$MOVIES_REAL" "$SERIES_REAL" "$QUARANTINE_REAL/20200101_000000_1/movies/Big" "$QUARANTINE_REAL/20200102_000000_2/movies/Small"
    printf 'oversized!' >"$QUARANTINE_REAL/20200101_000000_1/movies/Big/poster.jpg"
    printf x >"$QUARANTINE_REAL/20200102_000000_2/movies/Small/poster.jpg"
    MAX_PURGE_BYTES_PER_EXECUTION=2 MIN_RUN_IDLE_HOURS=0 DEFER_PURGE_WHILE_MOVER=false
    audit_quarantine
    purge_expired
    [[ -d "$QUARANTINE_REAL/20200101_000000_1" && ! -e "$QUARANTINE_REAL/20200102_000000_2" && "$RESULT_STATUS" == WARNING ]]
)
printf 'Checkpoint recovery, flush failure, daily packing, stale warning and oversized-run isolation tests passed\n'
