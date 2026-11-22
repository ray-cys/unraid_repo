#!/bin/bash
# shellcheck disable=SC2034
arrayStarted=true
# ImageMaid restore-generation preparation v1.0.
# Schedule 50 6 * * 3,7, ten minutes before current Wed/Sun 07:00 runs.
# Preserve every restore image using an atomic same-filesystem directory rename.
# Never purge archives or change Plex's active Metadata/Media directories.
# An active/unverified ImageMaid run prohibits preparation. Idle resident
# scheduler is stopped briefly under a watchdog lease, then restarted.
set -uo pipefail
readonly SCRIPT_VERSION="1.0"
CONTAINER="${CONTAINER:-imagemaid}"
PLEX_ROOT="${PLEX_ROOT:-/mnt/cache/appdata/plex-media-server/Library/Application Support/Plex Media Server}"
STATE_DIR="${STATE_DIR:-/mnt/vault/cloud/logs/script/imagemaid_restore_archive}"
STATUS_DIR="${STATUS_DIR:-/mnt/vault/cloud/logs/script/user_scripts_status}"
LEASE_DIR="${LEASE_DIR:-/run/docker-service-maintenance}"
NOTIFY_BIN="${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}"
NEEDS_RESTART=false
LEASE_FILE=""
ARCHIVED_PATH=""
archive_cleanup() {
    local rc=$? restart_alerted=false
    trap - EXIT
    if [[ "$NEEDS_RESTART" == true ]]; then
        if timeout 45 docker start "$CONTAINER" >/dev/null 2>&1 &&
           [[ $(timeout 10 docker inspect -f '{{.State.Running}}' "$CONTAINER") == true ]]; then
            printf 'ImageMaid resident scheduler restarted.\n'
        else
            timeout 30 "$NOTIFY_BIN" -i alert -s 'ImageMaid Restore Archive' -d 'Scheduler restart failed' -m "Restore images preserved at ${ARCHIVED_PATH:-$PLEX_ROOT/ImageMaid Restore}. ImageMaid could not be restarted; Docker recovery is not assumed." >/dev/null 2>&1 || true
            rc=1; restart_alerted=true
        fi
    fi
    [[ -z "$LEASE_FILE" ]] || rm -f -- "$LEASE_FILE"
    if (( rc!=0 )) && [[ "$restart_alerted" != true ]]; then
        timeout 30 "$NOTIFY_BIN" -i warning -s 'ImageMaid Restore Archive' -d 'Pre-run preparation failed' -m "Archival preparation did not complete (exit=$rc). Original/archived restore images were not purged. Archived path: ${ARCHIVED_PATH:-none}. Scheduler restart was attempted if this run stopped it; inspect the retained checkpoint before retrying an ambiguous move." >/dev/null 2>&1 || true
    fi
    exit "$rc"
}
main() {
    if [[ ${1:-} == --version ]]; then printf 'imagemaid_restore_archive.sh %s\n' "$SCRIPT_VERSION"; return; fi
    [[ $# == 0 ]] || { printf 'Usage: bash imagemaid_restore_archive.sh\nPre-run archival only; no purge or restore-image deletion.\n'; return 2; }
    local platform_version
    if [[ -r "${UNRAID_VERSION_FILE:-/etc/unraid-version}" ]]; then
        platform_version=$(sed -n 's/^version="\([^"]*\)"/\1/p' "${UNRAID_VERSION_FILE:-/etc/unraid-version}")
        [[ "$platform_version" == 7.* ]] || { printf 'Unvalidated Unraid %s; maintenance/config mutations deferred.\n' "$platform_version"; return 0; }
    fi
    for cmd in docker jq flock timeout stat mv realpath; do command -v "$cmd" >/dev/null || return 1; done
    mountpoint -q /mnt/cache && mountpoint -q /mnt/vault || return 1
    [[ "$CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && ! -L "$PLEX_ROOT" && $(realpath -e "$PLEX_ROOT") == "$PLEX_ROOT" ]] || return 1
    mv --help | grep -q -- --no-copy || { printf 'Atomic no-copy rename unavailable; no images changed.\n'; return 1; }
    mkdir -p "$STATE_DIR" "$STATUS_DIR" "$LEASE_DIR" || return 1
    exec 9>"$STATE_DIR/archive.lock"; flock -n 9 || return 0
    trap archive_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    exec {gate}>"${ARR_BACKUP_GATE:-/run/arr-appdata-coordination.lock}"; flock -s -n "$gate" || { printf 'Appdata maintenance active; ImageMaid archive deferred.\n'; return 0; }
    exec {producer}>"${APPDATA_LOCK_FILE:-/tmp/appdata_backup.lock}"; flock -s -n "$producer" || return 0
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}"; flock -s -n "$export_fd" || return 0
    local source="$PLEX_ROOT/ImageMaid Restore" root="$PLEX_ROOT/ImageMaid Restore Archives" temp identity bytes archive boot process_start
    [[ -d "$source" && ! -L "$source" ]] || { printf 'No active ImageMaid restore tree; preparation not needed.\n'; return 0; }
    [[ ! -L "$root" && $(realpath -m "$root") == "$root" ]] || return 1
    timeout 10 docker inspect "$CONTAINER" | jq -e --arg p "$PLEX_ROOT" 'length==1 and .[0].State.Running==true and any(.[0].Mounts[];.Destination=="/plex" and .Source==$p)' >/dev/null || { printf 'Expected running ImageMaid /plex mapping not proven; no changes.\n'; return 1; }
    local log_root log_before
    log_root=$(timeout 10 docker inspect "$CONTAINER" | jq -r '.[0].Mounts[]|select(.Destination=="/config/logs")|.Source') || return 1
    [[ -d "$log_root" && -f "$log_root/imagemaid.log" && ! -L "$log_root/imagemaid.log" ]] || return 1
    log_before=$(stat -c '%d:%i:%s:%y' "$log_root/imagemaid.log") || return 1
    # Native boundaries prove the previous run finished. No assumption based on
    # container uptime or a single generic completion word.
    if ! timeout 12 docker exec -i "$CONTAINER" python3 - <<'PY'
import re,sys
active=None;finished=False
with open('/config/logs/imagemaid.log',errors='replace') as f:
 for line in f:
  text=line.split('|',1)[-1].strip().strip('=| ').strip()
  if text=='Validating Options':active=True;finished=False
  if text=='ImageMaid Finished':finished=True
  if text.startswith('Total Runtime') and finished:active=False
sys.exit(0 if active is False else 1)
PY
    then
        printf 'ImageMaid is processing/unverified; restore tree preserved.\n'; return 0
    fi
    exec {lease_fd}>"$LEASE_DIR/$CONTAINER.lock"; flock -w 15 "$lease_fd" || return 1
    LEASE_FILE="$LEASE_DIR/$CONTAINER.restore-archive.json"
    boot=$(cat /proc/sys/kernel/random/boot_id)
    process_start=$(sed 's/.*) //' "/proc/$$/stat" | awk '{print $20}')
    temp=$(mktemp "$LEASE_DIR/.archive.XXXXXX") || return 1
    jq -n --arg boot "$boot" --arg processStart "$process_start" --argjson pid "$$" --argjson expires "$(( $(date +%s)+300 ))" '{boot:$boot,pid:$pid,processStart:$processStart,expires:$expires,reason:"ImageMaid restore archival"}' >"$temp" && mv "$temp" "$LEASE_FILE" || return 1
    trap archive_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    NEEDS_RESTART=true
    timeout 45 docker stop -t 20 "$CONTAINER" >/dev/null || return 1
    [[ $(timeout 10 docker inspect -f '{{.State.Running}}' "$CONTAINER") == false ]] || return 1
    [[ $(stat -c '%d:%i:%s:%y' "$log_root/imagemaid.log") == "$log_before" ]] || { printf 'ImageMaid log changed during preparation; archive aborted and scheduler will be restored.\n'; return 1; }
    identity=$(stat -c '%d:%i' "$source") || return 1
    bytes=$(timeout 15 du -sb "$source" | awk '{print $1}') || return 1
    [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
    mkdir -p "$root" || return 1
    archive="$root/restore_$(date +%Y%m%d_%H%M%S)_$$"
    [[ ! -e "$archive" ]] || return 1
    temp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 1
    jq -n --arg source "$source" --arg archive "$archive" --arg identity "$identity" --argjson bytes "$bytes" --argjson epoch "$(date +%s)" '{phase:"prepared",source:$source,archive:$archive,directoryIdentity:$identity,bytes:$bytes,epoch:$epoch}' >"$temp" && mv "$temp" "$STATE_DIR/state.json" || return 1
    mv --no-copy -T -- "$source" "$archive" || return 1
    ARCHIVED_PATH="$archive"
    [[ ! -e "$source" && $(stat -c '%d:%i' "$archive") == "$identity" ]] || return 1
    timeout 45 docker start "$CONTAINER" >/dev/null || return 1
    [[ $(timeout 10 docker inspect -f '{{.State.Running}}' "$CONTAINER") == true ]] || return 1
    NEEDS_RESTART=false
    temp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 1
    jq '.phase="complete" | .containerRestarted=true | .policy="all restore images retained; no archive expiry"' "$STATE_DIR/state.json" >"$temp" && mv "$temp" "$STATE_DIR/state.json" || return 1
    local summary="Preserved $((bytes/1048576)) MiB of ImageMaid restore images at $archive. Atomic rename verified by directory identity; no image files deleted or copied. Idle ImageMaid scheduler restarted; configured Wed/Sun 07:00 schedule retained. To undo, stop ImageMaid and restore this directory to its original name only when that name is absent."
    temp=$(mktemp "$STATUS_DIR/.imagemaid.XXXXXX") || return 1
    jq -n --arg name imagemaid_restore_archive --arg status OK --arg summary "$summary" --argjson epoch "$(date +%s)" '{name:$name,status:$status,summary:$summary,epoch:$epoch}' >"$temp" && mv "$temp" "$STATUS_DIR/imagemaid_restore_archive.json" || return 1
    printf '%s\n' "$summary"
    timeout 30 "$NOTIFY_BIN" -i normal -s 'ImageMaid Restore Archive' -d 'Restore images archived; scheduler ready' -m "$summary" >/dev/null 2>&1
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
