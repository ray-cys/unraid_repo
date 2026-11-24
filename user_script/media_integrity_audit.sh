#!/bin/bash
# shellcheck disable=SC2034
arrayStarted=true
###############################################################################
# Media Integrity Audit v1.1.0 -- personal Unraid User Script
#
# PURPOSE / USE CASE
# ------------------
# Find unreadable containers and repeatable audio/video decoder errors before
# playback. Read only movies/, series/ and formula1/ under /mnt/user/media using
# Bazarr's existing FFprobe, FFmpeg and Python. No package/image/startup/config
# installation or modification. Default observation performs no media/Arr mutation.
# Optional bounded recovery is installed but AUTO_RECOVERY_ENABLED=false.
# Download/quarantine folders and /mnt/user/secure are outside this scope.
#
# PROCESS / COVERAGE
# ------------------
# Inventory regular video files without following symlinks. New/changed files
# receive a bounded stream/container probe, with up to 25% of the run (30 minutes)
# front-loaded for broad new-file coverage before expensive decoding. Deep work decodes every selected
# video and audio stream in successive, overlapping ten-minute media ranges;
# save the next range so long files resume on a later weekly run. This is full
# planned-range coverage, NOT a single linear read, checksum baseline, subtitle
# check, visual-quality test, or proof that every Plex client plays the file.
# Size/mtime/ctime/inode changes invalidate progress. Unchanged successful files
# become due again after 180 days; metadata alone cannot rule out later bit rot.
# Prefer new/changed work with a 60% share, reserving 40% for older periodic work
# when both lanes have work. In-progress files resume before starting more files.
#
# BOUNDS / COORDINATION
# ---------------------
# Wednesday 09:30 Singapore time (30 9 * * 3); at most two hours per invocation.
# Use two video decoder threads, one audio/filter thread, nice 15, idle-class I/O
# and a 2 GiB per-decoder virtual-address-space limit. This is not a container RAM
# limit. Slow ranges shrink after timeout; timeouts/resource limits are unverified,
# not corruption. One worker at a time; interrupted ranges never advance.
# Actual kernel I/O stalls may outlast termination requests. Missing mounts/API,
# Mover, active parity, backups, Bazarr maintenance or Plex transcodes defer/stop
# read work. A paused parity operation with mdResync=0 does not imply active I/O.
# No long-held backup lock: appdata backup never waits two hours for this audit.
#
# FINDINGS / RECOVERY / NOTIFICATIONS
# ----------------------------------
# Repeat a decoder/container failure on the same unchanged file when budget
# permits; report repeatable errors separately from unsupported tools, permission
# errors, timeouts and incomplete coverage. A changed file is pending verification,
# never automatically healthy. Two clean same-range rechecks can close a prior
# finding; replacement files require a completed planned-range cycle. Confirmed
# inventory removal is reported as removed, not repaired. Failed files retry on
# later schedules rather than consuming the same run repeatedly.
# All run summaries/progress/recoveries remain in local reports. Only active
# findings, unexpected failures, state fallback or incomplete/overdue recovery
# trigger grouped attention email. Same evidence reminds at most weekly; progress
# alone and healthy scan/recovery completion never send success email. A failed
# attention email remains in one pending outbox and retries while still relevant.
#
# OPTIONAL ARR RECOVERY (OFF): two distinct confirming runs on one unchanged
# version, fresh <=48h evidence and matching decoder runtime. Exact monitored
# Arr file/parent/episode IDs and quiet health/queues/commands are required.
# Preserve original via a no-overwrite, no-copy move into integrity_quarantine,
# journal the intent before removing the obsolete Arr file record, verify 404,
# then submit one exact EpisodeSearch/MoviesSearch. Never lower a profile, monitor a previously unmonitored target,
# blocklist by title, delete the title, or use whole-library searches.
# Native unmonitor-on-delete is handled only by restoring the exact target
# monitored state recorded before our own immediate deletion; global settings
# stay unchanged. Uncertain or later/user changes require review.
# Lost responses are not replayed. One new recovery/pass, three/week, one attempt
# per target set/30 days. Replacement must pass a later full planned-range cycle;
# search acceptance/import alone is not health. Originals are never auto-purged.
# Existing Arr monitor calls --recover-only in 00/04/08/12/16/20:00-09 SGT windows.
# Same audit lock, backup gate and metadata lock prevent overlapping mutations.
# Delete-sync holds affected Sonarr series; conservatively pauses Radarr while
# any movie hold is unresolved. Review holds do not silently expire. Unmanaged
# Formula1, timeouts/resources/read errors and ambiguous IDs remain review-only.
#
# STATE / LOGS / CLI
# ------------------
# Own /mnt/vault/cloud/logs/script/media_integrity_audit: one compressed JSON state,
# one previous validated state, required recovery.json intent/hold journal,
# an overwritten latest-report.txt, notification
# outbox/receipt and a 1 MiB log with two backups (30-day backup retention).
# Checkpoint at most once per minute and at completion; incomplete last ranges
# may be repeated after interruption. Never create a shadow vault under RAM.
# --help / --version: no scans. --status: saved evidence only, no Docker/media I/O.
# --inventory-only: inventory/stat only; may wake disks and updates audit state,
# but performs no FFprobe/decoding and sends no normal summary. No argument: real
# scheduled audit (read-only while recovery is disabled). --recovery-status reads
# only the recovery journal. --recover-only cannot override the disabled switch.
# No scan, timeout or error changes media permissions.
###############################################################################
set -uo pipefail
umask 077
readonly SCRIPT_VERSION="1.1.0"
BAZARR_CONTAINER="bazarr"
MEDIA_HOST_ROOT="/mnt/user/media"
MEDIA_CONTAINER_ROOT="/data"
LIBRARY_SUBDIRS=(movies series formula1)
STATE_DIR="${STATE_DIR:-/mnt/vault/cloud/logs/script/media_integrity_audit}"
STATUS_DIR="${STATUS_DIR:-/mnt/vault/cloud/logs/script/user_scripts_status}"
VAULT_MOUNT="/mnt/vault"
STATE_FILE="$STATE_DIR/state.json.gz"
PREVIOUS_STATE_FILE="$STATE_DIR/state.previous.json.gz"
LOG_FILE="$STATE_DIR/media-integrity-audit.log"
LOCK_FILE="${LOCK_FILE:-/run/media_integrity_audit.lock}"
NOTIFY_BIN="${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}"
MAX_RUNTIME_SECONDS=7200
QUICK_PASS_MAX_SECONDS=1800
VIDEO_THREADS=2
DECODER_MEMORY_MIB=2048
SEGMENT_MEDIA_SECONDS=600
SEGMENT_WALL_SECONDS=600
FILE_SLICE_SECONDS=900
RECHECK_DAYS=180
SETTLE_SECONDS=600
MAX_STATE_BYTES=$((64*1024*1024))
LOG_MAX_BYTES=$((1024*1024))
NOTIFY_MAX_ITEMS=20
BACKUP_LOCK_FILES=(/tmp/appdata_backup.lock /tmp/remote_backup.lock /run/vault_backup.lock)
PLEX_CONTAINERS=(plex-media-server plex-media)
ARR_BACKUP_GATE="/run/arr-appdata-coordination.lock"
STATE_EXPORT_LOCK="/run/user-script-state-export.lock"
DOCKER_MAINTENANCE_DIR="/run/docker-service-maintenance"
# Observation remains the default. Enabling this later permits preservation +
# exact Arr file-record removal + one targeted search, only after two separate
# audit runs confirm the same unchanged decoder error. No force/quality override.
AUTO_RECOVERY_ENABLED=false
SONARR_API_ROOT="${SONARR_API_ROOT:-http://192.168.50.4:8989/api/v5}"
SONARR_API_KEY="${SONARR_API_KEY:-PUT_YOUR_SONARR_API_KEY_HERE}"
RADARR_API_ROOT="${RADARR_API_ROOT:-http://192.168.50.4:7878/api/v3}"
RADARR_API_KEY="${RADARR_API_KEY:-PUT_YOUR_RADARR_API_KEY_HERE}"
SONARR_MEDIA_ROOT="/data"
RADARR_MEDIA_ROOT="/data"
RECOVERY_FILE="$STATE_DIR/recovery.json"
RECOVERY_MAX_NEW_PER_RUN=1
RECOVERY_MAX_NEW_PER_WEEK=3
RECOVERY_WAIT_DAYS=28
RECOVERY_MAX_SECONDS=180
RECOVERY_DEADLINE=0
NOTIFICATION_REMINDER_SECONDS=604800

recovery_window_open() {
    local hour minute
    hour=$(TZ=Asia/Singapore date +%H);minute=$(TZ=Asia/Singapore date +%M)
    ((10#$hour%4==0 && 10#$minute<10))
}

recovery_new_window_open() {
    local minute
    recovery_window_open || return 1
    minute=$(TZ=Asia/Singapore date +%M)
    ((10#$minute<7)) # reserve the final three minutes for in-flight work
}

TMP_DIR="" WORKER_PID="" WORKER_TOKEN="" WORKER_FINISHED=false
RUN_REPORT_WRITTEN=false FAILURE_REASON=""
MODE=scan GUARD_REASON="" RECOVERY_NOTE="" TRANSPORT_RC=0

log() {
    local level="$1"; shift
    if [[ -f "$LOG_FILE" ]] && (( $(stat -c %s "$LOG_FILE" 2>/dev/null || printf 0)>=LOG_MAX_BYTES )); then
        rm -f -- "$LOG_FILE.2"
        [[ ! -f "$LOG_FILE.1" ]] || mv -f "$LOG_FILE.1" "$LOG_FILE.2"
        mv -f "$LOG_FILE" "$LOG_FILE.1"
    fi
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$*" | tee -a "$LOG_FILE"
}

probe_lock() {
    local fd path="$1"
    [[ ! -e "$path" ]] || { exec {fd}>"$path" || return 1; flock -s -n "$fd"; local rc=$?; exec {fd}>&-; return "$rc"; }
}

workload_guard() {
    local info values active position lock lease now processes container
    GUARD_REASON=""
    mountpoint -q /mnt/user && mountpoint -q "$VAULT_MOUNT" || { GUARD_REASON='Required user/vault mount unavailable'; return 1; }
    [[ -d "$MEDIA_HOST_ROOT" && ! -L "$MEDIA_HOST_ROOT" ]] || { GUARD_REASON='Media root unavailable or symlinked'; return 1; }
    for lock in "$ARR_BACKUP_GATE" "${BACKUP_LOCK_FILES[@]}"; do
        probe_lock "$lock" || { GUARD_REASON="Backup/maintenance lock active: ${lock##*/}"; return 1; }
    done
    if pgrep -f '(^|/)(mover|mover\.old)([[:space:]]|$)|mover\.php' >/dev/null; then GUARD_REASON='Unraid Mover is active'; return 1; fi
    values=$(timeout 5 /usr/local/sbin/mdcmd status 2>/dev/null) || { GUARD_REASON='Array/parity state unavailable'; return 1; }
    grep -q '^mdState=STARTED$' <<<"$values" || { GUARD_REASON='Array not started'; return 1; }
    active=$(awk -F= '$1=="mdResync" {print $2}' <<<"$values")
    position=$(awk -F= '$1=="mdResyncPos" {print $2}' <<<"$values")
    [[ "$active" =~ ^[0-9]+$ && "$position" =~ ^[0-9]+$ ]] || { GUARD_REASON='Parity fields unverified'; return 1; }
    if (( active>0 && position>0 )); then GUARD_REASON='Active parity/check/rebuild I/O'; return 1; fi
    now=$(date +%s)
    for lease in "$DOCKER_MAINTENANCE_DIR/$BAZARR_CONTAINER"*.json; do
        [[ -e "$lease" ]] || continue
        if ! jq -e --argjson now "$now" '(.expires|type)=="number" and .expires<=$now' "$lease" >/dev/null 2>&1; then
            GUARD_REASON='Bazarr maintenance lease active/unverified'; return 1
        fi
    done
    info=$(timeout 8 docker inspect "$BAZARR_CONTAINER" 2>/dev/null) || { GUARD_REASON='Bazarr inspection unavailable'; return 1; }
    if ! jq -e --arg source "$MEDIA_HOST_ROOT" --arg dest "$MEDIA_CONTAINER_ROOT" \
        'length==1 and .[0].State.Running==true and any(.[0].Mounts[]; .Type=="bind" and .Source==$source and .Destination==$dest)' <<<"$info" >/dev/null; then
        GUARD_REASON='Bazarr stopped or exact media bind mount unverified'; return 1
    fi
    for container in "${PLEX_CONTAINERS[@]}"; do
        if [[ $(timeout 6 docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null) == false ]]; then continue;fi
        processes=$(timeout 6 docker top "$container" -eo pid,comm 2>/dev/null) || { GUARD_REASON="Plex workload unverified: $container"; return 1; }
        if grep -Eq '[[:space:]]Plex Transcoder([[:space:]]|$)' <<<"$processes"; then GUARD_REASON="Plex transcoder active: $container"; return 1; fi
    done
}

cancel_worker() {
    [[ -n "$WORKER_TOKEN" && "$WORKER_FINISHED" != true ]] || return 0
    timeout 8 docker exec --user 99:100 "$BAZARR_CONTAINER" python3 -c '
import json,os,signal,sys
key=sys.argv[1];path="/tmp/media-integrity-audit."+key+".json"
try:
 fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
 with os.fdopen(fd) as f: d=json.load(f)
 pid=int(d["pid"])
 if d["token"]==key and key.encode() in open(f"/proc/{pid}/cmdline","rb").read().split(b"\0") and open(f"/proc/{pid}/stat").read().split()[21]==d["start"]:
  os.kill(pid,signal.SIGTERM)
except (FileNotFoundError,ProcessLookupError):pass
' "$WORKER_TOKEN" >/dev/null 2>&1 || true
}

cleanup() {
    cancel_worker
    [[ -z "$WORKER_PID" ]] || { kill "$WORKER_PID" 2>/dev/null || true; wait "$WORKER_PID" 2>/dev/null || true; }
    [[ -z "$TMP_DIR" || "$TMP_DIR" != /tmp/media-integrity-audit.* ]] || rm -rf -- "$TMP_DIR"
}

# If startup/storage/reporting fails before the normal grouped report can be
# written, still emit a bounded operational alert. Never invent healthy state
# or create a shadow vault/log tree. Explicit cancellation stays quiet.
finish() {
    local rc=$? marker
    trap - EXIT
    cleanup
    if ((rc!=0 && rc!=130 && rc!=143)) && [[ "$RUN_REPORT_WRITTEN" != true ]]; then
        marker="/tmp/media-integrity-preflight-$(date +%F).notified"
        printf 'Media integrity audit failed before normal reporting: %s (exit %s)\n' "${FAILURE_REASON:-${GUARD_REASON:-Startup or report persistence failed}}" "$rc" >&2
        if [[ ! -e "$marker" && -x "$NOTIFY_BIN" ]] && command -v timeout >/dev/null; then
            if timeout 30 "$NOTIFY_BIN" -i alert -s 'Media Integrity Audit' -d 'Audit could not complete normal reporting' \
              -m "Failure: ${FAILURE_REASON:-${GUARD_REASON:-Startup or persistent reporting failed}} (exit $rc).
No unverified scan/recovery was marked healthy. Existing recovery originals, intent records and deletion-sync holds remain protected. Correct the missing command/storage/configuration or reporting failure before the next run; review the User Scripts console for the failing operation."; then : >"$marker";fi
        fi
    fi
    exit "$rc"
}

load_state() {
    local file="$STATE_FILE"
    [[ ! -L "$file" && ! -L "$PREVIOUS_STATE_FILE" ]] || return 1
    if [[ ! -f "$file" ]]; then
        if [[ -f "$PREVIOUS_STATE_FILE" ]]; then file="$PREVIOUS_STATE_FILE";RECOVERY_NOTE='Current state missing; using previous validated checkpoint'
        else printf '{"schema":1,"files":{}}\n' >"$TMP_DIR/state.json";return 0; fi
    fi
    if ! unpack_state "$file"; then
        [[ "$file" != "$PREVIOUS_STATE_FILE" && -f "$PREVIOUS_STATE_FILE" ]] && unpack_state "$PREVIOUS_STATE_FILE" || return 1
        file="$PREVIOUS_STATE_FILE";RECOVERY_NOTE='Current state invalid; resumed previous validated checkpoint; recent work may repeat'
    fi
    cp -- "$file" "$PREVIOUS_STATE_FILE.new" 2>/dev/null && gzip -t "$PREVIOUS_STATE_FILE.new" 2>/dev/null && mv -f "$PREVIOUS_STATE_FILE.new" "$PREVIOUS_STATE_FILE" || true
}

unpack_state() {
    local file="$1" bytes
    (( $(stat -c %s "$file")<=MAX_STATE_BYTES )) || return 1
    if ! timeout 15 gzip -dc -- "$file" 2>/dev/null | head -c "$((MAX_STATE_BYTES+1))" >"$TMP_DIR/state.json"; then return 1; fi
    bytes=$(stat -c %s "$TMP_DIR/state.json")
    (( bytes<=MAX_STATE_BYTES )) && jq -e '
      .schema==1 and (.files|type)=="object" and
      all(.files|to_entries[];
        (.key|type)=="string" and (.key|test("(^/|(^|/)\\.\\.?(/|$))")|not) and
        (.value|type)=="object" and (.value.identity|type)=="array" and (.value.identity|length)==5 and
        (.value.issue==null or ((.value.issue|type)=="object" and (.value.issue.id|type)=="string" and (.value.issue.kind|type)=="string")))
      ' "$TMP_DIR/state.json" >/dev/null
}

save_checkpoint() {
    local event="$1"
    printf '%s\n' "$event" | jq -er .payload >"$TMP_DIR/checkpoint.base64" || return 1
    printf '%s\n' "$event" | jq .stats >"$TMP_DIR/checkpoint.stats.json" || return 1
    commit_checkpoint "$TMP_DIR/checkpoint.base64" "$TMP_DIR/checkpoint.stats.json"
}

commit_checkpoint() {
    local payload="$1" stats="$2" temp fd
    temp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 1
    if ! base64 -d "$payload" >"$temp" || ! gzip -t "$temp"; then rm -f "$temp";return 1;fi
    exec {fd}>"$STATE_EXPORT_LOCK" || { rm -f "$temp";return 1; }
    if ! flock -s -w 5 "$fd"; then exec {fd}>&-;rm -f "$temp";return 75;fi
    mv -f "$temp" "$STATE_FILE";local rc=$?
    exec {fd}>&-
    cp "$stats" "$TMP_DIR/stats.json"
    return "$rc"
}

write_report() {
    local fd rc=0
    exec {fd}>"$STATE_EXPORT_LOCK" || return 1
    if ! flock -s -w 30 "$fd"; then exec {fd}>&-;return 1;fi
    render_report "$@" || rc=$?
    exec {fd}>&-
    return "$rc"
}

render_report() {
    local status="$1" reason="$2" now sent=0 temp body importance=normal last=0 previous="" signature
    now=$(date +%s)
    [[ ! -f "$STATE_DIR/notified.json" ]] || sent=$(jq -r '.sentAt // 0' "$STATE_DIR/notified.json")
    [[ "$sent" =~ ^[0-9]+$ ]] || sent=0
    [[ ! -f "$STATE_FILE" ]] || unpack_state "$STATE_FILE" || true
    if ! jq -e '.schema==1 and (.files|type)=="object"' "$TMP_DIR/state.json" >/dev/null 2>&1; then printf '{"schema":1,"files":{}}' >"$TMP_DIR/state.json";fi
    [[ -f "$TMP_DIR/state.json" ]] || printf '{"schema":1,"files":{}}' >"$TMP_DIR/state.json"
    [[ -f "$TMP_DIR/stats.json" ]] || printf '{}' >"$TMP_DIR/stats.json"
    if [[ -f "$RECOVERY_FILE" ]] && recovery_valid; then cp "$RECOVERY_FILE" "$TMP_DIR/recovery-report.json";else printf '{"schema":1,"actions":{}}' >"$TMP_DIR/recovery-report.json";fi
    temp=$(mktemp "$STATE_DIR/.report.XXXXXX") || return 1
    jq -n --slurpfile state "$TMP_DIR/state.json" --slurpfile stats "$TMP_DIR/stats.json" --slurpfile recoveryState "$TMP_DIR/recovery-report.json" \
        --argjson recoveryWait "$((RECOVERY_WAIT_DAYS*86400))" --argjson recoveryEnabled "$AUTO_RECOVERY_ENABLED" --arg status "$status" --arg mode "$MODE" --arg reason "$reason" --arg recovery "$RECOVERY_NOTE" \
        --arg root "$MEDIA_HOST_ROOT" --argjson now "$now" --argjson sent "$sent" --argjson max "$NOTIFY_MAX_ITEMS" \
        '($recoveryState[0].actions // {} | to_entries | sort_by(.value.status!="review",-(.value.updatedAt // 0))) as $actions |
         [$actions[]|select(.value.status=="review" or .value.status=="delete_intent" or .value.status=="monitor_intent" or .value.status=="search_intent" or .value.status=="moved" or .value.status=="deleted" or (.value.status!="verified" and (($recoveryEnabled|not) or $now-.value.startedAt>$recoveryWait)))] as $recoveryAttention |
         ($state[0].files // {} | to_entries) as $files |
         [$files[]|select(.value.issue!=null)] as $issues |
         [($state[0].resolved // [])[]|select(.resolvedAt>$sent)] as $fixed |
         ($stats[0]) as $r |
         ([$state[0].runs[]? | .decodeWallSeconds // 0]|add // 0) as $wall |
         ([$state[0].runs[]? | .mediaSecondsDecoded // 0]|add // 0) as $media |
         ([$files[]|select((.value.verifiedAt // 0)==0)|((.value.duration // 0)-(.value.offset // 0))]|add // 0) as $remaining |
         ([$files[]|select((.value.duration // 0)<=0)]|length) as $unknown |
         (if $status=="FAILED" then "FAILED" elif ($issues|length)>0 or ($recoveryAttention|length)>0 or $recovery!="" then "WARNING" else $status end) as $effectiveStatus |
         {schema:1,name:"media_integrity_audit",status:$effectiveStatus,mode:$mode,epoch:$now,
          recoveryEnabled:$recoveryEnabled,recoveryActions:($actions|length),recoveryAttention:($recoveryAttention|length),
          recoveryAttentionKeys:[$recoveryAttention[]|.key+":"+.value.status+":"+.value.reason],
          stats:$r,activeFindings:($issues|length),recoveries:($fixed|length),
          findingKeys:[$issues[]|.value.issue.id+":"+.value.issue.kind+":"+(.value.issue.confirmed|tostring)],
          recoveryKeys:[$fixed[]|.id+":"+(.resolvedAt|tostring)],
          summary:("Media integrity audit: "+$effectiveStatus+"; quick="+(($r.quickPassed // 0)|tostring)+"; ranges="+(($r.segmentsPassed // 0)|tostring)+"; completed cycles="+(($r.cyclesCompleted // 0)|tostring)+"; findings="+($issues|length|tostring)),
          body:([
            "Media integrity audit: "+$effectiveStatus+"; mode="+$mode,
            "Scope: "+$root+"/{movies,series,formula1}; videos plus all their selected audio streams.",
            "Inventoried: "+(($r.inventoryFiles // 0)|tostring)+"; complete inventory: "+(($r.inventoryComplete // false)|tostring)+"; inventory errors: "+(($r.inventoryErrors // 0)|tostring),
            "This run: quick checks passed="+(($r.quickPassed // 0)|tostring)+"; decode ranges passed="+(($r.segmentsPassed // 0)|tostring)+"; complete planned-range cycles="+(($r.cyclesCompleted // 0)|tostring),
            "Pending initial/replacement coverage: "+([$files[]|select((.value.verifiedAt // 0)==0 and .value.cycleLane!="old")]|length|tostring)+"; pending periodic cycles: "+(($r.pendingPeriodic // 0)|tostring)+"; in-progress files: "+(($r.inProgress // 0)|tostring)+"; deferred files: "+(($r.deferredFiles // 0)|tostring)+"; active findings: "+($issues|length|tostring)+"; newly reported recoveries/removals: "+($fixed|length|tostring),
            "Elapsed: "+(($r.elapsedSeconds // 0)|tostring)+" seconds. Stop/defer reason: "+$reason,
            "Integrity scan: read-only inventory/probing/decoding with resumable progress. No Docker images/startup/configuration changed.",
            "Automatic Arr recovery: "+(if $recoveryEnabled then "ENABLED; bounded, preserved-original workflow" else "DISABLED; observation only; no media/Arr mutation" end)+". Journal actions: "+($actions|length|tostring)+"; recovery attention: "+($recoveryAttention|length|tostring),
            "Coverage: quick probes/sample ranges are not full verification. A completed cycle means all planned overlapping ranges decoded, not one linear decode or a known-good checksum. Pending files remain unverified.",
            (if $wall>0 and $media>0 then
              "Partial backlog estimate at observed decode rate: "+((($remaining*$wall/$media/3600)*10|round)/10|tostring)+" decoder hours for known pending durations. Unknown-duration files excluded: "+($unknown|tostring)+". Codecs, retries and workload deferrals can change this substantially."
             else "Decode throughput not established; no full-library completion estimate yet. Unknown-duration files: "+($unknown|tostring) end),
            "Retry/settle holds remain pending, not healthy; exact per-file progress and retry epochs are retained in compressed state.",
            "ISO/IMG not decoded: "+(($r.unsupportedImages // 0)|tostring)+"; symlinks skipped: "+(($r.symlinksSkipped // 0)|tostring),
            ""
          ] + (if $recovery!="" then ["State recovery: "+$recovery,""] else [] end) +
          ["", "Recovery journal (originals retained under /mnt/user/media/integrity_quarantine):"] +
          ([$actions[:$max][]|"- "+.value.app+" | "+.value.path+" | "+.value.status+"\n  Action/evidence: "+.value.reason+(if .value.status!="verified" and $now-.value.startedAt>$recoveryWait then " [Recovery deadline exceeded; operator review required; original/hold retained]" else "" end)+"\n  Arr parent/file IDs: "+(.value.parentId|tostring)+"/"+(.value.fileId|tostring)+"; targets: "+(.value.targets|tostring)+"; command: "+((.value.commandId // 0)|tostring)+"\n  Preserved path: integrity_quarantine/"+.key+"/"+(.value.path|split("/")|last)]) +
          ([$issues|sort_by((.value.issue.confirmed // false)|not)|.[:$max][]|
            "- "+.value.issue.kind+(if .value.issue.confirmed then " [repeatable decoder error; review required]" else " [unverified/read evidence; not confirmed corruption]" end)+"\n  File: "+.key+
            "\n  Finding ID: "+.value.issue.id+"; media offset: "+((.value.issue.offset // 0)|tostring)+"s; separate confirming runs: "+((.value.issue.confirmedRuns // 0)|tostring)+"\n  Evidence: "+(.value.issue.evidence|.[0:650])+
            "\n  Next action: "+(if .value.issue.kind=="decode_error" and .value.issue.confirmed then
              (if $recoveryEnabled then "Exact-ID recovery may qualify after two distinct audit runs; inspect the journal outcome below. Original is preserved before replacement." else "Recovery is disabled. Original retained; review repeated evidence during the observation period before enabling replacement." end)
              elif .value.issue.kind=="read_error" then "Investigate array/filesystem/drive I/O first. Read errors never authorize automatic replacement."
              elif (.value.issue.kind|test("timeout|resource|tool")) then "Review Bazarr decoder support, resource limits and workload. Coverage remains unverified; no replacement is authorized."
              else "Review this diagnostic and media access. This classification does not authorize automatic replacement." end)]) +
          (if ($issues|length)>$max then ["Additional active findings retained in compressed state: "+(($issues|length)-$max|tostring)] else [] end) +
          ["", "Recovered/removed since last delivered summary:"] +
          ([$fixed[:5][]|"- "+.path+": "+.resolution]) +
          (if ($fixed|length)>5 then ["Additional retained recovery records: "+(($fixed|length)-5|tostring)] else [] end) +
          ["", "Review: unsupported tools, resource/time limits, read errors and changing files never authorize automatic replacement. No quality/profile/global monitoring changes or automatic original purge. --recovery-status shows durable holds and request outcomes."] | join("\n"))}' >"$temp" || return 1
    # Clip only the optional tail at a byte limit; retain a valid UTF-8 body.
    body=$(jq -r .body "$temp" | head -c 23000 | iconv -f UTF-8 -t UTF-8 -c || true)
    if (( $(jq -r .body "$temp" | wc -c)>23000 )); then body+=$'\n[Email detail limit reached; individual findings retained in state.]';fi
    printf '%s\n' "$body" >"$STATE_DIR/latest-report.txt.new"
    mv -f "$STATE_DIR/latest-report.txt.new" "$STATE_DIR/latest-report.txt" || return 1
    [[ "$status" == OK || "$status" == INVENTORY_ONLY || "$status" == DEFERRED ]] || importance=warning
    # Success is recorded locally, never emailed. Progress counts do not change
    # an incident signature; unchanged unresolved evidence reminds weekly only.
    local attention=false
    if jq -e '.activeFindings>0 or .recoveryAttention>0 or .status=="FAILED" or .status=="WARNING"' "$temp" >/dev/null; then attention=true;fi
    [[ -z "$RECOVERY_NOTE" ]] || attention=true
    signature=$(jq -c '{status,activeFindings,findingKeys,recoveryAttentionKeys,reason:$reason,recoveryNote:$note}' \
      --arg reason "$( [[ "$status" != FAILED ]] || printf '%s' "$reason" )" --arg note "$RECOVERY_NOTE" "$temp" | sha256sum | awk '{print $1}')
    if [[ -f "$STATE_DIR/notified.json" ]]; then previous=$(jq -r '.signature // ""' "$STATE_DIR/notified.json");last=$(jq -r '.sentAt // 0' "$STATE_DIR/notified.json");fi
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [[ ( "$MODE" == scan || "$MODE" == recover ) && "$attention" == true && ( "$signature" != "$previous" || $((now-last)) -ge NOTIFICATION_REMINDER_SECONDS ) ]]; then
        importance=warning
        [[ "$status" != FAILED ]] || importance=alert
        jq -n --arg body "$body" --arg importance "$importance" --arg signature "$signature" --argjson epoch "$now" \
          '{schema:1,body:$body,importance:$importance,signature:$signature,epoch:$epoch}' >"$STATE_DIR/pending-notification.json.new" && mv "$STATE_DIR/pending-notification.json.new" "$STATE_DIR/pending-notification.json"
        if [[ -x "$NOTIFY_BIN" ]] && timeout 30 "$NOTIFY_BIN" -i "$importance" -s 'Media Integrity Audit' -d "$(jq -r .summary "$temp")" -m "$body"; then
            jq -n --arg signature "$signature" --argjson sentAt "$now" '{signature:$signature,sentAt:$sentAt}' >"$STATE_DIR/notified.json.new" && mv "$STATE_DIR/notified.json.new" "$STATE_DIR/notified.json"
            rm -f "$STATE_DIR/pending-notification.json"
            jq '.notification="sent"' "$temp" >"$temp.new" && mv "$temp.new" "$temp"
        else jq '.notification="failed"' "$temp" >"$temp.new" && mv "$temp.new" "$temp";log WARNING 'Notification failed; current grouped attention report remains pending';fi
    else
        # Do not send stale success/failure emails after the condition recovered.
        if [[ "$attention" == false && "$MODE" != inventory ]]; then rm -f -- "$STATE_DIR/pending-notification.json";fi
        if [[ -f "$STATE_DIR/pending-notification.json" ]]; then
            jq '.notification="failed"' "$temp" >"$temp.new" && mv "$temp.new" "$temp"
        else jq '.notification="suppressed"' "$temp" >"$temp.new" && mv "$temp.new" "$temp";fi
    fi
    local completed=0 installed="$now" first="$now"
    if [[ -f "$STATUS_DIR/media_integrity_audit.json" ]]; then
        completed=$(jq -r '.lastCompletedScanAt // 0' "$STATUS_DIR/media_integrity_audit.json")
        installed=$(jq -r '.installedAt // .epoch' "$STATUS_DIR/media_integrity_audit.json")
        first=$(jq -r '.firstScheduledAt // .epoch' "$STATUS_DIR/media_integrity_audit.json")
    fi
    if [[ "$MODE" == scan && "$WORKER_FINISHED" == true && "$status" != FAILED && "$status" != DEFERRED ]] && jq -e '.inventoryComplete==true' "$TMP_DIR/stats.json" >/dev/null; then completed="$now";fi
    jq --arg version "$SCRIPT_VERSION" --argjson completed "$completed" --argjson installed "$installed" --argjson first "$first" \
      '.+{scriptVersion:$version,lastCompletedScanAt:$completed,installedAt:$installed,firstScheduledAt:$first}' "$temp" >"$STATUS_DIR/.media-integrity-audit.new" && mv "$STATUS_DIR/.media-integrity-audit.new" "$STATUS_DIR/media_integrity_audit.json" || return 1
    RUN_REPORT_WRITTEN=true
    log INFO "$(jq -r .summary "$temp"); $reason"
    rm -f "$temp"
}

# Durable recovery journal is independent of rolling decoder checkpoints. It is
# also the hold consumed by delete-sync; never expire unresolved holds by age.
recovery_valid() {
    [[ ! -L "$RECOVERY_FILE" ]] || return 1
    [[ -f "$RECOVERY_FILE" ]] || return 0
    jq -e '.schema==1 and (.actions|type)=="object" and all(.actions|to_entries[];
      (.key|test("^[a-f0-9]{64}$")) and (.value.app=="Sonarr" or .value.app=="Radarr") and
      (.value.parentId|type)=="number" and .value.parentId>0 and
      (.value.fileId|type)=="number" and .value.fileId>0 and
      (.value.path|type)=="string" and (.value.path|test("(^/|(^|/)\\.\\.?(/|$))")|not) and
      (if .value.app=="Sonarr" then (.value.path|startswith("series/")) else (.value.path|startswith("movies/")) end) and
      (.value.identity|type)=="array" and (.value.identity|length)==5 and all(.value.identity[]; type=="string" and test("^[0-9]+$")) and
      (.value.targets|type)=="array" and (.value.targets|length)>0 and
      all(.value.targets[]; type=="number" and .>0) and
      (.value.status as $s | ["prepared","moved","delete_intent","deleted","monitor_intent","search_intent","search_submitted","replacement_detected","verified","review"]|index($s))!=null)' "$RECOVERY_FILE" >/dev/null
}
recovery_update() {
    local filter="$1" tmp fd; shift
    tmp=$(mktemp "$STATE_DIR/.recovery.XXXXXX") || return 1
    jq "$@" "$filter" "$RECOVERY_FILE" >"$tmp" && jq -e '.schema==1 and (.actions|type)=="object"' "$tmp" >/dev/null || { rm -f "$tmp"; return 1; }
    exec {fd}>"$STATE_EXPORT_LOCK" || return 1
    flock -s -w 5 "$fd" && sync -f "$tmp" && mv -f -- "$tmp" "$RECOVERY_FILE" && sync -f "$RECOVERY_FILE"
    local rc=$?; exec {fd}>&-; rm -f -- "$tmp"; return "$rc"
}
recovery_set() {
    local id="$1" status="$2" reason="$3"
    recovery_update '.actions[$id].status=$status | .actions[$id].reason=$reason | .actions[$id].updatedAt=$now' \
      --arg id "$id" --arg status "$status" --arg reason "$reason" --argjson now "$(date +%s)"
}
recovery_api() {
    local method="$1" endpoint="$2" output="$3" payload="${4:-}" rc=0 args=()
    RECOVERY_HTTP=000
    (( RECOVERY_DEADLINE==0 || $(date +%s)<RECOVERY_DEADLINE )) || return 124
    [[ "$method" != POST && "$method" != PUT ]] || args+=(--header 'Content-Type: application/json' --data-binary "@$payload")
    RECOVERY_HTTP=$(curl --silent --show-error --retry 0 --connect-timeout 4 --max-time 15 --max-filesize 67108864 \
      --request "$method" --header "X-Api-Key: $RECOVERY_KEY" --output "$output" --write-out '%{http_code}' \
      "${args[@]}" "$RECOVERY_ROOT$endpoint" 2>"$TMP_DIR/recovery-curl.error") || rc=$?
    (( rc==0 )) && [[ "$RECOVERY_HTTP" == 2?? || ( "$method" == GET && "$RECOVERY_HTTP" == 404 ) ]]
}
recovery_connection() {
    case "$1" in Sonarr) RECOVERY_ROOT="$SONARR_API_ROOT"; RECOVERY_KEY="$SONARR_API_KEY";; Radarr) RECOVERY_ROOT="$RADARR_API_ROOT"; RECOVERY_KEY="$RADARR_API_KEY";; *) return 1;; esac
    [[ -n "$RECOVERY_KEY" && "$RECOVERY_KEY" != PUT_YOUR_* && "$RECOVERY_ROOT" =~ ^https?://[^[:space:]]+/api/v(3|5)$ ]]
}
# This helper runs with the same UID/mount view as the decoder. It never copies,
# overwrites or follows source/quarantine symlinks. Prefer Linux renameat2;
# shfs fallback reserves a no-overwrite hard link before unlinking the source.
# Cross-device/unsupported preservation stops before any Arr deletion request.
recovery_file_tool() (
    [[ "$1" != identity ]] || exec </dev/null
    timeout 15 docker exec -i --user 99:100 "$BAZARR_CONTAINER" python3 -c '
import ctypes,errno,json,os,stat,sys
root,mode,rel,target=sys.argv[1:];root=os.path.realpath(root)
def safe(rel):
 if not rel or rel.startswith("/") or any(p in ("",".","..") for p in rel.split("/")):raise ValueError("unsafe relative path")
 path=os.path.join(root,rel)
 if os.path.realpath(path)!=path or os.path.commonpath((root,path))!=root:raise ValueError("path escape/symlink")
 return path
p=safe(rel)
def ident(p):
 s=os.stat(p,follow_symlinks=False)
 if not stat.S_ISREG(s.st_mode):raise ValueError("not regular media")
 return [str(x) for x in (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)]
if mode=="identity":print(json.dumps(ident(p)));sys.exit(0)
expected=json.loads(sys.stdin.read())
if ident(p)!=expected:raise ValueError("media identity changed before preservation")
d=safe(target);parent=os.path.dirname(d);os.makedirs(parent,mode=0o755,exist_ok=True)
if os.path.realpath(parent)!=parent:raise ValueError("quarantine parent changed")
lib=ctypes.CDLL(None,use_errno=True)
try:
 rename=lib.renameat2
 result=rename(-100,os.fsencode(p),-100,os.fsencode(d),1)
except AttributeError:
 # Alpine/musl may expose the kernel syscall without a libc wrapper.
 number={"x86_64":316,"aarch64":276,"arm64":276}.get(os.uname().machine)
 if number is None:raise OSError(errno.ENOSYS,"renameat2 unavailable on this architecture")
 lib.syscall.restype=ctypes.c_long
 result=lib.syscall(number,-100,os.fsencode(p),-100,os.fsencode(d),1)
if result!=0:
 e=ctypes.get_errno()
 if e not in (errno.EINVAL,errno.ENOSYS,errno.EOPNOTSUPP):raise OSError(e,os.strerror(e))
 # Unraid shfs may reject RENAME_NOREPLACE. A same-filesystem link reserves
 # the destination atomically without overwrite or payload copying. Verify
 # both names before unlinking the source; interruption keeps both copies.
 os.link(p,d,follow_symlinks=False)
 if ident(d)[:4]!=expected[:4] or ident(p)[:4]!=expected[:4]:
  raise ValueError("staged preservation identity differs; both names retained")
 os.unlink(p)
after=ident(d)
if after[:4]!=expected[:4]:raise ValueError("preserved identity differs; original retained, API mutation prohibited")
print(json.dumps(after))
' "$MEDIA_CONTAINER_ROOT" "$1" "$2" "${3:-}"
)
recovery_quiet_app() {
    local parent="$1" kind="$2" queue="$TMP_DIR/recovery-queue.json" commands="$TMP_DIR/recovery-commands.json" health="$TMP_DIR/recovery-health.json"
    recovery_api GET '/health' "$health" && [[ "$RECOVERY_HTTP" == 200 ]] && jq -e 'type=="array" and all(.[]; (.type // ""|ascii_downcase) as $level | ["notice","info"]|index($level)!=null)' "$health" >/dev/null || return 1
    recovery_api GET '/queue?page=1&pageSize=1000&includeUnknownSeriesItems=true&includeUnknownMovieItems=true' "$queue" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
    jq -e --arg field "$kind" --argjson parent "$parent" '
      (.records|type)=="array" and (.totalRecords|type)=="number" and .totalRecords==(.records|length)
      and all(.records[]; (.[$field] // 0)>0 and .[$field]!=$parent)' "$queue" >/dev/null || return 1
    recovery_api GET '/command' "$commands" && [[ "$RECOVERY_HTTP" == 200 ]] && jq -e 'type=="array" and all(.[]; ((.status // ""|ascii_downcase) as $s | ["completed","failed","cancelled","aborted"] | index($s))!=null)' "$commands" >/dev/null
}
recovery_capacity_ready() {
    local bytes="$1" available
    available=$(df -PB1 -- "$MEDIA_HOST_ROOT" | awk 'NR==2 {print $4}') || return 1
    [[ "$bytes" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]] && ((available>=bytes+10*1024*1024*1024))
}
recovery_platform_ready() {
    local version
    version=$(sed -n 's/^version="\([^"]*\)"/\1/p' /etc/unraid-version 2>/dev/null) || return 1
    [[ "$version" == 7.* ]]
}
recovery_plan() {
    local candidate="$1" output="$2" app relative expected catalog parent files targets file_id parent_id path
    relative=$(jq -r .key "$candidate"); expected="$TMP_DIR/recovery-expected.json"
    jq '.value.identity' "$candidate" >"$expected"
    recovery_capacity_ready "$(jq -r '.[2]' "$expected")" || return 1
    case "$relative" in movies/*) app=Radarr;; series/*) app=Sonarr;; *) return 1;; esac
    recovery_connection "$app" || return 1
    catalog="$TMP_DIR/recovery-catalog.json"; files="$TMP_DIR/recovery-files.json"; targets="$TMP_DIR/recovery-targets.json"
    if [[ "$app" == Sonarr ]]; then
        recovery_api GET /series "$catalog" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        path="$SONARR_MEDIA_ROOT/$relative"
        jq --arg path "$path" '[.[]|select(.monitored==true) | . as $parent | select($path|startswith($parent.path+"/"))]' "$catalog" >"$TMP_DIR/recovery-parent.json" || return 1
        [[ $(jq length "$TMP_DIR/recovery-parent.json") == 1 ]] || return 1
        parent_id=$(jq -r '.[0].id' "$TMP_DIR/recovery-parent.json")
        recovery_api GET "/episodefile?seriesId=$parent_id" "$files" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq --arg path "$path" '[.[]|select(.path==$path)]' "$files" >"$TMP_DIR/recovery-match.json" || return 1
        [[ $(jq length "$TMP_DIR/recovery-match.json") == 1 ]] || return 1
        file_id=$(jq -r '.[0].id' "$TMP_DIR/recovery-match.json")
        recovery_api GET "/episode?seriesId=$parent_id" "$targets" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq --argjson file "$file_id" --argjson parent "$parent_id" '[.[]|select(.episodeFileId==$file and .seriesId==$parent)]' "$targets" >"$TMP_DIR/recovery-linked.json" || return 1
        jq -e 'length>0 and all(.[]; .monitored==true and .hasFile==true and .id>0)' "$TMP_DIR/recovery-linked.json" >/dev/null || return 1
        jq -e --slurpfile parent "$TMP_DIR/recovery-parent.json" 'all(.[]; .seasonNumber as $n | any($parent[0][0].seasons[]; .seasonNumber==$n and .monitored==true))' "$TMP_DIR/recovery-linked.json" >/dev/null || return 1
        jq '[.[].id]|sort|unique' "$TMP_DIR/recovery-linked.json" >"$targets.ids"
    else
        recovery_api GET /movie "$catalog" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        path="$RADARR_MEDIA_ROOT/$relative"
        jq --arg path "$path" '[.[]|select(.monitored==true and .hasFile==true and .movieFile.path==$path and .movieFileId==.movieFile.id)]' "$catalog" >"$TMP_DIR/recovery-match.json" || return 1
        [[ $(jq length "$TMP_DIR/recovery-match.json") == 1 ]] || return 1
        parent_id=$(jq -r '.[0].id' "$TMP_DIR/recovery-match.json");file_id=$(jq -r '.[0].movieFileId' "$TMP_DIR/recovery-match.json")
        jq '[.[0].id]' "$TMP_DIR/recovery-match.json" >"$targets.ids"
    fi
    [[ "$file_id" =~ ^[1-9][0-9]*$ && "$parent_id" =~ ^[1-9][0-9]*$ ]] || return 1
    recovery_quiet_app "$parent_id" "$([[ "$app" == Sonarr ]] && printf seriesId || printf movieId)" || return 1
    recovery_file_tool identity "$relative" >"$TMP_DIR/recovery-identity.json" || return 1
    jq -e --slurpfile expected "$expected" '.==$expected[0]' "$TMP_DIR/recovery-identity.json" >/dev/null || return 1
    jq -n --arg app "$app" --arg path "$relative" --arg apiPath "$path" --argjson parent "$parent_id" --argjson file "$file_id" \
      --slurpfile candidate "$candidate" --slurpfile ids "$targets.ids" --argjson now "$(date +%s)" \
      '{app:$app,path:$path,apiPath:$apiPath,parentId:$parent,fileId:$file,targets:$ids[0],identity:$candidate[0].value.identity,
        finding:$candidate[0].value.issue,status:"prepared",startedAt:$now,updatedAt:$now,reason:"Exact monitored Arr file/targets and unchanged decoder identity verified"}' >"$output"
}
# Restore a target's pre-recovery monitored=true only when native unmonitor-on-
# delete is enabled AND our own deletion was just sent. A later/user change or
# uncertain PUT is never force-replayed. Global settings remain untouched.
recovery_monitoring_ready() {
    local id="$1" job="$2" app="$3" parent="$4" status="$5" target kind refs="$TMP_DIR/recovery-monitor-target.json"
    local all_monitored=true delete_at now payload="$TMP_DIR/recovery-monitor-payload.json" cfg="$TMP_DIR/recovery-monitor-config.json" cfg_path field parent_file="$TMP_DIR/recovery-monitor-parent.json"
    kind=$([[ "$app" == Sonarr ]] && printf episode || printf movie)
    while read -r target; do
        recovery_api GET "/$kind/$target" "$refs" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq -e --argjson id "$target" --argjson parent "$parent" --arg app "$app" '.id==$id and .hasFile==false and (if $app=="Sonarr" then .seriesId==$parent and (.episodeFileId // 0)==0 else .id==$parent and (.movieFileId // 0)==0 end)' "$refs" >/dev/null || { recovery_set "$id" review 'Exact target/file ownership changed; monitoring/search not forced; original retained';return 1; }
        jq -e '.monitored==true' "$refs" >/dev/null || all_monitored=false
    done < <(jq -r '.targets[]' "$job")
    if [[ "$all_monitored" == true ]]; then
        [[ "$status" != monitor_intent ]] || recovery_set "$id" deleted 'Previous monitoring restoration verified against all exact IDs; no PUT replayed'
        return 0
    fi
    if [[ "$status" == monitor_intent ]]; then recovery_set "$id" review 'Monitoring PUT outcome uncertain and requested state not present; no replay. Original retained; review exact targets';return 1;fi
    delete_at=$(jq -r --arg id "$id" '.actions[$id].deleteSentAt // 0' "$RECOVERY_FILE");now=$(date +%s)
    ((delete_at>0 && now>=delete_at && now-delete_at<=120)) || { recovery_set "$id" review 'Monitoring is now off outside the immediate native-deletion transition. User/native intent is uncertain; no monitoring override or search';return 1; }
    cfg_path=/config/mediamanagement
    [[ "$RECOVERY_ROOT" != */v5 ]] || cfg_path=/settings/mediamanagement
    field=$([[ "$app" == Sonarr ]] && printf autoUnmonitorPreviouslyDownloadedEpisodes || printf autoUnmonitorPreviouslyDownloadedMovies)
    recovery_api GET "$cfg_path" "$cfg" && [[ "$RECOVERY_HTTP" == 200 ]] && jq -e --arg field "$field" '.[$field]==true' "$cfg" >/dev/null || { recovery_set "$id" review 'Monitoring changed without verified native unmonitor-on-delete behavior; no override';return 1; }
    if [[ "$app" == Sonarr ]]; then
        recovery_api GET "/series/$parent" "$parent_file" && [[ "$RECOVERY_HTTP" == 200 ]] && jq -e --argjson id "$parent" '.id==$id and .monitored==true' "$parent_file" >/dev/null || return 1
        jq '{episodeIds:.targets,monitored:true}' "$job" >"$payload" || return 1
        cfg_path=/episode/monitor
    else
        jq '.monitored=true' "$refs" >"$payload" || return 1
        cfg_path="/movie/$parent"
    fi
    recovery_set "$id" monitor_intent 'Restoring only previously monitored exact recovery targets after our own verified file removal; global settings unchanged' || return 1
    recovery_api PUT "$cfg_path" "$TMP_DIR/recovery-monitor-response.json" "$payload" || return 1
    local attempt
    for attempt in 1 2 3; do
        all_monitored=true
        while read -r target; do
            recovery_api GET "/$kind/$target" "$refs" && [[ "$RECOVERY_HTTP" == 200 ]] && jq -e --argjson id "$target" '.id==$id and .monitored==true' "$refs" >/dev/null || all_monitored=false
        done < <(jq -r '.targets[]' "$job")
        [[ "$all_monitored" != true ]] || { recovery_set "$id" deleted 'Pre-recovery monitored state restored and verified for exact target IDs; global settings unchanged';return 0; }
        ((attempt>=3)) || sleep 1
    done
    return 1
}

recovery_resume() {
    local id="$1" job="$TMP_DIR/recovery-job.json" status app parent endpoint source file response command name field current new_path verified now
    jq --arg id "$id" '.actions[$id]' "$RECOVERY_FILE" >"$job" || return 1
    local expected_id
    expected_id=$(jq -c '[.path,.identity]' "$job" | sha256sum | awk '{print $1}')
    [[ "$expected_id" == "$id" ]] || { RECOVERY_NOTE='Recovery journal identity checksum mismatch; no mutation submitted';return 1; }
    status=$(jq -r .status "$job");app=$(jq -r .app "$job");parent=$(jq -r .parentId "$job");source=$(jq -r .path "$job");file=$(jq -r .fileId "$job")
    case "$status" in verified) return 0;; esac
    recovery_connection "$app" || { recovery_set "$id" review 'Arr credentials/API root unavailable; original preserved';return 1; }
    if [[ "$app" == Sonarr ]]; then endpoint=episodefile;name=EpisodeSearch;field=episodeIds;else endpoint=moviefile;name=MoviesSearch;field=movieIds;fi
    response="$TMP_DIR/recovery-response.json"
    # Completion requires the new exact Arr file path to pass a later full audit
    # cycle. An accepted search, new filename or successful import is not enough.
    if [[ "$status" == search_submitted || "$status" == replacement_detected || "$status" == review ]]; then
        local target kind refs="$TMP_DIR/recovery-followup.json" valid=true paths="$TMP_DIR/recovery-followup-paths.jsonl"
        local command_id
        command_id=$(jq -r '.commandId // 0' "$job")
        if [[ "$status" != review && "$command_id" =~ ^[1-9][0-9]*$ ]] && recovery_api GET "/command/$command_id" "$refs" && [[ "$RECOVERY_HTTP" == 200 ]]; then
            if jq -e '(.status // ""|ascii_downcase)=="failed"' "$refs" >/dev/null; then recovery_set "$id" review 'Arr reported that the targeted search failed; original retained; no automatic repeat request';return 1;fi
        fi
        : >"$paths"
        while read -r target; do
            kind=$([[ "$app" == Sonarr ]] && printf episode || printf movie)
            recovery_api GET "/$kind/$target" "$refs" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
            # Sonarr uses episodeFileId; Radarr uses movieFileId (camel case).
            jq -e --argjson target "$target" --argjson parent "$parent" --arg app "$app" '.id==$target and (if $app=="Sonarr" then .seriesId==$parent else .id==$parent end)' "$refs" >/dev/null || { valid=false;break; }
            current=$(jq -r --arg app "$app" 'if $app=="Sonarr" then .episodeFileId // 0 else .movieFileId // 0 end' "$refs")
            if ! [[ "$current" =~ ^[1-9][0-9]*$ ]] || [[ "$current" == "$file" && "$status" != review ]]; then valid=false;break;fi
            recovery_api GET "/$endpoint/$current" "$refs" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
            jq -e --argjson file "$current" --argjson parent "$parent" --arg app "$app" '.id==$file and (if $app=="Sonarr" then .seriesId==$parent else .movieId==$parent end)' "$refs" >/dev/null || { valid=false;break; }
            local added
            added=$(date -d "$(jq -r '.dateAdded // ""' "$refs")" +%s 2>/dev/null) || added=0
            [[ "$status" == review && "$current" == "$file" ]] || ((added>=$(jq -r .startedAt "$job"))) || { valid=false;break; }
            new_path=$(jq -r .path "$refs");local root;root=$([[ "$app" == Sonarr ]] && printf '%s' "$SONARR_MEDIA_ROOT" || printf '%s' "$RADARR_MEDIA_ROOT")
            [[ "$new_path" == "$root/"* ]] || { valid=false;break; };new_path=${new_path#"$root/"}
            jq -cn --arg path "$new_path" '{path:$path}' >>"$paths"
            recovery_file_tool identity "$new_path" >"$TMP_DIR/recovery-new-identity.json" || { valid=false;break; }
            [[ "$status" == review && "$current" == "$file" ]] || jq -e --slurpfile job "$job" '.[0:4]!=$job[0].identity[0:4]' "$TMP_DIR/recovery-new-identity.json" >/dev/null || { valid=false;break; }
            jq -e --arg path "$new_path" --slurpfile identity "$TMP_DIR/recovery-new-identity.json" --slurpfile job "$job" '
              .files[$path] as $f | $f!=null and $f.identity==$identity[0] and $f.issue==null and ($f.verifiedAt // 0)>=$job[0].startedAt' "$TMP_DIR/state.json" >/dev/null || valid=false
        done < <(jq -r '.targets[]' "$job")
        recovery_update ' .actions[$id].replacementPaths=[$paths[].path] | .actions[$id].updatedAt=$now ' --arg id "$id" --argjson now "$(date +%s)" --slurpfile paths "$paths" || return 1
        if [[ "$valid" == true ]]; then recovery_set "$id" verified 'Exact current Arr file(s) passed a complete later planned-range audit cycle; recovery hold released. Any preserved original remains retained for operator review';return 0;fi
        now=$(date +%s)
        if [[ "$status" != review ]] && ((now-$(jq -r .startedAt "$job")>=RECOVERY_WAIT_DAYS*86400)); then recovery_set "$id" review 'Replacement has not passed full audit verification before the recovery deadline. Original retained; deletion-sync hold remains active; no further download requested';fi
        return 0
    fi
    recovery_window_open || return 0
    if [[ "$status" == prepared ]]; then
        workload_guard || return 0
        local preserved="$MEDIA_HOST_ROOT/integrity_quarantine/$id/${source##*/}"
        if [[ -e "$preserved" || -L "$preserved" ]]; then
            if [[ -e "$MEDIA_HOST_ROOT/$source" || -L "$MEDIA_HOST_ROOT/$source" ]]; then
                recovery_set "$id" review 'Interrupted preservation has both source and destination names. Both retained; no Arr deletion/search or automatic overwrite/unlink';return 1
            fi
            recovery_file_tool identity "integrity_quarantine/$id/${source##*/}" >"$TMP_DIR/recovered-preservation.json" &&
              jq -e --slurpfile job "$job" '.[0:4]==$job[0].identity[0:4]' "$TMP_DIR/recovered-preservation.json" >/dev/null || { recovery_set "$id" review 'Interrupted preservation identity unverified; retained without API mutation';return 1; }
            recovery_set "$id" moved 'Interrupted preservation verified: exact original at owned destination and source absent; no move replayed' || return 1
            status=moved
        fi
    fi
    if [[ "$status" == prepared ]]; then
        local fresh="$TMP_DIR/recovery-fresh-plan.json" candidate="$TMP_DIR/recovery-fresh-candidate.json"
        jq '{key:.path,value:{identity,issue:.finding}}' "$job" >"$candidate" || return 1
        recovery_plan "$candidate" "$fresh" || return 1
        jq -e --slurpfile job "$job" '{app,path,apiPath,parentId,fileId,targets,identity}==($job[0]|{app,path,apiPath,parentId,fileId,targets,identity})' "$fresh" >/dev/null || { recovery_set "$id" review 'Current exact ownership/monitoring no longer matches the prepared plan; nothing moved or deleted';return 1; }
        recovery_quiet_app "$parent" "$([[ "$app" == Sonarr ]] && printf seriesId || printf movieId)" || return 0
        # Revalidate exact resource immediately before any filesystem operation.
        recovery_api GET "/$endpoint/$file" "$response" && [[ "$RECOVERY_HTTP" == 200 ]] && jq -e --slurpfile job "$job" '.id==$job[0].fileId and .path==$job[0].apiPath' "$response" >/dev/null || return 1
        recovery_window_open || return 0
        jq '.identity' "$job" | recovery_file_tool move "$source" "integrity_quarantine/$id/${source##*/}" >"$TMP_DIR/preserved-identity.json" || { recovery_set "$id" review 'Preservation failed or changed identity; no Arr deletion/search submitted. Inspect source and owned quarantine path';return 1; }
        recovery_set "$id" moved 'Damaged original preserved without copying/overwriting; Arr record update pending' || return 1
        status=moved
    fi
    if [[ "$status" == moved || "$status" == delete_intent ]]; then
        [[ ! -e "$MEDIA_HOST_ROOT/$source" && ! -L "$MEDIA_HOST_ROOT/$source" ]] || { recovery_set "$id" review 'A source file returned; refusing to delete any Arr file record. Preserved copy retained';return 1; }
        recovery_file_tool identity "integrity_quarantine/$id/${source##*/}" >"$TMP_DIR/preserved-check.json" || return 1
        jq -e --slurpfile job "$job" '.[0:4]==$job[0].identity[0:4]' "$TMP_DIR/preserved-check.json" >/dev/null || return 1
        recovery_api GET "/$endpoint/$file" "$response" || return 1
        if [[ "$RECOVERY_HTTP" != 404 ]]; then
            [[ "$status" != delete_intent ]] || { recovery_set "$id" review 'Prior file-record deletion outcome uncertain; current record still exists. Mutation not replayed; original retained';return 1; }
            jq -e --slurpfile job "$job" '.id==$job[0].fileId and .path==$job[0].apiPath' "$response" >/dev/null || return 1
            recovery_set "$id" delete_intent 'Exact file-record deletion intent durable; no blind replay after interruption' || return 1
            recovery_update '.actions[$id].deleteSentAt=$now' --arg id "$id" --argjson now "$(date +%s)" || return 1
            recovery_window_open || return 0
            [[ ! -e "$MEDIA_HOST_ROOT/$source" && ! -L "$MEDIA_HOST_ROOT/$source" ]] || { recovery_set "$id" review 'Source file reappeared immediately before deletion; no DELETE sent; preserved original retained';return 1; }
            recovery_api DELETE "/$endpoint/$file" "$response" || return 1
            recovery_api GET "/$endpoint/$file" "$response" && [[ "$RECOVERY_HTTP" == 404 ]] || return 1
        fi
        recovery_set "$id" deleted 'Original preserved and old Arr file record confirmed absent' || return 1
        status=deleted
    fi
    if [[ "$status" == deleted || "$status" == monitor_intent ]]; then
        local target kind refs="$TMP_DIR/recovery-search-target.json"
        recovery_quiet_app "$parent" "$([[ "$app" == Sonarr ]] && printf seriesId || printf movieId)" || return 0
        recovery_monitoring_ready "$id" "$job" "$app" "$parent" "$status" || return 1
        command="$TMP_DIR/recovery-command.json"
        jq --arg name "$name" --arg field "$field" '{name:$name,($field):.targets}' "$job" >"$command" || return 1
        recovery_window_open || return 0
        recovery_set "$id" search_intent 'Targeted search intent durable; request will be sent once only' || return 1
        recovery_api POST /command "$response" "$command" && [[ "$RECOVERY_HTTP" == 2?? ]] || return 1
        current=$(jq -r '.id // 0' "$response");[[ "$current" =~ ^[1-9][0-9]*$ ]] || return 1
        recovery_update '.actions[$id].commandId=$command' --arg id "$id" --argjson command "$current" || return 1
        status=search_intent
    fi
    if [[ "$status" == search_intent ]]; then
        current=$(jq -r --arg id "$id" '.actions[$id].commandId // 0' "$RECOVERY_FILE")
        [[ "$current" =~ ^[1-9][0-9]*$ ]] || { recovery_set "$id" review 'Search response was lost/invalid; request is not replayed. Inspect Arr command history; original retained';return 1; }
        recovery_api GET "/command/$current" "$response" && [[ "$RECOVERY_HTTP" == 200 ]] &&
          jq -e --argjson id "$current" --arg name "$name" --arg field "$field" --slurpfile job "$job" '
            .id==$id and (.name // .body.name)==$name and ((.body[$field] // .[$field])|sort)==($job[0].targets|sort)
            and ((.status|ascii_downcase) as $s | ["queued","pending","started","completed"]|index($s)!=null)' "$response" >/dev/null || return 1
        recovery_set "$id" search_submitted 'One exact-target search accepted and read back; awaiting replacement import and complete decode verification. Original retained; quality/profile policy unchanged'
    fi
}
recovery_runtime_matches() {
    local current
    current=$(timeout 12 docker exec --user 99:100 "$BAZARR_CONTAINER" sh -c 'ffmpeg -version | sed -n "1p"; ffprobe -version | sed -n "1p"') || return 1
    jq -e --arg toolset "$current" '.toolset==$toolset' "$TMP_DIR/state.json" >/dev/null
}

recovery_process() {
    [[ "$AUTO_RECOVERY_ENABLED" == true ]] || return 0
    recovery_platform_ready || { RECOVERY_NOTE='Recovery platform unverified; mutations require validated Unraid 7.x. Existing originals and holds remain protected.';return 1; }
    RECOVERY_DEADLINE=$(( $(date +%s)+RECOVERY_MAX_SECONDS ))
    recovery_valid || { RECOVERY_NOTE='Invalid recovery journal; recovery disabled for this invocation; unresolved holds preserved';return 1; }
    if [[ ! -f "$RECOVERY_FILE" ]]; then
        printf '{"schema":1,"actions":{}}\n' >"$STATE_DIR/.recovery-initial.$$" && sync -f "$STATE_DIR/.recovery-initial.$$" && mv "$STATE_DIR/.recovery-initial.$$" "$RECOVERY_FILE" && sync -f "$RECOVERY_FILE" || return 1
    fi
    local row examined=0 id candidate="$TMP_DIR/recovery-candidate.json" plan="$TMP_DIR/recovery-plan.json" now count=0 rc=0 fd hold
    exec {fd}>"$ARR_BACKUP_GATE" || return 1;flock -s -n "$fd" || { exec {fd}>&-;return 0; }
    exec {hold}>/tmp/arr_metadata_quarantine.lock || { exec {fd}>&-;return 1; };flock -n "$hold" || { exec {fd}>&-;exec {hold}>&-;return 0; }
    # Resume at most four journal entries per invocation. Never lose the original
    # hold when a command, API or process fails.
    while read -r id; do (( $(date +%s)<RECOVERY_DEADLINE )) || break;recovery_resume "$id" || rc=1;done < <(jq -r '.actions|to_entries|sort_by(.value.updatedAt)|.[]|select(.value.status!="verified")|.key' "$RECOVERY_FILE" | sed -n '1,4p')
    now=$(date +%s)
    if ! recovery_window_open; then exec {hold}>&-; exec {fd}>&-; return "$rc"; fi
    jq -c --argjson cutoff "$((now-48*3600))" '.files|to_entries[]|select((.value.issue.lastSeen // 0)>=$cutoff and .value.issue.kind=="decode_error" and .value.issue.confirmed==true and (.value.issue.confirmedRuns // 0)>=2 and .value.issue.identity==.value.identity and (.value.replacementPending // false)==false)' "$TMP_DIR/state.json" >"$TMP_DIR/recovery-candidates.jsonl" || { exec {hold}>&-;exec {fd}>&-;return 1; }
    if [[ ! -s "$TMP_DIR/recovery-candidates.jsonl" ]]; then exec {hold}>&-;exec {fd}>&-;return "$rc";fi
    if ! recovery_runtime_matches; then RECOVERY_NOTE='Decoder runtime differs from saved evidence or is unavailable; no new recovery started. A fresh audit must reconfirm the error under the current tools.';exec {hold}>&-;exec {fd}>&-;return 1;fi
    while IFS= read -r row; do
        ((count<RECOVERY_MAX_NEW_PER_RUN && examined<4 && $(date +%s)<RECOVERY_DEADLINE)) || break
        recovery_new_window_open || break
        examined=$((examined+1))
        jq -e --argjson cutoff "$((now-7*86400))" --argjson limit "$RECOVERY_MAX_NEW_PER_WEEK" '[.actions[]|select(.startedAt>=$cutoff)]|length<$limit' "$RECOVERY_FILE" >/dev/null || break
        printf '%s\n' "$row" >"$candidate"
        id=$(jq -c '[.key,.value.identity]' "$candidate" | sha256sum | awk '{print $1}')
        jq -e --arg id "$id" '.actions[$id]!=null' "$RECOVERY_FILE" >/dev/null && continue
        if ! recovery_plan "$candidate" "$plan"; then
            RECOVERY_NOTE="Recovery candidate remains unverified/ineligible: $(jq -r .key "$candidate"). No mutation for this candidate. Review exact Arr ownership/monitoring, health/queue/commands, free space and current file identity."
            continue
        fi
        # One attempt per exact parent/target set in 30 days; never churn a bad
        # source, lower a profile, blocklist by title, or run a library-wide search.
        jq -e --slurpfile plan "$plan" --argjson cutoff "$((now-30*86400))" 'all(.actions[]; .app!=$plan[0].app or .parentId!=$plan[0].parentId or (.targets|sort)!=($plan[0].targets|sort) or .startedAt<$cutoff)' "$RECOVERY_FILE" >/dev/null || continue
        recovery_update '.actions[$id]=$plan[0]' --arg id "$id" --slurpfile plan "$plan" || { rc=1;break; }
        count=$((count+1));recovery_resume "$id" || rc=1
    done <"$TMP_DIR/recovery-candidates.jsonl"
    exec {hold}>&-;exec {fd}>&-
    return "$rc"
}

worker_program() {
    cat <<'PYWORKER'
"""Read-only worker executed in Bazarr; stdout is a private checkpoint protocol."""
import base64, collections, errno, gzip, hashlib, json, math, os, re, resource
import selectors, signal, stat, subprocess, sys, time

SCHEMA=1
EXTENSIONS={'.mkv','.mp4','.m4v','.avi','.mov','.ts','.m2ts','.mts','.mpg','.mpeg','.webm','.wmv','.flv','.vob','.ogv','.3gp'}
STOP=''
ACTIVE=None

def identity(s):
    # jq bridges host/worker JSON. Nanosecond timestamps and 64-bit inodes
    # exceed IEEE-754's exact integer range, so identities travel as strings.
    return [str(v) for v in (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)]

def emit(event):
    sys.stdout.write(json.dumps(event,separators=(',',':'))+'\n');sys.stdout.flush()

def stop_handler(signum,frame):
    global STOP
    STOP='termination requested'

def kill_child(proc):
    if proc is None or proc.poll() is not None:return
    try:os.killpg(proc.pid,signal.SIGTERM)
    except ProcessLookupError:return
    try:proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:os.killpg(proc.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        proc.wait(timeout=2)

def run_process(args,fd,seconds,beat,memory_mib):
    global ACTIVE
    def limits():
        resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        memory=int(memory_mib)*1024*1024
        resource.setrlimit(resource.RLIMIT_AS,(memory,memory))
    started=time.monotonic(); buffers={'out':b'','err':b''}; stopped=''
    try:
        ACTIVE=subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                                pass_fds=(fd,),start_new_session=True,preexec_fn=limits)
        with selectors.DefaultSelector() as selector:
            selector.register(ACTIVE.stdout,selectors.EVENT_READ,'out');selector.register(ACTIVE.stderr,selectors.EVENT_READ,'err')
            while selector.get_map() or ACTIVE.poll() is None:
                beat()
                if STOP or time.monotonic()-started>=seconds:
                    stopped='cancelled' if STOP else 'timeout';kill_child(ACTIVE)
                for key,_ in selector.select(0.5):
                    data=os.read(key.fileobj.fileno(),65536)
                    if not data:selector.unregister(key.fileobj);continue
                    buffers[key.data]=(buffers[key.data]+data)[-262144:]
                if stopped and ACTIVE.poll() is not None and not selector.get_map():break
        code=ACTIVE.wait(timeout=2)
        return {'code':code,'out':buffers['out'].decode(errors='replace'),'err':buffers['err'].decode(errors='replace'),
                'stop':stopped,'wall':time.monotonic()-started}
    finally:
        kill_child(ACTIVE)
        if ACTIVE:
            for pipe in (ACTIVE.stdout,ACTIVE.stderr):
                if pipe:pipe.close()
        ACTIVE=None

def classify(result):
    if result['stop']:return result['stop']
    text=result['err'].lower()
    if re.search(r'cannot allocate memory|out of memory|resource temporarily unavailable|pthread_create|permission denied|operation not permitted|decoder .*not found|unknown decoder|unsupported codec|not implemented',text):
        return 'unverified_tool_or_resource'
    if 'input/output error' in text:return 'read_error'
    if re.search(r'invalid data|error (while|during) decoding|corrupt|truncat|invalid nal|moov atom not found|ebml header parsing failed|file ended prematurely|error submitting packet|error splitting',text):
        return 'decode_error'
    return 'passed' if result['code']==0 else 'unverified_tool_error'

def validate_state(state,cfg):
    if not isinstance(state,dict) or state.get('schema')!=SCHEMA or not isinstance(state.get('files'),dict):raise ValueError('unsupported state schema')
    if state.get('hostRoot',cfg['hostRoot'])!=cfg['hostRoot'] or state.get('libraries',cfg['libraries'])!=cfg['libraries']:
        raise ValueError('state source/scope differs; explicit review required')
    for path,entry in state['files'].items():
        if (not isinstance(path,str) or path.startswith('/') or os.path.normpath(path)!=path or path.split('/')[0] not in cfg['libraries']
                or not isinstance(entry,dict) or not isinstance(entry.get('identity'),list) or len(entry['identity'])!=5):
            raise ValueError('invalid state file identity/path')
        for field in ('offset','verifiedAt','probeAt','notBefore','chunkSeconds'):
            value=entry.get(field,0)
            if not isinstance(value,(int,float)) or not math.isfinite(value) or value<0:raise ValueError('invalid numeric progress')
    return state

class Audit:
    def __init__(self,cfg,state):
        self.cfg=cfg;self.state=validate_state(state,cfg);self.start=time.monotonic();self.deadline=self.start+cfg['budgetSeconds']
        self.runEpoch=int(time.time());self.last_heartbeat=0;self.last_checkpoint=0;self.dirty=True
        self.state.update(hostRoot=cfg['hostRoot'],libraries=cfg['libraries'])
        self.state.setdefault('resolved',[]);self.state.setdefault('runs',[])
        if self.state.get('toolset') and self.state['toolset']!=cfg['toolset']:
            for entry in self.state['files'].values():
                if entry.get('issue'):
                    entry['notBefore']=0;entry['probeAt']=0;entry['issue']['confirmedRuns']=0;entry['issue']['confirmed']=False;entry['issue']['lastConfirmedRunAt']=0
        self.stats={'startedAt':int(time.time()),'inventoryComplete':False,'inventoryFiles':0,'inventoryErrors':0,'symlinksSkipped':0,
                    'unsupportedImages':0,'newChanged':0,'quickPassed':0,'segmentsPassed':0,'cyclesCompleted':0,
                    'decodeWallSeconds':0.0,'mediaSecondsDecoded':0.0,'reason':'','mode':cfg['mode']}
        self.found=set();self.seen=set()
    def beat(self):
        if time.monotonic()-self.last_heartbeat>=10:
            emit({'type':'heartbeat','elapsed':int(time.monotonic()-self.start)})
            self.last_heartbeat=time.monotonic()
    def remaining(self):return max(0,self.deadline-time.monotonic())
    def stopped(self):return bool(STOP) or self.remaining()<3
    def checkpoint(self,force=False):
        if not force and (not self.dirty or time.monotonic()-self.last_checkpoint<60):return
        self.state['lastRun']=dict(self.stats,elapsedSeconds=int(time.monotonic()-self.start))
        raw=json.dumps(self.state,separators=(',',':')).encode()
        if len(raw)>self.cfg['maxStateBytes']:raise ValueError('state exceeds configured byte limit; previous checkpoint retained')
        payload=base64.b64encode(gzip.compress(raw,compresslevel=3,mtime=0)).decode()
        if len(payload)<=131072:
            emit({'type':'checkpoint','payload':payload,'stats':self.state['lastRun']})
        else:
            # Keep every protocol line bounded: Bash never needs to hold a
            # multi-megabyte state snapshot or pass it as an executable argument.
            emit({'type':'checkpoint-begin','length':len(payload)})
            for offset in range(0,len(payload),65536):
                emit({'type':'checkpoint-chunk','data':payload[offset:offset+65536]})
            emit({'type':'checkpoint-end','stats':self.state['lastRun']})
        self.last_checkpoint=time.monotonic();self.dirty=False
    def issue(self,path,entry,kind,evidence,offset=None,confirmed=False):
        old=entry.get('issue') or {};now=int(time.time())
        same=old.get('identity')==entry['identity'] and old.get('kind')==kind and old.get('confirmed')
        runs=(old.get('confirmedRuns',1) if same else 0)
        if confirmed and (not same or old.get('lastConfirmedRunAt')!=self.runEpoch):runs+=1
        entry['issue']={'id':hashlib.sha256(path.encode(errors='surrogateescape')).hexdigest()[:16],
                        'kind':kind,'firstSeen':old.get('firstSeen',now),'lastSeen':now,'confirmed':confirmed,
                        'confirmedRuns':runs if confirmed else 0,'lastConfirmedRunAt':self.runEpoch if confirmed else 0,
                        'offset':offset,'evidence':evidence[-3000:],'identity':entry['identity'],'cleanRechecks':0}
        entry['notBefore']=now+(7*86400 if kind in ('decode_error','read_error','intermittent_error') else 86400)
        self.dirty=True
    def resolve(self,path,entry,reason):
        if entry.get('issue'):
            self.state['resolved'].append(dict(entry.pop('issue'),path=path,resolvedAt=int(time.time()),resolution=reason))
            self.dirty=True
    def inventory(self):
        root=self.cfg['root'];complete=True
        for library in self.cfg['libraries']:
            library_path=os.path.join(root,library)
            if not os.path.isdir(library_path) or os.path.islink(library_path):
                self.stats['inventoryErrors']+=1;complete=False;continue
            stack=[library_path]
            while stack:
                self.beat()
                if self.stopped():complete=False;break
                directory=stack.pop()
                try:
                    with os.scandir(directory) as entries:
                        for item in entries:
                            self.beat()
                            if self.stopped():complete=False;break
                            if item.is_symlink():self.stats['symlinksSkipped']+=1;continue
                            if item.is_dir(follow_symlinks=False):stack.append(item.path);continue
                            if not item.is_file(follow_symlinks=False):continue
                            ext=os.path.splitext(item.name)[1].lower()
                            if ext in ('.iso','.img'):self.stats['unsupportedImages']+=1
                            if ext not in EXTENSIONS:continue
                            rel=os.path.relpath(item.path,root);self.seen.add(rel)
                            current=identity(item.stat(follow_symlinks=False));self.found.add(rel)
                            old=self.state['files'].get(rel)
                            if old is None or old['identity']!=current:
                                entry={'identity':current,'probeAt':0,'verifiedAt':0,'offset':0,'chunkSeconds':self.cfg['segmentSeconds'],
                                       'lastAttemptAt':0,'notBefore':0,'cycleLane':'new'}
                                if old and old.get('issue'):entry['issue']=old['issue'];entry['replacementPending']=True
                                self.state['files'][rel]=entry;self.stats['newChanged']+=1;self.dirty=True
                            if len(self.state['files'])>200000:raise ValueError('inventory exceeds 200000 files; explicit scope review required')
                except OSError:
                    self.stats['inventoryErrors']+=1;complete=False
            if self.stopped():break
        self.stats['inventoryFiles']=len(self.found);self.stats['inventoryComplete']=complete
        if complete:
            for path in list(self.state['files']):
                if path not in self.seen:
                    self.resolve(path,self.state['files'][path],'File no longer in a complete library inventory; no repair was performed')
                    del self.state['files'][path];self.dirty=True
        self.checkpoint(True)
    def open_file(self,path,entry):
        full=os.path.join(self.cfg['root'],path)
        if os.path.commonpath((self.cfg['root'],os.path.realpath(full)))!=self.cfg['root']:raise ValueError('source root escape')
        fd=os.open(full,os.O_RDONLY|os.O_NOFOLLOW)
        if not stat.S_ISREG(os.fstat(fd).st_mode) or identity(os.fstat(fd))!=entry['identity']:
            os.close(fd);raise FileNotFoundError('file identity changed')
        return fd
    def unchanged(self,path,entry,fd):
        try:
            return identity(os.fstat(fd))==entry['identity'] and identity(os.stat(os.path.join(self.cfg['root'],path),follow_symlinks=False))==entry['identity']
        except OSError:return False
    def run_tool(self,args,fd,seconds):
        if self.stopped():return {'code':-1,'out':'','err':'','stop':'cancelled','wall':0}
        return run_process(args,fd,min(seconds,max(1,self.remaining()-2)),self.beat,self.cfg['memoryMiB'])
    def probe(self,path,entry,fd):
        args=['ffprobe','-v','error','-protocol_whitelist','file','-show_entries',
              'format=duration:stream=index,codec_type,codec_name,duration:stream_disposition=attached_pic','-of','json',f'/proc/self/fd/{fd}']
        result=self.run_tool(args,fd,20);kind=classify(result)
        if not self.unchanged(path,entry,fd):
            entry['notBefore']=int(time.time())+300;return False
        if kind=='decode_error' and self.remaining()>25:
            again=self.run_tool(args,fd,20)
            if not self.unchanged(path,entry,fd):
                entry['notBefore']=int(time.time())+300;return False
            confirmed=classify(again)=='decode_error'
            if classify(again) in ('cancelled','timeout'):return False
            self.issue(path,entry,'decode_error' if confirmed else 'intermittent_error',result['err'],confirmed=confirmed)
            return False
        if kind!='passed':
            if kind not in ('cancelled','timeout'):self.issue(path,entry,kind,result['err'])
            else:self.issue(path,entry,'unverified_timeout','FFprobe exceeded its time budget; no corruption conclusion')
            return False
        try:
            data=json.loads(result['out']);streams=data['streams']
            videos=[s['index'] for s in streams if s.get('codec_type')=='video' and not s.get('disposition',{}).get('attached_pic')]
            audio=[s['index'] for s in streams if s.get('codec_type')=='audio']
            duration=float(data.get('format',{}).get('duration','nan'))
            if not videos or not math.isfinite(duration) or duration<=0 or duration>7*86400:raise ValueError('video/duration unavailable')
        except (ValueError,TypeError,KeyError):
            self.issue(path,entry,'unverified_metadata','No usable video stream or finite duration; deep decode coverage cannot be established')
            return False
        entry.update(probeAt=int(time.time()),duration=duration,video=videos,audio=audio)
        self.stats['quickPassed']+=1;self.dirty=True
        return True
    def segment(self,path,entry,fd):
        offset=float(entry.get('offset',0));duration=entry['duration']
        span=min(float(entry.get('chunkSeconds',self.cfg['segmentSeconds'])),duration-offset)
        if span<=0:return 'complete'
        seek=max(0,offset-2);length=span+offset-seek
        args=['ffmpeg','-hide_banner','-nostdin','-v','error','-xerror','-nostats','-stats_period','5',
              '-protocol_whitelist','file','-threads:v',str(self.cfg['threads']),'-threads:a','1',
              '-ss',str(seek),'-i',f'/proc/self/fd/{fd}','-t',str(length)]
        for index in entry['video']+entry['audio']:args+=['-map',f'0:{index}']
        args+=['-sn','-dn','-filter_threads','1','-filter_complex_threads','1','-threads',str(self.cfg['threads']),
               '-progress','pipe:1','-f','null','/dev/null']
        result=self.run_tool(args,fd,self.cfg['segmentWallSeconds']);kind=classify(result)
        self.stats['decodeWallSeconds']+=result['wall']
        if not self.unchanged(path,entry,fd):return 'changed'
        if kind in ('cancelled','timeout'):
            if kind=='timeout' and self.remaining()>5:
                entry['chunkSeconds']=max(15,span/2);self.issue(path,entry,'unverified_timeout','Decode range timed out; range size reduced, offset unchanged',offset)
            return kind
        if kind=='decode_error' and self.remaining()>30:
            again=self.run_tool(args,fd,self.cfg['segmentWallSeconds']);self.stats['decodeWallSeconds']+=again['wall']
            if not self.unchanged(path,entry,fd):return 'changed'
            again_kind=classify(again)
            if again_kind in ('cancelled','timeout'):return again_kind
            self.issue(path,entry,'decode_error' if again_kind=='decode_error' else 'intermittent_error',result['err'],offset,again_kind=='decode_error')
            return 'issue'
        if kind!='passed':
            self.issue(path,entry,kind,result['err'],offset);return 'issue'
        frames=[int(v) for v in re.findall(r'^frame=\s*([0-9]+)',result['out'],re.M)]
        output_times=[int(v) for v in re.findall(r'^out_time_us=([0-9]+)',result['out'],re.M)]
        if not frames or max(frames)==0 or not output_times or max(output_times)<=0:
            self.issue(path,entry,'unverified_empty_decode','Decoder returned success without positive video/frame progress; range not verified',offset)
            return 'issue'
        expected_end=offset+span
        # A successful but substantially short decode is not silently credited
        # for a duration advertised only by a broken/truncated container header.
        if length>10 and max(output_times)/1000000 < length-5:
            self.issue(path,entry,'unverified_short_decode','Decoded output ended before the planned range; duration/header review required',offset)
            return 'issue'
        old=entry.get('issue')
        if old and not entry.get('replacementPending'):
            old['cleanRechecks']=old.get('cleanRechecks',0)+1
            if old['cleanRechecks']<2:return 'recheck'
            self.resolve(path,entry,'Two successful unchanged-file rechecks of the previously failing probe/range; remaining ranges are tracked separately')
        entry['offset']=expected_end;entry['notBefore']=0
        self.stats['segmentsPassed']+=1;self.stats['mediaSecondsDecoded']+=span;self.dirty=True
        if expected_end>=duration-0.05:
            entry.update(verifiedAt=int(time.time()),offset=0,probeAt=int(time.time()),coverage='all_planned_segments_decoded')
            if entry.pop('replacementPending',False):self.resolve(path,entry,'Replacement file completed all planned decode ranges; source version changed')
            entry.pop('cycleLane',None)
            self.stats['cyclesCompleted']+=1;return 'complete'
        return 'next'
    def work(self,path,probe_only=False):
        entry=self.state['files'][path];entry['lastAttemptAt']=int(time.time());entry.pop('deferredReason',None);self.dirty=True
        if time.time()-max(map(int,entry['identity'][3:]))/1000000000<self.cfg['settleSeconds']:
            entry['notBefore']=int(time.time())+self.cfg['settleSeconds'];entry['deferredReason']='Recently changed file; ten-minute settle guard';return
        fd=None;start=time.monotonic()
        try:
            fd=self.open_file(path,entry)
            if not entry.get('probeAt') and not self.probe(path,entry,fd):return
            if probe_only:return
            while not self.stopped() and time.monotonic()-start<self.cfg['fileSliceSeconds']:
                outcome=self.segment(path,entry,fd)
                self.checkpoint()
                if outcome=='changed':entry['notBefore']=int(time.time())+300;entry['deferredReason']='File identity changed during decoding; no range credit'
                if outcome not in ('next','recheck'):break
        except FileNotFoundError:
            entry['notBefore']=int(time.time())+300;entry['deferredReason']='File removed/changed before opening; no range credit'
        except OSError as error:
            kind='read_error' if error.errno==errno.EIO else 'unverified_permissions_or_storage'
            self.issue(path,entry,kind,type(error).__name__+': '+str(error.errno))
        finally:
            if fd is not None:os.close(fd)
            self.checkpoint()
    def finish(self):
        now=int(time.time());files=self.state['files'];stats=self.stats
        stats.update(elapsedSeconds=int(time.monotonic()-self.start),finishedAt=now,
                     pendingInitial=sum(not f.get('verifiedAt') and f.get('cycleLane')!='old' for f in files.values()),
                     pendingPeriodic=sum(f.get('cycleLane')=='old' or (bool(f.get('verifiedAt')) and now-f['verifiedAt']>=self.cfg['recheckDays']*86400) for f in files.values()),
                     activeFindings=sum(bool(f.get('issue')) for f in files.values()),
                     deferredFiles=sum(f.get('notBefore',0)>now for f in files.values()),
                     inProgress=sum(f.get('offset',0)>0 for f in files.values()))
        self.state['resolved']=[r for r in self.state['resolved'] if now-r['resolvedAt']<=30*86400]
        self.state['runs']=(self.state['runs']+[dict(stats)])[-12:]
        self.state['toolset']=self.cfg['toolset'];self.dirty=True;self.checkpoint(True)
        emit({'type':'complete','stats':stats})
    def execute(self):
        self.inventory()
        if self.cfg['mode']=='inventory':self.stats['reason']='Inventory only; no media content read or decoded';self.finish();return
        quick_deadline=self.start+min(self.cfg.get('quickBudgetSeconds',1800),self.cfg['budgetSeconds']*.25)
        for path in sorted(self.found,key=lambda p:(self.state['files'][p].get('lastAttemptAt',0),p)):
            if self.stopped() or time.monotonic()>=quick_deadline:break
            entry=self.state['files'][path]
            if not entry.get('probeAt') and entry.get('notBefore',0)<=time.time():
                self.work(path,probe_only=True);self.checkpoint()
        spent={'new':0.0,'old':0.0}
        while not self.stopped():
            now=int(time.time());new=[];old=[]
            for path in self.found:
                f=self.state['files'][path]
                if f.get('notBefore',0)>now:continue
                if f.get('issue'):new.append(path)
                elif not f.get('verifiedAt'):
                    (old if f.get('cycleLane')=='old' else new).append(path)
                elif now-f['verifiedAt']>=self.cfg['recheckDays']*86400:old.append(path)
            if not new and not old:break
            def order(path):
                f=self.state['files'][path]
                return (path not in self.cfg.get('recoveryPriority',[]),not bool(f.get('offset',0)),f.get('lastAttemptAt',0),f.get('verifiedAt',0),path)
            new.sort(key=order);old.sort(key=order)
            lane='new' if new and (not old or spent['new']<=0.6*sum(spent.values())) else 'old'
            path=(new if lane=='new' else old)[0]
            if lane=='old' and self.state['files'][path].get('verifiedAt'):
                # Start a fresh periodic cycle; mtime/size alone cannot prove
                # absence of bit rot since a previous successful decode.
                f=self.state['files'][path];f['previousVerifiedAt']=f['verifiedAt'];f['verifiedAt']=0;f['offset']=0;f['probeAt']=0;f['cycleLane']='old'
            started=time.monotonic();self.work(path);spent[lane]+=time.monotonic()-started
            # A segment stopped at the remaining run budget is not corruption.
            if self.remaining()<5:break
        self.stats['reason']=STOP or ('Runtime budget reached; queue resumes next schedule' if self.remaining()<5 else 'Eligible queue slice completed; deferred work remains explicit')
        self.finish()

def main():
    global STOP
    signal.signal(signal.SIGTERM,stop_handler);signal.signal(signal.SIGINT,stop_handler)
    token=sys.argv[1]
    if not re.fullmatch(r'[a-f0-9-]{36}',token):raise ValueError('invalid worker token')
    data=json.load(sys.stdin);cfg=data['config']
    root=os.path.realpath(cfg['root'])
    if root!=cfg['root'] or root=='/' or not os.path.isdir(root):raise ValueError('invalid media root')
    if not cfg['libraries'] or any(not isinstance(s,str) or '/' in s or s in ('.','..') for s in cfg['libraries']):raise ValueError('invalid library scope')
    pidfile='/tmp/media-integrity-audit.'+token+'.json'
    fd=os.open(pidfile,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as f:json.dump({'pid':os.getpid(),'token':token,'start':open('/proc/self/stat').read().split()[21]},f)
    audit=None
    try:
        audit=Audit(cfg,data['state']);audit.execute()
    except (BrokenPipeError,KeyboardInterrupt):
        kill_child(ACTIVE)
    except Exception as error:
        kill_child(ACTIVE)
        if audit:
            audit.stats['reason']='Worker failure: '+type(error).__name__;audit.stats['failed']=True
            try:audit.finish()
            except (BrokenPipeError,ValueError,OSError):pass
        emit({'type':'failure','reason':type(error).__name__+': '+str(error)[:300]});sys.exit(1)
    finally:
        kill_child(ACTIVE)
        try:os.unlink(pidfile)
        except FileNotFoundError:pass
if __name__=='__main__':main()

PYWORKER
}

main() {
    case "${1:-}" in
      --version) printf 'media_integrity_audit.sh %s\n' "$SCRIPT_VERSION";return 0;;
      --help|-h) printf '%s\n' 'Usage: bash script [--version|--status|--inventory-only|--recovery-status|--recover-only|--help]' \
        'Default: weekly scan through Bazarr. Recovery is disabled by configuration; no installation or Docker changes.' \
        'Wednesday 09:30 SGT, two-hour runtime, two video threads, low CPU/I/O priority.' \
        'Quick probes and resumable overlapping decode ranges are separate evidence; pending files remain unverified.' \
        'Missing mounts, maintenance, active parity/Mover/backups or Plex transcoding defer/stop work.' \
        '--status reads only saved receipts. --inventory-only stats library paths and saves inventory; no decoding or normal email.' \
        'AUTO_RECOVERY_ENABLED=false: observe for several weeks before changing it. No CLI option bypasses the switch.' \
        '--recovery-status reads the journal only. --recover-only handles bounded Arr recovery; the existing Arr monitor invokes it in four-hour action windows.' \
        'When enabled: two distinct confirming audit runs, exact monitored Arr file/target IDs, no active work, preserved original, durable intents, one targeted search, full replacement verification.' \
        'Preserved originals remain under /mnt/user/media/integrity_quarantine; no automatic purge or quality/profile/blocklist override.' \
        'Timeouts, read errors, unsupported codecs, unmonitored/ambiguous/unmanaged media never authorize recovery.';return 0;;
      --status) [[ ! -f "$STATUS_DIR/media_integrity_audit.json" ]] || jq . "$STATUS_DIR/media_integrity_audit.json";return 0;;
      --inventory-only) MODE=inventory;;
      --recovery-status) recovery_valid || return 1; [[ ! -f "$RECOVERY_FILE" ]] || jq '{schema,actions:[.actions|to_entries[]|{id:.key,app:.value.app,path:.value.path,status:.value.status,reason:.value.reason,parentId:.value.parentId,fileId:.value.fileId,commandId:.value.commandId}]}' "$RECOVERY_FILE";return 0;;
      --recover-only) [[ "$AUTO_RECOVERY_ENABLED" == true ]] || { printf 'Automatic media recovery disabled; observation only.\n'; return 0; };MODE=recover;;
      '') ;;
      *) printf 'Unknown option; use --help.\n' >&2;return 2;;
    esac
    local command flag fd line kind program input libraries toolset started last_guard=0 last_log=0 reason status=OK failure=false event_fd
    local chunk_expected=0 chunk_bytes=0 checkpoint_rc=0 invocation_started worker_budget
    invocation_started=$(date +%s)
    RUN_REPORT_WRITTEN=false
    trap finish EXIT
    for command in docker jq flock timeout gzip base64 sha256sum find stat mountpoint pgrep iconv curl sync df; do command -v "$command" >/dev/null || { FAILURE_REASON="Required host command unavailable: $command";return 1; };done
    for flag in "$MAX_RUNTIME_SECONDS" "$VIDEO_THREADS" "$DECODER_MEMORY_MIB" "$SEGMENT_MEDIA_SECONDS" "$SEGMENT_WALL_SECONDS" "$FILE_SLICE_SECONDS" "$RECHECK_DAYS" "$MAX_STATE_BYTES"; do
        [[ "$flag" =~ ^[1-9][0-9]*$ ]] || return 2
    done
    [[ "$AUTO_RECOVERY_ENABLED" == true || "$AUTO_RECOVERY_ENABLED" == false ]] || return 2
    for flag in "$RECOVERY_MAX_NEW_PER_RUN" "$RECOVERY_MAX_NEW_PER_WEEK" "$RECOVERY_WAIT_DAYS" "$RECOVERY_MAX_SECONDS"; do [[ "$flag" =~ ^[1-9][0-9]*$ ]] || return 2;done
    (( RECOVERY_MAX_NEW_PER_RUN<=3 && RECOVERY_MAX_NEW_PER_WEEK<=10 && RECOVERY_WAIT_DAYS<=90 && RECOVERY_MAX_SECONDS<=180 )) || return 2
    (( MAX_RUNTIME_SECONDS>=60 && MAX_RUNTIME_SECONDS<=14400 && VIDEO_THREADS<=8 && DECODER_MEMORY_MIB>=256 )) || return 2
    mountpoint -q "$VAULT_MOUNT" || {
        RUN_REPORT_WRITTEN=true
        printf 'Vault unavailable; no shadow state, scan or recovery started.\n' >&2
        local marker
        marker="/tmp/media-integrity-storage-failure-$(date +%F)"
        if [[ ! -e "$marker" && -x "$NOTIFY_BIN" ]] && timeout 30 "$NOTIFY_BIN" -i alert -s 'Media Integrity Audit' -d 'Required vault storage unavailable' -m 'No audit or recovery was started. Persistent state was preserved; no media or Arr action was performed. Check the vault mount and next scheduled audit.'; then : >"$marker";fi
        return 1
    }
    [[ "$STATE_DIR" == "$VAULT_MOUNT"/cloud/logs/script/media_integrity_audit && ! -L "$STATE_DIR" && ! -L "$STATUS_DIR" ]] || return 1
    mkdir -p "$STATE_DIR" "$STATUS_DIR" || return 1
    for flag in "$LOG_FILE" "$LOG_FILE.1" "$LOG_FILE.2" "$STATE_DIR/notified.json" "$STATE_DIR/pending-notification.json" "$STATE_DIR/latest-report.txt" "$RECOVERY_FILE"; do [[ ! -L "$flag" ]] || return 1;done
    exec 9>"$LOCK_FILE" || return 1
    flock -n 9 || { printf 'Another media integrity audit is active; invocation deferred.\n';return 0; }
    TMP_DIR=$(mktemp -d /tmp/media-integrity-audit.XXXXXX) || return 1
    trap finish EXIT
    trap 'GUARD_REASON="Operator interruption";cancel_worker;exit 143' INT TERM HUP
    find "$STATE_DIR" -maxdepth 1 -type f \( -name 'media-integrity-audit.log.1' -o -name 'media-integrity-audit.log.2' \) -mtime +29 -delete
    log INFO "Media Integrity Audit v$SCRIPT_VERSION started; mode=$MODE; scope=${LIBRARY_SUBDIRS[*]}; budget=${MAX_RUNTIME_SECONDS}s"
    if ! load_state; then write_report FAILED 'State invalid/unrecoverable; original state preserved and no scan started';return 1;fi
    if ! workload_guard; then
        status=DEFERRED
        case "$GUARD_REASON" in *unavailable*|*unverified*|*stopped*|*symlinked*) status=FAILED;; esac
        write_report "$status" "$GUARD_REASON";[[ "$status" != FAILED ]];return $?
    fi
    if ! recovery_valid; then write_report FAILED 'Invalid/symlinked recovery journal; no scan or mutation started; recovery holds preserved';return 1;fi
    if [[ "$MODE" == recover ]]; then trap 'exit 143' INT TERM HUP;fi
    if [[ "$MODE" != inventory ]]; then
        if ! recovery_process; then RECOVERY_NOTE='Recovery could not complete safely. Preserved original/checkpoints retained; see recovery actions below; no uncertain request was replayed';fi
    fi
    if [[ "$MODE" == recover ]]; then
        trap 'exit 143' INT TERM HUP
        write_report OK 'Bounded recovery pass; scan coverage unchanged';return $?
    fi
    toolset=$(timeout 12 docker exec --user 99:100 "$BAZARR_CONTAINER" sh -c \
      'set -e; command -v python3 >/dev/null; command -v ffprobe >/dev/null; command -v ffmpeg >/dev/null; command -v nice >/dev/null; command -v ionice >/dev/null; ffmpeg -version | sed -n "1p"; ffprobe -version | sed -n "1p"') || {
        write_report FAILED 'Bazarr tool runtime unavailable; no media file was checked';return 1; }
    worker_budget=$((MAX_RUNTIME_SECONDS-($(date +%s)-invocation_started)))
    if ((worker_budget<60)); then write_report DEFERRED 'Preflight/recovery consumed the scan budget; coverage resumes on the next schedule';return 0;fi
    libraries=$(printf '%s\n' "${LIBRARY_SUBDIRS[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')
    input="$TMP_DIR/input.json"
    if [[ -f "$RECOVERY_FILE" ]]; then cp "$RECOVERY_FILE" "$TMP_DIR/recovery-input.json";else printf '{"schema":1,"actions":{}}' >"$TMP_DIR/recovery-input.json";fi
    jq -n --slurpfile state "$TMP_DIR/state.json" --slurpfile recovery "$TMP_DIR/recovery-input.json" --arg root "$MEDIA_CONTAINER_ROOT" --arg hostRoot "$MEDIA_HOST_ROOT" \
      --argjson libraries "$libraries" --arg toolset "$toolset" --arg mode "$MODE" \
      --argjson budget "$worker_budget" --argjson quick "$QUICK_PASS_MAX_SECONDS" --argjson threads "$VIDEO_THREADS" --argjson memory "$DECODER_MEMORY_MIB" \
      --argjson segment "$SEGMENT_MEDIA_SECONDS" --argjson wall "$SEGMENT_WALL_SECONDS" --argjson slice "$FILE_SLICE_SECONDS" \
      --argjson recheck "$RECHECK_DAYS" --argjson settle "$SETTLE_SECONDS" --argjson max "$MAX_STATE_BYTES" \
      '{state:$state[0],config:{root:$root,hostRoot:$hostRoot,libraries:$libraries,toolset:$toolset,mode:$mode,
       budgetSeconds:$budget,quickBudgetSeconds:$quick,threads:$threads,memoryMiB:$memory,segmentSeconds:$segment,segmentWallSeconds:$wall,
       fileSliceSeconds:$slice,recheckDays:$recheck,settleSeconds:$settle,maxStateBytes:$max,recoveryPriority:[$recovery[0].actions[]?|select(.status!="verified")|.replacementPaths[]?]}}' >"$input" || return 1
    program=$(worker_program) || return 1
    WORKER_TOKEN=$(cat /proc/sys/kernel/random/uuid)
    mkfifo "$TMP_DIR/events" || return 1
    (
      exec docker exec -i --user 99:100 "$BAZARR_CONTAINER" nice -n 15 ionice -c 3 python3 -c "$program" "$WORKER_TOKEN" <"$input"
    ) >"$TMP_DIR/events" 2>"$TMP_DIR/worker.stderr" &
    WORKER_PID=$!
    exec {event_fd}<"$TMP_DIR/events"
    started=$(date +%s)
    while :; do
        if IFS= read -r -t 5 line <&"$event_fd"; then
            kind=$(jq -er .type <<<"$line" 2>/dev/null) || { failure=true;GUARD_REASON='Invalid worker protocol';cancel_worker;break; }
            case "$kind" in
              checkpoint)
                checkpoint_rc=0;save_checkpoint "$line" || checkpoint_rc=$?
                if (( checkpoint_rc==75 )); then GUARD_REASON='Operational-state export active; deferred with last committed checkpoint';cancel_worker
                elif (( checkpoint_rc!=0 )); then failure=true;GUARD_REASON='Checkpoint could not be committed; original state retained';cancel_worker;fi;;
              checkpoint-begin)
                chunk_expected=$(jq -r .length <<<"$line")
                if [[ ! "$chunk_expected" =~ ^[1-9][0-9]*$ ]] || (( chunk_expected>MAX_STATE_BYTES*2 )); then failure=true;GUARD_REASON='Invalid checkpoint length';cancel_worker;break;fi
                chunk_bytes=0;: >"$TMP_DIR/checkpoint.chunks.base64";;
              checkpoint-chunk)
                if (( chunk_expected<=0 )) || ! jq -e '(.data|type)=="string" and (.data|length)>0 and (.data|length)<=65536' <<<"$line" >/dev/null; then failure=true;GUARD_REASON='Invalid checkpoint chunk';cancel_worker;break;fi
                printf '%s\n' "$line" | jq -jr .data >>"$TMP_DIR/checkpoint.chunks.base64"
                chunk_bytes=$((chunk_bytes+$(jq '.data|length' <<<"$line")))
                if (( chunk_bytes>chunk_expected )); then failure=true;GUARD_REASON='Checkpoint transport overrun';cancel_worker;break;fi;;
              checkpoint-end)
                printf '%s\n' "$line" | jq .stats >"$TMP_DIR/checkpoint.stats.json"
                checkpoint_rc=0
                if (( chunk_bytes!=chunk_expected || chunk_expected<=0 )); then checkpoint_rc=1
                else commit_checkpoint "$TMP_DIR/checkpoint.chunks.base64" "$TMP_DIR/checkpoint.stats.json" || checkpoint_rc=$?;fi
                if (( checkpoint_rc==75 )); then GUARD_REASON='Operational-state export active; deferred with last committed checkpoint';cancel_worker
                elif (( checkpoint_rc!=0 )); then failure=true;GUARD_REASON='Incomplete/uncommitted chunked checkpoint';cancel_worker;fi
                chunk_expected=0;chunk_bytes=0;;
              heartbeat) ;;
              complete) printf '%s\n' "$line" | jq .stats >"$TMP_DIR/stats.json";WORKER_FINISHED=true;;
              failure) failure=true;GUARD_REASON=$(jq -r .reason <<<"$line");;
              transport) TRANSPORT_RC=$(jq -r .code <<<"$line");break;;
              *) failure=true;GUARD_REASON='Unknown worker protocol event';cancel_worker;break;;
            esac
        elif ! kill -0 "$WORKER_PID" 2>/dev/null; then break;fi
        if (( $(date +%s)-last_guard>=15 )); then
            last_guard=$(date +%s)
            if (( last_guard-last_log>=600 )) && [[ -f "$TMP_DIR/stats.json" ]]; then
                log INFO "Checkpoint: $(jq -r '"quick="+((.quickPassed // 0)|tostring)+"; ranges="+((.segmentsPassed // 0)|tostring)+"; cycles="+((.cyclesCompleted // 0)|tostring)' "$TMP_DIR/stats.json")"
                last_log="$last_guard"
            fi
            if [[ -z "$GUARD_REASON" ]] && ! workload_guard; then log INFO "Work deferred: $GUARD_REASON";cancel_worker;fi
        fi
        if (( $(date +%s)-started>MAX_RUNTIME_SECONDS+90 )); then failure=true;GUARD_REASON='Worker exceeded supervisor deadline; cancellation requested';cancel_worker;break;fi
    done
    exec {event_fd}<&-
    if [[ "$WORKER_FINISHED" != true ]]; then cancel_worker;fi
    local wait_count=0
    while kill -0 "$WORKER_PID" 2>/dev/null && (( wait_count<20 )); do sleep 0.5;wait_count=$((wait_count+1));done
    if kill -0 "$WORKER_PID" 2>/dev/null; then kill "$WORKER_PID" 2>/dev/null || true; sleep 1;kill -KILL "$WORKER_PID" 2>/dev/null || true;fi
    wait "$WORKER_PID" 2>/dev/null || TRANSPORT_RC=$?
    WORKER_PID=""
    # Planned container maintenance may terminate docker exec before the next
    # guard poll. Recheck dependencies before classifying that as a script fault.
    if [[ -z "$GUARD_REASON" && ( "$WORKER_FINISHED" != true || "$TRANSPORT_RC" != 0 ) ]]; then workload_guard || true;fi
    if [[ "$failure" == true ]] || jq -e '.failed==true' "$TMP_DIR/stats.json" >/dev/null 2>&1; then
        status=FAILED;reason="${GUARD_REASON:-Worker failed; last completed checkpoint retained}"
    elif [[ -n "$GUARD_REASON" ]]; then status=DEFERRED;reason="$GUARD_REASON"
    elif [[ "$WORKER_FINISHED" != true || "$TRANSPORT_RC" != 0 ]]; then
        status=FAILED;reason='Worker interrupted/unavailable without maintenance evidence; last completed checkpoint retained'
    else
        reason=$(jq -r '.reason // "Completed scan slice"' "$TMP_DIR/stats.json")
        if jq -e '.activeFindings>0 or .inventoryErrors>0 or .inventoryComplete!=true' "$TMP_DIR/stats.json" >/dev/null; then status=WARNING;fi
        [[ "$MODE" != inventory ]] || status=INVENTORY_ONLY
    fi
    write_report "$status" "$reason" || return 1
    [[ "$status" != FAILED ]]
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
