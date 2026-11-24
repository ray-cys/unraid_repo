#!/usr/bin/env bash
# Isolated working folders and API snapshots; no network or production paths.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/sab-orphans.XXXXXX); fixture=$(realpath "$fixture")
trap 'rm -rf -- "$fixture"' EXIT
source "$repo/user_script/sabnzbd_cleanup.sh"
trap 'rm -rf -- "$fixture"' EXIT
LOG_DIR="$fixture/log"; LOG_FILE="$LOG_DIR/run.log"; TMP_DIR="$fixture/tmp"
SAB_COMPLETE_ROOT="$fixture/complete"; SAB_TV_DIR_REAL="$SAB_COMPLETE_ROOT/series"; SAB_MOVIE_DIR_REAL="$SAB_COMPLETE_ROOT/movies"
QUARANTINE_DIR_REAL="$fixture/quarantine"; IMPORT_RECEIPT_FILE="$fixture/imports.json"
SAB_HISTORY_FILE="$fixture/history.json"; SAB_QUEUE_FILE="$fixture/queue.json"
SONARR_QUEUE_FILE="$fixture/sonarr.json"; RADARR_QUEUE_FILE="$fixture/radarr.json"
mkdir -p "$LOG_DIR" "$TMP_DIR" "$SAB_TV_DIR_REAL" "$SAB_MOVIE_DIR_REAL" "$QUARANTINE_DIR_REAL" "$fixture/library"
printf '[]' >"$SAB_HISTORY_FILE"; printf '{"queue":{"slots":[]}}' >"$SAB_QUEUE_FILE"
printf '{"records":[]}' >"$SONARR_QUEUE_FILE"; cp "$SONARR_QUEUE_FILE" "$RADARR_QUEUE_FILE"
printf '{"version":1,"receipts":{}}' >"$IMPORT_RECEIPT_FILE"
DRY_RUN=false; MAX_QUARANTINES_PER_RUN=20; MOVER_GUARD_ENABLED=false
QUARANTINE_OWNER=$(id -un)
# Test namespace time without sleeping or changing host time.
fake_now=$(command date +%s)
date() { if [[ "$*" == +%s ]]; then printf '%s\n' "$fake_now"; else command date "$@"; fi; }
fetch_required_state() { return "${REFRESH_RC:-0}"; }
ops_flush_file() { return 0; }; ops_flush_move() { return 0; }
mkdir "$SAB_TV_DIR_REAL/_UNPACK_active" "$SAB_TV_DIR_REAL/_UNPACK_empty" "$SAB_TV_DIR_REAL/_UNPACK_unknown" "$SAB_TV_DIR_REAL/_FAILED_retry" "$SAB_TV_DIR_REAL/__ADMIN__" "$SAB_TV_DIR_REAL/_UNPACK_arr" "$SAB_TV_DIR_REAL/_UNPACK_link" "$SAB_TV_DIR_REAL/ordinary"
printf media >"$SAB_TV_DIR_REAL/_UNPACK_active/show.mkv"
printf unknown >"$SAB_TV_DIR_REAL/_UNPACK_unknown/show.mkv"
ln -s "$fixture/library" "$SAB_TV_DIR_REAL/_UNPACK_link/unsafe"
printf '[{"nzo_id":"active","name":"active","status":"Queued"},{"nzo_id":"retry","name":"retry","status":"Failed"}]' >"$SAB_HISTORY_FILE"
printf '{"records":[{"title":"arr"}]}' >"$SONARR_QUEUE_FILE"
process_orphan_folders
[[ -d "$SAB_TV_DIR_REAL/_UNPACK_empty" && "$ORPHANS_QUARANTINED" == 0 ]]
# Repeated manual invocations cannot count as separate observations.
process_orphan_folders
jq -e 'all(.folders[];.observations==1)' "$LOG_DIR/orphan-folders.json" >/dev/null
fake_now=$((fake_now+49*3600))
process_orphan_folders
[[ ! -e "$SAB_TV_DIR_REAL/_UNPACK_empty" && "$ORPHANS_QUARANTINED" == 1 ]]
for name in _UNPACK_active _UNPACK_unknown _FAILED_retry __ADMIN__ _UNPACK_arr _UNPACK_link ordinary; do [[ -d "$SAB_TV_DIR_REAL/$name" ]]; done
manifest=$(find "$QUARANTINE_DIR_REAL" -name .sabnzbd-cleanup-manifest.json -print -quit)
jq -e '.state=="committed" and .importProof.proofKind=="empty-orphan"' "$manifest" >/dev/null
printf 'Idle queue with Queued PP, failed/retryable, Arr references, admin and unknown payloads preserved; empty orphan quarantined after hold\n'
# A changed directory restarts its hold, including files with backdated mtimes.
mkdir "$SAB_TV_DIR_REAL/_UNPACK_changed"
process_orphan_folders
fake_now=$((fake_now+49*3600)); printf added >"$SAB_TV_DIR_REAL/_UNPACK_changed/new.txt"
process_orphan_folders
jq -e --arg p "$SAB_TV_DIR_REAL/_UNPACK_changed" 'any(.folders[];.path==$p and .observations==1)' "$LOG_DIR/orphan-folders.json" >/dev/null
# A late Queued job discovered at final refresh vetoes an eligible empty orphan.
mkdir "$SAB_TV_DIR_REAL/_UNPACK_late"
process_orphan_folders; fake_now=$((fake_now+49*3600))
fetch_required_state() { printf '[{"name":"late","status":"Queued"}]' >"$SAB_HISTORY_FILE"; }
process_orphan_folders
[[ -d "$SAB_TV_DIR_REAL/_UNPACK_late" ]]
printf 'Changes reset hold; fresh post-processing ownership vetoes a late move\n'
# Exact-path durable receipt can prove a nonempty orphan after native history pruning.
fetch_required_state() { return 0; }
printf '[]' >"$SAB_HISTORY_FILE"; printf '{"records":[]}' >"$SONARR_QUEUE_FILE"
path="$SAB_TV_DIR_REAL/_UNPACK_proven"; mkdir "$path"; printf movie >"$path/show.mkv"; printf imported >"$fixture/library/show.mkv"
jq -n --arg p "$path" --argjson epoch "$((fake_now-20*86400))" '{version:1,receipts:{"Sonarr:proof-id":{app:"Sonarr",downloadId:"proof-id",conflict:false,targets:{one:{kind:"episode",targetId:11,parentId:1,fileId:21,pathAtImport:"/library/show.mkv"}},sab:{nzo_id:"proof-id",name:"proven",storage:$p,completed:$epoch,category:"tv"}}}}' >"$IMPORT_RECEIPT_FILE"
verify_download_cleanup_proof() {
  [[ "$2" == proof-id && "$3" == "$path" ]] || return 1
  jq -n --arg p "$fixture/library/show.mkv" '{proofKind:"durable-import-receipt",importedPaths:[$p]}' >"$4"
}
process_orphan_folders; fake_now=$((fake_now+49*3600)); process_orphan_folders
[[ ! -e "$path" ]]
printf 'Nonempty orphan requires exact storage and shared verified-import proof\n'
# Failed API refresh and malformed reference snapshots cannot authorize removal.
path="$SAB_TV_DIR_REAL/_UNPACK_api"; mkdir "$path"
process_orphan_folders; fake_now=$((fake_now+49*3600))
fetch_required_state() { return 1; }
if process_orphan_folders; then echo 'API failure incorrectly accepted' >&2; exit 1; fi
[[ -d "$path" ]]
printf invalid >"$SAB_HISTORY_FILE"
orphan_has_live_reference "$path" Sonarr
printf 'API and reference-parse failures fail closed\n'
# Mature dry-run candidates are described but remain in their source location.
printf '[]' >"$SAB_HISTORY_FILE"
fetch_required_state() { return 0; }
DRY_RUN=true; path="$SAB_TV_DIR_REAL/_UNPACK_preview"; mkdir "$path"
process_orphan_folders; fake_now=$((fake_now+49*3600)); before=$ORPHANS_QUARANTINED
process_orphan_folders
[[ -d "$path" && "$ORPHANS_QUARANTINED" -gt "$before" ]]
printf 'Dry-run preserves mature orphan payloads and records previews\n'
