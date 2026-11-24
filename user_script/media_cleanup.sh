#!/bin/bash
clearLog=true
arrayStarted=true
# Media Cleanup v1.5.0 -- personal Hubble operations
#
# PURPOSE: One daily job coordinates Arr deletion/unmonitoring/90-day retirement,
# proven SAB completed-payload cleanup, and metadata-bin retention. Modules run
# sequentially: arr -> sab -> quarantine. Each retains its own proof, retry,
# mount/Mover, recovery-hold, confirmation, retention and action-budget checks.
# Runtime is cooperatively bounded to 45 minutes. Before new work, transport
# circuits and per-app write/retirement budgets are checked. Issued changes still
# complete their read-back/checkpoint; leftovers retry on the next scheduled run.
# SAB oversized wrappers drain by identity-checked file intents within the same
# daily byte limit and a 250-file cap. A single file above the byte limit remains
# protected/reported. Existing correct quarantine permissions are not rewritten.
# Run receipts include counts, protection reasons, timing and notification backlog.
# One module failure does not authorize another module to bypass its safeguards.
# Existing originals remain in GitHub as reference; this file is standalone.
#
# SCHEDULE: 38 4 * * * (04:38 Singapore on Hubble), after the 04:00 import batch
# and before the 05:38 appdata backup. Backup coordination defers unsafe work;
# runtime is workload dependent. No overlapping batch is allowed.
#
# STATE: /mnt/vault/cloud/logs/script/media_cleanup/{arr,sab,quarantine}; separate
# schemas preserve pending operations, receipts, two-observation confirmations,
# retirement clocks and notification lifecycle. Payloads stay in their existing
# /mnt/user/media/bin and /mnt/user/media/net/quarantine locations. They are NOT
# state directories. Metadata and SAB retention remain independent (15 / 14 days).
# Never delete a journal to clear an unresolved operation.
#
# LOG: media-cleanup.log, capped at 2 MiB, two backups, 30-day backup retention.
# Logs identify module, application, run and outcome. Working Arr snapshots and
# sidecar assembly use RAM; final state/checkpoints/receipts remain persistent.
# Sidecar tools use bounded 64-file/32-KiB argument batches; fresh SHA-256 and
# before/after identity checks remain mandatory. Sonarr merges each series map
# once instead of copying the library map for each episode. Timing is logged.
# File hashing before quarantine is retained. No Docker configuration is changed.
#
# NOTIFICATIONS: Modules hand complete operational reports to a durable shared
# outbox. Acceptance by that outbox is not email delivery. One grouped email/day
# covers actions, recovered work and attention; failed delivery retains the data.
# Routine NZB/database-backup expiry is log-only unless another action or
# exception justifies a report; its counts/bytes are included in that report.
# Quiet healthy runs send nothing. Oversize reports span future daily messages;
# undelivered details are retained, never silently dropped. Abnormal exits and
# deferrals are reported with outcomes. RUNNING receipts are written at startup
# and phase changes; an abandoned RUNNING record is reported on the next run.
# Console output streams live; only job-owned processes are stopped on cancellation.
#
# CLI (use /bin/bash on Unraid flash):
#   cleanup=/boot/config/plugins/user.scripts/scripts/media_cleanup/script
#   /bin/bash "$cleanup"                       # all, using module configuration
#   /bin/bash "$cleanup" --dry-run             # Arr + SAB preview; bin audit
#   /bin/bash "$cleanup" arr sonarr --dry-run   # Radarr is not run
#   /bin/bash "$cleanup" arr --list-pending
#   /bin/bash "$cleanup" arr --resolve-pending ID "verified outcome"
#   /bin/bash "$cleanup" sab --inspect
#   /bin/bash "$cleanup" sab --pending-operations
#   /bin/bash "$cleanup" sab --restore WRAPPER # native guarded restore
#   /bin/bash "$cleanup" sab --recover-orphan EXACT_FOLDER --execute
#   /bin/bash "$cleanup" quarantine audit
#   /bin/bash "$cleanup" quarantine restore RUN_ID movies "Movie/poster.jpg"
#   /bin/bash "$cleanup" quarantine --pending-operations
#   /bin/bash "$cleanup" quarantine --resolve-operation ID "verified outcome"
#   /bin/bash "$cleanup" --flush-notifications  # retries queue; daily cap applies
#   /bin/bash "$cleanup" arr --help             # full original module CLI
# Module-only invocations share the same locks/state/outbox and daily mail cap.
# A preview changes operational observations/logs; it does not mutate payloads or
# Arr monitoring. Restore/resolve/orphan modes require the original exact IDs and
# proofs; they never gain a force-delete shortcut from this wrapper.

# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="media_cleanup"
# Embedded operations contract v1; generated into standalone User Scripts.
usr_ops_log_line() {
    local level="${1^^}" phase="$2" message="$3" line LC_ALL=C
    case "$level" in WARN) level=WARNING;; ERR|FATAL) level=ERROR;; NOTICE) level=INFO;; esac
    message=${message//$'\r'/};message=${message//$'\n'/ | }
    printf -v line '%s | %s | %s | run=%s | phase=%s | %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$OPS_SCRIPT_ID" "${OPS_RUN_ID:-$$}" "$phase" "$message"
    if ((${#line}>4096));then line="${line:0:4050} ... [truncated]";fi
    printf '%s\n' "$line"
}

# Accept the original command, including its timeout, so producer-specific
# delivery/cooldown/acknowledgement semantics stay with the owning script.
usr_ops_notify() {
    local -a args=("$@")
    local i importance=normal summary='' message='' index=-1 status=UPDATE
    for ((i=0;i<${#args[@]};i++));do
        case "${args[$i]}" in
          -i) importance="${args[$((i+1))]:-normal}";;
          -d) summary="${args[$((i+1))]:-}";;
          -m) index=$((i+1));message="${args[$index]:-}";;
        esac
    done
    case "$importance" in alert|warning) status=ATTENTION;;esac
    if [[ "$message" != 'Status: '* ]];then
        message="Status: $status"$'\n'"Summary: $summary"$'\n\n'"Actions and findings:"$'\n'"${message:-$summary}"
        if ((index>=0));then args[$index]="$message";else args+=(-m "$message");fi
    fi
    # Every notifier has a termination escalation, including legacy callers.
    if [[ "${args[0]##*/}" == timeout ]];then
        if [[ " ${args[*]} " != *' --kill-after'* ]];then args=("${args[0]}" --kill-after=5 "${args[@]:1}");fi
    else args=(timeout --signal=TERM --kill-after=5 30 "${args[@]}");fi
    "${args[@]}"
}

# Bounded local history for scripts previously dependent on the plugin console.
usr_ops_append_log() {
    local file="$1" line="$2" max="${3:-2097152}" i
    [[ -d "${file%/*}" && ! -L "$file" ]] || return 1
    for i in 1 2;do [[ ! -L "$file.$i" ]] || return 1;done
    find "${file%/*}" -maxdepth 1 -type f \( -name "${file##*/}.1" -o -name "${file##*/}.2" \) -mtime +29 -delete || return 1
    if [[ -f "$file" ]] && (( $(stat -c %s "$file")+${#line}+1>max ));then
        rm -f "$file.2";[[ ! -f "$file.1" ]] || mv "$file.1" "$file.2";mv "$file" "$file.1" || return 1
    fi
    printf '%s\n' "$line" >>"$file"
}
# END EMBEDDED OPERATIONS CONTRACT
set -uo pipefail
umask 077
MC_VERSION="1.5.0"
# One execution switch across every module. Conflicting/unused flags fail before work.
# In preview, quarantine purge becomes audit; restore requires an explicit execute flag.
MC_DRY_RUN=false
# COMMON CONFIGURATION: credentials below are private on Hubble only.
MC_ROOT="/mnt/vault/cloud/logs/script/media_cleanup"
MC_SONARR_URL="http://192.168.50.4:8989"
MC_SONARR_API_KEY="PUT_YOUR_SONARR_API_KEY_HERE"
MC_RADARR_URL="http://192.168.50.4:7878"
MC_RADARR_API_KEY="PUT_YOUR_RADARR_API_KEY_HERE"
MC_SAB_URL="http://192.168.50.4:8080"
MC_SAB_API_KEY="PUT_YOUR_SABNZBD_API_KEY_HERE"
MC_NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
MC_LOG_MAX_BYTES=2097152
MC_LOG_BACKUPS=2
MC_LOG_RETENTION_DAYS=30
MC_MAIL_MAX_BYTES=24000
MC_LOCK="/run/media_cleanup.lock"
MC_NOTIFY_LOCK="/run/media_cleanup-notification.lock"
MC_LOG_LOCK="/run/media_cleanup-log.lock"
MC_STATUS_DIR="/mnt/vault/cloud/logs/script/user_scripts_status"
# Bounded external operations; failed/unverified delivery stays queued.
MC_NOTIFY_TIMEOUT_SECONDS=30
MC_LOCK_WAIT_SECONDS=20
# Soft deadline: stop at safe boundaries; never interrupt a committed move or
# its read-back. Limits reset each invocation; no manual reset is required.
MC_MAX_RUNTIME_SECONDS=2700
MC_ARR_CONSECUTIVE_FAILURES=3
MC_ARR_MAX_MUTATIONS=50            # Attempted mutation requests per application.
MC_ARR_MAX_RETIREMENTS=10          # DELETE requests per application.
MC_RADARR_MAX_TAG_MOVIES=100       # Bound a bulk editor payload; remainder retries.
MC_GUARDS_ACTIVE=false
MC_BRIDGE_ACTIVE=false

mc_app_mutation_gate() {
    local app="$1"
    [[ "${MC_GUARDS_ACTIVE:-false}" == true && "${MC_DRY_RUN:-false}" != true ]] || return 0
    exec {ARR_MUTATION_FD}>"${ARR_MUTATION_LOCK_DIR:-/run}/arr-mutations-$app.lock" || return 1
    flock -n "$ARR_MUTATION_FD" || { mc_defer_work "${app^^}" 'Another coordinated script owns Arr changes; current state preserved';return 75; }
}

# Shared v1 receipt contract, embedded verbatim in producer and consumer.
# Older receipts may lack optional enrichment; exact live identity validation
# remains mandatory before cleanup. History proof is not expired just by age.
arr_import_receipt_document_valid() {
    jq -e '
      def pos: type=="number" and .>0 and .==floor;
      def nonneg: type=="number" and .>=0 and .==floor;
      def text: type=="string" and length>0 and (contains("\u0000")|not);
      def absolute: text and startswith("/");
      .version==1 and (.receipts|type)=="object" and all(.receipts|to_entries[];
        .key as $key | .value |
        (.app=="Sonarr" or .app=="Radarr") and (.downloadId|text) and $key==(.app+":"+.downloadId) and
        (.targets|type)=="object" and (.targets|length)>0 and
        all(.targets[];
          (.fileId|pos) and (.targetId|pos) and (.parentId|pos) and (.pathAtImport|absolute) and
          (.kind=="episode" or .kind=="movie") and
          ((.parentExternalId // 0)|nonneg) and
          (if .kind=="episode" then
             ((.seasonNumber // 0)|nonneg) and ((.episodeNumber // 0)|nonneg) else .targetId==.parentId end)))' "$1" >/dev/null
}

arr_policy_receipt_document_valid() {
    jq -e '
      type=="object" and .version==1 and (.actions|type)=="object" and (.observations|type)=="object" and
      all(.actions|to_entries[];
        .key as $id | .value |
        .downloadId==$id and ($id|test("^[a-z0-9-]+$")) and
        ((.sab.nzo_id // ""|ascii_downcase)==$id) and ((.queue.downloadId // ""|ascii_downcase)==$id) and .queue.id==.queueId and
        ((.app=="Sonarr" and .kind=="episode") or (.app=="Radarr" and .kind=="movie")) and
        (.mode=="redundant" or .mode=="replace") and
        (.status=="intent" or .status=="queue_verified" or .status=="search_uncertain" or .status=="done") and
        ([.targetId,.parentId,.queueId,.startedAt] | all(.[]; type=="number" and .>0 and .==floor)) and
        (.command == (if .kind=="episode" then {name:"EpisodeSearch",episodeIds:[.targetId]} else {name:"MoviesSearch",movieIds:[.targetId]} end)) and
        ([.replacementProofRuns // 0,.replacementCheckedAt // 0,.searchStartedAt // 0] | all(.[];type=="number" and .>=0 and .==floor)) and
        (.profile|type)=="object" and (.target|type)=="object" and (.parent|type)=="object" and (.sab|type)=="object" and (.queue|type)=="object")
    ' "$1" >/dev/null
}

mc_state_ready() {
    [[ "$MC_ROOT" == /mnt/vault/cloud/logs/script/media_cleanup && ! -L "$MC_ROOT" &&
       "$(realpath -m -- "$MC_ROOT")" == "$MC_ROOT" ]] || return 1
    mountpoint -q /mnt/vault && mountpoint -q /mnt/user || return 1
    mkdir -p -- "$MC_ROOT" || return 1
    local p
    for p in "$MC_ROOT/arr" "$MC_ROOT/sab" "$MC_ROOT/quarantine"; do
        [[ ! -L "$p" ]] || return 1
        mkdir -p -- "$p" || return 1
    done
}

mc_publish() {
    sync -- "$1" && mv -f -- "$1" "$2" && sync -- "${2%/*}"
}

mc_rotate_locked() {
    local file="$MC_ROOT/media-cleanup.log" i generation suffix epoch cutoff
    [[ ! -L "$file" ]] || return 1
    cutoff=$(( $(date +%s)-MC_LOG_RETENTION_DAYS*86400 ))
    for generation in "$file".[0-9]*; do
        [[ -f "$generation" && ! -L "$generation" ]] || continue
        suffix=${generation##*.}; [[ "$suffix" =~ ^[0-9]+$ ]] || continue
        epoch=$(stat -c %Y "$generation") || return 1
        if (( suffix>MC_LOG_BACKUPS || epoch<cutoff )); then rm -f -- "$generation" || return 1; fi
    done
    [[ -f "$file" ]] || : >"$file"
    if (( $(stat -c %s "$file")>=MC_LOG_MAX_BYTES )); then
        rm -f -- "$file.$MC_LOG_BACKUPS" || return 1
        for ((i=MC_LOG_BACKUPS-1;i>=1;i--)); do
            [[ ! -f "$file.$i" ]] || mv -f -- "$file.$i" "$file.$((i+1))" || return 1
        done
        mv -f -- "$file" "$file.1" && : >"$file" || return 1
    fi
}

mc_write_line() {
    local line="$1" fd rc=0 LC_ALL=C
    [[ -d "$MC_ROOT" && ! -L "$MC_ROOT" && ! -L "$MC_ROOT/media-cleanup.log" ]] || return 1
    exec {fd}>"$MC_LOG_LOCK" || return 1
    flock -x -w "$MC_LOCK_WAIT_SECONDS" "$fd" || { exec {fd}>&-; return 1; }
    (( ${#line}<=4096 )) || line="${line:0:4050} ... [line truncated]"
    # Rotate before append, including a line that would cross the cap.
    if [[ -f "$MC_ROOT/media-cleanup.log" ]] && (( $(stat -c %s "$MC_ROOT/media-cleanup.log")+${#line}+1>MC_LOG_MAX_BYTES )); then
        # Rotation checks the same fixed bound; pad no data and force by argument.
        mc_rotate_locked_force || rc=1
    else mc_rotate_locked || rc=1; fi
    (( rc!=0 )) || printf '%s\n' "$line" >>"$MC_ROOT/media-cleanup.log" || rc=1
    exec {fd}>&-
    return "$rc"
}

mc_rotate_locked_force() {
    local actual=$MC_LOG_MAX_BYTES
    MC_LOG_MAX_BYTES=0
    mc_rotate_locked
    local rc=$?
    MC_LOG_MAX_BYTES=$actual
    return "$rc"
}

mc_log() {
    local level="$1"; shift
    local line;line=$(OPS_RUN_ID="${MC_RUN_ID:-$$}" usr_ops_log_line "$level" MAIN "$*")
    printf '%s\n' "$line" >&2
    mc_write_line "$line"
}

mc_export_guard() {
    exec {MC_EXPORT_FD}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || return 1
    flock -s -w 30 "$MC_EXPORT_FD"
}

mc_outbox_ready() {
    local state="$MC_ROOT/notification-outbox.json" tmp
    [[ ! -L "$state" ]] || return 1
    if [[ ! -e "$state" ]]; then
        tmp=$(mktemp "$MC_ROOT/.outbox.XXXXXX") || return 1
        # Honor an already-sent legacy/module report on migration day.
        local sent="" f value today=$(date +%F)
        for f in "$MC_ROOT/arr/notification-state.json" "$MC_ROOT/sab/notification-state.json" "$MC_ROOT/quarantine/notification-state.json"; do
            [[ -f "$f" ]] || continue
            value=$(jq -r '.lastSentAt // ""' "$f") || return 1
            [[ "${value:0:10}" != "$today" ]] || sent="$today"
        done
        jq -cn --arg sent "$sent" '{schema:1,events:[],lastSentDate:$sent}' >"$tmp" && mc_publish "$tmp" "$state" || return 1
    fi
    jq -e '.schema==1 and (.events|type)=="array" and all(.events[]; (.id|type)=="string" and (.message|type)=="string")' "$state" >/dev/null || return 1
    jq -e '((.topics // {})|type)=="object" and ((.delivered // {})|type)=="object"' "$state" >/dev/null || return 1
    if jq -e '.topics==null or .delivered==null' "$state" >/dev/null; then
      tmp=$(mktemp "$MC_ROOT/.outbox.XXXXXX") || return 1
      jq -c '.topics //= {} | .delivered //= {}' "$state" >"$tmp" && mc_publish "$tmp" "$state" || return 1
    fi
}

# Native notify-compatible collector. Each accepted body is durable before the
# module clears its local delivery queue. The central outbox then owns delivery.
mc_collect() (
    local module="$1";shift
    local importance=normal subject="Media Cleanup" description="" message="" work
    case "$module" in arr|sab|quarantine|main) ;; *) return 2;;esac
    while (( $# )); do
      (( $#>=2 )) || return 2
      case "$1" in -i) importance=$2;;-s) subject=$2;;-d) description=$2;;-m) message=$2;;*) return 2;;esac;shift 2
    done
    case "$importance" in normal|warning|alert) ;; *) importance=warning;;esac
    [[ -n "$message" ]] || message=$description
    work=$(mktemp /tmp/media-cleanup-legacy.XXXXXX) || return 1
    trap 'rm -f -- "$work" "$work.message"' EXIT
    printf '%s' "$message" >"$work.message"
    jq -n --arg module "$module" --arg importance "$importance" --arg subject "$subject" --arg description "$description" \
      --arg date "$(date +%F)" --rawfile message "$work.message" --argjson now "$(date +%s)" \
      '{events:[{nativeId:([$module,$importance,$subject,$description,$message,$date]|tojson),module:$module,importance:$importance,subject:$subject,
        description:$description,message:$message,epoch:$now,
        kind:(if $importance!="normal" and $subject!="Interrupted run detected" then "attention" else "action" end),
        topic:(if $importance!="normal" and $subject!="Interrupted run detected" then $module+":preflight" else "" end),eventGroup:""}]}
        | .topics=(if .events[0].topic!="" then {(.events[0].topic):{status:"attention",summary:$description}} else {} end)' >"$work" && mc_accept_records "$work"
)
mc_flush() (
    local fd selected tmp body today importance count rc
    mc_export_guard || return 1
    exec {fd}>"$MC_NOTIFY_LOCK"; flock -x -w "$MC_LOCK_WAIT_SECONDS" "$fd" || return 1
    mc_outbox_ready || return 1
    today=$(date +%F)
    if [[ "$(jq -r .lastSentDate "$MC_ROOT/notification-outbox.json")" == "$today" ]]; then
        count=$(jq '.events|length' "$MC_ROOT/notification-outbox.json")
        (( count==0 )) || mc_log INFO "Daily notification limit already used; $count report section(s) retained" || true
        return 0
    fi
    jq -e '.events|length>0' "$MC_ROOT/notification-outbox.json" >/dev/null || return 0
    selected=$(mktemp "$MC_ROOT/.selected.XXXXXX") || return 1
    body=$(mktemp "$MC_ROOT/.email.XXXXXX") || return 1
    # Split a single large report on UTF-8 characters so even old oversized
    # outboxes can progress. The remainder stays under the same event ID.
    jq --argjson budget "$((MC_MAIL_MAX_BYTES-2000))" '
      def prefix($s;$b): reduce ($s|explode[]) as $c ({s:"",n:0,full:false};
        ($c|[.]|implode) as $v | ($v|utf8bytelength) as $n |
        if .full or .n+$n>$b then .full=true else .s+=$v | .n+=$n end) | .s;
      . as $state | .events |= map(. as $e | if ($e.topic // "")!="" and $state.topics[$e.topic].status=="healthy" then
        .importance="normal" | .description+="; current condition resolved" else . end) |
      reduce (.events|sort_by([if .importance=="alert" then 0 elif .importance=="warning" then 1 else 2 end,.epoch])[]) as $e
        ({items:[],bytes:0}; ("["+$e.module+"] "+$e.subject+"\nReported: "+($e.epoch|strflocaltime("%Y-%m-%d %H:%M:%S %Z"))+"\n"+$e.description+"\n") as $h |
         ($budget-.bytes-($h|utf8bytelength)-4) as $remaining |
         if $remaining<256 then . else prefix($e.message;$remaining) as $p |
           .items += [$e+{message:$p,consumed:($p|length)}] | .bytes += (($h+$p)|utf8bytelength)+4 end)
      | .items' "$MC_ROOT/notification-outbox.json" >"$selected" || return 1
    count=$(jq length "$selected"); (( count>0 )) || return 1
    jq -r '.[] | ("["+.module+"] "+.subject+"\nReported: "+(.epoch|strflocaltime("%Y-%m-%d %H:%M:%S %Z"))+"\n"+.description+"\n"+.message+"\n")
      | explode | map(select(.!=8205 and .!=8419 and .!=65039 and (. < 9728 or . > 10175) and (. < 126976 or . > 129791))) | implode' "$selected" >"$body" || return 1
    printf '\nCurrent run outcomes: %s\nReports retain their original observation time. Pending detail is retained for subsequent daily delivery.\n' "${MC_OUTCOMES:-notification retry only}" >>"$body"
    mc_backlog_metrics >"$selected.backlog" || return 1
    jq -r '"Queue before delivery: \(.pendingSections) section(s), \(.pendingBytes) bytes; oldest pending age: \((.oldestAgeSeconds/86400)|floor) day(s)."' "$selected.backlog" >>"$body" || return 1
    rm -f -- "$selected.backlog"
    importance=$(jq -r 'if any(.[];.importance=="alert") then "alert" elif any(.[];.importance=="warning") then "warning" else "normal" end' "$selected")
    exec {MC_EXPORT_FD}>&-
    usr_ops_notify timeout --signal=TERM --kill-after=5 "$MC_NOTIFY_TIMEOUT_SECONDS" "$MC_NOTIFY_BIN" -i "$importance" -s "Media Cleanup" -d "Daily cleanup actions and attention" -m "$(cat "$body")"
    rc=$?
    if (( rc==0 )); then
        mc_export_guard || return 1
        tmp=$(mktemp "$MC_ROOT/.outbox.XXXXXX") || return 1
        jq -c --arg day "$today" --argjson sentAt "$(date +%s)" --slurpfile sent "$selected" '
           . as $state | .lastSentDate=$day | .events = [ $state.events[] | . as $e |
             ([$sent[0][] | select(.id==$e.id)][0] // null) as $s |
             if $s==null then . elif $s.consumed<(.message|length) then
               .message=.message[$s.consumed:] else empty end ]
           | reduce $sent[0][] as $s (.; if any(.events[];.id==$s.id) then . else
               .delivered[$s.id]={epoch:$sentAt,topic:($s.topic // ""),kind:($s.kind // "action")} end)' \
           "$MC_ROOT/notification-outbox.json" >"$tmp" && mc_publish "$tmp" "$MC_ROOT/notification-outbox.json" || return 1
        mc_log INFO "Unraid accepted one grouped email with $count report section(s); queued remainder=$(jq '.events|length' "$MC_ROOT/notification-outbox.json")" || true
    fi
    rm -f -- "$selected" "$body"
    return "$rc"
)

mc_help() {
    printf '%s\n' "media_cleanup.sh $MC_VERSION" \
      'Usage: /bin/bash SCRIPT [all [--dry-run|--execute]|--dry-run|--execute|--flush-notifications|--version|--help]' \
      '       /bin/bash SCRIPT arr [all|sonarr|radarr|--list-pending|--resolve-pending ID NOTE] [--dry-run|--execute]' \
      '       /bin/bash SCRIPT sab [--dry-run|--execute|--no-purge|--inspect|--restore WRAPPER|--pending-operations|--resolve-operation ID NOTE|--recover-orphan NAME --execute]' \
      '       /bin/bash SCRIPT quarantine [--dry-run|--execute] [audit|purge|restore RUN_ID movies|series RELATIVE_PATH|--pending-operations|--resolve-operation ID NOTE]' \
      'No arguments: Arr, SAB cleanup, metadata retention sequentially; one daily grouped notification.' \
      'Preview: records observations/logs without payload or Arr mutations. Module --help provides further details.' \
      "State/logs: $MC_ROOT; original quarantine payload roots and retention are preserved."
}

mc_record_status() (
    local tmp now=$(date +%s)
    mc_export_guard || return 1
    mc_backlog_metrics >"$MC_TMP/backlog.json" || return 1
    tmp=$(mktemp "$MC_ROOT/.status.XXXXXX") || return 1
    jq -n --arg name media_cleanup --arg version "$MC_VERSION" --arg status "$MC_RESULT" --arg summary "$MC_OUTCOMES" \
      --arg phase "${MC_ACTIVE_MODULE:-none}" --arg run "$MC_RUN_ID" --arg boot "${MC_BOOT_ID:-unknown}" \
      --arg mode "${MC_MODE:-manual}" --argjson epoch "$now" --argjson started "$MC_STARTED" --argjson pid "$$" \
      --slurpfile modules "$MC_TMP/outcomes.json" --slurpfile backlog "$MC_TMP/backlog.json" \
      '{schema:1,name:$name,scriptVersion:$version,status:$status,mode:$mode,summary:$summary,phase:$phase,runId:$run,bootId:$boot,pid:$pid,
        startedAt:$started,epoch:$epoch,duration_seconds:($epoch-$started),modules:$modules[0],notificationBacklog:$backlog[0]}' >"$tmp" && mc_publish "$tmp" "$MC_ROOT/latest-run.json" || return 1
    case "${MC_MODE:-manual}" in all|--execute) ;; *) return 0;; esac
    [[ ! -L "$MC_STATUS_DIR" ]] || return 1
    mkdir -p -- "$MC_STATUS_DIR" || return 1
    tmp=$(mktemp "$MC_STATUS_DIR/.media_cleanup.XXXXXX") || return 1
    cp -- "$MC_ROOT/latest-run.json" "$tmp" && mc_publish "$tmp" "$MC_STATUS_DIR/media_cleanup.json"
)

mc_finalizer() {
    local rc=$?
    trap - EXIT INT TERM
    mc_stop_child || true
    if [[ "${MC_DONE:-false}" != true && -n "${MC_TMP:-}" ]]; then
        MC_RESULT=FAILED
        MC_OUTCOMES="${MC_OUTCOMES:-}; interrupted during ${MC_ACTIVE_MODULE:-startup}; reason=${MC_CANCEL_REASON:-abnormal exit}; exit=$rc; pending journals retained"
        mc_note orchestration failed 'Cleanup interrupted' "$MC_OUTCOMES" || mc_emergency_notice "$MC_OUTCOMES"
        mc_record_status || mc_emergency_notice "Could not save interrupted-run status: $MC_OUTCOMES"
        mc_flush || true
    fi
    if [[ "${MC_CHILDREN_UNREAPED:-false}" != true && "${MC_TMP:-}" == /tmp/media-cleanup.* ]]; then rm -rf -- "$MC_TMP";fi
    exit "$rc"
}

mc_run_module() {
    local module="$1";shift
    local rc=0 start=$(date +%s) status=COMPLETED reason='Native workflow completed' preview="$MC_TMP/$module.output" next
    MC_ACTIVE_MODULE=$module
    mc_record_status || { mc_self_failure "Cannot persist start of $module; module was not started";return 1; }
    mc_log INFO "Starting module=$module" || { mc_self_failure "Cannot write operational log; $module not started";return 1; }
    # Give only this job a process group. The supervisor waits for tee so output
    # is complete before result inspection. No Docker processes are signalled.
    if ! mc_work_allowed "$module";then
      jq -n --arg reason "$(cat "$MC_TMP/deferred-$module")" --arg module "$module" '{module:$module,status:"DEFERRED",reason:$reason,exit:75,metrics:{notStarted:true}}' >"$MC_TMP/$module.result.json" || return 1
    fi
    set -m
    (
      trap - EXIT INT TERM
      set +m
      local -a codes
      if [[ -f "$MC_TMP/deferred-$module" ]];then exit 0;fi
      case "$module" in
        arr) mc_arr "$@" 2>&1 | tee "$preview";codes=("${PIPESTATUS[@]}");;
        sab) mc_sab "$@" 2>&1 | tee "$preview";codes=("${PIPESTATUS[@]}");;
        quarantine) mc_quarantine "$@" 2>&1 | tee "$preview";codes=("${PIPESTATUS[@]}");;
      esac
      (( codes[1]==0 )) || exit 74
      exit "${codes[0]}"
    ) &
    MC_CHILD_PID=$!
    set +m
    wait "$MC_CHILD_PID" || rc=$?
    MC_CHILD_PID=""
    if (( rc!=0 )); then status=FAILED;reason="Native process exit=$rc";fi
    if [[ -f "$MC_TMP/$module.result.json" ]]; then
      jq -e --arg module "$module" '.module==$module and (.status|IN("COMPLETED","WARNING","DEFERRED","FAILED"))' "$MC_TMP/$module.result.json" >/dev/null || { mc_self_failure "Invalid $module result receipt";return 1; }
      if (( rc==0 )); then status=$(jq -r .status "$MC_TMP/$module.result.json");reason=$(jq -r .reason "$MC_TMP/$module.result.json");fi
    elif (( rc==0 )) && grep -Eiq 'deferred|Another .*run is active' "$preview"; then status=DEFERRED;reason='Startup coordination prevented work';fi
    case "$status" in
      FAILED) MC_RESULT=ATTENTION;mc_note "$module" failed "$module workflow failed" "Exit=$rc; $reason. Completed work and pending journals retained."$'\n'"$(tail -c 6000 "$preview")" || return 1;;
      DEFERRED) [[ "$MC_RESULT" != RUNNING && "$MC_RESULT" != OK ]] || MC_RESULT=DEFERRED
        mc_note "$module" deferred "$module deferred" "$reason. No protected operation was forced; next scheduled pass retries." || return 1;;
      WARNING) [[ "$MC_RESULT" == ATTENTION ]] || MC_RESULT=WARNING;mc_note "$module" healthy 'Workflow completed' "$reason" || return 1;;
      *) mc_note "$module" healthy 'Workflow completed' "$reason" || return 1;;
    esac
    [[ -f "$MC_TMP/$module.result.json" ]] || printf '{}' >"$MC_TMP/$module.result.json"
    next="$MC_TMP/outcomes.next"
    jq --arg module "$module" --arg status "$status" --arg reason "$reason" --argjson rc "$rc" --argjson duration "$(( $(date +%s)-start ))" --slurpfile result "$MC_TMP/$module.result.json" \
      '.+[{module:$module,status:$status,reason:$reason,exit:(if $rc!=0 then $rc else ($result[0].exit//$rc) end),duration_seconds:$duration,metrics:($result[0].metrics//{})}]' "$MC_TMP/outcomes.json" >"$next" && mv "$next" "$MC_TMP/outcomes.json" || { mc_self_failure "Cannot record $module outcome";return 1; }
    MC_OUTCOMES+="${MC_OUTCOMES:+; }$module=$status ($(( $(date +%s)-start ))s): $reason"
    mc_log INFO "Completed module=$module status=$status exit=$rc runtime=$(( $(date +%s)-start ))s; $reason" || { mc_self_failure 'Cannot write completion log';return 1; }
    return 0
}

mc_main() {
    local fd self rc=0 module previous="" oldrun="" oldphase="" oldboot="" oldstatus=""
    if [[ "${1:-}" == --collect-notification ]]; then shift;mc_collect "$@";return $?;fi
    mc_parse_cli "$@" || { mc_help >&2;return 2; }
    case "$MC_ROUTE" in
      --version) printf 'media_cleanup.sh %s\n' "$MC_VERSION";return 0;;
      --help|-h) mc_help;return 0;;
    esac
    if [[ "${MC_ARGS[0]:-}" == --help || "${MC_ARGS[0]:-}" == --version ]]; then
      case "$MC_ROUTE" in arr) mc_arr "${MC_ARGS[@]}";;sab) mc_sab "${MC_ARGS[@]}";;quarantine) mc_quarantine "${MC_ARGS[@]}";;esac;return $?;
    fi
    [[ "$MC_EFFECTIVE_DRY" == true || "$MC_EFFECTIVE_DRY" == false ]] || return 2
    MC_DRY_RUN="$MC_EFFECTIVE_DRY"
    mc_state_ready || { mc_preflight_failure;return 1; }
    exec {fd}>"$MC_LOCK";flock -n "$fd" || { printf 'Media cleanup already active; no duplicate actions.\n';return 0; }
    for self in MC_MAX_RUNTIME_SECONDS MC_ARR_CONSECUTIVE_FAILURES MC_ARR_MAX_MUTATIONS MC_ARR_MAX_RETIREMENTS MC_RADARR_MAX_TAG_MOVIES;do
      [[ "${!self}" =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid positive limit: %s\n' "$self" >&2;return 2; }
    done
    MC_STARTED=$(date +%s);MC_DEADLINE=$((MC_STARTED+MC_MAX_RUNTIME_SECONDS));MC_GUARDS_ACTIVE=true;MC_RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
    MC_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)
    if [[ -f "$MC_ROOT/latest-run.json" ]]; then
      if ! jq -e '.schema==1 and (.status|type)=="string"' "$MC_ROOT/latest-run.json" >/dev/null; then
        mc_note orchestration failed 'Invalid run receipt' 'Existing run receipt was preserved; no modules started. Review its JSON and storage health.' || true
        mc_emergency_notice 'Existing cleanup run receipt is invalid; no modules started; state was preserved.' || true
        return 1
      fi
      previous=$(jq -r '.status // ""' "$MC_ROOT/latest-run.json") || return 1
      oldrun=$(jq -r '.runId // "unknown"' "$MC_ROOT/latest-run.json")
      oldphase=$(jq -r '.phase // "unknown"' "$MC_ROOT/latest-run.json")
    fi
    MC_TMP=$(mktemp -d /tmp/media-cleanup.XXXXXX) || return 1
    MC_MODE="$MC_ROUTE"; [[ "$MC_ROUTE" != all || "$MC_DRY_RUN" != true ]] || MC_MODE=--dry-run
    MC_DONE=false;MC_RESULT=RUNNING;MC_OUTCOMES="";MC_ACTIVE_MODULE=startup;MC_CHILD_PID="";MC_BRIDGE_ACTIVE=true
    printf '[]\n' >"$MC_TMP/outcomes.json"
    trap mc_finalizer EXIT
    trap 'mc_cancel 130 INT' INT
    trap 'mc_cancel 143 TERM' TERM
    self=$(realpath -- "${BASH_SOURCE[0]}") || return 1
    MC_PROXY="$MC_TMP/notify"
    printf '#!/bin/bash\nexec /bin/bash %q --collect-notification "$MC_MODULE" "$@"\n' "$self" >"$MC_PROXY" || return 1
    chmod 700 "$MC_PROXY";export MC_MODULE
    if [[ "$previous" == RUNNING ]]; then
      mc_collect main -i warning -s 'Interrupted run detected' -d 'Recovering after interruption' \
        -m "Prior run=$oldrun; last phase=$oldphase. Its lease is no longer active. Existing action journals are retained; each module verifies outcomes before retrying." || return 1
    fi
    mc_record_status || { mc_self_failure 'Cannot persist initial RUNNING receipt; no modules started';return 1; }
    mc_log INFO "Started mode=$MC_MODE preview=$MC_DRY_RUN"
    case "$MC_ROUTE" in
      all)
        for module in arr sab quarantine; do
          MC_MODULE=$module
          case "$module" in
            arr) mc_run_module arr all "${MC_ARGS[@]}" || { mc_self_failure 'Arr orchestration failed';rc=1; };;
            sab) mc_run_module sab "${MC_ARGS[@]}" || { mc_self_failure 'SAB orchestration failed';rc=1; };;
            quarantine) if [[ "$MC_DRY_RUN" == true ]]; then mc_run_module quarantine audit;else mc_run_module quarantine purge;fi || { mc_self_failure 'Quarantine orchestration failed';rc=1; };;
          esac
        done;;
      --flush-notifications) MC_OUTCOMES='Notification retry only; no cleanup performed';;
      *) MC_MODULE=$MC_ROUTE;mc_run_module "$MC_ROUTE" "${MC_ARGS[@]}" || { mc_self_failure 'Module orchestration failed';rc=1; };;
    esac
    [[ "$MC_RESULT" != RUNNING ]] || MC_RESULT=OK
    if (( rc==0 )) && [[ "$MC_RESULT" != ATTENTION ]]; then
      mc_note orchestration healthy 'Orchestration recovered' 'Current control-plane operations completed' || { MC_RESULT=ATTENTION;rc=1; }
    fi
    mc_record_status || { mc_self_failure 'Could not save final status; successful module actions remain recorded';rc=1; }
    if ! mc_flush; then mc_self_failure 'Notification delivery or persistence failed; unsent reports retained';rc=1;fi
    mc_record_status || { mc_emergency_notice 'Could not persist final cleanup status; inspect storage and permissions';rc=1;MC_RESULT=ATTENTION; }
    mc_log INFO "Finished status=$MC_RESULT; $MC_OUTCOMES; runtime=$(( $(date +%s)-MC_STARTED ))s" || { MC_RESULT=ATTENTION;rc=1; }
    MC_DONE=true
    [[ "$MC_RESULT" != ATTENTION ]] || rc=1
    return "$rc"
}

# A module exports its own result before its EXIT handler completes. The parent
# still treats the real process exit as authoritative if finalization then fails.
mc_finish_module() {
    local module="$1" rc="$2";shift 2
    local status=COMPLETED reason="Native workflow completed" temp
    [[ -d "${MC_TMP:-}" ]] || return "$rc"
    local scope deferred=""
    if [[ "${MC_GUARDS_ACTIVE:-false}" == true ]];then
      [[ ! -f "$MC_TMP/deferred-$module" ]] || deferred+="$(cat "$MC_TMP/deferred-$module"); "
      if [[ "$module" == arr ]];then
        for scope in SONARR RADARR RADARR_TAG_REMAINDER;do [[ ! -f "$MC_TMP/deferred-$scope" ]] || deferred+="$scope: $(cat "$MC_TMP/deferred-$scope"); ";done
      fi
    fi
    if [[ -f "$MC_TMP/failed-$module" ]];then status=FAILED;reason="$(cat "$MC_TMP/failed-$module"); $deferred"
    elif [[ "$module" == sab && "${ERRORS:-0}" != 0 ]];then status=FAILED;reason="SAB cleanup recorded $ERRORS error(s); $deferred"
    elif [[ -n "$deferred" ]];then status=DEFERRED;reason="$deferred"
    elif (( rc!=0 )); then status=FAILED; reason="Native workflow returned $rc"
    else
        case "$module" in
          arr)
            if [[ "${MC_MODULE_STATUS:-}" == DEFERRED ]]; then
                status=DEFERRED;reason="$MC_MODULE_REASON"
            elif [[ "${LOG_READY:-false}" != true && "${1:-}" != --list-pending ]]; then
                status=DEFERRED;reason="Coordination or active-run guard prevented startup"
            fi;;
          sab)
            if [[ "${RUN_INITIALIZED:-false}" != true && "${1:-}" != --inspect && "${1:-}" != --pending-operations ]]; then
                status=DEFERRED;reason="Coordination or active-run guard prevented startup"
            elif [[ "${MOVER_GUARD_TRIGGERED:-false}" == true || "${BACKUP_CLEANUP_STATUS:-}" == MOVER_* || "${STRANDED_CLEANUP_STATUS:-}" == MOVER_* || "${QUARANTINE_PURGE_STATUS:-}" == MOVER_* ]]; then
                status=DEFERRED;reason="Mover stopped protected mutations; completed work retained"
            elif [[ "${BACKUP_CLEANUP_STATUS:-}" == SKIPPED_* || "${STRANDED_CLEANUP_STATUS:-}" == SKIPPED_* || "${QUARANTINE_PURGE_STATUS:-}" == SKIPPED_* ]]; then
                status=WARNING;reason="Configured phase skipped: backups=$BACKUP_CLEANUP_STATUS; stranded=$STRANDED_CLEANUP_STATUS; purge=$QUARANTINE_PURGE_STATUS"
            elif (( ${ERRORS:-0}>0 )); then status=FAILED;reason="SAB cleanup reported $ERRORS error(s)";fi;;
          quarantine)
            if [[ "${1:-}" == --pending-operations ]]; then
                status=COMPLETED;reason="Pending operations listed without payload changes"
            else
            case "${RESULT_STATUS:-}" in
              WARNING) status=WARNING;reason="${RESULT_SUMMARY:-Protected or expired entries remain}";;
              DEFERRED) status=DEFERRED;reason="${RESULT_SUMMARY:-Producer or export coordination active}";;
              FAILED) status=FAILED;reason="$RESULT_SUMMARY";;
            esac
            fi;;
        esac
    fi
    if [[ "$module" == arr && "$status" == COMPLETED && -f "$MC_TMP/arr.result.json" ]]; then
      status=$(jq -r .status "$MC_TMP/arr.result.json");reason=$(jq -r .reason "$MC_TMP/arr.result.json")
    fi
    mc_module_metrics "$module" >"$MC_TMP/$module.metrics.json" || return 1
    temp=$(mktemp "$MC_TMP/.module-result.XXXXXX") || return 1
    jq -n --arg module "$module" --arg status "$status" --arg reason "$reason" --argjson rc "$rc" --slurpfile metrics "$MC_TMP/$module.metrics.json" \
      '{module:$module,status:$status,reason:$reason,exit:$rc,metrics:$metrics[0]}' >"$temp" && mv "$temp" "$MC_TMP/$module.result.json" || return 1
    [[ "$status" != DEFERRED ]] || return 0
    return "$rc"
}

# Storage is unavailable precisely when the vault outbox cannot be used. Keep
# only a RAM daily acceptance marker; never create a shadow vault directory.
mc_preflight_failure() {
    mc_emergency_notice "Required mounted/canonical storage is unavailable. Arr sync, SAB cleanup and metadata retention were not started; no application or payload changes attempted. Required: /mnt/vault and /mnt/user. State: $MC_ROOT."
}

mc_parse_cli() {
    MC_ROUTE="${1:-all}"; MC_ARGS=(); MC_EFFECTIVE_DRY="$MC_DRY_RUN"
    local choice="" flag arg command
    (( $#==0 )) || shift
    mc_execution_flag() {
        local value="$1"
        [[ -z "$choice" || "$choice" == "$value" ]] || { printf 'Conflicting --dry-run and --execute flags; nothing started.\n' >&2; return 2; }
        choice="$value"; MC_EFFECTIVE_DRY=$value
    }
    case "$MC_ROUTE" in
      --help|-h|--version|--flush-notifications)
        (( $#==0 )) || return 2; return 0;;
      --dry-run|--execute)
        (( $#==0 )) || { printf 'Use all --dry-run or a module command; extra global-mode arguments are rejected.\n' >&2;return 2; }
        [[ "$MC_ROUTE" != --dry-run ]] || MC_EFFECTIVE_DRY=true
        [[ "$MC_ROUTE" != --execute ]] || MC_EFFECTIVE_DRY=false
        MC_ROUTE=all;;
      all)
        for flag in "$@"; do case "$flag" in --dry-run) mc_execution_flag true || return 2;; --execute) mc_execution_flag false || return 2;; *) return 2;; esac; done;;
      arr)
        command="${1:-all}"; (( $#==0 )) || shift
        case "$command" in
          --help|--version|--list-pending) (( $#==0 )) || return 2; MC_ARGS=("$command");;
          --resolve-pending) (( $#>=2 )) || return 2; MC_ARGS=("$command" "$@");;
          all|sonarr|radarr)
            for flag in "$@"; do case "$flag" in --dry-run) mc_execution_flag true || return 2;; --execute) mc_execution_flag false || return 2;; *) return 2;; esac; done
            MC_ARGS=("$command");;
          *) return 2;;
        esac;;
      sab)
        while (( $# )); do
          arg="$1";shift
          case "$arg" in
            --dry-run) mc_execution_flag true || return 2;;
            --execute) mc_execution_flag false || return 2;;
            --restore|--recover-orphan) (( $#>=1 )) || return 2; MC_ARGS+=("$arg" "$1");shift;;
            --resolve-operation) (( $#>=2 )) || return 2; MC_ARGS+=("$arg" "$1" "$2");shift 2;;
            --no-purge|--purge|--inspect|--pending-operations|--help|--version) MC_ARGS+=("$arg");;
            *) return 2;;
          esac
        done;;
      quarantine)
        while [[ "${1:-}" == --dry-run || "${1:-}" == --execute ]]; do
          [[ "$1" != --dry-run ]] || mc_execution_flag true || return 2
          [[ "$1" != --execute ]] || mc_execution_flag false || return 2
          shift
        done
        command="${1:-purge}"; (( $#==0 )) || shift
        case "$command" in
          audit|purge)
            for flag in "$@"; do case "$flag" in --dry-run) mc_execution_flag true || return 2;; --execute) mc_execution_flag false || return 2;; *) return 2;; esac; done
            [[ "$command" != purge || "$MC_EFFECTIVE_DRY" != true ]] || command=audit
            MC_ARGS=("$command");;
          restore)
            (( $#==3 )) || return 2
            [[ "$MC_EFFECTIVE_DRY" != true ]] || { printf 'Restore moves payloads; use quarantine --execute restore after review.\n' >&2;return 2; }
            MC_ARGS=(restore "$@");;
          --resolve-operation) (( $#>=2 )) || return 2;MC_ARGS=("$command" "$@");;
          --help|--version|--pending-operations) (( $#==0 )) || return 2; MC_ARGS=("$command");;
          *) return 2;;
        esac;;
      *) return 2;;
    esac
    # Native orphan reconstruction is a special manual operation: a default
    # executing schedule never substitutes for its explicit --execute consent.
    if [[ "$MC_ROUTE" == sab && "$choice" != false && " ${MC_ARGS[*]} " == *" --recover-orphan "* ]]; then MC_EFFECTIVE_DRY=true;fi
    flag=--execute; [[ "$MC_EFFECTIVE_DRY" != true ]] || flag=--dry-run
    case "$MC_ROUTE:${MC_ARGS[0]:-}" in arr:all|arr:sonarr|arr:radarr|sab:*) MC_ARGS+=("$flag");; esac
}


mc_accept_records() (
    local input="$1" fd tmp work raw id key record now=$(date +%s)
    mc_state_ready && mc_export_guard || return 1
    exec {fd}>"$MC_NOTIFY_LOCK";flock -x -w "$MC_LOCK_WAIT_SECONDS" "$fd" || return 1
    mc_outbox_ready || return 1
    work=$(mktemp -d /tmp/media-cleanup-records.XXXXXX) || return 1
    trap 'rm -rf -- "$work"' EXIT
    jq -e '(.events|type)=="array" and (.topics|type)=="object" and all(.events[]; (.nativeId|type)=="string" and (.message|type)=="string" and (.module|type)=="string")' "$input" >/dev/null || return 1
    jq -r '.events[] | ((.module+"|"+.nativeId)|@base64)+"\t"+tojson' "$input" >"$work/records" || return 1
    : >"$work/framed"
    while IFS=$'\t' read -r key record; do
      id=$(printf '%s' "$key" | sha256sum | cut -d' ' -f1) || return 1
      printf '%s\0%s\0' "$id" "$record" >>"$work/framed" || return 1
    done <"$work/records"
    jq -Rsc 'split("\u0000")|.[:-1]|. as $v|[range(0;length;2) as $i|($v[$i+1]|fromjson)+{id:$v[$i]}|del(.nativeId)]' "$work/framed" >"$work/events" || return 1
    tmp=$(mktemp "$MC_ROOT/.outbox.XXXXXX") || return 1
    jq -c --slurpfile incoming "$work/events" --slurpfile envelope "$input" --argjson now "$now" '
      .delivered //= {} | .topics //= {}
      | .delivered |= with_entries(select((.value.epoch // 0)>($now-31536000)))
      | . as $state | .topics |= with_entries(select(.value.status!="healthy" or (.value.updatedAt // $now)>($now-31536000) or (.key as $key | any($state.events[];.topic==$key))))
      | reduce ($envelope[0].topics|to_entries[]) as $t (.;
          (.topics[$t.key] // {}) as $old
          | (any(.events[];.topic==$t.key and .kind=="attention") or any(.delivered[];.topic==$t.key and .kind=="attention")) as $known
          | .topics[$t.key]=($t.value+{updatedAt:$now})
          | if $t.value.status=="healthy" then
              .events |= map(select(.topic!=$t.key or (.kind // "action")!="attention"))
              | if $old.status!="healthy" and $known and (any($incoming[0][];.topic==$t.key and .kind=="resolved")|not) then
                  .events += [{id:($t.key+"|resolved|"+($old.updatedAt|tostring)),module:($t.key|split(":")[0]),topic:$t.key,
                    eventGroup:$t.key,kind:"resolved",importance:"normal",subject:"Condition recovered",description:$t.value.summary,
                    message:("Earlier attention for "+$t.key+" is no longer active. "+$t.value.summary+". Completed-action records are retained."),epoch:$now}]
                else . end
            else . end)
      | reduce $incoming[0][] as $e (.;
          if .delivered[$e.id]!=null or any(.events[];.id==$e.id) then . else
            if ($e.topic // "")!="" and ($e.kind=="attention" or $e.kind=="resolved") then
              .events |= map(select(.topic!=$e.topic or ((.kind // "action")!="attention" and .kind!="resolved") or .eventGroup==$e.eventGroup))
            else . end
            | .events += [$e]
          end)

    ' "$MC_ROOT/notification-outbox.json" >"$tmp" && mc_publish "$tmp" "$MC_ROOT/notification-outbox.json"
)


mc_handoff_arr() (
    local batch="$1" work
    work=$(mktemp /tmp/media-cleanup-arr-events.XXXXXX) || return 1
    trap 'rm -f -- "$work"' EXIT
    jq -sc --argjson now "$(date +%s)" '
      {events:[.[] | . as $e | {nativeId:($e|to_entries|sort_by(.key)|from_entries|tojson),module:"arr",kind:.event,
        topic:(if .key!="" then "arr:"+.key else "" end),eventGroup:(.app+"|"+.runId+"|"+.key+"|"+.event+"|"+(.title|sub(" \\(detail part [0-9]+\\)$";""))+"|"+.signature),
        importance:(if .severity=="ERROR" then "alert" elif .event=="attention" then "warning" else "normal" end),
        subject:("["+.app+"] "+.title),description:(.event+"; observed "+.queuedAt),message:.detail,epoch:$now}],
       topics:(reduce (.[]|select(.key!="" and (.event=="resolved" or .event=="attention"))) as $e ({};
         .["arr:"+$e.key]={status:(if $e.event=="resolved" then "healthy" else "attention" end),summary:$e.title}))}' "$batch" >"$work" && mc_accept_records "$work"
)


mc_handoff_ops() (
    local module="$1" work
    work=$(mktemp /tmp/media-cleanup-ops-events.XXXXXX) || return 1
    trap 'rm -f -- "$work"' EXIT
    jq --arg module "$module" --argjson now "$(date +%s)" '
      {events:[.outbox[]|{nativeId:(.id+"|"+.queuedAt),module:$module,kind:.kind,
        topic:(if .topic!="" then $module+":"+.topic else "" end),eventGroup:(.eventId+"|"+.queuedAt),
        importance:.importance,subject:.subject,description:(.description+"; observed "+.queuedAt),message:.message,epoch:$now}],
       topics:(.topics|with_entries(.key=($module+":"+.key)))}' "$OPS_NOTIFICATION_STATE" >"$work" && mc_accept_records "$work"
)


mc_note() (
    local module="$1" status="$2" description="$3" message="$4" work
    work=$(mktemp /tmp/media-cleanup-note.XXXXXX) || return 1
    trap 'rm -f -- "$work"' EXIT
    jq -n --arg module "$module" --arg status "$status" --arg description "$description" --arg message "$message" \
      --arg date "$(date +%F)" --argjson now "$(date +%s)" '
      ("main:"+$module) as $topic | {topics:({($topic):{status:$status,summary:$description}} +
        (if $status=="healthy" then {((if $module=="orchestration" then "main" else $module end)+":preflight"):{status:"healthy",summary:$description}} else {} end)),
       events:(if $status=="healthy" then [] else [{nativeId:($topic+"|"+$status+"|"+$date),module:"main",topic:$topic,
       eventGroup:($topic+"|"+$date),kind:"attention",importance:(if $status=="failed" then "alert" else "warning" end),
       subject:$description,description:$status,message:$message,epoch:$now}] end)}' >"$work" && mc_accept_records "$work"
)


mc_stop_child() {
    local n pgid="${MC_CHILD_PID:-}"
    [[ "$pgid" =~ ^[1-9][0-9]*$ ]] || return 0
    kill -TERM -- "-$pgid" 2>/dev/null || true
    for ((n=0;n<50;n++)); do kill -0 -- "-$pgid" 2>/dev/null || break;sleep .1;done
    if kill -0 -- "-$pgid" 2>/dev/null; then kill -KILL -- "-$pgid" 2>/dev/null || true;fi
    wait "$pgid" 2>/dev/null || true
    for ((n=0;n<50;n++)); do kill -0 -- "-$pgid" 2>/dev/null || { MC_CHILD_PID="";return 0; };sleep .1;done
    MC_CHILDREN_UNREAPED=true
    return 1
}


mc_cancel() {
    trap '' INT TERM
    MC_CANCELLED=true;MC_CANCEL_REASON="${2:-termination requested}"
    mc_stop_child || true
    exit "${1:-130}"
}


mc_self_failure() {
    MC_RESULT=ATTENTION
    mc_log ERROR "$*" || true
    mc_note orchestration failed 'Cleanup control-plane failure' "$*" || mc_emergency_notice "$*"
}


mc_emergency_notice() (
    local detail="$1" marker="${MC_EMERGENCY_MARKER:-/run/media_cleanup-preflight-notified}" fd today=$(date +%F)
    printf '%s\n' "$detail" >&2
    exec {fd}>"$MC_NOTIFY_LOCK";flock -x -w "$MC_LOCK_WAIT_SECONDS" "$fd" || return 1
    [[ ! -L "$marker" ]] || return 1
    [[ ! -r "$marker" || "$(cat "$marker")" != "$today" ]] || return 0
    # Respect the accepted-email cap even if only the status destination failed.
    if [[ -r "$MC_ROOT/notification-outbox.json" ]] && jq -e --arg day "$today" '.lastSentDate==$day' "$MC_ROOT/notification-outbox.json" >/dev/null 2>&1; then return 0;fi
    usr_ops_notify timeout --signal=TERM --kill-after=5 "$MC_NOTIFY_TIMEOUT_SECONDS" "$MC_NOTIFY_BIN" -i alert -s 'Media Cleanup' -d 'Cleanup control-plane attention' -m "$detail" || return 1
    printf '%s' "$today" >"$marker"
)


# Cooperative limits apply only to this supervised invocation. Finish any
# already-issued mutation/read-back and its durable checkpoint before stopping.
mc_defer_work() {
    local scope="$1" reason="$2"
    [[ "${MC_GUARDS_ACTIVE:-false}" == true && -d "${MC_TMP:-}" ]] || return 0
    [[ -f "$MC_TMP/deferred-$scope" ]] || printf '%s\n' "$reason" >"$MC_TMP/deferred-$scope"
}

mc_work_allowed() {
    local scope="$1" now
    [[ "${MC_GUARDS_ACTIVE:-false}" == true && -d "${MC_TMP:-}" ]] || return 0
    [[ ! -f "$MC_TMP/deferred-$scope" ]] || return 1
    now=$(date +%s)
    if ((now>=MC_DEADLINE)); then
        mc_defer_work "$scope" "Overall ${MC_MAX_RUNTIME_SECONDS}s budget reached; completed work retained; remaining candidates retry next scheduled run"
        return 1
    fi
}

mc_arr_write_reserve() {
    local method="$1" endpoint="$2" file count=0 retired=0
    [[ "${MC_GUARDS_ACTIVE:-false}" == true && "$method" != GET ]] || return 0
    file="$MC_TMP/arr-${APP_CONTEXT}.writes"
    [[ ! -f "$file" ]] || read -r count retired <"$file"
    if ((count>=MC_ARR_MAX_MUTATIONS)) || { [[ "$method" == DELETE ]] && ((retired>=MC_ARR_MAX_RETIREMENTS)); };then
        mc_defer_work "$APP_CONTEXT" "Arr write budget reached ($count requests, $retired retirements); unapplied candidates remain eligible next run"
        return 1
    fi
    [[ "$method" != DELETE ]] || retired=$((retired+1))
    printf '%s %s\n' "$((count+1))" "$retired" >"$file"
}

mc_arr_request() {
    local rc=0 transport=0 http=200 failures=0 file scope="${APP_CONTEXT:-UNKNOWN}"
    mc_work_allowed "$scope" || return 75
    mc_arr_write_reserve "$@" || return 75
    file="${MC_TMP:-}/arr-$scope.transport"
    [[ "${MC_GUARDS_ACTIVE:-false}" != true ]] || rm -f -- "$file"
    mc_timed_call api arr_api_request_core "$@" || rc=$?
    if [[ "${MC_GUARDS_ACTIVE:-false}" == true && -f "$file" ]];then
        read -r transport http <"$file"
        [[ ! -f "$MC_TMP/arr-$scope.failures" ]] || read -r failures <"$MC_TMP/arr-$scope.failures"
        if [[ "$http" == 401 || "$http" == 403 ]];then failures="$MC_ARR_CONSECUTIVE_FAILURES"
        elif ((transport!=0)) || [[ "$http" == 408 || "$http" == 425 || "$http" == 429 || "$http" == 5?? ]];then failures=$((failures+1));else failures=0;fi
        printf '%s\n' "$failures" >"$MC_TMP/arr-$scope.failures"
        if ((failures>=MC_ARR_CONSECUTIVE_FAILURES));then
            mc_defer_work "$scope" "Arr circuit breaker opened after $failures consecutive authentication/transport/rate-limit/server failures; no further requests sent to this application"
        fi
    fi
    return "$rc"
}

mc_backlog_metrics() {
    local state="$MC_ROOT/notification-outbox.json" now=$(date +%s)
    if [[ -f "$state" ]];then
        jq --argjson now "$now" '{pendingSections:(.events|length),pendingBytes:([.events[].message|utf8bytelength]|add//0),
          oldestAgeSeconds:(if (.events|length)>0 then ($now-([.events[].epoch]|min)|[.,0]|max) else 0 end)}' "$state"
    else printf '{"pendingSections":0,"pendingBytes":0,"oldestAgeSeconds":0}\n';fi
}

mc_module_metrics() {
  local module="$1" file scope
  case "$module" in
    arr)
      local -a files=()
      for scope in SONARR RADARR;do file="$MC_TMP/arr-$scope.metrics.json";[[ ! -f "$file" ]] || files+=("$file");done
      if ((${#files[@]}>0));then jq -s '{applications:.}' "${files[@]}";else printf '{"applications":[],"inventoryComplete":false}\n';fi;;
    sab)
      jq -n --argjson scanned "${SCANNED:-0}" --argjson quarantined "${QUARANTINED:-0}" --argjson purged "${PURGED:-0}" \
       --argjson bytes "${BYTES_PURGED:-0}" --argjson files "${SAB_PURGED_FILES:-0}" --argjson partial "${SAB_PARTIAL_PURGES:-0}" \
       --argjson remaining "${SAB_PURGE_REMAINING:-0}" --argjson protected "${QUEUE_PROTECTED:-0}" --argjson unproven "${HISTORY_UNPROVEN:-0}" \
       --argjson unverified "${DESTINATION_UNVERIFIED:-0}" --argjson backups "$((${NZB_BACKUPS_REMOVED:-0}+${APP_BACKUPS_REMOVED:-0}))" \
       --argjson errors "${ERRORS:-0}" --argjson remainingWrappers "$((${SAB_EXPIRED_WRAPPERS:-0}-${PURGED:-0}))" \
       --argjson oldest "${SAB_OLDEST_EXPIRED_EPOCH:-0}" '{oldestEligibleQuarantineEpoch:$oldest,remainingExpiredWrappers:$remainingWrappers,scanned:$scanned,quarantined:$quarantined,purgedWrappers:$purged,purgedBytes:$bytes,
         incrementallyPurgedFiles:$files,partialWrappers:$partial,remainingPurgeDeferrals:$remaining,
         protectedByQueue:$protected,importProofUnproven:$unproven,destinationUnverified:$unverified,routineBackupsExpired:$backups,errors:$errors}' ;;
    quarantine)
      jq -n --argjson runs "${RUNS_SCANNED:-0}" --argjson expired "${EXPIRED_RUNS:-0}" --argjson purged "${PURGED_RUNS:-0}" \
       --argjson files "${PURGED_FILES:-0}" --argjson bytes "${PURGED_BYTES:-0}" --argjson remaining "${REMAINING_EXPIRED_RUNS:-0}" \
       --argjson unmanaged "${UNMANAGED_ENTRIES:-0}" --argjson errors "${SCAN_ERRORS:-0}" \
       '{runsScanned:$runs,expiredRuns:$expired,purgedRuns:$purged,purgedFiles:$files,purgedBytes:$bytes,remainingExpiredRuns:$remaining,unmanagedEntries:$unmanaged,scanErrors:$errors}' ;;
  esac
}

mc_timed_call() {
    local kind="$1" function="$2" start rc=0 end;shift 2
    if [[ -z "${MC_TMP:-}" || ! -d "$MC_TMP" ]]; then "$function" "$@";return $?;fi
    start=$(date +%s%N)
    "$function" "$@" || rc=$?
    end=$(date +%s%N)
    printf '%s %s\n' "$kind" "$(((end-start)/1000000))" >>"$MC_TMP/arr-${APP_CONTEXT:-unknown}.timings"
    return "$rc"
}

mc_arr_metrics() {
    [[ -d "${MC_TMP:-}" ]] || return 0
    local inventory_complete=false
    [[ "${MC_COMPONENT_COMPLETED:-false}" != true || -f "$MC_TMP/deferred-$APP_CONTEXT" ]] || inventory_complete=true
    (($((${API_FAILURES:-0}+${HISTORY_FAILURES:-0}+${SIDECAR_FAILURES:-0}))==0)) || inventory_complete=false
    local api=0 hashing=0 total=$(( $(date +%s)-${MC_COMPONENT_STARTED:-$(date +%s)} )) other
    if [[ -f "$MC_TMP/arr-$APP_CONTEXT.timings" ]]; then
      IFS=' ' read -r api hashing < <(awk '$1=="api"{a+=$2}$1=="hash"{h+=$2}END{printf "%.0f %.0f\n",a,h}' "$MC_TMP/arr-$APP_CONTEXT.timings")
    fi
    other=$((total*1000-api-hashing)); ((other>=0)) || other=0
    log INFO "TIMING | total=${total}s api=${api}ms sidecar-capture=${hashing}ms planning-state-other=${other}ms"
    jq -n --arg app "$APP_CONTEXT" --argjson inventoryComplete "$inventory_complete" --argjson api "$api" --argjson hashing "$hashing" --argjson other "$other" \
      --argjson scanned "$((${SERIES_SCANNED:-0}+${MOVIES_SCANNED:-0}))" --argjson present "${FILES_PRESENT:-0}" \
      --argjson sidecars "${SIDECARS_CAPTURED:-0}" --argjson moved "${SIDECARS_QUARANTINED:-0}" --argjson folders "${FOLDERS_REMOVED:-0}" \
      --argjson retired "${ARR_REMOVALS:-0}" --argjson episodeActions "${EPISODE_ACTIONS:-0}" --argjson seasonActions "${SEASON_ACTIONS:-0}" \
      --argjson seriesActions "${SERIES_ACTIONS:-0}" --argjson tagActions "${TAG_ACTIONS:-0}" \
      --argjson confirmed "$((${EPISODES_CONFIRMED:-0}+${MOVIES_CONFIRMED:-0}))" --argjson pending "${FOLDER_CLEANUP_PENDING:-0}" --argjson mover "${MOVER_DEFERRALS:-0}" \
      --argjson errors "$((${API_FAILURES:-0}+${HISTORY_FAILURES:-0}+${SIDECAR_FAILURES:-0}))" \
      '{application:$app,inventoryComplete:$inventoryComplete,confirmedCandidates:$confirmed,episodeActions:$episodeActions,seasonActions:$seasonActions,seriesActions:$seriesActions,tagActions:$tagActions,scanned:$scanned,filesPresent:$present,sidecarsCaptured:$sidecars,sidecarsQuarantined:$moved,foldersRemoved:$folders,
        retired:$retired,pendingFolderCleanup:$pending,moverDeferrals:$mover,errors:$errors,timingMs:{api:$api,sidecarCapture:$hashing,planningStateOther:$other}}' >"$MC_TMP/arr-$APP_CONTEXT.metrics.json" || return 1
    if (( ${MOVER_DEFERRALS:-0}>0 || ${FOLDER_CLEANUP_PENDING:-0}>0 )); then
      jq -n --arg reason "Mover deferrals=${MOVER_DEFERRALS:-0}; pending folders=${FOLDER_CLEANUP_PENDING:-0}; completed actions retained" \
        '{module:"arr",status:"WARNING",reason:$reason,exit:0}' >"$MC_TMP/arr.result.json" || return 1
    fi
}

api_request() { mc_arr_request "$@"; }
capture_kodi_sidecars() { mc_timed_call hash capture_kodi_sidecars_core "$@"; }

# Shared durable operations and notification helpers (one implementation).
unraid_mover_running() {
    pgrep -f '(^|/)(mover|mover\.old)( |$)|mover\.php' >/dev/null 2>&1
}


ops_flush_file() {
    sync -- "$1"
}


ops_publish_checkpoint() {
    local temporary="$1" destination="$2"
    ops_flush_file "$temporary" || return 1
    mv -f -- "$temporary" "$destination" || return 1
    ops_flush_file "$destination" || return 1
    # Some FUSE versions reject directory fsync; syncfs is a checked fallback.
    sync -- "$(dirname -- "$destination")" 2>/dev/null || sync -f "$destination"
}


acquire_operation_coordination() {
    local now until version_file="${UNRAID_VERSION_FILE:-/etc/unraid-version}" version
    if [[ -r "$version_file" ]]; then
        version=$(sed -n 's/^version="\([^"]*\)"/\1/p' "$version_file")
        if [[ "$version" != 7.* ]]; then printf 'Unvalidated Unraid version %s; mutations deferred pending compatibility validation.\n' "$version" >&2; return 75; fi
    fi
    exec {ARR_OPERATION_FD}>"${ARR_BACKUP_GATE:-/run/arr-appdata-coordination.lock}" || return 1
    flock -s -n "$ARR_OPERATION_FD" || return 75
    now=$(date +%s)
    until=$(cat "${ARR_BACKUP_GRACE:-/run/arr-appdata-recovery-until}" 2>/dev/null || true)
    if [[ "$until" =~ ^[0-9]+$ ]] && (( until>now && until<=now+120 )); then return 75; fi
    exec {STATE_EXPORT_FD}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || return 1
    flock -s -n "$STATE_EXPORT_FD" || return 75
}


ops_flush_directory() {
    sync -- "$1" 2>/dev/null || sync -f "$1"
}


ops_flush_move() {
    local source="$1" destination="$2"
    if [[ -f "$destination" ]]; then ops_flush_file "$destination" || return 1
    elif [[ -d "$destination" ]]; then sync -f "$destination" || return 1
    else return 1; fi
    ops_flush_directory "$(dirname -- "$source")" || return 1
    ops_flush_directory "$(dirname -- "$destination")"
}


ops_set_topic() {
    local topic="$1" status="$2" summary="$3" tmp
    ops_notification_state || return 1
    tmp=$(mktemp "${LOG_DIR}/.notify-topic.XXXXXX") || return 1
    jq --arg topic "$topic" --arg status "$status" --arg summary "$summary" --arg at "$(date -Iseconds)" '
      .topics[$topic]={status:$status,summary:$summary,updatedAt:$at}
      | .outbox |= map(
          if .topic==$topic and .kind=="attention" and $status=="healthy" then
            .description as $previousDescription | .message as $previousMessage
            | .kind="resolved" | .importance="normal"
            | .id += ":resolved" | .description="Queued condition resolved before delivery"
            | .message=("Earlier queued condition: "+$previousDescription+"\nEarlier detail: "+$previousMessage[0:600]+"\nCurrent result: "+$summary+"\nThe earlier warning is no longer reported as active.")
          else . end)
    ' "$OPS_NOTIFICATION_STATE" >"$tmp" && mv -f -- "$tmp" "$OPS_NOTIFICATION_STATE" || return 1
    if [[ "${MC_BRIDGE_ACTIVE:-false}" == true ]]; then ops_flush_notifications || return 1;fi
}


ops_notification_state() {
    local tmp
    [[ ! -L "$OPS_NOTIFICATION_STATE" ]] || return 1
    if [[ ! -e "$OPS_NOTIFICATION_STATE" ]]; then
        tmp=$(mktemp "${LOG_DIR}/.notify-state.XXXXXX") || return 1
        printf '%s\n' '{"version":1,"outbox":[],"attention":{},"topics":{}}' >"$tmp" && mv -f -- "$tmp" "$OPS_NOTIFICATION_STATE" || return 1
    fi
    jq -e 'type=="object" and ((.outbox // [])|type)=="array" and ((.topics // {})|type)=="object"' "$OPS_NOTIFICATION_STATE" >/dev/null || return 1
    if jq -e '.outbox==null or .topics==null or any(.outbox[]?; .topic==null or .kind==null or ((.message // "")|utf8bytelength)>8000)' "$OPS_NOTIFICATION_STATE" >/dev/null; then
        local topic=sab-cleanup
        [[ "$OPS_SCRIPT_NAME" != quarantine_lifecycle ]] || topic=lifecycle
        tmp=$(mktemp "$LOG_DIR/.notify-migration.XXXXXX") || return 1
        jq --arg topic "$topic" '
          .outbox //= [] | .topics //= {}
          | .outbox |= [ .[] | .topic //= $topic
            | .kind //= (if .description=="Quarantine review required" then "attention" else "action" end)
            | if (.message|utf8bytelength)>8000 then
                . as $event | range(0;(.message|length);2000) as $offset
                | $event + {id:($event.id+":part"+($offset|tostring)),offset:(($event.offset // 0)+$offset),message:$event.message[$offset:$offset+2000]}
              else . end ]
        ' "$OPS_NOTIFICATION_STATE" >"$tmp" && mv -f -- "$tmp" "$OPS_NOTIFICATION_STATE" || return 1
    fi
}


ops_notify() {
    local importance="$1" subject="$2" description="$3" message="$4" topic="${5:-}" kind="${6:-action}" tmp message_file id
    OPS_NOTIFICATION_DELIVERED=false
    ops_notification_state || return 1
    message_file=$(mktemp "${LOG_DIR}/.notify-message.XXXXXX") || return 1
    printf '%s' "$message" >"$message_file" || return 1
    id=$( { printf '%s\n' "$subject" "$description" "$topic" "$kind"; cat "$message_file"; } | sha256sum | cut -d ' ' -f1)
    tmp=$(mktemp "${LOG_DIR}/.notify-outbox.XXXXXX") || return 1
    jq --arg id "$id" --arg importance "$importance" --arg subject "$subject" --arg description "$description" \
      --arg topic "$topic" --arg kind "$kind" --rawfile message "$message_file" --arg at "$(date -Iseconds)" '
      .outbox //= []
      | if any(.outbox[]; .eventId==$id) then . else
          if $topic!="" and ($kind=="attention" or $kind=="resolved") then
            .outbox |= map(select(.topic!=$topic or (.kind!="attention" and .kind!="resolved")))
          else . end
          | .outbox += [range(0;([$message|length,1]|max);2000) as $offset |
            {eventId:$id,id:($id+":"+($offset|tostring)),importance:$importance,subject:$subject,description:$description,
             message:$message[$offset:$offset+2000],offset:$offset,queuedAt:$at,topic:$topic,kind:$kind}]
        end
    ' "$OPS_NOTIFICATION_STATE" >"$tmp" && mv -f -- "$tmp" "$OPS_NOTIFICATION_STATE" || { rm -f -- "$tmp" "$message_file"; return 1; }
    rm -f -- "$message_file"
    ops_flush_notifications || return 1
    if ! jq -e --arg id "$id" 'any(.outbox[]?;.eventId==$id)' "$OPS_NOTIFICATION_STATE" >/dev/null; then OPS_NOTIFICATION_DELIVERED=true; fi
}


ops_flush_notifications() {
    local tmp selected body importance subject count sent today="$(date +%F)" notify_bin="${NOTIFY_BIN:-${NOTIFY:-}}"
    ops_notification_state || return 1
    if [[ "${MC_BRIDGE_ACTIVE:-false}" == true ]]; then
      mc_handoff_ops "$MC_MODULE" || return 1
      tmp=$(mktemp "$LOG_DIR/.notify-handed-off.XXXXXX") || return 1
      jq '.outbox=[]' "$OPS_NOTIFICATION_STATE" >"$tmp" && ops_publish_checkpoint "$tmp" "$OPS_NOTIFICATION_STATE" || return 1
      return 0
    fi
    jq -e '(.outbox // []|length)>0' "$OPS_NOTIFICATION_STATE" >/dev/null || return 0
    [[ "$(jq -r '.lastSentAt // ""' "$OPS_NOTIFICATION_STATE")" != "$today"* ]] || return 0
    selected=$(mktemp "${LOG_DIR}/.notify-selected.XXXXXX") || return 1
    # Include as many complete sections as fit a 22 KB payload budget. Reserve
    # 2 KB for the summary/footer; count UTF-8 bytes, not display characters.
    jq '
      .topics as $topics
      | [.outbox[] | . as $event
         | ($topics[.topic // ""] // {}) as $topic
         | .effectiveImportance=(if $topic.status=="healthy" and (.kind // "")!="attention" then "normal" else .importance end)
         | .render=("Queued: "+.queuedAt+"\n"+.description+"\n"
           + (if ($topic.summary // "")!="" then "Current status: "+$topic.summary+"\nAction details below were recorded at the queued time.\n" else "" end)
           + "\n"+.message)]
      | sort_by((if .effectiveImportance=="alert" then 0 elif .effectiveImportance=="warning" then 1 else 2 end),.queuedAt,.eventId,(.offset // 0))
      | reduce .[] as $event ({bytes:0,selected:[]};
          (($event.render|utf8bytelength)+10) as $bytes
          | if .bytes+$bytes<=22000 then .bytes+=$bytes | .selected+=[$event] else . end)
      | .selected
    ' "$OPS_NOTIFICATION_STATE" >"$selected" || return 1
    sent=$(jq 'length' "$selected")
    if ((sent==0)); then
        rm -f -- "$selected"; ops_log ERROR "Queued legacy report exceeds the notification byte budget; report preserved for review."; return 1
    fi
    body=$(jq -r 'map(.render)|join("\n\n----------\n\n")' "$selected")
    importance=$(jq -r 'if any(.[];.effectiveImportance=="alert") then "alert" elif any(.[];.effectiveImportance=="warning") then "warning" else "normal" end' "$selected")
    subject=$(jq -r '.[0].subject' "$selected")
    body=$(printf '%s' "$body" | jq -Rsr 'explode | map(select(.!=8205 and .!=8419 and .!=65039 and (. < 9728 or . > 10175) and (. < 126976 or . > 129791))) | implode')
    count=$(jq '.outbox|length' "$OPS_NOTIFICATION_STATE")
    body+=$'\n\n'"Included $sent report section(s); $((count-sent)) additional section(s) remain queued. Completed-action records are retained separately."
    if [[ ! -x "$notify_bin" ]] || ! "$notify_bin" -i "$importance" -s "$subject" -d "Operational actions and exceptions" -m "$body" >/dev/null 2>&1; then
        rm -f -- "$selected"; ops_log ERROR "Notification delivery failed; detailed reports retained in the daily outbox."; return 1
    fi
    tmp=$(mktemp "${LOG_DIR}/.notify-sent.XXXXXX") || return 1
    jq --slurpfile selected "$selected" --arg now "$(date -Iseconds)" \
      '.outbox |= map(. as $event | select(any($selected[0][]; .id==$event.id)|not)) | .lastSentAt=$now' \
      "$OPS_NOTIFICATION_STATE" >"$tmp" && mv -f -- "$tmp" "$OPS_NOTIFICATION_STATE" || return 1
    rm -f -- "$selected"
    ops_log INFO "Accepted module reports into the shared durable outbox containing $sent report sections; queued sections=$((count-sent))."
}


ops_list_pending_operations() {
    local state="${OPS_PENDING_OPERATIONS_FILE:-$LOG_DIR/pending-operations.json}"
    [[ -d "$LOG_DIR" ]] || { printf 'Operation state directory is unavailable: %s\n' "$LOG_DIR" >&2; return 1; }
    if [[ -f "$state" ]]; then jq -e '.version==1 and (.operations|type)=="object"' "$state" >/dev/null && jq '.operations' "$state"
    else printf '{}\n'; fi
}


ops_operation_state() {
    OPS_PENDING_OPERATIONS_FILE="${OPS_PENDING_OPERATIONS_FILE:-$LOG_DIR/pending-operations.json}"
    OPS_OPERATION_AUDIT_FILE="${OPS_OPERATION_AUDIT_FILE:-$LOG_DIR/operation-recovery.jsonl}"
    [[ ! -L "$OPS_PENDING_OPERATIONS_FILE" && ! -L "$OPS_OPERATION_AUDIT_FILE" ]] || return 1
    local tmp
    if [[ ! -e "$OPS_PENDING_OPERATIONS_FILE" ]]; then
        tmp=$(mktemp "$LOG_DIR/.operation-state.XXXXXX") || return 1
        printf '%s\n' '{"version":1,"operations":{}}' >"$tmp"
        ops_publish_checkpoint "$tmp" "$OPS_PENDING_OPERATIONS_FILE" || return 1
    fi
    jq -e '.version==1 and (.operations|type)=="object"' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null
}


ops_operation_paths_valid() {
    local source="$1" destination="$2" source_real root_real destination_real allowed=false root
    [[ -d "$OPS_QUARANTINE_ROOT" && ! -L "$OPS_QUARANTINE_ROOT" ]] || return 1
    source_real=$(realpath -m -- "$source") || return 1
    root_real=$(realpath -m -- "$OPS_QUARANTINE_ROOT") || return 1
    [[ "$source_real" == "$root_real"/* ]] || return 1
    if [[ -n "$destination" ]]; then
        destination_real=$(realpath -m -- "$destination") || return 1
        for root in "${OPS_RESTORE_ROOTS[@]}"; do
            root_real=$(realpath -m -- "$root") || return 1
            [[ "$destination_real" != "$root_real"/* ]] || allowed=true
        done
        [[ "$allowed" == true ]] || return 1
    fi
}


ops_operation_finish() {
    ops_operation_state || return 1
    local id="$1" result="$2" tmp
    jq -c --arg id "$id" --arg result "$result" --argjson now "$(date +%s)" \
      '.operations[$id]+{id:$id,result:$result,at:$now}' "$OPS_PENDING_OPERATIONS_FILE" >>"$OPS_OPERATION_AUDIT_FILE" || return 1
    ops_flush_file "$OPS_OPERATION_AUDIT_FILE" || return 1
    tmp=$(mktemp "$LOG_DIR/.operation-finished.XXXXXX") || return 1
    jq --arg id "$id" 'del(.operations[$id])' "$OPS_PENDING_OPERATIONS_FILE" >"$tmp" && ops_publish_checkpoint "$tmp" "$OPS_PENDING_OPERATIONS_FILE"
}


ops_receipt_in_use() {
    local state="${OPS_PENDING_OPERATIONS_FILE:-$LOG_DIR/pending-operations.json}"
    [[ -f "$state" ]] || return 1
    if ! jq -e '.version==1 and (.operations|type)=="object"' "$state" >/dev/null 2>&1; then
        ops_log ERROR "Invalid operation state; all aged receipts preserved until checkpoints can be reviewed: $state"
        return 0
    fi
    jq -e --arg file "$1" 'any(.operations[]?;.proof==$file)' "$state" >/dev/null
}


ops_resolve_operation() {
    local id="$1" note="$2"
    [[ "$id" =~ ^[a-f0-9]{64}$ && -n "$note" ]] || return 2
    ops_operation_state || return 1
    jq -e --arg id "$id" '.operations[$id]!=null' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null || return 2
    ops_operation_finish "$id" "Operator verified: $note" || return 1
    OPS_RECOVERY_DETAILS="- Operator resolved operation $id: $note. No payload mutation was performed by this command."
    OPS_RECOVERED_COUNT=1
}


log() {
    ops_log "$@"
}


ops_initialize_log() { mc_write_line "$(date '+%Y-%m-%d %H:%M:%S') | DEBUG | media_cleanup/$MC_MODULE | log initialized"; }
ops_rotate_log() { ops_initialize_log; }
ops_log() {
    local level="$1" message line LC_ALL=C
    shift; message="$*"
    [[ "$level" != DEBUG || "${LOG_LEVEL^^}" == DEBUG ]] || return 0
    case "$level" in WARN|WARNING|ERROR|CRITICAL)
        OPS_ATTENTION_DETAILS+="- [$level] $message"$'\n'
        if [[ -n "${OPS_ATTENTION_FILE:-}" ]]; then printf '%s\n' "- [$level] $message" >>"$OPS_ATTENTION_FILE"; fi;; esac
    line=$(usr_ops_log_line "$level" "$MC_MODULE" "$message")
    printf '%s\n' "$line" >&2
    mc_write_line "$line"
}

# MODULE: ARR -- isolated policy, state and traps.
mc_arr() (
MC_MODULE_STATUS="";MC_MODULE_REASON=""
set -uo pipefail
IFS=$'\n\t'
umask 077

# Release version for logs, notifications, and the HTTP User-Agent. State-file
# version fields below are independent schema versions and must not be changed
# merely when this release version changes.
readonly SCRIPT_VERSION="2.10.0"

###############################################################################
# CONFIGURATION
###############################################################################

# All active state, logs, and locks live below this one directory. Sonarr and
# Radarr retain separate state files because their schemas and actions differ.
RUNTIME_DIR="${MC_ROOT}/arr"
LOG_FILE="$MC_ROOT/media-cleanup.log"
LOCK_DIR="$RUNTIME_DIR/arr-delete-sync-tag.lock"
SONARR_STATE_FILE="$RUNTIME_DIR/sonarr-state.json"
SONARR_STATE_BACKUP="$RUNTIME_DIR/sonarr-state.json.bak"
RADARR_STATE_FILE="$RUNTIME_DIR/radarr-state.json"
RADARR_STATE_BACKUP="$RUNTIME_DIR/radarr-state.json.bak"
NOTIFICATION_STATE_FILE="$RUNTIME_DIR/notification-state.json"
PENDING_ACTIONS_FILE="$RUNTIME_DIR/pending-actions.json"
ACTION_RECEIPTS_FILE="$RUNTIME_DIR/action-receipts.jsonl"
PENDING_NOTIFICATIONS_FILE="$RUNTIME_DIR/pending-notifications.jsonl"

# No trailing slash. Each application keeps its own API key.
SONARR_URL="$MC_SONARR_URL"
SONARR_API_KEY="$MC_SONARR_API_KEY"
RADARR_URL="$MC_RADARR_URL"
RADARR_API_KEY="$MC_RADARR_API_KEY"

# Execution is enabled for this personal installation; set true for a preview.
# Dry-run still creates state and confirms candidates, but never changes either
# application. One switch keeps both workflows in the same operating mode.
DRY_RUN="$MC_DRY_RUN"
CONFIRMATION_RUNS=2

# A single optional freshness policy applies to both applications. Enabling it
# requests an all-library RescanSeries and RescanMovie before snapshots. This
# can spin up media disks and significantly extend the run.
TRIGGER_LIBRARY_RESCAN=false
RESCAN_TIMEOUT_SECONDS=7200
RESCAN_POLL_SECONDS=10

# Both workflows record application-native delete history when available.
# History is supporting audit evidence by default because it can be pruned and
# does not prove Plex initiated the deletion.
INSPECT_DELETE_HISTORY=true
REQUIRE_DELETE_HISTORY_EVENT=false
MAX_HISTORY_INSPECTIONS_PER_RUN=50

# Sonarr actions.
SONARR_UNMONITOR_SEASON=true

# Default-off final safeguard.  When true, a series can be unmonitored only
# after the state proves it once had downloaded media, every such file has a
# confirmed deletion, no current episode has a file or remains monitored, and
# every normal season is already (or is being) unmonitored.  Specials/Season 0
# do not block this action.  The script NEVER disables a series with no proven
# download history in its state file.
SONARR_UNMONITOR_SERIES=false

# Full-series retirement is deliberately separate from the ordinary series
# switch above. A partial season deletion can never enter this path. An ended,
# previously-downloaded series becomes eligible only after every file is gone,
# sidecar/folder cleanup is complete, and every historical deletion has passed
# the normal confirmation policy. Continuing series additionally require the
# opt-in tag unless SONARR_RETIRE_CONTINUING_SERIES is explicitly enabled.
SONARR_RETIRE_FULLY_DELETED_SERIES=true
SONARR_RETIRE_CONTINUING_SERIES=true
SONARR_RETIREMENT_REQUIRED_TAG="retire-series"
SONARR_RETIREMENT_EXEMPT_TAG="keep-in-arr"
SONARR_RETIREMENT_PENDING_TAG="retirement-pending"

# Sonarr tags are series-level only.  The first tag means one or more seasons
# of that series were unmonitored after a Plex deletion; it does NOT mean that
# the entire series was deleted.  The second tag is added only if this script
# unmonitors the series itself.  Existing series tags are always preserved.
PLEX_DELETED_SEASON_TAG="plex-deleted-season"
PLEX_DELETED_SERIES_TAG="plex-deleted-series"

# Radarr actions. A missing file becomes a candidate only after Radarr has also
# unmonitored the movie, matching Radarr's Unmonitor Deleted Movies behaviour.
RADARR_REQUIRE_MOVIE_UNMONITORED=true
PLEX_DELETED_MOVIE_TAG="plex-deleted"

# Radarr remains authoritative for Unmonitor Deleted Movies. The watchdog can
# request one item-specific rescan, then reports a movie that stays fileless and
# monitored; it never unmonitors the movie itself.
RADARR_MONITORED_FILELESS_WARNING_RUNS=2
RADARR_MONITORED_FILELESS_WARNING_HOURS=24
RADARR_MONITORED_FILELESS_RESCAN=false

# A confirmed, unmonitored, fileless movie can be retired from Radarr after the
# common hold period. The delete call never deletes files and adds an import
# exclusion so Arr lists cannot add the title again automatically.
RADARR_RETIRE_FULLY_DELETED_MOVIES=true
RADARR_RETIREMENT_EXEMPT_TAG="keep-in-arr"
RADARR_RETIREMENT_PENDING_TAG="retirement-pending"

# Shared retirement and state-retention policy. Ninety days comfortably
# outlives the current 45-day quarantine lifecycle.
ARR_RETIREMENT_DAYS=90
ARR_RETIREMENT_WARNING_DAYS=7
STATE_PRUNE_ABSENT_DAYS=90

# Kodi sidecar quarantine. While media exists, the script records recognized
# NFO, artwork, and external subtitle files. After the whole movie or series is
# confirmed fileless, surviving unchanged files are moved into the existing
# quarantine_lifecycle.sh layout. Recognized sidecars created after the original
# capture must remain unchanged across two cleanup runs before they are moved.
# Other media-linked extras remain the responsibility of Sonarr/Radarr and their
# Recycling Bin setting.
QUARANTINE_KODI_SIDECARS=true
CAPTURE_LATE_KODI_SIDECARS=true
QUARANTINE_ROOT="/mnt/user/media/bin"
# Normalize only QUARANTINE_ROOT and its contents. Supplying an owner without a
# group deliberately preserves each entry's existing group ownership.
QUARANTINE_OWNER="nobody"
QUARANTINE_DIRECTORY_MODE="0755"
QUARANTINE_FILE_MODE="0644"
MOVIES_ROOT="/mnt/user/media/movies"
SERIES_ROOT="/mnt/user/media/series"

# Root paths exactly as Sonarr/Radarr return them through their APIs. Keep them
# equal to the host roots above when the containers use identical paths. For a
# typical remap, use values such as /tv and /movies here; only the suffix below
# each root is transferred to the matching host root.
SONARR_API_SERIES_ROOT="/data/series"
RADARR_API_MOVIES_ROOT="/data/movies"

REQUIRE_SIDECAR_HASH_MATCH=true
REMOVE_EMPTY_MEDIA_FOLDERS=true
# Show a bounded list of files, links, or other non-directory entries that
# prevent rmdir-only cleanup. The manifest remains pending until they are gone.
CLEANUP_REMAINING_LOG_MAX_ITEMS=10
# Let API/state work continue, but defer sidecar moves and rmdir cleanup while
# Unraid Mover is active. Pending manifests remain eligible for the next run.
DEFER_SIDECAR_CLEANUP_WHILE_MOVER=true
MAX_SIDECAR_SIZE_MB=100

# Personal metadata extensions that are safe to treat like other sidecars.
# Files outside the built-in and configured sets are never moved; they become
# classified folder blockers. Keep this comma-separated and extension-only.
EXTRA_SIDECAR_EXTENSIONS="xml,json,txt,sfv,md5,sha1,sha256,url,webp"
# Exact named Kodi actor/extra-artwork and OS-cache files may be captured only
# after content signature checks. Newly recognized files still need two stable
# path/size/hash observations; unknown files and remaining videos stay blocked.
AUTO_RECOGNIZE_KNOWN_AUXILIARY=true

# An unchanged blocker is notified once, when its contents change, when it is
# resolved, and at this low-frequency reminder interval.
FOLDER_BLOCKER_REMINDER_DAYS=14

# One notification is rendered after both application workflows finish. A run
# with no actions or attention items sends nothing. Unchanged folder blockers
# are state-suppressed until their contents change or cleanup resolves.
SEND_GROUPED_NOTIFICATIONS=true
NOTIFY_DRY_RUN=false
NOTIFY_BIN="${MC_PROXY:-$MC_NOTIFY_BIN}"
NOTIFICATION_MAX_ITEMS=25
NOTIFICATION_ITEM_MAX_CHARS=600

# A progress line is written for the first series and then every N series, so
# a long library inspection is visibly active without filling the log.
PROGRESS_LOG_EVERY=25
LOG_LEVEL="INFO"
QUARANTINE_COORDINATION_LOCK="/tmp/arr_metadata_quarantine.lock"
ACTION_RECEIPT_RETENTION_DAYS=365

# ---------------------------------------------------------------------------
# Persistent logging
# ---------------------------------------------------------------------------
# Storage is strictly bounded while the script is running, not only when the
# next daily run begins. With the defaults below, storage is approximately:
#
#   active log      1 MiB
#   two backups     2 MiB
#   total maximum   3 MiB
#
# Existing backups that exceed the per-file limit, numbered generations beyond
# the retained count, and expired backups are removed automatically. A runaway
# active log is discarded instead of being copied into a huge backup.
LOG_MAX_BYTES=$((1 * 1024 * 1024)) # Maximum size of each log file: 1 MiB.
LOG_BACKUP_FILES=2                 # Keep .1 and .2 in addition to the active log.
LOG_RETENTION_DAYS=30              # Also remove backups older than 30 days; 0 disables age cleanup.
LOG_LINE_MAX_BYTES=4096            # Truncate a single unusually large message at 4 KiB.
LOG_RUNAWAY_MULTIPLIER=4           # Discard an inherited active log above 4x the normal limit.

HTTP_CONNECT_TIMEOUT=10
HTTP_MAX_TIME=90
HTTP_RETRIES=2
# Retry read-back only; a failed or delayed mutation is never blindly replayed.
API_VERIFY_ATTEMPTS=6
API_VERIFY_DELAY_SECONDS=2
USER_AGENT="Arr-Delete-Sync-Tag/$SCRIPT_VERSION"

###############################################################################
# END CONFIGURATION
###############################################################################

APP_CONTEXT="MAIN"
RUN_ID="$(date +%Y%m%d_%H%M%S)_$$"
NOTIFICATION_FINALIZED=false
LOCK_HELD=false
WORK_STATE=""
CURRENT_SNAPSHOT_FILE=""
SIDECAR_BATCH_FILE=""
SIDECAR_ENTRY_FILE=""
ARR_NAME=""
ARR_URL=""
ARR_API_KEY=""
ARR_TEMP_PREFIX=""
ARR_USER_AGENT=""
VERIFY_RUNTIME_DIR=""
QUARANTINE_RUN_ID=""
NOTIFICATION_BATCH=""
LOG_READY=false
LOG_FAILURE_REPORTED=false
LOG_CLEANED_FILES=0
LOG_CLEANED_BYTES=0

SIDECARS_CAPTURED=0
SIDECARS_QUARANTINED=0
SIDECARS_NATIVE_MISSING=0
SIDECARS_CHANGED=0
SIDECARS_LATE_CANDIDATES=0
SIDECARS_LATE_CONFIRMED=0
SIDECAR_FAILURES=0
FOLDERS_REMOVED=0
FOLDER_CLEANUP_PENDING=0
MOVER_DEFERRALS=0
MOVER_GUARD_NOTICE_LOGGED=false

CLEANUP_OPERATION_DETAILS=""
CLEANUP_EXCEPTION_DETAILS=""
CLEANUP_COMPLETE=false
CLEANUP_FOLDER_PENDING=false
CLEANUP_QUARANTINED=0
CLEANUP_NATIVE_MISSING=0
CLEANUP_CHANGED=0
CLEANUP_FOLDERS_REMOVED=0
CLEANUP_PROGRESS_QUARANTINED=0
CLEANUP_PROGRESS_NATIVE_MISSING=0
CLEANUP_PROGRESS_FOLDERS_REMOVED=0
CLEANUP_QUARANTINE_RUN_ID=""
CLEANUP_LATE_CANDIDATES='[]'
CLEANUP_LATE_CANDIDATE_COUNT=0
CLEANUP_LATE_CONFIRMED_COUNT=0
CLEANUP_BLOCKER_COUNT=0
CLEANUP_BLOCKER_DETAILS=""
CLEANUP_BLOCKER_SUMMARY=""
CLEANUP_BLOCKER_SIGNATURE=""
CLEANUP_BLOCKER_STABLE_RUNS=0
CLEANUP_BLOCKERS_JSON='[]'
CLEANUP_PRESERVE_MANIFEST=false

SONARR_QUEUE_JSON='{"records":[]}'
SONARR_QUEUE_AVAILABLE=false
RADARR_QUEUE_JSON='{"records":[]}'
RADARR_QUEUE_AVAILABLE=false
STATE_PRUNED=0
RETIREMENTS_STARTED=0
RETIREMENTS_CANCELLED=0
ARR_REMOVALS=0

log() {
    local level="$1"
    local message line
    local LC_ALL=C
    shift

    message="$*"
    if [[ "$level" == ERROR || "$level" == WARNING ]] && [[ " ${FUNCNAME[*]} " == *" quarantine_recorded_sidecars "* ]]; then
        CLEANUP_EXCEPTION_DETAILS+="$message"$'\n'
    fi
    [[ "$level" != DEBUG || "${LOG_LEVEL^^}" == DEBUG ]] || return 0
    if [[ "$LOG_LINE_MAX_BYTES" =~ ^[0-9]+$ ]] &&
       (( LOG_LINE_MAX_BYTES > 0 )) &&
       (( ${#message} > LOG_LINE_MAX_BYTES ));
    then
        message="${message:0:LOG_LINE_MAX_BYTES} ... [line truncated]"
    fi

    line=$(OPS_RUN_ID="$RUN_ID" usr_ops_log_line "$level" "arr/$APP_CONTEXT" "$message")
    printf '%s\n' "$line" >&2

    if [[ "$LOG_READY" == true ]] && ! append_persistent_log "$line"; then
        LOG_READY=false
        if [[ "$LOG_FAILURE_REPORTED" == false ]]; then
            LOG_FAILURE_REPORTED=true
            printf '[%s] [MAIN] [WARNING] Persistent log became unavailable: %s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$LOG_FILE" >&2
        fi
    fi
}

notification_hash() {
    printf '%s' "$1" | sha256sum | cut -d ' ' -f 1
}

strip_notification_emoji() {
    printf '%s' "$1" | jq -Rs -r '
        explode
        | map(
            select(
                . != 8205
                and . != 8419
                and . != 65039
                and (. < 9728 or . > 10175)
                and (. < 126976 or . > 129791)
            )
          )
        | implode
        '
}

initialize_grouped_notifications() {
    local next invalid_backup
    INITIALIZATION_FAILURE_REASON=""
    if [[ "$SEND_GROUPED_NOTIFICATIONS" == true ]]; then
        if [[ -f "$NOTIFICATION_STATE_FILE" ]] && ! jq -e 'type=="object" and ((.attention // {})|type)=="object"' "$NOTIFICATION_STATE_FILE" >/dev/null 2>&1; then
            invalid_backup="${NOTIFICATION_STATE_FILE}.invalid.$(date '+%Y%m%d_%H%M%S')"
            cp -f -- "$NOTIFICATION_STATE_FILE" "$invalid_backup" || return 1
            log WARNING "Invalid notification suppression state preserved at $invalid_backup; durable pending events retained."
            rm -f -- "$NOTIFICATION_STATE_FILE" || return 1
        fi
        if [[ ! -e "$NOTIFICATION_STATE_FILE" ]]; then
            next=$(mktemp "$RUNTIME_DIR/.notification-state.XXXXXX") || return 1
            printf '%s\n' '{"version":1,"attention":{},"lastSentAt":null}' >"$next" && mv -f -- "$next" "$NOTIFICATION_STATE_FILE" || return 1
        fi
        NOTIFICATION_BATCH="$PENDING_NOTIFICATIONS_FILE"
        : >>"$NOTIFICATION_BATCH" || return 1
    fi
    # Existing empty/corrupt action journals are never interpreted as no work.
    # Initialize the outbox first so a journal failure can still be reported.
    if [[ ! -e "$PENDING_ACTIONS_FILE" ]]; then
        next=$(mktemp "$RUNTIME_DIR/.pending-actions.XXXXXX") || return 1
        printf '%s\n' '{"version":1,"actions":{}}' >"$next" && ops_publish_checkpoint "$next" "$PENDING_ACTIONS_FILE" || return 1
    fi
    if ! jq -e '.version==1 and (.actions|type)=="object"' "$PENDING_ACTIONS_FILE" >/dev/null; then
        INITIALIZATION_FAILURE_REASON="Action journal is invalid: $PENDING_ACTIONS_FILE. Existing records were preserved; no Arr or sidecar mutations were attempted."
        return 1
    fi
    if [[ -s "$ACTION_RECEIPTS_FILE" ]]; then
        local receipts_tmp="$RUNTIME_DIR/.action-receipts.$$"
        jq -c --argjson cutoff "$(( $(date +%s)-ACTION_RECEIPT_RETENTION_DAYS*86400 ))" \
          'select(.finishedAt >= $cutoff)' "$ACTION_RECEIPTS_FILE" >"$receipts_tmp" && mv -f -- "$receipts_tmp" "$ACTION_RECEIPTS_FILE" || return 1
    fi
}

append_notification_record() {
    local event="$1"
    local severity="$2"
    local app_name="$3"
    local key="$4"
    local signature="$5"
    local title="$6"
    local detail="$7"

    [[ "$SEND_GROUPED_NOTIFICATIONS" == true ]] || return 0
    [[ -n "$NOTIFICATION_BATCH" && -f "$NOTIFICATION_BATCH" ]] || return 0

    jq -cn \
        --arg event "$event" \
        --arg severity "$severity" \
        --arg app "$app_name" \
        --arg key "$key" \
        --arg signature "$signature" \
        --arg title "$title" \
        --arg detail "$detail" \
        --arg run "$RUN_ID" --arg queuedAt "$(date -Iseconds)" \
        --argjson chunk "$NOTIFICATION_ITEM_MAX_CHARS" \
        'range(0;([$detail|length,1]|max);$chunk) as $offset | {
            runId:$run,queuedAt:$queuedAt,chunkOffset:$offset,
            event: $event,
            severity: $severity,
            app: $app,
            key: $key,
            signature: $signature,
            title: ($title + if ($detail|length)>$chunk then " (detail part " + (($offset/$chunk+1)|tostring) + ")" else "" end),
            detail: $detail[$offset:$offset+$chunk]
        }' >> "$NOTIFICATION_BATCH"
}

queue_action_notification() {
    local app_name="$1"
    local title="$2"
    local detail="$3"

    if [[ "$DRY_RUN" == true ]]; then
        [[ "$NOTIFY_DRY_RUN" == true ]] || return 0
        title="DRY RUN: $title"
    fi

    append_notification_record action INFO "$app_name" "" "" "$title" "$detail"
}

queue_attention_notification() {
    local severity="$1"
    local app_name="$2"
    local title="$3"
    local detail="$4"

    append_notification_record attention "$severity" "$app_name" "" "" "$title" "$detail"
}

timestamp_to_epoch() {
    local timestamp="$1"
    local normalized

    [[ -n "$timestamp" ]] || return 1
    date -d "$timestamp" +%s 2>/dev/null && return 0

    # BSD date fallback keeps local development checks usable; Unraid uses the
    # GNU path above. Convert +0800 to a colon-free format accepted by %z.
    normalized="${timestamp/T/ }"
    date -j -f '%Y-%m-%d %H:%M:%S%z' "$normalized" +%s 2>/dev/null
}

notification_reminder_due() {
    local last_notified_at="$1"
    local reminder_days="$2"
    local last_epoch now_epoch

    [[ "$reminder_days" =~ ^[1-9][0-9]*$ ]] || return 1
    last_epoch="$(timestamp_to_epoch "$last_notified_at" || true)"
    [[ "$last_epoch" =~ ^[0-9]+$ ]] || return 0
    now_epoch="$(date +%s)"
    (( now_epoch - last_epoch >= reminder_days * 86400 ))
}

remove_queued_stateful_notifications() {
    local key="$1" tmp
    [[ -s "$NOTIFICATION_BATCH" ]] || return 0
    tmp=$(mktemp "$RUNTIME_DIR/.notification-current.XXXXXX") || return 1
    jq -c --arg key "$key" 'select(.key!=$key or .event=="action")' "$NOTIFICATION_BATCH" >"$tmp" && mv -f -- "$tmp" "$NOTIFICATION_BATCH"
}

queue_stateful_attention_notification() {
    local severity="$1"
    local app_name="$2"
    local key="$3"
    local signature="$4"
    local title="$5"
    local detail="$6"
    local reminder_days="$7"
    local previous previous_at

    [[ "$SEND_GROUPED_NOTIFICATIONS" == true ]] || return 0
    [[ -n "$NOTIFICATION_BATCH" && -f "$NOTIFICATION_BATCH" ]] || return 0

    if jq -e --arg key "$key" --arg signature "$signature" \
        'select(.key==$key and (.event=="resolved" or (.event=="attention" and .signature!=$signature)))' \
        "$NOTIFICATION_BATCH" >/dev/null 2>&1; then
        remove_queued_stateful_notifications "$key" || return 1
    fi

    previous="$(jq -r --arg key "$key" '.attention[$key].signature // ""' \
        "$NOTIFICATION_STATE_FILE" 2>/dev/null || true)"
    previous_at="$(jq -r --arg key "$key" '.attention[$key].lastNotifiedAt // ""' \
        "$NOTIFICATION_STATE_FILE" 2>/dev/null || true)"

    if [[ "$previous" == "$signature" ]] &&
       ! notification_reminder_due "$previous_at" "$reminder_days"; then
        return 0
    fi
    if jq -e --arg key "$key" 'select(.key == $key)' "$NOTIFICATION_BATCH" \
        >/dev/null 2>&1; then
        return 0
    fi

    append_notification_record attention "$severity" "$app_name" "$key" \
        "$signature" "$title" "$detail"
}

queue_stateful_resolution_notification() {
    local app_name="$1"
    local key="$2"
    local title="$3"
    local detail="$4"

    [[ "$SEND_GROUPED_NOTIFICATIONS" == true ]] || return 0
    if ! jq -e --arg key "$key" '.attention[$key] != null' "$NOTIFICATION_STATE_FILE" >/dev/null 2>&1 &&
       ! jq -e --arg key "$key" 'select(.key==$key and .event!="action")' "$NOTIFICATION_BATCH" >/dev/null 2>&1; then return 0; fi
    remove_queued_stateful_notifications "$key" || return 1
    append_notification_record resolved INFO "$app_name" "$key" "" "$title" "$detail"
}

queue_folder_blocker_notification() {
    local app_name="$1"
    local item_id="$2"
    local title="$3"
    local media_path="$4"
    local key signature
    local detail

    [[ "$SEND_GROUPED_NOTIFICATIONS" == true ]] || return 0
    [[ -n "$NOTIFICATION_BATCH" && -f "$NOTIFICATION_BATCH" ]] || return 0

    key="folder:${app_name,,}:${item_id}"
    detail="Directory: ${media_path}"$'\n'
    detail+="Blocking entries: ${CLEANUP_BLOCKER_COUNT}"
    [[ -n "$CLEANUP_BLOCKER_SUMMARY" ]] && detail+=$'\n'"Types: ${CLEANUP_BLOCKER_SUMMARY}"
    detail+=$'\n'"Stable cleanup runs: ${CLEANUP_BLOCKER_STABLE_RUNS}"
    if (( CLEANUP_LATE_CANDIDATE_COUNT > 0 )); then
        detail+=$'\n'"Recognized late sidecars awaiting next-run confirmation: ${CLEANUP_LATE_CANDIDATE_COUNT}"
    fi
    [[ -n "$CLEANUP_BLOCKER_DETAILS" ]] && detail+=$'\n'"${CLEANUP_BLOCKER_DETAILS}"
    [[ -n "$CLEANUP_EXCEPTION_DETAILS" ]] && detail+=$'\n'"Preserved entries and reasons:"$'\n'"${CLEANUP_EXCEPTION_DETAILS}"
    signature="${CLEANUP_BLOCKER_SIGNATURE:-$(notification_hash "$media_path|$CLEANUP_BLOCKER_COUNT|$CLEANUP_LATE_CANDIDATE_COUNT|$CLEANUP_BLOCKER_DETAILS")}"
    queue_stateful_attention_notification WARNING "$app_name" "$key" \
        "$signature" "$title" "$detail" "$FOLDER_BLOCKER_REMINDER_DAYS"
}

queue_folder_resolution_notification() {
    local app_name="$1"
    local item_id="$2"
    local title="$3"
    local media_path="$4"
    local key

    [[ "$SEND_GROUPED_NOTIFICATIONS" == true ]] || return 0
    [[ -n "$NOTIFICATION_BATCH" && -f "$NOTIFICATION_BATCH" ]] || return 0

    key="folder:${app_name,,}:${item_id}"
    queue_stateful_resolution_notification "$app_name" "$key" "$title" "Pending directory cleanup completed: $media_path"

}

queue_cleanup_action_notification() {
    local app_name="$1"
    local title="$2"
    local media_path="$3"
    local detail=""

    (( CLEANUP_QUARANTINED > 0 || CLEANUP_FOLDERS_REMOVED > 0 )) || return 0

    detail="Sidecars quarantined: ${CLEANUP_QUARANTINED}; empty directories removed: ${CLEANUP_FOLDERS_REMOVED}."
    if (( CLEANUP_LATE_CONFIRMED_COUNT > 0 )); then
        detail+=$'\n'"Late sidecars confirmed unchanged and quarantined: ${CLEANUP_LATE_CONFIRMED_COUNT}."
    fi
    detail+=$'\n'"Media path: ${media_path}"
    detail+=$'\n'"${CLEANUP_OPERATION_DETAILS}"
    queue_action_notification "$app_name" "$title cleanup" "$detail"
}

mark_notification_batch_delivered() {
    local delivered_file="$1"
    local next now

    now="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    next="$(mktemp "$RUNTIME_DIR/.notification-state.XXXXXX")" || return 1

    if ! jq -c --arg now "$now" --slurpfile events "$delivered_file" '
        .version = 1
        | .attention //= {}
        | reduce $events[] as $event (.;
            if $event.event == "attention" and $event.key != "" then
                .attention[$event.key] = {
                    signature: $event.signature,
                    app: $event.app,
                    title: $event.title,
                    lastNotifiedAt: $now
                }
            elif $event.event == "resolved" and $event.key != "" then
                del(.attention[$event.key])
            else
                .
            end
          )
        | .lastSentAt = $now
        ' "$NOTIFICATION_STATE_FILE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$NOTIFICATION_STATE_FILE"
}

# Select only this run's failures; API helpers run in subshells, so read the
# durable log rather than relying on an in-memory last-error variable.
# Media integrity recovery owns this hold until a replacement passes full
# planned-range verification. Review/uncertain states never expire silently.
# Library protection ends after full replacement verification. Disposal problems
# concern the retired original only and must not block healthy library media.
# A persistent empty journal is installed with the audit. Missing/unreadable
# state is uncertainty, never permission to process a temporarily missing title.
media_recovery_journal_valid() {
    local file="${MEDIA_INTEGRITY_RECOVERY_FILE:-/mnt/vault/cloud/logs/script/media_integrity_audit/recovery.json}"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e '.schema==1 and .workflow=="arr-native" and (.actions|type)=="object" and all(.actions[];
      (.app=="Sonarr" or .app=="Radarr") and (.parentId|type)=="number" and .parentId>0 and
      (.status as $s|["required","selected","grab_intent","downloading","imported","verifying","recovered","blocked","review","cancelled","resolved","retry_wait"]|index($s))!=null)' "$file" >/dev/null 2>&1
}
media_recovery_ids() {
    local app="$1" output="$2" file="${MEDIA_INTEGRITY_RECOVERY_FILE:-/mnt/vault/cloud/logs/script/media_integrity_audit/recovery.json}"
    media_recovery_journal_valid || return 1
    jq -c --arg app "$app" '[.actions[]|select(.app==$app and (.status as $s|["recovered","resolved","cancelled"]|index($s))==null)|.parentId]|unique' "$file" >"$output"
}
media_recovery_app_held() {
    local app="$1" parent="${2:-0}" file="${MEDIA_INTEGRITY_RECOVERY_FILE:-/mnt/vault/cloud/logs/script/media_integrity_audit/recovery.json}" rc=0
    media_recovery_journal_valid || return 0
    jq -e --arg app "$app" --argjson parent "$parent" 'any(.actions[];.app==$app and ($parent==0 or .parentId==$parent) and (.status as $s|["recovered","resolved","cancelled"]|index($s))==null)' "$file" >/dev/null 2>&1 || rc=$?
    ((rc!=1))
}


# Preserve the complete catalog for pruning/existence checks. Only this RAM
# action view excludes exact protected IDs; held movie state is never falsified.
radarr_action_snapshot() {
    local source="$1" output="$2" holds="$3"
    media_recovery_ids Radarr "$holds" || return 1
    jq -c --slurpfile holds "$holds" '[.[]|select(.id as $id | ($holds[0]|index($id))==null)]' "$source" >"$output"
}

current_workflow_error_details() {
    awk -F ' \| ' -v run="run=$RUN_ID" '
      index($0,run) && $2=="ERROR" {reasons[++n]=$5 ": " $6}
      END {start=n>5?n-4:1; for(i=start;i<=n;i++) print "- " reasons[i];
        if(n==0) print "- See the per-application attention entries for this run."}
    ' "$LOG_FILE"
}

send_grouped_notification() {
    local LC_ALL=C
    local total actions attention resolved errors
    local importance description mode body="" record entry shown=0 omitted
    local sorted delivered

    NOTIFICATION_FINALIZED=true
    [[ "$SEND_GROUPED_NOTIFICATIONS" == true ]] || return 0
    [[ -n "$NOTIFICATION_BATCH" && -s "$NOTIFICATION_BATCH" ]] || return 0
    if [[ "${MC_BRIDGE_ACTIVE:-false}" == true ]]; then
      mc_handoff_arr "$NOTIFICATION_BATCH" || return 1
      mark_notification_batch_delivered "$NOTIFICATION_BATCH" || return 1
      : >"$NOTIFICATION_BATCH"
      return 0
    fi
    if [[ "$(jq -r '.lastSentAt // ""' "$NOTIFICATION_STATE_FILE")" == "$(date +%Y-%m-%d)"* ]]; then
        log INFO "Daily grouped notification already sent; pending events retained for the next day."
        return 0
    fi
    local deduplicated="$RUNTIME_DIR/.outbox-deduplicated.$$"
    jq -sc 'unique_by([.event,.app,.key,.signature,.title,.detail,(if .event=="action" then .runId else "" end)]) | .[]' "$NOTIFICATION_BATCH" >"$deduplicated" && mv -f -- "$deduplicated" "$NOTIFICATION_BATCH" || return 1

    total="$(wc -l < "$NOTIFICATION_BATCH" | tr -d ' ')"
    actions="$(jq -s '[.[] | select(.event == "action")] | length' "$NOTIFICATION_BATCH")"
    attention="$(jq -s '[.[] | select(.event == "attention")] | length' "$NOTIFICATION_BATCH")"
    resolved="$(jq -s '[.[] | select(.event == "resolved")] | length' "$NOTIFICATION_BATCH")"
    errors="$(jq -s '[.[] | select(.severity == "ERROR")] | length' "$NOTIFICATION_BATCH")"

    importance=normal
    (( attention > 0 )) && importance=warning
    (( errors > 0 )) && importance=alert
    mode=EXECUTE
    [[ "$DRY_RUN" == true ]] && mode="DRY RUN"
    description="Daily grouped summary: actions=${actions}, attention=${attention}, resolved=${resolved}"
    body="Arr Delete Sync v${SCRIPT_VERSION} | Run ${RUN_ID}"$'\n'
    body+="Mode: ${mode}; events may include retained earlier-run actions."$'\n'
    body+="Latest invocation: Sonarr exit=${sonarr_rc:-unknown}; Radarr exit=${radarr_rc:-unknown}. Earlier timestamps describe previous runs, not a new failure in this run."$'\n'
    body+="Actions: ${actions} | Attention: ${attention} | Resolved: ${resolved}"$'\n\n'

    sorted="$(mktemp "$RUNTIME_DIR/.notification-render.XXXXXX")" || return 1
    delivered="$(mktemp "$RUNTIME_DIR/.notification-delivered.XXXXXX")" || {
        rm -f -- "$sorted"
        return 1
    }
    : > "$delivered"
    jq -sc '
        sort_by(
            if .severity == "ERROR" then 0
            elif .event == "attention" then 1
            elif .event == "resolved" then 2
            else 3
            end,
            .app,
            (.title | sub(" \\(detail part [0-9]+\\)$"; "")),
            (.chunkOffset // 0)
        ) | .[]
        ' "$NOTIFICATION_BATCH" > "$sorted" || {
        rm -f -- "$sorted" "$delivered"
        return 1
    }

    while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        (( shown < NOTIFICATION_MAX_ITEMS )) || break
        entry="$(jq -r --argjson maximum "$NOTIFICATION_ITEM_MAX_CHARS" '
            (if .event == "attention" then "ATTENTION"
             elif .event == "resolved" then "RESOLVED"
             else "ACTION" end) as $label
            | ("- [" + .app + "] " + .title + " [" + $label + "]" + " (" + (.queuedAt // "earlier run") + ")"
              + if .detail == "" then "" else "\n  " + (.detail | gsub("[\\r\\n]+"; "\n  ")) end) as $text
            | $text
            ' <<< "$record")"
        if (( ${#body}+${#entry}+2>22000 )); then continue; fi
        body+="$entry"$'\n\n'
        printf '%s\n' "$record" >> "$delivered"
        ((shown += 1))
    done < "$sorted"
    rm -f -- "$sorted"

    if ((shown==0)); then rm -f -- "$delivered"; log ERROR "No queued section fits the daily notification byte budget; all events preserved."; return 1; fi
    omitted=$((total - shown))
    if (( omitted > 0 )); then
        body+="${omitted} additional item(s) remain in the durable notification queue and will be included in a later daily notification."$'\n'
    fi

    if [[ ! -x "$NOTIFY_BIN" ]]; then
        rm -f -- "$delivered"
        log ERROR "Grouped notification helper is unavailable: $NOTIFY_BIN"
        return 1
    fi

    description="$(strip_notification_emoji "$description")"
    body="$(strip_notification_emoji "$body")"

    if ! usr_ops_notify "$NOTIFY_BIN" \
        -i "$importance" \
        -s "Arr Delete Sync" \
        -d "$description" \
        -m "$body" >/dev/null 2>&1; then
        rm -f -- "$delivered"
        log ERROR "Could not send grouped Arr delete notification."
        return 1
    fi

    mark_notification_batch_delivered "$delivered" || {
        rm -f -- "$delivered"
        log ERROR "Notification was sent, but its suppression state could not be updated."
        return 1
    }
    local remaining="$RUNTIME_DIR/.notification-remaining.$$"
    jq -c --slurpfile delivered "$delivered" '. as $event | select(($delivered | index($event)) == null)' \
        "$NOTIFICATION_BATCH" >"$remaining" && mv -f -- "$remaining" "$NOTIFICATION_BATCH" || return 1
    rm -f -- "$delivered"
    log INFO "Accepted Arr report into the shared durable outbox with $shown of $total queued item(s)."
}

die() {
    queue_attention_notification ERROR "$APP_CONTEXT" "Workflow stopped" "$*" || true
    log ERROR "$*"
    exit 1
}

cleanup_app() {
    local status=$?
    [[ ! -d "${MC_TMP:-}" || -f "$MC_TMP/arr-${APP_CONTEXT:-UNKNOWN}.metrics.json" ]] || mc_arr_metrics || true
    [[ -n "$WORK_STATE" && -f "$WORK_STATE" ]] && rm -f -- "$WORK_STATE"
    [[ -n "$CURRENT_SNAPSHOT_FILE" && -f "$CURRENT_SNAPSHOT_FILE" ]] &&
        rm -f -- "$CURRENT_SNAPSHOT_FILE"
    [[ -n "$SIDECAR_BATCH_FILE" && -f "$SIDECAR_BATCH_FILE" ]] &&
        rm -f -- "$SIDECAR_BATCH_FILE"
    [[ -n "$SIDECAR_ENTRY_FILE" && -f "$SIDECAR_ENTRY_FILE" ]] &&
        rm -f -- "$SIDECAR_ENTRY_FILE"
    trap - EXIT
    exit "$status"
}

notify_preflight_failure() {
    local reason="$1" marker="/tmp/arr-delete-preflight-$(date +%F).notified"
    printf '%s\n' "$reason" >&2
    [[ ! -e "$marker" && -x "$NOTIFY_BIN" ]] || return 0
    if usr_ops_notify "$NOTIFY_BIN" -i alert -s "Arr Delete Sync" -d "Preflight failed; cleanup preserved" \
      -m "$reason"$'\n'"No Arr API changes, sidecar moves, folder removals or retirements were attempted. Existing state and media were preserved." >/dev/null 2>&1; then : >"$marker"; fi
}

cleanup_main() {
    local status=$?
    if [[ "$NOTIFICATION_FINALIZED" != true && -n "$NOTIFICATION_BATCH" && -s "$NOTIFICATION_BATCH" ]]; then
        send_grouped_notification || true
    fi
    if [[ "$LOCK_HELD" == true ]]; then
        rm -f -- "$LOCK_DIR/pid"
        rmdir -- "$LOCK_DIR" 2>/dev/null || true
    fi
    if [[ "$VERIFY_RUNTIME_DIR" == /tmp/arr-delete-verify.* ]]; then rm -rf -- "$VERIFY_RUNTIME_DIR"; fi
    trap - EXIT
    exit "$status"
}




append_persistent_log() { mc_write_line "$1"; }


initialize_logging() { mc_write_line "$(date '+%Y-%m-%d %H:%M:%S') | INFO | media_cleanup/arr v$MC_VERSION | run=$RUN_ID | MAIN | Logger initialized" || return 1; LOG_READY=true; }
# Temporary files live beside the state files so replacement stays atomic.
# This runs only after the unified exclusive lock is held.
remove_stale_temp_files() {
    local file removed=0 nullglob_was_set=false
    local -a stale_files

    shopt -q nullglob && nullglob_was_set=true
    shopt -s nullglob
    stale_files=(
        "$RUNTIME_DIR"/.state-*
        "$RUNTIME_DIR"/.episodes.*
        "$RUNTIME_DIR"/.movies.*
        "$RUNTIME_DIR"/.sonarr-*
        "$RUNTIME_DIR"/.radarr-*
        "$RUNTIME_DIR"/.sidecars.*
        "$RUNTIME_DIR"/.notification-*
    )
    [[ "$nullglob_was_set" == true ]] || shopt -u nullglob

    for file in "${stale_files[@]}"; do
        [[ -f "$file" ]] || continue
        rm -f -- "$file"
        ((removed += 1))
    done

    (( removed == 0 )) ||
        log INFO "Removed $removed stale temporary file(s) from an interrupted previous run."
}

valid_relative_path() {
    local relative="$1"
    [[ -n "$relative" &&
       "$relative" != /* &&
       "$relative" != "." &&
       "$relative" != ".." &&
       "$relative" != ../* &&
       "$relative" != */../* &&
       "$relative" != */.. &&
       "$relative" != *$'\n'* ]]
}

extension_in_configured_list() {
    local extension="${1,,}"
    [[ ",${EXTRA_SIDECAR_EXTENSIONS,,}," == *",${extension},"* ]]
}

is_video_extension() {
    case "${1,,}" in
        mkv|mp4|m4v|avi|mov|wmv|ts|m2ts|mts|mpg|mpeg|webm|vob|iso|strm)
            return 0
            ;;
    esac
    return 1
}

# Recognize only named Kodi artwork directories and named OS cache files.
# A matching suffix alone is insufficient: check the binary/content signature.
is_known_auxiliary_sidecar() {
    local relative="${2,,}" file="$3" header name="${2##*/}" directory="${2%/*}"
    [[ "$AUTO_RECOGNIZE_KNOWN_AUXILIARY" == true && -f "$file" && ! -L "$file" ]] || return 1
    name="${relative##*/}"; directory="${relative%/*}"
    header=$(od -An -tx1 -N12 -- "$file" | tr -d ' \n') || return 1
    case "$relative" in
        .ds_store) [[ "$header" == 0000000142756431* ]] ;;
        thumbs.db) [[ "$header" == d0cf11e0a1b11ae1* ]] ;;
        desktop.ini)
            [[ $(file_size_bytes "$file") -le 16384 ]] &&
              LC_ALL=C grep -Eq '^\[\.ShellClassInfo\][[:space:]]*$' "$file"
            ;;
        .actors/*|actors/*|extrafanart/*|extrathumbs/*)
            # No recursive directory rule: arbitrary nested content stays blocked.
            [[ "${directory,,}" == .actors || "${directory,,}" == actors || "${directory,,}" == extrafanart || "${directory,,}" == extrathumbs ]] || return 1
            case "${name##*.}" in
                jpg|jpeg|tbn) [[ "$header" == ffd8ff* ]] ;;
                png) [[ "$header" == 89504e470d0a1a0a* ]] ;;
                webp) [[ "$header" == 52494646????????57454250 ]] ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

classify_cleanup_entry() {
    local app_name="$1"
    local relative="$2"
    local entry="$3"
    local lower="${relative,,}"
    local name="${lower##*/}"
    local extension="${name##*.}"

    if [[ -L "$entry" ]]; then
        printf 'symlink'
        return
    fi
    if [[ ! -f "$entry" ]]; then
        printf 'special-entry'
        return
    fi
    if is_video_extension "$extension"; then
        printf 'remaining-video'
        return
    fi
    if jq -e --arg relative "$relative" \
        'any(.[]?; .relativePath == $relative)' \
        >/dev/null 2>&1 <<< "$CLEANUP_LATE_CANDIDATES"; then
        printf 'late-sidecar-confirmation'
        return
    fi
    case "$extension" in
        nfo|srt|ass|ssa|vtt|sub|idx|sup|smi|sami)
            printf 'recognized-sidecar'
            return
            ;;
    esac
    if extension_in_configured_list "$extension"; then
        printf 'configured-sidecar'
        return
    fi
    if [[ "$name" =~ ^(poster|banner|fanart|clearart|characterart|discart|keyart|landscape|logo|backdrop|clearlogo|folder|thumb)\.(jpg|jpeg|png|webp)$ ]] ||
       [[ "$app_name" == sonarr &&
          "$name" =~ ^season([0-9]{2,}|-all|-specials)-(poster|banner|fanart|landscape|thumb)\.(jpg|jpeg|png|webp)$ ]]; then
        printf 'recognized-artwork'
        return
    fi
    if is_known_auxiliary_sidecar "$app_name" "$relative" "$entry"; then
        printf 'known-auxiliary-awaiting-confirmation'
        return
    fi
    printf 'unknown-file'
}

normalize_quarantine_permissions() {
    local target="$1"
    local quarantine_real target_real
    local failed=false

    [[ -e "$QUARANTINE_ROOT" && ! -L "$QUARANTINE_ROOT" ]] || {
        log ERROR "Quarantine root is unavailable or unsafe for permission normalization: $QUARANTINE_ROOT"
        return 1
    }
    quarantine_real="$(realpath -- "$QUARANTINE_ROOT" 2>/dev/null)" || return 1
    target_real="$(realpath -- "$target" 2>/dev/null)" || return 1

    if [[ "$target_real" != "$quarantine_real" &&
          "$target_real" != "$quarantine_real"/* ]]; then
        log ERROR "Refusing to change ownership or permissions outside quarantine: $target_real"
        return 1
    fi

    # find does not follow symlinks by default. chown -h changes a symlink's
    # own owner; chmod is limited to real directories and regular files.
    if ! find "$target_real" -xdev ! -user "$QUARANTINE_OWNER" -exec chown -h -- "$QUARANTINE_OWNER" {} +; then
        log ERROR "Unable to set quarantine owner '$QUARANTINE_OWNER': $target_real"
        failed=true
    fi
    if ! find "$target_real" -xdev -type d ! -perm "$QUARANTINE_DIRECTORY_MODE" \
        -exec chmod -- "$QUARANTINE_DIRECTORY_MODE" {} +; then
        log ERROR "Unable to set quarantine directory mode $QUARANTINE_DIRECTORY_MODE: $target_real"
        failed=true
    fi
    if ! find "$target_real" -xdev -type f ! -perm "$QUARANTINE_FILE_MODE" \
        -exec chmod -- "$QUARANTINE_FILE_MODE" {} +; then
        log ERROR "Unable to set quarantine file mode $QUARANTINE_FILE_MODE: $target_real"
        failed=true
    fi

    [[ "$failed" == false ]]
}

map_arr_media_path() {
    local api_path="$1"
    local api_root="$2"
    local host_root="$3"
    local relative

    api_path="${api_path%/}"
    api_root="${api_root%/}"
    host_root="${host_root%/}"
    [[ "$api_path" == "$api_root"/* ]] || return 1
    relative="${api_path#"$api_root"/}"
    valid_relative_path "$relative" || return 1
    printf '%s/%s' "$host_root" "$relative"
}

# Print a canonical media directory only when it is a child of the configured
# root. Missing media directories are allowed for post-cleanup verification;
# an existing path must be a real directory and never a symlink.
media_path_under_root() {
    local media_path="$1"
    local media_root="$2"
    local root_real candidate relative

    media_root="${media_root%/}"
    media_path="${media_path%/}"
    root_real="$(realpath -- "$media_root" 2>/dev/null)" || return 1
    [[ "$media_path" == "$media_root"/* ]] || return 1
    relative="${media_path#"$media_root"/}"
    valid_relative_path "$relative" || return 1
    [[ ! -L "$media_path" ]] || return 1
    [[ ! -e "$media_path" || -d "$media_path" ]] || return 1
    if [[ -e "$media_path" ]]; then
        candidate="$(realpath -- "$media_path" 2>/dev/null)" || return 1
        [[ "$candidate" == "$root_real"/* ]] || return 1
    else
        candidate="${root_real}/${relative}"
    fi
    printf '%s' "$candidate"
}

file_size_bytes() {
    stat -c '%s' -- "$1" 2>/dev/null || stat -f '%z' -- "$1" 2>/dev/null
}

# Hash bounded groups in RAM: three tools per group instead of per sidecar.
# Every eligible file is freshly hashed. Device/inode/size/nanosecond mtime and
# ctime plus file type must remain identical across the hash pass. Quarantine
# still independently validates the saved SHA-256 immediately before moving.
mc_sidecar_path_bytes() { local LC_ALL=C; MC_PATH_BYTES=${#1}; }

mc_sidecar_batch() (
    local batch="$1";shift
    mc_work_allowed "${APP_CONTEXT:-arr}" || return 75
    (( $#>0 )) || return 0
    local temp file size identity type hash row i=0
    local -a files=() sizes=() identities=()
    temp=$(mktemp -d "${VERIFY_RUNTIME_DIR:-${TMPDIR:-/tmp}}/sidecar-batch.XXXXXX") || return 1
    trap 'rm -rf -- "$temp"' EXIT
    # A failed stat or hash rejects the entire capture, preserving the previous
    # manifest. NUL framing includes all filename bytes, including newlines.
    LC_ALL=C stat --printf='%s\0%d:%i:%s:%y:%z\0%F\0' -- "$@" >"$temp/before" || return 1
    exec 7<"$temp/before"
    for file in "$@"; do
        IFS= read -r -d '' size <&7 && IFS= read -r -d '' identity <&7 && IFS= read -r -d '' type <&7 || return 1
        [[ "$type" == 'regular file' || "$type" == 'regular empty file' ]] || return 1
        [[ "$size" =~ ^[0-9]+$ ]] || return 1
        if ((size>MAX_SIDECAR_SIZE_MB*1024*1024)); then
            log WARNING "Skipping oversized $app_name sidecar (${size} bytes): $file"
            continue
        fi
        files+=("$file");sizes+=("$size");identities+=("$identity")
    done
    exec 7<&-
    (( ${#files[@]}>0 )) || return 0
    sha256sum --zero -- "${files[@]}" >"$temp/hashes" || return 1
    LC_ALL=C stat --printf='%s\0%d:%i:%s:%y:%z\0%F\0' -- "${files[@]}" >"$temp/after" || return 1
    exec 7<"$temp/after" 6<"$temp/hashes"
    for file in "${files[@]}"; do
        IFS= read -r -d '' size <&7 && IFS= read -r -d '' identity <&7 && IFS= read -r -d '' type <&7 || return 1
        IFS= read -r -d '' row <&6 || return 1
        hash="${row:0:64}"
        if [[ ! "$hash" =~ ^[a-f0-9]{64}$ || "$row" != "$hash  $file" ||
              "$size" != "${sizes[$i]}" || "$identity" != "${identities[$i]}" ||
              ( "$type" != 'regular file' && "$type" != 'regular empty file' ) ]]; then
            log WARNING "Sidecar changed or could not be hashed while capturing it: $file"
            return 1
        fi
        printf '%s\0%s\0%s\0' "${file#"$media_real"/}" "$size" "$hash" >>"$batch" || return 1
        i=$((i+1))
    done
    # Reject unexpected/truncated tool output rather than pairing the wrong hash.
    if IFS= read -r -d '' row <&6 || [[ -n "$row" ]]; then return 1;fi
    exec 7<&- 6<&-
)

capture_kodi_sidecars_core() (
    local app_name="$1"
    local media_path="$2"
    local media_root="$3"
    local media_relative_paths="$4"
    local media_real relative lower name rel_dir file_name stem candidate
    local file eligible capture_failed=0 allow_auxiliary="${5:-false}"
    local list_file batch_bytes=0
    local -a pending_files=()
    local batch_file
    batch_file="$(mktemp "${VERIFY_RUNTIME_DIR:-${TMPDIR:-/tmp}}/sidecar-capture.XXXXXX")" || return 1
    list_file="${batch_file}.inventory"
    trap 'rm -f -- "$batch_file" "$list_file"' EXIT
    local type extension
    local -A exact_paths=()

    media_real="$(media_path_under_root "$media_path" "$media_root")" || {
        log ERROR "Cannot capture $app_name sidecars from unsafe media path: $media_path"
        return 1
    }
    [[ -d "$media_real" ]] || {
        log ERROR "Cannot capture $app_name sidecars because the media directory is missing: $media_path"
        return 1
    }
    jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1 \
        <<< "$media_relative_paths" || return 1

    if [[ "$app_name" == sonarr ]]; then
        exact_paths["tvshow.nfo"]=1
    else
        exact_paths["movie.nfo"]=1
    fi
    for type in poster banner fanart clearart characterart discart keyart \
        landscape logo backdrop clearlogo folder thumb; do
        for extension in jpg jpeg png; do
            exact_paths["${type}.${extension}"]=1
        done
    done

    while IFS= read -r relative; do
        valid_relative_path "$relative" || {
            log WARNING "Skipping unsafe $app_name media-relative path while capturing sidecars: $relative"
            capture_failed=1
            continue
        }
        rel_dir="${relative%/*}"
        [[ "$rel_dir" == "$relative" ]] && rel_dir=""
        file_name="${relative##*/}"
        stem="${file_name%.*}"
        [[ -n "$stem" && "$stem" != "$file_name" ]] || continue

        candidate="${stem}.nfo"
        [[ -n "$rel_dir" ]] && candidate="${rel_dir}/${candidate}"
        exact_paths["${candidate,,}"]=1

        if [[ "$app_name" == sonarr ]]; then
            for extension in jpg jpeg png; do
                candidate="${stem}-thumb.${extension}"
                [[ -n "$rel_dir" ]] && candidate="${rel_dir}/${candidate}"
                exact_paths["${candidate,,}"]=1
            done
        else
            for type in thumb poster banner fanart clearart discart keyart landscape logo backdrop clearlogo; do
                for extension in jpg jpeg png; do
                    candidate="${stem}-${type}.${extension}"
                    [[ -n "$rel_dir" ]] && candidate="${rel_dir}/${candidate}"
                    exact_paths["${candidate,,}"]=1
                done
            done
        fi
    done < <(jq -r '.[]' <<< "$media_relative_paths")

    # A traversal error must not silently publish an incomplete inventory.
    find "$media_real" -type f -print0 >"$list_file" || return 1
    while IFS= read -r -d '' file; do
        relative="${file#"$media_real"/}"
        valid_relative_path "$relative" || continue
        lower="${relative,,}"
        name="${lower##*/}"
        eligible=false

        if [[ -n "${exact_paths[$lower]+present}" ]]; then
            eligible=true
        elif [[ "$app_name" == sonarr &&
                "$name" =~ ^season([0-9]{2,}|-all|-specials)-(poster|banner|fanart|landscape|thumb)\.(jpg|jpeg|png)$ ]]; then
            eligible=true
        else
            extension="${name##*.}"
            case "$extension" in
                nfo|srt|ass|ssa|vtt|sub|idx|sup|smi|sami)
                    eligible=true
                    ;;
            esac
            if [[ "$eligible" == false ]] && extension_in_configured_list "$extension"; then
                eligible=true
            fi
        fi
        if [[ "$eligible" == false && "$allow_auxiliary" == true ]] && is_known_auxiliary_sidecar "$app_name" "$relative" "$file"; then
            eligible=true
        fi
        [[ "$eligible" == true ]] || continue

        mc_sidecar_path_bytes "$file"
        pending_files+=("$file");batch_bytes=$((batch_bytes+MC_PATH_BYTES+1))
        # Bound both count and argument bytes; never build an unbounded argv.
        if (( ${#pending_files[@]}>=64 || batch_bytes>=32768 )); then
            mc_sidecar_batch "$batch_file" "${pending_files[@]}" || capture_failed=1
            pending_files=();batch_bytes=0
        fi
    done < "$list_file"
    if (( ${#pending_files[@]}>0 )); then
        mc_sidecar_batch "$batch_file" "${pending_files[@]}" || capture_failed=1
    fi

    (( capture_failed == 0 )) || return 1
    # Assemble the complete RAM-backed batch once, preserving all path bytes.
    jq -Rsc 'split("\u0000") | .[:-1] | . as $v |
       [range(0;length;3) as $i | {relativePath:$v[$i],size:($v[$i+1]|tonumber),sha256:$v[$i+2]}] | unique_by(.relativePath)' "$batch_file"
)
# Build a file-backed cleanup plan without placing a potentially large sidecar
# list in jq's argument vector. A recognized file absent from the original
# manifest is moved only when its path, size, and hash match the candidate saved
# by the previous cleanup run.
build_sidecar_cleanup_plan() {
    local app_name="$1"
    local media_path="$2"
    local media_root="$3"
    local manifest="$4"
    local current_file plan

    if [[ "$CAPTURE_LATE_KODI_SIDECARS" != true ]]; then
        jq '{
            moveEntries: (.files // []),
            lateCandidates: [],
            lateConfirmed: [],
            observedLate: []
        }' <<< "$manifest"
        return
    fi

    current_file="$(mktemp "${VERIFY_RUNTIME_DIR:-$RUNTIME_DIR}/.sidecars.late-current.XXXXXX")" || return 1
    if ! capture_kodi_sidecars "$app_name" "$media_path" "$media_root" '[]' true \
        > "$current_file"; then
        rm -f -- "$current_file"
        return 1
    fi

    plan="$(jq -c --slurpfile current_source "$current_file" '
        def same_file($left; $right):
            ($left.relativePath == $right.relativePath)
            and ($left.size == $right.size)
            and (($left.sha256 | ascii_downcase) == ($right.sha256 | ascii_downcase));

        . as $manifest
        | ($manifest.files // []) as $recorded
        | ($manifest.lateSidecarCandidates // []) as $previous
        | ($current_source[0] // []) as $current
        | [
            $current[] as $candidate
            | select(all($recorded[]; .relativePath != $candidate.relativePath))
            | $candidate
          ] as $late
        | [
            $late[] as $candidate
            | select(any($previous[]; same_file($candidate; .)))
            | $candidate
          ] as $confirmed
        | [
            $late[] as $candidate
            | select(all($previous[]; same_file($candidate; .) | not))
            | $candidate
          ] as $pending
        | {
            moveEntries: (($recorded + $confirmed) | unique_by(.relativePath)),
            lateCandidates: $pending,
            lateConfirmed: $confirmed,
            observedLate: $late
          }
        ' <<< "$manifest")" || {
        rm -f -- "$current_file"
        return 1
    }
    rm -f -- "$current_file"
    printf '%s' "$plan"
}

contains_video_files() {
    local media_path="$1"
    find "$media_path" -type f \
        \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' \
           -o -iname '*.avi' -o -iname '*.mov' -o -iname '*.wmv' \
           -o -iname '*.ts' -o -iname '*.m2ts' -o -iname '*.mts' \
           -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.webm' \
           -o -iname '*.vob' -o -iname '*.iso' -o -iname '*.strm' \) \
        -print -quit | grep -q .
}


remove_empty_media_dirs() {
    local media_path="$1"
    local directory removed=0

    [[ -d "$media_path" ]] || return 0
    while IFS= read -r -d '' directory; do
        [[ ! -L "$directory" ]] || continue
        if rmdir -- "$directory" 2>/dev/null; then
            ((removed += 1))
            CLEANUP_OPERATION_DETAILS+="Removed empty directory with rmdir: $directory"$'\n'
            log INFO "Removed empty media directory: $directory"
        fi
    done < <(find "$media_path" -depth -type d -empty -print0 2>/dev/null)
    CLEANUP_FOLDERS_REMOVED=$((CLEANUP_FOLDERS_REMOVED + removed))
}

log_media_cleanup_blockers() {
    local app_name="$1"
    local media_path="$2"
    local manifest="${3:-null}"
    local entry relative classification size mtime
    local remaining=0 shown=0 additional
    local entry_word="entries"
    local previous_signature previous_runs

    CLEANUP_BLOCKER_COUNT=0
    CLEANUP_BLOCKER_DETAILS=""
    CLEANUP_BLOCKER_SUMMARY=""
    CLEANUP_BLOCKER_SIGNATURE=""
    CLEANUP_BLOCKER_STABLE_RUNS=0
    CLEANUP_BLOCKERS_JSON='[]'

    while IFS= read -r -d '' entry; do
        ((remaining += 1))
        relative="${entry#"$media_path"/}"
        relative="${relative//$'\n'/ }"
        classification="$(classify_cleanup_entry "$app_name" "$relative" "$entry")"
        size="$(file_size_bytes "$entry" 2>/dev/null || printf -- '-1')"
        mtime="$(stat -c '%Y' -- "$entry" 2>/dev/null || stat -f '%m' -- "$entry" 2>/dev/null || printf 0)"
        [[ "$size" =~ ^-?[0-9]+$ ]] || size=-1
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        CLEANUP_BLOCKERS_JSON="$(jq \
            --arg relative "$relative" \
            --arg classification "$classification" \
            --argjson size "$size" \
            --argjson mtime "$mtime" \
            '. + [{relativePath:$relative,type:$classification,size:$size,mtime:$mtime}]' \
            <<< "$CLEANUP_BLOCKERS_JSON")" || return 1
        if (( shown < CLEANUP_REMAINING_LOG_MAX_ITEMS )); then
            log WARNING "$app_name folder cleanup blocker [$classification]: $relative"
            [[ -z "$CLEANUP_BLOCKER_DETAILS" ]] || CLEANUP_BLOCKER_DETAILS+=$'\n'
            CLEANUP_BLOCKER_DETAILS+="- $relative [$classification]"
            ((shown += 1))
        fi
    done < <(find "$media_path" -mindepth 1 ! -type d -print0 2>/dev/null)

    CLEANUP_BLOCKER_SUMMARY="$(jq -r '
        group_by(.type)
        | map((.[0].type) + "=" + (length | tostring))
        | join(", ")
        ' <<< "$CLEANUP_BLOCKERS_JSON")" || return 1
    CLEANUP_BLOCKER_SIGNATURE="$(notification_hash "$(jq -cS . <<< "$CLEANUP_BLOCKERS_JSON")")"
    previous_signature="$(jq -r '.folderBlockers.signature // ""' <<< "$manifest" 2>/dev/null || true)"
    previous_runs="$(jq -r '.folderBlockers.stableRuns // 0' <<< "$manifest" 2>/dev/null || true)"
    [[ "$previous_runs" =~ ^[0-9]+$ ]] || previous_runs=0
    if [[ -n "$CLEANUP_BLOCKER_SIGNATURE" &&
          "$CLEANUP_BLOCKER_SIGNATURE" == "$previous_signature" ]]; then
        CLEANUP_BLOCKER_STABLE_RUNS=$((previous_runs + 1))
    else
        CLEANUP_BLOCKER_STABLE_RUNS=1
    fi

    if (( remaining == 0 )); then
        log WARNING "$app_name media directory still exists, but no remaining non-directory entry could be enumerated; permissions, a mount, or a concurrent writer may be preventing removal: $media_path"
    elif (( remaining > shown )); then
        additional=$((remaining - shown))
        [[ "$additional" == 1 ]] && entry_word="entry"
        log WARNING "$app_name folder cleanup has $additional additional blocking $entry_word not shown."
    fi

    entry_word="entries"
    [[ "$remaining" == 1 ]] && entry_word="entry"
    CLEANUP_BLOCKER_COUNT="$remaining"
    log WARNING "$app_name media directory remains with $remaining blocking $entry_word ($CLEANUP_BLOCKER_SUMMARY); folder cleanup stays pending and will be retried: $media_path"
}

# Return the captured manifest, a safe rmdir-only manifest when no sidecars
# were captured, a folder retry manifest for a cleanup recorded by an older
# release, or a completed sentinel when that recorded directory is absent.
prepare_sidecar_cleanup_manifest() {
    local item_id="$1"
    local current_media_path="$2"
    local media_root="$3"
    local bucket="$4"
    local manifest action

    manifest="$(jq -c --arg key "$item_id" \
        '.sidecarManifests[$key] // null' "$WORK_STATE")" || return 1
    if [[ "$manifest" != null ]]; then
        printf '%s' "$manifest"
        return 0
    fi

    action="$(jq -c --arg key "$item_id" \
        '.sidecarCleanupActions[$key] // null' "$WORK_STATE")" || return 1
    if [[ "$action" == null ]]; then
        log INFO "No pre-deletion sidecar manifest exists; attempting safe rmdir-only cleanup for confirmed fileless media path: $current_media_path"
        jq -cn \
            --arg media_path "$current_media_path" \
            --arg media_root "$media_root" \
            --arg bucket "$bucket" \
            --arg now "$RUN_AT" '
            {
                mediaPath: $media_path,
                mediaRoot: $media_root,
                bucket: $bucket,
                capturedAt: $now,
                files: [],
                lateSidecarCandidates: [],
                cleanupPending: false,
                cleanupProgress: {
                    quarantineRunId: null,
                    quarantinedFiles: 0,
                    nativeMissingFiles: 0,
                    foldersRemoved: 0
                }
            }'
        return
    fi

    if [[ ! -e "$current_media_path" && ! -L "$current_media_path" ]]; then
        printf '%s' '{"cleanupAlreadyRecorded":true}'
        return 0
    fi

    log INFO "Reopening previously recorded sidecar cleanup because its media directory still exists: $current_media_path"
    jq -cn \
        --arg media_path "$current_media_path" \
        --arg media_root "$media_root" \
        --arg bucket "$bucket" \
        --arg now "$RUN_AT" \
        --argjson action "$action" '
        {
            mediaPath: $media_path,
            mediaRoot: $media_root,
            bucket: $bucket,
            capturedAt: ($action.completedAt // $now),
            files: [],
            lateSidecarCandidates: [],
            cleanupPending: true,
            cleanupPendingSince: ($action.completedAt // $now),
            cleanupProgress: {
                quarantineRunId: ($action.quarantineRunId // null),
                quarantinedFiles: ($action.quarantinedFiles // 0),
                nativeMissingFiles: ($action.nativeMissingFiles // 0),
                foldersRemoved: ($action.foldersRemoved // 0)
            }
        }'
}

mark_sidecar_folder_cleanup_pending() {
    local item_id="$1"
    local media_path="$2"
    local media_root="$3"
    local bucket="$4"
    local next
    local total_quarantined total_native_missing total_folders_removed

    total_quarantined=$((CLEANUP_PROGRESS_QUARANTINED + CLEANUP_QUARANTINED))
    total_native_missing=$((CLEANUP_PROGRESS_NATIVE_MISSING + CLEANUP_NATIVE_MISSING))
    total_folders_removed=$((CLEANUP_PROGRESS_FOLDERS_REMOVED + CLEANUP_FOLDERS_REMOVED))
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-folder-pending.XXXXXX")" || return 1

    if ! jq \
        --arg key "$item_id" \
        --arg now "$RUN_AT" \
        --arg media_path "$media_path" \
        --arg media_root "$media_root" \
        --arg bucket "$bucket" \
        --arg quarantine_run_id "$CLEANUP_QUARANTINE_RUN_ID" \
        --argjson quarantined "$total_quarantined" \
        --argjson native_missing "$total_native_missing" \
        --argjson folders_removed "$total_folders_removed" \
        --argjson late_candidates "$CLEANUP_LATE_CANDIDATES" \
        --argjson blockers "$CLEANUP_BLOCKERS_JSON" \
        --arg blocker_signature "$CLEANUP_BLOCKER_SIGNATURE" \
        --arg blocker_summary "$CLEANUP_BLOCKER_SUMMARY" \
        --argjson blocker_stable_runs "$CLEANUP_BLOCKER_STABLE_RUNS" \
        --argjson preserve_manifest "$CLEANUP_PRESERVE_MANIFEST" '
        (.sidecarManifests[$key] // {}) as $old_manifest
        | (.sidecarCleanupActions[$key] // {}) as $old_action
        | .sidecarManifests[$key] = {
            mediaPath: $media_path,
            mediaRoot: $media_root,
            bucket: $bucket,
            capturedAt: ($old_manifest.capturedAt // $old_action.completedAt // $now),
            files: (if $preserve_manifest then ($old_manifest.files // []) else [] end),
            lateSidecarCandidates: $late_candidates,
            lateSidecarCandidateAt: (
                if ($late_candidates | length) > 0
                then $now
                else null
                end
            ),
            cleanupPending: true,
            cleanupPendingSince: ($old_manifest.cleanupPendingSince // $old_action.completedAt // $now),
            cleanupLastAttemptAt: $now,
            cleanupProgress: {
                quarantineRunId: (if $quarantine_run_id == "" then null else $quarantine_run_id end),
                quarantinedFiles: $quarantined,
                nativeMissingFiles: $native_missing,
                foldersRemoved: $folders_removed
            },
            folderBlockers: {
                signature: $blocker_signature,
                summary: $blocker_summary,
                firstSeenAt: (
                    if ($old_manifest.folderBlockers.signature // "") == $blocker_signature
                    then ($old_manifest.folderBlockers.firstSeenAt // $now)
                    else $now
                    end
                ),
                lastSeenAt: $now,
                stableRuns: $blocker_stable_runs,
                entries: $blockers
            }
          }
        | del(.sidecarCleanupActions[$key])
        ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

# Move unchanged files from a pre-deletion manifest plus recognized late
# sidecars confirmed by two cleanup runs. Missing files are treated as already
# handled by Arr's native Recycling Bin path. A changed, symlinked, or unsafe
# file is never moved and keeps the manifest pending.
quarantine_recorded_sidecars() {
    local app_name="$1"
    local bucket="$2"
    local media_root="$3"
    local current_media_path="$4"
    local manifest="$5"
    local recorded_media_path media_real root_real quarantine_real run_root
    local entry relative source source_real size expected_size hash expected_hash
    local root_relative destination destination_parent destination_real
    local files_count
    local cleanup_progress
    local cleanup_plan
    local late_candidate

    CLEANUP_OPERATION_DETAILS=""
    CLEANUP_EXCEPTION_DETAILS=""
    CLEANUP_COMPLETE=false
    CLEANUP_FOLDER_PENDING=false
    CLEANUP_QUARANTINED=0
    CLEANUP_NATIVE_MISSING=0
    CLEANUP_CHANGED=0
    CLEANUP_FOLDERS_REMOVED=0
    CLEANUP_PROGRESS_QUARANTINED=0
    CLEANUP_PROGRESS_NATIVE_MISSING=0
    CLEANUP_PROGRESS_FOLDERS_REMOVED=0
    CLEANUP_QUARANTINE_RUN_ID=""
    CLEANUP_LATE_CANDIDATES='[]'
    CLEANUP_LATE_CANDIDATE_COUNT=0
    CLEANUP_LATE_CONFIRMED_COUNT=0
    CLEANUP_BLOCKER_COUNT=0
    CLEANUP_BLOCKER_DETAILS=""
    CLEANUP_BLOCKER_SUMMARY=""
    CLEANUP_BLOCKER_SIGNATURE=""
    CLEANUP_BLOCKER_STABLE_RUNS=0
    CLEANUP_BLOCKERS_JSON='[]'
    CLEANUP_PRESERVE_MANIFEST=false

    [[ "$QUARANTINE_RUN_ID" =~ ^[0-9]{8}_[0-9]{6}_[0-9]+$ ]] || return 1
    [[ ! -L "$QUARANTINE_ROOT" ]] || return 1

    if [[ "$manifest" == null || -z "$manifest" ]]; then
        log WARNING "No pre-deletion Kodi sidecar manifest exists for $app_name path $current_media_path; cleanup was skipped."
        return 3
    fi
    if ! jq -e 'type == "object" and (.mediaPath | type == "string") and (.files | type == "array")' \
        >/dev/null 2>&1 <<< "$manifest"; then
        log ERROR "Invalid Kodi sidecar manifest for $app_name path $current_media_path."
        return 1
    fi

    cleanup_progress="$(jq -r '
        [
            (.cleanupProgress.quarantinedFiles // 0),
            (.cleanupProgress.nativeMissingFiles // 0),
            (.cleanupProgress.foldersRemoved // 0),
            (.cleanupProgress.quarantineRunId // "")
        ] | @tsv
        ' <<< "$manifest")" || return 1
    IFS=$'\t' read -r \
        CLEANUP_PROGRESS_QUARANTINED \
        CLEANUP_PROGRESS_NATIVE_MISSING \
        CLEANUP_PROGRESS_FOLDERS_REMOVED \
        CLEANUP_QUARANTINE_RUN_ID <<< "$cleanup_progress"
    [[ "$CLEANUP_PROGRESS_QUARANTINED" =~ ^[0-9]+$ ]] || return 1
    [[ "$CLEANUP_PROGRESS_NATIVE_MISSING" =~ ^[0-9]+$ ]] || return 1
    [[ "$CLEANUP_PROGRESS_FOLDERS_REMOVED" =~ ^[0-9]+$ ]] || return 1

    recorded_media_path="$(jq -r '.mediaPath' <<< "$manifest")"
    media_real="$(media_path_under_root "$current_media_path" "$media_root")" || {
        log ERROR "Refusing $app_name sidecar cleanup for unsafe media path: $current_media_path"
        return 1
    }
    root_real="$(realpath -- "$media_root" 2>/dev/null)" || return 1
    if [[ "${recorded_media_path%/}" != "${current_media_path%/}" ]]; then
        log WARNING "$app_name media path changed after manifest capture; cleanup was deferred: $recorded_media_path -> $current_media_path"
        return 0
    fi

    files_count="$(jq '.files | length' <<< "$manifest")"
    if [[ ! -e "$media_real" ]]; then
        CLEANUP_NATIVE_MISSING="$files_count"
        CLEANUP_COMPLETE=true
        log INFO "$app_name media directory is already absent; recorded sidecars require no further cleanup: $media_real"
        return 0
    fi
    if contains_video_files "$media_real"; then
        log WARNING "$app_name cleanup was deferred because a video file still exists below $media_real."
        CLEANUP_PRESERVE_MANIFEST=true
        CLEANUP_FOLDER_PENDING=true
        log_media_cleanup_blockers "$app_name" "$media_real" "$manifest" || return 1
        return 0
    fi
    if [[ "$DEFER_SIDECAR_CLEANUP_WHILE_MOVER" == true ]] && unraid_mover_running; then
        if [[ "$MOVER_GUARD_NOTICE_LOGGED" == false ]]; then
            log WARNING "Unraid Mover is running; sidecar quarantine and empty-folder cleanup are deferred. Pending manifests will be retried next run."
            MOVER_GUARD_NOTICE_LOGGED=true
        fi
        return 4
    fi

    if [[ -e "$QUARANTINE_ROOT" ]]; then
        quarantine_real="$(realpath -- "$QUARANTINE_ROOT" 2>/dev/null)" || return 1
    else
        quarantine_real="${QUARANTINE_ROOT%/}"
    fi
    run_root="${quarantine_real}/${QUARANTINE_RUN_ID}"
    root_relative="${media_real#"$root_real"/}"
    valid_relative_path "$root_relative" || return 1

    cleanup_plan="$(build_sidecar_cleanup_plan \
        "$app_name" \
        "$media_real" \
        "$media_root" \
        "$manifest")" || {
        log ERROR "Could not build the $app_name late-sidecar cleanup plan: $media_real"
        return 1
    }
    CLEANUP_LATE_CANDIDATES="$(jq -c '.lateCandidates // []' <<< "$cleanup_plan")" || return 1
    CLEANUP_LATE_CANDIDATE_COUNT="$(jq '.lateCandidates | length' <<< "$cleanup_plan")" || return 1
    CLEANUP_LATE_CONFIRMED_COUNT="$(jq '.lateConfirmed | length' <<< "$cleanup_plan")" || return 1
    ((SIDECARS_LATE_CANDIDATES += CLEANUP_LATE_CANDIDATE_COUNT)) || true
    ((SIDECARS_LATE_CONFIRMED += CLEANUP_LATE_CONFIRMED_COUNT)) || true

    while IFS= read -r late_candidate; do
        [[ -n "$late_candidate" ]] || continue
        log INFO "$app_name late sidecar candidate requires one more unchanged cleanup run: $late_candidate"
    done < <(jq -r '.lateCandidates[]?.relativePath' <<< "$cleanup_plan")

    while IFS= read -r late_candidate; do
        [[ -n "$late_candidate" ]] || continue
        log INFO "$app_name late sidecar candidate confirmed for quarantine: $late_candidate"
    done < <(jq -r '.lateConfirmed[]?.relativePath' <<< "$cleanup_plan")

    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        relative="$(jq -r '.relativePath // empty' <<< "$entry")"
        expected_size="$(jq -r '.size // empty' <<< "$entry")"
        expected_hash="$(jq -r '.sha256 // empty' <<< "$entry")"
        if ! valid_relative_path "$relative" ||
           ! [[ "$expected_size" =~ ^[0-9]+$ && "$expected_hash" =~ ^[a-fA-F0-9]{64}$ ]]; then
            log WARNING "Unsafe or invalid recorded $app_name sidecar entry was not moved: $relative"
            ((CLEANUP_CHANGED += 1))
            continue
        fi

        source="${media_real}/${relative}"
        if [[ ! -e "$source" && ! -L "$source" ]]; then
            ((CLEANUP_NATIVE_MISSING += 1))
            continue
        fi
        if [[ -L "$source" || ! -f "$source" ]]; then
            log WARNING "Recorded $app_name sidecar is no longer a regular file; leaving it untouched: $source"
            ((CLEANUP_CHANGED += 1))
            continue
        fi
        source_real="$(realpath -- "$source" 2>/dev/null)" || {
            ((CLEANUP_CHANGED += 1))
            continue
        }
        if [[ "$source_real" != "$media_real"/* ]]; then
            log WARNING "Recorded $app_name sidecar resolved outside its media directory; leaving it untouched: $source"
            ((CLEANUP_CHANGED += 1))
            continue
        fi

        size="$(file_size_bytes "$source")" || size=-1
        if [[ "$REQUIRE_SIDECAR_HASH_MATCH" == true ]]; then
            hash="$(sha256sum -- "$source" 2>/dev/null | cut -d ' ' -f 1)"
            if [[ "$size" != "$expected_size" || "${hash,,}" != "${expected_hash,,}" ]]; then
                log WARNING "Recorded $app_name sidecar changed after capture; leaving it untouched: $source"
                ((CLEANUP_CHANGED += 1))
                continue
            fi
        fi

        destination="${run_root}/${bucket}/${root_relative}/${relative}"
        destination_real="${destination}"
        [[ "$destination_real" == "$run_root"/* ]] || return 1

        if [[ "$DRY_RUN" == true ]]; then
            log INFO "DRY RUN: would quarantine $app_name Kodi sidecar: $source -> $destination"
            ((CLEANUP_QUARANTINED += 1))
            continue
        fi

        if [[ ! -d "$run_root" ]]; then
            mkdir -p -- "$run_root" || return 1
        fi
        if [[ -L "$run_root" || ! -d "$run_root" ]]; then
            log ERROR "Quarantine run path is not a safe directory: $run_root"
            return 1
        fi
        destination_parent="$(dirname -- "$destination")"
        mkdir -p -- "$destination_parent" || return 1
        normalize_quarantine_permissions "$run_root" || {
            log ERROR "Quarantine directories were created but their ownership or permissions could not be normalized: $run_root"
            return 1
        }
        [[ ! -e "$destination" && ! -L "$destination" ]] || {
            log ERROR "Quarantine destination already exists; refusing to overwrite it: $destination"
            return 1
        }
        if [[ "$DEFER_SIDECAR_CLEANUP_WHILE_MOVER" == true ]] && unraid_mover_running; then return 4; fi
        local move_id
        move_id=$(journal_intent sidecar "$source" "$source" "$destination" "$expected_hash") || return 1
        if mv -- "$source" "$destination"; then
            normalize_quarantine_permissions "$destination" || {
                log ERROR "Sidecar was quarantined but its ownership or permissions could not be normalized: $destination"
                return 1
            }
            ops_flush_file "$destination" || return 1
            sync -- "$(dirname -- "$source")" "$(dirname -- "$destination")" || return 1
            journal_finish "$move_id" "Sidecar quarantined; ownership normalized; file/directory changes flushed" || return 1
            CLEANUP_OPERATION_DETAILS+="Quarantined $relative: $source -> $destination"$'\n'
            log INFO "Quarantined $app_name Kodi sidecar: $source -> $destination"
            [[ -n "$CLEANUP_QUARANTINE_RUN_ID" ]] || \
                CLEANUP_QUARANTINE_RUN_ID="$QUARANTINE_RUN_ID"
            ((CLEANUP_QUARANTINED += 1))
        else
            return 1
        fi
    done < <(jq -c '.moveEntries[]?' <<< "$cleanup_plan")

    if [[ "$DRY_RUN" == true ]]; then
        [[ "$REMOVE_EMPTY_MEDIA_FOLDERS" == true ]] &&
            log INFO "DRY RUN: would attempt rmdir-only cleanup below $media_real after quarantining sidecars."
        return 0
    fi
    if (( CLEANUP_CHANGED > 0 )); then
        CLEANUP_PRESERVE_MANIFEST=true
        CLEANUP_FOLDER_PENDING=true
        log_media_cleanup_blockers "$app_name" "$media_real" "$manifest" || return 1
        return 0
    fi

    if (( CLEANUP_LATE_CANDIDATE_COUNT > 0 )) &&
       [[ "$REMOVE_EMPTY_MEDIA_FOLDERS" != true ]]; then
        CLEANUP_FOLDER_PENDING=true
        log INFO "$app_name cleanup remains pending for $CLEANUP_LATE_CANDIDATE_COUNT late sidecar candidate(s): $media_real"
        return 0
    fi

    if [[ "$REMOVE_EMPTY_MEDIA_FOLDERS" == true ]]; then
        if [[ "$DEFER_SIDECAR_CLEANUP_WHILE_MOVER" == true ]] && unraid_mover_running; then return 4; fi
        remove_empty_media_dirs "$media_real"
        if [[ -e "$media_real" || -L "$media_real" ]]; then
            CLEANUP_FOLDER_PENDING=true
            log_media_cleanup_blockers "$app_name" "$media_real" "$manifest" || return 1
            return 0
        fi
    fi
    CLEANUP_COMPLETE=true
}

###############################################################################
# API: one response body on stdout; useful diagnostics on errors
###############################################################################

# Flush only destructive-operation checkpoints and their receipts, never every
# log line. Flush the containing directory after atomic replacement too.



journal_intent() {
    local kind="$1" key="$2" source="$3" destination="$4" verification="$5" id tmp
    id=$(printf '%s' "$APP_CONTEXT|$kind|$key" | sha256sum | cut -d ' ' -f1)
    if jq -e --arg id "$id" '.actions[$id]!=null' "$PENDING_ACTIONS_FILE" >/dev/null; then
        log ERROR "Unfinished action $id must be reconciled before another mutation of the same target."; return 1
    fi
    local destination_file
    destination_file=$(mktemp "$RUNTIME_DIR/.intent-payload.XXXXXX") || return 1
    printf '%s' "$destination" >"$destination_file" || return 1
    tmp=$(mktemp "$RUNTIME_DIR/.pending-actions.XXXXXX") || return 1
    jq -c --arg id "$id" --arg app "$APP_CONTEXT" --arg kind "$kind" --arg source "$source" \
      --rawfile destination "$destination_file" --arg verification "$verification" --argjson now "$(date +%s)" \
      '.actions[$id]={app:$app,kind:$kind,source:$source,destination:$destination,verification:$verification,startedAt:$now}' \
      "$PENDING_ACTIONS_FILE" >"$tmp" && ops_publish_checkpoint "$tmp" "$PENDING_ACTIONS_FILE" || return 1
    rm -f -- "$destination_file"
    printf '%s' "$id"
}

journal_finish() {
    local id="$1" result="$2" tmp
    jq -c --arg id "$id" --arg result "$result" --argjson now "$(date +%s)" \
      '.actions[$id] + {id:$id,result:$result,finishedAt:$now}' "$PENDING_ACTIONS_FILE" >>"$ACTION_RECEIPTS_FILE" || return 1
    ops_flush_file "$ACTION_RECEIPTS_FILE" || return 1
    tmp=$(mktemp "$RUNTIME_DIR/.pending-actions.XXXXXX") || return 1
    jq -c --arg id "$id" 'del(.actions[$id])' "$PENDING_ACTIONS_FILE" >"$tmp" && ops_publish_checkpoint "$tmp" "$PENDING_ACTIONS_FILE"
}

recover_pending_actions() {
    if [[ "$DRY_RUN" == true ]]; then
        log DEBUG "Dry run: pending action recovery is report-only; no journal or filesystem mutation was performed."
        return 0
    fi
    local records="$RUNTIME_DIR/.recovery-records.$$" entry id kind source destination verification body http resolved=0 failed=0
    jq -c --arg app "$APP_CONTEXT" '.actions|to_entries[]|select(.value.app==$app)' "$PENDING_ACTIONS_FILE" >"$records" || return 1
    while IFS= read -r entry; do
        IFS=$'\t' read -r id kind < <(jq -r '[.key,.value.kind]|@tsv' <<<"$entry")
        source=$(jq -r '.value.source' <<<"$entry"); destination=$(jq -r '.value.destination' <<<"$entry"); verification=$(jq -r '.value.verification' <<<"$entry")
        if [[ "$kind" == sidecar ]]; then
            # Revalidate recorded paths; a journal is never authority to escape roots.
            local source_real destination_real quarantine_real movies_real series_real
            source_real=$(realpath -m -- "$source") || return 1
            destination_real=$(realpath -m -- "$destination") || return 1
            quarantine_real=$(realpath -m -- "$QUARANTINE_ROOT") || return 1
            movies_real=$(realpath -m -- "$MOVIES_ROOT") || return 1
            series_real=$(realpath -m -- "$SERIES_ROOT") || return 1
            if [[ "$destination_real" != "$quarantine_real"/* || ( "$source_real" != "$movies_real"/* && "$source_real" != "$series_real"/* ) ]]; then
                queue_attention_notification ERROR "$APP_CONTEXT" "Unsafe interrupted sidecar path preserved" "Action $id resolves outside configured media/quarantine roots. No filesystem change was made."
                failed=$((failed+1)); continue
            fi
            if [[ ! -e "$source" && ! -L "$source" && -f "$destination" && ! -L "$destination" ]] &&
               [[ "$(sha256sum -- "$destination" | cut -d ' ' -f1)" == "$verification" ]]; then
                normalize_quarantine_permissions "$destination" || return 1
                journal_finish "$id" "Recovered interrupted sidecar move; destination hash verified" || return 1
                queue_action_notification "$APP_CONTEXT" "Recovered interrupted sidecar quarantine" "$source -> $destination; SHA-256 matched. Folder cleanup will be reevaluated."
            elif [[ -f "$source" && ! -e "$destination" && ! -L "$destination" ]]; then
                journal_finish "$id" "Move did not occur; fresh manifest checks will reevaluate the source" || return 1
            else
                queue_attention_notification ERROR "$APP_CONTEXT" "Interrupted sidecar action is ambiguous" "Source: $source; destination: $destination. Both copies were preserved; automatic overwriting is prohibited."
                failed=$((failed+1))
            fi
        elif [[ "$kind" == api ]]; then
            if verify_arr_checkpoint_with_grace "$id"; then
                journal_finish "$id" "Recovered interrupted API mutation: $ARR_VERIFY_REASON" || return 1
                queue_stateful_resolution_notification "$APP_CONTEXT" "api-action:$id" "Arr mutation verified" "$verification $source: $ARR_VERIFY_REASON"
                queue_action_notification "$APP_CONTEXT" "Verified interrupted Arr action" "$verification $source: $ARR_VERIFY_REASON. No mutation was replayed."
            elif [[ "$ARR_VERIFY_DIFFERENT" == true && "$verification" != POST ]]; then
                journal_finish "$id" "Requested state not present: $ARR_VERIFY_REASON; fresh snapshots will reevaluate remaining actions" || return 1
                queue_stateful_resolution_notification "$APP_CONTEXT" "api-action:$id" "Arr request outcome reconciled" "$verification $source: requested state is not present. The old request was not replayed; fresh state will determine any new action."
                queue_action_notification "$APP_CONTEXT" "Reconciled unapplied or changed Arr action" "$verification $source: $ARR_VERIFY_REASON. The old request was not replayed; current records will drive fresh monitoring/retirement decisions."
            elif [[ "$ARR_VERIFY_DIFFERENT" == true && "$source" == /api/v3/tag ]]; then
                journal_finish "$id" "Tag creation not present in current catalog; fresh catalog will drive any new creation" || return 1
                queue_stateful_resolution_notification "$APP_CONTEXT" "api-action:$id" "Tag creation outcome reconciled" "The tag is absent from the authoritative catalog; fresh catalog checks precede any new creation."
                queue_action_notification "$APP_CONTEXT" "Reconciled absent tag creation" "$source: $ARR_VERIFY_REASON. Fresh catalog checks will precede any new POST."
            else
                queue_stateful_attention_notification ERROR "$APP_CONTEXT" "api-action:$id" "$ARR_VERIFY_REASON" "Arr mutation remains unverified" "$verification $source: $ARR_VERIFY_REASON. Checkpoint $id retained; no mutation replayed and no fully successful outcome claimed." 14
                failed=$((failed+1))
            fi
        else failed=$((failed+1)); fi
        resolved=$((resolved+1))
    done <"$records"
    rm -f -- "$records"
    (( failed==0 ))
}

arr_verification_get() {
    local endpoint="$1" output="$2" http
    ARR_VERIFY_HTTP=""
    http=$(curl --silent --show-error --connect-timeout "$HTTP_CONNECT_TIMEOUT" --max-time "$HTTP_MAX_TIME" \
      --request GET --header "X-Api-Key: $ARR_API_KEY" --header 'Accept: application/json' \
      --output "$output" --write-out '%{http_code}' "$ARR_URL$endpoint") || { ARR_VERIFY_HTTP="${http:-000}"; return 1; }
    ARR_VERIFY_HTTP="$http"
    [[ "$http" == 200 || "$http" == 404 ]]
}

arr_expected_fields_match() {
    local expected="$1" actual="$2" id="$3" tags_mode="${4:-replace}"
    jq -e --slurpfile expected "$expected" --argjson id "$id" --arg tagsMode "$tags_mode" '
      $expected[0] as $e
      | type=="object" and .id==$id
      and (if ($e|has("monitored")) then .monitored==$e.monitored else true end)
      and (if ($e|has("tags")) then
          (.tags // []) as $actual
          | if $tagsMode=="add" then all($e.tags[]; . as $tag | ($actual|index($tag))!=null)
            elif $tagsMode=="remove" then all($e.tags[]; . as $tag | ($actual|index($tag))==null)
            else ($actual|sort)==($e.tags|sort) end
        else true end)
      and (if ($e|has("seasons")) then
          (.seasons // []) as $actual
          | all($e.seasons[]; . as $season | any($actual[]; .seasonNumber==$season.seasonNumber and .monitored==$season.monitored))
        else true end)
    ' "$actual" >/dev/null
}

journal_expected_resource() {
    local id="$1" resource="$2" tmp
    tmp=$(mktemp "$RUNTIME_DIR/.expected-resource.XXXXXX") || return 1
    jq -c --arg id "$id" --slurpfile resource "$resource" '.actions[$id].expectedResource=$resource[0]' \
      "$PENDING_ACTIONS_FILE" >"$tmp" && ops_publish_checkpoint "$tmp" "$PENDING_ACTIONS_FILE"
}

arr_prepare_delete_expectation() {
    local endpoint="${1%%\?*}" output="$2" resource catalog field exclusion expected_id
    resource=$(mktemp "${VERIFY_RUNTIME_DIR:-$RUNTIME_DIR}/.delete-before.XXXXXX") || return 1
    catalog=$(mktemp "${VERIFY_RUNTIME_DIR:-$RUNTIME_DIR}/.delete-catalog.XXXXXX") || return 1
    case "$endpoint" in
      /api/v3/series/[0-9]*) field=tvdbId; exclusion=/api/v3/importlistexclusion;;
      /api/v3/movie/[0-9]*) field=tmdbId; exclusion=/api/v3/exclusions;;
      *) log ERROR "Unsupported removal endpoint; mutation refused: $endpoint"; return 1;;
    esac
    expected_id=${endpoint##*/}
    [[ "$expected_id" =~ ^[1-9][0-9]*$ ]] || return 1
    if ! arr_verification_get "$endpoint" "$resource" || [[ "$ARR_VERIFY_HTTP" != 200 ]] ||
       ! jq -e --argjson id "$expected_id" --arg field "$field" '.id==$id and (.[$field]|type)=="number" and .[$field]>0' "$resource" >/dev/null; then
        log ERROR "Exact removal identity could not be read; DELETE was not sent: $endpoint"; return 1
    fi
    # Check read-back capability before removing a title. Official v3 endpoints
    # expose TVDB IDs for Sonarr and TMDB IDs for Radarr, never title matching.
    if ! arr_verification_get "$exclusion" "$catalog" || [[ "$ARR_VERIFY_HTTP" != 200 ]] || ! jq -e 'type=="array"' "$catalog" >/dev/null; then
        log ERROR "Import exclusion catalog unavailable; DELETE was not sent: $exclusion"; return 1
    fi
    jq -c --arg field "$field" --arg endpoint "$exclusion" \
      '{id,externalId:.[$field],externalField:$field,exclusionEndpoint:$endpoint,title:(.title // "")}' "$resource" >"$output" || return 1
    rm -f -- "$resource" "$catalog"
}

verify_arr_checkpoint() {
    local id="$1" checkpoint expected actual endpoint method payload ids object_id object_endpoint mode matches=0 total=0 body response_id external_id field exclusions
    ARR_VERIFY_REASON=""; ARR_VERIFY_DIFFERENT=false
    checkpoint=$(mktemp "${VERIFY_RUNTIME_DIR:-$RUNTIME_DIR}/.verify-checkpoint.XXXXXX") || return 1
    expected=$(mktemp "${VERIFY_RUNTIME_DIR:-$RUNTIME_DIR}/.verify-expected.XXXXXX") || return 1
    actual=$(mktemp "${VERIFY_RUNTIME_DIR:-$RUNTIME_DIR}/.verify-actual.XXXXXX") || return 1
    jq -c --arg id "$id" '.actions[$id]' "$PENDING_ACTIONS_FILE" >"$checkpoint" || return 1
    endpoint=$(jq -r '.source' "$checkpoint"); method=$(jq -r '.verification' "$checkpoint")
    jq -r '.destination // ""' "$checkpoint" >"$expected"
    if [[ "$method" == DELETE ]]; then
        external_id=$(jq -r '.expectedResource.externalId // 0' "$checkpoint")
        field=$(jq -r '.expectedResource.externalField // ""' "$checkpoint")
        exclusions=$(jq -r '.expectedResource.exclusionEndpoint // ""' "$checkpoint")
        if ! [[ "$external_id" =~ ^[1-9][0-9]*$ ]] || [[ -z "$field" || -z "$exclusions" ]]; then ARR_VERIFY_REASON="Removal identity/exclusion context is missing; no exclusion can be inferred from a title"; return 1; fi
        arr_verification_get "${endpoint%%\?*}" "$actual" || { ARR_VERIFY_REASON="Removal read-back API unavailable"; return 1; }
        if [[ "$ARR_VERIFY_HTTP" == 200 ]]; then
            object_id=$(jq -r '.expectedResource.id' "$checkpoint")
            if jq -e --argjson id "$object_id" --arg field "$field" --argjson external "$external_id" '.id==$id and .[$field]==$external' "$actual" >/dev/null; then
                ARR_VERIFY_DIFFERENT=true; ARR_VERIFY_REASON="Exact Arr object still exists; removal is not confirmed"
            else ARR_VERIFY_REASON="Removal read-back returned a different/invalid identity; checkpoint preserved"; fi
            return 1
        fi
        [[ "$ARR_VERIFY_HTTP" == 404 ]] || return 1
        arr_verification_get "$exclusions" "$actual" || { ARR_VERIFY_REASON="Object is absent, but exclusion API unavailable"; return 1; }
        if [[ "$ARR_VERIFY_HTTP" == 200 ]] && jq -e --arg field "$field" --argjson external "$external_id" \
          'type=="array" and any(.[];.[$field]==$external)' "$actual" >/dev/null; then
            ARR_VERIFY_REASON="Removal verified: exact object absent and $field=$external_id present in import exclusions"; return 0
        fi
        ARR_VERIFY_REASON="Object is absent, but $field=$external_id exclusion is not verified. Checkpoint retained; removal is not reported as fully successful"; return 1
    elif [[ "$method" == PUT ]]; then
        if [[ "$endpoint" == /api/v3/episode/monitor || "$endpoint" == /api/v3/movie/editor ]]; then
            ids=$(jq -r '(.episodeIds // .movieIds // [])[]' "$expected") || return 1
            mode=$(jq -r '.applyTags // "replace"' "$expected")
            [[ -n "$ids" ]] || { ARR_VERIFY_REASON="Bulk request contained no exact target IDs"; return 1; }
            while IFS= read -r object_id; do
                [[ "$object_id" =~ ^[1-9][0-9]*$ ]] || return 1
                if [[ "$endpoint" == /api/v3/episode/monitor ]]; then object_endpoint="/api/v3/episode/$object_id"; else object_endpoint="/api/v3/movie/$object_id"; fi
                arr_verification_get "$object_endpoint" "$actual" || { ARR_VERIFY_REASON="Exact bulk target $object_id could not be read"; return 1; }
                [[ "$ARR_VERIFY_HTTP" == 200 ]] && jq -e --argjson id "$object_id" '.id==$id' "$actual" >/dev/null || { ARR_VERIFY_REASON="Bulk target ID $object_id missing or mismatched"; return 1; }
                total=$((total+1))
                if arr_expected_fields_match "$expected" "$actual" "$object_id" "$mode"; then matches=$((matches+1)); fi
            done <<<"$ids"
            ARR_VERIFY_REASON="Read-back: $matches/$total exact targets have the requested monitoring/tags"
            if ((matches==total)); then return 0; fi
            ARR_VERIFY_DIFFERENT=true; return 1
        fi
        object_id=${endpoint##*/}; [[ "$object_id" =~ ^[1-9][0-9]*$ ]] || return 1
        arr_verification_get "$endpoint" "$actual" || { ARR_VERIFY_REASON="Arr object read-back unavailable"; return 1; }
        if [[ "$ARR_VERIFY_HTTP" != 200 ]] || ! jq -e --argjson id "$object_id" '.id==$id' "$actual" >/dev/null; then ARR_VERIFY_REASON="Arr object identity missing or mismatched"; return 1; fi
        if arr_expected_fields_match "$expected" "$actual" "$object_id"; then ARR_VERIFY_REASON="Monitoring, seasons and tags verified against exact object ID $object_id"; return 0; fi
        ARR_VERIFY_REASON="Exact object $object_id does not currently match requested monitoring/seasons/tags: $(jq -cr --slurpfile expected "$expected" '
          $expected[0] as $e | . as $a | {
            monitored:(if ($e|has("monitored")) then {expected:$e.monitored,actual:$a.monitored} else null end),
            tags:(if ($e|has("tags")) then {expected:$e.tags,actual:$a.tags} else null end),
            seasons:[ $e.seasons[]? | . as $s | select(any($a.seasons[]?; .seasonNumber==$s.seasonNumber and .monitored==$s.monitored)|not) | {seasonNumber,expectedMonitored:.monitored} ]
          }' "$actual")"; ARR_VERIFY_DIFFERENT=true; return 1
    elif [[ "$method" == POST && "$endpoint" == /api/v3/tag ]]; then
        local label
        label=$(jq -r '.label // ""' "$expected") || return 1
        arr_verification_get /api/v3/tag "$actual" || { ARR_VERIFY_REASON="Tag catalog read-back unavailable"; return 1; }
        [[ "$ARR_VERIFY_HTTP" == 200 ]] && jq -e 'type=="array"' "$actual" >/dev/null || return 1
        matches=$(jq -c --arg label "$label" '[.[]|select(.label==$label and (.id // 0)>0)]|length' "$actual")
        ARR_VERIFY_REASON="Tag '$label' exact catalog matches=$matches"
        ((matches==1)) && return 0
        [[ "$matches" != 0 ]] || ARR_VERIFY_DIFFERENT=true
        return 1
    elif [[ "$method" == POST && "$endpoint" == /api/v3/command ]]; then
        response_id=$(jq -r '.responseId // 0' "$checkpoint")
        [[ "$response_id" =~ ^[1-9][0-9]*$ ]] || { ARR_VERIFY_REASON="Command response ID unavailable; POST will not be replayed"; return 1; }
        arr_verification_get "/api/v3/command/$response_id" "$actual" || { ARR_VERIFY_REASON="Command read-back API unavailable"; return 1; }
        if [[ "$ARR_VERIFY_HTTP" == 200 ]] && jq -e --argjson id "$response_id" --slurpfile expected "$expected" '
          $expected[0] as $e | . as $command | (.body // .) as $body
          | .id==$id and ((.name // .body.name // "" | ascii_downcase)==($e.name|ascii_downcase))
          and ((.status // "" | ascii_downcase) as $s | ["queued","pending","started","completed"] | index($s)!=null)
          and all($e|to_entries[]|select(.key!="name"); . as $entry | $body[$entry.key]==$entry.value)
        ' "$actual" >/dev/null; then ARR_VERIFY_REASON="Command $response_id identity and accepted execution status verified; completion is checked separately"; return 0; fi
        ARR_VERIFY_REASON="Command $response_id status/body not verified; no duplicate POST submitted"; return 1
    fi
    ARR_VERIFY_REASON="Unsupported mutation verification; checkpoint retained"; return 1
}

verify_arr_checkpoint_with_grace() {
    local id="$1" attempt
    for ((attempt=1;attempt<=API_VERIFY_ATTEMPTS;attempt++)); do
        if verify_arr_checkpoint "$id"; then return 0; fi
        ((attempt>=API_VERIFY_ATTEMPTS)) || sleep "$API_VERIFY_DELAY_SECONDS"
    done
    return 1
}

arr_api_request_core() {
    local method="$1"
    local endpoint="$2"
    local payload="$3"
    local body err http_status curl_status message

    local journal_id="" payload_file="" delete_expectation=""
    if [[ "$method" == DELETE ]]; then
        delete_expectation=$(mktemp "${VERIFY_RUNTIME_DIR:-$RUNTIME_DIR}/.delete-expectation.XXXXXX") || return 1
        arr_prepare_delete_expectation "$endpoint" "$delete_expectation" || return 1
    fi
    if [[ -n "$payload" ]]; then
        payload_file=$(mktemp "$RUNTIME_DIR/.api-payload.XXXXXX") || return 1
        printf '%s' "$payload" >"$payload_file" || return 1
    fi
    if [[ "$method" != GET ]]; then
        journal_id=$(journal_intent api "$method $endpoint" "$endpoint" "$payload" "$method") || return 1
        if [[ -n "$delete_expectation" ]]; then journal_expected_resource "$journal_id" "$delete_expectation" || return 1; rm -f -- "$delete_expectation"; fi
    fi
    body="$(mktemp "${VERIFY_RUNTIME_DIR:-$RUNTIME_DIR}/.${ARR_TEMP_PREFIX}-body.XXXXXX")" || return 1
    err="$(mktemp "${VERIFY_RUNTIME_DIR:-$RUNTIME_DIR}/.${ARR_TEMP_PREFIX}-error.XXXXXX")" || {
        rm -f -- "$body"
        return 1
    }

    if [[ "$method" == GET ]]; then
        http_status="$(
            curl --silent --show-error \
                --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
                --max-time "$HTTP_MAX_TIME" \
                --retry "$HTTP_RETRIES" --retry-all-errors \
                --request GET \
                --header "X-Api-Key: $ARR_API_KEY" \
                --header 'Accept: application/json' \
                --header "User-Agent: $ARR_USER_AGENT" \
                --output "$body" --write-out '%{http_code}' \
                "$ARR_URL$endpoint" 2>"$err"
        )"
    elif [[ -n "$payload" ]]; then
        http_status="$(
            curl --silent --show-error \
                --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
                --max-time "$HTTP_MAX_TIME" \
                --retry 0 \
                --request "$method" \
                --header "X-Api-Key: $ARR_API_KEY" \
                --header 'Accept: application/json' \
                --header 'Content-Type: application/json' \
                --header "User-Agent: $ARR_USER_AGENT" \
                --data-binary "@$payload_file" \
                --output "$body" --write-out '%{http_code}' \
                "$ARR_URL$endpoint" 2>"$err"
        )"
    else
        http_status="$(
            curl --silent --show-error \
                --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
                --max-time "$HTTP_MAX_TIME" \
                --retry 0 \
                --request "$method" \
                --header "X-Api-Key: $ARR_API_KEY" \
                --header 'Accept: application/json' \
                --header "User-Agent: $ARR_USER_AGENT" \
                --output "$body" --write-out '%{http_code}' \
                "$ARR_URL$endpoint" 2>"$err"
        )"
    fi
    curl_status=$?
    if [[ "${MC_GUARDS_ACTIVE:-false}" == true ]];then printf '%s %s\n' "$curl_status" "${http_status:-000}" >"$MC_TMP/arr-$APP_CONTEXT.transport";fi

    if (( curl_status != 0 )) || ! [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
        message="$({ tr '\r\n' ' ' < "$err"; tr '\r\n' ' ' < "$body"; } | cut -c1-500)"
        [[ -n "$http_status" ]] || http_status=none
        [[ -n "$message" ]] || message="no response body"
        log ERROR "$ARR_NAME $method $endpoint failed (curl=$curl_status HTTP=$http_status): $message"
        rm -f -- "$body" "$err" "${payload_file:-$RUNTIME_DIR/.unused-payload}"
        return 1
    fi

    if [[ -n "$journal_id" ]]; then
        if [[ "$method" == POST && "$endpoint" == /api/v3/command ]]; then
            local response_id response_tmp
            response_id=$(jq -r '.id // 0' "$body" 2>/dev/null) || response_id=0
            if [[ "$response_id" =~ ^[1-9][0-9]*$ ]]; then
                response_tmp=$(mktemp "$RUNTIME_DIR/.command-response.XXXXXX") || return 1
                jq -c --arg id "$journal_id" --argjson response "$response_id" '.actions[$id].responseId=$response' "$PENDING_ACTIONS_FILE" >"$response_tmp" &&
                  ops_publish_checkpoint "$response_tmp" "$PENDING_ACTIONS_FILE" || return 1
            fi
        fi
        if ! verify_arr_checkpoint_with_grace "$journal_id"; then
            log ERROR "$ARR_NAME accepted $method $endpoint (HTTP $http_status), but read-back is unverified: $ARR_VERIFY_REASON"
            queue_stateful_attention_notification ERROR "$APP_CONTEXT" "api-action:$journal_id" "$ARR_VERIFY_REASON" "Arr change accepted but not verified" "$method $endpoint: $ARR_VERIFY_REASON. Recovery checkpoint retained; no automatic mutation retry was sent." 14
            rm -f -- "$body" "$err" "${payload_file:-$RUNTIME_DIR/.unused-payload}"
            return 1
        fi
        journal_finish "$journal_id" "Verified after HTTP $http_status: $ARR_VERIFY_REASON" || { rm -f -- "$body" "$err"; return 1; }
        queue_stateful_resolution_notification "$APP_CONTEXT" "api-action:$journal_id" "Arr mutation verified" "$method $endpoint: $ARR_VERIFY_REASON"
    fi
    cat "$body"
    rm -f -- "$body" "$err" "${payload_file:-$RUNTIME_DIR/.unused-payload}"
}

api_get_json() {
    local endpoint="$1"
    local json
    json="$(api_request GET "$endpoint" "")" || return 1
    if ! jq -e . >/dev/null 2>&1 <<< "$json"; then
        log ERROR "$ARR_NAME GET $endpoint returned invalid JSON."
        return 1
    fi
    printf '%s' "$json"
}

api_put_json() {
    api_request PUT "$1" "$2" >/dev/null
}

api_post_json() {
    api_request POST "$1" "$2"
}

api_delete() {
    api_request DELETE "$1" "" >/dev/null
}

age_at_least_hours() {
    local timestamp="$1"
    local hours="$2"
    local then_epoch now_epoch

    [[ "$hours" =~ ^[0-9]+$ ]] || return 1
    then_epoch="$(timestamp_to_epoch "$timestamp" || true)"
    [[ "$then_epoch" =~ ^[0-9]+$ ]] || return 1
    now_epoch="$(date +%s)"
    (( now_epoch - then_epoch >= hours * 3600 ))
}

age_at_least_days() {
    local timestamp="$1"
    local days="$2"
    age_at_least_hours "$timestamp" "$((days * 24))"
}

load_arr_queue() {
    local kind="$1" page=1 loaded=0 total=0 count queue endpoint merged
    if [[ "$kind" == sonarr ]]; then SONARR_QUEUE_AVAILABLE=false; else RADARR_QUEUE_AVAILABLE=false; fi
    local pages_file="$RUNTIME_DIR/.${ARR_TEMP_PREFIX}-queue-pages.$$"
    : >"$pages_file" || return 1
    while :; do
        if [[ "$kind" == sonarr ]]; then
            endpoint="/api/v3/queue?page=$page&pageSize=500&includeUnknownSeriesItems=true&includeSeries=true&includeEpisode=true"
        else
            endpoint="/api/v3/queue?page=$page&pageSize=500&includeUnknownMovieItems=true&includeMovie=true"
        fi
        queue="$(api_get_json "$endpoint")" || { rm -f -- "$pages_file"; return 1; }
        if ! jq -e 'type=="object" and (.records|type)=="array" and (.totalRecords|type)=="number"' <<<"$queue" >/dev/null; then
            rm -f -- "$pages_file"; log ERROR "Incomplete or invalid $ARR_NAME queue response; destructive actions are prohibited."; return 1
        fi
        count=$(jq '.records|length' <<<"$queue"); total=$(jq '.totalRecords' <<<"$queue")
        printf '%s\n' "$queue" >>"$pages_file" || return 1
        loaded=$((loaded+count))
        (( loaded>=total )) && break
        if (( count==0 || page>=1000 )); then rm -f -- "$pages_file"; log ERROR "Truncated $ARR_NAME queue: $loaded/$total"; return 1; fi
        page=$((page+1))
    done
    merged=$(jq -sc '.[0] as $first | . as $pages | $first | .records=[$pages[].records[]]' "$pages_file") || return 1
    rm -f -- "$pages_file"
    if [[ "$kind" == sonarr ]]; then SONARR_QUEUE_JSON="$merged"; SONARR_QUEUE_AVAILABLE=true
    else RADARR_QUEUE_JSON="$merged"; RADARR_QUEUE_AVAILABLE=true; fi
}

sonarr_queue_has_series() {
    local series_id="$1"
    jq -e --argjson series_id "$series_id" '
        any(.records[]?;
            (.seriesId // .episode.seriesId // .series.id // 0) == $series_id
        )
    ' >/dev/null 2>&1 <<< "$SONARR_QUEUE_JSON"
}

radarr_queue_has_movie() {
    local movie_id="$1"
    jq -e --argjson movie_id "$movie_id" '
        any(.records[]?;
            (.movieId // .movie.id // 0) == $movie_id
        )
    ' >/dev/null 2>&1 <<< "$RADARR_QUEUE_JSON"
}

# Load one application's tag catalogue into its isolated workflow context.
load_tag_catalog() {
    local tags
    tags="$(api_get_json "/api/v3/tag")" || return 1
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$tags"; then
        log ERROR "$ARR_NAME /tag did not return an array."
        return 1
    fi
    TAG_CATALOG="$tags"
}

tag_id_by_label() {
    local label="$1"
    jq -r --arg label "$label" \
        'first(.[] | select(.label == $label) | .id) // empty' \
        <<< "$TAG_CATALOG"
}

# Set the named variable to an existing tag ID or create the tag.
ensure_tag_id() {
    local label="$1"
    local destination="$2"
    local id payload created

    id="$(jq -r --arg label "$label" 'first(.[] | select(.label == $label) | .id) // empty' <<< "$TAG_CATALOG")"
    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
        payload="$(jq -cn --arg label "$label" '{label: $label}')"
        created="$(api_post_json "/api/v3/tag" "$payload" || true)"
        id="$(jq -r '.id // empty' <<< "$created" 2>/dev/null || true)"

        if [[ ! "$id" =~ ^[0-9]+$ ]]; then
            load_tag_catalog || return 1
            id="$(jq -r --arg label "$label" 'first(.[] | select(.label == $label) | .id) // empty' <<< "$TAG_CATALOG")"
            [[ "$id" =~ ^[0-9]+$ ]] || {
                log ERROR "Could not create or find $ARR_NAME tag '$label'."
                return 1
            }
        else
            TAG_CATALOG="$(jq -c --arg label "$label" --argjson id "$id" '
                if any(.[]; .id == $id) then . else . + [{id: $id, label: $label}] end
            ' <<< "$TAG_CATALOG")" || return 1
            log INFO "Created $ARR_NAME tag '$label'."
        fi
    fi

    printf -v "$destination" '%s' "$id"
}

# Submit one application-specific command and return its tracked command ID.
start_arr_command() {
    local payload="$1"
    local response command_id command_name
    command_name="$(jq -r '.name // "unknown"' <<< "$payload")"
    response="$(api_post_json "/api/v3/command" "$payload")" || return 1
    command_id="$(jq -r '.id // empty' <<< "$response")"
    [[ "$command_id" =~ ^[0-9]+$ ]] || {
        log ERROR "$ARR_NAME accepted $command_name but did not return a command ID."
        return 1
    }
    printf '%s' "$command_id"
}

wait_for_arr_command() {
    local command_id="$1"
    local started now elapsed last_notice=-1 status result
    started="$(date +%s)"

    while true; do
        COMMAND_JSON="$(api_get_json "/api/v3/command/$command_id")" || return 1
        status="$(jq -r '.status // "unknown"' <<< "$COMMAND_JSON")"
        result="$(jq -r '.result // "unknown"' <<< "$COMMAND_JSON")"

        case "$status" in
            completed)
                if [[ "$result" == failed || "$result" == unsuccessful ]]; then
                    log ERROR "$ARR_NAME command $command_id completed with result=$result."
                    return 1
                fi
                log INFO "$ARR_NAME command $command_id completed."
                return 0
                ;;
            failed|aborted)
                log ERROR "$ARR_NAME command $command_id ended with status=$status, result=$result."
                return 1
                ;;
        esac

        now="$(date +%s)"
        elapsed=$((now - started))
        if (( elapsed >= RESCAN_TIMEOUT_SECONDS )); then
            log ERROR "Timed out after ${RESCAN_TIMEOUT_SECONDS}s waiting for $ARR_NAME command $command_id (status=$status)."
            return 1
        fi
        if (( elapsed / 60 > last_notice )); then
            last_notice=$((elapsed / 60))
            log INFO "Waiting for $ARR_NAME command $command_id (status=$status, elapsed=${elapsed}s)."
        fi
        sleep "$RESCAN_POLL_SECONDS"
    done
}

###############################################################################
# STATE: work only in a temporary copy until final atomic commit
###############################################################################

sonarr_apply_snapshot() {
    local series_id="$1"
    local series_title="$2"
    local episodes_file="$3"
    local series_path="$4"
    local sidecar_files_file="$5"
    local next
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-snapshot.XXXXXX")" || return 1

    if ! jq -c --argjson series_id "$series_id" \
        --arg series_title "$series_title" \
        --arg series_path "$series_path" \
        --arg media_root "$SERIES_ROOT" \
        --arg now "$RUN_AT" \
        --slurpfile sidecar_source "$sidecar_files_file" \
        --slurpfile source "$episodes_file" '($source[0] // []) as $episodes
        | ($sidecar_source[0] // null) as $sidecar_files
        | .episodes //= {}
        | .sidecarManifests //= {}
        | .seriesRetirements //= {}
        | if $sidecar_files != null then
            .sidecarManifests[($series_id | tostring)] = {
                mediaPath: $series_path,
                mediaRoot: $media_root,
                bucket: "series",
                capturedAt: $now,
                files: $sidecar_files,
                lateSidecarCandidates: []
            }
          else
            .
          end
        # Build only the current series update map, then merge once. Replacing an
        # episode must not copy the whole library map for every episode.
        | .episodes as $previous
        | (reduce $episodes[] as $episode ({};
            ($episode.id | tostring) as $key
            | (.[$key] // $previous[$key] // {}) as $old
            | {
                episodeId: $episode.id,
                seriesId: $series_id,
                seriesTitle: $series_title,
                seasonNumber: ($episode.seasonNumber // 0),
                episodeNumber: ($episode.episodeNumber // 0),
                episodeTitle: ($episode.title // "Unknown"),
                lastObservedAt: $now
              } as $identity
            | if $episode.hasFile == true then
                .[$key] = (
                    $old + $identity + {
                        everHadFile: true,
                        lastKnownFileId: ($episode.episodeFileId // 0),
                        lastSeenWithFileAt: $now,
                        missingSince: null,
                        missingRuns: 0
                    }
                )
              elif $old.everHadFile == true then
                .[$key] = (
                    $old + $identity + {
                        missingSince: ($old.missingSince // $now),
                        missingRuns: (($old.missingRuns // 0) + 1)
                    }
                )
              else
                .
              end
        )) as $updates
        | .episodes += $updates
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

sonarr_series_cleanup_eligible() {
    sonarr_prepare_read_state || return 1
    local series_id="$1"
    local episodes_file="$2"

    jq -c --argjson series_id "$series_id" \
        --argjson needed "$CONFIRMATION_RUNS" \
        --argjson require_history "$REQUIRE_DELETE_HISTORY_EVENT" \
        --slurpfile source "$episodes_file" '($source[0] // []) as $episodes
        | .episodes as $state
        | [
            $state | to_entries[]
            | select(.value.seriesId == $series_id and .value.everHadFile == true)
          ] as $historical
        | ($episodes | map({key:(.id | tostring),value:.}) | from_entries) as $current
        | (
            (($historical | length) > 0)
            and all($episodes[]; .hasFile != true)
            and all(
                $historical[];
                ($current[.key] != null)
                and ($current[.key].hasFile != true)
                and ((.value.missingRuns // 0) >= $needed)
                and (
                    ($require_history | not)
                    or (.value.latestEpisodeFileDeletedHistory != null)
                )
            )
          )
    ' "$SONARR_READ_STATE"
}

sonarr_mark_sidecar_cleanup() {
    local series_id="$1"
    local next
    local total_quarantined total_native_missing total_folders_removed

    total_quarantined=$((CLEANUP_PROGRESS_QUARANTINED + CLEANUP_QUARANTINED))
    total_native_missing=$((CLEANUP_PROGRESS_NATIVE_MISSING + CLEANUP_NATIVE_MISSING))
    total_folders_removed=$((CLEANUP_PROGRESS_FOLDERS_REMOVED + CLEANUP_FOLDERS_REMOVED))
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-sidecar-action.XXXXXX")" || return 1

    if ! jq -c --arg now "$RUN_AT" \
        --arg run_id "$CLEANUP_QUARANTINE_RUN_ID" \
        --argjson series_id "$series_id" \
        --argjson quarantined "$total_quarantined" \
        --argjson native_missing "$total_native_missing" \
        --argjson folders_removed "$total_folders_removed" '
        .sidecarCleanupActions //= {}
        | .sidecarCleanupActions[($series_id | tostring)] = {
            seriesId: $series_id,
            completedAt: $now,
            quarantineRunId: (if $quarantined > 0 and $run_id != "" then $run_id else null end),
            quarantinedFiles: $quarantined,
            nativeMissingFiles: $native_missing,
            foldersRemoved: $folders_removed
          }
        | del(.sidecarManifests[($series_id | tostring)])
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

sonarr_confirmed_episode_ids() {
    sonarr_prepare_read_state || return 1
    local episodes_file="$1"
    jq -c --slurpfile source "$episodes_file" --argjson needed "$CONFIRMATION_RUNS" '($source[0] // []) as $episodes
        | .episodes as $state
        | [
            $episodes[]
            | select(.monitored == true and .hasFile != true)
            | . as $episode
            | ($episode.id | tostring) as $key
            | ($state[$key] // {}) as $record
            | select($record.everHadFile == true and $record.missingRuns >= $needed)
            | $episode.id
          ]
        | unique
    ' "$SONARR_READ_STATE"
}

sonarr_new_candidate_count() {
    sonarr_prepare_read_state || return 1
    local series_id="$1"
    jq -c --argjson series_id "$series_id" --arg now "$RUN_AT" '
        [
            .episodes[]
            | select(
                .seriesId == $series_id and
                .missingSince == $now and
                .missingRuns == 1
              )
        ]
        | length
    ' "$SONARR_READ_STATE"
}

sonarr_log_new_candidates() {
    sonarr_prepare_read_state || return 1
    local series_id="$1"
    while IFS= read -r line; do
        [[ -n "$line" ]] && log WARNING "$line"
    done < <(
        jq -r --argjson series_id "$series_id" --arg now "$RUN_AT" '
            .episodes[]
            | select(
                .seriesId == $series_id and
                .missingSince == $now and
                .missingRuns == 1
              )
            | "Deletion candidate: \(.seriesTitle) S\(.seasonNumber)E\(.episodeNumber) — \(.episodeTitle) [episode \(.episodeId)]; confirmation pending."
        ' "$SONARR_READ_STATE"
    )
}

# Sonarr exposes deletion history by series. One request can therefore provide
# audit evidence for every confirmed episode in that series.
sonarr_series_delete_history() {
    local series_id="$1"
    local history
    history="$(api_get_json "/api/v3/history/series?seriesId=${series_id}&eventType=episodeFileDeleted")" ||
        return 1
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$history"; then
        log ERROR "Sonarr History for series $series_id did not return an array."
        return 1
    fi
    jq '[
            .[]
            | select(.eventType == "episodeFileDeleted")
            | {
                id: .id,
                episodeId: .episodeId,
                seriesId: .seriesId,
                date: .date,
                eventType: .eventType,
                data: (.data // {})
              }
        ]
        | sort_by(.date // "")
    ' <<< "$history"
}

sonarr_record_history_evidence() {
    local episode_id="$1"
    local evidence="$2"
    local next
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-history.XXXXXX")" || return 1

    if ! jq -c --arg now "$RUN_AT" --argjson episode_id "$episode_id" \
        --argjson evidence "$evidence" '
        .episodes[($episode_id | tostring)] |= . + {
            lastHistoryInspectionAt: $now,
            latestEpisodeFileDeletedHistory: $evidence
        }
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

sonarr_ids_with_history() {
    local ids="$1"
    local history="$2"
    jq -c --argjson ids "$ids" --argjson history "$history" '
        [
            $ids[] as $id
            | select(any($history[]; .episodeId == $id))
            | $id
        ]
        | unique
    ' <<< 'null'
}

# A season is eligible only if every historically downloaded episode in that
# season is currently present in Sonarr, fileless, and confirmed missing. It
# must also have no current monitored episodes after this run's episode action.
sonarr_candidate_seasons() {
    sonarr_prepare_read_state || return 1
    local series_id="$1"
    local episodes_file="$2"
    local effective_episode_actions="$3"

    jq -c --argjson series_id "$series_id" \
        --slurpfile source "$episodes_file" \
        --argjson effective "$effective_episode_actions" \
        --argjson needed "$CONFIRMATION_RUNS" '($source[0] // []) as $episodes
        | .episodes as $state
        | ($episodes | map({key: (.id | tostring), value: .}) | from_entries) as $current
        | ($episodes | map(select((.seasonNumber // 0) > 0) | .seasonNumber) | unique) as $seasons
        | [
            $seasons[]
            | . as $season
            | [
                $state | to_entries[]
                | select(
                    .value.seriesId == $series_id and
                    .value.seasonNumber == $season and
                    .value.everHadFile == true
                  )
              ] as $historical
            | select(($historical | length) > 0)
            | select(all(
                $historical[];
                (
                    ($current[.key] != null) and
                    ($current[.key].hasFile != true) and
                    (.value.missingRuns >= $needed)
                )
              ))
            | select(all(
                $episodes[] | select(.seasonNumber == $season);
                . as $episode
                | (
                    $episode.monitored != true or
                    (($effective | index($episode.id)) != null)
                  )
              ))
            | $season
          ]
        | unique
    ' "$SONARR_READ_STATE"
}

# This deliberately does not inspect .seasons; it establishes the episode and
# state prerequisites for a series action.  The caller performs the final
# seasons-array check against freshly retrieved Sonarr series detail.
sonarr_candidate_series() {
    sonarr_prepare_read_state || return 1
    local series_id="$1"
    local episodes_file="$2"
    local effective_episode_actions="$3"

    jq -c --argjson series_id "$series_id" \
        --slurpfile source "$episodes_file" \
        --argjson effective "$effective_episode_actions" \
        --argjson needed "$CONFIRMATION_RUNS" '($source[0] // []) as $episodes
        | .episodes as $state
        | [
            $state | to_entries[]
            | select(.value.seriesId == $series_id and .value.everHadFile == true)
          ] as $historical
        | ($episodes | map({key: (.id | tostring), value: .}) | from_entries) as $current
        | (
            (($historical | length) > 0)
            and all(
                $historical[];
                (
                    ($current[.key] != null)
                    and ($current[.key].hasFile != true)
                    and (.value.missingRuns >= $needed)
                )
            )
            and all(
                $episodes[];
                . as $episode
                | (
                    $episode.hasFile != true
                    and (
                        $episode.monitored != true
                        or (($effective | index($episode.id)) != null)
                    )
                )
            )
          )
    ' "$SONARR_READ_STATE"
}

sonarr_mark_episode_action() {
    local ids="$1"
    local next
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-action.XXXXXX")" || return 1
    if ! jq -c --arg now "$RUN_AT" --argjson ids "$ids" '
        reduce $ids[] as $id (.;
            .episodes[($id | tostring)] |= . + {lastEpisodeUnmonitoredAt: $now}
        )
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

sonarr_mark_season_action() {
    local series_id="$1"
    local seasons="$2"
    local next
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-season.XXXXXX")" || return 1
    if ! jq -c --arg now "$RUN_AT" --argjson series_id "$series_id" \
        --argjson seasons "$seasons" '
        .seasonActions //= {}
        | reduce $seasons[] as $season (.;
            .seasonActions[($series_id | tostring) + ":" + ($season | tostring)] = {
                seriesId: $series_id,
                seasonNumber: $season,
                lastUnmonitoredAt: $now
            }
        )
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

sonarr_mark_series_action() {
    local series_id="$1"
    local next
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-series.XXXXXX")" || return 1
    if ! jq -c --arg now "$RUN_AT" --argjson series_id "$series_id" '
        .seriesActions //= {}
        | .seriesActions[($series_id | tostring)] = {
            seriesId: $series_id,
            lastUnmonitoredAt: $now
        }
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

sonarr_cleanup_complete_for_retirement() {
    sonarr_prepare_read_state || return 1
    local series_id="$1"

    if [[ "$QUARANTINE_KODI_SIDECARS" != true ]]; then
        return 0
    fi
    jq -e --arg key "$series_id" '
        (.sidecarCleanupActions[$key] != null)
        and (.sidecarManifests[$key] == null)
    ' "$SONARR_READ_STATE" >/dev/null 2>&1
}

sonarr_mark_retirement_started() {
    local series_id="$1"
    local title="$2"
    local status="$3"
    local next

    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-retirement.XXXXXX")" || return 1
    if ! jq -c --arg key "$series_id" \
        --argjson series_id "$series_id" \
        --arg title "$title" \
        --arg status "$status" \
        --arg now "$RUN_AT" '
        .seriesRetirements //= {}
        | .seriesRetirements[$key] = {
            seriesId: $series_id,
            title: $title,
            seriesStatus: $status,
            startedAt: $now,
            lastValidatedAt: $now,
            suppressed: false,
            removedFromArrAt: null
          }
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

sonarr_touch_retirement() {
    local series_id="$1"
    local next

    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-retirement-touch.XXXXXX")" || return 1
    if ! jq -c --arg key "$series_id" --arg now "$RUN_AT" '
        .seriesRetirements[$key].lastValidatedAt = $now
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

sonarr_cancel_retirement() {
    local series_id="$1"
    local reason="$2"
    local next

    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-retirement-cancel.XXXXXX")" || return 1
    if ! jq -c --arg key "$series_id" --arg now "$RUN_AT" --arg reason "$reason" '
        .seriesRetirements //= {}
        | .seriesRetirements[$key] = ((.seriesRetirements[$key] // {}) + {
            startedAt: null,
            lastValidatedAt: $now,
            cancelledAt: $now,
            cancellationReason: $reason,
            suppressed: true
          })
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
    ((RETIREMENTS_CANCELLED += 1))
}

sonarr_clear_retirement() {
    local series_id="$1"
    local next

    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-retirement-clear.XXXXXX")" || return 1
    if ! jq -c --arg key "$series_id" 'del(.seriesRetirements[$key])' \
        "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
    ((RETIREMENTS_CANCELLED += 1))
}

sonarr_mark_removed_from_arr() {
    local series_id="$1"
    local next

    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-retirement-removed.XXXXXX")" || return 1
    if ! jq -c --arg key "$series_id" --arg now "$RUN_AT" '
        .seriesRetirements[$key].removedFromArrAt = $now
        | .seriesRetirements[$key].lastValidatedAt = $now
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

# Return 0 when no retirement action was taken, 10 when the caller should skip
# ordinary season/series processing for this item, and non-zero on failure.
sonarr_process_full_retirement() {
    sonarr_prepare_read_state || return 1
    local series_id="$1"
    local series_title="$2"
    local series_item="$3"
    local episodes_file="$4"
    local key status existing started_at suppressed fully_deleted
    local exempt_id required_id pending_id deleted_id
    local has_exempt=false has_required=false is_continuing=false
    local monitored_episode_count monitored_season_count series_monitored
    local current_file_count
    local episode_ids payload detail tag_ids warning_threshold

    [[ "$SONARR_RETIRE_FULLY_DELETED_SERIES" == true ]] || return 0
    key="$series_id"
    status="$(jq -r '.status // "unknown"' <<< "$series_item")"
    [[ "$status" == ended ]] || is_continuing=true
    existing="$(jq -c --arg key "$key" '.seriesRetirements[$key] // null' "$SONARR_READ_STATE")" || return 1
    started_at="$(jq -r '.startedAt // empty' <<< "$existing")"
    suppressed="$(jq -r '.suppressed // false' <<< "$existing")"

    exempt_id="$(tag_id_by_label "$SONARR_RETIREMENT_EXEMPT_TAG")"
    required_id="$(tag_id_by_label "$SONARR_RETIREMENT_REQUIRED_TAG")"
    if [[ "$exempt_id" =~ ^[0-9]+$ ]] &&
       jq -e --argjson id "$exempt_id" '(.tags // []) | index($id) != null' \
           >/dev/null <<< "$series_item"; then
        has_exempt=true
    fi
    if [[ "$required_id" =~ ^[0-9]+$ ]] &&
       jq -e --argjson id "$required_id" '(.tags // []) | index($id) != null' \
           >/dev/null <<< "$series_item"; then
        has_required=true
    fi

    fully_deleted="$(sonarr_series_cleanup_eligible "$series_id" "$episodes_file")" || return 1
    monitored_episode_count="$(jq '[.[] | select(.monitored == true)] | length' "$episodes_file")" || return 1
    current_file_count="$(jq '[.[] | select(.hasFile == true)] | length' "$episodes_file")" || return 1
    monitored_season_count="$(jq '[.seasons[]? | select(.monitored == true)] | length' <<< "$series_item")" || return 1
    series_monitored="$(jq -r '.monitored == true' <<< "$series_item")"

    if [[ -n "$started_at" ]]; then
        if (( current_file_count > 0 )); then
            sonarr_clear_retirement "$series_id" || return 1
            queue_stateful_resolution_notification Sonarr \
                "retirement:sonarr:${series_id}:upcoming" \
                "$series_title retirement hold cancelled" \
                "Episode media returned before automatic removal."
            queue_action_notification Sonarr "$series_title retirement cancelled" \
                "Episode media returned; the previous retirement hold was cleared and a future complete deletion may start a new hold."
            return 10
        fi
        if [[ "$fully_deleted" != true ]]; then
            sonarr_cancel_retirement "$series_id" "A file returned or the complete-deletion evidence no longer qualifies." || return 1
            queue_stateful_resolution_notification Sonarr \
                "retirement:sonarr:${series_id}:upcoming" \
                "$series_title retirement hold cancelled" \
                "Complete-deletion evidence no longer qualifies."
            queue_action_notification Sonarr "$series_title retirement cancelled" \
                "Complete-series deletion evidence no longer qualifies; automatic Arr removal was cancelled."
            return 10
        fi
        if [[ "$has_exempt" == true || "$series_monitored" == true ||
              "$monitored_episode_count" != 0 || "$monitored_season_count" != 0 ]]; then
            sonarr_cancel_retirement "$series_id" \
                "Monitoring was restored or the retirement exemption tag was applied." || return 1
            queue_stateful_resolution_notification Sonarr \
                "retirement:sonarr:${series_id}:upcoming" \
                "$series_title retirement hold cancelled" \
                "Monitoring was restored or a retirement exemption was applied."
            queue_action_notification Sonarr "$series_title retirement cancelled" \
                "Monitoring was restored or tag '$SONARR_RETIREMENT_EXEMPT_TAG' was applied; automatic Arr removal was cancelled."
            return 10
        fi

        sonarr_touch_retirement "$series_id" || return 1
        warning_threshold=$((ARR_RETIREMENT_DAYS - ARR_RETIREMENT_WARNING_DAYS))
        (( warning_threshold < 0 )) && warning_threshold=0
        if age_at_least_days "$started_at" "$warning_threshold" &&
           ! age_at_least_days "$started_at" "$ARR_RETIREMENT_DAYS"; then
            queue_stateful_attention_notification WARNING Sonarr \
                "retirement:sonarr:${series_id}:upcoming" "$started_at" \
                "$series_title scheduled for Arr removal" \
                "The fully deleted series will be removed from Sonarr after ${ARR_RETIREMENT_DAYS} days unless media or monitoring returns. Started: $started_at" \
                "$ARR_RETIREMENT_DAYS"
        fi
        if ! age_at_least_days "$started_at" "$ARR_RETIREMENT_DAYS"; then
            return 10
        fi
        if [[ "$SONARR_QUEUE_AVAILABLE" != true ]]; then
            log WARNING "Retirement removal for $series_title is due, but Sonarr queue status is unavailable."
            return 10
        fi
        if sonarr_queue_has_series "$series_id"; then
            log WARNING "Retirement removal for $series_title is due, but Sonarr still has queue activity."
            return 10
        fi

        if [[ "$DRY_RUN" == true ]]; then
            log INFO "DRY RUN: would remove retired series $series_title from Sonarr and add an import-list exclusion."
            queue_action_notification Sonarr "$series_title retirement removal" \
                "Would remove from Sonarr with deleteFiles=false and addImportListExclusion=true."
            return 10
        fi
        if api_delete "/api/v3/series/${series_id}?deleteFiles=false&addImportListExclusion=true"; then
            sonarr_mark_removed_from_arr "$series_id" || return 1
            queue_stateful_resolution_notification Sonarr \
                "retirement:sonarr:${series_id}:upcoming" \
                "$series_title retirement hold completed" \
                "The 90-day hold completed and the series was removed from Sonarr."
            queue_action_notification Sonarr "$series_title removed from Sonarr" \
                "The fully deleted series completed its ${ARR_RETIREMENT_DAYS}-day hold; files were not deleted and an import-list exclusion was added."
            log INFO "Removed retired series $series_title from Sonarr and added an import-list exclusion."
            ((ARR_REMOVALS += 1))
            return 10
        fi
        log ERROR "Could not remove retired series $series_title from Sonarr; it will be retried."
        queue_attention_notification ERROR Sonarr "$series_title retirement removal failed" \
            "The series remains in Sonarr and will be retried next run."
        return 1
    fi

    [[ "$suppressed" != true && "$fully_deleted" == true ]] || return 0
    [[ "$has_exempt" != true ]] || return 0
    if [[ "$is_continuing" == true && "$SONARR_RETIRE_CONTINUING_SERIES" != true &&
          "$has_required" != true ]]; then
        log INFO "Fully fileless continuing series $series_title was not retired; add tag '$SONARR_RETIREMENT_REQUIRED_TAG' to confirm that future episodes should be abandoned."
        return 0
    fi
    sonarr_cleanup_complete_for_retirement "$series_id" || {
        log INFO "Full-series retirement for $series_title is waiting for sidecar and folder cleanup to complete."
        return 0
    }
    if [[ "$SONARR_QUEUE_AVAILABLE" != true ]]; then
        log WARNING "Full-series retirement for $series_title is waiting because Sonarr queue status is unavailable."
        return 0
    fi
    if sonarr_queue_has_series "$series_id"; then
        log INFO "Full-series retirement for $series_title is waiting for Sonarr queue activity to finish."
        return 0
    fi

    episode_ids="$(jq '[.[].id] | unique' "$episodes_file")" || return 1
    if [[ "$DRY_RUN" == true ]]; then
        log INFO "DRY RUN: would unmonitor every episode, season, and the series for full-series retirement: $series_title."
        queue_action_notification Sonarr "$series_title full-series retirement" \
            "Would unmonitor all hierarchy levels and start the ${ARR_RETIREMENT_DAYS}-day hold."
        return 10
    fi

    if (( $(jq length <<< "$episode_ids") > 0 )); then
        payload="$(jq -cn --argjson ids "$episode_ids" '{episodeIds:$ids,monitored:false}')" || return 1
        api_put_json '/api/v3/episode/monitor' "$payload" || return 1
    fi
    detail="$(api_get_json "/api/v3/series/$series_id")" || return 1
    ensure_tag_id "$PLEX_DELETED_SERIES_TAG" deleted_id || return 1
    ensure_tag_id "$SONARR_RETIREMENT_PENDING_TAG" pending_id || return 1
    tag_ids="$(jq -cn --argjson deleted "$deleted_id" --argjson pending "$pending_id" \
        '[$deleted,$pending]')" || return 1
    payload="$(jq -c --argjson tags "$tag_ids" '
        .monitored = false
        | .seasons |= map(.monitored = false)
        | .tags //= []
        | .tags |= ((. + $tags) | unique)
    ' <<< "$detail")" || return 1
    api_put_json "/api/v3/series/$series_id" "$payload" || return 1
    sonarr_mark_retirement_started "$series_id" "$series_title" "$status" || return 1
    sonarr_mark_series_action "$series_id" || return 1
    queue_action_notification Sonarr "$series_title full-series retirement started" \
        "All episodes, seasons, and the series were unmonitored; the ${ARR_RETIREMENT_DAYS}-day removal hold has started."
    log INFO "Started full-series retirement for $series_title; removal hold is ${ARR_RETIREMENT_DAYS} days."
    ((RETIREMENTS_STARTED += 1))
    return 10
}

sonarr_prune_state() {
    local series_json="$1"
    local now_epoch cutoff next pruned

    now_epoch="$(date +%s)"
    cutoff=$((now_epoch - STATE_PRUNE_ABSENT_DAYS * 86400))
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-prune.XXXXXX")" || return 1
    if ! jq -c --arg now "$RUN_AT" \
        --argjson now_epoch "$now_epoch" \
        --argjson cutoff "$cutoff" \
        --slurpfile current_source <(printf '%s' "$series_json") '
        (($current_source[0] // []) | map(.id | tostring)) as $present
        | .episodes //= {}
        | .seriesRetirements //= {}
        | .seriesActions //= {}
        | .seasonActions //= {}
        | .sidecarManifests //= {}
        | .sidecarCleanupActions //= {}
        | reduce (.episodes | to_entries[]) as $entry (.;
            ($entry.value.seriesId | tostring) as $series_key
            | if ($present | index($series_key)) != null then
                del(.episodes[$entry.key].absentFromArrAt, .episodes[$entry.key].absentFromArrEpoch)
              else
                .episodes[$entry.key].absentFromArrAt //= $now
                | .episodes[$entry.key].absentFromArrEpoch //= $now_epoch
              end
          )
        | . as $state
        | [
            $state.episodes | to_entries[]
            | (.value.seriesId | tostring) as $series_key
            | select(
                (.value.absentFromArrEpoch // $now_epoch) <= $cutoff
                and $state.sidecarManifests[$series_key] == null
              )
            | .key
          ] as $episode_keys
        | ([$episode_keys[] as $key | .episodes[$key].seriesId] | unique) as $series_ids
        | reduce $episode_keys[] as $key (.; del(.episodes[$key]))
        | reduce $series_ids[] as $series_id (.;
            ($series_id | tostring) as $series_key
            | del(.seriesRetirements[$series_key], .seriesActions[$series_key], .sidecarCleanupActions[$series_key])
            | .seasonActions |= with_entries(select(.value.seriesId != $series_id))
          )
        | .lastPrunedCount = ($episode_keys | length)
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    pruned="$(jq -r '.lastPrunedCount // 0' "$next")"
    mv -f -- "$next" "$WORK_STATE"
    ((STATE_PRUNED += pruned))
    (( pruned == 0 )) || log INFO "Pruned $pruned Sonarr episode state record(s) absent for at least $STATE_PRUNE_ABSENT_DAYS days."
}

sonarr_commit_state() {
    local final backup had_errors
    final="$(mktemp "$STATE_DIR/.state-final.XXXXXX")" || return 1
    had_errors=false
    (( API_FAILURES > 0 || HISTORY_FAILURES > 0 || SIDECAR_FAILURES > 0 )) && had_errors=true

    if ! jq -c --arg now "$RUN_AT" --argjson had_errors "$had_errors" '
        .version = 7
        | .lastRun = $now
        | .lastRunHadApiErrors = $had_errors
        | .episodes //= {}
        | .sidecarManifests //= {}
        | .sidecarCleanupActions //= {}
        | .seriesRetirements //= {}
        | .seasonActions //= {}
        | .seriesActions //= {}
    ' "$WORK_STATE" > "$final" ||
       ! jq -e 'type == "object" and (.episodes | type == "object")' "$final" >/dev/null; then
        rm -f -- "$final"
        return 1
    fi

    backup="$(mktemp "$STATE_DIR/.state-backup.XXXXXX")" || return 1
    if cp -- "$STATE_FILE" "$backup"; then
        ops_publish_checkpoint "$backup" "$STATE_BACKUP"
    else
        rm -f -- "$backup"
        log WARNING "Could not update state backup."
    fi
    ops_publish_checkpoint "$final" "$STATE_FILE"
}

###############################################################################
# SONARR WORKFLOW
###############################################################################

run_sonarr() (
APP_CONTEXT="SONARR"
MC_COMPONENT_STARTED=$(date +%s);MC_COMPONENT_COMPLETED=false
ARR_NAME="Sonarr"
ARR_URL="$SONARR_URL"
ARR_API_KEY="$SONARR_API_KEY"
ARR_TEMP_PREFIX="sonarr"
ARR_USER_AGENT="$USER_AGENT Sonarr"
STATE_DIR="$RUNTIME_DIR"
STATE_FILE="$SONARR_STATE_FILE"
STATE_BACKUP="$SONARR_STATE_BACKUP"
RUN_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"
WORK_STATE=""
CURRENT_SNAPSHOT_FILE=""
SIDECAR_BATCH_FILE=""
SIDECAR_ENTRY_FILE=""
API_FAILURES=0
HISTORY_FAILURES=0
HISTORY_INSPECTIONS=0
HISTORY_DELETE_EVENTS=0
HISTORY_LIMIT_SKIPS=0
SERIES_LISTED=0
SERIES_SCANNED=0
EPISODES_SCANNED=0
FILES_PRESENT=0
FIRST_MISSING=0
EPISODES_CONFIRMED=0
EPISODE_ACTIONS=0
SEASON_ACTIONS=0
SERIES_ACTIONS=0
TAGGED_SERIES_ACTIONS=0
SIDECARS_CAPTURED=0
SIDECARS_QUARANTINED=0
SIDECARS_NATIVE_MISSING=0
SIDECARS_CHANGED=0
SIDECARS_LATE_CANDIDATES=0
SIDECARS_LATE_CONFIRMED=0
SIDECAR_FAILURES=0
FOLDERS_REMOVED=0
FOLDER_CLEANUP_PENDING=0
MOVER_DEFERRALS=0
MOVER_GUARD_NOTICE_LOGGED=false
STATE_PRUNED=0
RETIREMENTS_STARTED=0
RETIREMENTS_CANCELLED=0
ARR_REMOVALS=0
SONARR_QUEUE_JSON='{"records":[]}'
SONARR_QUEUE_AVAILABLE=false
TAG_CATALOG=''
PLEX_DELETED_SEASON_TAG_ID=''
PLEX_DELETED_SERIES_TAG_ID=''

trap cleanup_app EXIT
trap 'exit 130' INT TERM
mc_app_mutation_gate Sonarr || return $?


[[ -n "$SONARR_URL" && "$SONARR_URL" != */ ]] || die "Set SONARR_URL without a trailing slash."
[[ -n "$SONARR_API_KEY" && "$SONARR_API_KEY" != PUT_YOUR_SONARR_API_KEY_HERE ]] ||
    die "Set SONARR_API_KEY."
[[ "$SONARR_UNMONITOR_SEASON" == true || "$SONARR_UNMONITOR_SEASON" == false ]] ||
    die "SONARR_UNMONITOR_SEASON must be true or false."
[[ "$SONARR_UNMONITOR_SERIES" == true || "$SONARR_UNMONITOR_SERIES" == false ]] ||
    die "SONARR_UNMONITOR_SERIES must be true or false."
[[ "$PLEX_DELETED_SEASON_TAG" =~ ^[a-z0-9-]+$ ]] ||
    die "PLEX_DELETED_SEASON_TAG may contain only lowercase letters, numbers, and hyphens."
[[ "$PLEX_DELETED_SERIES_TAG" =~ ^[a-z0-9-]+$ ]] ||
    die "PLEX_DELETED_SERIES_TAG may contain only lowercase letters, numbers, and hyphens."
[[ "$SONARR_RETIREMENT_REQUIRED_TAG" =~ ^[a-z0-9-]+$ &&
   "$SONARR_RETIREMENT_EXEMPT_TAG" =~ ^[a-z0-9-]+$ &&
   "$SONARR_RETIREMENT_PENDING_TAG" =~ ^[a-z0-9-]+$ ]] ||
    die "Sonarr retirement tags may contain only lowercase letters, numbers, and hyphens."
[[ "$PLEX_DELETED_SEASON_TAG" != "$PLEX_DELETED_SERIES_TAG" ]] ||
    die "PLEX_DELETED_SEASON_TAG and PLEX_DELETED_SERIES_TAG must be different."
[[ "$PROGRESS_LOG_EVERY" =~ ^[1-9][0-9]*$ ]] ||
    die "PROGRESS_LOG_EVERY must be a positive integer."

if [[ ! -f "$STATE_FILE" ]]; then
    INITIAL_STATE="$(mktemp "$STATE_DIR/.state-initial.XXXXXX")" ||
        die "Cannot create initial state file."
    printf '%s\n' '{"version":7,"lastRun":null,"lastRunHadApiErrors":false,"episodes":{},"sidecarManifests":{},"sidecarCleanupActions":{},"seriesRetirements":{}}' > "$INITIAL_STATE" &&
        mv -f -- "$INITIAL_STATE" "$STATE_FILE" || {
            rm -f -- "$INITIAL_STATE"
            die "Cannot create state file."
        }
    log INFO "Created state file; this first run establishes a baseline."
fi
if ! jq -e 'type == "object" and (.episodes | type == "object")' "$STATE_FILE" >/dev/null; then
    die "State file is invalid: $STATE_FILE"
fi
WORK_STATE="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-working.XXXXXX")" || die "Cannot create working state."
cp -- "$STATE_FILE" "$WORK_STATE" || die "Cannot copy state to working file."

###############################################################################
# RUN
###############################################################################

log DEBUG "Starting delete sync (dry-run=$DRY_RUN, confirmations=$CONFIRMATION_RUNS)."
if [[ "$TRIGGER_LIBRARY_RESCAN" == true && "$DRY_RUN" != true ]]; then
    log INFO "API-only mode: requesting one Sonarr all-library rescan before checking episodes."
else
    log DEBUG "Using Sonarr's current database state; no rescan will be requested."
fi

SYSTEM="$(api_get_json "/api/v3/system/status")" || {
    ((API_FAILURES += 1))
    die "Cannot contact Sonarr; state was not changed."
}
if ! jq -e '.appName == "Sonarr"' >/dev/null 2>&1 <<< "$SYSTEM"; then
    die "Configured SONARR_URL did not identify itself as Sonarr."
fi
log DEBUG "Connected to Sonarr $(jq -r '.version // "unknown"' <<< "$SYSTEM")."

load_tag_catalog || {
    ((API_FAILURES += 1))
    die "Could not load Sonarr tags; state was not changed."
}

if [[ "$TRIGGER_LIBRARY_RESCAN" == true && "$DRY_RUN" != true ]]; then
    RESCAN_ID="$(start_arr_command '{"name":"RescanSeries"}')" || {
        ((API_FAILURES += 1))
        die "Could not start Sonarr library rescan; state was not changed."
    }
    log INFO "Submitted Sonarr library rescan command $RESCAN_ID; waiting before checking episodes."
    wait_for_arr_command "$RESCAN_ID" || {
        ((API_FAILURES += 1))
        die "Sonarr library rescan did not complete successfully; state was not changed."
    }
fi

recover_pending_actions || die "Unresolved prior actions require review; no further $ARR_NAME mutations were attempted."
SERIES="$(api_get_json "/api/v3/series")" || {
    ((API_FAILURES += 1))
    die "Could not retrieve series; state was not changed."
}
jq -e 'type == "array"' >/dev/null <<< "$SERIES" ||
    die "Sonarr /series did not return an array."
SERIES_LISTED="$(jq length <<< "$SERIES")"
jq -e 'all(.[]; (.id|type)=="number" and .id>0 and .id==(.id|floor))' <<<"$SERIES" >/dev/null || die "Invalid Sonarr catalog IDs; state preserved."
declare -A SONARR_CATALOG_INDEX=()
while IFS=$'\t' read -r catalog_id catalog_item; do
    SONARR_CATALOG_INDEX["$catalog_id"]="$catalog_item"
done < <(jq -r '.[] | (.id|tostring)+"\t"+tojson' <<<"$SERIES")

if [[ "$SONARR_RETIRE_FULLY_DELETED_SERIES" == true ]]; then
    if load_arr_queue sonarr; then
        queue_stateful_resolution_notification Sonarr "queue:sonarr:retirement" \
            "Sonarr retirement queue check restored" \
            "Queue status is available again; eligible retirement work may continue."
    else
        log WARNING "Sonarr queue status is unavailable; retirement starts and removals are deferred."
        queue_stateful_attention_notification WARNING Sonarr \
            "queue:sonarr:retirement" unavailable \
            "Sonarr retirement queue check unavailable" \
            "Normal delete-sync work continues, but no series retirement will start or complete until queue status is available." \
            "$FOLDER_BLOCKER_REMINDER_DAYS"
    fi
fi

# Every monitored series is scanned once, plus a series holding a pending
# candidate. No episode-file lookups, refresh commands, or same-run waits occur.
while IFS= read -r SERIES_ID; do
    [[ -n "$SERIES_ID" ]] || continue
    mc_work_allowed SONARR || break
    [[ "$SERIES_ID" =~ ^[1-9][0-9]*$ ]] || die "Invalid stored Sonarr series ID; state preserved."
    if media_recovery_app_held Sonarr "$SERIES_ID"; then log INFO "Series $SERIES_ID deletion/retirement deferred: integrity recovery holds its exact media; state preserved";continue;fi
    SERIES_ITEM="${SONARR_CATALOG_INDEX[$SERIES_ID]:-}"
    SERIES_TITLE="$(jq -r '.title // empty' <<< "$SERIES_ITEM")"
    SERIES_API_PATH="$(jq -r '.path // empty' <<< "$SERIES_ITEM")"
    SERIES_PATH=""
    if [[ -n "$SERIES_API_PATH" ]]; then
        SERIES_PATH="$(map_arr_media_path "$SERIES_API_PATH" "$SONARR_API_SERIES_ROOT" "$SERIES_ROOT" || true)"
    fi
    if [[ -z "$SERIES_TITLE" ]]; then
        log WARNING "Series $SERIES_ID is no longer returned by Sonarr; leaving its state untouched."
        continue
    fi

    NEXT_SERIES=$((SERIES_SCANNED + 1))
    if (( NEXT_SERIES == 1 || NEXT_SERIES % PROGRESS_LOG_EVERY == 0 )); then
        log INFO "Episode inspection progress: starting series $NEXT_SERIES ($SERIES_TITLE)."
    fi

    # Keep this potentially large response in a file.  Passing it through
    # jq's --argjson puts the full episode list in exec(2)'s argument vector,
    # which is what caused "Argument list too long" on large series.
    [[ -n "$CURRENT_SNAPSHOT_FILE" ]] && rm -f -- "$CURRENT_SNAPSHOT_FILE"
    CURRENT_SNAPSHOT_FILE="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.episodes.XXXXXX")" ||
        die "Cannot create temporary episode snapshot."
    if ! api_get_json "/api/v3/episode?seriesId=$SERIES_ID&includeEpisodeFile=true" > "$CURRENT_SNAPSHOT_FILE"; then
        ((API_FAILURES += 1))
        log ERROR "Skipping $SERIES_TITLE; its state was not advanced."
        continue
    fi
    jq -e 'type == "array"' "$CURRENT_SNAPSHOT_FILE" >/dev/null || {
        ((API_FAILURES += 1))
        log ERROR "Skipping $SERIES_TITLE; Sonarr returned a non-array episode response."
        continue
    }

    ((SERIES_SCANNED += 1))
    IFS=$'\t' read -r COUNT PRESENT < <(jq -r '[length,([.[] | select(.hasFile == true)]|length)]|@tsv' "$CURRENT_SNAPSHOT_FILE")
    [[ "$COUNT" =~ ^[0-9]+$ && "$PRESENT" =~ ^[0-9]+$ ]] || die "Could not count Sonarr episode snapshot."
    ((EPISODES_SCANNED += COUNT))
    ((FILES_PRESENT += PRESENT))

    [[ -n "$SIDECAR_ENTRY_FILE" ]] && rm -f -- "$SIDECAR_ENTRY_FILE"
    SIDECAR_ENTRY_FILE="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.sidecars.entry.XXXXXX")" ||
        die "Cannot create temporary Sonarr sidecar manifest."
    if [[ "$QUARANTINE_KODI_SIDECARS" == true ]] && (( PRESENT > 0 )); then
        MEDIA_RELATIVE_PATHS="$(jq '[
            .[]
            | select(.hasFile == true and (.episodeFile.relativePath | type == "string"))
            | .episodeFile.relativePath
        ] | unique' "$CURRENT_SNAPSHOT_FILE")" || die "Could not list Sonarr media paths for $SERIES_TITLE."
        if [[ -z "$SERIES_PATH" || "$(jq length <<< "$MEDIA_RELATIVE_PATHS")" == 0 ]]; then
            ((SIDECAR_FAILURES += 1))
            log ERROR "Could not capture Kodi sidecars for $SERIES_TITLE because Sonarr omitted its media path."
        elif capture_kodi_sidecars sonarr "$SERIES_PATH" "$SERIES_ROOT" \
            "$MEDIA_RELATIVE_PATHS" > "$SIDECAR_ENTRY_FILE"; then
            CAPTURED="$(jq length "$SIDECAR_ENTRY_FILE")"
            ((SIDECARS_CAPTURED += CAPTURED))
        else
            : > "$SIDECAR_ENTRY_FILE"
            ((SIDECAR_FAILURES += 1))
            log ERROR "Kodi sidecar manifest capture failed for $SERIES_TITLE; the previous manifest was retained."
        fi
    fi

    sonarr_apply_snapshot "$SERIES_ID" "$SERIES_TITLE" "$CURRENT_SNAPSHOT_FILE" \
        "$SERIES_PATH" "$SIDECAR_ENTRY_FILE" ||
        die "Could not update temporary state for $SERIES_TITLE."
    rm -f -- "$SIDECAR_ENTRY_FILE"
    SIDECAR_ENTRY_FILE=""

    NEW="$(sonarr_new_candidate_count "$SERIES_ID")"
    ((FIRST_MISSING += NEW))
    (( NEW > 0 )) && sonarr_log_new_candidates "$SERIES_ID"

    IDS="$(sonarr_confirmed_episode_ids "$CURRENT_SNAPSHOT_FILE")" ||
        die "Could not calculate episode action plan for $SERIES_TITLE."
    ID_COUNT="$(jq length <<< "$IDS")"
    ((EPISODES_CONFIRMED += ID_COUNT))
    ACTION_IDS="$IDS"
    EFFECTIVE='[]'

    if (( ID_COUNT > 0 )) && [[ "$INSPECT_DELETE_HISTORY" == true ]]; then
        if (( HISTORY_INSPECTIONS < MAX_HISTORY_INSPECTIONS_PER_RUN )); then
            ((HISTORY_INSPECTIONS += 1))
            if HISTORY="$(sonarr_series_delete_history "$SERIES_ID")"; then
                IDS_WITH_HISTORY="$(sonarr_ids_with_history "$IDS" "$HISTORY")" ||
                    die "Could not match Sonarr History evidence for $SERIES_TITLE."
                IDS_WITH_HISTORY_COUNT="$(jq length <<< "$IDS_WITH_HISTORY")"
                ((HISTORY_DELETE_EVENTS += IDS_WITH_HISTORY_COUNT))

                while IFS= read -r EPISODE_ID; do
                    [[ -n "$EPISODE_ID" ]] || continue
                    EVIDENCE="$(jq -c --argjson episode_id "$EPISODE_ID" '
                        [ .[] | select(.episodeId == $episode_id) ]
                        | sort_by(.date // "")
                        | last // null
                    ' <<< "$HISTORY")" ||
                        die "Could not select Sonarr History evidence for episode $EPISODE_ID."
                    sonarr_record_history_evidence "$EPISODE_ID" "$EVIDENCE" ||
                        die "Could not record Sonarr History evidence for episode $EPISODE_ID."
                done < <(jq -r '.[]' <<< "$IDS")

                if [[ "$REQUIRE_DELETE_HISTORY_EVENT" == true ]]; then
                    ACTION_IDS="$IDS_WITH_HISTORY"
                fi
                log DEBUG "History audit: $IDS_WITH_HISTORY_COUNT of $ID_COUNT confirmed episode(s) in $SERIES_TITLE have episodeFileDeleted evidence."
                if [[ "$REQUIRE_DELETE_HISTORY_EVENT" == true ]] &&
                   (( IDS_WITH_HISTORY_COUNT < ID_COUNT )); then
                    queue_attention_notification WARNING Sonarr \
                        "$SERIES_TITLE deletion action awaiting History evidence" \
                        "$((ID_COUNT - IDS_WITH_HISTORY_COUNT)) confirmed episode(s) remain monitored because required episodeFileDeleted evidence is unavailable."
                fi
            else
                ((HISTORY_FAILURES += 1))
                log WARNING "History audit failed for $SERIES_TITLE."
                [[ "$REQUIRE_DELETE_HISTORY_EVENT" == true ]] && ACTION_IDS='[]'
            fi
        else
            ((HISTORY_LIMIT_SKIPS += ID_COUNT))
            log WARNING "History inspection cap reached; deferred audit for $ID_COUNT episode(s) in $SERIES_TITLE."
            [[ "$REQUIRE_DELETE_HISTORY_EVENT" == true ]] && ACTION_IDS='[]'
            if [[ "$REQUIRE_DELETE_HISTORY_EVENT" == true ]]; then
                queue_attention_notification WARNING Sonarr \
                    "$SERIES_TITLE deletion action deferred" \
                    "The daily History inspection cap was reached before $ID_COUNT confirmed episode(s) could be verified."
            fi
        fi
    fi

    ACTION_ID_COUNT="$(jq length <<< "$ACTION_IDS")"
    if (( ACTION_ID_COUNT > 0 )); then
        if [[ "$DRY_RUN" == true ]]; then
            log INFO "DRY RUN: would unmonitor $ACTION_ID_COUNT confirmed episode(s) in $SERIES_TITLE: $(jq -r 'join(", ")' <<< "$ACTION_IDS")."
            EFFECTIVE="$ACTION_IDS"
            ((EPISODE_ACTIONS += ACTION_ID_COUNT))
        else
            PAYLOAD="$(jq -cn --argjson ids "$ACTION_IDS" '{episodeIds:$ids, monitored:false}')"
            if api_put_json "/api/v3/episode/monitor" "$PAYLOAD"; then
                log INFO "Unmonitored $ACTION_ID_COUNT confirmed episode(s) in $SERIES_TITLE: $(jq -r 'join(", ")' <<< "$ACTION_IDS")."
                sonarr_mark_episode_action "$ACTION_IDS" ||
                    die "Could not record episode action in temporary state."
                EFFECTIVE="$ACTION_IDS"
                ((EPISODE_ACTIONS += ACTION_ID_COUNT))
            else
                ((API_FAILURES += 1))
                log ERROR "Episode update failed for $SERIES_TITLE; it will be retried next run."
                queue_attention_notification ERROR Sonarr \
                    "$SERIES_TITLE episode update failed" \
                    "$ACTION_ID_COUNT confirmed episode(s) could not be unmonitored and will be retried."
            fi
        fi

        if (( $(jq length <<< "$EFFECTIVE") > 0 )); then
            queue_action_notification Sonarr "$SERIES_TITLE episodes unmonitored" \
                "Count: $ACTION_ID_COUNT; episode IDs: $(jq -r 'join(", ")' <<< "$EFFECTIVE")"
        fi
    fi

    if [[ "$QUARANTINE_KODI_SIDECARS" == true ]] &&
       [[ "$(sonarr_series_cleanup_eligible "$SERIES_ID" "$CURRENT_SNAPSHOT_FILE")" == true ]]; then
        if [[ -z "$SERIES_PATH" ]]; then
            ((SIDECAR_FAILURES += 1))
            log ERROR "Cannot map Sonarr path '$SERIES_API_PATH' from SONARR_API_SERIES_ROOT to SERIES_ROOT; sidecar cleanup for $SERIES_TITLE was deferred."
            queue_attention_notification WARNING Sonarr "$SERIES_TITLE cleanup deferred" \
                "The Sonarr media path could not be mapped safely: $SERIES_API_PATH"
        else
            MANIFEST="$(prepare_sidecar_cleanup_manifest "$SERIES_ID" \
                "$SERIES_PATH" "$SERIES_ROOT" series)" ||
                die "Could not prepare Kodi sidecar cleanup state for $SERIES_TITLE."
            if jq -e 'type == "object" and (.cleanupAlreadyRecorded // false) == true' \
                >/dev/null 2>&1 <<< "$MANIFEST"; then
                :
            elif quarantine_recorded_sidecars sonarr series "$SERIES_ROOT" "$SERIES_PATH" "$MANIFEST"; then
                ((SIDECARS_QUARANTINED += CLEANUP_QUARANTINED))
                ((SIDECARS_NATIVE_MISSING += CLEANUP_NATIVE_MISSING))
                ((SIDECARS_CHANGED += CLEANUP_CHANGED))
                ((FOLDERS_REMOVED += CLEANUP_FOLDERS_REMOVED))
                queue_cleanup_action_notification Sonarr "$SERIES_TITLE" "$SERIES_PATH"
                if [[ "$CLEANUP_COMPLETE" == true ]]; then
                    queue_folder_resolution_notification Sonarr "$SERIES_ID" \
                        "$SERIES_TITLE folder cleanup" "$SERIES_PATH"
                    sonarr_mark_sidecar_cleanup "$SERIES_ID" ||
                        die "Could not record Kodi sidecar cleanup for $SERIES_TITLE."
                elif [[ "$CLEANUP_FOLDER_PENDING" == true ]]; then
                    mark_sidecar_folder_cleanup_pending "$SERIES_ID" "$SERIES_PATH" \
                        "$SERIES_ROOT" series ||
                        die "Could not retain pending folder cleanup for $SERIES_TITLE."
                    ((FOLDER_CLEANUP_PENDING += 1))
                    queue_folder_blocker_notification Sonarr "$SERIES_ID" \
                        "$SERIES_TITLE folder cleanup pending" "$SERIES_PATH"
                elif (( CLEANUP_CHANGED > 0 )); then
                    queue_attention_notification WARNING Sonarr \
                        "$SERIES_TITLE sidecar cleanup deferred" \
                        "Preserved $CLEANUP_CHANGED changed/unsafe recorded sidecar(s). Completed: quarantined=$CLEANUP_QUARANTINED; folders removed=$CLEANUP_FOLDERS_REMOVED."$'\n'"$CLEANUP_EXCEPTION_DETAILS"
                fi
            else
                CLEANUP_RC=$?
                case "$CLEANUP_RC" in
                    3) ;;
                    4) ((MOVER_DEFERRALS += 1)) ;;
                    *)
                        ((SIDECAR_FAILURES += 1))
                        log ERROR "Kodi sidecar quarantine failed for $SERIES_TITLE; its manifest was retained."
                        queue_attention_notification ERROR Sonarr \
                            "$SERIES_TITLE sidecar quarantine failed" \
                            "Cleanup failed after quarantining $CLEANUP_QUARANTINED sidecar(s) and removing $CLEANUP_FOLDERS_REMOVED empty folder(s). Recovery intent and the manifest were retained; the next run will verify outcomes before retrying."$'\n'"$CLEANUP_OPERATION_DETAILS"$'\n'"$CLEANUP_EXCEPTION_DETAILS"
                        ;;
                esac
            fi
        fi
    fi

    RETIREMENT_RC=0
    sonarr_process_full_retirement "$SERIES_ID" "$SERIES_TITLE" \
        "$SERIES_ITEM" "$CURRENT_SNAPSHOT_FILE" || RETIREMENT_RC=$?
    case "$RETIREMENT_RC" in
        0) ;;
        10) continue ;;
        *)
            ((API_FAILURES += 1))
            log ERROR "Full-series retirement processing failed for $SERIES_TITLE; it will be retried."
            queue_attention_notification ERROR Sonarr \
                "$SERIES_TITLE retirement processing failed" \
                "No retirement removal occurred; the workflow will retry next run."
            continue
            ;;
    esac

    # Build independent season and series plans.  The series plan is default
    # off and still needs a fresh series-detail check below.
    SEASONS='[]'
    if [[ "$SONARR_UNMONITOR_SEASON" == true ]]; then
        SEASONS="$(sonarr_candidate_seasons "$SERIES_ID" "$CURRENT_SNAPSHOT_FILE" "$EFFECTIVE")" ||
            die "Could not calculate season action plan for $SERIES_TITLE."
    fi
    SEASON_COUNT="$(jq length <<< "$SEASONS")"

    SERIES_PRECONDITION=false
    if [[ "$SONARR_UNMONITOR_SERIES" == true ]]; then
        SERIES_PRECONDITION="$(sonarr_candidate_series "$SERIES_ID" "$CURRENT_SNAPSHOT_FILE" "$EFFECTIVE")" ||
            die "Could not calculate series action plan for $SERIES_TITLE."
    fi

    # Avoid series-detail calls except where there is an actual season plan or
    # an episode/state-qualified series plan.
    if (( SEASON_COUNT == 0 )) && [[ "$SERIES_PRECONDITION" != true ]]; then
        continue
    fi

    DETAIL="$(api_get_json "/api/v3/series/$SERIES_ID")" || {
        ((API_FAILURES += 1))
        log ERROR "Could not inspect season/series monitoring for $SERIES_TITLE; retrying next run."
        continue
    }
    jq -e 'type == "object" and (.seasons | type == "array")' >/dev/null <<< "$DETAIL" || {
        ((API_FAILURES += 1))
        log ERROR "Series detail for $SERIES_TITLE has no usable seasons array."
        continue
    }

    # A candidate season can already be unmonitored manually; only selected,
    # presently monitored seasons are included in the update payload.
    ACTIVE="$(
        jq -c --argjson candidates "$SEASONS" '
            [
                .seasons[]
                | .seasonNumber as $season
                | select(.monitored == true and ($candidates | index($season)) != null)
                | $season
            ]
            | unique
        ' <<< "$DETAIL"
    )"
    ACTIVE_COUNT="$(jq length <<< "$ACTIVE")"

    # A final series action requires every normal season (Season 1+) to be
    # unmonitored after this run's selected season changes.  Specials do not
    # block the action.  The top-level monitored flag must still be true.
    SERIES_ACTION="$(
        jq -c --argjson series_precondition "$SERIES_PRECONDITION" \
            --argjson active "$ACTIVE" '
            (
                $series_precondition
                and .monitored == true
                and ([.seasons[] | select(.seasonNumber > 0)] | length > 0)
                and all(
                    .seasons[] | select(.seasonNumber > 0);
                    . as $season
                    | (
                        $season.monitored != true
                        or (($active | index($season.seasonNumber)) != null)
                      )
                )
            )
        ' <<< "$DETAIL"
    )"

    if (( ACTIVE_COUNT == 0 )) && [[ "$SERIES_ACTION" != true ]]; then
        continue
    fi

    ACTION_TAG_LABELS=()
    (( ACTIVE_COUNT > 0 )) && ACTION_TAG_LABELS+=("$PLEX_DELETED_SEASON_TAG")
    [[ "$SERIES_ACTION" == true ]] && ACTION_TAG_LABELS+=("$PLEX_DELETED_SERIES_TAG")
    ACTION_TAG_LABEL_TEXT="$(jq -rn --args '$ARGS.positional | join(", ")' "${ACTION_TAG_LABELS[@]}")"

    if [[ "$DRY_RUN" == true ]]; then
        if (( ACTIVE_COUNT > 0 )); then
            log INFO "DRY RUN: would unmonitor season(s) $(jq -r 'join(", ")' <<< "$ACTIVE") for $SERIES_TITLE."
            ((SEASON_ACTIONS += ACTIVE_COUNT))
        fi
        if [[ "$SERIES_ACTION" == true ]]; then
            log INFO "DRY RUN: would unmonitor series $SERIES_TITLE after all normal seasons are unmonitored."
            ((SERIES_ACTIONS += 1))
        fi
        log INFO "DRY RUN: would ensure series tag(s) [$ACTION_TAG_LABEL_TEXT] on $SERIES_TITLE."
        ((TAGGED_SERIES_ACTIONS += 1))
        queue_action_notification Sonarr "$SERIES_TITLE monitoring and tags" \
            "Seasons to unmonitor: $(jq -r 'if length == 0 then "none" else join(", ") end' <<< "$ACTIVE"); series unmonitor: $SERIES_ACTION; tags: $ACTION_TAG_LABEL_TEXT"
        continue
    fi

    # Preserve the full resource and all season values except the selected
    # season updates. A series action changes only top-level .monitored. The
    # selected audit tags are appended to the existing series-level tags list.
    ACTION_TAG_IDS='[]'
    if (( ACTIVE_COUNT > 0 )); then
        ensure_tag_id "$PLEX_DELETED_SEASON_TAG" PLEX_DELETED_SEASON_TAG_ID || {
            ((API_FAILURES += 1))
            log ERROR "Could not prepare '$PLEX_DELETED_SEASON_TAG' for $SERIES_TITLE; no monitoring changes were sent."
            continue
        }
        ACTION_TAG_IDS="$(jq -cn --argjson tags "$ACTION_TAG_IDS" --argjson id "$PLEX_DELETED_SEASON_TAG_ID" '$tags + [$id] | unique')"
    fi
    if [[ "$SERIES_ACTION" == true ]]; then
        ensure_tag_id "$PLEX_DELETED_SERIES_TAG" PLEX_DELETED_SERIES_TAG_ID || {
            ((API_FAILURES += 1))
            log ERROR "Could not prepare '$PLEX_DELETED_SERIES_TAG' for $SERIES_TITLE; no monitoring changes were sent."
            continue
        }
        ACTION_TAG_IDS="$(jq -cn --argjson tags "$ACTION_TAG_IDS" --argjson id "$PLEX_DELETED_SERIES_TAG_ID" '$tags + [$id] | unique')"
    fi
    SERIES_PAYLOAD="$(
        jq -c --argjson active "$ACTIVE" \
            --argjson unmonitor_series "$SERIES_ACTION" \
            --argjson action_tags "$ACTION_TAG_IDS" '
            .seasons |= map(
                .seasonNumber as $season
                | if ($active | index($season)) != null then
                    .monitored = false
                  else
                    .
                  end
            )
            | if $unmonitor_series then .monitored = false else . end
            | .tags //= []
            | .tags |= ((. + $action_tags) | unique)
        ' <<< "$DETAIL"
    )"
    if api_put_json "/api/v3/series/$SERIES_ID" "$SERIES_PAYLOAD"; then
        if (( ACTIVE_COUNT > 0 )); then
            log INFO "Unmonitored season(s) $(jq -r 'join(", ")' <<< "$ACTIVE") for $SERIES_TITLE."
            sonarr_mark_season_action "$SERIES_ID" "$ACTIVE" ||
                die "Could not record season action in temporary state."
            ((SEASON_ACTIONS += ACTIVE_COUNT))
        fi
        if [[ "$SERIES_ACTION" == true ]]; then
            log INFO "Unmonitored series $SERIES_TITLE after all normal seasons were unmonitored."
            sonarr_mark_series_action "$SERIES_ID" ||
                die "Could not record series action in temporary state."
            ((SERIES_ACTIONS += 1))
        fi
        log INFO "Ensured series tag(s) [$ACTION_TAG_LABEL_TEXT] on $SERIES_TITLE."
        ((TAGGED_SERIES_ACTIONS += 1))
        queue_action_notification Sonarr "$SERIES_TITLE monitoring and tags" \
            "Seasons unmonitored: $(jq -r 'if length == 0 then "none" else join(", ") end' <<< "$ACTIVE"); series unmonitored: $SERIES_ACTION; tags: $ACTION_TAG_LABEL_TEXT"
    else
        ((API_FAILURES += 1))
        log ERROR "Season/series update failed for $SERIES_TITLE; it will be retried next run."
        queue_attention_notification ERROR Sonarr \
            "$SERIES_TITLE season or series update failed" \
            "The monitoring and tag update will be retried during the next daily run."
    fi
done < <(
    {
        jq -r '.[] | select(.monitored == true) | .id' <<< "$SERIES"
        jq -r '.episodes | to_entries[]? | select((.value.missingRuns // 0) > 0) | .value.seriesId' "$WORK_STATE"
    } | sort -nu
)

sonarr_prune_state "$SERIES" || die "Could not prune stale Sonarr state safely."
sonarr_commit_state || { [[ ! -d "${MC_TMP:-}" ]] || printf 'Sonarr state commit failed\n' >>"$MC_TMP/failed-arr";die "Could not atomically save state."; }
WORK_STATE=""

MC_COMPONENT_COMPLETED=true
mc_arr_metrics || die "Cannot record Arr timing/protection outcome."
ACTION_LABEL=applied
[[ "$DRY_RUN" == true ]] && ACTION_LABEL=would-apply
log INFO "Summary: series-listed=$SERIES_LISTED, series-scanned=$SERIES_SCANNED, episodes=$EPISODES_SCANNED, files-present=$FILES_PRESENT, first-missing=$FIRST_MISSING, confirmed=$EPISODES_CONFIRMED, history-inspected=$HISTORY_INSPECTIONS, history-delete-events=$HISTORY_DELETE_EVENTS, history-cap-skips=$HISTORY_LIMIT_SKIPS, episode-actions-$ACTION_LABEL=$EPISODE_ACTIONS, season-actions-$ACTION_LABEL=$SEASON_ACTIONS, series-actions-$ACTION_LABEL=$SERIES_ACTIONS, tagged-series-$ACTION_LABEL=$TAGGED_SERIES_ACTIONS, retirements-started=$RETIREMENTS_STARTED, retirements-cancelled=$RETIREMENTS_CANCELLED, arr-removals=$ARR_REMOVALS, state-pruned=$STATE_PRUNED, sidecars-captured=$SIDECARS_CAPTURED, sidecars-$ACTION_LABEL=$SIDECARS_QUARANTINED, late-sidecar-candidates=$SIDECARS_LATE_CANDIDATES, late-sidecars-confirmed-$ACTION_LABEL=$SIDECARS_LATE_CONFIRMED, sidecars-native-missing=$SIDECARS_NATIVE_MISSING, sidecars-changed=$SIDECARS_CHANGED, folders-removed-$ACTION_LABEL=$FOLDERS_REMOVED, folder-cleanup-pending=$FOLDER_CLEANUP_PENDING, mover-deferrals=$MOVER_DEFERRALS, api-failures=$API_FAILURES, history-failures=$HISTORY_FAILURES, sidecar-failures=$SIDECAR_FAILURES."

if (( API_FAILURES > 0 || HISTORY_FAILURES > 0 || SIDECAR_FAILURES > 0 )); then
    FAILURE_SEVERITY=WARNING
    (( API_FAILURES > 0 || SIDECAR_FAILURES > 0 )) && FAILURE_SEVERITY=ERROR
    queue_attention_notification "$FAILURE_SEVERITY" Sonarr \
        "Daily Sonarr delete-sync completed with failures" \
        "API failures: $API_FAILURES; history failures: $HISTORY_FAILURES; sidecar failures: $SIDECAR_FAILURES. Completed: unmonitored episodes=$EPISODE_ACTIONS, seasons=$SEASON_ACTIONS, series=$SERIES_ACTIONS; sidecars quarantined=$SIDECARS_QUARANTINED, empty folders removed=$FOLDERS_REMOVED, Arr removals=$ARR_REMOVALS. Pending actions were preserved for fresh verification."
    log WARNING "Completed with API, History, or sidecar failures; safe state was saved and unfinished actions will be retried."
    exit 2
fi
log DEBUG "Completed successfully."
)

###############################################################################
# UNIFIED ORCHESTRATION
###############################################################################

validate_common_configuration() {
    local command

    [[ "$RUNTIME_DIR" == "$MC_ROOT/arr" && ! -L "$RUNTIME_DIR" &&
       "$RUNTIME_DIR" != *$'\n'* ]] || {
        printf 'Unsafe RUNTIME_DIR: %s\n' "$RUNTIME_DIR" >&2
        return 1
    }
    for command in od curl jq mktemp stat sort cut tr cp mv find grep pgrep chown chmod wc \
        realpath sha256sum dirname rmdir flock sync; do
        command -v "$command" >/dev/null 2>&1 || {
            printf 'Required command not found: %s\n' "$command" >&2
            return 1
        }
    done

    [[ "$DRY_RUN" == true || "$DRY_RUN" == false ]] ||
        die "DRY_RUN must be true or false."
    [[ "$TRIGGER_LIBRARY_RESCAN" == true || "$TRIGGER_LIBRARY_RESCAN" == false ]] ||
        die "TRIGGER_LIBRARY_RESCAN must be true or false."
    [[ "$INSPECT_DELETE_HISTORY" == true || "$INSPECT_DELETE_HISTORY" == false ]] ||
        die "INSPECT_DELETE_HISTORY must be true or false."
    [[ "$REQUIRE_DELETE_HISTORY_EVENT" == true || "$REQUIRE_DELETE_HISTORY_EVENT" == false ]] ||
        die "REQUIRE_DELETE_HISTORY_EVENT must be true or false."
    [[ "$QUARANTINE_KODI_SIDECARS" == true || "$QUARANTINE_KODI_SIDECARS" == false ]] ||
        die "QUARANTINE_KODI_SIDECARS must be true or false."
    [[ "$CAPTURE_LATE_KODI_SIDECARS" == true || "$CAPTURE_LATE_KODI_SIDECARS" == false ]] ||
        die "CAPTURE_LATE_KODI_SIDECARS must be true or false."
    [[ "$REQUIRE_SIDECAR_HASH_MATCH" == true || "$REQUIRE_SIDECAR_HASH_MATCH" == false ]] ||
        die "REQUIRE_SIDECAR_HASH_MATCH must be true or false."
    [[ "$REMOVE_EMPTY_MEDIA_FOLDERS" == true || "$REMOVE_EMPTY_MEDIA_FOLDERS" == false ]] ||
        die "REMOVE_EMPTY_MEDIA_FOLDERS must be true or false."
    [[ "$DEFER_SIDECAR_CLEANUP_WHILE_MOVER" == true ||
       "$DEFER_SIDECAR_CLEANUP_WHILE_MOVER" == false ]] ||
        die "DEFER_SIDECAR_CLEANUP_WHILE_MOVER must be true or false."
    [[ "$SEND_GROUPED_NOTIFICATIONS" == true || "$SEND_GROUPED_NOTIFICATIONS" == false ]] ||
        die "SEND_GROUPED_NOTIFICATIONS must be true or false."
    [[ "$NOTIFY_DRY_RUN" == true || "$NOTIFY_DRY_RUN" == false ]] ||
        die "NOTIFY_DRY_RUN must be true or false."
    [[ "$SONARR_RETIRE_FULLY_DELETED_SERIES" == true ||
       "$SONARR_RETIRE_FULLY_DELETED_SERIES" == false ]] ||
        die "SONARR_RETIRE_FULLY_DELETED_SERIES must be true or false."
    [[ "$SONARR_RETIRE_CONTINUING_SERIES" == true ||
       "$SONARR_RETIRE_CONTINUING_SERIES" == false ]] ||
        die "SONARR_RETIRE_CONTINUING_SERIES must be true or false."
    [[ "$RADARR_MONITORED_FILELESS_RESCAN" == true ||
       "$RADARR_MONITORED_FILELESS_RESCAN" == false ]] ||
        die "RADARR_MONITORED_FILELESS_RESCAN must be true or false."
    [[ "$RADARR_RETIRE_FULLY_DELETED_MOVIES" == true ||
       "$RADARR_RETIRE_FULLY_DELETED_MOVIES" == false ]] ||
        die "RADARR_RETIRE_FULLY_DELETED_MOVIES must be true or false."
    [[ "$INSPECT_DELETE_HISTORY" == true || "$REQUIRE_DELETE_HISTORY_EVENT" == false ]] ||
        die "REQUIRE_DELETE_HISTORY_EVENT=true requires INSPECT_DELETE_HISTORY=true."
    [[ "$CONFIRMATION_RUNS" =~ ^[0-9]+$ ]] && (( CONFIRMATION_RUNS >= 2 )) ||
        die "CONFIRMATION_RUNS must be an integer of at least 2."
    [[ "$MAX_HISTORY_INSPECTIONS_PER_RUN" =~ ^[1-9][0-9]*$ ]] ||
        die "MAX_HISTORY_INSPECTIONS_PER_RUN must be a positive integer."
    [[ "$MAX_SIDECAR_SIZE_MB" =~ ^[1-9][0-9]*$ ]] ||
        die "MAX_SIDECAR_SIZE_MB must be a positive integer."
    [[ "$RADARR_MONITORED_FILELESS_WARNING_RUNS" =~ ^[0-9]+$ ]] &&
       (( RADARR_MONITORED_FILELESS_WARNING_RUNS >= 2 )) ||
        die "RADARR_MONITORED_FILELESS_WARNING_RUNS must be at least 2."
    [[ "$RADARR_MONITORED_FILELESS_WARNING_HOURS" =~ ^[1-9][0-9]*$ ]] ||
        die "RADARR_MONITORED_FILELESS_WARNING_HOURS must be a positive integer."
    [[ "$ARR_RETIREMENT_DAYS" =~ ^[1-9][0-9]*$ &&
       "$ARR_RETIREMENT_WARNING_DAYS" =~ ^[0-9]+$ ]] &&
       (( ARR_RETIREMENT_WARNING_DAYS < ARR_RETIREMENT_DAYS )) ||
        die "Retirement days must be positive and warning days smaller than the hold."
    [[ "$STATE_PRUNE_ABSENT_DAYS" =~ ^[1-9][0-9]*$ ]] ||
        die "STATE_PRUNE_ABSENT_DAYS must be a positive integer."
    [[ "$FOLDER_BLOCKER_REMINDER_DAYS" =~ ^[1-9][0-9]*$ ]] ||
        die "FOLDER_BLOCKER_REMINDER_DAYS must be a positive integer."
    [[ "$EXTRA_SIDECAR_EXTENSIONS" =~ ^[a-z0-9]+(,[a-z0-9]+)*$ ]] ||
        die "EXTRA_SIDECAR_EXTENSIONS must be a comma-separated lowercase extension list."
    [[ "$CLEANUP_REMAINING_LOG_MAX_ITEMS" =~ ^[1-9][0-9]*$ ]] ||
        die "CLEANUP_REMAINING_LOG_MAX_ITEMS must be a positive integer."
    [[ "$NOTIFICATION_MAX_ITEMS" =~ ^[1-9][0-9]*$ &&
       "$NOTIFICATION_ITEM_MAX_CHARS" =~ ^[1-9][0-9]*$ ]] ||
        die "Notification item limits must be positive integers."
    if [[ ! "$LOG_MAX_BYTES" =~ ^[0-9]+$ ]] || (( LOG_MAX_BYTES < 4096 )); then
        die "LOG_MAX_BYTES must be an integer of at least 4096 bytes."
    fi
    if [[ ! "$LOG_BACKUP_FILES" =~ ^[1-9][0-9]*$ ]]; then
        die "LOG_BACKUP_FILES must be a positive integer."
    fi
    if [[ ! "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
        die "LOG_RETENTION_DAYS must be zero or a positive integer."
    fi
    if [[ ! "$LOG_LINE_MAX_BYTES" =~ ^[0-9]+$ ]] ||
       (( LOG_LINE_MAX_BYTES < 256 || LOG_LINE_MAX_BYTES >= LOG_MAX_BYTES ));
    then
        die "LOG_LINE_MAX_BYTES must be at least 256 and smaller than LOG_MAX_BYTES."
    fi
    if [[ ! "$LOG_RUNAWAY_MULTIPLIER" =~ ^[0-9]+$ ]] ||
       (( LOG_RUNAWAY_MULTIPLIER < 2 ));
    then
        die "LOG_RUNAWAY_MULTIPLIER must be an integer of at least 2."
    fi
    [[ "$HTTP_CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ &&
       "$HTTP_MAX_TIME" =~ ^[1-9][0-9]*$ &&
       "$HTTP_RETRIES" =~ ^[0-9]+$ ]] ||
        die "HTTP timeout values must be positive integers and HTTP_RETRIES non-negative."
    [[ "$RESCAN_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ &&
       "$RESCAN_POLL_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
        die "Rescan timeout and poll values must be positive integers."

    if [[ "$QUARANTINE_KODI_SIDECARS" == true ]]; then
        [[ -n "$QUARANTINE_OWNER" && "$QUARANTINE_OWNER" != *:* ]] ||
            die "QUARANTINE_OWNER must name one owner without a group."
        [[ "$QUARANTINE_DIRECTORY_MODE" =~ ^0?[0-7]{3}$ ]] ||
            die "QUARANTINE_DIRECTORY_MODE must be a three- or four-digit octal mode."
        [[ "$QUARANTINE_FILE_MODE" =~ ^0?[0-7]{3}$ ]] ||
            die "QUARANTINE_FILE_MODE must be a three- or four-digit octal mode."
        [[ "$QUARANTINE_ROOT" == /mnt/user/* && "$QUARANTINE_ROOT" != "/mnt/user/" &&
           "$MOVIES_ROOT" == /mnt/user/* && "$MOVIES_ROOT" != "/mnt/user/" &&
           "$SERIES_ROOT" == /mnt/user/* && "$SERIES_ROOT" != "/mnt/user/" &&
           "$QUARANTINE_ROOT" != *$'\n'* && "$MOVIES_ROOT" != *$'\n'* &&
           "$SERIES_ROOT" != *$'\n'* ]] ||
            die "Kodi sidecar roots must be safe children of /mnt/user."
        [[ "$QUARANTINE_ROOT" != "$MOVIES_ROOT" &&
           "$QUARANTINE_ROOT" != "$SERIES_ROOT" &&
           "$MOVIES_ROOT" != "$SERIES_ROOT" &&
           "$QUARANTINE_ROOT" != "$MOVIES_ROOT"/* &&
           "$QUARANTINE_ROOT" != "$SERIES_ROOT"/* &&
           "$MOVIES_ROOT" != "$QUARANTINE_ROOT"/* &&
           "$SERIES_ROOT" != "$QUARANTINE_ROOT"/* ]] ||
            die "Quarantine, movies, and series roots must not overlap."
        [[ ! -L "$QUARANTINE_ROOT" && ! -L "$MOVIES_ROOT" && ! -L "$SERIES_ROOT" ]] ||
            die "Quarantine, movies, and series roots must not be symlinks."
        [[ "$SONARR_API_SERIES_ROOT" == /* && "$SONARR_API_SERIES_ROOT" != "/" &&
           "$RADARR_API_MOVIES_ROOT" == /* && "$RADARR_API_MOVIES_ROOT" != "/" &&
           "$SONARR_API_SERIES_ROOT" != *$'\n'* && "$RADARR_API_MOVIES_ROOT" != *$'\n'* &&
           "$SONARR_API_SERIES_ROOT" != */../* && "$SONARR_API_SERIES_ROOT" != */.. &&
           "$RADARR_API_MOVIES_ROOT" != */../* && "$RADARR_API_MOVIES_ROOT" != */.. ]] ||
            die "SONARR_API_SERIES_ROOT and RADARR_API_MOVIES_ROOT must be safe absolute paths."
    fi
}

acquire_main_lock() {
    local old_pid=""

    if ! mkdir -- "$LOCK_DIR" 2>/dev/null; then
        [[ -r "$LOCK_DIR/pid" ]] && old_pid="$(<"$LOCK_DIR/pid")"
        if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
            log WARNING "Another unified Arr delete-sync run is active (PID $old_pid); exiting."
            return 2
        fi
        log WARNING "Removing stale unified lock."
        rm -f -- "$LOCK_DIR/pid"
        rmdir -- "$LOCK_DIR" 2>/dev/null || return 1
        mkdir -- "$LOCK_DIR" || return 1
    fi
    printf '%s\n' "$$" > "$LOCK_DIR/pid" || return 1
    LOCK_HELD=true
}

# Shared maintenance protocol. Hold through API/filesystem mutations so appdata
# cannot stop dependencies midway through this run. Export lock protects a
# consistent per-service operational-state snapshot, never bulk application data.

main() {
    local mode="${1:-all}"
    local sonarr_rc=0 radarr_rc=0 lock_rc=0 notification_rc=0

    case "$mode" in
        --help|-h)
            printf '%s\n' 'Usage: /bin/bash SCRIPT arr [all|sonarr|radarr] [--dry-run|--execute]' '       /bin/bash SCRIPT arr --list-pending' '       /bin/bash SCRIPT arr --resolve-pending ACTION_ID "verified outcome and reason"' 'Execution is enabled by configuration. Preview still updates observation state.' 'Uncertain mutations are not blindly retried; read current Arr state and inspect pending actions.' 'Resolution records an operator decision in the action audit; it does not replay or reverse an action.' 'Notifications contain named actions, paths, preserved blockers and recovery results; unsent events carry forward.'
            return 0 ;;
        all|sonarr|radarr|--list-pending|--resolve-pending) ;;
        --version|-V)
            printf 'arr_delete_sync_tag.sh %s\n' "$SCRIPT_VERSION"
            return 0
            ;;
        *)
            printf 'Usage: %s [all|sonarr|radarr|--version]\n' "$0" >&2
            return 2
            ;;
    esac

    if [[ "$mode" == all || "$mode" == sonarr || "$mode" == radarr ]]; then
        case "${2:-}" in --dry-run) DRY_RUN=true;; --execute) DRY_RUN=false;; "") ;; *) printf 'Unknown override: %s\n' "$2" >&2; return 2;; esac
    fi
    local coordination_rc=0
    acquire_operation_coordination || coordination_rc=$?
    if (( coordination_rc==75 )); then printf 'MAINTENANCE: run deferred for appdata/startup/state export; no mutations performed.\n'; return 0; fi
    (( coordination_rc==0 )) || return 1

    command -v mountpoint >/dev/null 2>&1 || {
        printf 'Required command not found: mountpoint\n' >&2
        return 1
    }
    mountpoint -q /mnt/user || {
        notify_preflight_failure '/mnt/user is not mounted; runtime state cannot be opened safely.'
        return 1
    }
    validate_common_configuration || { notify_preflight_failure 'Arr delete-sync configuration or required commands failed validation; execution was stopped before application changes.'; return 1; }
    mkdir -p -- "$RUNTIME_DIR" || return 1
    [[ ! -L "$RUNTIME_DIR" ]] || {
        printf 'RUNTIME_DIR must not be a symlink: %s\n' "$RUNTIME_DIR" >&2
        return 1
    }
    [[ ! -L "$LOG_FILE" ]] || {
        printf 'LOG_FILE must not be a symlink: %s\n' "$LOG_FILE" >&2
        return 1
    }
    trap cleanup_main EXIT
    trap 'exit 130' INT TERM
    if acquire_main_lock; then
        :
    else
        lock_rc=$?
        case "$lock_rc" in
            2) MC_MODULE_STATUS=DEFERRED;MC_MODULE_REASON="Another Arr run holds its runtime lock";return 0 ;;
            *) die "Cannot acquire unified runtime lock." ;;
        esac
    fi
    initialize_logging || {
        printf 'Could not initialize persistent logging: %s\n' "$LOG_FILE" >&2
        return 1
    }

    exec 8>"$QUARANTINE_COORDINATION_LOCK"
    flock -n 8 || { MC_MODULE_STATUS=DEFERRED;MC_MODULE_REASON="Metadata quarantine producer lock is active"; log WARNING "Metadata quarantine is in use; scheduled run deferred without changes."; return 0; }
    VERIFY_RUNTIME_DIR=$(mktemp -d /tmp/arr-delete-verify.XXXXXX) || return 1
    remove_stale_temp_files
    initialize_grouped_notifications || die "${INITIALIZATION_FAILURE_REASON:-Could not initialize the action journal or grouped notification state; existing records were preserved.}"
    if [[ "$mode" == --list-pending ]]; then
        NOTIFICATION_FINALIZED=true
        jq '.actions|to_entries|map({id:.key}+.value)' "$PENDING_ACTIONS_FILE"
        return 0
    elif [[ "$mode" == --resolve-pending ]]; then
        local action_id="${2:-}" reason="${*:3}"
        [[ "$action_id" =~ ^[a-f0-9]{64}$ && -n "$reason" ]] || { printf 'An exact ACTION_ID and verified outcome/reason are required.\n' >&2; return 2; }
        jq -e --arg id "$action_id" '.actions[$id]!=null' "$PENDING_ACTIONS_FILE" >/dev/null || return 2
        journal_finish "$action_id" "Operator verified: $reason" || return 1
        queue_action_notification MAIN "Pending action resolved by operator" "Action $action_id: $reason. No API or media mutation was performed by this resolution command."
        send_grouped_notification
        return $?
    fi

    if [[ "$QUARANTINE_KODI_SIDECARS" == true && "$DRY_RUN" == false &&
          -e "$QUARANTINE_ROOT" ]]; then
        normalize_quarantine_permissions "$QUARANTINE_ROOT" ||
            die "Could not normalize quarantine ownership and permissions."
    fi

    QUARANTINE_RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
    [[ "$QUARANTINE_RUN_ID" =~ ^[0-9]{8}_[0-9]{6}_[0-9]+$ ]] ||
        die "Could not create a valid quarantine run ID."

    log DEBUG "Starting unified Arr delete workflow v$SCRIPT_VERSION (mode=$mode, dry-run=$DRY_RUN)."

    if [[ "$mode" == all || "$mode" == sonarr ]]; then
        run_sonarr || sonarr_rc=$?
        if ((sonarr_rc!=0)) && [[ -d "${MC_TMP:-}" && ! -f "$MC_TMP/deferred-SONARR" ]];then printf 'Sonarr workflow failed with exit=%s\n' "$sonarr_rc" >>"$MC_TMP/failed-arr";fi
    fi
    if [[ "$mode" == all || "$mode" == radarr ]]; then
        run_radarr || radarr_rc=$?
        if ((radarr_rc!=0)) && [[ -d "${MC_TMP:-}" && ! -f "$MC_TMP/deferred-RADARR" ]];then printf 'Radarr workflow failed with exit=%s\n' "$radarr_rc" >>"$MC_TMP/failed-arr";fi
    fi

    APP_CONTEXT="MAIN"
    log INFO "Combined summary: sonarr-rc=$sonarr_rc, radarr-rc=$radarr_rc."
    if (( sonarr_rc != 0 || radarr_rc != 0 )); then
        log WARNING "Unified Arr delete workflow completed with one or more application failures."
        queue_attention_notification ERROR MAIN "Application workflow failure" \
            "Sonarr exit status: ${sonarr_rc}; Radarr exit status: ${radarr_rc}. Successful actions remain committed; only incomplete work is reconsidered next run. No unverified retirement removal is reported as successful."$'\n'"$(current_workflow_error_details)"
    fi

    send_grouped_notification || {
        notification_rc=$?
        [[ ! -d "${MC_TMP:-}" ]] || printf 'Arr report handoff failed; producer outbox retained\n' >>"$MC_TMP/failed-arr"
    }

    if (( sonarr_rc != 0 || radarr_rc != 0 )); then
        return 2
    fi
    if (( notification_rc != 0 )); then
        log WARNING "Unified Arr delete workflow completed, but its grouped notification failed."
        return 2
    fi
    log DEBUG "Unified Arr delete workflow completed successfully."
}


###############################################################################
# STATE: work only in a temporary copy until final atomic commit
###############################################################################

# A tracked record is created only after Radarr first reports hasFile=true.
# A missing run counts only when the movie is fileless and, when configured,
# unmonitored.  A fileless but still-monitored movie therefore resets the
# confirmation counter instead of being treated as a deletion.
radarr_apply_snapshot() {
    local movies_file="$1"
    local sidecar_manifests_file="$2"
    local next
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-snapshot.XXXXXX")" || return 1

    if ! jq -c --arg now "$RUN_AT" \
        --argjson require_unmonitored "$RADARR_REQUIRE_MOVIE_UNMONITORED" \
        --slurpfile sidecar_source "$sidecar_manifests_file" \
        --slurpfile source "$movies_file" '($source[0] // []) as $movies
        | (($sidecar_source | add) // {}) as $sidecar_manifests
        | .movies //= {}
        | .movieRetirements //= {}
        | .sidecarManifests = ((.sidecarManifests // {}) * $sidecar_manifests)
        | reduce $movies[] as $movie (.;
            ($movie.id | tostring) as $key
            | (.movies[$key] // {}) as $old
            | {
                movieId: $movie.id,
                title: ($movie.title // "Unknown"),
                year: ($movie.year // null),
                tmdbId: ($movie.tmdbId // null),
                lastObservedAt: $now,
                lastObservedMonitored: ($movie.monitored == true)
              } as $identity
            | if $movie.hasFile == true then
                .movies[$key] = (
                    $old + $identity + {
                        everHadFile: true,
                        lastKnownMovieFileId: ($movie.movieFileId // 0),
                        lastSeenWithFileAt: $now,
                        missingSince: null,
                        missingRuns: 0,
                        monitoredFilelessSince: null,
                        monitoredFilelessRuns: 0,
                        lastMonitoredFilelessRescanAt: null
                    }
                )
              elif $old.everHadFile == true then
                .movies[$key] = (
                    $old + $identity +
                    (if (($require_unmonitored | not) or ($movie.monitored != true)) then
                        {
                            missingSince: ($old.missingSince // $now),
                            missingRuns: (($old.missingRuns // 0) + 1),
                            monitoredFilelessSince: null,
                            monitoredFilelessRuns: 0,
                            lastMonitoredFilelessRescanAt: null
                        }
                     else
                        {
                            missingSince: null,
                            missingRuns: 0,
                            monitoredFilelessSince: ($old.monitoredFilelessSince // $now),
                            monitoredFilelessRuns: (($old.monitoredFilelessRuns // 0) + 1)
                        }
                     end)
                )
              else
                .
              end
        )
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

radarr_cleanup_history_eligible() {
    local movie_id="$1"
    if [[ "$REQUIRE_DELETE_HISTORY_EVENT" == false ]]; then
        printf 'true'
        return 0
    fi
    jq -r --argjson movie_id "$movie_id" '
        (.movies[($movie_id | tostring)].latestMovieFileDeletedHistory // null) != null
    ' "$WORK_STATE"
}

radarr_mark_sidecar_cleanup() {
    local movie_id="$1"
    local next
    local total_quarantined total_native_missing total_folders_removed

    total_quarantined=$((CLEANUP_PROGRESS_QUARANTINED + CLEANUP_QUARANTINED))
    total_native_missing=$((CLEANUP_PROGRESS_NATIVE_MISSING + CLEANUP_NATIVE_MISSING))
    total_folders_removed=$((CLEANUP_PROGRESS_FOLDERS_REMOVED + CLEANUP_FOLDERS_REMOVED))
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-sidecar-action.XXXXXX")" || return 1

    if ! jq -c --arg now "$RUN_AT" \
        --arg run_id "$CLEANUP_QUARANTINE_RUN_ID" \
        --argjson movie_id "$movie_id" \
        --argjson quarantined "$total_quarantined" \
        --argjson native_missing "$total_native_missing" \
        --argjson folders_removed "$total_folders_removed" '
        .sidecarCleanupActions //= {}
        | .sidecarCleanupActions[($movie_id | tostring)] = {
            movieId: $movie_id,
            completedAt: $now,
            quarantineRunId: (if $quarantined > 0 and $run_id != "" then $run_id else null end),
            quarantinedFiles: $quarantined,
            nativeMissingFiles: $native_missing,
            foldersRemoved: $folders_removed
          }
        | del(.sidecarManifests[($movie_id | tostring)])
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

radarr_new_candidate_count() {
    jq -c --arg now "$RUN_AT" '
        [
            .movies[]
            | select(.missingSince == $now and .missingRuns == 1)
        ]
        | length
    ' "$WORK_STATE"
}

radarr_log_new_candidates() {
    while IFS= read -r line; do
        [[ -n "$line" ]] && log WARNING "$line"
    done < <(
        jq -r --arg now "$RUN_AT" '
            .movies[]
            | select(.missingSince == $now and .missingRuns == 1)
            | "Deletion candidate: \(.title)\(if .year == null then "" else " (\(.year))" end) [movie \(.movieId)]; confirmation pending."
        ' "$WORK_STATE"
    )
}

# Current Radarr data is always required in addition to state.  This prevents
# a removed Radarr movie from being acted on and makes an old state file alone
# insufficient to create a tag.
radarr_confirmed_movies() {
    local movies_file="$1"
    jq -c --slurpfile source "$movies_file" \
        --argjson require_unmonitored "$RADARR_REQUIRE_MOVIE_UNMONITORED" \
        --argjson needed "$CONFIRMATION_RUNS" '($source[0] // []) as $movies
        | .movies as $state
        | [
            $movies[]
            | select(.hasFile != true)
            | select(($require_unmonitored | not) or (.monitored != true))
            | . as $movie
            | ($movie.id | tostring) as $key
            | ($state[$key] // {}) as $record
            | select($record.everHadFile == true and ($record.missingRuns // 0) >= $needed)
            | {
                id: $movie.id,
                title: ($movie.title // "Unknown"),
                year: ($movie.year // null),
                path: ($movie.path // ""),
                tags: ($movie.tags // [])
              }
          ]
        | unique_by(.id)
    ' "$WORK_STATE"
}

radarr_movies_missing_tag() {
    local candidates="$1"
    local tag_id="$2"

    if [[ "$tag_id" =~ ^[0-9]+$ ]]; then
        jq -c --argjson tag_id "$tag_id" '
            [ .[] | select(((.tags // []) | index($tag_id)) == null) ]
        ' <<< "$candidates"
    else
        printf '%s' "$candidates"
    fi
}

radarr_record_history_evidence() {
    local movie_id="$1"
    local evidence="$2"
    local next
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-history.XXXXXX")" || return 1

    if ! jq -c --arg now "$RUN_AT" --argjson movie_id "$movie_id" \
        --argjson evidence "$evidence" '
        .movies[($movie_id | tostring)] |= . + {
            lastHistoryInspectionAt: $now,
            latestMovieFileDeletedHistory: $evidence
        }
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

# This endpoint returns an array for one movie, so it cannot create a costly
# full-library History sweep.  Only the newest movieFileDeleted record is kept.
radarr_history_delete_event() {
    local movie_id="$1"
    local history

    history="$(api_get_json "/api/v3/history/movie?movieId=$movie_id&eventType=movieFileDeleted")" || return 1
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$history"; then
        log ERROR "Radarr History for movie $movie_id did not return an array."
        return 1
    fi
    jq '[
            .[]
            | select(.eventType == "movieFileDeleted")
            | {id: .id, date: .date, eventType: .eventType, data: (.data // {})}
        ]
        | sort_by(.date // "")
        | last // null
    ' <<< "$history"
}

radarr_mark_tag_actions() {
    local ids="$1"
    local next
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-action.XXXXXX")" || return 1
    if ! jq -c --arg now "$RUN_AT" --argjson ids "$ids" '
        reduce $ids[] as $id (.;
            .movies[($id | tostring)] |= . + {lastPlexDeletedTagAppliedAt: $now}
        )
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

radarr_mark_watchdog_rescan() {
    local movie_id="$1"
    local next

    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-watchdog.XXXXXX")" || return 1
    if ! jq -c --argjson movie_id "$movie_id" --arg now "$RUN_AT" '
        .movies[($movie_id | tostring)].lastMonitoredFilelessRescanAt = $now
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

radarr_process_monitored_fileless_watchdog() {
    local movies_file="$1"
    local candidates movie movie_id title since runs signature command_id
    local key key_movie_id still_active

    candidates="$(jq -c --slurpfile source "$movies_file" \
        --argjson needed "$RADARR_MONITORED_FILELESS_WARNING_RUNS" '
        ($source[0] // []) as $movies
        | .movies as $state
        | [
            $movies[]
            | select(.hasFile != true and .monitored == true)
            | . as $movie
            | ($movie.id | tostring) as $key
            | ($state[$key] // {}) as $record
            | select(
                $record.everHadFile == true
                and ($record.monitoredFilelessRuns // 0) >= $needed
              )
            | {
                id: $movie.id,
                title: ($movie.title // "Unknown"),
                year: ($movie.year // null),
                since: ($record.monitoredFilelessSince // ""),
                runs: ($record.monitoredFilelessRuns // 0),
                lastRescanAt: ($record.lastMonitoredFilelessRescanAt // null)
              }
          ]
    ' "$WORK_STATE")" || return 1

    while IFS= read -r movie; do
        [[ -n "$movie" ]] || continue
        movie_id="$(jq -r '.id' <<< "$movie")"
        title="$(jq -r '"\(.title)\(if .year == null then "" else " (\(.year))" end)"' <<< "$movie")"
        since="$(jq -r '.since' <<< "$movie")"
        runs="$(jq -r '.runs' <<< "$movie")"
        age_at_least_hours "$since" "$RADARR_MONITORED_FILELESS_WARNING_HOURS" || continue

        if [[ "$RADARR_MONITORED_FILELESS_RESCAN" == true ]] &&
           [[ "$(jq -r '.lastRescanAt == null' <<< "$movie")" == true ]]; then
            command_id="$(start_arr_command "$(jq -cn --argjson id "$movie_id" '{name:"RescanMovie",movieIds:[$id]}')")" || return 1
            radarr_mark_watchdog_rescan "$movie_id" || return 1
            log INFO "Requested one Radarr rescan for monitored, fileless movie $title (command $command_id)."
            continue
        fi

        signature="$(notification_hash "$movie_id|$since")"
        queue_stateful_attention_notification WARNING Radarr \
            "watchdog:radarr:${movie_id}" "$signature" \
            "$title remains monitored after file deletion" \
            "Radarr still reports hasFile=false and monitored=true after $runs successful runs. Verify Unmonitor Deleted Movies and Radarr's folder-rescan policy. The script did not unmonitor it." \
            "$FOLDER_BLOCKER_REMINDER_DAYS"
    done < <(jq -c '.[]' <<< "$candidates")

    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        key_movie_id="${key##*:}"
        media_recovery_app_held Radarr "$key_movie_id" && continue
        still_active="$(jq -c --argjson id "$key_movie_id" \
            'any(.[]; .id == $id and .hasFile != true and .monitored == true)' \
            "$movies_file")" || still_active=false
        [[ "$still_active" == true ]] && continue
        queue_stateful_resolution_notification Radarr "$key" \
            "Radarr monitored-fileless condition resolved" \
            "Movie ID $key_movie_id either returned or became unmonitored."
    done < <(jq -r '.attention | keys[]? | select(startswith("watchdog:radarr:"))' \
        "$NOTIFICATION_STATE_FILE" 2>/dev/null || true)
}

radarr_cleanup_complete_for_retirement() {
    local movie_id="$1"

    if [[ "$QUARANTINE_KODI_SIDECARS" != true ]]; then
        return 0
    fi
    jq -e --arg key "$movie_id" '
        (.sidecarCleanupActions[$key] != null)
        and (.sidecarManifests[$key] == null)
    ' "$WORK_STATE" >/dev/null 2>&1
}

radarr_mark_retirement_started() {
    local movie_id="$1"
    local title="$2"
    local year="$3"
    local next

    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-retirement.XXXXXX")" || return 1
    if ! jq -c --arg key "$movie_id" \
        --argjson movie_id "$movie_id" \
        --arg title "$title" \
        --arg year "$year" \
        --arg now "$RUN_AT" '
        .movieRetirements //= {}
        | .movieRetirements[$key] = {
            movieId: $movie_id,
            title: $title,
            year: (if $year == "" then null else ($year | tonumber) end),
            startedAt: $now,
            lastValidatedAt: $now,
            suppressed: false,
            removedFromArrAt: null
          }
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

radarr_touch_retirement() {
    local movie_id="$1"
    local next
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-retirement-touch.XXXXXX")" || return 1
    if ! jq -c --arg key "$movie_id" --arg now "$RUN_AT" '
        .movieRetirements[$key].lastValidatedAt = $now
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

radarr_cancel_retirement() {
    local movie_id="$1"
    local reason="$2"
    local next
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-retirement-cancel.XXXXXX")" || return 1
    if ! jq -c --arg key "$movie_id" --arg now "$RUN_AT" --arg reason "$reason" '
        .movieRetirements //= {}
        | .movieRetirements[$key] = ((.movieRetirements[$key] // {}) + {
            startedAt: null,
            lastValidatedAt: $now,
            cancelledAt: $now,
            cancellationReason: $reason,
            suppressed: true
          })
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
    ((RETIREMENTS_CANCELLED += 1))
}

radarr_clear_retirement() {
    local movie_id="$1"
    local next
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-retirement-clear.XXXXXX")" || return 1
    if ! jq -c --arg key "$movie_id" 'del(.movieRetirements[$key])' \
        "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
    ((RETIREMENTS_CANCELLED += 1))
}

radarr_mark_removed_from_arr() {
    local movie_id="$1"
    local next
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-retirement-removed.XXXXXX")" || return 1
    if ! jq -c --arg key "$movie_id" --arg now "$RUN_AT" '
        .movieRetirements[$key].removedFromArrAt = $now
        | .movieRetirements[$key].lastValidatedAt = $now
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

radarr_process_retirements() {
    local movies_file="$1"
    local movie movie_id title year monitored has_file tags record started_at suppressed
    local exempt_id pending_id plex_id has_exempt=false tagged=false warning_threshold payload

    [[ "$RADARR_RETIRE_FULLY_DELETED_MOVIES" == true ]] || return 0
    local retirement_candidates
    retirement_candidates=$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.retirement-candidates.XXXXXX") || return 1
    # Healthy/monitored movies with no existing retirement cannot enter any
    # retirement branch. Select the work once, keeping ALL existing timers so
    # returned media, restored monitoring and exemptions still cancel holds.
    jq -c --slurpfile state "$WORK_STATE" '
      .[] | select(
        (($state[0].movieRetirements[(.id|tostring)].startedAt // "") != "")
        or (.hasFile != true and .monitored != true))' "$movies_file" >"$retirement_candidates" || return 1
    while IFS= read -r movie; do
        [[ -n "$movie" ]] || continue
        movie_id="$(jq -r '.id' <<< "$movie")"
        title="$(jq -r '.title // "Unknown"' <<< "$movie")"
        year="$(jq -r '.year // empty' <<< "$movie")"
        monitored="$(jq -r '.monitored == true' <<< "$movie")"
        has_file="$(jq -r '.hasFile == true' <<< "$movie")"
        tags="$(jq -c '.tags // []' <<< "$movie")"
        record="$(jq -c --arg key "$movie_id" '.movieRetirements[$key] // null' "$WORK_STATE")" || return 1
        started_at="$(jq -r '.startedAt // empty' <<< "$record")"
        suppressed="$(jq -r '.suppressed // false' <<< "$record")"
        has_exempt=false
        tagged=false

        exempt_id="$(tag_id_by_label "$RADARR_RETIREMENT_EXEMPT_TAG")"
        plex_id="$(tag_id_by_label "$PLEX_DELETED_MOVIE_TAG")"
        if [[ "$exempt_id" =~ ^[0-9]+$ ]] &&
           jq -e --argjson id "$exempt_id" 'index($id) != null' >/dev/null <<< "$tags"; then
            has_exempt=true
        fi
        if [[ "$plex_id" =~ ^[0-9]+$ ]] &&
           jq -e --argjson id "$plex_id" 'index($id) != null' >/dev/null <<< "$tags"; then
            tagged=true
        elif jq -e --arg key "$movie_id" '.movies[$key].lastPlexDeletedTagAppliedAt != null' \
            "$WORK_STATE" >/dev/null 2>&1; then
            tagged=true
        fi

        if [[ -n "$started_at" ]]; then
            if [[ "$has_file" == true ]]; then
                radarr_clear_retirement "$movie_id" || return 1
                queue_stateful_resolution_notification Radarr \
                    "retirement:radarr:${movie_id}:upcoming" \
                    "$title retirement hold cancelled" \
                    "Movie media returned before automatic removal."
                queue_action_notification Radarr "$title retirement cancelled" \
                    "Movie media returned; the previous retirement hold was cleared and a future deletion may start a new hold."
                continue
            fi
            if [[ "$monitored" == true || "$has_exempt" == true ]]; then
                radarr_cancel_retirement "$movie_id" \
                    "A file or monitoring returned, or the retirement exemption tag was applied." || return 1
                queue_stateful_resolution_notification Radarr \
                    "retirement:radarr:${movie_id}:upcoming" \
                    "$title retirement hold cancelled" \
                    "Monitoring was restored or a retirement exemption was applied."
                queue_action_notification Radarr "$title retirement cancelled" \
                    "Automatic Arr removal was cancelled because media or monitoring returned, or tag '$RADARR_RETIREMENT_EXEMPT_TAG' was applied."
                continue
            fi
            radarr_touch_retirement "$movie_id" || return 1
            warning_threshold=$((ARR_RETIREMENT_DAYS - ARR_RETIREMENT_WARNING_DAYS))
            (( warning_threshold < 0 )) && warning_threshold=0
            if age_at_least_days "$started_at" "$warning_threshold" &&
               ! age_at_least_days "$started_at" "$ARR_RETIREMENT_DAYS"; then
                queue_stateful_attention_notification WARNING Radarr \
                    "retirement:radarr:${movie_id}:upcoming" "$started_at" \
                    "$title scheduled for Arr removal" \
                    "The fully deleted movie will be removed from Radarr after ${ARR_RETIREMENT_DAYS} days unless media or monitoring returns. Started: $started_at" \
                    "$ARR_RETIREMENT_DAYS"
            fi
            age_at_least_days "$started_at" "$ARR_RETIREMENT_DAYS" || continue
            if [[ "$RADARR_QUEUE_AVAILABLE" != true ]] || radarr_queue_has_movie "$movie_id"; then
                log WARNING "Retirement removal for $title is due, but Radarr queue status is unavailable or active."
                continue
            fi
            if [[ "$DRY_RUN" == true ]]; then
                log INFO "DRY RUN: would remove retired movie $title from Radarr and add an import exclusion."
                queue_action_notification Radarr "$title retirement removal" \
                    "Would remove from Radarr with deleteFiles=false and addImportExclusion=true."
                continue
            fi
            if api_delete "/api/v3/movie/${movie_id}?deleteFiles=false&addImportExclusion=true"; then
                radarr_mark_removed_from_arr "$movie_id" || return 1
                queue_stateful_resolution_notification Radarr \
                    "retirement:radarr:${movie_id}:upcoming" \
                    "$title retirement hold completed" \
                    "The 90-day hold completed and the movie was removed from Radarr."
                queue_action_notification Radarr "$title removed from Radarr" \
                    "The fully deleted movie completed its ${ARR_RETIREMENT_DAYS}-day hold; files were not deleted and an import exclusion was added."
                log INFO "Removed retired movie $title from Radarr and added an import exclusion."
                ((ARR_REMOVALS += 1))
            else
                log ERROR "Could not remove retired movie $title from Radarr; it will be retried."
                queue_attention_notification ERROR Radarr "$title retirement removal failed" \
                    "The movie remains in Radarr and will be retried next run."
                return 1
            fi
            continue
        fi

        [[ "$suppressed" != true && "$has_file" != true && "$monitored" != true &&
           "$has_exempt" != true && "$tagged" == true ]] || continue
        jq -e --arg key "$movie_id" --argjson needed "$CONFIRMATION_RUNS" '
            (.movies[$key].everHadFile == true)
            and ((.movies[$key].missingRuns // 0) >= $needed)
        ' "$WORK_STATE" >/dev/null 2>&1 || continue
        radarr_cleanup_complete_for_retirement "$movie_id" || continue
        if [[ "$RADARR_QUEUE_AVAILABLE" != true ]] || radarr_queue_has_movie "$movie_id"; then
            continue
        fi
        if [[ "$DRY_RUN" == true ]]; then
            log INFO "DRY RUN: would start the ${ARR_RETIREMENT_DAYS}-day retirement hold for $title."
            queue_action_notification Radarr "$title retirement hold" \
                "Would add '$RADARR_RETIREMENT_PENDING_TAG' and start the ${ARR_RETIREMENT_DAYS}-day hold."
            continue
        fi
        ensure_tag_id "$RADARR_RETIREMENT_PENDING_TAG" pending_id || return 1
        payload="$(jq -cn --argjson movie_id "$movie_id" --argjson tag_id "$pending_id" \
            '{movieIds:[$movie_id],tags:[$tag_id],applyTags:"add"}')" || return 1
        api_put_json '/api/v3/movie/editor' "$payload" || return 1
        radarr_mark_retirement_started "$movie_id" "$title" "$year" || return 1
        queue_action_notification Radarr "$title retirement hold started" \
            "The confirmed deleted movie is unmonitored and clean; the ${ARR_RETIREMENT_DAYS}-day removal hold has started."
        log INFO "Started movie retirement for $title; removal hold is ${ARR_RETIREMENT_DAYS} days."
        ((RETIREMENTS_STARTED += 1))
    done <"$retirement_candidates"
    rm -f -- "$retirement_candidates"
}

radarr_prune_state() {
    local movies_file="$1"
    local now_epoch cutoff next pruned

    now_epoch="$(date +%s)"
    cutoff=$((now_epoch - STATE_PRUNE_ABSENT_DAYS * 86400))
    next="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-prune.XXXXXX")" || return 1
    if ! jq -c --arg now "$RUN_AT" \
        --argjson now_epoch "$now_epoch" \
        --argjson cutoff "$cutoff" \
        --slurpfile source "$movies_file" '
        ($source[0] | map(.id | tostring)) as $present
        | .movies //= {}
        | .movieRetirements //= {}
        | .sidecarManifests //= {}
        | .sidecarCleanupActions //= {}
        | reduce (.movies | keys[]) as $key (.;
            if ($present | index($key)) != null then
                del(.movies[$key].absentFromArrAt, .movies[$key].absentFromArrEpoch)
              else
                .movies[$key].absentFromArrAt //= $now
                | .movies[$key].absentFromArrEpoch //= $now_epoch
              end
          )
        | . as $state
        | [
            $state.movies | to_entries[]
            | select(
                (.value.absentFromArrEpoch // $now_epoch) <= $cutoff
                and $state.sidecarManifests[.key] == null
              )
            | .key
          ] as $keys
        | reduce $keys[] as $key (.;
            del(.movies[$key], .movieRetirements[$key], .sidecarCleanupActions[$key])
          )
        | .lastPrunedCount = ($keys | length)
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    pruned="$(jq -r '.lastPrunedCount // 0' "$next")"
    mv -f -- "$next" "$WORK_STATE"
    ((STATE_PRUNED += pruned))
    (( pruned == 0 )) || log INFO "Pruned $pruned Radarr movie state record(s) absent for at least $STATE_PRUNE_ABSENT_DAYS days."
}

radarr_commit_state() {
    local final backup had_errors
    final="$(mktemp "$STATE_DIR/.state-final.XXXXXX")" || return 1
    had_errors=false
    (( API_FAILURES > 0 || HISTORY_FAILURES > 0 || SIDECAR_FAILURES > 0 )) && had_errors=true

    if ! jq -c --arg now "$RUN_AT" --argjson had_errors "$had_errors" '
        .version = 5
        | .lastRun = $now
        | .lastRunHadApiErrors = $had_errors
        | .movies //= {}
        | .sidecarManifests //= {}
        | .sidecarCleanupActions //= {}
        | .movieRetirements //= {}
    ' "$WORK_STATE" > "$final" ||
       ! jq -e 'type == "object" and (.movies | type == "object")' "$final" >/dev/null; then
        rm -f -- "$final"
        return 1
    fi

    backup="$(mktemp "$STATE_DIR/.state-backup.XXXXXX")" || return 1
    if cp -- "$STATE_FILE" "$backup"; then
        ops_publish_checkpoint "$backup" "$STATE_BACKUP"
    else
        rm -f -- "$backup"
        log WARNING "Could not update state backup."
    fi
    ops_publish_checkpoint "$final" "$STATE_FILE"
}

radarr_movie_name() {
    local movie="$1"
    jq -r '"\(.title)\(if .year == null then "" else " (\(.year))" end) [movie \(.id)]"' <<< "$movie"
}

###############################################################################
# RADARR WORKFLOW
###############################################################################

run_radarr() (
APP_CONTEXT="RADARR"
MC_COMPONENT_STARTED=$(date +%s);MC_COMPONENT_COMPLETED=false
ARR_NAME="Radarr"
ARR_URL="$RADARR_URL"
ARR_API_KEY="$RADARR_API_KEY"
ARR_TEMP_PREFIX="radarr"
ARR_USER_AGENT="$USER_AGENT Radarr"
STATE_DIR="$RUNTIME_DIR"
STATE_FILE="$RADARR_STATE_FILE"
STATE_BACKUP="$RADARR_STATE_BACKUP"
RUN_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"
WORK_STATE=""
CURRENT_SNAPSHOT_FILE=""
SIDECAR_BATCH_FILE=""
SIDECAR_ENTRY_FILE=""
API_FAILURES=0
HISTORY_FAILURES=0
MOVIES_LISTED=0
MOVIES_SCANNED=0
FILES_PRESENT=0
FIRST_MISSING=0
MOVIES_CONFIRMED=0
HISTORY_INSPECTIONS=0
HISTORY_DELETE_EVENTS=0
HISTORY_LIMIT_SKIPS=0
TAG_ACTIONS=0
SIDECARS_CAPTURED=0
SIDECARS_QUARANTINED=0
SIDECARS_NATIVE_MISSING=0
SIDECARS_CHANGED=0
SIDECARS_LATE_CANDIDATES=0
SIDECARS_LATE_CONFIRMED=0
SIDECAR_FAILURES=0
FOLDERS_REMOVED=0
FOLDER_CLEANUP_PENDING=0
MOVER_DEFERRALS=0
MOVER_GUARD_NOTICE_LOGGED=false
STATE_PRUNED=0
RETIREMENTS_STARTED=0
RETIREMENTS_CANCELLED=0
ARR_REMOVALS=0
RADARR_QUEUE_JSON='{"records":[]}'
RADARR_QUEUE_AVAILABLE=false
TAG_CATALOG=''
PLEX_DELETED_MOVIE_TAG_ID=''

trap cleanup_app EXIT
trap 'exit 130' INT TERM
mc_app_mutation_gate Radarr || return $?


[[ -n "$RADARR_URL" && "$RADARR_URL" != */ ]] || die "Set RADARR_URL without a trailing slash."
[[ -n "$RADARR_API_KEY" && "$RADARR_API_KEY" != PUT_YOUR_RADARR_API_KEY_HERE ]] ||
    die "Set RADARR_API_KEY."
[[ "$RADARR_REQUIRE_MOVIE_UNMONITORED" == true || "$RADARR_REQUIRE_MOVIE_UNMONITORED" == false ]] ||
    die "RADARR_REQUIRE_MOVIE_UNMONITORED must be true or false."
[[ "$PLEX_DELETED_MOVIE_TAG" =~ ^[a-z0-9-]+$ ]] ||
    die "PLEX_DELETED_MOVIE_TAG may contain only lowercase letters, numbers, and hyphens."
[[ "$RADARR_RETIREMENT_EXEMPT_TAG" =~ ^[a-z0-9-]+$ &&
   "$RADARR_RETIREMENT_PENDING_TAG" =~ ^[a-z0-9-]+$ ]] ||
    die "Radarr retirement tags may contain only lowercase letters, numbers, and hyphens."

if [[ ! -f "$STATE_FILE" ]]; then
    INITIAL_STATE="$(mktemp "$STATE_DIR/.state-initial.XXXXXX")" ||
        die "Cannot create initial state file."
    printf '%s\n' '{"version":5,"lastRun":null,"lastRunHadApiErrors":false,"movies":{},"sidecarManifests":{},"sidecarCleanupActions":{},"movieRetirements":{}}' > "$INITIAL_STATE" &&
        mv -f -- "$INITIAL_STATE" "$STATE_FILE" || {
            rm -f -- "$INITIAL_STATE"
            die "Cannot create state file."
        }
    log INFO "Created state file; this first run establishes a baseline."
fi
if ! jq -e 'type == "object" and (.movies | type == "object")' "$STATE_FILE" >/dev/null; then
    die "State file is invalid: $STATE_FILE"
fi
WORK_STATE="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.state-working.XXXXXX")" || die "Cannot create working state."
cp -- "$STATE_FILE" "$WORK_STATE" || die "Cannot copy state to working file."

###############################################################################
# RUN
###############################################################################

log DEBUG "Starting delete tagger (dry-run=$DRY_RUN, confirmations=$CONFIRMATION_RUNS)."
media_recovery_journal_valid || die 'Media recovery hold journal invalid; Radarr state and media preserved.'
if [[ "$TRIGGER_LIBRARY_RESCAN" == true && "$DRY_RUN" != true ]]; then
    log INFO "Requesting one Radarr all-library rescan before checking movies."
else
    log DEBUG "Using Radarr's current database state; no rescan will be requested."
fi

SYSTEM="$(api_get_json "/api/v3/system/status")" || {
    ((API_FAILURES += 1))
    die "Cannot contact Radarr; state was not changed."
}
if ! jq -e '.appName == "Radarr"' >/dev/null 2>&1 <<< "$SYSTEM"; then
    die "Configured RADARR_URL did not identify itself as Radarr."
fi
log DEBUG "Connected to Radarr $(jq -r '.version // "unknown"' <<< "$SYSTEM")."

load_tag_catalog || {
    ((API_FAILURES += 1))
    die "Could not load Radarr tags; state was not changed."
}

if [[ "$TRIGGER_LIBRARY_RESCAN" == true && "$DRY_RUN" != true ]]; then
    RESCAN_ID="$(start_arr_command '{"name":"RescanMovie"}')" || {
        ((API_FAILURES += 1))
        die "Could not start Radarr library rescan; state was not changed."
    }
    log INFO "Submitted Radarr library rescan command $RESCAN_ID; waiting before checking movies."
    wait_for_arr_command "$RESCAN_ID" || {
        ((API_FAILURES += 1))
        die "Radarr library rescan did not complete successfully; state was not changed."
    }
fi

# Keep this potentially large response in a file.  Passing a full library as
# jq -c --argjson would put it in exec(2)'s argument vector and can cause
# "Argument list too long" on larger libraries.
recover_pending_actions || die "Unresolved prior actions require review; no further $ARR_NAME mutations were attempted."
CURRENT_SNAPSHOT_FILE="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.movies.XXXXXX")" ||
    die "Cannot create temporary movie snapshot."
if ! api_get_json "/api/v3/movie" > "$CURRENT_SNAPSHOT_FILE"; then
    ((API_FAILURES += 1))
    die "Could not retrieve movies; state was not changed."
fi
jq -e 'type == "array"' "$CURRENT_SNAPSHOT_FILE" >/dev/null ||
    die "Radarr /movie did not return an array."

MOVIES_LISTED="$(jq length "$CURRENT_SNAPSHOT_FILE")"
RADARR_ACTION_SNAPSHOT_FILE=$(mktemp "$VERIFY_RUNTIME_DIR/.radarr-action-snapshot.XXXXXX") || die 'Cannot prepare Radarr action snapshot.'
RADARR_HOLD_IDS_FILE=$(mktemp "$VERIFY_RUNTIME_DIR/.radarr-recovery-holds.XXXXXX") || die 'Cannot prepare movie hold IDs.'
radarr_action_snapshot "$CURRENT_SNAPSHOT_FILE" "$RADARR_ACTION_SNAPSHOT_FILE" "$RADARR_HOLD_IDS_FILE" || die 'Cannot validate/filter exact movie recovery holds.'
RECOVERY_HELD_COUNT=$(jq -c --slurpfile active "$RADARR_ACTION_SNAPSHOT_FILE" 'length-($active[0]|length)' "$CURRENT_SNAPSHOT_FILE")
MOVIES_SCANNED=$(jq length "$RADARR_ACTION_SNAPSHOT_FILE")
((RECOVERY_HELD_COUNT==0)) || log INFO "Radarr recovery holds: $RECOVERY_HELD_COUNT current movie(s) protected; $MOVIES_SCANNED unrelated movie(s) continue normally."

FILES_PRESENT="$(jq '[.[] | select(.hasFile == true)] | length' "$CURRENT_SNAPSHOT_FILE")"

SIDECAR_BATCH_FILE="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.sidecars.batch.XXXXXX")" ||
    die "Cannot create temporary Radarr sidecar manifest batch."
if [[ "$QUARANTINE_KODI_SIDECARS" == true ]] && (( FILES_PRESENT > 0 )); then
    RADARR_CAPTURE_SCANNED=0
    while IFS= read -r MOVIE_WITH_FILE; do
        [[ -n "$MOVIE_WITH_FILE" ]] || continue
        mc_work_allowed RADARR || break
        MOVIE_ID="$(jq -r '.id' <<< "$MOVIE_WITH_FILE")"
        (( RADARR_CAPTURE_SCANNED+=1 ))
        if (( RADARR_CAPTURE_SCANNED==1 || RADARR_CAPTURE_SCANNED%PROGRESS_LOG_EVERY==0 )); then
            log INFO "Sidecar inventory progress: inspected $RADARR_CAPTURE_SCANNED movie(s); current movie ID=$MOVIE_ID."
        fi
        MOVIE_API_PATH="$(jq -r '.path // empty' <<< "$MOVIE_WITH_FILE")"
        MOVIE_PATH="$(map_arr_media_path "$MOVIE_API_PATH" "$RADARR_API_MOVIES_ROOT" "$MOVIES_ROOT" || true)"
        MOVIE_RELATIVE_PATH="$(jq -r '.movieFile.relativePath // empty' <<< "$MOVIE_WITH_FILE")"
        if [[ -z "$MOVIE_PATH" || -z "$MOVIE_RELATIVE_PATH" ]]; then
            ((SIDECAR_FAILURES += 1))
            log ERROR "Could not map or capture Kodi sidecars for Radarr movie $MOVIE_ID (API path: $MOVIE_API_PATH)."
            continue
        fi
        MEDIA_RELATIVE_PATHS="$(jq -cn --arg path "$MOVIE_RELATIVE_PATH" '[$path]')"
        [[ -n "$SIDECAR_ENTRY_FILE" ]] && rm -f -- "$SIDECAR_ENTRY_FILE"
        SIDECAR_ENTRY_FILE="$(mktemp "${VERIFY_RUNTIME_DIR:-$STATE_DIR}/.sidecars.entry.XXXXXX")" ||
            die "Cannot create temporary Radarr sidecar manifest."
        if capture_kodi_sidecars radarr "$MOVIE_PATH" "$MOVIES_ROOT" \
            "$MEDIA_RELATIVE_PATHS" > "$SIDECAR_ENTRY_FILE"; then
            CAPTURED="$(jq length "$SIDECAR_ENTRY_FILE")"
            ((SIDECARS_CAPTURED += CAPTURED))
            if ! jq -n --arg key "$MOVIE_ID" \
                --arg media_path "$MOVIE_PATH" \
                --arg media_root "$MOVIES_ROOT" \
                --arg now "$RUN_AT" \
                --slurpfile files_source "$SIDECAR_ENTRY_FILE" '
                ($files_source[0] // []) as $files
                | {($key):{
                    mediaPath:$media_path,
                    mediaRoot:$media_root,
                    bucket:"movies",
                    capturedAt:$now,
                    files:$files,
                    lateSidecarCandidates:[]
                }}
            ' >> "$SIDECAR_BATCH_FILE"; then
                die "Could not build Radarr sidecar manifest batch."
            fi
        else
            ((SIDECAR_FAILURES += 1))
            log ERROR "Kodi sidecar manifest capture failed for Radarr movie $MOVIE_ID; its previous manifest was retained."
        fi
        rm -f -- "$SIDECAR_ENTRY_FILE"
        SIDECAR_ENTRY_FILE=""
    done < <(jq -c '.[] | select(.hasFile == true)' "$RADARR_ACTION_SNAPSHOT_FILE")
fi

radarr_apply_snapshot "$RADARR_ACTION_SNAPSHOT_FILE" "$SIDECAR_BATCH_FILE" ||
    die "Could not update temporary state."
rm -f -- "$SIDECAR_BATCH_FILE"
SIDECAR_BATCH_FILE=""

if [[ "$RADARR_RETIRE_FULLY_DELETED_MOVIES" == true ]]; then
    if load_arr_queue radarr; then
        queue_stateful_resolution_notification Radarr "queue:radarr:retirement" \
            "Radarr retirement queue check restored" \
            "Queue status is available again; eligible retirement work may continue."
    else
        log WARNING "Radarr queue status is unavailable; retirement starts and removals are deferred."
        queue_stateful_attention_notification WARNING Radarr \
            "queue:radarr:retirement" unavailable \
            "Radarr retirement queue check unavailable" \
            "Normal delete-sync work continues, but no movie retirement will start or complete until queue status is available." \
            "$FOLDER_BLOCKER_REMINDER_DAYS"
    fi
fi

radarr_process_monitored_fileless_watchdog "$RADARR_ACTION_SNAPSHOT_FILE" || {
    ((API_FAILURES += 1))
    log ERROR "Radarr monitored-fileless watchdog failed."
    queue_attention_notification ERROR Radarr "Monitored-fileless watchdog failed" \
        "The main workflow continues, but watchdog state could not be evaluated."
}

FIRST_MISSING="$(radarr_new_candidate_count)"
(( FIRST_MISSING == 0 )) || radarr_log_new_candidates

CONFIRMED="$(radarr_confirmed_movies "$RADARR_ACTION_SNAPSHOT_FILE")" ||
    die "Could not calculate tag action plan."
MOVIES_CONFIRMED="$(jq length <<< "$CONFIRMED")"

if (( MOVIES_CONFIRMED > 0 )); then
    PLEX_DELETED_MOVIE_TAG_ID="$(jq -r --arg label "$PLEX_DELETED_MOVIE_TAG" 'first(.[] | select(.label == $label) | .id) // empty' <<< "$TAG_CATALOG")"
        ACTION_CANDIDATES="$(radarr_movies_missing_tag "$CONFIRMED" "$PLEX_DELETED_MOVIE_TAG_ID")" ||
            die "Could not calculate movies that need the '$PLEX_DELETED_MOVIE_TAG' tag."
        ACTION_CANDIDATE_COUNT="$(jq length <<< "$ACTION_CANDIDATES")"
        if [[ "${MC_GUARDS_ACTIVE:-false}" == true ]] && ((ACTION_CANDIDATE_COUNT>MC_RADARR_MAX_TAG_MOVIES));then
            mc_defer_work RADARR_TAG_REMAINDER "$((ACTION_CANDIDATE_COUNT-MC_RADARR_MAX_TAG_MOVIES)) movie tag candidates remain beyond the bulk limit; retry next run"
            ACTION_CANDIDATES=$(jq -c --argjson limit "$MC_RADARR_MAX_TAG_MOVIES" 'sort_by(.id)|.[:$limit]' <<<"$ACTION_CANDIDATES") || return 1
            ACTION_CANDIDATE_COUNT=$(jq length <<<"$ACTION_CANDIDATES")
        fi

        if (( ACTION_CANDIDATE_COUNT == 0 )); then
            log DEBUG "All $MOVIES_CONFIRMED confirmed movie(s) already have the '$PLEX_DELETED_MOVIE_TAG' tag."
        else
            ELIGIBLE_IDS='[]'
            while IFS= read -r MOVIE; do
                [[ -n "$MOVIE" ]] || continue
                MOVIE_ID="$(jq -r '.id' <<< "$MOVIE")"
                MOVIE_LABEL="$(radarr_movie_name "$MOVIE")"
                HISTORY_EVIDENCE=null
                HISTORY_INSPECTED=false

                if [[ "$INSPECT_DELETE_HISTORY" == true ]]; then
                    if (( HISTORY_INSPECTIONS < MAX_HISTORY_INSPECTIONS_PER_RUN )); then
                        HISTORY_INSPECTED=true
                        ((HISTORY_INSPECTIONS += 1))
                        if HISTORY_EVIDENCE="$(radarr_history_delete_event "$MOVIE_ID")"; then
                            radarr_record_history_evidence "$MOVIE_ID" "$HISTORY_EVIDENCE" ||
                                die "Could not record History evidence for $MOVIE_LABEL."
                            if [[ "$HISTORY_EVIDENCE" != null ]]; then
                                ((HISTORY_DELETE_EVENTS += 1))
                                log DEBUG "History audit: $MOVIE_LABEL has movieFileDeleted event $(jq -r '.id // "unknown"' <<< "$HISTORY_EVIDENCE") at $(jq -r '.date // "unknown"' <<< "$HISTORY_EVIDENCE")."
                            else
                                log DEBUG "History audit: $MOVIE_LABEL has no movieFileDeleted event."
                            fi
                        else
                            ((HISTORY_FAILURES += 1))
                            log WARNING "History audit failed for $MOVIE_LABEL."
                        fi
                    else
                        ((HISTORY_LIMIT_SKIPS += 1))
                        log WARNING "History inspection cap reached; deferred audit for $MOVIE_LABEL."
                    fi
                fi

                if [[ "$REQUIRE_DELETE_HISTORY_EVENT" == true ]] &&
                   { [[ "$HISTORY_INSPECTED" != true ]] || [[ "$HISTORY_EVIDENCE" == null ]]; }; then
                    log INFO "Not tagging $MOVIE_LABEL because no verified movieFileDeleted History event is available."
                    queue_attention_notification WARNING Radarr \
                        "$MOVIE_LABEL tag action awaiting History evidence" \
                        "The required movieFileDeleted event is unavailable; the movie remains untagged."
                    continue
                fi

                ELIGIBLE_IDS="$(jq -c --argjson movie_id "$MOVIE_ID" '. + [$movie_id] | unique' <<< "$ELIGIBLE_IDS")" ||
                    die "Could not extend the tag action plan."
            done < <(jq -c '.[]' <<< "$ACTION_CANDIDATES")

            ELIGIBLE_COUNT="$(jq length <<< "$ELIGIBLE_IDS")"
            if (( ELIGIBLE_COUNT > 0 )); then
                if [[ "$DRY_RUN" == true ]]; then
                    if [[ ! "$PLEX_DELETED_MOVIE_TAG_ID" =~ ^[0-9]+$ ]]; then
                        log INFO "DRY RUN: would create Radarr tag '$PLEX_DELETED_MOVIE_TAG'."
                    fi
                    while IFS= read -r MOVIE; do
                        [[ -n "$MOVIE" ]] || continue
                        log INFO "DRY RUN: would add '$PLEX_DELETED_MOVIE_TAG' to $(radarr_movie_name "$MOVIE")."
                        queue_action_notification Radarr \
                            "$(radarr_movie_name "$MOVIE") tag update" \
                            "Tag to add: $PLEX_DELETED_MOVIE_TAG"
                    done < <(
                        jq -c --argjson ids "$ELIGIBLE_IDS" '
                            [ .[] | . as $movie | select(($ids | index($movie.id)) != null) ][]
                        ' <<< "$ACTION_CANDIDATES" | jq -c .
                    )
                    TAG_ACTIONS="$ELIGIBLE_COUNT"
                else
                    ensure_tag_id "$PLEX_DELETED_MOVIE_TAG" PLEX_DELETED_MOVIE_TAG_ID || {
                        ((API_FAILURES += 1))
                        log ERROR "Could not prepare '$PLEX_DELETED_MOVIE_TAG'; confirmed movies will be retried next run."
                        PLEX_DELETED_MOVIE_TAG_ID=''
                    }
                    if [[ "$PLEX_DELETED_MOVIE_TAG_ID" =~ ^[0-9]+$ ]]; then
                        PAYLOAD="$(jq -cn --argjson ids "$ELIGIBLE_IDS" --argjson tag_id "$PLEX_DELETED_MOVIE_TAG_ID" '
                            {movieIds: $ids, tags: [$tag_id], applyTags: "add"}
                        ')"
                        if api_put_json "/api/v3/movie/editor" "$PAYLOAD"; then
                            radarr_mark_tag_actions "$ELIGIBLE_IDS" ||
                                die "Could not record applied tag actions."
                            while IFS= read -r MOVIE; do
                                [[ -n "$MOVIE" ]] || continue
                                log INFO "Added '$PLEX_DELETED_MOVIE_TAG' to $(radarr_movie_name "$MOVIE")."
                                queue_action_notification Radarr \
                                    "$(radarr_movie_name "$MOVIE") tag update" \
                                    "Added tag: $PLEX_DELETED_MOVIE_TAG"
                            done < <(
                                jq -c --argjson ids "$ELIGIBLE_IDS" '
                                    [ .[] | . as $movie | select(($ids | index($movie.id)) != null) ][]
                                ' <<< "$ACTION_CANDIDATES" | jq -c .
                            )
                            TAG_ACTIONS="$ELIGIBLE_COUNT"
                        else
                            ((API_FAILURES += 1))
                            log ERROR "Bulk tag update failed; confirmed movies will be retried next run."
                            queue_attention_notification ERROR Radarr \
                                "Confirmed movie tag update failed" \
                                "$ELIGIBLE_COUNT confirmed movie(s) could not be tagged and will be retried."
                        fi
                    fi
                fi
            fi
        fi
fi

if [[ "$QUARANTINE_KODI_SIDECARS" == true ]] && (( MOVIES_CONFIRMED > 0 )); then
    while IFS= read -r MOVIE; do
        [[ -n "$MOVIE" ]] || continue
        MOVIE_ID="$(jq -r '.id' <<< "$MOVIE")"
        MOVIE_API_PATH="$(jq -r '.path // empty' <<< "$MOVIE")"
        MOVIE_PATH="$(map_arr_media_path "$MOVIE_API_PATH" "$RADARR_API_MOVIES_ROOT" "$MOVIES_ROOT" || true)"
        MOVIE_LABEL="$(radarr_movie_name "$MOVIE")"
        if [[ -z "$MOVIE_PATH" ]]; then
            ((SIDECAR_FAILURES += 1))
            log ERROR "Cannot map Radarr path '$MOVIE_API_PATH' from RADARR_API_MOVIES_ROOT to MOVIES_ROOT; sidecar cleanup for $MOVIE_LABEL was deferred."
            queue_attention_notification WARNING Radarr "$MOVIE_LABEL cleanup deferred" \
                "The Radarr media path could not be mapped safely: $MOVIE_API_PATH"
            continue
        fi
        if [[ "$(radarr_cleanup_history_eligible "$MOVIE_ID")" != true ]]; then
            log INFO "Not quarantining Kodi sidecars for $MOVIE_LABEL because required deletion History evidence is unavailable."
            continue
        fi
        MANIFEST="$(prepare_sidecar_cleanup_manifest "$MOVIE_ID" \
            "$MOVIE_PATH" "$MOVIES_ROOT" movies)" ||
            die "Could not prepare Kodi sidecar cleanup state for $MOVIE_LABEL."
        if jq -e 'type == "object" and (.cleanupAlreadyRecorded // false) == true' \
            >/dev/null 2>&1 <<< "$MANIFEST"; then
            :
        elif quarantine_recorded_sidecars radarr movies "$MOVIES_ROOT" "$MOVIE_PATH" "$MANIFEST"; then
            ((SIDECARS_QUARANTINED += CLEANUP_QUARANTINED))
            ((SIDECARS_NATIVE_MISSING += CLEANUP_NATIVE_MISSING))
            ((SIDECARS_CHANGED += CLEANUP_CHANGED))
            ((FOLDERS_REMOVED += CLEANUP_FOLDERS_REMOVED))
            queue_cleanup_action_notification Radarr "$MOVIE_LABEL" "$MOVIE_PATH"
            if [[ "$CLEANUP_COMPLETE" == true ]]; then
                queue_folder_resolution_notification Radarr "$MOVIE_ID" \
                    "$MOVIE_LABEL folder cleanup" "$MOVIE_PATH"
                radarr_mark_sidecar_cleanup "$MOVIE_ID" ||
                    die "Could not record Kodi sidecar cleanup for $MOVIE_LABEL."
            elif [[ "$CLEANUP_FOLDER_PENDING" == true ]]; then
                mark_sidecar_folder_cleanup_pending "$MOVIE_ID" "$MOVIE_PATH" \
                    "$MOVIES_ROOT" movies ||
                    die "Could not retain pending folder cleanup for $MOVIE_LABEL."
                ((FOLDER_CLEANUP_PENDING += 1))
                queue_folder_blocker_notification Radarr "$MOVIE_ID" \
                    "$MOVIE_LABEL folder cleanup pending" "$MOVIE_PATH"
            elif (( CLEANUP_CHANGED > 0 )); then
                queue_attention_notification WARNING Radarr \
                    "$MOVIE_LABEL sidecar cleanup deferred" \
                    "Preserved $CLEANUP_CHANGED changed/unsafe recorded sidecar(s). Completed: quarantined=$CLEANUP_QUARANTINED; folders removed=$CLEANUP_FOLDERS_REMOVED."$'\n'"$CLEANUP_EXCEPTION_DETAILS"
            fi
        else
            CLEANUP_RC=$?
            case "$CLEANUP_RC" in
                3) ;;
                4) ((MOVER_DEFERRALS += 1)) ;;
                *)
                    ((SIDECAR_FAILURES += 1))
                    log ERROR "Kodi sidecar quarantine failed for $MOVIE_LABEL; its manifest was retained."
                    queue_attention_notification ERROR Radarr \
                        "$MOVIE_LABEL sidecar quarantine failed" \
                        "Cleanup failed after quarantining $CLEANUP_QUARANTINED sidecar(s) and removing $CLEANUP_FOLDERS_REMOVED empty folder(s). Recovery intent and the manifest were retained; the next run will verify outcomes before retrying."$'\n'"$CLEANUP_OPERATION_DETAILS"$'\n'"$CLEANUP_EXCEPTION_DETAILS"
                    ;;
            esac
        fi
    done < <(jq -c '.[]' <<< "$CONFIRMED")
fi

radarr_process_retirements "$RADARR_ACTION_SNAPSHOT_FILE" || {
    ((API_FAILURES += 1))
    log ERROR "Radarr retirement processing failed; unfinished work will be retried."
    queue_attention_notification ERROR Radarr "Radarr retirement processing failed" \
        "No unsafe removal was attempted; unfinished retirement work will be retried next run."
}
radarr_prune_state "$CURRENT_SNAPSHOT_FILE" || die "Could not prune stale Radarr state safely."
radarr_commit_state || { [[ ! -d "${MC_TMP:-}" ]] || printf 'Radarr state commit failed\n' >>"$MC_TMP/failed-arr";die "Could not atomically save state."; }
WORK_STATE=""

MC_COMPONENT_COMPLETED=true
mc_arr_metrics || die "Cannot record Arr timing/protection outcome."
ACTION_LABEL=applied
[[ "$DRY_RUN" == true ]] && ACTION_LABEL=would-apply
log INFO "Summary: movies-listed=$MOVIES_LISTED, movies-scanned=$MOVIES_SCANNED, recovery-held=$RECOVERY_HELD_COUNT, files-present=$FILES_PRESENT, first-missing=$FIRST_MISSING, confirmed=$MOVIES_CONFIRMED, history-inspected=$HISTORY_INSPECTIONS, history-delete-events=$HISTORY_DELETE_EVENTS, history-cap-skips=$HISTORY_LIMIT_SKIPS, tag-actions-$ACTION_LABEL=$TAG_ACTIONS, retirements-started=$RETIREMENTS_STARTED, retirements-cancelled=$RETIREMENTS_CANCELLED, arr-removals=$ARR_REMOVALS, state-pruned=$STATE_PRUNED, sidecars-captured=$SIDECARS_CAPTURED, sidecars-$ACTION_LABEL=$SIDECARS_QUARANTINED, late-sidecar-candidates=$SIDECARS_LATE_CANDIDATES, late-sidecars-confirmed-$ACTION_LABEL=$SIDECARS_LATE_CONFIRMED, sidecars-native-missing=$SIDECARS_NATIVE_MISSING, sidecars-changed=$SIDECARS_CHANGED, folders-removed-$ACTION_LABEL=$FOLDERS_REMOVED, folder-cleanup-pending=$FOLDER_CLEANUP_PENDING, mover-deferrals=$MOVER_DEFERRALS, api-failures=$API_FAILURES, history-failures=$HISTORY_FAILURES, sidecar-failures=$SIDECAR_FAILURES."

if (( API_FAILURES > 0 || HISTORY_FAILURES > 0 || SIDECAR_FAILURES > 0 )); then
    FAILURE_SEVERITY=WARNING
    (( API_FAILURES > 0 || SIDECAR_FAILURES > 0 )) && FAILURE_SEVERITY=ERROR
    queue_attention_notification "$FAILURE_SEVERITY" Radarr \
        "Daily Radarr delete-sync completed with failures" \
        "API failures: $API_FAILURES; history failures: $HISTORY_FAILURES; sidecar failures: $SIDECAR_FAILURES. Completed: tags applied=$TAG_ACTIONS, sidecars quarantined=$SIDECARS_QUARANTINED, empty folders removed=$FOLDERS_REMOVED, Arr removals=$ARR_REMOVALS. Pending actions were preserved for fresh verification."
    log WARNING "Completed with API, History, or sidecar failures; safe state was saved and unfinished actions will be retried."
    exit 2
fi
log DEBUG "Completed successfully."
)

# Only per-series read-only planners use this view. Every state writer still
# updates WORK_STATE; every final API/path/hash check still reads fresh evidence.
# The RAM view is invalidated by series ID and the working file's full stat
# identity, including nanosecond modification/change times and replacement inode.
sonarr_prepare_read_state() {
    SONARR_READ_STATE="$WORK_STATE"
    local series="${SERIES_ID:-}" signature cache marker temp current=""
    [[ "$series" =~ ^[1-9][0-9]*$ && -d "${VERIFY_RUNTIME_DIR:-}" ]] || return 0
    cache="$VERIFY_RUNTIME_DIR/sonarr-planner-view.json"
    marker="$VERIFY_RUNTIME_DIR/sonarr-planner-view.identity"
    signature="$series|$(stat -c '%d:%i:%s:%y:%z' -- "$WORK_STATE")" || return 1
    [[ ! -f "$marker" ]] || current=$(cat -- "$marker") || return 1
    if [[ "$current" != "$signature" || ! -f "$cache" ]]; then
        temp=$(mktemp "$VERIFY_RUNTIME_DIR/.planner-view.XXXXXX") || return 1
        if ! jq -c --argjson series "$series" --arg key "$series" '
          .episodes |= with_entries(select(.value.seriesId==$series))
          | .sidecarManifests = {($key):.sidecarManifests[$key]}
          | .sidecarCleanupActions = {($key):.sidecarCleanupActions[$key]}
        ' "$WORK_STATE" >"$temp"; then rm -f -- "$temp"; return 1; fi
        mv -f -- "$temp" "$cache" || return 1
        printf '%s' "$signature" >"$marker" || return 1
    fi
    SONARR_READ_STATE="$cache"
}

main "$@"
mc_finish_module arr "$?" "$@"
)

# MODULE: SAB -- isolated policy, state and traps.
mc_sab() (
set -uo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

VERSION="2.8.0"

# ---------------------------------------------------------------------------
# Execution behavior
# ---------------------------------------------------------------------------

DRY_RUN="$MC_DRY_RUN"

# Each cleanup module can be disabled independently. Quarantine purge does not
# require SABnzbd or Arr API access when stranded-download cleanup is disabled.
CLEAN_BACKUPS="${CLEAN_BACKUPS:-true}"
CLEAN_STRANDED_DOWNLOADS="${CLEAN_STRANDED_DOWNLOADS:-true}"
PURGE_QUARANTINE="${PURGE_QUARANTINE:-true}"

# ---------------------------------------------------------------------------
# SABnzbd backup retention
# ---------------------------------------------------------------------------

SAB_BACKUP_DIR="${SAB_BACKUP_DIR:-/mnt/vault/backup/arr_db/sabnzbd}"
NZB_BACKUP_DIR="${NZB_BACKUP_DIR:-${SAB_BACKUP_DIR}/nzb}"

NZB_RETENTION_DAYS="${NZB_RETENTION_DAYS:-60}"
APP_BACKUP_RETENTION_DAYS="${APP_BACKUP_RETENTION_DAYS:-7}"

# A conservative grace period. Radarr/Sonarr also regard aggressive SAB
# history retention (less than 14 days) as unsafe.
MIN_COMPLETED_AGE_HOURS="${MIN_COMPLETED_AGE_HOURS:-336}"

# Special working-folder audit runs inside completed-download cleanup, using the
# same APIs, locks, quarantine limits and daily outbox. No separate schedule.
CLEAN_ORPHAN_FOLDERS="${CLEAN_ORPHAN_FOLDERS:-true}"
ORPHAN_MIN_STABLE_HOURS="${ORPHAN_MIN_STABLE_HOURS:-48}"
ORPHAN_OBSERVATION_GAP_HOURS="${ORPHAN_OBSERVATION_GAP_HOURS:-4}"
# At least two observations are mandatory even if this is configured lower.
ORPHAN_CONFIRMATION_RUNS="${ORPHAN_CONFIRMATION_RUNS:-2}"

# Even an old job is protected if anything below its path changed recently.
MIN_PATH_STABLE_HOURS="${MIN_PATH_STABLE_HOURS:-24}"

# Quarantine retention starts when this script moves the payload.
QUARANTINE_RETENTION_DAYS="${QUARANTINE_RETENTION_DAYS:-14}"

# Limit real quarantine moves per run. Zero means unlimited.
MAX_QUARANTINES_PER_RUN="${MAX_QUARANTINES_PER_RUN:-10}"
MAX_PURGES_PER_RUN="${MAX_PURGES_PER_RUN:-25}"
MAX_PURGE_FILES_PER_RUN="${MAX_PURGE_FILES_PER_RUN:-250}"
MAX_PURGE_BYTES_PER_RUN="${MAX_PURGE_BYTES_PER_RUN:-107374182400}"
PURGE_RECEIPT_RETENTION_DAYS=365
PURGE_RECEIPT_DIR="$MC_ROOT/sab/purge-receipts"

# Refuse to overlap Unraid Mover. The process pattern matches current and
# legacy Unraid mover entry points and is shared with mover_audit.sh.
MOVER_GUARD_ENABLED="${MOVER_GUARD_ENABLED:-true}"
MOVER_PROCESS_PATTERN="${MOVER_PROCESS_PATTERN:-(^|/)(mover|mover\.old)( |$)|mover\.php}"

# Send a normal Unraid notification when a scheduled cleanup is skipped because
# Mover is still active. The script exits successfully so User Scripts does not
# report the deliberate skip as a failure.
NOTIFY_MOVER_SKIP="${NOTIFY_MOVER_SKIP:-true}"

# ---------------------------------------------------------------------------
# Sonarr
# ---------------------------------------------------------------------------

SONARR_ENABLED="${SONARR_ENABLED:-true}"
SONARR_URL="$MC_SONARR_URL"
SONARR_API_KEY="$MC_SONARR_API_KEY"

# Semicolon-separated container-prefix|host-prefix mappings. The script first
# tries importedPath exactly as Arr reports it, then tries each mapping.
SONARR_IMPORT_PATH_MAPS="${SONARR_IMPORT_PATH_MAPS:-/media/series|/mnt/user/media/series;/data/media/series|/mnt/user/media/series;/tv|/mnt/user/media/series}"

# Semicolon-separated host roots. Every verified Sonarr importedPath must
# resolve below one of these roots.
SONARR_LIBRARY_ROOTS="${SONARR_LIBRARY_ROOTS:-/mnt/user/media/series}"

# ---------------------------------------------------------------------------
# Radarr
# ---------------------------------------------------------------------------

RADARR_ENABLED="${RADARR_ENABLED:-true}"
RADARR_URL="$MC_RADARR_URL"
RADARR_API_KEY="$MC_RADARR_API_KEY"

RADARR_IMPORT_PATH_MAPS="${RADARR_IMPORT_PATH_MAPS:-/media/movies|/mnt/user/media/movies;/data/media/movies|/mnt/user/media/movies;/movies|/mnt/user/media/movies}"
RADARR_LIBRARY_ROOTS="${RADARR_LIBRARY_ROOTS:-/mnt/user/media/movies}"

# ---------------------------------------------------------------------------
# SABnzbd
# ---------------------------------------------------------------------------

SAB_URL="$MC_SAB_URL"
SAB_API_KEY="$MC_SAB_API_KEY"

# Host-visible completed download layout. These defaults match the repository's
# media_health_monitor.sh configuration.
# Only the monitor-generated verified dispositions can authorize rejected-payload quarantine.
# Exact native import receipts survive history pruning and destination renames.
IMPORT_RECEIPT_FILE="${IMPORT_RECEIPT_FILE:-/mnt/vault/cloud/logs/script/media_health_monitor/import-receipts.json}"
POLICY_DISPOSITION_FILE="${POLICY_DISPOSITION_FILE:-/mnt/vault/cloud/logs/script/media_health_monitor/policy-actions.json}"

SAB_COMPLETE_ROOT="${SAB_COMPLETE_ROOT:-/mnt/user/media/net/complete}"

SAB_MOVIE_CATEGORY="${SAB_MOVIE_CATEGORY:-movie}"
SAB_MOVIE_DIR="${SAB_MOVIE_DIR:-${SAB_COMPLETE_ROOT}/movies}"

SAB_TV_CATEGORY="${SAB_TV_CATEGORY:-tv}"
SAB_TV_DIR="${SAB_TV_DIR:-${SAB_COMPLETE_ROOT}/series}"

# SAB may return its container-side path. Configure the completed root exactly
# as SAB sees it. Leave empty to disable prefix mapping; basename fallback under
# the category root remains available for ordinary completed cleanup. Orphan
# ownership never uses that fallback: set the exact container root to allow
# nonempty working-folder proof (this installation uses /data/net/complete).
SAB_CONTAINER_COMPLETE_ROOT="${SAB_CONTAINER_COMPLETE_ROOT:-/data/net/complete}"

# ---------------------------------------------------------------------------
# Quarantine, logs, notifications, and APIs
# ---------------------------------------------------------------------------

# Keep quarantine outside SAB_COMPLETE_ROOT but preferably on the same Unraid
# share/filesystem so the move is fast and recoverable.
QUARANTINE_DIR="${QUARANTINE_DIR:-/mnt/user/media/net/quarantine}"

# Normalize only QUARANTINE_DIR and its contents. Supplying an owner without a
# group deliberately preserves each entry's existing group ownership.
QUARANTINE_OWNER="${QUARANTINE_OWNER:-nobody}"
QUARANTINE_DIRECTORY_MODE="${QUARANTINE_DIRECTORY_MODE:-0755}"
QUARANTINE_FILE_MODE="${QUARANTINE_FILE_MODE:-0644}"

LOG_DIR="$MC_ROOT/sab"
LOG_FILE="$MC_ROOT/media-cleanup.log"
# Compact operational logs; full inventories remain in deletion receipts.
LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_BACKUP_FILES=2
LOG_RETENTION_DAYS=30
LOG_LINE_MAX_BYTES=4096

LOG_MAX_BYTES="${LOG_MAX_BYTES:-1048576}"
LOG_KEEP="${LOG_KEEP:-2}"

SEND_NOTIFICATIONS="${SEND_NOTIFICATIONS:-true}"
OPS_NOTIFICATION_STATE="${LOG_DIR}/notification-state.json"
NOTIFY_DRY_RUN="${NOTIFY_DRY_RUN:-false}"
NOTIFY="${MC_PROXY:-$MC_NOTIFY_BIN}"
NOTIFY_BIN="$NOTIFY"

LOCK_FILE="${LOCK_FILE:-/run/media_cleanup-sab.lock}"

SAB_HISTORY_PAGE_SIZE="${SAB_HISTORY_PAGE_SIZE:-500}"
SAB_HISTORY_MAX_PAGES="${SAB_HISTORY_MAX_PAGES:-100}"
ARR_QUEUE_PAGE_SIZE="${ARR_QUEUE_PAGE_SIZE:-10000}"
ARR_HISTORY_PAGE_SIZE="${ARR_HISTORY_PAGE_SIZE:-1000}"

CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-10}"
CURL_MAX_TIME="${CURL_MAX_TIME:-60}"
TLS_VERIFY="${TLS_VERIFY:-true}"

###############################################################################
# INTERNAL STATE
###############################################################################

START_EPOCH="$(date '+%s')"
RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
TMP_DIR=""

SAB_HISTORY_FILE=""
SAB_QUEUE_FILE=""
SONARR_QUEUE_FILE=""
RADARR_QUEUE_FILE=""

SAB_MOVIE_DIR_REAL=""
SAB_TV_DIR_REAL=""
QUARANTINE_DIR_REAL=""
SAB_BACKUP_DIR_REAL=""
NZB_BACKUP_DIR_REAL=""

BACKUP_CLEANUP_STATUS="DISABLED"
STRANDED_CLEANUP_STATUS="DISABLED"
QUARANTINE_PURGE_STATUS="DISABLED"

NZB_BACKUPS_ELIGIBLE=0
APP_BACKUPS_ELIGIBLE=0
NZB_BACKUPS_REMOVED=0
APP_BACKUPS_REMOVED=0
NZB_BACKUP_BYTES=0
APP_BACKUP_BYTES=0

SCANNED=0
COMPLETED_SCANNED=0
TOO_YOUNG=0
QUEUE_PROTECTED=0
PATH_MISSING=0
PATH_UNSTABLE=0
HISTORY_UNPROVEN=0
DESTINATION_UNVERIFIED=0
SOURCE_UNACCOUNTED=0
SAFETY_SKIPPED=0
MOVER_PROTECTED=0
ELIGIBLE=0
QUARANTINED=0
SAB_PURGED_FILES=0;SAB_PARTIAL_PURGES=0;SAB_PURGE_REMAINING=0;SAB_EXPIRED_WRAPPERS=0;SAB_OLDEST_EXPIRED_EPOCH=0
PURGED=0
ERRORS=0
BYTES_ELIGIBLE=0
BYTES_QUARANTINED=0
BYTES_PURGED=0

BACKUP_DETAILS=()
QUARANTINE_DETAILS=()
ORPHANS_SCANNED=0
ORPHANS_PROTECTED=0
ORPHANS_WAITING=0
ORPHANS_UNVERIFIED=0
ORPHANS_QUARANTINED=0
PURGE_DETAILS=()

RECOVERED=0
NOTIFICATION_FINALIZED=false
RUN_INITIALIZED=false
RECOVERY_DETAILS=()
MOVER_GUARD_TRIGGERED=false
MOVER_GUARD_CONTEXT=""

###############################################################################
# GENERAL HELPERS
###############################################################################

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

is_true() {
  case "${1:-}" in
    1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]) return 0 ;;
    *) return 1 ;;
  esac
}

is_false() {
  case "${1:-}" in
    0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) return 0 ;;
    *) return 1 ;;
  esac
}

OPS_SCRIPT_NAME="arr_sabnzbd_cleanup"
OPS_SCRIPT_VERSION="2.8.0"
OPS_RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
OPS_ATTENTION_DETAILS=""
OPS_ATTENTION_FILE=""
OPS_LOG_BYTES=""

# Shared operational logging convention, embedded to keep User Scripts standalone.
# INFO records actions, warnings and one completion summary. DEBUG adds routine
# progress. Numbered backups expire by size, count and age; receipts are separate.



# Durable daily outbox. Unsent chunks survive failures, daily limits and caps.
# Flush only destructive-operation checkpoints and their receipts, never every
# log line. Flush the containing directory after atomic replacement too.








# Unfinished purge/restore operations outlive processes and daily log rotation.



ops_operation_begin() {
    local kind="$1" source="$2" destination="$3" proof="$4" identity="" id tmp
    mc_work_allowed sab || return 75
    ops_operation_state || return 1
    ops_operation_paths_valid "$source" "$destination" || { ops_log ERROR "Unsafe operation paths; checkpoint and mutation refused: $source -> $destination"; return 1; }
    id=$(printf '%s' "$kind|$source|$destination" | sha256sum | cut -d ' ' -f1)
    if jq -e --arg id "$id" '.operations[$id]!=null' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null; then
        # A partial purge resumes only after the caller's normal retention,
        # inventory, Mover and byte-limit checks. Its original evidence stays.
        [[ "$kind" == purge || "$kind" == purge-file ]] || { ops_log ERROR "Restore already pending; reconciliation required ($id)."; return 1; }
        printf '%s' "$id"; return 0
    fi
    [[ -f "$proof" ]] || return 1
    ops_flush_file "$proof" || return 1
    ops_flush_directory "$(dirname -- "$proof")" || return 1
    if [[ "$kind" == purge-file ]];then identity=$(stat -c '%d:%i:%f:%s:%y:%z' -- "$source") || return 1;fi
    if [[ "$kind" == restore ]]; then identity=$(stat -c '%d:%i:%F:%s' -- "$source") || return 1; fi
    tmp=$(mktemp "$LOG_DIR/.operation-intent.XXXXXX") || return 1
    jq --arg id "$id" --arg kind "$kind" --arg source "$source" --arg destination "$destination" \
      --arg proof "$proof" --arg identity "$identity" --argjson now "$(date +%s)" \
      '.operations[$id]={kind:$kind,source:$source,destination:$destination,proof:$proof,identity:$identity,startedAt:$now}' \
      "$OPS_PENDING_OPERATIONS_FILE" >"$tmp" && ops_publish_checkpoint "$tmp" "$OPS_PENDING_OPERATIONS_FILE" || return 1
    printf '%s' "$id"
}



ops_recover_operations() {
    local list entry id kind source destination identity actual failed=0
    OPS_RECOVERY_DETAILS=""; OPS_RECOVERED_COUNT=0
    ops_operation_state || return 1
    list=$(mktemp "$LOG_DIR/.operation-recovery.XXXXXX") || return 1
    jq -c '.operations|to_entries[]' "$OPS_PENDING_OPERATIONS_FILE" >"$list" || return 1
    while IFS= read -r entry; do
        id=$(jq -r '.key' <<<"$entry"); kind=$(jq -r '.value.kind' <<<"$entry")
        source=$(jq -r '.value.source' <<<"$entry"); destination=$(jq -r '.value.destination' <<<"$entry")
        ops_operation_paths_valid "$source" "$destination" || { ops_log ERROR "Unsafe pending operation preserved: $id"; failed=$((failed+1)); continue; }
        if [[ "$kind" == purge-file && -z "$destination" ]];then
            identity=$(jq -r '.value.identity // ""' <<<"$entry")
            if [[ ! -e "$source" && ! -L "$source" ]];then
                ops_operation_finish "$id" 'Reconciled interrupted file purge: absence verified; no new deletion' || return 1
                OPS_RECOVERED_COUNT=$((OPS_RECOVERED_COUNT+1));OPS_RECOVERY_DETAILS+="- Reconciled interrupted file purge: $source is absent; no repeat unlink."$'\n'
            elif [[ -f "$source" && ! -L "$source" && -n "$identity" && "$(stat -c '%d:%i:%f:%s:%y:%z' -- "$source")" == "$identity" ]];then
                ops_log WARNING "Interrupted file purge retained for fresh retention, Mover and budget checks: $source"
            else ops_log ERROR "Interrupted file identity changed; preserved: $source";failed=$((failed+1));fi
        elif [[ "$kind" == purge && -z "$destination" ]]; then
            if [[ ! -e "$source" && ! -L "$source" ]]; then
                ops_operation_finish "$id" "Reconciled interrupted purge: directory absence confirmed; no new deletion performed" || return 1
                OPS_RECOVERY_DETAILS+="- Reconciled interrupted purge: $source is absent. No new deletion was needed. Operation $id."$'\n'
                OPS_RECOVERED_COUNT=$((OPS_RECOVERED_COUNT+1))
            elif [[ -d "$source" && ! -L "$source" ]]; then
                check_mover_guard 'before reconciling an empty purged wrapper' || { failed=$((failed+1));continue; }
                if rmdir -- "$source" 2>/dev/null;then
                    ops_flush_directory "${source%/*}" || return 1
                    ops_operation_finish "$id" 'Interrupted purge reconciled: remaining empty wrapper removed; no files deleted' || return 1
                    OPS_RECOVERED_COUNT=$((OPS_RECOVERED_COUNT+1));OPS_RECOVERY_DETAILS+="- Removed interrupted empty purge wrapper: $source; no payload files deleted."$'\n'
                    continue
                fi
                ops_log WARNING "Incomplete purge preserved: $source; remaining files will be retried only after normal retention, idle, Mover and execution-limit checks. Operation $id."
            else
                ops_log ERROR "Interrupted purge source changed type; preserved for review: $source (operation $id)"; failed=$((failed+1))
            fi
        elif [[ "$kind" == restore && -n "$destination" ]]; then
            if [[ ! -e "$source" && ! -L "$source" && -e "$destination" && ! -L "$destination" ]]; then
                identity=$(jq -r '.value.identity' <<<"$entry")
                actual=$(stat -c '%d:%i:%F:%s' -- "$destination") || actual=""
                if [[ -n "$identity" && "$actual" == "$identity" ]]; then
                    ops_operation_finish "$id" "Reconciled interrupted restore: original object identity verified at destination" || return 1
                    OPS_RECOVERY_DETAILS+="- Recovered interrupted restore: $source -> $destination. Original object identity matched; no overwrite or repeat move performed."$'\n'
                    OPS_RECOVERED_COUNT=$((OPS_RECOVERED_COUNT+1))
                else
                    ops_log ERROR "Restore destination exists but identity cannot be proven (possible cross-filesystem copy); destination preserved: $destination. Review operation $id with --pending-operations; use --resolve-operation only after verification."
                    failed=$((failed+1))
                fi
            elif [[ -e "$source" && ! -e "$destination" && ! -L "$destination" ]]; then
                ops_operation_finish "$id" "Interrupted restore was not applied; original source preserved for explicit retry" || return 1
                OPS_RECOVERY_DETAILS+="- Restore did not occur: $source remains quarantined; $destination was not created. An explicit restore may be retried."$'\n'
                OPS_RECOVERED_COUNT=$((OPS_RECOVERED_COUNT+1))
            else
                ops_log ERROR "Ambiguous interrupted restore: source=$source; destination=$destination. Both locations preserved; operation=$id."
                failed=$((failed+1))
            fi
        else ops_log ERROR "Unknown checkpoint type preserved for review: $id"; failed=$((failed+1)); fi
    done <"$list"
    rm -f -- "$list"
    # Keep the small recovery audit for one year, independently of main logs.
    if [[ -s "$OPS_OPERATION_AUDIT_FILE" ]]; then
        local retained
        retained=$(mktemp "$LOG_DIR/.operation-audit.XXXXXX") || return 1
        jq -c --argjson cutoff "$(( $(date +%s)-365*86400 ))" 'select(.at >= $cutoff)' "$OPS_OPERATION_AUDIT_FILE" >"$retained" &&
          ops_publish_checkpoint "$retained" "$OPS_OPERATION_AUDIT_FILE" || return 1
    fi
    ((failed==0))
}



die() {
  ((ERRORS++)) || true
  log "ERROR" "$*"
  exit 1
}

runtime() {
  local seconds=$(( $(date '+%s') - START_EPOCH ))
  printf '%dh:%dm:%ds' \
    $((seconds / 3600)) \
    $(((seconds % 3600) / 60)) \
    $((seconds % 60))
}

bytes_human() {
  local bytes="${1:-0}"

  awk -v b="$bytes" '
    BEGIN {
      if (b >= 1099511627776) printf "%.2f TB", b / 1099511627776
      else if (b >= 1073741824) printf "%.2f GB", b / 1073741824
      else if (b >= 1048576) printf "%.2f MB", b / 1048576
      else if (b >= 1024) printf "%.2f KB", b / 1024
      else printf "%d B", b
    }
  '
}

stat_size() {
  stat -c '%s' -- "$1" 2>/dev/null || stat -f '%z' -- "$1" 2>/dev/null || printf '0'
}

stat_mtime() {
  stat -c '%Y' -- "$1" 2>/dev/null || stat -f '%m' -- "$1" 2>/dev/null || printf '0'
}

stat_device() {
  stat -c '%d' -- "$1" 2>/dev/null || stat -f '%d' -- "$1" 2>/dev/null || printf ''
}

sanitize_component() {
  printf '%s' "$1" |
    tr '/\n\r\t' '____' |
    sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^[_ .-]+//; s/[_ .-]+$//' |
    cut -c 1-120
}

cleanup_tmp() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}

on_exit() {
  local exit_code=$?
  if [[ "$RUN_INITIALIZED" == true && "$NOTIFICATION_FINALIZED" != true ]]; then
    if (( exit_code!=0 )); then ((ERRORS++)) || true; fi
    notify_summary || exit_code=1
  fi
  if [[ "$RUN_INITIALIZED" == true ]] && is_true "$SEND_NOTIFICATIONS"; then ops_flush_notifications || exit_code=1; fi
  cleanup_tmp
  trap - EXIT
  exit "$exit_code"
}

trap on_exit EXIT
trap 'exit 130' INT TERM

###############################################################################
# COMMAND-LINE OVERRIDES
###############################################################################

usage() {
  cat <<'EOF'
Usage: /bin/bash SCRIPT sab [options]

Options:
  --dry-run     Report all eligible cleanup without changing anything.
  --execute     Enable backup deletion and quarantine operations.
  --purge       Enable delayed quarantine purge.
  --no-purge    Disable delayed quarantine purge.
  --inspect     List quarantine payloads, original paths, state and retention age; change nothing.
  --recover-orphan NAME Retry one exact native SAB orphan; requires --execute to submit.
                        Reuses retained data; never deletes an incomplete folder.
  --restore WRAPPER Restore one manifest-backed payload to its original path; never overwrite.
  --pending-operations List unfinished purge/restore checkpoints.
  --resolve-operation ID "verified outcome" Record an operator resolution; change no payload.
  --version     Print release version.
  --help        Show this help.

Normal scheduled invocation uses configuration above. Notifications include actions,
protected items and failures, grouped through a durable once-daily outbox.
Examples: /bin/bash SCRIPT --dry-run --no-purge
          /bin/bash SCRIPT --inspect
          /bin/bash SCRIPT --restore /mnt/user/media/net/quarantine/items/Sonarr/WRAPPER
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --dry-run) DRY_RUN=true; CLI_EXECUTE=false ;;
      --execute) DRY_RUN=false; CLI_EXECUTE=true ;;
      --purge) PURGE_QUARANTINE=true ;;
      --no-purge) PURGE_QUARANTINE=false ;;
      --pending-operations) CLI_OPERATION=pending ;;
      --resolve-operation) [[ $# -ge 3 ]] || { usage >&2; exit 2; }; CLI_OPERATION=resolve; CLI_OPERATION_ID="$2"; CLI_OPERATION_NOTE="$3"; shift 2 ;;
      --inspect) CLI_OPERATION=inspect ;;
      --recover-orphan) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; CLI_OPERATION=recover-orphan; CLI_WRAPPER="$2"; shift ;;
      --restore) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; CLI_OPERATION=restore; CLI_WRAPPER="$2"; shift ;;
      --version) printf 'sabnzbd_cleanup.sh %s\n' "$VERSION"; exit 0 ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
  done
}

###############################################################################
# INITIALIZATION / VALIDATION
###############################################################################

rotate_logs() {
    ops_initialize_log
}

require_commands() {
  local command_name
  local missing=0

  for command_name in awk basename cat chown chmod curl cut date dirname find flock jq mkdir mktemp mv realpath rm rmdir sed sort stat sha256sum tee tr wc sync; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      log "ERROR" "Required command not found: $command_name"
      missing=1
    fi
  done

  if is_true "$MOVER_GUARD_ENABLED" && ! command -v pgrep >/dev/null 2>&1; then
    log "ERROR" "Required Mover guard command not found: pgrep"
    missing=1
  fi

  (( missing == 0 )) || die "One or more required commands are unavailable."
}

validate_boolean() {
  local name="$1"
  local value="$2"
  if ! is_true "$value" && ! is_false "$value"; then
    ((ERRORS++)) || true
    log "ERROR" "$name must be true/false, yes/no, on/off, or 1/0."
    return 1
  fi
}

validate_integer() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    ((ERRORS++)) || true
    log "ERROR" "$name must be a non-negative integer."
    return 1
  fi
}

validate_api_key() {
  local app="$1"
  local key="$2"

  if [[ -z "$key" ]]; then
    ((ERRORS++)) || true
    log "ERROR" "$app API key is empty."
    return 1
  fi

  if [[ "$key" == PUT_YOUR_* ]]; then
    ((ERRORS++)) || true
    log "ERROR" "$app API key still contains its placeholder value."
    return 1
  fi
}

validate_library_roots() {
  local app="$1"
  local roots="$2"
  local root_list=()
  local root
  local valid=0
  local invalid=0

  IFS=';' read -r -a root_list <<<"$roots"

  for root in "${root_list[@]}"; do
    [[ -n "$root" ]] || continue

    if [[ -d "$root" ]]; then
      root="$(realpath -- "$root")" || continue
      if dangerously_broad_path "$root"; then
        ((ERRORS++)) || true
        log "ERROR" "$app library root is dangerously broad: $root"
        invalid=1
        continue
      fi
      ((valid++)) || true
    else
      log "WARNING" "$app library root does not exist and cannot verify imports: $root"
    fi
  done

  if (( valid == 0 )); then
    ((ERRORS++)) || true
    log "ERROR" "$app has no accessible library root for import verification."
    invalid=1
  fi

  (( invalid == 0 ))
}

dangerously_broad_path() {
  case "$1" in
    /|/mnt|/mnt/user|/mnt/user/media) return 0 ;;
  esac

  [[ "$1" =~ ^/mnt/[^/]+$ ]]
}

canonicalize_target() {
  local target="$1"
  local cursor="$target"
  local suffix=""
  local component
  local parent
  local resolved

  while [[ ! -e "$cursor" ]]; do
    component="$(basename -- "$cursor")"
    parent="$(dirname -- "$cursor")"

    [[ "$parent" != "$cursor" ]] || return 1
    suffix="/${component}${suffix}"
    cursor="$parent"
  done

  resolved="$(realpath -- "$cursor")" || return 1
  printf '%s%s' "$resolved" "$suffix"
}

path_is_below() {
  local child="$1"
  local root="$2"
  [[ "$child" == "$root"/* && "$child" != "$root" ]]
}

normalize_quarantine_permissions() {
  local target="$1"
  local target_real
  local failed=false

  target_real="$(realpath -- "$target")" || {
    log "ERROR" "Unable to resolve quarantine permission target: $target"
    return 1
  }

  if [[ "$target_real" != "$QUARANTINE_DIR_REAL" ]] && \
     ! path_is_below "$target_real" "$QUARANTINE_DIR_REAL"; then
    log "ERROR" "Refusing to change ownership or permissions outside quarantine: $target_real"
    return 1
  fi

  # find does not follow symlinks by default. chown -h changes a symlink's own
  # owner, while chmod is limited to real directories and regular files.
  if ! find "$target_real" -xdev ! -user "$QUARANTINE_OWNER" -exec chown -h -- "$QUARANTINE_OWNER" {} +; then
    log "ERROR" "Unable to set quarantine owner '$QUARANTINE_OWNER': $target_real"
    failed=true
  fi

  if ! find "$target_real" -xdev -type d ! -perm "$QUARANTINE_DIRECTORY_MODE" -exec chmod -- "$QUARANTINE_DIRECTORY_MODE" {} +; then
    log "ERROR" "Unable to set quarantine directory mode $QUARANTINE_DIRECTORY_MODE: $target_real"
    failed=true
  fi

  if ! find "$target_real" -xdev -type f ! -perm "$QUARANTINE_FILE_MODE" -exec chmod -- "$QUARANTINE_FILE_MODE" {} +; then
    log "ERROR" "Unable to set quarantine file mode $QUARANTINE_FILE_MODE: $target_real"
    failed=true
  fi

  ! is_true "$failed"
}

paths_overlap() {
  local first="$1"
  local second="$2"

  [[ "$first" == "$second" || "$first" == "$second"/* || "$second" == "$first"/* ]]
}

validate_common_environment() {
  local valid=true

  validate_boolean "DRY_RUN" "$DRY_RUN" || valid=false
  validate_boolean "CLEAN_BACKUPS" "$CLEAN_BACKUPS" || valid=false
  validate_boolean "CLEAN_STRANDED_DOWNLOADS" "$CLEAN_STRANDED_DOWNLOADS" || valid=false
  validate_boolean "CLEAN_ORPHAN_FOLDERS" "$CLEAN_ORPHAN_FOLDERS" || valid=false
  validate_integer "ORPHAN_MIN_STABLE_HOURS" "$ORPHAN_MIN_STABLE_HOURS" || valid=false
  validate_integer "ORPHAN_OBSERVATION_GAP_HOURS" "$ORPHAN_OBSERVATION_GAP_HOURS" || valid=false
  validate_integer "ORPHAN_CONFIRMATION_RUNS" "$ORPHAN_CONFIRMATION_RUNS" || valid=false
  validate_boolean "PURGE_QUARANTINE" "$PURGE_QUARANTINE" || valid=false
  validate_boolean "MOVER_GUARD_ENABLED" "$MOVER_GUARD_ENABLED" || valid=false
  validate_boolean "NOTIFY_MOVER_SKIP" "$NOTIFY_MOVER_SKIP" || valid=false
  validate_boolean "SEND_NOTIFICATIONS" "$SEND_NOTIFICATIONS" || valid=false
  validate_boolean "NOTIFY_DRY_RUN" "$NOTIFY_DRY_RUN" || valid=false
  validate_boolean "TLS_VERIFY" "$TLS_VERIFY" || valid=false
  validate_integer "LOG_MAX_BYTES" "$LOG_MAX_BYTES" || valid=false
  validate_integer "LOG_KEEP" "$LOG_KEEP" || valid=false
  validate_integer "MAX_PURGES_PER_RUN" "$MAX_PURGES_PER_RUN" || valid=false
  validate_integer "MAX_PURGE_BYTES_PER_RUN" "$MAX_PURGE_BYTES_PER_RUN" || valid=false
  validate_integer "MAX_PURGE_FILES_PER_RUN" "$MAX_PURGE_FILES_PER_RUN" || valid=false
  [[ "$MAX_PURGE_FILES_PER_RUN" =~ ^[1-9][0-9]*$ ]] || { log ERROR "MAX_PURGE_FILES_PER_RUN must be positive";valid=false; }
  validate_integer "CURL_CONNECT_TIMEOUT" "$CURL_CONNECT_TIMEOUT" || valid=false
  validate_integer "CURL_MAX_TIME" "$CURL_MAX_TIME" || valid=false

  if ! is_true "$CLEAN_BACKUPS" &&
     ! is_true "$CLEAN_STRANDED_DOWNLOADS" &&
     ! is_true "$PURGE_QUARANTINE"
  then
    ((ERRORS++)) || true
    log "ERROR" "At least one cleanup module must be enabled."
    valid=false
  fi

  if is_true "$MOVER_GUARD_ENABLED" && [[ -z "$MOVER_PROCESS_PATTERN" ]]; then
    ((ERRORS++)) || true
    log "ERROR" "MOVER_PROCESS_PATTERN cannot be empty while the Mover guard is enabled."
    valid=false
  fi

  is_true "$valid"
}

validate_backup_environment() {
  local valid=true

  validate_integer "NZB_RETENTION_DAYS" "$NZB_RETENTION_DAYS" || valid=false
  validate_integer "APP_BACKUP_RETENTION_DAYS" "$APP_BACKUP_RETENTION_DAYS" || valid=false

  if [[ ! -d "$SAB_BACKUP_DIR" ]]; then
    ((ERRORS++)) || true
    log "ERROR" "SABnzbd backup directory does not exist: $SAB_BACKUP_DIR"
    return 1
  fi

  SAB_BACKUP_DIR_REAL="$(realpath -- "$SAB_BACKUP_DIR")" || {
    ((ERRORS++)) || true
    log "ERROR" "Unable to resolve SABnzbd backup directory: $SAB_BACKUP_DIR"
    return 1
  }

  if dangerously_broad_path "$SAB_BACKUP_DIR_REAL"; then
    ((ERRORS++)) || true
    log "ERROR" "SABnzbd backup directory is dangerously broad: $SAB_BACKUP_DIR_REAL"
    valid=false
  fi

  if [[ -d "$NZB_BACKUP_DIR" ]]; then
    NZB_BACKUP_DIR_REAL="$(realpath -- "$NZB_BACKUP_DIR")" || {
      ((ERRORS++)) || true
      log "ERROR" "Unable to resolve NZB backup directory: $NZB_BACKUP_DIR"
      return 1
    }

    if ! path_is_below "$NZB_BACKUP_DIR_REAL" "$SAB_BACKUP_DIR_REAL"; then
      ((ERRORS++)) || true
      log "ERROR" "NZB backup directory must be below SAB_BACKUP_DIR: $NZB_BACKUP_DIR_REAL"
      valid=false
    fi
  else
    NZB_BACKUP_DIR_REAL=""
    log "WARNING" "NZB backup directory is unavailable; NZB retention will be skipped: $NZB_BACKUP_DIR"
  fi

  is_true "$valid"
}

prepare_quarantine_environment() {
  validate_integer "QUARANTINE_RETENTION_DAYS" "$QUARANTINE_RETENTION_DAYS" || return 1

  if [[ -z "$QUARANTINE_OWNER" || "$QUARANTINE_OWNER" == *:* ]]; then
    ((ERRORS++)) || true
    log "ERROR" "QUARANTINE_OWNER must name one owner without a group."
    return 1
  fi

  if ! [[ "$QUARANTINE_DIRECTORY_MODE" =~ ^0?[0-7]{3}$ ]]; then
    ((ERRORS++)) || true
    log "ERROR" "QUARANTINE_DIRECTORY_MODE must be a three- or four-digit octal mode."
    return 1
  fi

  if ! [[ "$QUARANTINE_FILE_MODE" =~ ^0?[0-7]{3}$ ]]; then
    ((ERRORS++)) || true
    log "ERROR" "QUARANTINE_FILE_MODE must be a three- or four-digit octal mode."
    return 1
  fi

  QUARANTINE_DIR_REAL="$(canonicalize_target "$QUARANTINE_DIR")" || {
    ((ERRORS++)) || true
    log "ERROR" "Unable to resolve quarantine target: $QUARANTINE_DIR"
    return 1
  }

  if dangerously_broad_path "$QUARANTINE_DIR_REAL"; then
    ((ERRORS++)) || true
    log "ERROR" "Quarantine directory is dangerously broad: $QUARANTINE_DIR_REAL"
    return 1
  fi

  if ! is_true "$DRY_RUN"; then
    if ! mkdir -p -- "$QUARANTINE_DIR_REAL/items/Sonarr" "$QUARANTINE_DIR_REAL/items/Radarr"; then
      ((ERRORS++)) || true
      log "ERROR" "Unable to create quarantine directories."
      return 1
    fi

    QUARANTINE_DIR_REAL="$(realpath -- "$QUARANTINE_DIR_REAL")" || {
      ((ERRORS++)) || true
      log "ERROR" "Unable to resolve created quarantine directory."
      return 1
    }

    if ! normalize_quarantine_permissions "$QUARANTINE_DIR_REAL"; then
      ((ERRORS++)) || true
      return 1
    fi
  fi
}

validate_stranded_environment() {
  local valid=true

  validate_boolean "SONARR_ENABLED" "$SONARR_ENABLED" || valid=false
  validate_boolean "RADARR_ENABLED" "$RADARR_ENABLED" || valid=false
  validate_integer "MIN_COMPLETED_AGE_HOURS" "$MIN_COMPLETED_AGE_HOURS" || valid=false
  validate_integer "MIN_PATH_STABLE_HOURS" "$MIN_PATH_STABLE_HOURS" || valid=false
  validate_integer "MAX_QUARANTINES_PER_RUN" "$MAX_QUARANTINES_PER_RUN" || valid=false
  validate_integer "SAB_HISTORY_PAGE_SIZE" "$SAB_HISTORY_PAGE_SIZE" || valid=false
  validate_integer "SAB_HISTORY_MAX_PAGES" "$SAB_HISTORY_MAX_PAGES" || valid=false
  validate_integer "ARR_QUEUE_PAGE_SIZE" "$ARR_QUEUE_PAGE_SIZE" || valid=false
  validate_integer "ARR_HISTORY_PAGE_SIZE" "$ARR_HISTORY_PAGE_SIZE" || valid=false

  if [[ "$SAB_HISTORY_PAGE_SIZE" =~ ^[0-9]+$ ]] && (( SAB_HISTORY_PAGE_SIZE == 0 )); then
    ((ERRORS++)) || true
    log "ERROR" "SAB_HISTORY_PAGE_SIZE must be greater than zero."
    valid=false
  fi
  if [[ "$SAB_HISTORY_MAX_PAGES" =~ ^[0-9]+$ ]] && (( SAB_HISTORY_MAX_PAGES == 0 )); then
    ((ERRORS++)) || true
    log "ERROR" "SAB_HISTORY_MAX_PAGES must be greater than zero."
    valid=false
  fi
  if [[ "$ARR_QUEUE_PAGE_SIZE" =~ ^[0-9]+$ ]] && (( ARR_QUEUE_PAGE_SIZE == 0 )); then
    ((ERRORS++)) || true
    log "ERROR" "ARR_QUEUE_PAGE_SIZE must be greater than zero."
    valid=false
  fi
  if [[ "$ARR_HISTORY_PAGE_SIZE" =~ ^[0-9]+$ ]] && (( ARR_HISTORY_PAGE_SIZE == 0 )); then
    ((ERRORS++)) || true
    log "ERROR" "ARR_HISTORY_PAGE_SIZE must be greater than zero."
    valid=false
  fi

  if is_true "$CLEAN_ORPHAN_FOLDERS" &&
     { ((ORPHAN_MIN_STABLE_HOURS<48)) || ((ORPHAN_OBSERVATION_GAP_HOURS<4)); }; then
    log ERROR 'Orphan cleanup requires at least a 48-hour hold and four-hour observation gap.'
    valid=false
  fi
  validate_api_key "SABnzbd" "$SAB_API_KEY" || valid=false

  if is_true "$SONARR_ENABLED"; then
    validate_api_key "Sonarr" "$SONARR_API_KEY" || valid=false
    validate_library_roots "Sonarr" "$SONARR_LIBRARY_ROOTS" || valid=false
  fi

  if is_true "$RADARR_ENABLED"; then
    validate_api_key "Radarr" "$RADARR_API_KEY" || valid=false
    validate_library_roots "Radarr" "$RADARR_LIBRARY_ROOTS" || valid=false
  fi

  if [[ ! -d "$SAB_MOVIE_DIR" ]]; then
    ((ERRORS++)) || true
    log "ERROR" "SAB movie directory does not exist: $SAB_MOVIE_DIR"
    valid=false
  else
    SAB_MOVIE_DIR_REAL="$(realpath -- "$SAB_MOVIE_DIR")" || valid=false
  fi

  if [[ ! -d "$SAB_TV_DIR" ]]; then
    ((ERRORS++)) || true
    log "ERROR" "SAB TV directory does not exist: $SAB_TV_DIR"
    valid=false
  else
    SAB_TV_DIR_REAL="$(realpath -- "$SAB_TV_DIR")" || valid=false
  fi

  if [[ -n "$SAB_MOVIE_DIR_REAL" ]] && dangerously_broad_path "$SAB_MOVIE_DIR_REAL"; then
    ((ERRORS++)) || true
    log "ERROR" "SAB movie directory is dangerously broad: $SAB_MOVIE_DIR_REAL"
    valid=false
  fi
  if [[ -n "$SAB_TV_DIR_REAL" ]] && dangerously_broad_path "$SAB_TV_DIR_REAL"; then
    ((ERRORS++)) || true
    log "ERROR" "SAB TV directory is dangerously broad: $SAB_TV_DIR_REAL"
    valid=false
  fi

  if [[ -n "$SAB_MOVIE_DIR_REAL" && -n "$SAB_TV_DIR_REAL" ]] && paths_overlap "$SAB_MOVIE_DIR_REAL" "$SAB_TV_DIR_REAL"; then
    ((ERRORS++)) || true
    log "ERROR" "SAB movie and TV roots must not overlap."
    valid=false
  fi
  if [[ -n "$QUARANTINE_DIR_REAL" && -n "$SAB_MOVIE_DIR_REAL" ]] && paths_overlap "$QUARANTINE_DIR_REAL" "$SAB_MOVIE_DIR_REAL"; then
    ((ERRORS++)) || true
    log "ERROR" "Quarantine and SAB movie roots must not overlap."
    valid=false
  fi
  if [[ -n "$QUARANTINE_DIR_REAL" && -n "$SAB_TV_DIR_REAL" ]] && paths_overlap "$QUARANTINE_DIR_REAL" "$SAB_TV_DIR_REAL"; then
    ((ERRORS++)) || true
    log "ERROR" "Quarantine and SAB TV roots must not overlap."
    valid=false
  fi

  if [[ "${SAB_MOVIE_CATEGORY,,}" == "${SAB_TV_CATEGORY,,}" ]]; then
    ((ERRORS++)) || true
    log "ERROR" "SAB movie and TV categories must be different."
    valid=false
  fi

  is_true "$valid"
}

initialize() {
  # Never create a shadow log/outbox tree on Unraid's root filesystem if the
  # share/pool disappeared. A RAM marker bounds the exceptional direct alert.
  local required_log_mount="" storage_marker="/tmp/arr-sab-cleanup-storage-$(date +%F).notified" storage_reason
  case "$LOG_DIR" in /mnt/user/*) required_log_mount=/mnt/user;; /mnt/vault/*) required_log_mount=/mnt/vault;; esac
  if [[ -n "$required_log_mount" ]] && ! mountpoint -q "$required_log_mount"; then
    storage_reason="Required log storage $required_log_mount is unavailable. No backup deletions, quarantine moves, purges or restores were attempted."
    printf '%s\n' "$storage_reason" >&2
    if [[ ! -e "$storage_marker" && -x "$NOTIFY" ]] && is_true "$SEND_NOTIFICATIONS"; then
      if usr_ops_notify "$NOTIFY" -i alert -s "SABnzbd Cleanup" -d "Storage preflight failed" -m "$storage_reason" >/dev/null 2>&1; then : >"$storage_marker"; fi
    fi
    return 1
  fi
  mkdir -p -- "$LOG_DIR" || {
    printf 'Unable to create log directory: %s\n' "$LOG_DIR" >&2
    exit 1
  }

  require_commands

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "INFO" "Another SABnzbd cleanup run is active; exiting."
    exit 0
  fi

  RUN_INITIALIZED=true
  rotate_logs || die "Persistent logging initialization failed."
  ops_notification_state || die "Invalid notification state; existing outbox was preserved."
  TMP_DIR="$(mktemp -d '/tmp/sabnzbd_cleanup.XXXXXX')" || \
    die "Unable to create temporary directory."

  OPS_ATTENTION_FILE="$TMP_DIR/attention-details.txt"
  : >"$OPS_ATTENTION_FILE"
  SAB_HISTORY_FILE="$TMP_DIR/sab_history.json"
  SAB_QUEUE_FILE="$TMP_DIR/sab_queue.json"
  SONARR_QUEUE_FILE="$TMP_DIR/sonarr_queue.json"
  RADARR_QUEUE_FILE="$TMP_DIR/radarr_queue.json"

  if ! validate_common_environment; then
    die "Common configuration validation failed."
  fi
}

###############################################################################
# UNRAID MOVER GUARD
###############################################################################

mover_is_running() {
  is_true "$MOVER_GUARD_ENABLED" || return 1
  pgrep -f "$MOVER_PROCESS_PATTERN" >/dev/null 2>&1
}

notify_mover_skip() {
  # The finalizer includes the guard context and completed actions in the same
  # durable daily report; never send a second standalone Mover email.
  return 0
}

check_mover_guard() {
  mc_work_allowed sab || return 21
  local context="$1"

  mover_is_running || return 0

  MOVER_GUARD_TRIGGERED=true
  MOVER_GUARD_CONTEXT="$context"
  ((MOVER_PROTECTED++)) || true

  log "WARNING" "Unraid Mover is running at guard point '$context'."
  log "WARNING" "Stopping cleanup successfully; no further cleanup writes will be attempted."
  notify_mover_skip "$context"

  return 20
}

###############################################################################
# BACKUP RETENTION
###############################################################################

find_backup_candidates() {
  local backup_kind="$1"

  case "$backup_kind" in
    nzb)
      [[ -n "$NZB_BACKUP_DIR_REAL" ]] || return 0
      find "$NZB_BACKUP_DIR_REAL" \
        -type f \
        \( -iname '*.nzb' -o -iname '*.nzb.gz' \) \
        -mmin "+$((NZB_RETENTION_DAYS * 1440))" \
        -print0
      ;;
    application)
      find "$SAB_BACKUP_DIR_REAL" \
        -maxdepth 1 \
        -type f \
        -iname '*.zip' \
        -mmin "+$((APP_BACKUP_RETENTION_DAYS * 1440))" \
        -print0
      ;;
    *)
      return 2
      ;;
  esac
}

backup_candidate_is_contained() {
  local backup_kind="$1"
  local file="$2"
  local file_real
  local expected_root

  file_real="$(realpath -- "$file" 2>/dev/null)" || return 1

  case "$backup_kind" in
    nzb) expected_root="$NZB_BACKUP_DIR_REAL" ;;
    application) expected_root="$SAB_BACKUP_DIR_REAL" ;;
    *) return 1 ;;
  esac

  path_is_below "$file_real" "$expected_root"
}

process_backup_candidate() {
  local backup_kind="$1"
  local file="$2"
  local label
  local size
  local guard_status

  case "$backup_kind" in
    nzb) label="NZB backup" ;;
    application) label="application backup" ;;
    *) return 2 ;;
  esac

  if ! backup_candidate_is_contained "$backup_kind" "$file"; then
    ((ERRORS++)) || true
    log "ERROR" "Refusing ${label} outside its validated root: $file"
    return 1
  fi

  size="$(stat_size "$file")"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0

  case "$backup_kind" in
    nzb)
      ((NZB_BACKUPS_ELIGIBLE++)) || true
      ((NZB_BACKUP_BYTES += size)) || true
      ;;
    application)
      ((APP_BACKUPS_ELIGIBLE++)) || true
      ((APP_BACKUP_BYTES += size)) || true
      ;;
  esac

  if is_true "$DRY_RUN"; then
    log "INFO" "[DRY RUN] Would delete ${label}: $file"
    return 0
  fi

  check_mover_guard "before deleting ${label} ${file}"
  guard_status=$?
  (( guard_status == 0 )) || return "$guard_status"

  if rm -f -- "$file"; then
    BACKUP_DETAILS+=("Removed $backup_kind backup: $file ($(bytes_human "$size")); retention policy satisfied.")
    log "INFO" "Deleted ${label}: $file"
    case "$backup_kind" in
      nzb) ((NZB_BACKUPS_REMOVED++)) || true ;;
      application) ((APP_BACKUPS_REMOVED++)) || true ;;
    esac
    return 0
  fi

  ((ERRORS++)) || true
  log "ERROR" "Failed to delete ${label}: $file"
  return 1
}

cleanup_backup_class() {
  local backup_kind="$1"
  local file
  local candidate_status
  local class_failed=false

  local candidate_list="$TMP_DIR/backup-$backup_kind.list"
  if ! find_backup_candidates "$backup_kind" >"$candidate_list"; then
    log ERROR "Incomplete $backup_kind backup inventory; this backup class was preserved."
    return 1
  fi
  while IFS= read -r -d '' file; do
    mc_work_allowed sab || return 21
    process_backup_candidate "$backup_kind" "$file"
    candidate_status=$?

    if (( candidate_status == 20 )); then
      return 20
    elif (( candidate_status != 0 )); then
      class_failed=true
    fi
  done <"$candidate_list"

  ! is_true "$class_failed"
}

remove_empty_nzb_backup_directories() {
  local guard_status

  is_true "$DRY_RUN" && return 0
  [[ -n "$NZB_BACKUP_DIR_REAL" ]] || return 0

  check_mover_guard "before removing empty NZB backup directories"
  guard_status=$?
  (( guard_status == 0 )) || return "$guard_status"

  find "$NZB_BACKUP_DIR_REAL" \
    -mindepth 1 \
    -depth \
    -type d \
    -empty \
    -delete 2>/dev/null || true
}

cleanup_backups() {
  local operation_status
  local cleanup_failed=false

  log "DEBUG" "Cleaning SABnzbd backups."
  log "DEBUG" "NZB retention: ${NZB_RETENTION_DAYS}d"
  log "DEBUG" "Application backup retention: ${APP_BACKUP_RETENTION_DAYS}d"

  if [[ -n "$NZB_BACKUP_DIR_REAL" ]]; then
    cleanup_backup_class nzb
    operation_status=$?
    (( operation_status == 20 || operation_status == 21 )) && return "$operation_status"
    (( operation_status == 0 )) || cleanup_failed=true
  fi

  cleanup_backup_class application
  operation_status=$?
  (( operation_status == 20 || operation_status == 21 )) && return "$operation_status"
  (( operation_status == 0 )) || cleanup_failed=true

  remove_empty_nzb_backup_directories
  operation_status=$?
  (( operation_status == 20 || operation_status == 21 )) && return "$operation_status"

  ! is_true "$cleanup_failed"
}

###############################################################################
# API HELPERS
###############################################################################

curl_common_args() {
  printf '%s\0' \
    --silent \
    --show-error \
    --fail \
    --retry 2 \
    --retry-delay 1 \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_MAX_TIME"

  if ! is_true "$TLS_VERIFY"; then
    printf '%s\0' --insecure
  fi
}

run_curl() {
  local args=()
  while IFS= read -r -d '' arg; do
    args+=("$arg")
  done < <(curl_common_args)

  curl "${args[@]}" "$@"
}

sab_get() {
  local mode="$1"
  local output="$2"
  shift 2

  local query_args=(
    --get
    --data-urlencode "mode=$mode"
    --data-urlencode "output=json"
    --data-urlencode "apikey=$SAB_API_KEY"
  )

  local parameter
  for parameter in "$@"; do
    query_args+=(--data-urlencode "$parameter")
    # This GET-shaped native endpoint mutates the queue. Never replay it on
    # timeout/server error, even though read-only API requests may retry.
    [[ "$parameter" != name=add_orphan ]] || query_args+=(--retry 0)
  done

  if ! run_curl "${query_args[@]}" "${SAB_URL%/}/api" -o "$output"; then
    return 1
  fi

  jq empty "$output" >/dev/null 2>&1
}

arr_get() {
  local url="$1"
  local api_key="$2"
  local output="$3"
  shift 3

  local query_args=(--get -H "X-Api-Key: $api_key")
  local parameter

  for parameter in "$@"; do
    query_args+=(--data-urlencode "$parameter")
  done

  if ! run_curl "${query_args[@]}" "$url" -o "$output"; then
    return 1
  fi

  jq empty "$output" >/dev/null 2>&1
}

fetch_sab_history() {
  local slots_file="$TMP_DIR/sab_history_slots.jsonl"
  : > "$slots_file"

  local start=0
  local page=0
  local count
  local output

  while (( page < SAB_HISTORY_MAX_PAGES )); do
    mc_work_allowed sab || return 21
    output="$TMP_DIR/sab_history_page_${page}.json"

    if ! sab_get history "$output" "start=$start" "limit=$SAB_HISTORY_PAGE_SIZE"; then
      return 1
    fi

    count="$(jq '.history.slots // [] | length' "$output" 2>/dev/null)" || return 1
    [[ "$count" =~ ^[0-9]+$ ]] || return 1

    jq -c '.history.slots[]?' "$output" >> "$slots_file" || return 1

    (( count == 0 )) && break

    start=$((start + count))
    page=$((page + 1))

    (( count < SAB_HISTORY_PAGE_SIZE )) && break
  done

  if (( page >= SAB_HISTORY_MAX_PAGES && count >= SAB_HISTORY_PAGE_SIZE )); then
    log "ERROR" "SAB history exceeded the configured pagination safety limit."
    return 1
  fi

  jq -s '.' "$slots_file" > "$SAB_HISTORY_FILE" || return 1
}

fetch_sab_queue() {
  sab_get queue "$SAB_QUEUE_FILE" "start=0" "limit=0" || return 1
  jq -e '.queue|type=="object" and (.slots|type)=="array" and ((.noofslots|tonumber) <= (.slots|length))' "$SAB_QUEUE_FILE" >/dev/null || {
    log ERROR "SAB queue is incomplete or invalid; stranded download cleanup is prohibited."
    return 1
  }
}

fetch_arr_queue() {
  local app="$1"
  local output="$2"
  local base_url
  local api_key
  local unknown_parameter

  case "$app" in
    Sonarr)
      base_url="$SONARR_URL"
      api_key="$SONARR_API_KEY"
      unknown_parameter="includeUnknownSeriesItems=true"
      ;;
    Radarr)
      base_url="$RADARR_URL"
      api_key="$RADARR_API_KEY"
      unknown_parameter="includeUnknownMovieItems=true"
      ;;
    *) return 1 ;;
  esac

  if ! arr_get \
    "${base_url%/}/api/v3/queue" \
    "$api_key" \
    "$output" \
    "page=1" \
    "pageSize=$ARR_QUEUE_PAGE_SIZE" \
    "$unknown_parameter"
  then
    return 1
  fi

  local loaded
  local total
  loaded="$(jq '.records // [] | length' "$output" 2>/dev/null)" || return 1
  total="$(jq '.totalRecords // (.records // [] | length)' "$output" 2>/dev/null)" || return 1

  [[ "$loaded" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || return 1

  if (( loaded < total )); then
    log "ERROR" "$app queue has $total records but only $loaded were loaded; refusing cleanup."
    return 1
  fi
}

fetch_arr_history_for_download() {
  local app="$1"
  local download_id="$2"
  local output="$3"
  local base_url
  local api_key

  case "$app" in
    Sonarr)
      base_url="$SONARR_URL"
      api_key="$SONARR_API_KEY"
      ;;
    Radarr)
      base_url="$RADARR_URL"
      api_key="$RADARR_API_KEY"
      ;;
    *) return 1 ;;
  esac

  if ! arr_get \
    "${base_url%/}/api/v3/history" \
    "$api_key" \
    "$output" \
    "page=1" \
    "pageSize=$ARR_HISTORY_PAGE_SIZE" \
    "sortKey=date" \
    "sortDirection=descending" \
    "downloadId=$download_id"
  then
    return 1
  fi

  local loaded
  local total
  loaded="$(jq '.records // [] | length' "$output" 2>/dev/null)" || return 1
  total="$(jq '.totalRecords // (.records // [] | length)' "$output" 2>/dev/null)" || return 1

  [[ "$loaded" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || return 1

  if (( loaded < total )); then
    log "WARNING" "$app history for download ID '$download_id' was truncated ($loaded/$total)."
    return 1
  fi
}

fetch_required_state() {
  log "INFO" "Fetching SABnzbd history and queue."
  if ! fetch_sab_history; then
    ((ERRORS++)) || true
    log "ERROR" "Unable to fetch complete SABnzbd history. Stranded cleanup was skipped."
    return 1
  fi
  if ! fetch_sab_queue; then
    ((ERRORS++)) || true
    log "ERROR" "Unable to fetch SABnzbd queue. Stranded cleanup was skipped."
    return 1
  fi

  if is_true "$SONARR_ENABLED"; then
    log "INFO" "Fetching Sonarr Activity queue."
    if ! fetch_arr_queue Sonarr "$SONARR_QUEUE_FILE"; then
      ((ERRORS++)) || true
      log "ERROR" "Unable to fetch complete Sonarr queue. Stranded cleanup was skipped."
      return 1
    fi
  else
    printf '{"records":[],"totalRecords":0}\n' > "$SONARR_QUEUE_FILE"
  fi

  if is_true "$RADARR_ENABLED"; then
    log "INFO" "Fetching Radarr Activity queue."
    if ! fetch_arr_queue Radarr "$RADARR_QUEUE_FILE"; then
      ((ERRORS++)) || true
      log "ERROR" "Unable to fetch complete Radarr queue. Stranded cleanup was skipped."
      return 1
    fi
  else
    printf '{"records":[],"totalRecords":0}\n' > "$RADARR_QUEUE_FILE"
  fi
}

refresh_active_state() {
  fetch_sab_queue || return 1

  if is_true "$SONARR_ENABLED"; then
    fetch_arr_queue Sonarr "$SONARR_QUEUE_FILE" || return 1
  fi

  if is_true "$RADARR_ENABLED"; then
    fetch_arr_queue Radarr "$RADARR_QUEUE_FILE" || return 1
  fi
}

###############################################################################
# TIME / QUEUE HELPERS
###############################################################################

date_to_epoch() {
  local value="$1"
  local normalized

  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
    return 0
  fi

  if date -d "$value" '+%s' >/dev/null 2>&1; then
    date -d "$value" '+%s'
    return 0
  fi

  normalized="${value%%.*}"
  normalized="${normalized%Z}"

  date -j -u -f '%Y-%m-%dT%H:%M:%S' "$normalized" '+%s' 2>/dev/null || printf '0'
}

sab_completed_epoch() {
  local item="$1"
  local value

  value="$(jq -r '.completed // .completed_time // .completedTime // .completionTime // ""' <<<"$item")"
  date_to_epoch "$value"
}

queue_contains_download() {
  local queue_file="$1"
  local download_id="$2"

  jq -e \
    --arg id "$download_id" \
    'any(.records[]?; ((.downloadId // "") | ascii_downcase) == ($id | ascii_downcase))' \
    "$queue_file" >/dev/null 2>&1
}

sab_queue_contains_download() {
  local download_id="$1"

  jq -e \
    --arg id "$download_id" \
    'any(.queue.slots[]?; ((.nzo_id // "") | ascii_downcase) == ($id | ascii_downcase))' \
    "$SAB_QUEUE_FILE" >/dev/null 2>&1
}

download_is_active_anywhere() {
  local download_id="$1"

  sab_queue_contains_download "$download_id" || \
    queue_contains_download "$SONARR_QUEUE_FILE" "$download_id" || \
    queue_contains_download "$RADARR_QUEUE_FILE" "$download_id" || \
    sab_history_download_pending "$download_id"
}

sab_history_download_pending() {
  [[ -f "${SAB_HISTORY_FILE:-}" ]] || return 1
  local rc=0
  jq -e --arg id "${1,,}" 'any(.[]; ((.nzo_id // ""|ascii_downcase)==$id) and
    ((.status // ""|ascii_downcase)!="completed"))' "$SAB_HISTORY_FILE" >/dev/null 2>&1 || rc=$?
  # Unknown states and parse failures remain protected.
  ((rc!=1))
}

###############################################################################
# PATH HELPERS
###############################################################################

owner_for_category() {
  local category="${1,,}"

  if [[ "$category" == "${SAB_TV_CATEGORY,,}" ]]; then
    printf 'Sonarr'
  elif [[ "$category" == "${SAB_MOVIE_CATEGORY,,}" ]]; then
    printf 'Radarr'
  fi
}

root_for_owner() {
  case "$1" in
    Sonarr) printf '%s' "$SAB_TV_DIR_REAL" ;;
    Radarr) printf '%s' "$SAB_MOVIE_DIR_REAL" ;;
  esac
}

library_roots_for_owner() {
  case "$1" in
    Sonarr) printf '%s' "$SONARR_LIBRARY_ROOTS" ;;
    Radarr) printf '%s' "$RADARR_LIBRARY_ROOTS" ;;
  esac
}

path_maps_for_owner() {
  case "$1" in
    Sonarr) printf '%s' "$SONARR_IMPORT_PATH_MAPS" ;;
    Radarr) printf '%s' "$RADARR_IMPORT_PATH_MAPS" ;;
  esac
}

resolve_sab_path() {
  local item="$1"
  local root="$2"
  local storage
  local name
  local candidate=""
  local relative
  local resolved

  storage="$(jq -r '.storage // .path // ""' <<<"$item")"
  name="$(jq -r '.name // .nzb_name // ""' <<<"$item")"

  if [[ -n "$storage" && -e "$storage" ]]; then
    candidate="$storage"
  elif [[ -n "$storage" && -n "$SAB_CONTAINER_COMPLETE_ROOT" && \
          ( "$storage" == "$SAB_CONTAINER_COMPLETE_ROOT" || "$storage" == "$SAB_CONTAINER_COMPLETE_ROOT"/* ) ]]; then
    relative="${storage#"$SAB_CONTAINER_COMPLETE_ROOT"}"
    candidate="${SAB_COMPLETE_ROOT%/}${relative}"
  elif [[ -n "$storage" ]]; then
    candidate="${root%/}/$(basename -- "${storage%/}")"
  elif [[ -n "$name" ]]; then
    candidate="${root%/}/$name"
  else
    return 1
  fi

  [[ -e "$candidate" ]] || return 1
  [[ ! -L "$candidate" ]] || return 1

  resolved="$(realpath -- "$candidate")" || return 1
  path_is_below "$resolved" "$root" || return 1

  printf '%s' "$resolved"
}

resolve_imported_path() {
  local owner="$1"
  local reported="$2"
  local candidate=""
  local resolved
  local mappings
  local mapping
  local from
  local to
  local roots
  local root
  local allowed=false

  if [[ -e "$reported" ]]; then
    candidate="$reported"
  else
    mappings="$(path_maps_for_owner "$owner")"
    local mapping_list=()
    IFS=';' read -r -a mapping_list <<<"$mappings"

    for mapping in "${mapping_list[@]}"; do
      [[ "$mapping" == *'|'* ]] || continue
      from="${mapping%%|*}"
      to="${mapping#*|}"
      [[ -n "$from" && -n "$to" ]] || continue

      if [[ "$reported" == "$from" || "$reported" == "$from"/* ]]; then
        candidate="${to%/}${reported#"$from"}"
        [[ -e "$candidate" ]] && break
        candidate=""
      fi
    done
  fi

  [[ -n "$candidate" && -f "$candidate" ]] || return 1

  resolved="$(realpath -- "$candidate")" || return 1
  roots="$(library_roots_for_owner "$owner")"

  local root_list=()
  IFS=';' read -r -a root_list <<<"$roots"

  for root in "${root_list[@]}"; do
    [[ -d "$root" ]] || continue
    root="$(realpath -- "$root")" || continue
    if path_is_below "$resolved" "$root"; then
      allowed=true
      break
    fi
  done

  is_true "$allowed" || return 1

  local size
  size="$(stat_size "$resolved")"
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  (( size > 0 )) || return 1

  printf '%s' "$resolved"
}

newest_path_mtime() {
  find "$1" -xdev -printf '%T@\n' | awk 'BEGIN{max=0} $1>max {max=$1} END{printf "%.0f",max}'
}

path_is_stable() {
  local path="$1"
  local newest
  local cutoff

  newest="$(newest_path_mtime "$path")"
  [[ "$newest" =~ ^[0-9]+$ ]] || return 1
  (( newest > 0 )) || return 1

  cutoff=$(( $(date '+%s') - MIN_PATH_STABLE_HOURS * 3600 ))
  (( newest <= cutoff ))
}

path_size() {
  if [[ -f "$1" ]]; then stat_size "$1"; return; fi
  find "$1" -xdev -type f -printf '%s\n' | awk '{n+=$1} END{printf "%.0f",n+0}'
}

source_media_count() {
  local path="$1"
  local count=0
  local file
  local base inventory
  inventory=$(mktemp "$TMP_DIR/source-media.XXXXXX") || return 1
  if [[ -f "$path" && ! -L "$path" ]]; then
    printf '%s\0' "$path" >"$inventory" || return 1
  elif [[ -d "$path" && ! -L "$path" ]]; then
    find "$path" -xdev -type f -print0 >"$inventory" || { rm -f -- "$inventory"; return 1; }
  else rm -f -- "$inventory"; return 1; fi

  while IFS= read -r -d '' file; do
    base="${file##*/}"
    base="${base,,}"

    case "$base" in
      *.mkv|*.mp4|*.m4v|*.avi|*.mov|*.ts|*.m2ts|*.wmv|*.webm)
        if [[ "$base" =~ (^|[._\ -])(sample|trailer)([._\ -]|$) ]]; then
          continue
        fi
        ((count++)) || true
        ;;
    esac
  done <"$inventory"
  rm -f -- "$inventory" || return 1

  printf '%s' "$count"
}

###############################################################################
# ARR IMPORT PROOF
###############################################################################

# A policy disposition is NOT an import. Accept only this monitor's durable,
# verified exact-ID receipt, with unchanged SAB identity and fresh Arr checks.
# It authorizes reversible quarantine only, never removal from the library.
# Durable receipts supplement native history; they never substitute a title
# match or a different current file. A rename is accepted only for the SAME ID.
verify_durable_import_receipt() {
  local owner="$1" download_id="${2,,}" source_path="$3" proof_file="$4" item="$5"
  local input="$TMP_DIR/import-receipt-job.json" receipt="$TMP_DIR/import-receipt.json" targets="$TMP_DIR/import-receipt-targets.jsonl"
  local root key target target_id parent_id file_id kind object="$TMP_DIR/receipt-object.json" media="$TMP_DIR/receipt-media.json"
  local paths="$TMP_DIR/receipt-paths.jsonl" resolved source_count count
  [[ -f "$IMPORT_RECEIPT_FILE" && ! -L "$IMPORT_RECEIPT_FILE" ]] || return 11
  arr_import_receipt_document_valid "$IMPORT_RECEIPT_FILE" || { log ERROR 'Import receipt schema invalid; payload preserved';return 11; }
  printf '%s' "$item" >"$input" || return 11
  jq -e --arg app "$owner" --arg id "$download_id" --slurpfile job "$input" '
    select(.version==1) | .receipts[$app+":"+$id] | select(.app==$app and .downloadId==$id and .conflict!=true and
      .sab==($job[0]|{nzo_id,name,storage,completed,category}) and (.targets|type)=="object" and (.targets|length)>0)' "$IMPORT_RECEIPT_FILE" >"$receipt" || return 11
  case "$owner" in
    Sonarr) root="${SONARR_URL%/}/api/v3"; key="$SONARR_API_KEY"; kind=episode ;;
    Radarr) root="${RADARR_URL%/}/api/v3"; key="$RADARR_API_KEY"; kind=movie ;;
    *) return 11 ;;
  esac
  jq -c '.targets[]' "$receipt" >"$targets" || return 11
  : >"$paths"
  while IFS= read -r target; do
    target_id=$(jq -r '.targetId' <<<"$target"); parent_id=$(jq -r '.parentId' <<<"$target"); file_id=$(jq -r '.fileId' <<<"$target")
    [[ "$target_id" =~ ^[1-9][0-9]*$ && "$parent_id" =~ ^[1-9][0-9]*$ && "$file_id" =~ ^[1-9][0-9]*$ ]] || return 12
    jq -e --arg kind "$kind" '.kind==$kind' <<<"$target" >/dev/null || return 12
    arr_get "$root/$kind/$target_id" "$key" "$object" && arr_get "$root/${kind}file/$file_id" "$key" "$media" || return 10
    local target_input="$TMP_DIR/receipt-target.json"; printf '%s' "$target" >"$target_input"
    jq -e --slurpfile expected "$target_input" --arg kind "$kind" '
      $expected[0] as $e | .id==$e.targetId and .hasFile==true and
      (if $kind=="episode" then .episodeFileId==$e.fileId and .seriesId==$e.parentId and
        ($e.seasonNumber==null or .seasonNumber==$e.seasonNumber) and ($e.episodeNumber==null or .episodeNumber==$e.episodeNumber)
       else .movieFileId==$e.fileId end)' "$object" >/dev/null || return 12
    jq -e --argjson id "$file_id" --argjson parent "$parent_id" --arg kind "$kind" '.id==$id and .size>0 and
      (if $kind=="episode" then .seriesId==$parent else .movieId==$parent end) and (.path|type)=="string"' "$media" >/dev/null || return 12
    local external parent_object="$TMP_DIR/receipt-parent.json" parent_kind=movie
    external=$(jq -r '.parentExternalId // 0' <<<"$target")
    if [[ "$external" =~ ^[1-9][0-9]*$ ]]; then
      [[ "$kind" != episode ]] || parent_kind=series
      arr_get "$root/$parent_kind/$parent_id" "$key" "$parent_object" || return 10
      jq -e --argjson id "$parent_id" --argjson external "$external" --arg kind "$kind" '.id==$id and
        (if $kind=="episode" then .tvdbId==$external else .tmdbId==$external end)' "$parent_object" >/dev/null || return 12
    else
      # Older receipts without TVDB/TMDB identity can prove the original exact
      # path, but may not authorize a rename after database IDs were reused.
      jq -e --slurpfile expected "$target_input" '.path==$expected[0].pathAtImport' "$media" >/dev/null || return 12
    fi
    resolved=$(resolve_imported_path "$owner" "$(jq -r '.path' "$media")") || return 12
    jq -nc --arg path "$resolved" '$path' >>"$paths" || return 12
  done <"$targets"
  source_count=$(source_media_count "$source_path") || return 13
  count=$(jq -s 'unique|length' "$paths") || return 12
  [[ "$source_count" =~ ^[0-9]+$ ]] && ((count>0 && count>=source_count)) || return 13
  jq -n --arg owner "$owner" --arg id "$download_id" --argjson count "$count" --argjson source "$source_count" \
    --slurpfile receipt "$receipt" --slurpfile paths "$paths" \
    '{proofKind:"durable-import-receipt",owner:$owner,downloadId:$id,importReceipt:$receipt[0],
      latestGrabEpoch:0,importEvents:($receipt[0].targets|length),verifiedImportedPaths:$count,
      remainingSourceMediaFiles:$source,importedPaths:($paths|unique)}' >"$proof_file"
}

verify_policy_disposition() {
  local owner="$1" download_id="${2,,}" source_path="$3" proof_file="$4" item="$5"
  local receipt="$TMP_DIR/policy-receipt.json" target="$TMP_DIR/policy-current-target.json" parent="$TMP_DIR/policy-current-parent.json"
  local root key kind target_id parent_id mode file_id file endpoint resolved source_count
  [[ -r "$POLICY_DISPOSITION_FILE" ]] || return 11
  arr_policy_receipt_document_valid "$POLICY_DISPOSITION_FILE" || { log ERROR 'Policy receipt schema invalid; payload preserved';return 11; }
  local item_file="$TMP_DIR/policy-sab-item.json"
  printf '%s' "$item" >"$item_file" || return 11
  jq -e --arg id "$download_id" --arg app "$owner" --slurpfile sab_item "$item_file" '$sab_item[0] as $item |
    .actions[$id] | select(.downloadId==$id and .app==$app and .status=="done" and .queueVerified==true and
      (.mode=="redundant" or .mode=="replace") and
      .sab==($item|{nzo_id,name,storage,completed,category}))' "$POLICY_DISPOSITION_FILE" >"$receipt" || return 11
  kind=$(jq -r '.kind' "$receipt"); target_id=$(jq -r '.targetId' "$receipt"); parent_id=$(jq -r '.parentId' "$receipt"); mode=$(jq -r '.mode' "$receipt")
  [[ "$target_id" =~ ^[1-9][0-9]*$ && "$parent_id" =~ ^[1-9][0-9]*$ ]] || return 11
  case "$owner:$kind" in
    Sonarr:episode) root="${SONARR_URL%/}/api/v3"; key="$SONARR_API_KEY"; endpoint=series ;;
    Radarr:movie) root="${RADARR_URL%/}/api/v3"; key="$RADARR_API_KEY"; endpoint=movie ;;
    *) return 11 ;;
  esac
  source_count=$(source_media_count "$source_path") || return 13
  # A second video could be a partial pack/extra required episode: preserve.
  [[ "$source_count" =~ ^[01]$ ]] || return 13
  arr_get "$root/$kind/$target_id" "$key" "$target" && arr_get "$root/$endpoint/$parent_id" "$key" "$parent" || return 10
  jq -e --argjson id "$target_id" --argjson parent "$parent_id" --arg kind "$kind" --slurpfile receipt "$receipt" '.id==$id and .monitored==true and
    (if $kind=="episode" then .seriesId==$parent and .seasonNumber==$receipt[0].target.seasonNumber and .episodeNumber==$receipt[0].target.episodeNumber else true end)' "$target" >/dev/null || return 12
  jq -e --argjson id "$parent_id" '.id==$id and .monitored==true and (.tags|length)==0' "$parent" >/dev/null || return 12
  local imported='[]'
  if [[ "$mode" == redundant ]]; then
    file_id=$(jq -r '.fileId' "$receipt"); [[ "$file_id" =~ ^[1-9][0-9]*$ ]] || return 12
    jq -e --argjson file "$file_id" '(.episodeFileId // .movieFileId)==$file and .hasFile==true' "$target" >/dev/null || return 12
    file="$TMP_DIR/policy-existing-file.json"
    arr_get "$root/${kind}file/$file_id" "$key" "$file" || return 10
    jq -e --argjson id "$file_id" --argjson parent "$parent_id" --arg kind "$kind" --slurpfile receipt "$receipt" '.id==$id and .path==$receipt[0].filePath and
      (if $kind=="episode" then .seriesId==$parent else .movieId==$parent end)' "$file" >/dev/null || return 12
    resolved=$(resolve_imported_path "$owner" "$(jq -r '.path' "$file")") || return 12
    imported=$(jq -nc --arg path "$resolved" '[$path]') || return 12
  else
    # A verified external/current import can make the planned search obsolete.
    # It authorizes no replay and must still name the exact current native file.
    if ! jq -e '(.commandId // 0)>0' "$receipt" >/dev/null;then
      jq -e '.resolutionSource=="verified-current-file" and .replacementState=="import_verified" and
        (.replacementProofRuns|type)=="number" and .replacementProofRuns>=2 and
        (.replacementFileId|type)=="number" and .replacementFileId>0' "$receipt" >/dev/null || return 11
      file_id=$(jq -r '.replacementFileId' "$receipt")
      jq -e --argjson file "$file_id" '.hasFile==true and (.episodeFileId // .movieFileId)==$file' "$target" >/dev/null || return 12
      file="$TMP_DIR/policy-replacement-file.json"
      arr_get "$root/${kind}file/$file_id" "$key" "$file" || return 10
      jq -e --argjson id "$file_id" --argjson parent "$parent_id" --arg kind "$kind" '.id==$id and .size>0 and
        (.path|type)=="string" and (if $kind=="episode" then .seriesId==$parent else .movieId==$parent end)' "$file" >/dev/null || return 12
      resolved=$(resolve_imported_path "$owner" "$(jq -r '.path' "$file")") || return 12
      imported=$(jq -nc --arg path "$resolved" '[$path]') || return 12
    fi
  fi
  jq -n --arg owner "$owner" --arg id "$download_id" --argjson paths "$imported" --argjson count "$source_count" --slurpfile receipt "$receipt" \
    '{proofKind:"policy-disposition",owner:$owner,downloadId:$id,policyReceipt:$receipt[0],importEvents:0,
      latestGrabEpoch:0,verifiedImportedPaths:($paths|length),remainingSourceMediaFiles:$count,importedPaths:$paths}' >"$proof_file"
}

verify_arr_import() {
  local owner="$1"
  local download_id="$2"
  local source_path="$3"
  local proof_file="$4"

  local history_file="$TMP_DIR/history_${SCANNED}.json"
  local imported_paths_file="$TMP_DIR/imported_paths_${SCANNED}.txt"
  local imported_paths_unique="$TMP_DIR/imported_paths_unique_${SCANNED}.txt"
  : > "$imported_paths_file"

  if ! fetch_arr_history_for_download "$owner" "$download_id" "$history_file"; then
    log "WARNING" "$owner history lookup failed for download ID: $download_id"
    return 10
  fi

  local latest_grab_epoch=0
  local record
  local record_id
  local event_type
  local event_date
  local event_epoch

  while IFS= read -r record; do
    record_id="$(jq -r '.downloadId // ""' <<<"$record")"
    [[ "${record_id,,}" == "${download_id,,}" ]] || continue

    event_type="$(jq -r '.eventType // ""' <<<"$record")"
    [[ "$event_type" == "grabbed" ]] || continue

    event_date="$(jq -r '.date // ""' <<<"$record")"
    event_epoch="$(date_to_epoch "$event_date")"
    [[ "$event_epoch" =~ ^[0-9]+$ ]] || event_epoch=0

    (( event_epoch > latest_grab_epoch )) && latest_grab_epoch="$event_epoch"
  done < <(jq -c '.records[]?' "$history_file")

  (( latest_grab_epoch > 0 )) || return 11

  local reported_path
  local resolved_path
  local import_events=0

  while IFS= read -r record; do
    record_id="$(jq -r '.downloadId // ""' <<<"$record")"
    [[ "${record_id,,}" == "${download_id,,}" ]] || continue

    event_type="$(jq -r '.eventType // ""' <<<"$record")"
    [[ "$event_type" == "downloadFolderImported" ]] || continue

    event_date="$(jq -r '.date // ""' <<<"$record")"
    event_epoch="$(date_to_epoch "$event_date")"
    [[ "$event_epoch" =~ ^[0-9]+$ ]] || event_epoch=0
    (( event_epoch >= latest_grab_epoch )) || continue

    ((import_events++)) || true
    reported_path="$(jq -r '.data.importedPath // ""' <<<"$record")"
    [[ -n "$reported_path" ]] || return 12

    resolved_path="$(resolve_imported_path "$owner" "$reported_path" || true)"
    [[ -n "$resolved_path" ]] || return 12
    printf '%s\n' "$resolved_path" >> "$imported_paths_file"
  done < <(jq -c '.records[]?' "$history_file")

  (( import_events > 0 )) || return 11

  sort -u -- "$imported_paths_file" > "$imported_paths_unique"

  local imported_count
  local source_count
  imported_count="$(wc -l < "$imported_paths_unique" | tr -d ' ')"
  source_count="$(source_media_count "$source_path")"

  [[ "$imported_count" =~ ^[0-9]+$ && "$source_count" =~ ^[0-9]+$ ]] || return 13
  (( imported_count > 0 )) || return 12
  (( imported_count >= source_count )) || return 13

  local imported_paths_json
  imported_paths_json="$(jq -R -s 'split("\n") | map(select(length > 0))' "$imported_paths_unique")" || return 12

  jq -n \
    --arg owner "$owner" \
    --arg downloadId "$download_id" \
    --argjson latestGrabEpoch "$latest_grab_epoch" \
    --argjson importEvents "$import_events" \
    --argjson verifiedImportedPaths "$imported_count" \
    --argjson remainingSourceMediaFiles "$source_count" \
    --argjson importedPaths "$imported_paths_json" \
    '{
      owner: $owner,
      downloadId: $downloadId,
      latestGrabEpoch: $latestGrabEpoch,
      importEvents: $importEvents,
      verifiedImportedPaths: $verifiedImportedPaths,
      remainingSourceMediaFiles: $remainingSourceMediaFiles,
      importedPaths: $importedPaths
    }' > "$proof_file"
}

proof_paths_still_valid() {
  local proof_file="$1"
  local imported_path
  local size

  while IFS= read -r imported_path; do
    [[ -n "$imported_path" && -f "$imported_path" ]] || return 1
    size="$(stat_size "$imported_path")"
    [[ "$size" =~ ^[0-9]+$ ]] || return 1
    (( size > 0 )) || return 1
  done < <(jq -r '.importedPaths[]?' "$proof_file")

  if jq -e '.proofKind=="policy-disposition" and .policyReceipt.mode=="replace"' "$proof_file" >/dev/null; then
    # Missing-media rejection has no imported destination. It remains protected
    # by the exact receipt, single-video inventory, path-idle and fresh queues.
    return 0
  fi
  jq -e '.importedPaths | length > 0' "$proof_file" >/dev/null 2>&1
}

###############################################################################
# QUARANTINE / PURGE
###############################################################################

quarantine_payload() {
  local owner="$1"
  local category="$2"
  local download_id="$3"
  local job_name="$4"
  local completed_epoch="$5"
  local source_path="$6"
  local size="$7"
  local proof_file="$8"

  local safe_id
  local safe_name
  local wrapper
  local payload_name
  local manifest

  safe_id="$(sanitize_component "$download_id")"
  safe_name="$(sanitize_component "$job_name")"
  [[ -n "$safe_id" ]] || safe_id="unknown-id"
  [[ -n "$safe_name" ]] || safe_name="unnamed-job"

  wrapper="${QUARANTINE_DIR_REAL}/items/${owner}/${safe_id}__${safe_name}"
  if [[ -e "$wrapper" ]]; then
    wrapper="${wrapper}__${RUN_ID}"
  fi

  LAST_QUARANTINE_DESTINATION="$wrapper/payload"
  payload_name="$(basename -- "$source_path")"
  manifest="${wrapper}/.sabnzbd-cleanup-manifest.json"

  if is_true "$DRY_RUN"; then
    log "INFO" "[DRY RUN] Would quarantine: $source_path"
    log "INFO" "[DRY RUN] Destination wrapper: $wrapper"
    return 0
  fi

  # This is deliberately the last check before the first quarantine write.
  # If Mover started after the initial scan, stop the entire run here.
  check_mover_guard "before quarantine move for ${download_id}" || return $?

  mkdir -p -- "$wrapper" || return 1

  local wrapper_real
  wrapper_real="$(realpath -- "$wrapper")" || return 1
  path_is_below "$wrapper_real" "${QUARANTINE_DIR_REAL}/items/${owner}" || return 1

  local source_device
  local destination_device
  source_device="$(stat_device "$source_path")"
  destination_device="$(stat_device "$wrapper")"

  if [[ -z "$source_device" || -z "$destination_device" || "$source_device" != "$destination_device" ]]; then
    log "ERROR" "Source and quarantine are not on the same filesystem: $source_path"
    rmdir -- "$wrapper" 2>/dev/null || true
    return 1
  fi

  orphan_move_guard "$source_path" "$proof_file" || { log WARNING "Orphan changed immediately before intent; preserved: $source_path"; return 1; }
  local prepared="$wrapper/.manifest-prepared.$$" committed="$wrapper/.manifest-committed.$$"
  if ! jq -n --arg version "$VERSION" --arg runId "$RUN_ID" --arg quarantinedAt "$(timestamp)" \
    --arg owner "$owner" --arg category "$category" --arg downloadId "$download_id" --arg jobName "$job_name" \
    --arg originalPath "$source_path" --arg payloadName "$payload_name" --argjson completedEpoch "$completed_epoch" \
    --argjson bytes "$size" --argjson now "$(date +%s)" --slurpfile proof "$proof_file" \
    '{scriptVersion:$version,runId:$runId,state:"prepared",preparedEpoch:$now,quarantinedAt:$quarantinedAt,
      owner:$owner,category:$category,downloadId:$downloadId,jobName:$jobName,originalPath:$originalPath,
      payloadName:$payloadName,completedEpoch:$completedEpoch,bytes:$bytes,importProof:$proof[0]}' >"$prepared" ||
     ! ops_publish_checkpoint "$prepared" "$manifest"; then
      log ERROR "Cannot commit quarantine intent; source was preserved: $source_path"; return 1
  fi
  orphan_move_guard "$source_path" "$proof_file" || { log WARNING "Orphan changed after intent; source and recovery manifest preserved: $source_path"; return 1; }
  if ! mv -- "$source_path" "$wrapper/payload"; then
    log ERROR "Quarantine move was unsuccessful; recovery manifest retained: $manifest"; return 1
  fi
  normalize_quarantine_permissions "$wrapper" || return 1
  ops_flush_move "$source_path" "$wrapper/payload" || return 1
  jq --argjson now "$(date +%s)" '.state="committed" | .quarantinedEpoch=$now' "$manifest" >"$committed" &&
    ops_publish_checkpoint "$committed" "$manifest" || return 1
  normalize_quarantine_permissions "$manifest" || return 1

  return 0
}

validate_quarantine_manifest() {
  local wrapper="$1" manifest="$1/.sabnzbd-cleanup-manifest.json" real owner
  [[ -d "$wrapper" && ! -L "$wrapper" && -f "$manifest" && ! -L "$manifest" ]] || return 1
  real=$(realpath -- "$wrapper") || return 1
  owner=$(basename -- "$(dirname -- "$real")")
  [[ "$owner" == Sonarr || "$owner" == Radarr ]] || return 1
  path_is_below "$real" "$QUARANTINE_DIR_REAL/items/$owner" || return 1
  jq -e --arg owner "$owner" --arg movie "$SAB_MOVIE_DIR_REAL" --arg tv "$SAB_TV_DIR_REAL" '
    type=="object" and .owner==$owner
    and (.downloadId|type)=="string" and (.downloadId|length)>0
    and (.originalPath|type)=="string" and
      ((.originalPath|startswith($movie+"/")) or (.originalPath|startswith($tv+"/")))
    and (.bytes|type)=="number" and .bytes>=0
    and ((.state // "committed")=="committed" or .state=="prepared")
  ' "$manifest" >/dev/null
}

inspect_quarantines() {
  local root list manifest epoch age
  [[ -d "$QUARANTINE_DIR/items" && ! -L "$QUARANTINE_DIR" ]] || { printf 'No quarantine payloads found.\n'; return 0; }
  root=$(realpath -- "$QUARANTINE_DIR") || return 1
  exec 9>"$LOCK_FILE"; flock -n 9 || { printf 'Cleanup is active; inspection deferred.\n' >&2; return 1; }
  TMP_DIR=$(mktemp -d /tmp/sabnzbd_cleanup.XXXXXX) || return 1
  list="$TMP_DIR/inspect.list"
  find "$root/items" -mindepth 3 -maxdepth 3 -name '.sabnzbd-cleanup-manifest.json' -type f -print0 >"$list" || return 1
  while IFS= read -r -d '' manifest; do
    jq -c --arg wrapper "${manifest%/*}" --argjson now "$(date +%s)" \
      '{wrapper:$wrapper,job:.jobName,originalPath,state:(.state // "committed"),quarantinedAt,quarantinedEpoch,bytes,incrementalPurgeStarted:(.incrementalPurgeStarted // false),
        ageDays:(if (.quarantinedEpoch // 0)>0 then (($now-.quarantinedEpoch)/86400|floor) else null end)}' "$manifest" || return 1
  done <"$list"
}

restore_quarantine_payload() {
  OPS_QUARANTINE_ROOT="$QUARANTINE_DIR_REAL"
  OPS_RESTORE_ROOTS=("$SAB_MOVIE_DIR_REAL" "$SAB_TV_DIR_REAL")
  local operation_id partial_notice=""
  local wrapper="$1" manifest="$1/.sabnzbd-cleanup-manifest.json" destination resolved
  check_mover_guard "before manual quarantine restore" || return $?
  validate_quarantine_manifest "$wrapper" || { log ERROR "Invalid restore manifest or unsafe wrapper: $wrapper"; return 1; }
  if jq -e '.incrementalPurgeStarted==true' "$manifest" >/dev/null;then
    partial_notice='Incremental purge previously started; this restore returns only the remaining quarantined payload. Previously purged files cannot be restored from this wrapper.'
    log WARNING "$partial_notice"
  fi
  destination=$(jq -r '.originalPath' "$manifest")
  resolved=$(realpath -m -- "$destination") || return 1
  if ! { path_is_below "$resolved" "$SAB_MOVIE_DIR_REAL" || path_is_below "$resolved" "$SAB_TV_DIR_REAL"; }; then log ERROR "Restore path escapes completed-download roots: $destination"; return 1; fi
  [[ -e "$wrapper/payload" && ! -L "$wrapper/payload" && ! -e "$destination" && ! -L "$destination" ]] || { log ERROR "Restore refused: source missing/unsafe or destination already exists: $destination"; return 1; }
  if is_true "$DRY_RUN"; then log INFO "[DRY RUN] Would restore $wrapper/payload -> $destination"; return 0; fi
  mkdir -p -- "$PURGE_RECEIPT_DIR" "$(dirname -- "$destination")" || return 1
  jq -c --argjson at "$(date +%s)" '. + {auditEvent:"restore_intent",at:$at}' "$manifest" >>"$PURGE_RECEIPT_DIR/$RUN_ID.jsonl" || return 1
  operation_id=$(ops_operation_begin restore "$wrapper/payload" "$destination" "$PURGE_RECEIPT_DIR/$RUN_ID.jsonl") || { log ERROR "Cannot flush restore checkpoint; payload preserved."; return 1; }
  check_mover_guard "immediately before manual restore" || return $?
  ops_operation_paths_valid "$wrapper/payload" "$destination" || return 1
  mv -T -n -- "$wrapper/payload" "$destination" || return 1
  [[ ! -e "$wrapper/payload" && ! -L "$wrapper/payload" && -e "$destination" ]] || { log ERROR "Restore was not completed; existing paths and checkpoint preserved."; return 1; }
  jq -c --argjson at "$(date +%s)" '. + {auditEvent:"restore_verified",at:$at}' "$manifest" >>"$PURGE_RECEIPT_DIR/$RUN_ID.jsonl" || return 1
  ops_flush_move "$wrapper/payload" "$destination" || return 1
  ops_flush_file "$PURGE_RECEIPT_DIR/$RUN_ID.jsonl" || return 1
  ops_operation_finish "$operation_id" "Restore verified by successful move, source absence and destination presence" || return 1
  rm -f -- "$manifest"; rmdir -- "$wrapper" 2>/dev/null || true
  RECOVERY_DETAILS+=("Restored $destination from $wrapper/payload; existing destinations were not overwritten. Permissions outside quarantine were not changed. $partial_notice")
  ((RECOVERED++)) || true
  log INFO "Restored quarantined download: $destination"
}

recover_quarantine_preparations() {
  local manifests="$TMP_DIR/prepared-manifests.list" manifest wrapper source tmp payload_exists=false source_exists=false
  [[ -d "$QUARANTINE_DIR_REAL/items" ]] || return 0
  find "$QUARANTINE_DIR_REAL/items" -mindepth 3 -maxdepth 3 -name '.sabnzbd-cleanup-manifest.json' -type f -print0 >"$manifests" || return 1
  while IFS= read -r -d '' manifest; do
    jq -e '.state=="prepared"' "$manifest" >/dev/null || continue
    wrapper=${manifest%/*}
    validate_quarantine_manifest "$wrapper" || { log ERROR "Invalid interrupted quarantine was preserved: $wrapper"; ((ERRORS++)) || true; continue; }
    source=$(jq -r '.originalPath' "$manifest")
    if [[ -e "$wrapper/payload" && ! -e "$source" && ! -L "$source" ]]; then
      local recorded_size actual_size
      recorded_size=$(jq -r '.bytes' "$manifest"); actual_size=$(path_size "$wrapper/payload") || return 1
      if [[ "$recorded_size" != "$actual_size" ]]; then
        log ERROR "Interrupted payload size differs from its intent: $wrapper/payload; recorded=$recorded_size actual=$actual_size. Payload preserved for review."
        ((ERRORS++)) || true; continue
      fi
      check_mover_guard "before recovering quarantine intent" || return $?
      normalize_quarantine_permissions "$wrapper" || return 1
      tmp="$wrapper/.manifest-recovered.$$"
      jq --argjson now "$(date +%s)" '.state="committed" | .quarantinedEpoch=$now | .recovered=true' "$manifest" >"$tmp" && mv -f -- "$tmp" "$manifest" || return 1
      normalize_quarantine_permissions "$manifest" || return 1
      ((RECOVERED++)) || true
      RECOVERY_DETAILS+=("Recovered interrupted move: $source -> $wrapper/payload; manifest committed; retention restarted conservatively.")
    elif [[ -e "$source" && ! -e "$wrapper/payload" && ! -L "$wrapper/payload" ]]; then
      local extras="$TMP_DIR/prepared-extra.list"
      find "$wrapper" -mindepth 1 -maxdepth 1 ! -name '.sabnzbd-cleanup-manifest.json' -print -quit >"$extras" || return 1
      if [[ ! -s "$extras" ]]; then
        mkdir -p -- "$PURGE_RECEIPT_DIR" || return 1
        jq -c --argjson now "$(date +%s)" '. + {auditEvent:"interrupted_move_not_applied",auditedAt:$now}' "$manifest" >>"$PURGE_RECEIPT_DIR/$RUN_ID.jsonl" || return 1
        rm -f -- "$manifest" && rmdir -- "$wrapper" || return 1
        RECOVERY_DETAILS+=("Interrupted move did not occur: source preserved at $source; empty prepared wrapper removed; import proof will be reevaluated.")
        ((RECOVERED++)) || true
      else log ERROR "Interrupted quarantine contains unexpected entries; source and wrapper preserved: $wrapper"; ((ERRORS++)) || true; fi
    else
      log ERROR "Ambiguous interrupted move preserved: source=$source; quarantine=$wrapper/payload. Neither copy was overwritten or deleted."
      ((ERRORS++)) || true
    fi
  done <"$manifests"
}

# Drain only the payload, keeping its ownership/retention manifest until all
# payload entries are gone. Every file has a flushed identity intent and result.
# A single file larger than the configured byte cap remains protected/reported.
sab_purge_incremental() {
  local wrapper="$1" epoch="$2" receipt="$3" list="$TMP_DIR/incremental-files.list"
  local source canonical identity recorded op size completed=0 bytes=0 remaining manifest_identity manifest="$wrapper/.sabnzbd-cleanup-manifest.json"
  manifest_identity=$(stat -c '%d:%i:%f:%s:%y:%z' -- "$manifest") || return 1
  : >"$list"
  if [[ -e "$wrapper/payload" || -L "$wrapper/payload" ]];then
    find "$wrapper/payload" -xdev -type f -print0 >"$list" || return 1
  fi
  sort -z "$list" -o "$list" || return 1
  while IFS= read -r -d '' source;do
    mc_work_allowed sab || return 21
    check_mover_guard 'before incremental quarantine purge' || return $?
    validate_quarantine_manifest "$wrapper" || return 1
    [[ "$(stat -c '%d:%i:%f:%s:%y:%z' -- "$manifest")" == "$manifest_identity" ]] || return 1
    jq -e '(.state // "committed")=="committed"' "$manifest" >/dev/null || return 1
    [[ "$source" == "$wrapper/payload" || "$source" == "$wrapper/payload/"* ]] || return 1
    canonical=$(realpath -e -- "$source") || return 1
    [[ "$canonical" == "$source" && -f "$source" && ! -L "$source" ]] || return 1
    identity=$(stat -c '%d:%i:%f:%s:%y:%z' -- "$source") || return 1
    size=$(stat -c %s -- "$source") || return 1
    if ((size>MAX_PURGE_BYTES_PER_RUN));then
      log WARNING "Single quarantined file exceeds the daily byte cap; preserved: $source; bytes=$size; cap=$MAX_PURGE_BYTES_PER_RUN"
    fi
    if ((BYTES_PURGED+size>MAX_PURGE_BYTES_PER_RUN || SAB_PURGED_FILES>=MAX_PURGE_FILES_PER_RUN));then
      SAB_PURGE_REMAINING=$((SAB_PURGE_REMAINING+1));continue
    fi
    if is_true "$DRY_RUN";then
      log INFO "[DRY RUN] Would incrementally purge $source ($size bytes)"
    else
      # Persist before the first file unlink so manual restore/inspection never
      # promises a complete payload after an interrupted partial purge.
      if ! jq -e '.incrementalPurgeStarted==true' "$manifest" >/dev/null;then
        jq '.incrementalPurgeStarted=true' "$manifest" >"$TMP_DIR/partial-manifest.json" || return 1
        ops_publish_checkpoint "$TMP_DIR/partial-manifest.json" "$manifest" || return 1
        manifest_identity=$(stat -c '%d:%i:%f:%s:%y:%z' -- "$manifest") || return 1
      fi
      jq -nc --arg source "$source" --arg identity "$identity" --arg wrapper "$wrapper" --argjson bytes "$size" --argjson epoch "$epoch" \
        '{event:"file_purge_intent",source:$source,identity:$identity,wrapper:$wrapper,quarantinedEpoch:$epoch,bytes:$bytes}' >>"$receipt" || return 1
      op=$(ops_operation_begin purge-file "$source" '' "$receipt") || return 1
      recorded=$(jq -r --arg id "$op" '.operations[$id].identity' "$OPS_PENDING_OPERATIONS_FILE") || return 1
      [[ "$identity" == "$recorded" && "$(stat -c '%d:%i:%f:%s:%y:%z' -- "$source")" == "$identity" && ! -L "$source" ]] || { log ERROR "Incremental purge identity changed; file preserved: $source";return 1; }
      check_mover_guard 'immediately before incremental unlink' || return $?
      [[ "$(realpath -e -- "$source")" == "$source" && "$(stat -c '%d:%i:%f:%s:%y:%z' -- "$source")" == "$identity" && "$(stat -c '%d:%i:%f:%s:%y:%z' -- "$manifest")" == "$manifest_identity" ]] || return 1
      rm -f -- "$source" || return 1
      [[ ! -e "$source" && ! -L "$source" ]] || return 1
      ops_flush_directory "${source%/*}" || return 1
      jq -nc --arg source "$source" --argjson bytes "$size" '{event:"file_purge_verified",source:$source,bytes:$bytes}' >>"$receipt" || return 1
      ops_flush_file "$receipt" || return 1
      ops_operation_finish "$op" "Incremental purge verified; original file absent; bytes=$size" || return 1
    fi
    SAB_PURGED_FILES=$((SAB_PURGED_FILES+1));BYTES_PURGED=$((BYTES_PURGED+size))
    completed=$((completed+1));bytes=$((bytes+size))
  done <"$list"
  if ! is_true "$DRY_RUN";then
    check_mover_guard 'before incremental empty-directory removal' || return $?
    : >"$list"
    if [[ -d "$wrapper/payload" && ! -L "$wrapper/payload" ]];then
      find "$wrapper/payload" -xdev -depth -type d -print0 >"$list" || return 1
    fi
    while IFS= read -r -d '' source;do rmdir -- "$source" 2>/dev/null || true;done <"$list"
    if [[ ! -e "$wrapper/payload" && ! -L "$wrapper/payload" ]];then
      # Never remove a wrapper containing unexpected or newly created entries.
      find "$wrapper" -mindepth 1 -maxdepth 1 ! -name '.sabnzbd-cleanup-manifest.json' -print0 >"$list" || return 1
      if [[ ! -s "$list" ]] && ((SAB_PURGED_FILES<MAX_PURGE_FILES_PER_RUN && BYTES_PURGED+$(stat -c %s -- "$manifest")<=MAX_PURGE_BYTES_PER_RUN));then
        op=$(ops_operation_begin purge "$wrapper" '' "$receipt") || return 1
        check_mover_guard 'before final incremental wrapper cleanup' || return $?
        size=$(stat -c %s -- "$manifest") || return 1
        rm -f -- "$manifest" && rmdir -- "$wrapper" || return 1
        SAB_PURGED_FILES=$((SAB_PURGED_FILES+1));BYTES_PURGED=$((BYTES_PURGED+size))
        ops_flush_directory "${wrapper%/*}" || return 1
        ops_operation_finish "$op" 'Incremental wrapper purge complete; absence verified' || return 1
        PURGED=$((PURGED+1))
      fi
    fi
  fi
  if [[ -d "$wrapper" ]];then
    SAB_PURGE_REMAINING=$((SAB_PURGE_REMAINING+1))
    ((completed==0)) || SAB_PARTIAL_PURGES=$((SAB_PARTIAL_PURGES+1))
    log WARNING "Incremental quarantine retained remainder: $wrapper; removed=$completed files/$bytes bytes; byte/file caps or protected entries require a later eligible pass"
  fi
  ((completed==0)) || PURGE_DETAILS+=("Incremental purge $wrapper: $completed file(s), $(bytes_human "$bytes"); manifest/retention verified; remaining payload is preserved for a later eligible pass.")
}

purge_quarantine() {
  OPS_QUARANTINE_ROOT="$QUARANTINE_DIR_REAL"
  OPS_RESTORE_ROOTS=("$SAB_MOVIE_DIR_REAL" "$SAB_TV_DIR_REAL")
  local operation_id expired_receipts
  is_true "$PURGE_QUARANTINE" || return 0
  [[ -d "$QUARANTINE_DIR_REAL/items" ]] || return 0
  local wrappers="$TMP_DIR/purge-wrappers.list" candidates="$TMP_DIR/purge-candidates.tsv" wrapper manifest epoch at now size inventory receipt tmp count
  : >"$candidates"
  now=$(date +%s)
  mkdir -p -- "$PURGE_RECEIPT_DIR" || return 1
  if ! is_true "$DRY_RUN"; then
    expired_receipts="$TMP_DIR/old-receipts.list"
    find "$PURGE_RECEIPT_DIR" -maxdepth 1 -type f -name '*.jsonl' -mtime "+$PURGE_RECEIPT_RETENTION_DAYS" -print0 >"$expired_receipts" || return 1
    local old_receipt
    while IFS= read -r -d '' old_receipt; do
      ops_receipt_in_use "$old_receipt" && continue
      rm -f -- "$old_receipt" || return 1
    done <"$expired_receipts"
  fi
  find "$QUARANTINE_DIR_REAL/items" -mindepth 2 -maxdepth 2 -type d -print0 >"$wrappers" || return 1
  while IFS= read -r -d '' wrapper; do
    manifest="$wrapper/.sabnzbd-cleanup-manifest.json"
    if ! validate_quarantine_manifest "$wrapper"; then
      log WARNING "Quarantine preserved: missing/invalid manifest or unsafe path: $wrapper"; continue
    fi
    jq -e '(.state // "committed")=="committed"' "$manifest" >/dev/null || continue
    epoch=$(jq -r '.quarantinedEpoch // 0' "$manifest")
    if [[ ! "$epoch" =~ ^[0-9]+$ ]] || ((epoch<=0)); then
      at=$(jq -r '.quarantinedAt // ""' "$manifest"); epoch=$(date_to_epoch "$at")
    fi
    if [[ ! "$epoch" =~ ^[0-9]+$ ]] || ((epoch<=0 || epoch>now)); then
      log WARNING "Quarantine preserved: trustworthy quarantine timestamp unavailable: $wrapper"; continue
    fi
    (( now-epoch>=QUARANTINE_RETENTION_DAYS*86400 )) || continue
    printf '%s\t%s\n' "$epoch" "$wrapper" >>"$candidates"
  done <"$wrappers"
  sort -n "$candidates" -o "$candidates" || return 1
  SAB_OLDEST_EXPIRED_EPOCH=0
  SAB_EXPIRED_WRAPPERS=$(wc -l <"$candidates")
  if [[ -s "$candidates" ]];then IFS=$'\t' read -r SAB_OLDEST_EXPIRED_EPOCH wrapper <"$candidates";fi
  receipt="$PURGE_RECEIPT_DIR/$RUN_ID.jsonl"
  while IFS=$'\t' read -r epoch wrapper; do
    [[ -n "$wrapper" ]] || continue
    check_mover_guard "before quarantine purge" || return $?
    validate_quarantine_manifest "$wrapper" || return 1
    inventory="$TMP_DIR/purge-inventory.raw"
    find "$wrapper" -xdev -type f -printf '%P\t%s\0' >"$inventory" || { log ERROR "Incomplete purge inventory; wrapper preserved: $wrapper"; return 1; }
    tmp="$TMP_DIR/purge-inventory.json"
    jq -Rs '[split("\u0000")[]|select(length>0)|capture("^(?<path>.*)\t(?<bytes>[0-9]+)$";"s")|.bytes|=tonumber]' "$inventory" >"$tmp" || return 1
    size=$(jq '[.[].bytes]|add // 0' "$tmp"); count=$(jq 'length' "$tmp")
    if ((size>MAX_PURGE_BYTES_PER_RUN || count>MAX_PURGE_FILES_PER_RUN || BYTES_PURGED+size>MAX_PURGE_BYTES_PER_RUN || SAB_PURGED_FILES+count>MAX_PURGE_FILES_PER_RUN));then
      if ((PURGED+SAB_PARTIAL_PURGES>=MAX_PURGES_PER_RUN));then SAB_PURGE_REMAINING=$((SAB_PURGE_REMAINING+1));continue;fi
      sab_purge_incremental "$wrapper" "$epoch" "$receipt" || return $?
      continue
    fi
    if ((PURGED+SAB_PARTIAL_PURGES>=MAX_PURGES_PER_RUN || BYTES_PURGED+size>MAX_PURGE_BYTES_PER_RUN)); then
      log WARNING "Purge limit reached; retained additional expired payloads for the next run (count limit=$MAX_PURGES_PER_RUN, byte limit=$MAX_PURGE_BYTES_PER_RUN)."; break
    fi
    manifest="$wrapper/.sabnzbd-cleanup-manifest.json"
    if is_true "$DRY_RUN"; then
      PURGE_DETAILS+=("[DRY RUN] Would purge $(jq -r '.jobName // .downloadId' "$manifest"): $wrapper ($count files, $(bytes_human "$size")); manifest retention satisfied.")
      ((PURGED++)) || true; ((BYTES_PURGED+=size)) || true; SAB_PURGED_FILES=$((SAB_PURGED_FILES+count)); continue
    fi
    jq -nc --slurpfile manifest "$manifest" --slurpfile files "$tmp" --arg wrapper "$wrapper" --argjson now "$now" \
      '{event:"purge_intent",at:$now,wrapper:$wrapper,manifest:$manifest[0],files:$files[0]}' >>"$receipt" || return 1
    operation_id=$(ops_operation_begin purge "$wrapper" "" "$receipt") || { log ERROR "Cannot flush purge checkpoint; payload preserved: $wrapper"; return 1; }
    check_mover_guard "immediately before quarantine deletion" || return $?
    if rm -rf --one-file-system -- "$wrapper" && [[ ! -e "$wrapper" && ! -L "$wrapper" ]]; then
      jq -nc --arg wrapper "$wrapper" --argjson now "$(date +%s)" '{event:"purge_verified",at:$now,wrapper:$wrapper}' >>"$receipt" || return 1
      ops_flush_directory "$(dirname -- "$wrapper")" || return 1
      ops_flush_file "$receipt" || return 1
      ops_operation_finish "$operation_id" "Purge verified: wrapper absent; files=$count bytes=$size" || return 1
      PURGE_DETAILS+=("Purged $wrapper: $count files, $(bytes_human "$size"); quarantine age=$(((now-epoch)/86400)) days; deletion verified.")
      ((PURGED++)) || true; ((BYTES_PURGED+=size)) || true; SAB_PURGED_FILES=$((SAB_PURGED_FILES+count))
      log INFO "Purged quarantine: $wrapper; files=$count; bytes=$size; absence verified."
    else ((ERRORS++)) || true; log ERROR "Quarantine deletion incomplete; remaining entries preserved: $wrapper"; return 1; fi
  done <"$candidates"
}

###############################################################################
# MAIN CANDIDATE PROCESSING
###############################################################################

verify_download_cleanup_proof() {
  local owner="$1" id="$2" path="$3" proof="$4" item="$5" rc=0
  verify_arr_import "$owner" "$id" "$path" "$proof" || rc=$?
  if ((rc!=0)) && verify_durable_import_receipt "$owner" "$id" "$path" "$proof" "$item"; then rc=0; fi
  if ((rc==11)); then verify_policy_disposition "$owner" "$id" "$path" "$proof" "$item"; return $?; fi
  return "$rc"
}

# A malformed/missing reference snapshot protects rather than authorizes work.
orphan_reference_query() {
  local rc=0
  jq -e "$@" >/dev/null 2>&1 || rc=$?
  ((rc!=1))
}

# Names are used only to veto cleanup, never to establish ownership or import.
# SAB exposes pending post-processing in history, even when queue says Idle.
orphan_has_live_reference() {
  local path="$1" owner="$2" base stem refs="$TMP_DIR/orphan-reference.json" app_file
  base=${path##*/}; stem="$base"
  case "$stem" in _UNPACK_*) stem=${stem#_UNPACK_};; _FAILED_*) stem=${stem#_FAILED_};; esac
  jq -n --arg path "$path" --arg base "$base" --arg stem "$stem" \
    '{path:$path,base:($base|ascii_downcase),stem:($stem|ascii_downcase)}' >"$refs" || return 0
  # A failed job is still retryable. Only an explicitly Completed row may
  # supply proof; all other statuses (including unknown future ones) protect.
  orphan_reference_query --slurpfile ref "$refs" '
    def matches: . as $j | any([.name,.filename,.nzb_name,.storage,.path][]?;
      type=="string" and (ascii_downcase | .==$ref[0].base or .==$ref[0].stem or
        (split("/")|last)==$ref[0].base or (split("/")|last)==$ref[0].stem));
    any(.[]; ((.status // ""|ascii_downcase)!="completed") and matches)' "$SAB_HISTORY_FILE" >/dev/null && return 0
  orphan_reference_query --slurpfile ref "$refs" '
    any(.queue.slots[]?; any([.filename,.name,.storage,.path][]?;
      type=="string" and (ascii_downcase | .==$ref[0].base or .==$ref[0].stem or
       (split("/")|last)==$ref[0].base or (split("/")|last)==$ref[0].stem)))' "$SAB_QUEUE_FILE" >/dev/null && return 0
  for app_file in "$SONARR_QUEUE_FILE" "$RADARR_QUEUE_FILE"; do
    orphan_reference_query --slurpfile ref "$refs" 'any(.records[]?;
      any([.title,.outputPath][]?; type=="string" and
        (ascii_downcase | .==$ref[0].base or .==$ref[0].stem or
         (split("/")|last)==$ref[0].base or (split("/")|last)==$ref[0].stem)))' "$app_file" >/dev/null && return 0
  done
  return 1
}

orphan_fingerprint() {
  local path="$1" list="$TMP_DIR/orphan-fingerprint.list" unsafe="$TMP_DIR/orphan-unsafe.list"
  [[ -d "$path" && ! -L "$path" ]] || return 1
  find "$path" -xdev ! -type d ! -type f -print0 >"$unsafe" || return 1
  [[ ! -s "$unsafe" ]] || return 1
  # Refuse nested mount points. Record ctime too: archive mtimes may be old.
  find "$path" -xdev -type d -printf '%D\n' >"$unsafe" || return 1
  [[ $(sort -u "$unsafe" | wc -l) == 1 ]] || return 1
  find "$path" -xdev -printf '%P\0%y:%i:%s:%T@:%C@\0' >"$list" || return 1
  sort -z "$list" | sha256sum | awk '{print $1}'
}

# Exact storage paths only: no basename/title inference can authorize a move.
orphan_exact_storage() {
  local item="$1" storage candidate
  storage=$(jq -r '.storage // empty' <<<"$item") || return 1
  [[ "$storage" == /* && "$storage" != *'/../'* && "$storage" != */.. ]] || return 1
  if [[ "$storage" == "$SAB_COMPLETE_ROOT/"* ]]; then candidate="$storage"
  elif [[ -n "$SAB_CONTAINER_COMPLETE_ROOT" && "$storage" == "$SAB_CONTAINER_COMPLETE_ROOT/"* ]]; then
    candidate="$SAB_COMPLETE_ROOT${storage#"$SAB_CONTAINER_COMPLETE_ROOT"}"
  else return 1; fi
  [[ -d "$candidate" && ! -L "$candidate" ]] || return 1
  realpath -e -- "$candidate"
}

orphan_move_guard() {
  local path="$1" proof="$2" expected entries
  expected=$(jq -r '.orphanFingerprint // empty' "$proof") || return 1
  [[ -n "$expected" ]] || return 0
  [[ $(orphan_fingerprint "$path") == "$expected" ]] || return 1
  if jq -e '.proofKind=="empty-orphan"' "$proof" >/dev/null; then
    entries="$TMP_DIR/orphan-final-entries"
    find "$path" -mindepth 1 -print0 >"$entries" || return 1
    [[ ! -s "$entries" ]] || return 1
  fi
}

process_orphan_folders() {
  is_true "$CLEAN_ORPHAN_FOLDERS" || return 0
  local state="$LOG_DIR/orphan-folders.json" work="$TMP_DIR/orphan-state.json" list="$TMP_DIR/orphan-list"
  local owner root path base id fingerprint old first last count now required empty item row mapped matches
  local proof="$TMP_DIR/orphan-proof.json" selected="$TMP_DIR/orphan-selected.json" candidates="$TMP_DIR/orphan-jobs.jsonl" rc size category epoch detail
  [[ ! -L "$state" ]] || return 1
  if [[ -f "$state" ]]; then
    jq -e '.version==1 and (.folders|type=="object") and all(.folders[];
      (.fingerprint|type=="string") and (.firstSeen|type=="number") and
      (.lastCounted|type=="number") and (.observations|type=="number"))' "$state" >/dev/null || return 1
    cp "$state" "$work" || return 1
  else printf '{"version":1,"folders":{}}\n' >"$work"; fi
  now=$(date +%s); required=$ORPHAN_CONFIRMATION_RUNS; ((required>=2)) || required=2
  for owner in Sonarr Radarr; do
    case "$owner" in Sonarr) is_true "$SONARR_ENABLED" || continue; category="$SAB_TV_CATEGORY";; Radarr) is_true "$RADARR_ENABLED" || continue; category="$SAB_MOVIE_CATEGORY";; esac
    root=$(root_for_owner "$owner")
    [[ -d "$root" && ! -L "$root" ]] || return 1
    find "$root" -mindepth 1 -maxdepth 1 -type d \( -name '_UNPACK_*' -o -name '_FAILED_*' -o -name '__ADMIN__' -o -name '_ADMIN_' \) -print0 >"$list" || return 1
    sort -z -o "$list" "$list" || return 1
    while IFS= read -r -d '' path; do
      mc_work_allowed sab || return 21
      ((ORPHANS_SCANNED++)) || true
      base=${path##*/}; id=$(printf '%s' "$path" | sha256sum | awk '{print $1}')
      # A bare admin directory has no payload-job boundary. Never remove it.
      if [[ "$base" == __ADMIN__ || "$base" == _ADMIN_ ]] || orphan_has_live_reference "$path" "$owner"; then
        ((ORPHANS_PROTECTED++)) || true
        jq --arg id "$id" 'del(.folders[$id])' "$work" >"$work.next" && mv "$work.next" "$work" || return 1
        log DEBUG "Working folder protected by SAB/Arr ownership or administrative role: $path"
        continue
      fi
      fingerprint=$(orphan_fingerprint "$path") || { ((ORPHANS_UNVERIFIED++)) || true; log WARNING "Orphan folder inventory unsafe/incomplete; preserved: $path"; continue; }
      old=$(jq -r --arg id "$id" '.folders[$id].fingerprint // ""' "$work")
      if [[ "$old" == "$fingerprint" ]]; then
        first=$(jq -r --arg id "$id" '.folders[$id].firstSeen' "$work")
        last=$(jq -r --arg id "$id" '.folders[$id].lastCounted' "$work")
        count=$(jq -r --arg id "$id" '.folders[$id].observations' "$work")
        if ((now>=last && now-last>=ORPHAN_OBSERVATION_GAP_HOURS*3600)); then count=$((count+1)); last=$now; fi
      else first=$now; last=$now; count=1; fi
      # A backwards clock cannot shorten the hold or count another observation.
      if ((first>now || last>now)); then first=$now; last=$now; count=1; fi
      jq --arg id "$id" --arg path "$path" --arg hash "$fingerprint" --argjson first "$first" --argjson last "$last" --argjson count "$count" \
        '.folders[$id]={path:$path,fingerprint:$hash,firstSeen:$first,lastCounted:$last,observations:$count}' "$work" >"$work.next" && mv "$work.next" "$work" || return 1
      if ((now-first<ORPHAN_MIN_STABLE_HOURS*3600 || count<required)); then ((ORPHANS_WAITING++)) || true; continue; fi
      # Include durable exact-ID import receipts when native history was pruned.
      jq -c --arg base "$base" '.[]|select((.status // ""|ascii_downcase)=="completed" and ((.storage // ""|split("/")|last)==$base))' "$SAB_HISTORY_FILE" >"$candidates" || return 1
      if [[ -f "$IMPORT_RECEIPT_FILE" ]]; then
        arr_import_receipt_document_valid "$IMPORT_RECEIPT_FILE" || { log ERROR 'Import receipt schema invalid; orphan payloads preserved';return 1; }
        jq -c --arg owner "$owner" --arg base "$base" '.receipts[]|select(.app==$owner and .conflict!=true and ((.sab.storage // ""|split("/")|last)==$base))|.sab+{status:"Completed"}' "$IMPORT_RECEIPT_FILE" >>"$candidates" || return 1
      fi
      : >"$selected"; matches=0
      while IFS= read -r row; do
        [[ $(owner_for_category "$(jq -r '.category // ""' <<<"$row")") == "$owner" ]] || continue
        mapped=$(orphan_exact_storage "$row") || continue
        [[ "$mapped" == "$path" ]] || continue
        # Same immutable SAB identity from history/receipt is one candidate.
        jq -c '{nzo_id,name,storage,completed,category}' <<<"$row" >>"$selected" || return 1
      done <"$candidates"
      sort -u "$selected" >"$selected.unique"; matches=$(wc -l <"$selected.unique")
      empty=false
      find "$path" -mindepth 1 -print0 >"$TMP_DIR/orphan-contents" || return 1
      if [[ ! -s "$TMP_DIR/orphan-contents" ]]; then empty=true; fi
      if [[ "$matches" == 1 ]]; then
        item=$(jq -c '.+{status:"Completed"}' "$selected.unique")
        row=$(jq -r '.nzo_id // empty' <<<"$item"); [[ -n "$row" ]] || continue
        epoch=$(sab_completed_epoch "$item")
        if ! [[ "$epoch" =~ ^[0-9]+$ ]] || ((epoch<=0 || now-epoch<MIN_COMPLETED_AGE_HOURS*3600)); then ((ORPHANS_WAITING++)) || true; continue; fi
        if download_is_active_anywhere "$row" || ! verify_download_cleanup_proof "$owner" "$row" "$path" "$proof" "$item" || ! proof_paths_still_valid "$proof"; then
          ((ORPHANS_UNVERIFIED++)) || true; log WARNING "Orphan folder preserved: exact job $row lacks current cleanup proof: $path"; continue
        fi
      elif [[ "$empty" == true && "$matches" == 0 ]]; then
        row="orphan-empty-$id"; epoch=0
        jq -n --arg path "$path" --arg hash "$fingerprint" --argjson count "$count" \
          '{proofKind:"empty-orphan",originalPath:$path,fingerprint:$hash,observations:$count,importedPaths:[]}' >"$proof" || return 1
      else
        ((ORPHANS_UNVERIFIED++)) || true
        log WARNING "Orphan folder preserved: nonempty or ambiguous ownership; no unique exact-path import/disposition proof: $path"
        continue
      fi
      # Refresh history as well as queue: an Idle queue can hide Queued PP jobs.
      fetch_required_state || { log ERROR 'Orphan cleanup stopped: fresh API state unavailable; remaining folders preserved'; return 1; }
      if orphan_has_live_reference "$path" "$owner" || download_is_active_anywhere "$row"; then
        ((ORPHANS_PROTECTED++)) || true
        jq --arg id "$id" 'del(.folders[$id])' "$work" >"$work.next" && mv "$work.next" "$work" || return 1
        continue
      fi
      [[ $(orphan_fingerprint "$path") == "$fingerprint" ]] || { ((ORPHANS_WAITING++)) || true; continue; }
      if [[ "$empty" == true ]]; then
        find "$path" -mindepth 1 -print0 >"$TMP_DIR/orphan-contents" || return 1
        [[ ! -s "$TMP_DIR/orphan-contents" ]] || continue
      else
        verify_download_cleanup_proof "$owner" "$row" "$path" "$proof" "$item" && proof_paths_still_valid "$proof" || continue
      fi
      if ((MAX_QUARANTINES_PER_RUN>0 && QUARANTINED>=MAX_QUARANTINES_PER_RUN)); then break; fi
      jq --arg hash "$fingerprint" '.+{orphanFingerprint:$hash}' "$proof" >"$proof.next" && mv "$proof.next" "$proof" || return 1
      size=$(path_size "$path") || return 1
      quarantine_payload "$owner" "$category" "$row" "$base" "$epoch" "$path" "$size" "$proof"; rc=$?
      if ((rc==20)); then return 20; elif ((rc!=0)); then log ERROR "Orphan quarantine failed; recovery manifest retained: $path"; return 1; fi
      ((ORPHANS_QUARANTINED++)) || true; ((QUARANTINED++)) || true; ((BYTES_QUARANTINED+=size)) || true
      detail="Orphan working folder $(is_true "$DRY_RUN" && printf 'would be quarantined' || printf 'quarantined'): $path -> $LAST_QUARANTINE_DESTINATION; $(bytes_human "$size"); proof=$(jq -r .proofKind "$proof"); $count stable observations and ${ORPHAN_MIN_STABLE_HOURS}h hold passed; fresh SAB/Arr protections passed."
      QUARANTINE_DETAILS+=("$detail")
      log INFO "$detail"
      if ! is_true "$DRY_RUN"; then jq --arg id "$id" 'del(.folders[$id])' "$work" >"$work.next" && mv "$work.next" "$work" || return 1; fi
    done <"$list"
  done
  # Prune only observation records for paths now absent; never touch payloads.
  jq -c '.folders|to_entries[]' "$work" >"$TMP_DIR/orphan-records" || return 1
  while IFS= read -r item; do
    path=$(jq -r '.value.path' <<<"$item"); [[ ! -e "$path" ]] || continue
    id=$(jq -r .key <<<"$item")
    jq --arg id "$id" 'del(.folders[$id])' "$work" >"$work.next" && mv "$work.next" "$work" || return 1
  done <"$TMP_DIR/orphan-records"
  ops_publish_checkpoint "$work" "$state"
}

process_completed_jobs() {
  local item
  local status
  local category
  local owner
  local enabled
  local root
  local download_id
  local job_name
  local completed_epoch
  local age_hours
  local source_path
  local size
  local proof_file
  local proof_status
  local verified_paths
  local source_media
  local quarantine_status

  log "INFO" "Evaluating completed SABnzbd jobs."

  while IFS= read -r item; do
    mc_work_allowed sab || return 21
    ((SCANNED++)) || true

    status="$(jq -r '.status // ""' <<<"$item")"
    [[ "${status,,}" == "completed" ]] || continue
    ((COMPLETED_SCANNED++)) || true

    category="$(jq -r '.category // ""' <<<"$item")"
    owner="$(owner_for_category "$category")"
    [[ -n "$owner" ]] || continue

    case "$owner" in
      Sonarr) enabled="$SONARR_ENABLED" ;;
      Radarr) enabled="$RADARR_ENABLED" ;;
      *) enabled=false ;;
    esac

    if ! is_true "$enabled"; then
      ((SAFETY_SKIPPED++)) || true
      log "INFO" "Skipping $owner category because that integration is disabled: $category"
      continue
    fi

    download_id="$(jq -r '.nzo_id // ""' <<<"$item")"
    job_name="$(jq -r '.name // .nzb_name // "Unknown"' <<<"$item")"

    if [[ -z "$download_id" ]]; then
      ((SAFETY_SKIPPED++)) || true
      log "WARNING" "Skipping completed job without a download ID: $job_name"
      continue
    fi

    completed_epoch="$(sab_completed_epoch "$item")"
    [[ "$completed_epoch" =~ ^[0-9]+$ ]] || completed_epoch=0

    if (( completed_epoch <= 0 )); then
      ((SAFETY_SKIPPED++)) || true
      log "WARNING" "Skipping job with unknown completion time: $job_name"
      continue
    fi

    age_hours=$(( ($(date '+%s') - completed_epoch) / 3600 ))
    (( age_hours >= 0 )) || age_hours=0

    if (( age_hours < MIN_COMPLETED_AGE_HOURS )); then
      ((TOO_YOUNG++)) || true
      continue
    fi

    if download_is_active_anywhere "$download_id"; then
      ((QUEUE_PROTECTED++)) || true
      log "INFO" "Queue-protected completed job: $job_name [$download_id]"
      continue
    fi

    root="$(root_for_owner "$owner")"
    source_path="$(resolve_sab_path "$item" "$root" || true)"

    if [[ -z "$source_path" || ! -e "$source_path" ]]; then
      ((PATH_MISSING++)) || true
      continue
    fi

    if ! path_is_stable "$source_path"; then
      ((PATH_UNSTABLE++)) || true
      log "INFO" "Recently changed path remains protected: $source_path"
      continue
    fi

    proof_file="$TMP_DIR/proof_${SCANNED}.json"
    verify_download_cleanup_proof "$owner" "$download_id" "$source_path" "$proof_file" "$item"
    proof_status=$?

    case "$proof_status" in
      0) ;;
      10|11)
        ((HISTORY_UNPROVEN++)) || true
        log "INFO" "Import history not proven; preserving: $job_name [$download_id]"
        continue
        ;;
      12)
        ((DESTINATION_UNVERIFIED++)) || true
        log "WARNING" "Imported library destination not verified; preserving: $job_name [$download_id]"
        continue
        ;;
      13)
        ((SOURCE_UNACCOUNTED++)) || true
        log "WARNING" "Remaining source media not fully accounted for; preserving: $job_name [$download_id]"
        continue
        ;;
      *)
        ((SAFETY_SKIPPED++)) || true
        log "WARNING" "Unexpected import-proof result $proof_status; preserving: $job_name [$download_id]"
        continue
        ;;
    esac

    # Recheck mutable filesystem state immediately before declaring
    # eligibility. Execute mode also refreshes all live queues so an API
    # snapshot cannot become stale during a long run.
    if ! proof_paths_still_valid "$proof_file"; then
      ((DESTINATION_UNVERIFIED++)) || true
      log "WARNING" "Imported destination changed during validation; preserving: $job_name [$download_id]"
      continue
    fi

    if ! is_true "$DRY_RUN" && ! refresh_active_state; then
      ((ERRORS++)) || true
      ((SAFETY_SKIPPED++)) || true
      log "ERROR" "Unable to refresh active queues; preserving: $job_name [$download_id]"
      continue
    fi

    if download_is_active_anywhere "$download_id" || \
       [[ ! -e "$source_path" || -L "$source_path" ]] || \
       ! path_is_below "$(realpath -- "$source_path" 2>/dev/null || true)" "$root" || \
       ! path_is_stable "$source_path"
    then
      ((QUEUE_PROTECTED++)) || true
      log "INFO" "Candidate changed during validation; preserving: $job_name [$download_id]"
      continue
    fi

    verified_paths="$(jq -r '.verifiedImportedPaths' "$proof_file")"
    source_media="$(jq -r '.remainingSourceMediaFiles' "$proof_file")"
    size="$(path_size "$source_path")"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0

    ((ELIGIBLE++)) || true
    ((BYTES_ELIGIBLE += size)) || true

    log "DEBUG" "------------------------------------------------------------"
    log "DEBUG" "Verified stranded completed download"
    log "DEBUG" "Owner: $owner"
    log "DEBUG" "Category: $category"
    log "DEBUG" "Release: $job_name"
    log "DEBUG" "Download ID: $download_id"
    log "DEBUG" "Completed age: ${age_hours}h"
    log "DEBUG" "Source path: $source_path"
    log "DEBUG" "Source size: $(bytes_human "$size")"
    log "DEBUG" "Verified imported paths: $verified_paths"
    log "DEBUG" "Remaining source media files: $source_media"

    if (( MAX_QUARANTINES_PER_RUN > 0 && QUARANTINED >= MAX_QUARANTINES_PER_RUN )) && ! is_true "$DRY_RUN"; then
      log "WARNING" "Per-run quarantine limit reached; preserving remaining candidates."
      continue
    fi

    quarantine_payload \
      "$owner" \
      "$category" \
      "$download_id" \
      "$job_name" \
      "$completed_epoch" \
      "$source_path" \
      "$size" \
      "$proof_file"
    quarantine_status=$?

    if (( quarantine_status == 0 )); then
      ((QUARANTINED++)) || true
      ((BYTES_QUARANTINED += size)) || true
      QUARANTINE_DETAILS+=("Quarantined [$owner] $job_name: $source_path -> $LAST_QUARANTINE_DESTINATION ($(bytes_human "$size")); $(jq -r 'if .proofKind=="policy-disposition" then "verified policy disposition (not an import)" elif .proofKind=="durable-import-receipt" then "durable exact-file import proof (current paths revalidated)" else "exact import proof" end' "$proof_file") and fresh queue protections passed.")

      if is_true "$DRY_RUN"; then
        log "INFO" "Action: dry-run candidate only"
      else
        log "INFO" "Action: moved to quarantine"
      fi
    elif (( quarantine_status == 20 || quarantine_status == 21 )); then
      return "$quarantine_status"
    else
      ((ERRORS++)) || true
      log "ERROR" "Failed to quarantine: $source_path"
    fi
  done < <(jq -c '.[]?' "$SAB_HISTORY_FILE")
}

###############################################################################
# NOTIFICATION / SUMMARY
###############################################################################

notify_summary() {
  NOTIFICATION_FINALIZED=true
  is_true "$SEND_NOTIFICATIONS" || return 0
  if is_true "$DRY_RUN" && ! is_true "$NOTIFY_DRY_RUN"; then return 0; fi
  # Routine NZB/database backup expiry remains fully logged. It must not
  # create an email by itself; include those details when payload actions,
  # recovery or an exception already justify the daily grouped report. Keep
  # routine backup filenames in the log so they cannot create days of overflow.
  local changed=$((QUARANTINED+PURGED+RECOVERED))
  local warnings="$OPS_ATTENTION_DETAILS" signature previous="" mode="EXECUTE" importance=normal message detail shown=0
  if [[ -s "${OPS_ATTENTION_FILE:-}" ]]; then warnings=$(cat "$OPS_ATTENTION_FILE"); fi
  signature=$(printf '%s' "$BACKUP_CLEANUP_STATUS|$STRANDED_CLEANUP_STATUS|$QUARANTINE_PURGE_STATUS|$warnings" | sha256sum | cut -d ' ' -f1)
  previous=$(jq -r '.lastAttentionSignature // ""' "$OPS_NOTIFICATION_STATE" 2>/dev/null || true)
  local kind=action topic_status=healthy queued_attention=false
  jq -e 'any(.outbox[]?;.topic=="sab-cleanup" and (.kind=="attention" or .kind=="resolved"))' "$OPS_NOTIFICATION_STATE" >/dev/null && queued_attention=true
  if [[ -n "$warnings" || "$ERRORS" != 0 ]]; then topic_status=attention; fi
  ops_set_topic sab-cleanup "$topic_status" "status=$topic_status; backup=$BACKUP_CLEANUP_STATUS; downloads=$STRANDED_CLEANUP_STATUS; purge=$QUARANTINE_PURGE_STATUS; errors=$ERRORS" || return 1
  if (( changed==0 && ERRORS==0 )) && [[ -z "$warnings" && -z "$previous" && "$queued_attention" != true ]]; then return 0; fi
  if ((changed==0)); then if [[ "$topic_status" == attention ]]; then kind=attention; else kind=resolved; fi; fi
  if (( changed==0 )) && [[ -n "$warnings" && "$signature" == "$previous" ]]; then return 0; fi
  is_true "$DRY_RUN" && mode="DRY RUN"
  (( ERRORS==0 )) || importance=alert
  [[ -z "$warnings" || "$importance" == alert ]] || importance=warning
  message="SABnzbd Cleanup v$VERSION | Mode: $mode"$'\n'
  message+="Backup cleanup: $BACKUP_CLEANUP_STATUS; removed $NZB_BACKUPS_REMOVED NZB backup(s), $APP_BACKUPS_REMOVED application backup(s), $(bytes_human "$((NZB_BACKUP_BYTES+APP_BACKUP_BYTES))") eligible."$'\n'
  message+="Completed downloads: $STRANDED_CLEANUP_STATUS; quarantined $QUARANTINED payload(s), $(bytes_human "$BYTES_QUARANTINED")."$'\n'
  message+="Working folders: inspected=$ORPHANS_SCANNED; protected=$ORPHANS_PROTECTED; awaiting stable observations=$ORPHANS_WAITING; unverified=$ORPHANS_UNVERIFIED; quarantined=$ORPHANS_QUARANTINED."$'\n'
  message+="Quarantine purge: $QUARANTINE_PURGE_STATUS; purged $PURGED payload(s), $(bytes_human "$BYTES_PURGED"). Recovered interrupted actions: $RECOVERED."$'\n'
  message+="Purge backlog: expired wrappers remaining=$((SAB_EXPIRED_WRAPPERS-PURGED)); partial wrappers=$SAB_PARTIAL_PURGES; file/budget deferrals=$SAB_PURGE_REMAINING; oldest eligible quarantine epoch=$SAB_OLDEST_EXPIRED_EPOCH."$'\n'
  message+="Protected/skipped: active queue=$QUEUE_PROTECTED; recently changed=$PATH_UNSTABLE; import history unproven=$HISTORY_UNPROVEN; destination unverified=$DESTINATION_UNVERIFIED; source media unaccounted=$SOURCE_UNACCOUNTED; Mover stops=$MOVER_PROTECTED. Errors: $ERRORS."$'\n'
  for detail in "${RECOVERY_DETAILS[@]}" "${QUARANTINE_DETAILS[@]}" "${PURGE_DETAILS[@]}"; do
    message+=$'\n'"- $detail"; shown=$((shown+1))
  done
  if [[ -n "$warnings" ]]; then message+=$'\n\n'"Exceptions and preserved items:"$'\n'"$warnings"; fi
  if [[ -n "$previous" && -z "$warnings" && "$ERRORS" == 0 ]]; then message+=$'\n'"Recovery: previously reported cleanup exceptions are no longer present; configured checks completed."; fi
  ops_notify "$importance" "SABnzbd Cleanup" "Actions, recovery and protected downloads" "$message" sab-cleanup "$kind" || return 1
  if [[ "$OPS_NOTIFICATION_DELIVERED" == true ]]; then
    local tmp="$TMP_DIR/notification-state.json" new_signature=""
    [[ -z "$warnings" && "$ERRORS" == 0 ]] || new_signature="$signature"
    jq --arg signature "$new_signature" '.lastAttentionSignature=$signature' "$OPS_NOTIFICATION_STATE" >"$tmp" && mv -f -- "$tmp" "$OPS_NOTIFICATION_STATE" || return 1
  fi
}

log_detail_list() {
  local heading="$1"
  shift

  (( $# > 0 )) || return 0

  log "INFO" "$heading"

  local detail
  for detail in "$@"; do
    log "INFO" "  - $detail"
  done
}

print_summary() {
  log INFO "SUMMARY | backups=$BACKUP_CLEANUP_STATUS removed=$((NZB_BACKUPS_REMOVED+APP_BACKUPS_REMOVED)) | stranded=$STRANDED_CLEANUP_STATUS quarantined=$QUARANTINED bytes=$BYTES_QUARANTINED | purge=$QUARANTINE_PURGE_STATUS purged=$PURGED bytes=$BYTES_PURGED | orphans=$ORPHANS_SCANNED protected=$ORPHANS_PROTECTED waiting=$ORPHANS_WAITING unverified=$ORPHANS_UNVERIFIED quarantined=$ORPHANS_QUARANTINED | recovered=$RECOVERED errors=$ERRORS runtime=$(runtime)"
  if [[ "${LOG_LEVEL^^}" == DEBUG ]]; then
    log_detail_list "Quarantine details:" "${QUARANTINE_DETAILS[@]}"
    log_detail_list "Purge details:" "${PURGE_DETAILS[@]}"
    log_detail_list "Recovery details:" "${RECOVERY_DETAILS[@]}"
  fi
}

###############################################################################
# ENTRY POINT
###############################################################################

# Shared maintenance protocol. Hold through API/filesystem mutations so appdata
# cannot stop dependencies midway through this run. Export lock protects a
# consistent per-service operational-state snapshot, never bulk application data.

# Explicit operator recovery only. SAB's success response is not sufficient:
# verify that the exact native orphan disappears and an exact job is visible.
recover_sab_orphan() {
  local started
  local name="$1" before="$TMP_DIR/orphan-before.json" after="$TMP_DIR/orphan-after.json"
  local response="$TMP_DIR/orphan-retry.json" queue="$TMP_DIR/orphan-retry-queue.json" history="$TMP_DIR/orphan-retry-history.json"
  [[ -n "$name" && "$name" != . && "$name" != .. && "$name" != */* && "$name" != *\\* && "$name" != *$'\n'* && "$name" != *$'\r'* ]] || { log ERROR 'Expected an exact orphan folder basename, not a path'; return 2; }
  validate_api_key SABnzbd "$SAB_API_KEY" || return 1
  check_mover_guard 'native orphan recovery' || return $?
  sab_get status "$before" skip_dashboard=1 || return 1
  jq -e --arg name "$name" '(.status.folders|type)=="array" and ([.status.folders[]|select(.==$name)]|length)==1' "$before" >/dev/null || { log ERROR "Recovery refused: exact folder is not a native SAB orphan: $name"; return 1; }
  if is_true "$DRY_RUN"; then log INFO "DRY RUN: would request native SAB orphan reconstruction for $name; no files deleted"; return 0; fi
  started=$(date +%s) || return 1
  # No curl retries: a timed-out mutation must be inspected before manual retry.
  sab_get status "$response" name=add_orphan "value=$name" || { log ERROR "Native recovery response unavailable for $name; inspect SAB before retrying"; return 1; }
  jq -e '.status==true' "$response" >/dev/null || { log ERROR "Native SAB orphan retry rejected for $name"; return 1; }
  sab_get status "$after" skip_dashboard=1 && sab_get queue "$queue" limit=1000 && sab_get history "$history" limit=1000 || return 1
  if jq -e --arg name "$name" '(.status.folders|type)=="array" and all(.status.folders[]; .!=$name)' "$after" >/dev/null &&
     jq -en --arg name "$name" --argjson started "$started" --slurpfile q "$queue" --slurpfile h "$history" '
       [($q[0].queue.slots[]?, $h[0].history.slots[]?)
         | select((.filename // .name // "")==$name and (.nzo_id // ""|length)>0)
         | select(([(.time_added // 0),(.completed // 0)] | map(tonumber? // 0)|max)>=$started)
         | .nzo_id] | unique | length==1'  >/dev/null; then
    RECOVERED=$((RECOVERED+1))
    RECOVERY_DETAILS+=("Native SAB orphan reconstructed: $name. Retained NZB/data reused; job registration verified. Download/repair/import completion is monitored separately; no payload was deleted.")
    log INFO "${RECOVERY_DETAILS[-1]}"
    notify_summary
    return 0
  fi
  log ERROR "SAB accepted orphan recovery but exact registration is unverified: $name. No second request or deletion was sent; inspect SAB queue/history."
  return 1
}

main() {
  local operation_status
  local quarantine_ready=false

  CLI_EXECUTE=false
  CLI_OPERATION=""; CLI_WRAPPER=""; CLI_OPERATION_ID=""; CLI_OPERATION_NOTE=""
  parse_args "$@"
  [[ "$CLI_OPERATION" != recover-orphan || "$CLI_EXECUTE" == true ]] || DRY_RUN=true
  if [[ "$CLI_OPERATION" == inspect ]]; then inspect_quarantines; return $?; fi
  if [[ "$CLI_OPERATION" == pending ]]; then ops_list_pending_operations; return $?; fi
    local coordination_rc=0
    acquire_operation_coordination || coordination_rc=$?
    if (( coordination_rc==75 )); then printf 'MAINTENANCE: run deferred for appdata/startup/state export; no mutations performed.\n'; return 0; fi
    (( coordination_rc==0 )) || return 1

  initialize || return 1
  if [[ "$CLI_OPERATION" == recover-orphan ]]; then recover_sab_orphan "$CLI_WRAPPER"; return $?; fi
  if [[ "$CLI_OPERATION" == resolve ]]; then
    ops_resolve_operation "$CLI_OPERATION_ID" "$CLI_OPERATION_NOTE" || return $?
    RECOVERED=1; RECOVERY_DETAILS+=("$OPS_RECOVERY_DETAILS")
    notify_summary; return $?
  fi
  if [[ -n "$CLI_OPERATION" ]]; then
    STRANDED_CLEANUP_STATUS="MANUAL_${CLI_OPERATION^^}"
    validate_stranded_environment || return 1
    prepare_quarantine_environment || return 1
    fetch_required_state || { log ERROR "Cannot validate active queues for restore; payload preserved."; return 1; }
    local restore_id
    restore_id=$(jq -r '.downloadId' "$CLI_WRAPPER/.sabnzbd-cleanup-manifest.json") || return 1
    if jq -e '.importProof.orphanFingerprint|type=="string"' "$CLI_WRAPPER/.sabnzbd-cleanup-manifest.json" >/dev/null &&
       orphan_has_live_reference "$(jq -r .originalPath "$CLI_WRAPPER/.sabnzbd-cleanup-manifest.json")" "$(jq -r .owner "$CLI_WRAPPER/.sabnzbd-cleanup-manifest.json")"; then
      log ERROR 'Restore refused: orphan source path is referenced by current SAB/Arr work.'; return 1
    fi
    if download_is_active_anywhere "$restore_id"; then log ERROR "Restore refused: exact download is active in an Arr/SAB queue ($restore_id)."; return 1; fi
    restore_quarantine_payload "$CLI_WRAPPER"
    return $?
  fi

  log "DEBUG" "Starting SABnzbd cleanup v${VERSION}."
  log "DEBUG" "DRY_RUN=$DRY_RUN | CLEAN_BACKUPS=$CLEAN_BACKUPS | CLEAN_STRANDED_DOWNLOADS=$CLEAN_STRANDED_DOWNLOADS | PURGE_QUARANTINE=$PURGE_QUARANTINE"
  log "DEBUG" "Mover guard enabled: $MOVER_GUARD_ENABLED"

  check_mover_guard "startup"
  operation_status=$?
  if (( operation_status == 20 || operation_status == 21 )); then
      local stop_prefix=MOVER
      if ((operation_status==21));then stop_prefix=BUDGET;fi
    is_true "$CLEAN_BACKUPS" && BACKUP_CLEANUP_STATUS="${stop_prefix}_SKIPPED"
    is_true "$CLEAN_STRANDED_DOWNLOADS" && STRANDED_CLEANUP_STATUS="${stop_prefix}_SKIPPED"
    is_true "$PURGE_QUARANTINE" && QUARANTINE_PURGE_STATUS="${stop_prefix}_SKIPPED"
    print_summary
    return 0
  fi

  if is_true "$CLEAN_BACKUPS"; then
    if validate_backup_environment; then
      BACKUP_CLEANUP_STATUS="RUNNING"
      cleanup_backups
      operation_status=$?

      if (( operation_status == 20 || operation_status == 21 )); then
      local stop_prefix=MOVER
      if ((operation_status==21));then stop_prefix=BUDGET;fi
        BACKUP_CLEANUP_STATUS="${stop_prefix}_STOPPED"
        is_true "$CLEAN_STRANDED_DOWNLOADS" && STRANDED_CLEANUP_STATUS="${stop_prefix}_SKIPPED"
        is_true "$PURGE_QUARANTINE" && QUARANTINE_PURGE_STATUS="${stop_prefix}_SKIPPED"
        print_summary
        return 0
      elif (( operation_status == 0 )); then
        BACKUP_CLEANUP_STATUS="COMPLETED"
      else
        BACKUP_CLEANUP_STATUS="COMPLETED_WITH_ERRORS"
      fi
    else
      BACKUP_CLEANUP_STATUS="SKIPPED_CONFIGURATION"
    fi
  fi

  if is_true "$CLEAN_STRANDED_DOWNLOADS" || is_true "$PURGE_QUARANTINE"; then
    if prepare_quarantine_environment; then
      quarantine_ready=true
      if [[ -z "$SAB_MOVIE_DIR_REAL" && -d "$SAB_MOVIE_DIR" ]]; then SAB_MOVIE_DIR_REAL=$(realpath -- "$SAB_MOVIE_DIR"); fi
      if [[ -z "$SAB_TV_DIR_REAL" && -d "$SAB_TV_DIR" ]]; then SAB_TV_DIR_REAL=$(realpath -- "$SAB_TV_DIR"); fi
      OPS_QUARANTINE_ROOT="$QUARANTINE_DIR_REAL"
      OPS_RESTORE_ROOTS=("$SAB_MOVIE_DIR_REAL" "$SAB_TV_DIR_REAL")
      if ! is_true "$DRY_RUN"; then
        local recovery_status=0
        ops_recover_operations || recovery_status=$?
        RECOVERED=$((RECOVERED+OPS_RECOVERED_COUNT))
        [[ -z "$OPS_RECOVERY_DETAILS" ]] || RECOVERY_DETAILS+=("$OPS_RECOVERY_DETAILS")
        if ((recovery_status!=0)); then ((ERRORS++)) || true; log ERROR "Pending purge/restore operations require review; further payload mutations stopped."; return 1; fi
      fi
      if ! is_true "$DRY_RUN"; then recover_quarantine_preparations || { ((ERRORS++)) || true; log ERROR "Interrupted quarantine recovery incomplete; preserved affected payloads."; }; fi
    else
      is_true "$CLEAN_STRANDED_DOWNLOADS" && STRANDED_CLEANUP_STATUS="SKIPPED_CONFIGURATION"
      is_true "$PURGE_QUARANTINE" && QUARANTINE_PURGE_STATUS="SKIPPED_CONFIGURATION"
    fi
  fi

  if is_true "$CLEAN_STRANDED_DOWNLOADS" && is_true "$quarantine_ready"; then
    log "DEBUG" "Minimum completed age: ${MIN_COMPLETED_AGE_HOURS}h"
    log "DEBUG" "Minimum path stability: ${MIN_PATH_STABLE_HOURS}h"

    if ! validate_stranded_environment; then
      STRANDED_CLEANUP_STATUS="SKIPPED_CONFIGURATION"
    elif ! fetch_required_state; then
      if [[ -f "${MC_TMP:-}/deferred-sab" ]];then
        STRANDED_CLEANUP_STATUS=BUDGET_SKIPPED
        log INFO 'Runtime budget deferred SAB collection; completed-download payloads preserved'
      else
        STRANDED_CLEANUP_STATUS="SKIPPED_API_FAILURE"
        ((ERRORS++)) || true
        log ERROR "Sonarr/Radarr/SAB API collection failed; completed-download payloads were preserved."
      fi
    else
      STRANDED_CLEANUP_STATUS="RUNNING"
      process_completed_jobs
      operation_status=$?
      if ((operation_status==0)); then process_orphan_folders; operation_status=$?; fi

      if (( operation_status == 20 || operation_status == 21 )); then
      local stop_prefix=MOVER
      if ((operation_status==21));then stop_prefix=BUDGET;fi
        STRANDED_CLEANUP_STATUS="${stop_prefix}_STOPPED"
        is_true "$PURGE_QUARANTINE" && QUARANTINE_PURGE_STATUS="${stop_prefix}_SKIPPED"
        print_summary
        return 0
      elif (( operation_status == 0 )); then
        STRANDED_CLEANUP_STATUS="COMPLETED"
      else
        ((ERRORS++)) || true
        STRANDED_CLEANUP_STATUS="COMPLETED_WITH_ERRORS"
        log "ERROR" "Completed-job processing failed with status $operation_status."
      fi
    fi
  fi

  if is_true "$PURGE_QUARANTINE" && is_true "$quarantine_ready"; then
    log "DEBUG" "Quarantine retention: ${QUARANTINE_RETENTION_DAYS}d"
    QUARANTINE_PURGE_STATUS="RUNNING"
    purge_quarantine
    operation_status=$?

    if (( operation_status == 20 || operation_status == 21 )); then
      local stop_prefix=MOVER
      if ((operation_status==21));then stop_prefix=BUDGET;fi
      QUARANTINE_PURGE_STATUS="${stop_prefix}_STOPPED"
      print_summary
      return 0
    elif (( operation_status == 0 )); then
      QUARANTINE_PURGE_STATUS="COMPLETED"
    else
      ((ERRORS++)) || true
      QUARANTINE_PURGE_STATUS="FAILED"
      log "ERROR" "Quarantine purge failed with status $operation_status."
    fi
  fi

  print_summary
  notify_summary

  (( ERRORS == 0 ))
}


main "$@"
mc_finish_module sab "$?" "$@"
)

# MODULE: QUARANTINE -- isolated policy, state and traps.
mc_quarantine() (
set -uo pipefail
umask 077

readonly SCRIPT_VERSION="1.6.0"
readonly REQUIRED_PURGE_CONFIRMATION="DELETE_EXPIRED_QUARANTINE"

###############################################################################
# CONFIGURATION
###############################################################################

QUARANTINE_ROOT="/mnt/user/media/bin"
MOVIES_ROOT="/mnt/user/media/movies"
SERIES_ROOT="/mnt/user/media/series"

RETENTION_DAYS=15
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
# Oversized runs are drained by regular-file entries within the same byte cap.
# Per-file intents/receipts make interrupted partial runs resumable.
MAX_PURGE_FILES_PER_EXECUTION=250
MAX_PURGE_BYTES_PER_EXECUTION=$((10 * 1024 * 1024 * 1024))

# Purging through /mnt/user is safe during parity checks, but defer while Mover
# is actively changing user-share placement.
DEFER_PURGE_WHILE_MOVER=true
QUARANTINE_COORDINATION_LOCK="/tmp/arr_metadata_quarantine.lock"
# Newly changed runs are protected even when their run ID is old.
MIN_RUN_IDLE_HOURS=24

LOG_DIR="${MC_ROOT}/quarantine"
LOG_FILE="$MC_ROOT/media-cleanup.log"
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

STATUS_DIR="${MC_ROOT}/quarantine"
NOTIFY_BIN="${MC_PROXY:-$MC_NOTIFY_BIN}"
LOCK_FILE="/run/media_cleanup-quarantine.lock"

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
PARTIALLY_PURGED_RUNS=0
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
OPS_SCRIPT_VERSION="1.6.0"
OPS_RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
OPS_ATTENTION_DETAILS=""
OPS_ATTENTION_FILE=""
OPS_LOG_BYTES=""

# Shared operational logging convention, embedded to keep User Scripts standalone.
# INFO records actions, warnings and one completion summary. DEBUG adds routine
# progress. Numbered backups expire by size, count and age; receipts are separate.



# Durable daily outbox. Unsent chunks survive failures, daily limits and caps.
# Flush only destructive-operation checkpoints and their receipts, never every
# log line. Flush the containing directory after atomic replacement too.








# Unfinished purge/restore operations outlive processes and daily log rotation.



ops_operation_begin() {
    mc_work_allowed quarantine || return 75
    local kind="$1" source="$2" destination="$3" proof="$4" identity="" id tmp
    ops_operation_state || return 1
    ops_operation_paths_valid "$source" "$destination" || { ops_log ERROR "Unsafe operation paths; checkpoint and mutation refused: $source -> $destination"; return 1; }
    id=$(printf '%s' "$kind|$source|$destination" | sha256sum | cut -d ' ' -f1)
    if jq -e --arg id "$id" '.operations[$id]!=null' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null; then
        # A partial purge resumes only after the caller's normal retention,
        # inventory, Mover and byte-limit checks. Its original evidence stays.
        [[ "$kind" == purge || "$kind" == purge-file ]] || { ops_log ERROR "Restore already pending; reconciliation required ($id)."; return 1; }
        printf '%s' "$id"; return 0
    fi
    [[ -f "$proof" ]] || return 1
    ops_flush_file "$proof" || return 1
    ops_flush_directory "$(dirname -- "$proof")" || return 1
    if [[ "$kind" == restore ]]; then identity=$(stat -c '%d:%i:%F:%s' -- "$source") || return 1; fi
    if [[ "$kind" == purge-file ]]; then identity=$(stat -c '%d:%i:%f:%s:%Y:%Z' -- "$source") || return 1; fi
    tmp=$(mktemp "$LOG_DIR/.operation-intent.XXXXXX") || return 1
    jq --arg id "$id" --arg kind "$kind" --arg source "$source" --arg destination "$destination" \
      --arg proof "$proof" --arg identity "$identity" --argjson now "$(date +%s)" \
      '.operations[$id]={kind:$kind,source:$source,destination:$destination,proof:$proof,identity:$identity,startedAt:$now}' \
      "$OPS_PENDING_OPERATIONS_FILE" >"$tmp" && ops_publish_checkpoint "$tmp" "$OPS_PENDING_OPERATIONS_FILE" || return 1
    printf '%s' "$id"
}



ops_recover_operations() {
    local list entry id kind source destination identity actual failed=0
    OPS_RECOVERY_DETAILS=""; OPS_RECOVERED_COUNT=0
    ops_operation_state || return 1
    list=$(mktemp "$LOG_DIR/.operation-recovery.XXXXXX") || return 1
    jq -c '.operations|to_entries[]' "$OPS_PENDING_OPERATIONS_FILE" >"$list" || return 1
    while IFS= read -r entry; do
        id=$(jq -r '.key' <<<"$entry"); kind=$(jq -r '.value.kind' <<<"$entry")
        source=$(jq -r '.value.source' <<<"$entry"); destination=$(jq -r '.value.destination' <<<"$entry")
        ops_operation_paths_valid "$source" "$destination" || { ops_log ERROR "Unsafe pending operation preserved: $id"; failed=$((failed+1)); continue; }
        if [[ "$kind" == purge-file && -z "$destination" ]]; then
            if [[ ! -e "$source" && ! -L "$source" ]]; then
                ops_operation_finish "$id" 'Recovered incremental purge: file absence confirmed; no repeated deletion' || return 1
                OPS_RECOVERY_DETAILS+="- Reconciled an interrupted incremental purge: $source is absent; no new unlink was needed."$'\n'
                OPS_RECOVERED_COUNT=$((OPS_RECOVERED_COUNT+1))
            elif [[ -f "$source" && ! -L "$source" && "$(stat -c '%d:%i:%f:%s:%Y:%Z' -- "$source")" == "$(jq -r '.value.identity' <<<"$entry")" ]]; then
                ops_log WARNING "Interrupted file purge retained for normal retention/idle/Mover/limit reevaluation: $source"
            else
                ops_log ERROR "Interrupted file purge identity changed; preserved: $source"; failed=$((failed+1))
            fi
        elif [[ "$kind" == purge && -z "$destination" ]]; then
            if [[ ! -e "$source" && ! -L "$source" ]]; then
                ops_operation_finish "$id" "Reconciled interrupted purge: directory absence confirmed; no new deletion performed" || return 1
                OPS_RECOVERY_DETAILS+="- Reconciled interrupted purge: $source is absent. No new deletion was needed. Operation $id."$'\n'
                OPS_RECOVERED_COUNT=$((OPS_RECOVERED_COUNT+1))
            elif [[ -d "$source" && ! -L "$source" ]]; then
                ops_log WARNING "Incomplete purge preserved: $source; remaining files will be retried only after normal retention, idle, Mover and execution-limit checks. Operation $id."
            else
                ops_log ERROR "Interrupted purge source changed type; preserved for review: $source (operation $id)"; failed=$((failed+1))
            fi
        elif [[ "$kind" == restore && -n "$destination" ]]; then
            if [[ ! -e "$source" && ! -L "$source" && -e "$destination" && ! -L "$destination" ]]; then
                identity=$(jq -r '.value.identity' <<<"$entry")
                actual=$(stat -c '%d:%i:%F:%s' -- "$destination") || actual=""
                if [[ -n "$identity" && "$actual" == "$identity" ]]; then
                    ops_operation_finish "$id" "Reconciled interrupted restore: original object identity verified at destination" || return 1
                    OPS_RECOVERY_DETAILS+="- Recovered interrupted restore: $source -> $destination. Original object identity matched; no overwrite or repeat move performed."$'\n'
                    OPS_RECOVERED_COUNT=$((OPS_RECOVERED_COUNT+1))
                else
                    ops_log ERROR "Restore destination exists but identity cannot be proven (possible cross-filesystem copy); destination preserved: $destination. Review operation $id with --pending-operations; use --resolve-operation only after verification."
                    failed=$((failed+1))
                fi
            elif [[ -e "$source" && ! -e "$destination" && ! -L "$destination" ]]; then
                ops_operation_finish "$id" "Interrupted restore was not applied; original source preserved for explicit retry" || return 1
                OPS_RECOVERY_DETAILS+="- Restore did not occur: $source remains quarantined; $destination was not created. An explicit restore may be retried."$'\n'
                OPS_RECOVERED_COUNT=$((OPS_RECOVERED_COUNT+1))
            else
                ops_log ERROR "Ambiguous interrupted restore: source=$source; destination=$destination. Both locations preserved; operation=$id."
                failed=$((failed+1))
            fi
        else ops_log ERROR "Unknown checkpoint type preserved for review: $id"; failed=$((failed+1)); fi
    done <"$list"
    rm -f -- "$list"
    # Keep the small recovery audit for one year, independently of main logs.
    if [[ -s "$OPS_OPERATION_AUDIT_FILE" ]]; then
        local retained
        retained=$(mktemp "$LOG_DIR/.operation-audit.XXXXXX") || return 1
        jq -c --argjson cutoff "$(( $(date +%s)-365*86400 ))" 'select(.at >= $cutoff)' "$OPS_OPERATION_AUDIT_FILE" >"$retained" &&
          ops_publish_checkpoint "$retained" "$OPS_OPERATION_AUDIT_FILE" || return 1
    fi
    ((failed==0))
}



rotate_log() {
    ops_initialize_log
}

notify_unraid() {
    local importance="$1" description="$2" message="$3"
    NOTIFICATION_ATTEMPTED=true
    local kind=action
    case "$description" in *review*|*failed*) kind=attention;; *recovered*) kind=resolved;; esac
    ops_notify "$importance" "Quarantine Lifecycle v$SCRIPT_VERSION" "$description" "$message" lifecycle "$kind"
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
    if [[ -z "$previous" ]] && ! jq -e 'any(.outbox[]?;.topic=="lifecycle" and (.kind=="attention" or .kind=="resolved"))' "$NOTIFICATION_STATE_FILE" >/dev/null; then return 0; fi

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
    ops_publish_checkpoint "$tmp" "$PURGE_RECEIPT_FILE"
}

append_purge_receipt_block() {
    local block="$1" tmp

    [[ -f "$PURGE_RECEIPT_FILE" && -f "$block" ]] || return 1
    tmp="$(mktemp "${PURGE_RECEIPT_DIR}/.purge-receipt.XXXXXX")" || return 1
    if ! cat -- "$PURGE_RECEIPT_FILE" "$block" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    ops_publish_checkpoint "$tmp" "$PURGE_RECEIPT_FILE"
}

prune_purge_receipts() {
    local receipt removed=0

    mkdir -p -- "$PURGE_RECEIPT_DIR" 2>/dev/null || return 1
    while IFS= read -r -d '' receipt; do
        [[ "$receipt" == "$PURGE_RECEIPT_DIR"/purge-*.tsv || "$receipt" == "$PURGE_RECEIPT_DIR"/restore-*.json ]] || continue
        ops_receipt_in_use "$receipt" && continue
        rm -f -- "$receipt" || return 1
        removed=$((removed + 1))
    done < <(
        find "$PURGE_RECEIPT_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -type f \
            \( -name 'purge-*.tsv' -o -name 'restore-*.json' \) \
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
        mv -f -- "$tmp" "${STATUS_DIR}/latest-run.json"
        RECEIPT_WRITTEN=1
    else
        rm -f -- "$tmp"
    fi
}

cleanup() {
    local rc=$?
    if (( rc!=0 )) && [[ "$NOTIFICATION_ATTEMPTED" != true && -d "$LOG_DIR" ]]; then
        notify_unraid alert "Quarantine lifecycle failed" \
          "Status: $RESULT_STATUS; exit=$rc"$'\n'"$RESULT_SUMMARY"$'\n'"Completed actions: purged $PURGED_RUNS run(s), $PURGED_FILES file(s), $(human_bytes "$PURGED_BYTES")."$'\n'"${OPS_ATTENTION_DETAILS:0:6000}"$'\n'"Checkpoint recovery results:"$'\n'"${OPS_RECOVERY_DETAILS:-No checkpoint recovery completed.}" || true
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
        touch tr wc sync; do
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
    OPS_QUARANTINE_ROOT="$QUARANTINE_REAL"
    OPS_RESTORE_ROOTS=("$MOVIES_REAL" "$SERIES_REAL")
    mkdir -p -- "$PURGE_RECEIPT_DIR" || return 1
    local proof="$PURGE_RECEIPT_DIR/restore-${OPS_RUN_ID}.json" operation_id
    jq -n --arg source "$source" --arg destination "$destination" --arg at "$(date -Iseconds)" \
      '{event:"restore_intent",source:$source,destination:$destination,at:$at}' >"$proof" || return 1
    operation_id=$(ops_operation_begin restore "$source" "$destination" "$proof") || { log ERROR "Cannot flush restore intent; source preserved."; return 1; }
    mkdir -p -- "$(dirname "$destination")" || return 1
    ops_operation_paths_valid "$source" "$destination" || return 1
    mv -T -n -- "$source" "$destination" || return 1
    [[ ! -e "$source" && ! -L "$source" && ( -e "$destination" || -L "$destination" ) ]] || { log ERROR "Restore did not complete; existing objects preserved and checkpoint retained."; return 1; }
    ops_flush_move "$source" "$destination" || return 1
    ops_operation_finish "$operation_id" "Restore verified by successful move, source absence and destination presence" || return 1
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

# Oversized runs drain by verified regular-file entries. Every unlink has a
# durable intent. No recursive delete is used for a partial run; special files,
# changed objects and single files above the budget remain protected.
purge_run_incrementally() {
    local run="$1" run_id="$2" age_days="$3" list="$RUNTIME_DIR/chunk-files.list"
    local selected="$RUNTIME_DIR/chunk-selected.list" manifest="$RUNTIME_DIR/chunk-receipt.tsv"
    local relative source canonical identity dev inode mode bytes mtime ctime current op_id
    local chosen_files=0 chosen_bytes=0 completed_files=0 completed_bytes=0 before_files="$PURGED_FILES" entry
    local file_budget=$((MAX_PURGE_FILES_PER_EXECUTION-PURGED_FILES))
    (( file_budget>0 )) || { PURGE_LIMIT_REACHED=1; return 0; }
    find "$run" -xdev -type f -printf '%P\0' >"$list" || return 1
    sort -z "$list" -o "$list" || return 1
    : >"$selected"; : >"$manifest"
    while IFS= read -r -d '' relative; do
        valid_relative_path "$relative" || return 1
        case "$relative" in movies/*|series/*) ;; *) return 1;; esac
        source="$run/$relative"
        canonical=$(realpath -e -- "$source") || return 1
        [[ "$canonical" == "$source" && -f "$source" && ! -L "$source" ]] || return 1
        identity=$(stat -c '%d:%i:%f:%s:%Y:%Z' -- "$source") || return 1
        IFS=: read -r dev inode mode bytes mtime ctime <<<"$identity"
        [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
        if (( PURGED_BYTES+chosen_bytes+bytes>MAX_PURGE_BYTES_PER_EXECUTION )); then
            PURGE_LIMIT_REACHED=1
            continue
        fi
        (( chosen_files<file_budget )) || { PURGE_LIMIT_REACHED=1; break; }
        printf '%s\0%s\0' "$relative" "$identity" >>"$selected" || return 1
        printf 'FILE_INTENT\t%s\t%s\t%s\t%s\t%s\tf\t%s\trecorded_before_delete\tidentity=%s\n' \
          "$(date -Iseconds)" "$run_id" "$age_days" "${relative%%/*}" "$(escape_tsv_field "${relative#*/}")" "$bytes" "$identity" >>"$manifest" || return 1
        chosen_files=$((chosen_files+1)); chosen_bytes=$((chosen_bytes+bytes))
    done <"$list"
    if ((chosen_files==0)); then
        AUDIT_ATTENTION_DETAILS+="Run $run_id remains: no regular file fits the remaining byte/file budget, or only special entries remain."$'\n'
        return 0
    fi
    initialize_purge_receipt && append_purge_receipt_block "$manifest" || return 1
    while IFS= read -r -d '' relative && IFS= read -r -d '' identity; do
        mc_work_allowed quarantine || { PURGE_DEFERRED_REASON='Overall cleanup runtime budget reached';break; }
        if [[ "$DEFER_PURGE_WHILE_MOVER" == true ]] && unraid_mover_running; then
            PURGE_DEFERRED_REASON="Unraid Mover became active during incremental purge"; break
        fi
        validate_managed_run_path "$run" "$run_id" || return 1
        source="$run/$relative"; current=$(stat -c '%d:%i:%f:%s:%Y:%Z' -- "$source") || return 1
        [[ "$current" == "$identity" && -f "$source" && ! -L "$source" ]] || { log ERROR "Incremental purge object changed; preserved: $source"; return 1; }
        [[ "$(realpath -e -- "$source")" == "$source" ]] || return 1
        # A pre-existing interrupted intent must describe this same object.
        op_id=$(ops_operation_begin purge-file "$source" '' "$PURGE_RECEIPT_FILE") || return 1
        entry=$(jq -r --arg id "$op_id" '.operations[$id].identity // ""' "$OPS_PENDING_OPERATIONS_FILE")
        [[ "$entry" == "$identity" ]] || { log ERROR "Pending file identity changed; unlink refused: $source"; return 1; }
        [[ "$(stat -c '%d:%i:%f:%s:%Y:%Z' -- "$source")" == "$identity" ]] || return 1
        IFS=: read -r dev inode mode bytes mtime ctime <<<"$identity"
        rm -f -- "$source" || return 1
        [[ ! -e "$source" && ! -L "$source" ]] || return 1
        ops_flush_directory "$(dirname -- "$source")" || return 1
        PURGED_FILES=$((PURGED_FILES+1)); PURGED_BYTES=$((PURGED_BYTES+bytes))
        completed_files=$((completed_files+1)); completed_bytes=$((completed_bytes+bytes))
        ops_operation_finish "$op_id" "Incremental purge verified; file absent; bytes=$bytes; run=$run_id" || return 1
        printf '%s\t%s\t%s\n' "$bytes" "$run_id" "$(escape_tsv_field "$relative")" >>"$PURGE_FILE_CANDIDATES" || return 1
        printf 'FILE_RESULT\t%s\t%s\t%s\t%s\t%s\tf\t%s\tpurged_and_absence_verified\t-\n' \
          "$(date -Iseconds)" "$run_id" "$age_days" "${relative%%/*}" "$(escape_tsv_field "${relative#*/}")" "$bytes" >"$manifest" || return 1
        append_purge_receipt_block "$manifest" || return 1
    done <"$selected"
    # Removing empty directories does not discard unlisted content. Defer
    # even rmdir when Mover starts after the last unlink.
    if [[ "$DEFER_PURGE_WHILE_MOVER" != true ]] || ! unraid_mover_running; then
        find "$run" -xdev -depth -type d -print0 >"$list" || return 1
        while IFS= read -r -d '' source; do rmdir -- "$source" 2>/dev/null || true; done <"$list"
    else PURGE_DEFERRED_REASON="Unraid Mover became active before empty-directory cleanup"; fi
    if [[ ! -e "$run" ]]; then
        PURGED_RUNS=$((PURGED_RUNS+1))
        ops_flush_directory "$QUARANTINE_REAL" || return 1
    elif (( PURGED_FILES>before_files )); then
        PARTIALLY_PURGED_RUNS=$((PARTIALLY_PURGED_RUNS+1)); PURGE_LIMIT_REACHED=1
    fi
    PURGE_RUN_DETAILS+="- $run_id (${age_days} days): incremental purge removed $completed_files file(s), $(human_bytes "$completed_bytes"); remaining entries are retained for a later eligible run."$'\n'
}

purge_expired() {
    local run run_id created age_days files bytes operation_id
    OPS_QUARANTINE_ROOT="$QUARANTINE_REAL"
    OPS_RESTORE_ROOTS=("$MOVIES_REAL" "$SERIES_REAL")

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
        mc_work_allowed quarantine || { PURGE_DEFERRED_REASON='Overall cleanup runtime budget reached';break; }
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

        if ((PURGED_RUNS+PARTIALLY_PURGED_RUNS>=MAX_PURGE_RUNS_PER_EXECUTION || PURGED_FILES>=MAX_PURGE_FILES_PER_EXECUTION)); then
            PURGE_LIMIT_REACHED=1; break
        fi

        if (( MIN_RUN_IDLE_HOURS>0 )); then
            local idle_check="${RUNTIME_DIR}/idle-check.list"
            find "$run" -xdev -cmin "-$((MIN_RUN_IDLE_HOURS*60))" -print -quit >"$idle_check" || return 1
            if [[ -s "$idle_check" ]]; then
                log WARN "Recently changed run $run_id was preserved; retention alone does not authorize purge."
                continue
            fi
        fi
        if ((PURGED_BYTES+bytes>MAX_PURGE_BYTES_PER_EXECUTION || PURGED_FILES+files>MAX_PURGE_FILES_PER_EXECUTION)); then
            purge_run_incrementally "$run" "$run_id" "$age_days" || return 1
            continue
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
        operation_id=$(ops_operation_begin purge "$run" "" "$PURGE_RECEIPT_FILE") || { log ERROR "Cannot flush purge checkpoint; preserved $run_id"; return 1; }
        log INFO "Purging expired quarantine run: $run_id; files=$files; bytes=$bytes"
        rm -rf --one-file-system -- "$run" || {
            log ERROR "Failed to purge: $run"
            return 1
        }
        [[ ! -e "$run" && ! -L "$run" ]] || {
            log ERROR "Expired quarantine run still exists after purge: $run_id"
            return 1
        }
        ops_flush_directory "$QUARANTINE_REAL" || return 1
        if ! record_run_purge_result \
            "$run_id" "$age_days" "$files" "$bytes"; then
            log ERROR "Run $run_id was purged, but its verified result could not be appended to $PURGE_RECEIPT_FILE"
            return 1
        fi
        ops_operation_finish "$operation_id" "Purge verified: source directory absent; files=$files bytes=$bytes; receipt=$PURGE_RECEIPT_FILE" || return 1
        if ! cat -- "${RUNTIME_DIR}/${run_id}.candidates.tsv" \
            >>"$PURGE_FILE_CANDIDATES"; then
            log WARN "Run $run_id was purged, but its largest-file notification summary could not be prepared; the full receipt remains available"
        fi
        PURGED_RUNS=$((PURGED_RUNS + 1))
        PURGED_FILES=$((PURGED_FILES + files))
        PURGED_BYTES=$((PURGED_BYTES + bytes))
        PURGE_RUN_DETAILS+="- ${run_id} (${age_days} days): ${files} file(s), $(human_bytes "$bytes"); movies=${INVENTORY_MOVIE_FILES}, series=${INVENTORY_SERIES_FILES}"$'\n'
    done < <(awk -F '\t' 'NR>1 && $6=="true" {printf "%s%c", $1, 0}' "$INDEX_FILE" | sort -z | while IFS= read -r -d '' id; do printf '%s\0' "$QUARANTINE_REAL/$id"; done)

    if (( PURGED_FILES > 0 || PURGED_RUNS > 0 )); then
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
        RESULT_SUMMARY="Purged $PURGED_RUNS complete run(s), partially drained $PARTIALLY_PURGED_RUNS run(s), $PURGED_FILES file(s), and $(human_bytes "$PURGED_BYTES"); retained expired=$REMAINING_EXPIRED_RUNS, unmanaged=$UNMANAGED_ENTRIES, scan errors=$SCAN_ERRORS. Safety deferrals and limits are included in this report."
    else
        RESULT_STATUS="OK"
        RESULT_SUMMARY="Purged $PURGED_RUNS complete run(s), partially drained $PARTIALLY_PURGED_RUNS run(s), $PURGED_FILES file(s), and $(human_bytes "$PURGED_BYTES")"
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
    detail+=$'\n'"${OPS_RECOVERY_DETAILS:-}"
    local pending_count=0
    if [[ -f "${OPS_PENDING_OPERATIONS_FILE:-$LOG_DIR/pending-operations.json}" ]]; then
        pending_count=$(jq '.operations|length' "${OPS_PENDING_OPERATIONS_FILE:-$LOG_DIR/pending-operations.json}") || return 1
    fi
    if ((pending_count>0)); then signature+="pending-operations;"; detail+=$'\n'"Pending purge/restore checkpoints: $pending_count. Remaining data is preserved until normal safeguards permit completion or an operator verifies the outcome."; fi
    local current_topic=healthy
    [[ -z "$signature" ]] || current_topic=attention
    ops_set_topic lifecycle "$current_topic" "status=$current_topic; purged=$PURGED_RUNS runs/$PURGED_FILES files; expired retained=$REMAINING_EXPIRED_RUNS; unmanaged=$UNMANAGED_ENTRIES; scan errors=$SCAN_ERRORS" || return 1

    if (( PURGED_FILES > 0 || PURGED_RUNS > 0 || ${OPS_RECOVERED_COUNT:-0}>0 )); then
        if ((PURGED_FILES>0 || PURGED_RUNS>0)); then detail="$(build_purge_detail)"$'\n\n'"$detail"; fi
        [[ -z "$signature" ]] && importance="normal"
        local action_description="Quarantine recovery completed"
        ((PURGED_FILES==0 && PURGED_RUNS==0)) || action_description="Quarantine purge completed"
        notify_unraid "$importance" "$action_description" \
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
    if [[ "$MC_DRY_RUN" == true ]]; then
      [[ "$mode" != purge ]] || mode=audit
      [[ "$mode" != restore ]] || { printf 'Restore refused in preview mode.\n' >&2;return 2; }
    fi
    trap cleanup EXIT
    case "$mode" in
      --help|-h) printf '%s\n' 'Usage: /bin/bash SCRIPT quarantine [audit|purge|restore RUN_ID movies|series RELATIVE_PATH|--version]' 'audit changes no quarantine payload. purge defaults to scheduled retention with per-run limits.' 'restore never overwrites an existing path. All modes coordinate with the Arr producer.' '--pending-operations lists unfinished checkpoints; --resolve-operation ID "verified outcome" records an operator decision without moving/deleting payloads.'; RESULT_STATUS=OK; RESULT_SUMMARY="Help displayed"; trap - EXIT; return 0 ;;
      --version) printf 'quarantine_lifecycle.sh %s\n' "$SCRIPT_VERSION"; trap - EXIT; return 0 ;;
      --pending-operations) local list_status=0; ops_list_pending_operations || list_status=$?; trap - EXIT; return "$list_status" ;;
      audit|purge|restore|--resolve-operation) ;;
      *) printf 'Unknown mode: %s; use --help.\n' "$mode" >&2; trap - EXIT; return 2 ;;
    esac
    if [[ "$mode" == restore && $# != 4 ]]; then printf 'restore requires RUN_ID movies|series RELATIVE_PATH.\n' >&2; trap - EXIT; return 2; fi
    if [[ "$mode" == --resolve-operation && $# -lt 3 ]]; then printf 'resolution requires an exact operation ID and verified outcome.\n' >&2; trap - EXIT; return 2; fi
    local platform_version
    if [[ "$mode" != audit && -r "${UNRAID_VERSION_FILE:-/etc/unraid-version}" ]]; then
        platform_version=$(sed -n 's/^version="\([^"]*\)"/\1/p' "${UNRAID_VERSION_FILE:-/etc/unraid-version}")
        if [[ "$platform_version" != 7.* ]]; then RESULT_STATUS=DEFERRED; RESULT_SUMMARY='Unvalidated Unraid major; mutations deferred'; printf 'Unvalidated Unraid major; purge/restore deferred.\n'; trap - EXIT; return 0; fi
    fi
    exec {STATE_EXPORT_FD}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || return 1
    if ! flock -s -n "$STATE_EXPORT_FD"; then RESULT_STATUS=DEFERRED; RESULT_SUMMARY='Operational-state export active'; printf 'Operational-state export active; lifecycle deferred without changes.\n'; trap - EXIT; return 0; fi
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then RESULT_STATUS=DEFERRED; RESULT_SUMMARY="Another lifecycle run holds the lock"; trap - EXIT; return 0; fi
    exec 8>"$QUARANTINE_COORDINATION_LOCK"
    if ! flock -n 8; then RESULT_STATUS=DEFERRED; RESULT_SUMMARY="Quarantine producer is active; payloads preserved"; trap - EXIT; printf '%s\n' "$RESULT_SUMMARY"; return 0; fi
    if ! mountpoint -q /mnt/vault || ! mountpoint -q /mnt/user; then
        RESULT_SUMMARY="Required mounts are unavailable: /mnt/vault and/or /mnt/user; no purge or restore was attempted"
        printf '%s\n' "$RESULT_SUMMARY" >&2
        if [[ -x "$NOTIFY_BIN" ]]; then usr_ops_notify "$NOTIFY_BIN" -i alert -s "Quarantine Lifecycle" -d "Required storage unavailable" -m "$RESULT_SUMMARY" >/dev/null 2>&1 || true; NOTIFICATION_ATTEMPTED=true; fi
        return 1
    fi
    mkdir -p -- "$LOG_DIR" || return 1
    rotate_log || return 1
    touch "$LOG_FILE" || return 1
    validate_configuration || return 1
    [[ "$MAX_PURGE_FILES_PER_EXECUTION" =~ ^[1-9][0-9]*$ ]] || { log ERROR 'Invalid per-execution purge file limit'; return 1; }
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
    OPS_QUARANTINE_ROOT="$QUARANTINE_REAL"
    OPS_RESTORE_ROOTS=("$MOVIES_REAL" "$SERIES_REAL")
    if [[ "$mode" == --resolve-operation ]]; then
        ops_resolve_operation "${2:-}" "${*:3}" || return $?
        RESULT_STATUS=OK; RESULT_SUMMARY="Operator resolution recorded; no payload changes performed"
        notify_unraid normal "Operation resolution recorded" "$OPS_RECOVERY_DETAILS"
        return $?
    fi
    # An audit reports pending work but never clears or resumes an operation.
    if [[ "$mode" != audit ]]; then ops_recover_operations || { log ERROR "Pending purge/restore operations require review; new mutations stopped."; return 1; }; fi

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
                if (( PURGED_FILES > 0 || PURGED_RUNS > 0 )); then
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
                log ERROR "Usage: $0 quarantine restore RUN_ID movies|series RELATIVE_PATH"
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


main "$@"
mc_finish_module quarantine "$?" "$@"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then mc_main "$@"; fi
