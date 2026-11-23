#!/bin/bash
# shellcheck disable=SC2034
arrayStarted=true
###############################################################################
# Media Integrity Audit v1.0.0 -- personal Unraid User Script
#
# PURPOSE / USE CASE
# ------------------
# Find unreadable containers and repeatable audio/video decoder errors before
# playback. Read only movies/, series/ and formula1/ under /mnt/user/media using
# Bazarr's existing FFprobe, FFmpeg and Python. No package/image/startup/config
# installation or modification. No media deletion, rename, repair or Arr action.
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
# One grouped run summary contains actions, counts, named findings, evidence,
# resumable/deferred work and recovery reasons. No per-file emails. A failed email
# stays in a single pending outbox; retained active/recovery state feeds the next
# summary. Clean reruns within 24h with unchanged evidence are suppressed.
#
# STATE / LOGS / CLI
# ------------------
# Own /mnt/vault/cloud/logs/script/media_integrity_audit: one compressed JSON state,
# one previous validated state, an overwritten latest-report.txt, notification
# outbox/receipt and a 1 MiB log with two backups (30-day backup retention).
# Checkpoint at most once per minute and at completion; incomplete last ranges
# may be repeated after interruption. Never create a shadow vault under RAM.
# --help / --version: no scans. --status: saved evidence only, no Docker/media I/O.
# --inventory-only: inventory/stat only; may wake disks and updates audit state,
# but performs no FFprobe/decoding and sends no normal summary. No argument: real
# scheduled read-only scan. No scan, timeout or error changes media permissions.
###############################################################################
set -uo pipefail
umask 077
readonly SCRIPT_VERSION="1.0.0"
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
TMP_DIR="" WORKER_PID="" WORKER_TOKEN="" WORKER_FINISHED=false
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
    temp=$(mktemp "$STATE_DIR/.report.XXXXXX") || return 1
    jq -n --slurpfile state "$TMP_DIR/state.json" --slurpfile stats "$TMP_DIR/stats.json" \
        --arg status "$status" --arg mode "$MODE" --arg reason "$reason" --arg recovery "$RECOVERY_NOTE" \
        --arg root "$MEDIA_HOST_ROOT" --argjson now "$now" --argjson sent "$sent" --argjson max "$NOTIFY_MAX_ITEMS" \
        '($state[0].files // {} | to_entries) as $files |
         [$files[]|select(.value.issue!=null)] as $issues |
         [($state[0].resolved // [])[]|select(.resolvedAt>$sent)] as $fixed |
         ($stats[0]) as $r |
         ([$state[0].runs[]? | .decodeWallSeconds // 0]|add // 0) as $wall |
         ([$state[0].runs[]? | .mediaSecondsDecoded // 0]|add // 0) as $media |
         ([$files[]|select((.value.verifiedAt // 0)==0)|((.value.duration // 0)-(.value.offset // 0))]|add // 0) as $remaining |
         ([$files[]|select((.value.duration // 0)<=0)]|length) as $unknown |
         {schema:1,name:"media_integrity_audit",status:$status,mode:$mode,epoch:$now,
          stats:$r,activeFindings:($issues|length),recoveries:($fixed|length),
          findingKeys:[$issues[]|.value.issue.id+":"+.value.issue.kind+":"+(.value.issue.confirmed|tostring)],
          recoveryKeys:[$fixed[]|.id+":"+(.resolvedAt|tostring)],
          summary:("Media integrity audit: "+$status+"; quick="+(($r.quickPassed // 0)|tostring)+"; ranges="+(($r.segmentsPassed // 0)|tostring)+"; completed cycles="+(($r.cyclesCompleted // 0)|tostring)+"; findings="+($issues|length|tostring)),
          body:([
            "Media integrity audit: "+$status+"; mode="+$mode,
            "Scope: "+$root+"/{movies,series,formula1}; videos plus all their selected audio streams.",
            "Inventoried: "+(($r.inventoryFiles // 0)|tostring)+"; complete inventory: "+(($r.inventoryComplete // false)|tostring)+"; inventory errors: "+(($r.inventoryErrors // 0)|tostring),
            "This run: quick checks passed="+(($r.quickPassed // 0)|tostring)+"; decode ranges passed="+(($r.segmentsPassed // 0)|tostring)+"; complete planned-range cycles="+(($r.cyclesCompleted // 0)|tostring),
            "Pending initial/replacement coverage: "+([$files[]|select((.value.verifiedAt // 0)==0 and .value.cycleLane!="old")]|length|tostring)+"; pending periodic cycles: "+(($r.pendingPeriodic // 0)|tostring)+"; in-progress files: "+(($r.inProgress // 0)|tostring)+"; deferred files: "+(($r.deferredFiles // 0)|tostring)+"; active findings: "+($issues|length|tostring)+"; newly reported recoveries/removals: "+($fixed|length|tostring),
            "Elapsed: "+(($r.elapsedSeconds // 0)|tostring)+" seconds. Stop/defer reason: "+$reason,
            "Action: read-only inventory/probing/decoding and saved resumable progress. No media was deleted, repaired, moved, renamed or chmod/chowned; no Docker configuration or Arr action.",
            "Coverage: quick probes/sample ranges are not full verification. A completed cycle means all planned overlapping ranges decoded, not one linear decode or a known-good checksum. Pending files remain unverified.",
            (if $wall>0 and $media>0 then
              "Partial backlog estimate at observed decode rate: "+((($remaining*$wall/$media/3600)*10|round)/10|tostring)+" decoder hours for known pending durations. Unknown-duration files excluded: "+($unknown|tostring)+". Codecs, retries and workload deferrals can change this substantially."
             else "Decode throughput not established; no full-library completion estimate yet. Unknown-duration files: "+($unknown|tostring) end),
            "Retry/settle holds remain pending, not healthy; exact per-file progress and retry epochs are retained in compressed state.",
            "ISO/IMG not decoded: "+(($r.unsupportedImages // 0)|tostring)+"; symlinks skipped: "+(($r.symlinksSkipped // 0)|tostring),
            ""
          ] + (if $recovery!="" then ["State recovery: "+$recovery,""] else [] end) +
          ([$issues|sort_by((.value.issue.confirmed // false)|not)|.[:$max][]|
            "- "+.value.issue.kind+(if .value.issue.confirmed then " [repeatable decoder error; review required]" else " [unverified/read evidence; not confirmed corruption]" end)+"\n  File: "+.key+
            "\n  Finding ID: "+.value.issue.id+"; media offset: "+((.value.issue.offset // 0)|tostring)+"s\n  Evidence: "+(.value.issue.evidence|.[0:650])]) +
          (if ($issues|length)>$max then ["Additional active findings retained in compressed state: "+(($issues|length)-$max|tostring)] else [] end) +
          ["", "Recovered/removed since last delivered summary:"] +
          ([$fixed[:5][]|"- "+.path+": "+.resolution]) +
          (if ($fixed|length)>5 then ["Additional retained recovery records: "+(($fixed|length)-5|tostring)] else [] end) +
          ["", "Review: repeatable errors need playback/backup investigation; unsupported tools, resource/time limits and changing files remain unverified. No automatic replacement is enabled."] | join("\n"))}' >"$temp" || return 1
    # Clip only the optional tail at a byte limit; retain a valid UTF-8 body.
    body=$(jq -r .body "$temp" | head -c 23000 | iconv -f UTF-8 -t UTF-8 -c || true)
    if (( $(jq -r .body "$temp" | wc -c)>23000 )); then body+=$'\n[Email detail limit reached; individual findings retained in state.]';fi
    printf '%s\n' "$body" >"$STATE_DIR/latest-report.txt.new"
    mv -f "$STATE_DIR/latest-report.txt.new" "$STATE_DIR/latest-report.txt"
    [[ "$status" == OK || "$status" == INVENTORY_ONLY || "$status" == DEFERRED ]] || importance=warning
    signature=$(jq -c '{status,mode,activeFindings,recoveries,findingKeys,recoveryKeys,stats:{quick:.stats.quickPassed,ranges:.stats.segmentsPassed,cycles:.stats.cyclesCompleted},reason:$reason}' --arg reason "$reason" "$temp" | sha256sum | awk '{print $1}')
    if [[ -f "$STATE_DIR/notified.json" ]]; then previous=$(jq -r '.signature // ""' "$STATE_DIR/notified.json");last=$(jq -r '.sentAt // 0' "$STATE_DIR/notified.json");fi
    if [[ "$MODE" == scan && ( "$signature" != "$previous" || $((now-last)) -ge 86400 ) ]]; then
        jq -n --arg body "$body" --arg importance "$importance" --arg signature "$signature" --argjson epoch "$now" \
          '{schema:1,body:$body,importance:$importance,signature:$signature,epoch:$epoch}' >"$STATE_DIR/pending-notification.json.new" && mv "$STATE_DIR/pending-notification.json.new" "$STATE_DIR/pending-notification.json"
        if [[ -x "$NOTIFY_BIN" ]] && timeout 30 "$NOTIFY_BIN" -i "$importance" -s 'Media Integrity Audit' -d "$(jq -r .summary "$temp")" -m "$body"; then
            jq -n --arg signature "$signature" --argjson sentAt "$now" '{signature:$signature,sentAt:$sentAt}' >"$STATE_DIR/notified.json.new" && mv "$STATE_DIR/notified.json.new" "$STATE_DIR/notified.json"
            rm -f "$STATE_DIR/pending-notification.json"
            jq '.notification="sent"' "$temp" >"$temp.new" && mv "$temp.new" "$temp"
        else jq '.notification="failed"' "$temp" >"$temp.new" && mv "$temp.new" "$temp";log WARNING 'Notification failed; grouped summary remains pending';fi
    else
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
      '.+{scriptVersion:$version,lastCompletedScanAt:$completed,installedAt:$installed,firstScheduledAt:$first}' "$temp" >"$STATUS_DIR/.media-integrity-audit.new" && mv "$STATUS_DIR/.media-integrity-audit.new" "$STATUS_DIR/media_integrity_audit.json"
    log INFO "$(jq -r .summary "$temp"); $reason"
    rm -f "$temp"
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
        self.last_heartbeat=0;self.last_checkpoint=0;self.dirty=True
        self.state.update(hostRoot=cfg['hostRoot'],libraries=cfg['libraries'])
        self.state.setdefault('resolved',[]);self.state.setdefault('runs',[])
        if self.state.get('toolset') and self.state['toolset']!=cfg['toolset']:
            for entry in self.state['files'].values():
                if entry.get('issue'):entry['notBefore']=0;entry['probeAt']=0
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
        old=entry.get('issue',{});now=int(time.time())
        entry['issue']={'id':hashlib.sha256(path.encode(errors='surrogateescape')).hexdigest()[:16],
                        'kind':kind,'firstSeen':old.get('firstSeen',now),'lastSeen':now,'confirmed':confirmed,
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
                return (not bool(f.get('offset',0)),f.get('lastAttemptAt',0),f.get('verifiedAt',0),path)
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
      --help|-h) printf '%s\n' 'Usage: bash script [--version|--status|--inventory-only|--help]' \
        'Default: real read-only weekly scan through Bazarr; no installation or media mutation.' \
        'Wednesday 09:30 SGT, two-hour runtime, two video threads, low CPU/I/O priority.' \
        'Quick probes and resumable overlapping decode ranges are separate evidence; pending files remain unverified.' \
        'Missing mounts, maintenance, active parity/Mover/backups or Plex transcoding defer/stop work.' \
        '--status reads only saved receipts. --inventory-only stats library paths and saves inventory; no decoding or normal email.' \
        'No media deletion/re-download/repair. Decoder timeouts and unsupported tools are unverified, not confirmed corruption.';return 0;;
      --status) [[ ! -f "$STATUS_DIR/media_integrity_audit.json" ]] || jq . "$STATUS_DIR/media_integrity_audit.json";return 0;;
      --inventory-only) MODE=inventory;;
      '') ;;
      *) printf 'Unknown option; use --help.\n' >&2;return 2;;
    esac
    local command flag fd line kind program input libraries toolset started last_guard=0 last_log=0 reason status=OK failure=false event_fd
    local chunk_expected=0 chunk_bytes=0 checkpoint_rc=0
    for command in docker jq flock timeout gzip base64 sha256sum find stat mountpoint pgrep iconv; do command -v "$command" >/dev/null || return 1;done
    for flag in "$MAX_RUNTIME_SECONDS" "$VIDEO_THREADS" "$DECODER_MEMORY_MIB" "$SEGMENT_MEDIA_SECONDS" "$SEGMENT_WALL_SECONDS" "$FILE_SLICE_SECONDS" "$RECHECK_DAYS" "$MAX_STATE_BYTES"; do
        [[ "$flag" =~ ^[1-9][0-9]*$ ]] || return 2
    done
    (( MAX_RUNTIME_SECONDS>=60 && MAX_RUNTIME_SECONDS<=14400 && VIDEO_THREADS<=8 && DECODER_MEMORY_MIB>=256 )) || return 2
    mountpoint -q "$VAULT_MOUNT" || { printf 'Vault unavailable; no shadow state or scan started.\n' >&2;return 1; }
    [[ "$STATE_DIR" == "$VAULT_MOUNT"/cloud/logs/script/media_integrity_audit && ! -L "$STATE_DIR" && ! -L "$STATUS_DIR" ]] || return 1
    mkdir -p "$STATE_DIR" "$STATUS_DIR" || return 1
    for flag in "$LOG_FILE" "$LOG_FILE.1" "$LOG_FILE.2" "$STATE_DIR/notified.json" "$STATE_DIR/pending-notification.json" "$STATE_DIR/latest-report.txt"; do [[ ! -L "$flag" ]] || return 1;done
    exec 9>"$LOCK_FILE" || return 1
    flock -n 9 || { printf 'Another media integrity audit is active; invocation deferred.\n';return 0; }
    TMP_DIR=$(mktemp -d /tmp/media-integrity-audit.XXXXXX) || return 1
    trap cleanup EXIT
    trap 'GUARD_REASON="Operator interruption";cancel_worker' INT TERM HUP
    find "$STATE_DIR" -maxdepth 1 -type f \( -name 'media-integrity-audit.log.1' -o -name 'media-integrity-audit.log.2' \) -mtime +29 -delete
    log INFO "Media Integrity Audit v$SCRIPT_VERSION started; mode=$MODE; scope=${LIBRARY_SUBDIRS[*]}; budget=${MAX_RUNTIME_SECONDS}s"
    if ! load_state; then write_report FAILED 'State invalid/unrecoverable; original state preserved and no scan started';return 1;fi
    if ! workload_guard; then write_report DEFERRED "$GUARD_REASON";return 0;fi
    toolset=$(timeout 12 docker exec --user 99:100 "$BAZARR_CONTAINER" sh -c \
      'set -e; command -v python3 >/dev/null; command -v ffprobe >/dev/null; command -v ffmpeg >/dev/null; command -v nice >/dev/null; command -v ionice >/dev/null; ffmpeg -version | head -n 1; ffprobe -version | head -n 1') || {
        write_report FAILED 'Bazarr tool runtime unavailable; no media file was checked';return 1; }
    libraries=$(printf '%s\n' "${LIBRARY_SUBDIRS[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')
    input="$TMP_DIR/input.json"
    jq -n --slurpfile state "$TMP_DIR/state.json" --arg root "$MEDIA_CONTAINER_ROOT" --arg hostRoot "$MEDIA_HOST_ROOT" \
      --argjson libraries "$libraries" --arg toolset "$toolset" --arg mode "$MODE" \
      --argjson budget "$MAX_RUNTIME_SECONDS" --argjson quick "$QUICK_PASS_MAX_SECONDS" --argjson threads "$VIDEO_THREADS" --argjson memory "$DECODER_MEMORY_MIB" \
      --argjson segment "$SEGMENT_MEDIA_SECONDS" --argjson wall "$SEGMENT_WALL_SECONDS" --argjson slice "$FILE_SLICE_SECONDS" \
      --argjson recheck "$RECHECK_DAYS" --argjson settle "$SETTLE_SECONDS" --argjson max "$MAX_STATE_BYTES" \
      '{state:$state[0],config:{root:$root,hostRoot:$hostRoot,libraries:$libraries,toolset:$toolset,mode:$mode,
       budgetSeconds:$budget,quickBudgetSeconds:$quick,threads:$threads,memoryMiB:$memory,segmentSeconds:$segment,segmentWallSeconds:$wall,
       fileSliceSeconds:$slice,recheckDays:$recheck,settleSeconds:$settle,maxStateBytes:$max}}' >"$input" || return 1
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
