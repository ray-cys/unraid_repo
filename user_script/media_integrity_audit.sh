#!/bin/bash
# shellcheck disable=SC2034
arrayStarted=true
###############################################################################
# Media Integrity Audit v2.1.2 -- personal Unraid User Script
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
# All run summaries/progress/recoveries remain in local reports. Active
# findings, unexpected failures, state fallback or incomplete/overdue recovery
# trigger grouped attention email. Same evidence reminds at most weekly; progress
# alone and healthy ordinary scans stay quiet. Verified replacement completion
# sends one grouped operational notification, retried if delivery fails. A failed
# attention email remains in one pending outbox and retries while still relevant.
#
# OPTIONAL ARR RECOVERY (OFF): two distinct confirming runs on one unchanged
# version, fresh <=48h evidence and matching decoder runtime. Keep the original
# and Arr file record in place. Use native interactive release search, exact IDs,
# current profile/quality/revision/language/score rules and Usenet only. Select
# an alternative release; POST /release once. No file DELETE, monitoring PUT,
# profile changes, blocklisting, forced import or script-managed bin handoff.
# Arr owns normal replacement and recycling. Exact download history/import/file
# identity plus complete planned-range decoding are required before RECOVERED.
# Existing monitor runs bounded priority verification between weekly scans; only
# new grabs use 00/04/08/12/16/20:00-09 SGT windows. Same audit/backup/metadata
# locks and exact-target ownership protect complementary script automation.
# Replacement-required/blocked/completed events are grouped and delivery-tracked.
# Native bin retention is independent; overdue verification alerts cannot extend
# it. No promise of atomic filesystem import or guaranteed original rollback.
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
readonly SCRIPT_VERSION="2.1.2"
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
NOTIFY_MAX_ITEMS=8
BACKUP_LOCK_FILES=(/tmp/appdata_backup.lock /tmp/remote_backup.lock /run/vault_backup.lock)
PLEX_CONTAINERS=(plex-media-server plex-media)
ARR_BACKUP_GATE="/run/arr-appdata-coordination.lock"
STATE_EXPORT_LOCK="/run/user-script-state-export.lock"
DOCKER_MAINTENANCE_DIR="/run/docker-service-maintenance"
# Observation remains the default. Enabling this later permits bounded
# Arr-native release selection/grab, only after two separate audit runs confirm
# the same unchanged decoder error. Original remains in place; no forced import.
AUTO_RECOVERY_ENABLED=false
SONARR_API_ROOT="${SONARR_API_ROOT:-http://192.168.50.4:8989/api/v5}"
SONARR_API_KEY="${SONARR_API_KEY:-PUT_YOUR_SONARR_API_KEY_HERE}"
RADARR_API_ROOT="${RADARR_API_ROOT:-http://192.168.50.4:7878/api/v3}"
RADARR_API_KEY="${RADARR_API_KEY:-PUT_YOUR_RADARR_API_KEY_HERE}"
SONARR_MEDIA_ROOT="/data"
RADARR_MEDIA_ROOT="/data"
RECOVERY_FILE="$STATE_DIR/recovery.json"
RECOVERY_PREVIOUS_FILE="$STATE_DIR/recovery.previous.json"
RECOVERY_DOWNLOAD_ROOTS=(/mnt/user/media/net/incomplete /mnt/user/media/net/complete)
RECOVERY_MAX_ATTEMPTS=2
RECOVERY_RETRY_SECONDS=14400
RECOVERY_MAX_NEW_PER_RUN=1
RECOVERY_MAX_NEW_PER_WEEK=3
RECOVERY_WAIT_DAYS=28
RECOVERY_ALLOW_GRAB="${RECOVERY_ALLOW_GRAB:-false}"
RECOVERY_NEW_GRABS=0
RECOVERY_MAX_SECONDS=90
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
    local status="$1" reason="$2" now temp body importance=normal previous="" last=0 signature attention=false sent=0
    now=$(date +%s)
    [[ ! -f "$STATE_FILE" ]] || unpack_state "$STATE_FILE" || true
    jq -e '.schema==1 and (.files|type)=="object"' "$TMP_DIR/state.json" >/dev/null 2>&1 || printf '{"schema":1,"files":{}}' >"$TMP_DIR/state.json"
    [[ -f "$TMP_DIR/stats.json" ]] || printf '{}' >"$TMP_DIR/stats.json"
    if recovery_valid;then cp "$RECOVERY_FILE" "$TMP_DIR/recovery-report.json";else printf '{"schema":1,"workflow":"arr-native","actions":{}}' >"$TMP_DIR/recovery-report.json";fi
    if [[ -f "$STATE_DIR/notified.json" ]];then cp "$STATE_DIR/notified.json" "$TMP_DIR/delivery.json";else printf '{}' >"$TMP_DIR/delivery.json";fi
    temp=$(mktemp "$STATE_DIR/.report.XXXXXX") || return 1
    jq -n --slurpfile state "$TMP_DIR/state.json" --slurpfile stats "$TMP_DIR/stats.json" --slurpfile journal "$TMP_DIR/recovery-report.json" --slurpfile receipt "$TMP_DIR/delivery.json" \
      --argjson enabled "$AUTO_RECOVERY_ENABLED" --argjson now "$now" --argjson max "$NOTIFY_MAX_ITEMS" --arg status "$status" --arg reason "$reason" --arg mode "$MODE" --arg note "$RECOVERY_NOTE" '
      [$state[0].files|to_entries[]|select(.value.issue!=null)] as $issues |
      [$journal[0].actions|to_entries[]|.notice=(.key+":"+.value.status+":"+.value.reason+(if .value.status=="verifying" and (.value.verificationDeadlineAt // 0)>0 and $now>=.value.verificationDeadlineAt then ":native_retention_elapsed" else "" end))] as $jobs |
      [$jobs[]|select(.value.status=="required" or .value.status=="downloading" or .value.status=="blocked" or .value.status=="review" or .value.status=="recovered" or .value.status=="cancelled" or .value.status=="resolved" or .value.status=="retry_wait" or
        (.value.status=="verifying" and $now>=(.value.verificationAttentionAt // ((.value.importedAt // .value.startedAt)+86400))))|
        select(.notice as $k|($receipt[0].recoveryEvents // []|index($k))==null)] as $notices |
      [$jobs[]|select(.value.status=="required" or .value.status=="blocked" or .value.status=="review" or .value.status=="retry_wait" or (.value.status=="verifying" and $now>=(.value.verificationAttentionAt // ((.value.importedAt // .value.startedAt)+86400))))] as $attention |
      (if $status=="FAILED" then "FAILED" elif ($issues|length)>0 or ($attention|length)>0 or $note!="" then "WARNING" else $status end) as $effective |
      {schema:1,name:"media_integrity_audit",status:$effective,epoch:$now,mode:$mode,recoveryEnabled:$enabled,stats:$stats[0],
       recoveryActions:($jobs|length),recoveryAttention:($attention|length),activeFindings:($issues|length),recoveries:([$jobs[]|select(.value.status=="recovered")]|length),
       findingKeys:[$issues[]|.value.issue.id+":"+.value.issue.kind+":"+(.value.issue.confirmed|tostring)+":"+((.value.issue.confirmedRuns // 0)>=2|tostring)],
       recoveryAttentionKeys:[$attention[].notice],noticeKeys:[$notices[:$max][].notice],
       summary:("Media integrity: "+$effective+"; findings="+($issues|length|tostring)+"; replacement updates="+($notices|length|tostring)),
       body:(["Media integrity audit: "+$effective,"Automatic replacement: "+(if $enabled then "ENABLED" else "DISABLED; original files remain unchanged" end),
        "Run: "+$mode+"; "+$reason,"Checks passed: quick="+(($stats[0].quickPassed // 0)|tostring)+"; ranges="+(($stats[0].segmentsPassed // 0)|tostring)+"; full planned-range cycles="+(($stats[0].cyclesCompleted // 0)|tostring),
        "Original files and monitoring are retained until native Arr replacement. Arr owns imports and recycling; this script never moves/deletes library media or forces import.",
        "State note: "+$note,"", "Replacement actions and results:"]+
       [$notices[:$max][]|"- "+.value.app+" | "+.value.path+" | "+.value.status+
        "\n  Action/evidence: "+.value.reason+"\n  Target IDs: "+(.value.targets|tostring)+"; original file ID: "+(.value.fileId|tostring)+
        "\n  Selected release: "+(.value.selected.title // "none; original retained")+"; download ID: "+(.value.downloadId // "none")+
        "\n  Replacement files: "+((.value.replacementFiles // []|map({path,fileId}))|tostring)+
        "\n  Attempts: "+((.value.attempts // []|length)|tostring)+"; retry no earlier than epoch: "+((.value.retryAt // 0)|tostring)+
        "\n  Native recycling retention days: "+((.value.binRetentionDays // "unknown")|tostring)+"; verification deadline: "+(if (.value.verificationDeadlineAt // 0)>0 then (.value.verificationDeadlineAt|strftime("%Y-%m-%d %H:%M UTC")) else "no timed native cleanup verified" end)+
        "\n  Last API diagnostic: "+((.value.lastError // {})|tostring)+"\n  Recent transitions: "+((.value.events[-5:] // []|map(.status+": "+.reason))|join("; "))]+
       ["", "Current media findings:"]+
       [$issues[:$max][]|"- "+.key+" | "+.value.issue.kind+"\n  Finding ID: "+.value.issue.id+"; separate confirming runs: "+((.value.issue.confirmedRuns // 0)|tostring)+
        "\n  Evidence: "+((.value.issue.evidence // "")|.[0:650])+"\n  Next action: "+
        (if .value.issue.kind=="decode_error" and .value.issue.confirmed then "Replacement required after two separate confirming runs. "+(if $enabled then "Exact-rule selection is bounded; see job outcome." else "Recovery disabled; review evidence before enabling automation." end)
         else "Review access/tool/resource evidence. This issue does not authorize automatic replacement." end)]+
       ["", "Full verification requires all planned decode ranges; a download/import event alone does not prove integrity. Native bin retention continues independently. Verification alerts before the observed native retention expires (or after 24 hours when no deadline applies); no rollback is guaranteed. --recovery-status includes bounded transition history."]|join("\n"))}' >"$temp" || return 1
    body=$(jq -r .body "$temp"|head -c 23000|iconv -f UTF-8 -t UTF-8 -c || true)
    printf '%s\n' "$body" >"$STATE_DIR/latest-report.txt.new" && mv "$STATE_DIR/latest-report.txt.new" "$STATE_DIR/latest-report.txt" || return 1
    signature=$(jq -c '{status,findingKeys,recoveryAttentionKeys,note:$note,reason:$reason}' --arg note "$RECOVERY_NOTE" --arg reason "$( [[ "$status" != FAILED ]] || printf '%s' "$reason" )" "$temp"|sha256sum|awk '{print $1}')
    previous=$(jq -r '.signature // ""' "$TMP_DIR/delivery.json");last=$(jq -r '.sentAt // 0' "$TMP_DIR/delivery.json")
    jq -e '.activeFindings>0 or .recoveryAttention>0 or .status=="FAILED" or .status=="WARNING"' "$temp" >/dev/null && attention=true
    if [[ "$MODE" != inventory ]] && { jq -e '.noticeKeys|length>0' "$temp" >/dev/null || [[ "$attention" == true && ( "$signature" != "$previous" || $((now-last)) -ge NOTIFICATION_REMINDER_SECONDS ) ]]; };then
        [[ "$attention" != true ]] || importance=warning;[[ "$status" != FAILED ]] || importance=alert
        jq -n --arg body "$body" --arg signature "$signature" --argjson epoch "$now" '{schema:1,body:$body,signature:$signature,epoch:$epoch}' >"$STATE_DIR/pending-notification.json.new" && mv "$STATE_DIR/pending-notification.json.new" "$STATE_DIR/pending-notification.json" || return 1
        if [[ -x "$NOTIFY_BIN" ]] && timeout 30 "$NOTIFY_BIN" -i "$importance" -s 'Media Integrity Audit' -d "$(jq -r .summary "$temp")" -m "$body";then
            jq --arg signature "$signature" --argjson sentAt "$now" --slurpfile report "$temp" '.signature=$signature | .sentAt=$sentAt | .recoveryEvents=((.recoveryEvents // [])+$report[0].noticeKeys|unique|.[-512:])' "$TMP_DIR/delivery.json" >"$STATE_DIR/notified.json.new" && mv "$STATE_DIR/notified.json.new" "$STATE_DIR/notified.json" || return 1
            rm -f "$STATE_DIR/pending-notification.json";sent=1
        else log WARNING 'Grouped replacement notification failed; delivery remains pending';fi
    elif [[ "$attention" == false ]];then rm -f "$STATE_DIR/pending-notification.json";fi
    local completed=0 installed="$now" first="$now"
    if [[ -f "$STATUS_DIR/media_integrity_audit.json" ]];then
        completed=$(jq -r '.lastCompletedScanAt // 0' "$STATUS_DIR/media_integrity_audit.json");installed=$(jq -r '.installedAt // .epoch' "$STATUS_DIR/media_integrity_audit.json");first=$(jq -r '.firstScheduledAt // .epoch' "$STATUS_DIR/media_integrity_audit.json")
    fi
    if [[ "$MODE" == scan && "$WORKER_FINISHED" == true && "$status" != FAILED && "$status" != DEFERRED ]] && jq -e '.inventoryComplete==true' "$TMP_DIR/stats.json" >/dev/null;then completed="$now";fi
    local delivery=suppressed;((sent==0)) || delivery=sent;[[ ! -f "$STATE_DIR/pending-notification.json" ]] || delivery=failed
    jq --arg notification "$delivery" --arg version "$SCRIPT_VERSION" --argjson completed "$completed" --argjson installed "$installed" --argjson first "$first" '.+{notification:$notification,scriptVersion:$version,lastCompletedScanAt:$completed,installedAt:$installed,firstScheduledAt:$first}' "$temp" >"$STATUS_DIR/.media-integrity-audit.new" && mv "$STATUS_DIR/.media-integrity-audit.new" "$STATUS_DIR/media_integrity_audit.json" || return 1
    RUN_REPORT_WRITTEN=true;log INFO "$(jq -r .summary "$temp")";rm -f "$temp"
}

# Arr-native recovery never moves/unlinks library media, deletes file records,
# changes monitoring, forces imports or purges bins. Only POST /release is allowed.
recovery_valid() { recovery_document_valid "$RECOVERY_FILE"; }
recovery_document_valid() {
    local document="$1"
    [[ -f "$document" && ! -L "$document" ]] || return 1
    jq -e '.schema==1 and .workflow=="arr-native" and (.actions|type)=="object" and all(.actions|to_entries[];
      (.key|test("^[a-f0-9]{64}$")) and (.value.app=="Sonarr" or .value.app=="Radarr") and
      (.value.parentId|type)=="number" and .value.parentId>0 and (.value.fileId|type)=="number" and .value.fileId>0 and
      (.value.path|type)=="string" and (.value.path|startswith("/")|not) and all(.value.path|split("/")[];.!="" and .!="." and .!="..") and
      (.value.identity|type)=="array" and (.value.identity|length)==5 and all(.value.identity[];type=="string" and test("^[0-9]+$")) and
      (.value.targets|type)=="array" and (.value.targets|length)>0 and all(.value.targets[];type=="number" and .>0) and
      (.value.status as $s|["required","selected","grab_intent","downloading","imported","verifying","recovered","blocked","review","cancelled","resolved","retry_wait"]|index($s))!=null and
      (.value.events|type)=="array" and (.value.events|length)<=32)' "$document" >/dev/null
}
recovery_update() {
    local filter="$1" tmp fd previous="${RECOVERY_FILE%.json}.previous.json";shift
    tmp=$(mktemp "$STATE_DIR/.recovery.XXXXXX") || return 1
    jq "$@" "$filter" "$RECOVERY_FILE" >"$tmp" || { rm -f "$tmp";return 1; }
    # Journal only meaningful transitions, capped per action; polling/progress
    # timestamps never create an unbounded event stream or new notification.
    jq --slurpfile old "$RECOVERY_FILE" --argjson now "$(date +%s)" '.actions |= with_entries(
      .key as $id | if ($old[0].actions[$id].status!="" and ($old[0].actions[$id].status!=.value.status or $old[0].actions[$id].reason!=.value.reason)) then
       .value.events=((.value.events // [])+[{at:$now,status:.value.status,reason:.value.reason}]|.[-32:]) else . end)' "$tmp" >"$tmp.events" && mv "$tmp.events" "$tmp" || return 1
    recovery_document_valid "$tmp" || { rm -f "$tmp";return 1; }
    if jq -e --slurpfile next "$tmp" '.==$next[0]' "$RECOVERY_FILE" >/dev/null;then rm -f "$tmp";return 0;fi
    exec {fd}>"$STATE_EXPORT_LOCK" || return 1
    flock -s -w 5 "$fd" && recovery_valid && cp "$RECOVERY_FILE" "$previous.new" && sync -f "$previous.new" && mv -f "$previous.new" "$previous" && sync -f "$tmp" && mv -f "$tmp" "$RECOVERY_FILE" && sync -f "$RECOVERY_FILE"
    local rc=$?;exec {fd}>&-;rm -f "$tmp";return "$rc"
}
recovery_set() {
    recovery_update 'if .actions[$id].status==$status and .actions[$id].reason==$reason then . else .actions[$id].status=$status | .actions[$id].reason=$reason | .actions[$id].updatedAt=$now end' \
      --arg id "$1" --arg status "$2" --arg reason "$3" --argjson now "$(date +%s)"
}
# Retry idempotent reads only. Requests and diagnostics never include API keys.
recovery_api() {
    local method="$1" endpoint="$2" output="$3" payload="${4:-}" rc=0 attempt limit=1 remaining seconds args=()
    RECOVERY_HTTP=000;RECOVERY_LAST_OPERATION="$method $endpoint";RECOVERY_LAST_EXIT=0
    [[ "$method" == GET || ( "$method" == POST && "$endpoint" == /release ) ]] || return 2
    [[ "$method" != GET ]] || limit=2
    [[ "$method" != POST ]] || args+=(--header 'Content-Type: application/json' --data-binary "@$payload")
    for ((attempt=1;attempt<=limit;attempt++));do
        seconds=10;[[ "$endpoint" != /release\?* ]] || seconds=30
        if ((RECOVERY_DEADLINE>0));then remaining=$((RECOVERY_DEADLINE-$(date +%s)));((remaining>0)) || { RECOVERY_LAST_EXIT=124;return 124; };((remaining>=seconds)) || seconds=$remaining;fi
        rc=0
        RECOVERY_HTTP=$(curl --silent --show-error --retry 0 --connect-timeout 4 --max-time "$seconds" --max-filesize 67108864 \
          --request "$method" --header "X-Api-Key: $RECOVERY_KEY" --output "$output" --write-out '%{http_code}' \
          "${args[@]}" "$RECOVERY_ROOT$endpoint" 2>"$TMP_DIR/recovery-curl.error") || rc=$?
        RECOVERY_LAST_EXIT=$rc
        if ((rc==0)) && [[ "$RECOVERY_HTTP" == 2?? || ( "$method" == GET && "$RECOVERY_HTTP" == 404 ) ]];then return 0;fi
        [[ "$method" == GET && ( "$rc" == 28 || "$rc" == 7 || "$rc" == 6 || "$RECOVERY_HTTP" == 429 || "$RECOVERY_HTTP" == 502 || "$RECOVERY_HTTP" == 503 || "$RECOVERY_HTTP" == 504 ) ]] || break
        ((attempt>=limit)) || sleep 1
    done
    return 1
}
recovery_api_diagnostic() {
    local id="$1" detail="$2"
    recovery_update '.actions[$id].lastError={at:$now,detail:$detail,operation:$operation,http:$http,exit:$exit}' --arg id "$id" --arg detail "$detail" \
      --arg operation "${RECOVERY_LAST_OPERATION:-native response validation}" --arg http "${RECOVERY_HTTP:-000}" --argjson exit "${RECOVERY_LAST_EXIT:-0}" --argjson now "$(date +%s)"
}
recovery_connection() {
    case "$1" in Sonarr) RECOVERY_ROOT="$SONARR_API_ROOT";RECOVERY_KEY="$SONARR_API_KEY";;Radarr) RECOVERY_ROOT="$RADARR_API_ROOT";RECOVERY_KEY="$RADARR_API_KEY";;*) return 1;;esac
    [[ -n "$RECOVERY_KEY" && "$RECOVERY_KEY" != PUT_YOUR_* && "$RECOVERY_ROOT" =~ ^https?://[^[:space:]]+/api/v(3|5)$ ]]
}
recovery_file_tool() {
    [[ "$1" == identity ]] || return 2
    timeout 10 docker exec --user 99:100 "$BAZARR_CONTAINER" python3 -c '
import json,os,stat,sys
root,rel=sys.argv[1:];p=os.path.join(root,rel)
if not rel or rel.startswith("/") or any(v in ("",".","..") for v in rel.split("/")) or os.path.realpath(p)!=p:raise ValueError("unsafe/symlinked media path")
s=os.stat(p,follow_symlinks=False)
if not stat.S_ISREG(s.st_mode):raise ValueError("not regular media")
print(json.dumps([str(v) for v in (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)]))
' "$MEDIA_CONTAINER_ROOT" "$2" </dev/null
}
recovery_quiet_app() {
    local parent="$1" kind="$2" queue="$TMP_DIR/recovery-queue.json" commands="$TMP_DIR/recovery-commands.json" health="$TMP_DIR/recovery-health.json"
    recovery_api GET '/health' "$health" && [[ "$RECOVERY_HTTP" == 200 ]] && jq -e 'type=="array" and all(.[]; (.type // ""|ascii_downcase) as $level | ["notice","info"]|index($level)!=null)' "$health" >/dev/null || return 1
    recovery_api GET '/queue?page=1&pageSize=1000&includeUnknownSeriesItems=true&includeUnknownMovieItems=true' "$queue" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
    jq -e --arg field "$kind" --argjson parent "$parent" '
      (.records|type)=="array" and (.totalRecords|type)=="number" and .totalRecords==(.records|length)
      and all(.records[]; (.[$field] // 0)>0 and .[$field]!=$parent)' "$queue" >/dev/null || return 1
    recovery_api GET '/command' "$commands" && [[ "$RECOVERY_HTTP" == 200 ]] && jq -e 'type=="array" and all(.[]; ((.status // ""|ascii_downcase) as $s | ["completed","failed","cancelled","aborted"] | index($s))!=null)' "$commands" >/dev/null
}
recovery_platform_ready() {
    local version
    version=$(sed -n 's/^version="\([^"]*\)"/\1/p' /etc/unraid-version 2>/dev/null) || return 1
    [[ "$version" == 7.* ]]
}
recovery_base_plan() {
    local candidate="$1" output="$2" app relative expected catalog parent files targets file_id parent_id path
    printf '[]\n' >"$TMP_DIR/recovery-linked.json"
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
recovery_runtime_matches() {
    local current
    current=$(timeout 12 docker exec --user 99:100 "$BAZARR_CONTAINER" sh -c 'ffmpeg -version | sed -n "1p"; ffprobe -version | sed -n "1p"') || return 1
    jq -e --arg toolset "$current" '.toolset==$toolset' "$TMP_DIR/state.json" >/dev/null
}

recovery_select_release() {
    timeout 12 docker exec -i --user 99:100 "$BAZARR_CONTAINER" python3 -c '
import json,re,sys
x=json.load(sys.stdin);j=x['\''job'\''];profile=j['\''profile'\''];old=j['\''originalMedia'\''];app=j['\''app'\'']
# Preserve native profile ordering, including grouped qualities. Unknown quality
# IDs, source metadata, rejection formats and episode mappings fail closed.
weights={}
for i,g in enumerate(profile['\''items'\'']):
 for q in ([g.get('\''quality'\'')] if not g.get('\''items'\'') else [v.get('\''quality'\'') for v in g['\''items'\'']]):
  if q and g.get('\''allowed'\'') is True:weights[q['\''id'\'']]=i
oldq=old['\''quality'\'']['\''quality'\'']['\''id'\''];minimum=profile['\''minFormatScore'\''];previous=old.get('\''customFormatScore'\'')
if oldq not in weights or not isinstance(previous,int):raise ValueError('\''original quality/format score unavailable'\'')
allowed={'\''diskCutoffMet'\'','\''diskHigherPreference'\'','\''diskHigherRevision'\'','\''diskCustomFormatCutoffMet'\'','\''diskCustomFormatScore'\'','\''diskCustomFormatScoreIncrement'\''}
patterns=[r'\''Existing file meets cutoff: .+'\'',r'\''Existing file on disk meets (?:quality|Custom Format) cutoff: .+'\'',r'\''Existing file on disk is of equal or higher (?:preference|revision): .+'\'',r'\''Existing file on disk has a equal or higher Custom Format score: .+'\'',r'\''Existing file on disk has Custom Format score within Custom Format score increment: .+'\'']
selected=[]
for r in x['\''releases'\'']:
 try:
  release=r['\''release'\''] if app=='\''Sonarr'\'' else r
  decision=r['\''decision'\''] if app=='\''Sonarr'\'' else r
  parsed=r['\''parsedInfo'\''] if app=='\''Sonarr'\'' else r
  q=parsed['\''quality'\''];qid=q['\''quality'\'']['\''id'\''];score=r['\''customFormatScore'\'']
  if release.get('\''protocol'\'','\'''\'').lower()!='\''usenet'\'' or not isinstance(release.get('\''guid'\''),str) or not release['\''guid'\''] or not isinstance(release.get('\''indexerId'\''),int) or release['\''indexerId'\'']<=0:continue
  if not isinstance(release.get('\''title'\''),str) or not release['\''title'\''] or release.get('\''size'\'',0)<=0 or r.get('\''downloadAllowed'\'') is not True or decision.get('\''temporarilyRejected'\'') is not False:continue
  if qid not in weights or weights[qid]<weights[oldq] or not isinstance(score,int) or score<minimum:continue
  if weights[qid]==weights[oldq] and score<previous:continue
  revision=lambda z:(z.get('\''real'\'',0),z.get('\''version'\'',1),bool(z.get('\''isRepack'\'',False)))
  if qid==oldq and revision(q.get('\''revision'\'',{}))<revision(old['\''quality'\''].get('\''revision'\'',{})):continue
  if old.get('\''languages'\'') and sorted(v['\''id'\''] for v in r.get('\''languages'\'',[]))!=sorted(v['\''id'\''] for v in old['\''languages'\'']):continue
  if any(v.get('\''guid'\'')==release['\''guid'\''] or v.get('\''title'\'')==release['\''title'\''] for v in j.get('\''failedReleases'\'',[])):continue
  if release['\''title'\'']==old.get('\''sceneName'\'') or (r.get('\''history'\'') or {}).get('\''grabbed'\''):continue
  reasons=decision.get('\''rejections'\'')
  if not isinstance(reasons,list):continue
  if not reasons and decision.get('\''approved'\'') is not True:continue
  if app=='\''Sonarr'\'':
   if any(not isinstance(v,dict) or v.get('\''reason'\'') not in allowed for v in reasons):continue
   mapped=r['\''mappedEpisodeInfo'\'']
   if r.get('\''mappedSeriesId'\'')!=j['\''parentId'\''] or sorted(v['\''id'\''] for v in mapped)!=sorted(j['\''targets'\'']) or parsed.get('\''fullSeason'\'') is not False:continue
   expected={v['\''id'\'']:(v['\''seasonNumber'\''],v['\''episodeNumber'\'']) for v in j['\''targetDetails'\'']}
   if any(expected[v['\''id'\'']]!=(v['\''seasonNumber'\''],v['\''episodeNumber'\'']) for v in mapped):continue
   payload={'\''guid'\'':release['\''guid'\''],'\''indexerId'\'':release['\''indexerId'\''],'\''searchInfo'\'':{'\''episodeId'\'':j['\''targets'\''][0]}}
  else:
   if any(not isinstance(v,str) or not any(re.fullmatch(p,v) for p in patterns) for v in reasons):continue
   if r.get('\''mappedMovieId'\'')!=j['\''parentId'\''] or r.get('\''movieRequested'\'') is not True:continue
   if old.get('\''edition'\'') and r.get('\''edition'\'')!=old['\''edition'\'']:continue
   payload={'\''guid'\'':release['\''guid'\''],'\''indexerId'\'':release['\''indexerId'\''],'\''movieId'\'':j['\''parentId'\'']}
  selected.append({'\''title'\'':release['\''title'\''],'\''guid'\'':release['\''guid'\''],'\''indexerId'\'':release['\''indexerId'\''],'\''size'\'':release['\''size'\''],'\''quality'\'':q,'\''score'\'':score,'\''rejections'\'':reasons,'\''payload'\'':payload,'\''rank'\'':r.get('\''releaseWeight'\'',1000000)})
 except (KeyError,TypeError,ValueError):continue
selected.sort(key=lambda v:v['\''rank'\''])
print(json.dumps(selected[0] if selected else None))
'
}
recovery_plan() {
    local candidate="$1" output="$2" base="$TMP_DIR/native-base.json" owner="$TMP_DIR/native-owner.json" media="$TMP_DIR/native-original.json" profile="$TMP_DIR/native-profile.json" app parent file kind pid
    recovery_base_plan "$candidate" "$base" || return 1
    app=$(jq -r .app "$base");parent=$(jq -r .parentId "$base");file=$(jq -r .fileId "$base")
    kind=movie;[[ "$app" != Sonarr ]] || kind=series
    recovery_api GET "/$kind/$parent" "$owner" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
    jq -e --argjson parent "$parent" '.id==$parent and .monitored==true and (.tags|length)==0 and (.qualityProfileId|type)=="number"' "$owner" >/dev/null || return 1
    kind=moviefile;[[ "$app" != Sonarr ]] || kind=episodefile
    recovery_api GET "/$kind/$file" "$media" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
    jq -e --slurpfile job "$base" '.id==$job[0].fileId and .path==$job[0].apiPath and (.customFormatScore|type)=="number"' "$media" >/dev/null || return 1
    pid=$(jq -r .qualityProfileId "$owner")
    recovery_api GET "/qualityprofile/$pid" "$profile" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
    jq -e --argjson pid "$pid" '.id==$pid and (.items|type)=="array" and (.minFormatScore|type)=="number"' "$profile" >/dev/null || return 1
    jq --slurpfile owner "$owner" --slurpfile media "$media" --slurpfile profile "$profile" --slurpfile details "$TMP_DIR/recovery-linked.json" \
      '.workflow="arr-native" | .status="required" | .reason="Confirmed unchanged decoder failure; replacement required. Original remains in its library location and native monitoring is unchanged." |
       .externalId=(if .app=="Sonarr" then $owner[0].tvdbId else $owner[0].tmdbId end) | .profile=$profile[0] | .originalMedia=($media[0]|{id,path,quality,customFormatScore,languages,edition,sceneName}) |
       .targetDetails=(if .app=="Sonarr" then [$details[0][]|{id,seriesId,seasonNumber,episodeNumber}] else [] end) | .events=[]' "$base" >"$output" || return 1
    jq -e '.externalId>0' "$output" >/dev/null
}
# Bound complete pagination. Duplicate IDs or changing totals fail closed.
recovery_history() {
    local job="$1" output="$2" download="${3:-}" query page count total=-1 loaded=0 expected part="$TMP_DIR/history-page.json" rows="$TMP_DIR/history-rows.jsonl"
    if [[ -n "$download" ]];then query="downloadId=$download";elif [[ $(jq -r .app "$job") == Sonarr ]];then query="episodeId=$(jq -r '.targets[0]' "$job")";else query="movieIds=$(jq -r .parentId "$job")";fi
    : >"$rows"
    for ((page=1;page<=10;page++));do
        recovery_api GET "/history?page=$page&pageSize=200&sortKey=date&sortDirection=descending&$query" "$part" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq -e '(.records|type)=="array" and (.totalRecords|type)=="number" and .totalRecords>=0 and all(.records[];(.id|type)=="number" and .id>0)' "$part" >/dev/null || return 1
        expected=$(jq .totalRecords "$part");count=$(jq '.records|length' "$part")
        ((expected<=2000 && (total<0 || expected==total))) || return 1;total=$expected
        jq -c '.records[]' "$part" >>"$rows" || return 1;loaded=$((loaded+count))
        ((loaded<total)) || break;((count>0)) || return 1
    done
    jq -s --argjson total "$total" 'unique_by(.id)|select(length==$total)|{totalRecords:$total,records:.}' "$rows" >"$output" || return 1
    jq -e --arg download "$download" '.totalRecords==(.records|length) and (if $download!="" then all(.records[];.downloadId==$download) else true end)' "$output" >/dev/null
}
recovery_correlate() {
    local id="$1" job="$2" history="$TMP_DIR/native-history.json" download selected="$TMP_DIR/native-grabs.json"
    recovery_history "$job" "$history" || return 1
    jq --slurpfile j "$job" '[.records[]|select(.eventType=="grabbed" and .sourceTitle==$j[0].selected.title and .data.guid==$j[0].selected.guid and
      (if $j[0].app=="Sonarr" then .seriesId==$j[0].parentId and .episodeId==$j[0].targets[0] else .movieId==$j[0].parentId end) and
      (.id as $id|($j[0].baselineGrabs|index($id))==null))|.downloadId]|unique' "$history" >"$selected" || return 1
    [[ $(jq length "$selected") == 1 ]] || return 1
    download=$(jq -r '.[0]' "$selected");[[ "$download" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    recovery_history "$job" "$history" "$download" || return 1
    jq -e --slurpfile j "$job" --arg download "$download" '[.records[]|select(.eventType=="grabbed")] as $g |
      ($g|length)>0 and all($g[];.downloadId==$download and .sourceTitle==$j[0].selected.title and .data.guid==$j[0].selected.guid and
      (if $j[0].app=="Sonarr" then .seriesId==$j[0].parentId else .movieId==$j[0].parentId end)) and
      (if $j[0].app=="Sonarr" then ([$g[].episodeId]|sort|unique)==($j[0].targets|sort) else true end)' "$history" >/dev/null || return 1
    recovery_update '.actions[$id].downloadId=$download | if (.actions[$id].attempts // []|length)>0 then .actions[$id].attempts[-1].downloadId=$download | .actions[$id].attempts[-1].outcome="grab_verified" else . end' --arg id "$id" --arg download "$download" || return 1
    recovery_set "$id" downloading 'Selected release correlated through exact native grab history and download ID; original retained while Arr downloads/imports. No repeated grab.'
}
recovery_followup() {
    local id="$1" job="$2" app parent target kind endpoint root current file path added history="$TMP_DIR/native-import-history.json" refs="$TMP_DIR/native-current.json" rows="$TMP_DIR/native-paths.jsonl" valid=true
    app=$(jq -r .app "$job");parent=$(jq -r .parentId "$job")
    if [[ "$app" == Sonarr ]];then kind=episode;endpoint=episodefile;root="$SONARR_MEDIA_ROOT";else kind=movie;endpoint=moviefile;root="$RADARR_MEDIA_ROOT";fi
    local queue="$TMP_DIR/native-followup-queue.json" progress="$TMP_DIR/native-progress.json"
    recovery_api GET '/queue?page=1&pageSize=1000&includeUnknownSeriesItems=true&includeUnknownMovieItems=true' "$queue" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
    jq -e '(.records|type)=="array" and .totalRecords==(.records|length)' "$queue" >/dev/null || return 1
    jq --slurpfile j "$job" '[.records[]|select((.downloadId // ""|ascii_downcase)==($j[0].downloadId|ascii_downcase))|{status,trackedDownloadState,trackedDownloadStatus,sizeleft,statusMessages}]' "$queue" >"$progress" || return 1
    recovery_update 'if (.actions[$id].nativeQueue // []|map({status,trackedDownloadState,trackedDownloadStatus,statusMessages}))==($p[0]|map({status,trackedDownloadState,trackedDownloadStatus,statusMessages})) and $now-(.actions[$id].progressSavedAt // 0)<900 then . else .actions[$id].progressSavedAt=$now | .actions[$id].nativeQueue=$p[0] | .actions[$id].downloadCompletedAt=(if any($p[0][];.status=="completed") then (.actions[$id].downloadCompletedAt // $now) else .actions[$id].downloadCompletedAt end) end' --arg id "$id" --slurpfile p "$progress" --argjson now "$(date +%s)" || return 1
    recovery_history "$job" "$history" "$(jq -r .downloadId "$job")" || return 1
    if jq -e 'any(.records[];.eventType=="downloadFailed" or .eventType=="downloadIgnored")' "$history" >/dev/null;then
        if recovery_prepare_retry "$id" "$job" "$history";then return 0;fi
        recovery_set "$id" review 'Native download failed/ignored; automatic alternative was not authorised. Requires exact archive-failure evidence, unchanged monitored original and fewer than two attempts. Storage/manual/unknown failures stay protected; no blocklist or forced import.';return 0;fi
    local owner="$TMP_DIR/native-followup-owner.json" parent_kind=movie
    [[ "$app" != Sonarr ]] || parent_kind=series
    recovery_api GET "/$parent_kind/$parent" "$owner" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
    jq -e --slurpfile j "$job" '.id==$j[0].parentId and (if $j[0].app=="Sonarr" then .tvdbId else .tmdbId end)==$j[0].externalId' "$owner" >/dev/null || return 1
    if jq -e '.monitored==false' "$owner" >/dev/null;then
        if recovery_observe_external "$id" "$job";then return 0;fi
    fi
    : >"$rows"
    while read -r target;do
        recovery_api GET "/$kind/$target" "$refs" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq -e --argjson target "$target" --argjson parent "$parent" --arg app "$app" '.id==$target and .hasFile==true and (if $app=="Sonarr" then .seriesId==$parent else .id==$parent end)' "$refs" >/dev/null || { valid=false;break; }
        file=$(jq -r --arg app "$app" 'if $app=="Sonarr" then .episodeFileId else .movieFileId end' "$refs")
        if [[ "$file" == "$(jq -r .fileId "$job")" ]] && jq -e '.monitored==false' "$refs" >/dev/null;then recovery_observe_external "$id" "$job";return $?;fi
        [[ "$file" =~ ^[1-9][0-9]*$ && "$file" != "$(jq -r .fileId "$job")" ]] || { valid=false;break; }
        recovery_api GET "/$endpoint/$file" "$refs" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq -e --argjson file "$file" --argjson parent "$parent" --arg app "$app" '.id==$file and (if $app=="Sonarr" then .seriesId==$parent else .movieId==$parent end)' "$refs" >/dev/null || return 1
        path=$(jq -r '.path // ""' "$refs");[[ "$path" == "$root/"* ]] || return 1;path=${path#"$root/"}
        added=$(date -d "$(jq -r '.dateAdded // ""' "$refs")" +%s 2>/dev/null) || return 1
        ((added>=$(jq -r .startedAt "$job"))) || return 1
        jq -e --slurpfile j "$job" --argjson file "$file" --argjson target "$target" --arg path "$root/$path" 'any(.records[];.eventType=="downloadFolderImported" and .downloadId==$j[0].downloadId and
          (.data.fileId|tonumber?)==$file and .data.importedPath==$path and (if $j[0].app=="Sonarr" then .seriesId==$j[0].parentId and .episodeId==$target else .movieId==$target end))' "$history" >/dev/null || return 1
        recovery_file_tool identity "$path" >"$TMP_DIR/native-current-identity.json" || return 1
        jq -e --slurpfile j "$job" '.[0:4]!=$j[0].identity[0:4]' "$TMP_DIR/native-current-identity.json" >/dev/null || return 1
        jq -cn --arg path "$path" --argjson file "$file" --argjson added "$added" --slurpfile identity "$TMP_DIR/native-current-identity.json" '{path:$path,fileId:$file,identity:$identity[0],importedAt:$added}' >>"$rows"
    done < <(jq -r '.targets[]' "$job")
    if [[ "$valid" != true ]];then
        if (( $(date +%s)-$(jq -r .startedAt "$job")>RECOVERY_WAIT_DAYS*86400 ));then recovery_set "$id" review 'Replacement not imported by the recovery deadline. No original was moved/deleted by this script; inspect the exact native download/import outcome.';fi
        if jq -e 'any(.[];.trackedDownloadStatus=="warning" or .trackedDownloadStatus=="error")' "$progress" >/dev/null;then
            recovery_set "$id" review "Native replacement queue needs attention: $(jq -c '[.[].statusMessages[]?.messages[]?]|unique' "$progress" | head -c 1000). No forced import or extra grab."
        fi
        return 0
    fi
    recovery_update '.actions[$id].replacementPaths=[$rows[].path] | .actions[$id].replacementFiles=$rows | .actions[$id].importedAt=([$rows[].importedAt]|min)' --arg id "$id" --slurpfile rows "$rows" || return 1
    recovery_retention "$id" "$job" || return 1
    if jq -e --slurpfile rows "$rows" --slurpfile j "$job" 'all($rows[];. as $r|$r.path as $p| .identity as $i|
       $state[0].files[$p] as $f|$f!=null and $f.identity==$i and $f.issue==null and ($f.verifiedAt // 0)>=$j[0].startedAt)' \
       --slurpfile state "$TMP_DIR/state.json" -n >/dev/null;then
        recovery_update '.actions[$id].replacementVerifiedAt=$now | .actions[$id].resolutionSource="native" | .actions[$id].lastError=null' --arg id "$id" --argjson now "$(date +%s)" || return 1
        recovery_set "$id" recovered 'Replacement completed: exact native download/import/file IDs and current filesystem version passed all planned decode ranges. Arr performed replacement and owns original recycling; script performed no media move/delete.'
    else
        recovery_update '.actions[$id].importedAt=(.actions[$id].importedAt // $now)' --arg id "$id" --argjson now "$(date +%s)" || return 1
        recovery_set "$id" verifying 'Arr imported the exact replacement. Priority resumable integrity verification pending; original recycling is owned by Arr. Native bin retention continues during verification.'
    fi
}
# Selected-release capacity includes packed/unpacked download space plus an
# import copy. Shared filesystem budgets are combined instead of double-counted.
recovery_capacity_ready() {
    local bytes="$1" selected="${2:-false}" path device available need library_device="" reserve=$((10*1024*1024*1024))
    local -a paths=("$MEDIA_HOST_ROOT")
    local -A required=() free=()
    [[ "$bytes" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$selected" != true ]] || paths+=("${RECOVERY_DOWNLOAD_ROOTS[@]}")
    for path in "${paths[@]}";do
        [[ "$path" == "$MEDIA_HOST_ROOT" || "$path" == "$MEDIA_HOST_ROOT/"* ]] && [[ -d "$path" && ! -L "$path" ]] || return 1
        device=$(stat -c %d -- "$path") || return 1
        available=$(df -PB1 -- "$path"|awk 'NR==2 {print $4}') || return 1
        [[ "$available" =~ ^[0-9]+$ ]] || return 1
        need=$bytes;[[ "$path" == "$MEDIA_HOST_ROOT" ]] || need=$((bytes*2))
        if [[ "$path" == "$MEDIA_HOST_ROOT" ]];then library_device=$device
        elif ((need>${required[$device]:-0}));then required[$device]=$need;fi
        if [[ -z "${free[$device]+set}" ]] || ((available<free[$device]));then free[$device]=$available;fi
    done
    required[$library_device]=$(( ${required[$library_device]:-0}+bytes ))
    for device in "${!required[@]}";do
        # Ten percent allows for native size estimates/filesystem overhead.
        ((free[$device]>=required[$device]+required[$device]/10+reserve)) || return 1
    done
}
recovery_retention() {
    local id="$1" job="$2" cfg="$TMP_DIR/native-retention.json" endpoint=/config/mediamanagement now days imported deadline attention
    now=$(date +%s)
    if (( now-$(jq -r '.binPolicyCheckedAt // 0' "$job")>=43200 ));then
        [[ "$RECOVERY_ROOT" != */v5 ]] || endpoint=/settings/mediamanagement
        recovery_api GET "$endpoint" "$cfg" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq -e '(.recycleBin|type)=="string" and (.recycleBin|startswith("/")) and (.recycleBinCleanupDays|type)=="number" and .recycleBinCleanupDays>=0 and .recycleBinCleanupDays==(.recycleBinCleanupDays|floor)' "$cfg" >/dev/null || return 1
        recovery_update '.actions[$id].binRetentionDays=$c[0].recycleBinCleanupDays | .actions[$id].binPolicyCheckedAt=$now' --arg id "$id" --slurpfile c "$cfg" --argjson now "$now" || return 1
    fi
    days=$(jq -r --arg id "$id" '.actions[$id].binRetentionDays // 0' "$RECOVERY_FILE")
    imported=$(jq -r --arg id "$id" '.actions[$id].importedAt // 0' "$RECOVERY_FILE")
    if ((imported>0 && days>0));then
        deadline=$((imported+days*86400));attention=$((deadline-(days*86400/2<43200 ? days*86400/2 : 43200)))
    else deadline=0;attention=$(( (imported>0 ? imported : now)+86400 ));fi
    recovery_update '.actions[$id].verificationDeadlineAt=$deadline | .actions[$id].verificationAttentionAt=$attention' --arg id "$id" --argjson deadline "$deadline" --argjson attention "$attention"
}
# Read current native/physical identities independently of the selected download.
# Full audit proof can close externally fixed media without claiming our grab
# caused the fix. Native unmonitoring cancels only while the original still exists.
recovery_observe_external() {
    local id="$1" job="$2" refs="$TMP_DIR/external-target.json" owner="$TMP_DIR/external-owner.json" rows="$TMP_DIR/external-rows.jsonl" app parent kind endpoint parent_kind target file path root added old_same=true monitored=true all_verified=true
    app=$(jq -r .app "$job");parent=$(jq -r .parentId "$job")
    if [[ "$app" == Sonarr ]];then kind=episode;endpoint=episodefile;parent_kind=series;root="$SONARR_MEDIA_ROOT";else kind=movie;endpoint=moviefile;parent_kind=movie;root="$RADARR_MEDIA_ROOT";fi
    recovery_api GET "/$parent_kind/$parent" "$owner" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
    jq -e --slurpfile j "$job" '.id==$j[0].parentId and (if $j[0].app=="Sonarr" then .tvdbId else .tmdbId end)==$j[0].externalId' "$owner" >/dev/null || return 1
    jq -e '.monitored==true' "$owner" >/dev/null || monitored=false
    : >"$rows"
    while read -r target;do
        recovery_api GET "/$kind/$target" "$refs" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq -e --argjson target "$target" --argjson parent "$parent" --arg app "$app" '.id==$target and .hasFile==true and (if $app=="Sonarr" then .seriesId==$parent else .id==$parent end)' "$refs" >/dev/null || return 1
        jq -e '.monitored==true' "$refs" >/dev/null || monitored=false
        file=$(jq -r --arg app "$app" 'if $app=="Sonarr" then .episodeFileId else .movieFileId end' "$refs")
        [[ "$file" =~ ^[1-9][0-9]*$ ]] || return 1
        recovery_api GET "/$endpoint/$file" "$refs" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq -e --argjson file "$file" --argjson parent "$parent" --arg app "$app" '.id==$file and (if $app=="Sonarr" then .seriesId==$parent else .movieId==$parent end)' "$refs" >/dev/null || return 1
        path=$(jq -r '.path // ""' "$refs");[[ "$path" == "$root/"* ]] || return 1;path=${path#"$root/"}
        added=$(date -d "$(jq -r '.dateAdded // ""' "$refs")" +%s 2>/dev/null) || added=0
        recovery_file_tool identity "$path" >"$TMP_DIR/external-identity.json" || return 1
        jq -cn --arg path "$path" --argjson file "$file" --argjson added "$added" --slurpfile i "$TMP_DIR/external-identity.json" '{path:$path,fileId:$file,identity:$i[0],importedAt:$added}' >>"$rows"
        [[ "$file" == "$(jq -r .fileId "$job")" ]] && jq -e --slurpfile j "$job" '.==$j[0].identity' "$TMP_DIR/external-identity.json" >/dev/null || old_same=false
        jq -e --arg path "$path" --slurpfile i "$TMP_DIR/external-identity.json" --slurpfile j "$job" '.files[$path] as $f|$f.identity==$i[0] and $f.issue==null and ($f.verifiedAt // 0)>=$j[0].startedAt and $f.coverage=="all_planned_segments_decoded"' "$TMP_DIR/state.json" >/dev/null || all_verified=false
    done < <(jq -r '.targets[]' "$job")
    if [[ "$old_same" == true && "$monitored" == false ]];then
        recovery_set "$id" cancelled 'Recovery cancelled: native monitoring is now off while the exact original remains present. Monitoring/user intent preserved; no replacement or deletion performed.';return $?
    fi
    if [[ "$all_verified" == true ]];then
        recovery_update '.actions[$id].replacementFiles=$rows | .actions[$id].replacementPaths=[$rows[].path] | .actions[$id].replacementVerifiedAt=$now | .actions[$id].resolutionSource="external" | .actions[$id].lastError=null' --arg id "$id" --slurpfile rows "$rows" --argjson now "$(date +%s)" || return 1
        if [[ "$old_same" == true ]];then recovery_set "$id" resolved 'Recovery no longer required: the unchanged current original completed all planned decode ranges successfully. No replacement attributed to this script.'
        else recovery_set "$id" recovered 'External recovery verified: exact current Arr/external IDs and physical replacement completed all planned decode ranges. Recovery guards released; replacement was not attributed to this script.';fi
        return $?
    fi
    if [[ "$old_same" == true ]];then
        if jq -e --slurpfile rows "$rows" 'all($rows[];.path as $p|$state[0].files[$p].issue==null)' --slurpfile state "$TMP_DIR/state.json" -n >/dev/null;then
            recovery_update '.actions[$id].replacementFiles=$rows | .actions[$id].replacementPaths=[$rows[].path] | .actions[$id].resolutionSource="recheck"' --arg id "$id" --slurpfile rows "$rows" || return 1
            recovery_set "$id" verifying 'Original warning cleared on focused rechecks; a complete current-file decode cycle is still required. No replacement attributed or media changed.';return $?
        fi
        return 1
    fi
    recovery_update '.actions[$id].replacementFiles=$rows | .actions[$id].replacementPaths=[$rows[].path] | .actions[$id].resolutionSource="external" | .actions[$id].importedAt=([$rows[].importedAt|select(.>0)]|min // $now)' --arg id "$id" --slurpfile rows "$rows" --argjson now "$(date +%s)" || return 1
    recovery_retention "$id" "$job" || return 1
    recovery_set "$id" verifying 'External/current replacement detected by exact Arr and physical identities. Attribution is unproven; priority full verification pending. No download replay or monitoring override.'
}
# An alternative is permitted only for an exact, proven native archive/download
# failure, with unchanged monitored original, cooldown, fresh evidence and budgets.
recovery_prepare_retry() {
    local id="$1" job="$2" history="$3" message original="$TMP_DIR/retry-original.json" candidate="$TMP_DIR/retry-candidate.json" now
    now=$(date +%s)
    jq -e --slurpfile j "$job" '[.records[]|select(.eventType=="downloadFailed")] as $fail|($fail|length)>0 and all(.records[];.eventType!="downloadIgnored" and .eventType!="downloadFolderImported") and
      all($fail[];.downloadId==$j[0].downloadId and (if $j[0].app=="Sonarr" then .seriesId==$j[0].parentId and (.episodeId as $e|$j[0].targets|index($e))!=null else .movieId==$j[0].parentId end)) and
      (if $j[0].app=="Sonarr" then ([$fail[].episodeId]|sort|unique)==($j[0].targets|sort) else true end)' "$history" >/dev/null || return 1
    message=$(jq -r '[.records[]|select(.eventType=="downloadFailed")|.data.message // ""]|join("; ")' "$history")
    [[ "$message" =~ [Cc][Rr][Cc]|[Cc]hecksum|[Uu]npack|[Rr]epair|[Mm]issing\ articles|[Ee]ncrypted|[Pp]assword|[Dd]amaged\ archive ]] || return 1
    grep -Eiq 'permission|denied|space|disk|I/O|input/output|manually|ignored|cancel' <<<"$message" && return 1
    jq -e --argjson limit "$RECOVERY_MAX_ATTEMPTS" '(.attempts // []|length)<$limit and .selected.guid!=null' "$job" >/dev/null || return 1
    jq '{key:.path,value:{identity,issue:.finding}}' "$job" >"$candidate"
    recovery_plan "$candidate" "$original" || return 1
    jq -e --slurpfile j "$job" '{identity,fileId,parentId,targets,externalId,profile}==($j[0]|{identity,fileId,parentId,targets,externalId,profile})' "$original" >/dev/null || return 1
    recovery_update '.actions[$id].attempts=(if (.actions[$id].attempts // []|length)==0 then [{at:.actions[$id].grabSentAt,guid:.actions[$id].selected.guid,title:.actions[$id].selected.title,downloadId:.actions[$id].downloadId}] else .actions[$id].attempts end) | .actions[$id].attempts[-1].outcome="native_download_failed" | .actions[$id].failedReleases=((.actions[$id].failedReleases // [])+[{guid:.actions[$id].selected.guid,title:.actions[$id].selected.title}]) |
      .actions[$id].retryAt=$retry | .actions[$id].selected=null | .actions[$id].downloadId=null | .actions[$id].selectionAt=0' --arg id "$id" --argjson retry "$((now+RECOVERY_RETRY_SECONDS))" || return 1
    recovery_set "$id" retry_wait "Verified native download failure: ${message:0:500}. Original unchanged; one alternative may be selected after the four-hour cooldown, fresh evidence and shared budgets. Failed release excluded."
}

# Fair, deadline-aware targeted work. Three replacement slots plus one stale
# evidence slot when needed; timestamps come from actual decoder work, not polls.
recovery_schedule() {
    jq -n --slurpfile j "$RECOVERY_FILE" --slurpfile state "$TMP_DIR/state.json" --argjson now "$(date +%s)" '
      [$j[0].actions|to_entries[]|select(.value.status=="verifying")|. as $job|
       .value.replacementPaths[]? as $path|{path:$path,deadline:($job.value.verificationDeadlineAt // 0),attempt:($state[0].files[$path].lastAttemptAt // 0)}]|
      unique_by(.path)|sort_by(.attempt,(if .deadline>0 then .deadline else 9999999999 end)) as $replacements|
      [$j[0].actions[]|select(.status=="required" or .status=="blocked" or .status=="retry_wait")|. as $job|
       $state[0].files[.path] as $f|select($f.identity==$job.identity and $f.issue.kind=="decode_error" and $f.issue.confirmed==true and
       ($f.issue.lastSeen // 0)<$now-48*3600 and ($f.lastAttemptAt // 0)<$now-86400)|{path:.path,attempt:($f.lastAttemptAt // 0)}]|
      unique_by(.path)|sort_by(.attempt) as $evidence|
      {recheckAfter:([$j[0].actions[]|select(.status=="verifying" and .resolutionSource=="recheck")|. as $job|.replacementPaths[]?|{key:.,value:$job.startedAt}]|from_entries),evidencePaths:[$evidence[:1][].path],paths:([$replacements[:(if ($evidence|length)>0 then 3 else 4 end)][].path]+[$evidence[:1][].path])}' >"$TMP_DIR/recovery-schedule.json"
}

recovery_resume() (
    if [[ "${ARR_MUTATION_COORDINATION_ACTIVE:-false}" != true ]];then recovery_resume_core "$@";return $?;fi
    local coordinated_app fd
    coordinated_app=$(jq -r --arg id "$1" '.actions[$id].app' "$RECOVERY_FILE") || return 1
    case "$coordinated_app" in Sonarr|Radarr) ;;*) return 1;;esac
    exec {fd}>"${ARR_MUTATION_LOCK_DIR:-/run}/arr-mutations-$coordinated_app.lock" || return 1
    flock -n "$fd" || { printf '%s recovery deferred: another coordinated script owns Arr changes\n' "$coordinated_app" >&2;return 0; }
    recovery_resume_core "$@"
)

recovery_resume_core() {
    local id="$1" job="$TMP_DIR/native-job.json" status response="$TMP_DIR/native-response.json" query selected="$TMP_DIR/native-selected.json" fresh="$TMP_DIR/native-fresh.json" candidate="$TMP_DIR/native-candidate.json" history="$TMP_DIR/native-baseline.json" ready
    jq --arg id "$id" '.actions[$id]' "$RECOVERY_FILE" >"$job" || return 1
    status=$(jq -r .status "$job");[[ "$status" != recovered && "$status" != cancelled && "$status" != resolved ]] || return 0
    recovery_connection "$(jq -r .app "$job")" || return 1
    if [[ "$status" == grab_intent || "$status" == review ]] && jq -e '.selected!=null and .grabSentAt>0 and (.downloadId // "")==""' "$job" >/dev/null;then
        recovery_correlate "$id" "$job" || { if recovery_observe_external "$id" "$job";then return 0;fi;recovery_set "$id" review 'Grab outcome uncertain: exact native download identity not established. Request not replayed; original remains in place.';return 0; }
        jq --arg id "$id" '.actions[$id]' "$RECOVERY_FILE" >"$job";status=downloading
    fi
    if [[ $(jq -r '.resolutionSource // ""' "$job") == recheck ]] && recovery_observe_external "$id" "$job";then return 0;fi
    if jq -e '(.downloadId // "")!=""' "$job" >/dev/null;then
        if recovery_followup "$id" "$job";then return 0;fi
        recovery_api_diagnostic "$id" 'Native download/import correlation unavailable; checking exact current media without attributing the replacement' || return 1
        recovery_observe_external "$id" "$job";return $?
    fi
    if recovery_observe_external "$id" "$job";then return 0;fi
    [[ "$status" != retry_wait ]] || (( $(date +%s)>=$(jq -r '.retryAt // 0' "$job") )) || return 0
    [[ "$status" == required || "$status" == selected || "$status" == blocked || "$status" == retry_wait ]] || return 0
    [[ "$RECOVERY_ALLOW_GRAB" == true ]] && recovery_new_window_open || return 0
    jq -e --slurpfile j "$job" --argjson cutoff "$(( $(date +%s)-48*3600 ))" '.files[$j[0].path] as $f|$f.identity==$j[0].identity and $f.issue.confirmed==true and $f.issue.confirmedRuns>=2 and $f.issue.lastSeen>=$cutoff' "$TMP_DIR/state.json" >/dev/null || { recovery_set "$id" blocked 'Fresh unchanged-file corruption evidence required before release selection; original retained';return 0; }
    local last
    last=$(jq -r '.selectionAt // 0' "$job");(( $(date +%s)-last>=86400 )) || return 0
    jq '{key:.path,value:{identity,issue:.finding}}' "$job" >"$candidate"
    recovery_plan "$candidate" "$fresh" || { recovery_set "$id" blocked 'Original ownership/identity/monitoring/profile/health no longer qualifies. Original unchanged; no grab.';return 0; }
    jq -e --slurpfile j "$job" '{app,parentId,fileId,identity,targets,externalId,profile}==($j[0]|{app,parentId,fileId,identity,targets,externalId,profile})' "$fresh" >/dev/null || { recovery_set "$id" blocked 'Profile or exact original identity changed; no grab. Reconfirm evidence under current rules.';return 0; }
    query="movieId=$(jq -r .parentId "$job")";[[ $(jq -r .app "$job") != Sonarr ]] || query="episodeId=$(jq -r '.targets[0]' "$job")"
    recovery_update '.actions[$id].selectionAt=$now' --arg id "$id" --argjson now "$(date +%s)" || return 1
    recovery_api GET "/release?$query" "$response" && [[ "$RECOVERY_HTTP" == 200 ]] && jq -e 'type=="array"' "$response" >/dev/null || { recovery_set "$id" blocked 'Native interactive release search unavailable; original retained; selection retries at most daily inside approved windows.';return 0; }
    jq -n --slurpfile job "$job" --slurpfile releases "$response" '{job:$job[0],releases:$releases[0]}' | recovery_select_release >"$selected" || return 1
    jq -e 'type=="object"' "$selected" >/dev/null || { recovery_set "$id" blocked 'No exact alternative release satisfies profile, language, quality/revision, score and identity safeguards. Original retained; no fallback deletion or forced import.';return 0; }
    recovery_capacity_ready "$(jq -r .size "$selected")" true || { recovery_set "$id" blocked 'Selected replacement exceeds download/destination filesystem budget or a configured download mount is unavailable. Original retained; no grab.';return 0; }
    recovery_retention "$id" "$job" || { recovery_api_diagnostic "$id" 'Native recycling retention could not be validated';return 1; }
    recovery_update '.actions[$id].selected=$selected[0]' --arg id "$id" --slurpfile selected "$selected" || return 1
    recovery_set "$id" selected 'Exact alternative selected; only existing-file upgrade/cutoff rejections may be bypassed. Profile minimums and identity remain enforced.' || return 1
    # Search may take time. Re-read quiet native state and exact original again
    # before the sole mutation. No app-wide configuration/monitoring override.
    recovery_runtime_matches && recovery_new_window_open && workload_guard && recovery_plan "$candidate" "$fresh" || return 0
    jq -e --slurpfile j "$job" '{parentId,fileId,identity,targets,externalId,profile}==($j[0]|{parentId,fileId,identity,targets,externalId,profile})' "$fresh" >/dev/null || return 1
    ((RECOVERY_NEW_GRABS<RECOVERY_MAX_NEW_PER_RUN)) || return 0
    jq -e --argjson cutoff "$(( $(date +%s)-7*86400 ))" --argjson limit "$RECOVERY_MAX_NEW_PER_WEEK" '[.actions[]|if (.attempts // []|length)>0 then .attempts[]|select(.at>=$cutoff) else select((.grabSentAt // 0)>=$cutoff) end]|length<$limit' "$RECOVERY_FILE" >/dev/null || return 0
    recovery_history "$job" "$history" || return 1
    recovery_update '.actions[$id].baselineGrabs=[$h[0].records[]|select(.eventType=="grabbed")|.id] | .actions[$id].grabSentAt=$now | .actions[$id].attempts=((.actions[$id].attempts // [])+[{at:$now,guid:.actions[$id].selected.guid,title:.actions[$id].selected.title,indexerId:.actions[$id].selected.indexerId,outcome:"intent"}])' --arg id "$id" --argjson now "$(date +%s)" --slurpfile h "$history" || return 1
    RECOVERY_NEW_GRABS=$((RECOVERY_NEW_GRABS+1))
    recovery_set "$id" grab_intent 'Release grab intent saved before one POST /release. Original remains in library; uncertain outcomes will not be replayed.' || return 1
    jq '.payload' "$selected" >"$TMP_DIR/native-grab-payload.json"
    recovery_window_open || return 0
    recovery_api POST /release "$response" "$TMP_DIR/native-grab-payload.json" || true
    jq --arg id "$id" '.actions[$id]' "$RECOVERY_FILE" >"$job"
    recovery_correlate "$id" "$job" || recovery_set "$id" review 'Grab sent once; exact native download identity not yet established. No replay; follow-up reads history before further action.'
}
recovery_process() {
    [[ "$AUTO_RECOVERY_ENABLED" == true ]] || return 0
    recovery_platform_ready && recovery_valid || { RECOVERY_NOTE='Recovery platform/journal unavailable; no mutation allowed';return 1; }
    recovery_update '.actions |= with_entries(select((.value.status!="recovered" and .value.status!="resolved" and .value.status!="cancelled") or (.value.replacementVerifiedAt // .value.updatedAt // .value.startedAt // 0)>=$cutoff))' --argjson cutoff "$(( $(date +%s)-365*86400 ))" || return 1
    RECOVERY_DEADLINE=$(( $(date +%s)+RECOVERY_MAX_SECONDS ))
    local fd hold id row count=0 rc=0 candidate="$TMP_DIR/native-candidate-plan.json" plan="$TMP_DIR/native-new-plan.json" now
    exec {fd}>"$ARR_BACKUP_GATE" || return 1;flock -s -n "$fd" || { exec {fd}>&-;return 0; }
    exec {hold}>/tmp/arr_metadata_quarantine.lock || { exec {fd}>&-;return 1; };flock -n "$hold" || { exec {fd}>&-;exec {hold}>&-;return 0; }
    RECOVERY_NEW_GRABS=0
    while read -r id;do (( $(date +%s)<RECOVERY_DEADLINE )) || break;recovery_update ' if $now-(.actions[$id].checkedAt // 0)>=900 then .actions[$id].checkedAt=$now else . end ' --arg id "$id" --argjson now "$(date +%s)" || break;if ! recovery_resume "$id";then
        if ! jq -e --arg id "$id" --argjson cutoff "$(( $(date +%s)-120 ))" '(.actions[$id].lastError.at // 0)>=$cutoff' "$RECOVERY_FILE" >/dev/null;then recovery_api_diagnostic "$id" 'Bounded native API or identity/history evidence step incomplete' || true;fi
        rc=1
    fi;done < <(jq -r '.actions|to_entries|sort_by(.value.checkedAt // 0)|.[]|select(.value.status!="recovered" and .value.status!="resolved" and .value.status!="cancelled")|.key' "$RECOVERY_FILE"|sed -n '1,4p')
    now=$(date +%s)
    if [[ "$RECOVERY_ALLOW_GRAB" == true ]] && recovery_new_window_open && recovery_runtime_matches;then
      while IFS= read -r row;do
        ((count<RECOVERY_MAX_NEW_PER_RUN && $(date +%s)<RECOVERY_DEADLINE)) || break
        jq -e --argjson cutoff "$((now-7*86400))" --argjson limit "$RECOVERY_MAX_NEW_PER_WEEK" '[.actions[]|if (.attempts // []|length)>0 then .attempts[]|select(.at>=$cutoff) else select((.grabSentAt // 0)>=$cutoff) end]|length<$limit' "$RECOVERY_FILE" >/dev/null || break
        printf '%s\n' "$row" >"$candidate";id=$(jq -c '[.key,.value.identity]' "$candidate"|sha256sum|awk '{print $1}')
        jq -e --arg id "$id" '.actions[$id]!=null' "$RECOVERY_FILE" >/dev/null && continue
        recovery_plan "$candidate" "$plan" || continue
        jq -e --slurpfile p "$plan" --argjson cutoff "$((now-30*86400))" 'all(.actions[];.app!=$p[0].app or .parentId!=$p[0].parentId or .startedAt<$cutoff)' "$RECOVERY_FILE" >/dev/null || continue
        recovery_update '.actions[$id]=$p[0]' --arg id "$id" --slurpfile p "$plan" || { rc=1;break; }
        count=$((count+1));recovery_resume "$id" || rc=1
      done < <(jq -c --argjson cutoff "$((now-48*3600))" '.files|to_entries[]|select((.value.issue.lastSeen // 0)>=$cutoff and .value.issue.kind=="decode_error" and .value.issue.confirmed==true and (.value.issue.confirmedRuns // 0)>=2 and .value.issue.identity==.value.identity and (.value.replacementPending // false)==false)' "$TMP_DIR/state.json")
    fi
    exec {hold}>&-;exec {fd}>&-;return "$rc"
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
        if self.cfg.get('targeted'):
            for rel in self.cfg.get('recoveryPriority',[])[:4]:
                if os.path.normpath(rel)!=rel or rel.startswith('/') or rel.split('/')[0] not in self.cfg['libraries']:raise ValueError('unsafe replacement path')
                p=os.path.join(root,rel)
                try:
                    if os.path.realpath(p)!=p:raise ValueError('symlinked replacement')
                    st=os.stat(p,follow_symlinks=False)
                    if not stat.S_ISREG(st.st_mode):raise ValueError('not regular replacement')
                    self.found.add(rel);self.seen.add(rel);current=identity(st);old=self.state['files'].get(rel)
                    if not old or old['identity']!=current:
                        self.state['files'][rel]={'identity':current,'probeAt':0,'verifiedAt':0,'offset':0,'chunkSeconds':self.cfg['segmentSeconds'],'notBefore':0,'cycleLane':'new'}
                except OSError:self.stats['inventoryErrors']+=1
            for rel,after in self.cfg.get('recheckAfter',{}).items():
                e=self.state['files'].get(rel)
                if rel in self.found and e and 0<e.get('verifiedAt',0)<after:
                    e.update(verifiedAt=0,offset=0,notBefore=0)
            for rel in self.cfg.get('evidencePaths',[]):
                e=self.state['files'].get(rel)
                if rel in self.found and e and e.get('issue') and e['issue'].get('identity')==e['identity']:
                    e['notBefore']=0
                    if e['issue'].get('offset') is not None:e['offset']=e['issue']['offset']
            self.stats.update(inventoryFiles=len(self.found),inventoryComplete=False,targeted=True)
            self.checkpoint(True);return
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
                if path in self.cfg.get('evidencePaths',[]) and outcome!='recheck':break
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
        for path in self.cfg.get('evidencePaths',[]):
            if path in self.found and not self.stopped():self.work(path);self.checkpoint()
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
                if path in self.cfg.get('evidencePaths',[]):continue
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
    ARR_MUTATION_COORDINATION_ACTIVE=true
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
        'When enabled: two distinct confirming audit runs, exact monitored Arr file/target IDs, no active work, original retained in place, durable intents, one exact release grab, full replacement verification.' \
        'Originals remain in their library locations until Arr replaces/recycles them. No repair_hold, file deletion or forced import. Required/blocked/completed replacement updates are grouped.' \
        'Timeouts, read errors, unsupported codecs, unmonitored/ambiguous/unmanaged media never authorize recovery.';return 0;;
      --status) [[ ! -f "$STATUS_DIR/media_integrity_audit.json" ]] || jq . "$STATUS_DIR/media_integrity_audit.json";return 0;;
      --inventory-only) MODE=inventory;;
      --recovery-status) recovery_valid || return 1; jq '{schema,workflow,actions:[.actions|to_entries[]|{id:.key,app:.value.app,path:.value.path,status:.value.status,reason:.value.reason,parentId:.value.parentId,fileId:.value.fileId,targets:.value.targets,selected:.value.selected.title,downloadId:.value.downloadId,replacementFiles:.value.replacementFiles,replacementVerifiedAt:.value.replacementVerifiedAt,events:.value.events}]}' "$RECOVERY_FILE";return 0;;
      --recover-only) MAX_RUNTIME_SECONDS=210;[[ "$AUTO_RECOVERY_ENABLED" == true ]] || { printf 'Automatic media recovery disabled; observation only.\n'; return 0; };MODE=recover;;
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
    for flag in "$LOG_FILE" "$LOG_FILE.1" "$LOG_FILE.2" "$STATE_DIR/notified.json" "$STATE_DIR/pending-notification.json" "$STATE_DIR/latest-report.txt" "$RECOVERY_FILE" "$RECOVERY_PREVIOUS_FILE"; do [[ ! -L "$flag" ]] || return 1;done
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
        if ! recovery_process; then RECOVERY_NOTE='Native recovery follow-up incomplete; original/library state remains Arr-managed. Exact job/checkpoints retained; no uncertain request replayed';fi
    fi
    recovery_schedule || return 1
    if [[ "$MODE" == recover ]] && ! jq -e '.paths|length>0' "$TMP_DIR/recovery-schedule.json" >/dev/null;then
        write_report OK 'Bounded native recovery follow-up; no imported replacement awaiting decoder work';return $?
    fi
    toolset=$(timeout 12 docker exec --user 99:100 "$BAZARR_CONTAINER" sh -c \
      'set -e; command -v python3 >/dev/null; command -v ffprobe >/dev/null; command -v ffmpeg >/dev/null; command -v nice >/dev/null; command -v ionice >/dev/null; ffmpeg -version | sed -n "1p"; ffprobe -version | sed -n "1p"') || {
        write_report FAILED 'Bazarr tool runtime unavailable; no media file was checked';return 1; }
    worker_budget=$((MAX_RUNTIME_SECONDS-($(date +%s)-invocation_started)))
    if ((worker_budget<60)); then write_report DEFERRED 'Preflight/recovery consumed the scan budget; coverage resumes on the next schedule';return 0;fi
    if [[ "$MODE" == recover ]];then worker_budget=$((worker_budget<75 ? worker_budget : 75));SEGMENT_WALL_SECONDS=30;FILE_SLICE_SECONDS=35;fi
    libraries=$(printf '%s\n' "${LIBRARY_SUBDIRS[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')
    input="$TMP_DIR/input.json"
    if [[ -f "$RECOVERY_FILE" ]]; then cp "$RECOVERY_FILE" "$TMP_DIR/recovery-input.json";else printf '{"schema":1,"actions":{}}' >"$TMP_DIR/recovery-input.json";fi
    jq -n --slurpfile state "$TMP_DIR/state.json" --slurpfile recovery "$TMP_DIR/recovery-input.json" --slurpfile schedule "$TMP_DIR/recovery-schedule.json" --arg root "$MEDIA_CONTAINER_ROOT" --arg hostRoot "$MEDIA_HOST_ROOT" \
      --argjson libraries "$libraries" --arg toolset "$toolset" --arg mode "$MODE" \
      --argjson targeted "$( [[ "$MODE" == recover ]] && printf true || printf false )" --argjson budget "$worker_budget" --argjson quick "$QUICK_PASS_MAX_SECONDS" --argjson threads "$VIDEO_THREADS" --argjson memory "$DECODER_MEMORY_MIB" \
      --argjson segment "$SEGMENT_MEDIA_SECONDS" --argjson wall "$SEGMENT_WALL_SECONDS" --argjson slice "$FILE_SLICE_SECONDS" \
      --argjson recheck "$RECHECK_DAYS" --argjson settle "$SETTLE_SECONDS" --argjson max "$MAX_STATE_BYTES" \
      '{state:$state[0],config:{root:$root,hostRoot:$hostRoot,libraries:$libraries,toolset:$toolset,mode:$mode,
       targeted:$targeted,budgetSeconds:$budget,quickBudgetSeconds:$quick,threads:$threads,memoryMiB:$memory,segmentSeconds:$segment,segmentWallSeconds:$wall,
       fileSliceSeconds:$slice,recheckDays:$recheck,settleSeconds:$settle,maxStateBytes:$max,recoveryPriority:$schedule[0].paths,evidencePaths:$schedule[0].evidencePaths,recheckAfter:($schedule[0].recheckAfter // {})}}' >"$input" || return 1
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
        if jq -e '.activeFindings>0 or .inventoryErrors>0 or (.inventoryComplete!=true and (.targeted // false)!=true)' "$TMP_DIR/stats.json" >/dev/null; then status=WARNING;fi
        [[ "$MODE" != inventory ]] || status=INVENTORY_ONLY
    fi
    if [[ "$MODE" == recover && "$status" != FAILED ]];then
        RECOVERY_ALLOW_GRAB=false;RECOVERY_MAX_SECONDS=20;recovery_process || RECOVERY_NOTE='Replacement verification follow-up incomplete; exact job remains protected'
    fi
    write_report "$status" "$reason" || return 1
    [[ "$status" != FAILED ]]
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
