#!/usr/bin/env bash
# Completion evidence and notification lifecycle fixtures; no Unraid services.
# Globals and mocks are consumed by the sourced script.
# shellcheck disable=SC2034,SC2329
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/daily_digest_test.XXXXXX)"
cleanup_test() {
    case "$TEST_ROOT" in /tmp/daily_digest_test.*) rm -rf -- "$TEST_ROOT" ;; esac
}
trap cleanup_test EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC1091
source "$REPO_ROOT/user_script/daily_digest.sh"

# The production target supplies GNU stat/date. Use their macOS names when
# available so the fixtures exercise the same parsing and size calculations.
stat() {
    if command -v gstat >/dev/null 2>&1; then gstat "$@"; else command stat "$@"; fi
}
date() {
    if command -v gdate >/dev/null 2>&1; then gdate "$@"; else command date "$@"; fi
}
reset_findings() { OK_ITEMS=(); WARNING_ITEMS=(); CRITICAL_ITEMS=(); ISSUE_KEYS=(); }
assert_issue() {
    printf '%s\n' "${ISSUE_KEYS[@]}" | grep -Fq -- "$1" || fail "expected condition: $1"
}
assert_clear() { (( ${#ISSUE_KEYS[@]} == 0 )) || fail "unexpected issues: ${ISSUE_KEYS[*]}"; }

LOG_DIR="$TEST_ROOT/logs"
LOG_FILE="$LOG_DIR/audit.log"
NOTIFICATION_STATE_FILE="$LOG_DIR/notifications.json"
NOTIFY_BIN="$TEST_ROOT/notify"
STATUS_DIR="$TEST_ROOT/receipts"
mkdir -p "$LOG_DIR" "$STATUS_DIR"
touch "$LOG_FILE"
# Notification mock receives the real Unraid command arguments and can fail.
printf '#!/bin/sh\n[ ! -e "%s/fail-notify" ] || exit 1\nprintf "sent\\n" >> "%s/sent"\nprintf "%%s\\n" "$*" >> "%s/messages"\n' \
    "$TEST_ROOT" "$TEST_ROOT" "$TEST_ROOT" >"$NOTIFY_BIN"
chmod 755 "$NOTIFY_BIN"

# Optional event-driven receipts have no stale threshold; malformed evidence
# and future timestamps must never be accepted as successful.
receipt="$STATUS_DIR/test.json"
jq -n --argjson epoch "$((START_EPOCH - 90 * 86400))" \
    '{status:"OK",epoch:$epoch,summary:"Event audit complete"}' >"$receipt"
check_receipt "reboot|$receipt|0|0"
assert_clear
reset_findings
check_receipt "job|$receipt|192|1"
assert_issue job:overdue
(( ${#OK_ITEMS[@]} == 0 )) || fail 'overdue receipt also reported current'
reset_findings
printf '[]\n' >"$receipt"
check_receipt "job|$receipt|192|1"
assert_issue job:receipt

# Appdata accepts only finalized generations with consistent protected metadata.
APPDATA_BACKUP_ROOT="$TEST_ROOT/appdata"
generation="$APPDATA_BACKUP_ROOT/backup_$(date '+%Y%m%d_%H%M%S')"
mkdir -p "$generation" "$APPDATA_BACKUP_ROOT/backup_20990101_000000.partial"
printf 'fixture payload\n' >"$generation/plex.tar.gz"
bytes="$(stat -c %s "$generation/plex.tar.gz")"
hash="$(sha256sum "$generation/plex.tar.gz")"; hash="${hash%% *}"
{
    printf '# archive_count=1\n# created=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '123\t%s\t%s\tplex\n' "$bytes" "$hash"
} >"$generation/backup_manifest.tsv"
(cd "$generation" && sha256sum backup_manifest.tsv >backup_manifest.tsv.sha256)
reset_findings; check_appdata; assert_clear
printf 'changed size\n' >>"$generation/plex.tar.gz"
reset_findings; check_appdata; assert_issue appdata:metadata

# A fresh ZIP alone is insufficient. Require the producer's successful state,
# original size, matching sidecar, and a recent successfulAt timestamp.
FLASH_BACKUP_ROOT="$TEST_ROOT/flash"
FLASH_STATE_FILE="$FLASH_BACKUP_ROOT/.flash_backup_state.json"
mkdir -p "$FLASH_BACKUP_ROOT"
archive="$FLASH_BACKUP_ROOT/backup.zip"
printf 'fixture archive\n' >"$archive"
reset_findings; check_flash; assert_issue flash:state
hash="$(sha256sum "$archive")"; hash="${hash%% *}"
bytes="$(stat -c %s "$archive")"
printf '%s  backup.zip\n' "$hash" >"$archive.sha256"
jq -n --arg path "$archive" --arg hash "$hash" --argjson bytes "$bytes" --argjson now "$START_EPOCH" \
    '{backupFile:$path,archiveBytes:$bytes,archiveSha256:$hash,successfulAt:$now}' >"$FLASH_STATE_FILE"
reset_findings; check_flash; assert_clear
printf 'changed size\n' >>"$archive"
reset_findings; check_flash; assert_issue flash:size

# Arr execution can be current while application health is degraded. Do not
# duplicate its issue emails, but detect failed or overdue monitor execution.
ARR_STATE_FILE="$TEST_ROOT/arr.json"
jq -n --argjson now "$START_EPOCH" '{monitor:{lastStartedAt:$now,lastCompletedAt:$now,lastStatus:"DEGRADED",lastExitCode:0}}' >"$ARR_STATE_FILE"
reset_findings; check_arr_execution; assert_clear
jq '.monitor.lastCompletedAt -= 3600 | .monitor.lastStatus = "running"' "$ARR_STATE_FILE" >"$ARR_STATE_FILE.next"
mv "$ARR_STATE_FILE.next" "$ARR_STATE_FILE"
reset_findings; check_arr_execution; assert_issue arr:overdue
jq '.monitor.lastStatus = "failed" | .monitor.lastExitCode = 1' "$ARR_STATE_FILE" >"$ARR_STATE_FILE.next"
mv "$ARR_STATE_FILE.next" "$ARR_STATE_FILE"
reset_findings; check_arr_execution; assert_issue arr:failed

# Healthy silence; changed/partial/all recovery; stable keys despite changing
# ages; delivery failure retries without incorrectly committing sent state.
reset_findings; update_notifications || fail 'initial healthy audit failed'
[[ ! -e "$TEST_ROOT/sent" ]] || fail 'initial healthy audit sent email'
add_item CRITICAL job:overdue 'Job overdue: 9 days'
update_notifications >/dev/null || fail 'new finding notification failed'
reset_findings; add_item CRITICAL job:overdue 'Job overdue: 16 days'
update_notifications >/dev/null || fail 'unchanged audit failed'
[[ "$(wc -l <"$TEST_ROOT/sent")" -eq 1 ]] || fail 'unchanged finding sent reminder'
add_item WARNING other:failed 'Other job failed'
update_notifications >/dev/null || fail 'changed notification failed'
reset_findings; add_item WARNING other:failed 'Other job failed'
update_notifications >/dev/null || fail 'partial recovery notification failed'
reset_findings; update_notifications >/dev/null || fail 'full recovery failed'
grep -Fq 'Audit RESOLVED' "$TEST_ROOT/messages" || fail 'missing resolution notification'
update_notifications >/dev/null || fail 'healthy repeat failed'
[[ "$(wc -l <"$TEST_ROOT/sent")" -eq 4 ]] || fail 'wrong transition notification count'
add_item CRITICAL retry:failed 'Pending failure'
touch "$TEST_ROOT/fail-notify"
if update_notifications >/dev/null; then fail 'notification failure was swallowed'; fi
jq -e '.issues == []' "$NOTIFICATION_STATE_FILE" >/dev/null || fail 'failed delivery advanced state'
rm "$TEST_ROOT/fail-notify"
update_notifications >/dev/null || fail 'pending delivery was not retried'
[[ "$(wc -l <"$TEST_ROOT/sent")" -eq 5 ]] || fail 'retry notification missing'
write_receipt CRITICAL 'Fixture findings' || fail 'audit completion receipt failed'
jq -e '.name == "daily_digest" and .scriptVersion == "2.0" and .status == "CRITICAL"' \
    "$STATUS_DIR/daily_digest.json" >/dev/null || fail 'incorrect audit completion receipt'
printf 'daily_digest fixture tests passed\n'
