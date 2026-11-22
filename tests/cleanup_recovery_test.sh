#!/usr/bin/env bash
# Destructive operations are exercised only below an isolated temporary fixture.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/cleanup-recovery.XXXXXX)
fixture=$(realpath -- "$fixture")
trap 'rm -rf -- "$fixture"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
(
source "$repo/user_script/sabnzbd_cleanup.sh"
trap - EXIT INT TERM
LOG_DIR="$fixture/sab-logs" LOG_FILE="$fixture/sab-logs/operations.log"
OPS_NOTIFICATION_STATE="$LOG_DIR/notification-state.json"
TMP_DIR="$fixture/work" QUARANTINE_DIR_REAL="$fixture/quarantine"
SAB_MOVIE_DIR_REAL="$fixture/complete/movies" SAB_TV_DIR_REAL="$fixture/complete/series"
PURGE_RECEIPT_DIR="$LOG_DIR/purge-receipts"
mkdir -p "$LOG_DIR" "$TMP_DIR" "$QUARANTINE_DIR_REAL" "$SAB_MOVIE_DIR_REAL" "$SAB_TV_DIR_REAL"
DRY_RUN=false
check_mover_guard() { return 0; }
normalize_quarantine_permissions() { [[ "${break_commit:-false}" != true ]]; }
proof="$fixture/proof.json"; printf '{"verified":true}\n' >"$proof"
source_path="$SAB_MOVIE_DIR_REAL/Example Movie"; mkdir -p "$source_path"; printf 'fixture media\n' >"$source_path/movie.mkv"
# The intent must exist before the payload move begins.
mv() {
  if [[ "${2:-}" == "$source_path" ]]; then
    local destination="${3:-}" manifest="${3%/*}/.sabnzbd-cleanup-manifest.json"
    jq -e '.state=="prepared" and .originalPath!=""' "$manifest" >/dev/null || fail 'move occurred without a committed intent'
  fi
  command mv "$@"
}
break_commit=true
if quarantine_payload Radarr movie exact-id 'Example Movie' 100 "$source_path" 14 "$proof"; then fail 'injected commit failure was not detected'; fi
wrapper="${LAST_QUARANTINE_DESTINATION%/*}"
[[ -f "$wrapper/payload/movie.mkv" && ! -e "$source_path" ]] || fail 'interrupted move fixture incorrect'
jq -e '.state=="prepared"' "$wrapper/.sabnzbd-cleanup-manifest.json" >/dev/null
break_commit=false
recover_quarantine_preparations
jq -e '.state=="committed" and .recovered==true and .quarantinedEpoch>0' "$wrapper/.sabnzbd-cleanup-manifest.json" >/dev/null
[[ "$RECOVERED" == 1 ]] || fail 'recovery not counted'
# Restore refuses collisions and preserves both copies.
mkdir -p "$source_path"
if restore_quarantine_payload "$wrapper"; then fail 'restore overwrote an existing destination'; fi
rmdir "$source_path"
restore_quarantine_payload "$wrapper"
[[ -f "$source_path/movie.mkv" && ! -e "$wrapper" ]] || fail 'restore did not recover the original destination'
# Requarantine; purge uses manifest time even when the wrapper was touched now.
quarantine_payload Radarr movie another-id 'Example Movie' 100 "$source_path" 14 "$proof"
wrapper="${LAST_QUARANTINE_DESTINATION%/*}"; manifest="$wrapper/.sabnzbd-cleanup-manifest.json"
jq --argjson past "$(( $(date +%s)-40*86400 ))" '.quarantinedEpoch=$past' "$manifest" >"$TMP_DIR/aged.json"
command mv "$TMP_DIR/aged.json" "$manifest"
touch "$wrapper"
QUARANTINE_RETENTION_DAYS=14
purge_quarantine
[[ ! -e "$wrapper" && "$PURGED" == 1 ]] || fail 'manifest age purge failed'
jq -e 'select(.event=="purge_intent") | .files|length>0' "$PURGE_RECEIPT_DIR/$RUN_ID.jsonl" >/dev/null
# Failed notification remains pending; successful delivery advances state once.
NOTIFY="$fixture/notify"; NOTIFY_BIN="$NOTIFY"
printf '#!/bin/sh\nexit 1\n' >"$NOTIFY"; chmod +x "$NOTIFY"
if ops_notify alert 'Fixture cleanup' 'Detailed actions' 'Moved Example Movie; preserved blocker poster.jpg; removed 3 empty folders.'; then fail 'notification command failure was ignored'; fi
jq -e '(.outbox|length)==1 and (.lastSentAt // "")==""' "$OPS_NOTIFICATION_STATE" >/dev/null
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$fixture/notifications.txt" >"$NOTIFY"
ops_flush_notifications
jq -e '(.outbox|length)==0 and (.lastSentAt|length)>0' "$OPS_NOTIFICATION_STATE" >/dev/null
grep -q 'removed 3 empty folders' "$fixture/notifications.txt"
ops_notify normal 'Fixture cleanup' 'Next actions' 'Quarantined another payload; original path and proof preserved.'
jq -e '(.outbox|length)==1' "$OPS_NOTIFICATION_STATE" >/dev/null
# Split long reports are retained, not silently truncated; priority favors errors.
ops_notify alert 'Fixture failure' 'Preserved download' 'Import proof failed; payload untouched.'
jq 'del(.lastSentAt)' "$OPS_NOTIFICATION_STATE" >"$TMP_DIR/notify-reset.json"; command mv "$TMP_DIR/notify-reset.json" "$OPS_NOTIFICATION_STATE"
ops_flush_notifications
tail -n 4 "$fixture/notifications.txt" | grep -q 'Import proof failed' || fail 'urgent report was not prioritized'
)
(
source "$repo/user_script/arr_delete_sync_tag.sh"
RUNTIME_DIR="$fixture/arr-runtime" LOG_FILE="$fixture/arr-runtime/operations.log"
mkdir -p "$RUNTIME_DIR"
PENDING_ACTIONS_FILE="$RUNTIME_DIR/pending-actions.json" ACTION_RECEIPTS_FILE="$RUNTIME_DIR/action-receipts.jsonl"
PENDING_NOTIFICATIONS_FILE="$RUNTIME_DIR/pending-notifications.jsonl" NOTIFICATION_STATE_FILE="$RUNTIME_DIR/notification-state.json"
APP_CONTEXT=SONARR SEND_GROUPED_NOTIFICATIONS=true
initialize_grouped_notifications
# Full pagination must be proven, and failure must clear prior availability.
ARR_TEMP_PREFIX=sonarr ARR_NAME=Sonarr
api_get_json() {
  case "$1" in
    *page=1\&*) printf '{"records":[{"downloadId":"one"}],"totalRecords":2}\n';;
    *page=2\&*) if [[ "${truncated:-false}" == true ]]; then printf '{"records":[],"totalRecords":2}\n'; else printf '{"records":[{"downloadId":"two"}],"totalRecords":2}\n'; fi;;
  esac
}
load_arr_queue sonarr
[[ "$(jq '.records|length' <<<"$SONARR_QUEUE_JSON")" == 2 ]] || fail 'queue pagination failed'
truncated=true
if load_arr_queue sonarr; then fail 'truncated queue accepted'; fi
[[ "$SONARR_QUEUE_AVAILABLE" == false ]] || fail 'failed queue retained healthy status'
# Quarantined sidecar reconciliation restores permission checks and audits its outcome.
MOVIES_ROOT="$fixture/arr-movies" SERIES_ROOT="$fixture/arr-series" QUARANTINE_ROOT="$fixture/arr-bin"
mkdir -p "$MOVIES_ROOT/Example" "$SERIES_ROOT" "$QUARANTINE_ROOT/run/movies/Example"
original="$MOVIES_ROOT/Example/poster.jpg" destination="$QUARANTINE_ROOT/run/movies/Example/poster.jpg"
printf 'fixture artwork\n' >"$original"; hash=$(sha256sum "$original" | cut -d ' ' -f1)
id=$(journal_intent sidecar "$original" "$original" "$destination" "$hash")
if journal_intent sidecar "$original" "$original" "$destination" "$hash" >/dev/null; then fail 'pending action overwritten'; fi
command mv "$original" "$destination"
normalize_quarantine_permissions() { return 0; }
recover_pending_actions
jq -e '(.actions|length)==0' "$PENDING_ACTIONS_FILE" >/dev/null
grep -q 'Recovered interrupted sidecar move' "$ACTION_RECEIPTS_FILE"
grep -q 'Recovered interrupted sidecar quarantine' "$PENDING_NOTIFICATIONS_FILE"
# Notification failure and display caps preserve the outbox, including omitted actions.
NOTIFY_BIN="$fixture/arr-notify"; printf '#!/bin/sh\nexit 1\n' >"$NOTIFY_BIN"; chmod +x "$NOTIFY_BIN"
queue_action_notification Sonarr 'Removed empty series folder' 'Example Show: quarantined 3 artwork files, then removed Season 01 and series directory with rmdir.'
if send_grouped_notification; then fail 'Arr notification failure ignored'; fi
[[ -s "$PENDING_NOTIFICATIONS_FILE" ]] || fail 'failed Arr report discarded'
printf '#!/bin/sh\nexit 0\n' >"$NOTIFY_BIN"
NOTIFICATION_MAX_ITEMS=1
send_grouped_notification
[[ "$(wc -l <"$PENDING_NOTIFICATIONS_FILE")" -ge 1 ]] || fail 'omitted Arr event lost'
)
printf 'Cleanup intent, recovery, purge, restore, queue coverage and durable notification tests passed\n'
