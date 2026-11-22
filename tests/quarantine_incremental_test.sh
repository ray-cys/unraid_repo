#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/quarantine_lifecycle.sh"
fixture=$(mktemp -d /tmp/quarantine-incremental.XXXXXX); fixture=$(realpath "$fixture")
trap - EXIT INT TERM HUP
trap 'rm -rf -- "$fixture"' EXIT
LOG_DIR="$fixture/log"; LOG_FILE="$LOG_DIR/main.log"; RUNTIME_DIR="$fixture/work"
QUARANTINE_REAL="$fixture/bin"; MOVIES_REAL="$fixture/movies"; SERIES_REAL="$fixture/series"
INDEX_FILE="$LOG_DIR/index.tsv"; PURGE_RECEIPT_DIR="$LOG_DIR/receipts"; PURGE_FILE_CANDIDATES="$RUNTIME_DIR/candidates.tsv"
OPS_PENDING_OPERATIONS_FILE="$LOG_DIR/pending.json"; OPS_OPERATION_AUDIT_FILE="$LOG_DIR/audit.jsonl"
mkdir -p "$LOG_DIR" "$RUNTIME_DIR" "$QUARANTINE_REAL" "$MOVIES_REAL" "$SERIES_REAL"
RETENTION_DAYS=7; MIN_RUN_IDLE_HOURS=0; DEFER_PURGE_WHILE_MOVER=false
MAX_PURGE_BYTES_PER_EXECUTION=6; MAX_PURGE_FILES_PER_EXECUTION=250
mountpoint() { return 1; }; sync() { :; }
reset_counts() {
 PURGED_RUNS=0; PARTIALLY_PURGED_RUNS=0; PURGED_FILES=0; PURGED_BYTES=0; PURGE_LIMIT_REACHED=0
 PURGE_RUN_DETAILS=""; PURGE_DEFERRED_REASON=""
 : >"$PURGE_FILE_CANDIDATES"
}
reset_counts
mkdir -p "$QUARANTINE_REAL/20200101_000000_1/movies/Big" "$QUARANTINE_REAL/20200102_000000_2/movies/Small"
printf aaaa >"$QUARANTINE_REAL/20200101_000000_1/movies/Big/a.jpg"
printf bbbb >"$QUARANTINE_REAL/20200101_000000_1/movies/Big/b.jpg"
printf c >"$QUARANTINE_REAL/20200101_000000_1/movies/Big/c.jpg"
printf d >"$QUARANTINE_REAL/20200102_000000_2/movies/Small/poster.jpg"
audit_quarantine
purge_expired
[[ "$PURGED_BYTES" == 6 && "$PURGED_FILES" == 3 && "$PARTIALLY_PURGED_RUNS" == 1 ]]
[[ -f "$QUARANTINE_REAL/20200101_000000_1/movies/Big/b.jpg" && ! -e "$QUARANTINE_REAL/20200102_000000_2" ]]
jq -e '.operations|length==0' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null
grep -q FILE_RESULT "$PURGE_RECEIPT_FILE"
# The next scheduled pass completes the remainder within the original cap.
reset_counts; audit_quarantine; purge_expired
[[ "$PURGED_BYTES" == 4 && "$PURGED_FILES" == 1 && ! -e "$QUARANTINE_REAL/20200101_000000_1" ]]
# File-count limits also drain large numbers of tiny files, then resume.
mkdir -p "$QUARANTINE_REAL/20200103_000000_3/movies/Count"
for n in 1 2 3; do printf x >"$QUARANTINE_REAL/20200103_000000_3/movies/Count/$n.nfo"; done
MAX_PURGE_FILES_PER_EXECUTION=1
reset_counts; audit_quarantine; purge_expired
[[ "$PURGED_FILES" == 1 && -d "$QUARANTINE_REAL/20200103_000000_3" ]]
# Every partial unlink must have durable proof before the mutation.
MAX_PURGE_FILES_PER_EXECUTION=1
reset_counts; audit_quarantine
( sync() { return 1; }; if purge_expired; then exit 1; fi )
[[ "$(find "$QUARANTINE_REAL/20200103_000000_3" -type f | wc -l | tr -d ' ')" == 2 ]]
# Interruption after unlink is reconciled by absence, never a repeated deletion.
reset_counts; audit_quarantine
( rm() { command rm "$@"; return 1; }; if purge_expired; then exit 1; fi )
jq -e '.operations|length==1' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null
ops_recover_operations
jq -e '.operations|length==0' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null
[[ "$OPS_RECOVERED_COUNT" == 1 ]]
# Changing an object between checkpoint and unlink preserves it for review.
printf x >"$QUARANTINE_REAL/20200103_000000_3/movies/Count/extra.nfo"
reset_counts; audit_quarantine
eval "$(declare -f ops_operation_begin | sed '1s/ops_operation_begin/fixture_original_operation_begin/')"
ops_operation_begin() {
 local result; result=$(fixture_original_operation_begin "$@") || return 1
 printf changed >>"$2"
 printf '%s' "$result"
}
if purge_expired; then exit 1; fi
[[ "$(find "$QUARANTINE_REAL/20200103_000000_3" -type f | wc -l | tr -d ' ')" == 2 ]]
if ops_recover_operations; then echo 'changed interrupted object falsely cleared' >&2; exit 1; fi
printf 'Incremental byte/file caps, progress, smaller-run fairness, receipts, flush failures and interrupted unlink recovery passed\n'
