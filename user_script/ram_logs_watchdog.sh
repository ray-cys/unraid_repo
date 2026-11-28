#!/bin/bash
# Release version: bump for every deployed code change; descriptions stay user-owned.
readonly SCRIPT_VERSION="3.3.3"
# Version lookup exits before logging, locks, state, Docker or network activity.
if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == --version ]]; then
    printf 'ram_logs_watchdog.sh %s\n' "$SCRIPT_VERSION"
    exit 0
fi
# BEGIN CURRENT OPERATIONAL PURPOSE
# PURPOSE: Keep dedicated RAM-log storage ready and preserve bounded recent logs on persistent
#   storage for diagnosis.
# WORKFLOW: Check RAM-log readiness and capacity, checkpoint logs to vault, verify retained
#   archives periodically, and use the clean-stop hook for a final archive. After power loss,
#   preserve the last completed checkpoint.
# COORDINATION: Boot preparation supports applications using RAM-log mounts; backup_health_audit
#   and host_health_watchdog independently check checkpoint/execution freshness.
# LIMITS: Keep only the configured latest two archives. Sudden power loss cannot capture logs
#   written after the last checkpoint; old logs are never restored into live RAM logs.
# REPORTING: Report readiness, checkpoint/archive failures and recovery rather than every
#   healthy checkpoint.
# Commands and side effects: docs/user-scripts-cli.md in ray-cys/unraid_repo.
# END CURRENT OPERATIONAL PURPOSE
# CHECKPOINT EVIDENCE: records current-boot archive metadata after read-back;
# backup_health_audit independently detects staleness without a new timer.
# Unchanged archives stay valid; empty sources require independent empty read-back.
clearLog=true
# RAM-log readiness and lifecycle monitor (Unraid User Scripts).
# Schedule: */10 * * * * (unchanged). Normal runs check RAM-log health and save
# changed logs to vault at most once per interval. Application logs are never
# deleted/truncated/rotated. --prepare is the existing PRE-DOCKER boot hook;
# it also registers a bounded unmounting_disks archive callback on every boot.
#
# RECOVERY: clean array stops/reboots/shutdowns request a final snapshot while
# vault is mounted. Sudden power loss cannot run a shutdown hook: recover the
# latest completed checkpoint instead. Changes after it may be lost, and a
# hanging/unavailable filesystem or missed schedule can make that gap longer.
# Archives are for review; old logs are never restored into active RAM paths.
#
# RETENTION: keep at most TWO completed archives: current boot's rolling snapshot
# plus the newest other boot. Each successful capture replaces the prior snapshot
# for its boot. This preserves crash evidence across repeated new-boot checkpoints.
# A temporary third archive can exist during creation/promotion; old snapshots
# are pruned only after a verified, synced replacement. Cap each compressed file
# at 256 MiB; metadata is small. Unknown/unmanaged paths are never purged.
# All archive diagnostics go to console and existing monitor health reporting,
# never a new syslog stream or additional scheduled User Script.
# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="ram_logs_watchdog"
# shellcheck shell=bash
# Shared operational logs, notifications and execution receipts.
usr_ops_log_line() {
    local level="${1^^}" phase="$2" message="$3" line LC_ALL=C
    case "$level" in WARN) level=WARNING;; ERR|FATAL) level=ERROR;; NOTICE) level=INFO;; esac
    message=${message//$'\r'/};message=${message//$'\n'/ | }
    printf -v line '%s | %s | %s | run=%s | phase=%s | %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$OPS_SCRIPT_ID" "${OPS_RUN_ID:-$$}" "$phase" "$message"
    if ((${#line}>4096));then line="${line:0:4050} ... [truncated]";fi
    printf '%s\n' "$line"
}

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
    local delivery_rc=0
    "${args[@]}" || delivery_rc=$?
    return "$delivery_rc"
}

usr_ops_execution_record() (
    local phase="$1" started="$2" pid="$3" rc="${4:-0}" process_start root="${USR_OPS_EXECUTION_ROOT:-/run/user-script-execution}" file tmp now boot old='{}' status
    [[ "${OPS_SCRIPT_ID:-}" =~ ^[a-z0-9_]+$ && ! -L "$root" ]] || return 1
    mkdir -p "$root" || return 1;file="$root/$OPS_SCRIPT_ID.json"
    [[ ! -L "$file" ]] || return 1
    if [[ -f "$file" ]];then old=$(jq -c 'select(.schema==1)' "$file") || old='{}';fi
    [[ -n "$old" ]] || old='{}'
    now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)
    process_start=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')
    [[ "$phase" != finish ]] || process_start=$(jq -r '.processStart // ""' <<<"$old")
    status=RUNNING;[[ "$phase" != finish ]] || { status=COMPLETED;((rc==0)) || status=FAILED; }
    tmp=$(mktemp "$root/.execution.XXXXXX") || return 1;trap 'rm -f -- "$tmp"' EXIT
    jq -n --argjson old "$old" --arg processStart "$process_start" --arg name "$OPS_SCRIPT_ID" --arg boot "$boot" --arg status "$status" --argjson started "$started" --argjson at "$now" --argjson pid "$pid" --argjson rc "$rc" \
      '$old+{schema:1,name:$name,boot:$boot,executionStatus:$status,startedAt:$started,observedAt:$at,pid:$pid,processStart:$processStart,lastExitCode:$rc} |
       if $status!="RUNNING" then .finishedAt=$at|.durationSeconds=($at-$started)|.lastCompletedAt=$at|if $rc==0 then .lastSuccessAt=$at else . end
       else .previousRun={startedAt:$old.startedAt,finishedAt:$old.finishedAt,status:$old.executionStatus,exitCode:$old.lastExitCode,durationSeconds:$old.durationSeconds}|.finishedAt=null|.durationSeconds=null|.lastExitCode=null end' >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file" || return 1
    local persistent="${USR_OPS_EXECUTION_PERSISTENT_ROOT:-/mnt/vault/cloud/logs/script/user_scripts_status/execution}" fd export_fd
    mountpoint -q "${USR_OPS_VAULT_MOUNT:-/mnt/vault}" || return 0
    [[ ! -L "$persistent" && $(realpath -m "$persistent") == "$persistent" ]] || return 1
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}";flock -s -n "$export_fd" || return 0
    mkdir -p "$persistent" || return 1
    tmp=$(mktemp "$persistent/.execution.XXXXXX") || return 1
    cp "$file" "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$persistent/$OPS_SCRIPT_ID.json"
)

usr_ops_supervise() {
    local script="$1" started pid='' interrupted='' rc=0 receipt_fd record_owner=false
    # Repository/fixture executions must never publish production evidence.
    # Explicit test roots opt into supervision for isolated regression checks.
    case "$script" in
      /boot/config/plugins/user.scripts/scripts/*/script|/tmp/user.scripts/tmpScripts/*/script) ;;
      *) if [[ -z "${USR_OPS_EXECUTION_ROOT:-}" ]];then USR_OPS_SUPERVISED="$OPS_SCRIPT_ID" /bin/bash "$script";return $?;fi;;
    esac
    local execution_root="${USR_OPS_EXECUTION_ROOT:-/run/user-script-execution}"
    if [[ ! -L "$execution_root" ]] && mkdir -p "$execution_root";then
        exec {receipt_fd}>"$execution_root/$OPS_SCRIPT_ID.lock"
        flock -n "$receipt_fd" && record_owner=true
    fi
    # Register forwarding before launch or receipt I/O. Background Bash may
    # inherit ignored SIGINT, so interactive cancellation uses its TERM cleanup.
    trap 'interrupted=TERM;[[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true' TERM HUP
    trap 'interrupted=INT;[[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true' INT
    started=$(date +%s)
    USR_OPS_SUPERVISED="$OPS_SCRIPT_ID" OPS_RUN_ID="${OPS_RUN_ID:-${started}_$$}" /bin/bash "$script" &
    pid=$!
    [[ -z "$interrupted" ]] || kill -TERM "$pid" 2>/dev/null || true
    [[ "$record_owner" != true ]] || usr_ops_execution_record start "$started" "$pid" || printf 'Execution receipt unavailable for %s; workflow continues.\n' "$OPS_SCRIPT_ID" >&2
    wait "$pid" || rc=$?
    # A signal can interrupt wait while the producer is still restoring state.
    if kill -0 "$pid" 2>/dev/null;then wait "$pid" || rc=$?;fi
    if [[ "$interrupted" == INT ]];then rc=130;elif [[ "$interrupted" == TERM ]];then rc=143;fi
    [[ "$record_owner" != true ]] || usr_ops_execution_record finish "$started" "$pid" "$rc" || printf 'Completion receipt unavailable for %s (exit=%s).\n' "$OPS_SCRIPT_ID" "$rc" >&2
    trap - TERM HUP INT
    return "$rc"
}
# END EMBEDDED OPERATIONS CONTRACT
# BEGIN SCHEDULED EXECUTION SUPERVISOR
if [[ "${BASH_SOURCE[0]}" == "$0" && $# == 0 && "${USR_OPS_SUPERVISED:-}" != "$OPS_SCRIPT_ID" ]];then
    usr_ops_supervise "$0";exit $?
fi
# END SCHEDULED EXECUTION SUPERVISOR
set -uo pipefail
RAMLOG_PATH="${RAMLOG_PATH:-/mnt/ramlogs}"
RAMLOG_SIZE="${RAMLOG_SIZE:-2G}"
RAMLOG_APPS=(sonarr radarr prowlarr bazarr tautulli recyclarr sabnzbd qbittorrent imagemaid seerr lumunarr)
WARNING_PERCENT=70
CRITICAL_PERCENT=90
RECOVER_PERCENT=65
REMINDER_SECONDS=86400
APP_WARNING_BYTES=$((512 * 1024 * 1024))
STATE_DIR="${STATE_DIR:-/run/ram_logs_watchdog}"
NOTIFY="${NOTIFY:-/usr/local/emhttp/webGui/scripts/notify}"
STATUS_DIR="${STATUS_DIR:-/mnt/vault/cloud/logs/script/user_scripts_status}"

ARCHIVE_ROOT="${ARCHIVE_ROOT:-/mnt/vault/cloud/logs/ram_logs_watchdog_archives}"
VAULT_MOUNT="${VAULT_MOUNT:-/mnt/vault}"
ARCHIVE_INTERVAL_SECONDS="${ARCHIVE_INTERVAL_SECONDS:-600}"
ARCHIVE_MAX_BYTES=$((256 * 1024 * 1024))
ARCHIVE_RESERVE_BYTES=$((64 * 1024 * 1024))
ARCHIVE_TIMEOUT_SECONDS=25
ARCHIVE_HOOK_ROOT="${ARCHIVE_HOOK_ROOT:-/usr/local/emhttp/plugins/ram_logs_watchdog}"
EMHTTP_EVENT="${EMHTTP_EVENT:-/usr/local/sbin/emhttp_event}"
INSTALLED_SCRIPT="${INSTALLED_SCRIPT:-/boot/config/plugins/user.scripts/scripts/ram_logs_watchdog/script}"
BOOT_ID_FILE="${BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
readonly SELF_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
ARCHIVE_LAST_ERROR=""

# This is a RAM-resident event adapter, not another User Scripts entry. The
# existing --prepare call recreates it before emhttp starts on every boot.
install_archive_hook() {
    local hook="$ARCHIVE_HOOK_ROOT/event/unmounting_disks" temp
    [[ -f "$EMHTTP_EVENT" ]] && grep -q '^# unmounting_disks' "$EMHTTP_EVENT" || {
        usr_ops_log_line INFO archive "$(printf 'Archive hook unavailable: Unraid event interface not recognized.\n')" >&2; return 1;
    }
    [[ "$ARCHIVE_HOOK_ROOT" == /usr/local/emhttp/plugins/* || "$ARCHIVE_HOOK_ROOT" == /tmp/* ]] || return 1
    [[ ! -L "$ARCHIVE_HOOK_ROOT" && $(realpath -m "$ARCHIVE_HOOK_ROOT") == "$ARCHIVE_HOOK_ROOT" &&
       "$INSTALLED_SCRIPT" == /* && "$INSTALLED_SCRIPT" != *$'\n'* ]] || return 1
    if [[ -e "$hook" ]]; then
        [[ -f "$hook" && ! -L "$hook" ]] && grep -Fqx '# Managed by ram_logs_watchdog.sh archive hook v1' "$hook" || {
            usr_ops_log_line WARNING archive "$(printf 'Unrecognized archive event hook preserved.\n')" >&2; return 1;
        }
    fi
    [[ $(realpath -m "${hook%/*}") == "${hook%/*}" ]] || return 1
    mkdir -p -- "${hook%/*}" || return 1
    temp=$(mktemp "${hook%/*}/.ramlog-hook.XXXXXX") || return 1
    {
        printf '#!/bin/bash\n# Managed by ram_logs_watchdog.sh archive hook v1\n'
        printf 'cd /\n'
        printf 'if ! /usr/bin/timeout --kill-after=2 %s /bin/bash %q --archive shutdown; then\n' "$ARCHIVE_TIMEOUT_SECONDS" "$INSTALLED_SCRIPT"
        printf '  printf "%%s\\n" "RAM-log shutdown archive incomplete; previous completed checkpoints retained." >/dev/console\nfi\nexit 0\n'
    } >"$temp" || { rm -f "$temp"; return 1; }
    chmod 755 "$temp" || { rm -f "$temp"; return 1; }
    if [[ -f "$hook" ]] && cmp -s "$temp" "$hook"; then rm -f "$temp"; return 0; fi
    mv -f -- "$temp" "$hook"
}

archive_source_inventory() {
    local files="$1" inventory="$2"
    mountpoint -q "$RAMLOG_PATH" && [[ $(findmnt -rn -T "$RAMLOG_PATH" -o FSTYPE) == tmpfs && ! -L "$RAMLOG_PATH" &&
        $(realpath -e "$RAMLOG_PATH") == "$RAMLOG_PATH" ]] || return 1
    # Do not follow links, cross mounted filesystems or archive sockets/devices.
    find "$RAMLOG_PATH" -xdev -type f -printf '%P\0' >"$files" || return 1
    sort -z -o "$files" "$files" || return 1
    find "$RAMLOG_PATH" -xdev -type f -printf '%P\0%i:%s:%T@:%C@\0' >"$inventory" || return 1
    sort -z -o "$inventory" "$inventory"
}

archive_generation_valid() {
    local dir="$1" id="${1##*/}"
    [[ "$id" =~ ^ramlogs_[0-9]{8}_[0-9]{6}_[a-f0-9-]{36}_[A-Za-z0-9]+$ &&
       -d "$dir" && ! -L "$dir" && -f "$dir/.owner" && ! -L "$dir/.owner" &&
       $(cat "$dir/.owner") == ramlog_archive ]] || return 1
    [[ -z $(find "$dir" -mindepth 1 ! -type f -print -quit) ]] || return 1
    [[ -z $(find "$dir" -mindepth 1 -maxdepth 1 ! -name .owner ! -name payload.tar.gz ! -name manifest.json ! -name SHA256SUMS -print -quit) ]] || return 1
    [[ -f "$dir/payload.tar.gz" && -f "$dir/SHA256SUMS" ]] || return 1
    jq -e '.schema==1 and (.bootId|test("^[a-f0-9-]{36}$")) and (.createdAt|type=="number")' "$dir/manifest.json" >/dev/null
}

prune_ram_logs_watchdog_archives() {
    local list="$STATE_DIR/archive-retention.list" dir boot kept=1 promoted="$1" promoted_boot
    local -A retained_boots=()
    archive_generation_valid "$promoted" || return 1
    promoted_boot=$(jq -r .bootId "$promoted/manifest.json") || return 1
    retained_boots[$promoted_boot]=1
    find "$ARCHIVE_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'ramlogs_*' -printf '%f\n' | sort -r >"$list" || return 1
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        dir="$ARCHIVE_ROOT/$dir"
        archive_generation_valid "$dir" || { usr_ops_log_line WARNING archive "$(printf 'Unrecognized archive generation preserved: %s\n' "$dir")" >&2; return 1; }
        [[ "$dir" != "$promoted" ]] || continue
        boot=$(jq -r .bootId "$dir/manifest.json") || return 1
        if [[ -z "${retained_boots[$boot]:-}" ]] && ((kept<2)); then
            retained_boots[$boot]=1; kept=$((kept+1)); continue
        fi
        # Valid, known generation only; never follow directory/file links.
        rm -- "$dir/payload.tar.gz" "$dir/manifest.json" "$dir/SHA256SUMS" "$dir/.owner" && rmdir -- "$dir" || return 1
    done <"$list"
    sync -- "$ARCHIVE_ROOT"
}

archive_ramlogs() (
    umask 077
    local reason="$1" boot now work='' stage='' target files inventory fingerprint after newest='' dir available size count rc=0 temp
    local LC_ALL=C
    cleanup_archive() {
        [[ -z "$work" ]] || rm -rf -- "$work"
        if [[ -n "$stage" && -d "$stage" && ! -L "$stage" && -f "$stage/.owner" && $(cat "$stage/.owner") == ramlog_archive ]]; then
            rm -f -- "$stage/payload.tar.gz" "$stage/manifest.json" "$stage/SHA256SUMS" "$stage/.owner"
            rmdir -- "$stage" 2>/dev/null || true
        fi
    }
    trap cleanup_archive EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    case "$reason" in checkpoint|shutdown|manual) ;; *) return 2;; esac
    for dependency in jq flock timeout tar gzip sha256sum stat find sort df sync realpath; do command -v "$dependency" >/dev/null || return 1; done
    tar --version 2>/dev/null | grep -q 'GNU tar' || { usr_ops_log_line ERROR archive "$(printf 'Archive failed: GNU tar is required.\n')" >&2; return 1; }
    [[ "$ARCHIVE_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || return 1
    mountpoint -q "$VAULT_MOUNT" || { usr_ops_log_line ERROR archive "$(printf 'Archive failed: vault is not mounted; no shadow directory created.\n')" >&2; return 1; }
    [[ "$ARCHIVE_ROOT" == "$VAULT_MOUNT"/* && ! -L "$ARCHIVE_ROOT" && $(realpath -m "$ARCHIVE_ROOT") == "$ARCHIVE_ROOT" ]] || return 1
    mkdir -p -- "$STATE_DIR" || return 1
    exec {archive_fd}>"$STATE_DIR/archive.lock" || return 1
    if ! flock -w 5 "$archive_fd"; then usr_ops_log_line INFO archive "$(printf 'Archive deferred: another capture is active.\n')"; return 1; fi
    boot=$(cat "$BOOT_ID_FILE") || return 1
    [[ "$boot" =~ ^[a-f0-9-]{36}$ ]] || return 1
    now=$(date +%s)
    work=$(mktemp -d "$STATE_DIR/.archive-work.XXXXXX") || return 1
    files="$work/files"; inventory="$work/inventory"
    archive_source_inventory "$files" "$inventory" || { usr_ops_log_line ERROR archive "$(printf 'Archive failed: RAM-log source is unavailable or is not tmpfs.\n')" >&2; return 1; }
    [[ -s "$files" ]] || { usr_ops_log_line INFO archive "$(printf 'Archive skipped: RAM log tree has no regular files.\n')"; return 0; }
    fingerprint=$(sha256sum "$inventory" | awk '{print $1}') || return 1
    if [[ -d "$ARCHIVE_ROOT" ]]; then
        if [[ ! -f "$ARCHIVE_ROOT/.owner" || -L "$ARCHIVE_ROOT/.owner" || $(cat "$ARCHIVE_ROOT/.owner") != ram_logs_watchdog ]]; then
            usr_ops_log_line ERROR archive "$(printf 'Archive failed: existing destination is unowned; preserved.\n')" >&2; return 1
        fi
    else
        mkdir -m 700 -- "$ARCHIVE_ROOT" || return 1
        printf 'ram_logs_watchdog\n' >"$ARCHIVE_ROOT/.owner" || return 1
    fi
    # Only this worker owns the archive lock. Remove recognizable interrupted
    # staging directories; completed generations are never treated as scratch.
    while IFS= read -r -d '' dir; do
        [[ ! -L "$dir" && -f "$dir/.owner" && ! -L "$dir/.owner" && $(cat "$dir/.owner") == ramlog_archive ]] || continue
        [[ -z $(find "$dir" -mindepth 1 ! -type f -print -quit) ]] || continue
        [[ -z $(find "$dir" -mindepth 1 -maxdepth 1 ! -name .owner ! -name payload.tar.gz ! -name manifest.json ! -name SHA256SUMS -print -quit) ]] || continue
        rm -f -- "$dir/payload.tar.gz" "$dir/manifest.json" "$dir/SHA256SUMS" "$dir/.owner" && rmdir "$dir" || return 1
    done < <(find "$ARCHIVE_ROOT" -mindepth 1 -maxdepth 1 -type d -name '.ramlog-*.partial' -print0)
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        if archive_generation_valid "$ARCHIVE_ROOT/$dir" && [[ $(jq -r .bootId "$ARCHIVE_ROOT/$dir/manifest.json") == "$boot" ]]; then newest="$ARCHIVE_ROOT/$dir"; break; fi
    done < <(find "$ARCHIVE_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'ramlogs_*' -printf '%f\n' | sort -r)
    [[ -z "$newest" ]] || prune_ram_logs_watchdog_archives "$newest" || return 1
    if [[ "$reason" == checkpoint && -n "$newest" ]]; then
        local epoch
        epoch=$(jq -r .createdAt "$newest/manifest.json")
        if ((now>=epoch && now-epoch<ARCHIVE_INTERVAL_SECONDS)); then usr_ops_log_line INFO archive "$(printf 'Archive checkpoint not due; last success %ss ago.\n' "$((now-epoch))")"; return 0; fi
        if [[ $(jq -r .sourceFingerprint "$newest/manifest.json") == "$fingerprint" ]]; then
            usr_ops_log_line INFO archive "$(printf 'Archive checkpoint unchanged; previous completed snapshot retained.\n')"; return 0
        fi
    fi
    available=$(df -PB1 "$ARCHIVE_ROOT" | awk 'NR==2{print $4}') || return 1
    [[ "$available" =~ ^[0-9]+$ ]] && ((available>=ARCHIVE_MAX_BYTES+ARCHIVE_RESERVE_BYTES)) || {
        usr_ops_log_line ERROR archive "$(printf 'Archive failed: insufficient vault space for the bounded archive plus reserve; previous archives retained.\n')" >&2; return 1;
    }
    stage=$(mktemp -d "$ARCHIVE_ROOT/.ramlog-$boot.XXXXXX.partial") || return 1
    printf 'ramlog_archive\n' >"$stage/.owner" || return 1
    # Bash file limits use KiB when POSIX mode is off. Limit the compressed output,
    # not source logs. GNU tar status 1 is allowed for a live, changing log file;
    # compressed integrity and headers must still verify before promotion.
    (
        set +o posix; unset POSIXLY_CORRECT
        ulimit -f "$((ARCHIVE_MAX_BYTES/1024))" || exit 2
        tar --create --use-compress-program='gzip -1' --file="$stage/payload.tar.gz" \
            --directory="$RAMLOG_PATH" --no-recursion --hard-dereference --null --verbatim-files-from --files-from="$files"
    ) 2>"$work/tar.err" || rc=$?
    if ((rc>1)); then usr_ops_log_line ERROR archive "$(printf 'Archive failed: tar exit=%s; incomplete staging discarded.\n' "$rc")" >&2; return 1; fi
    size=$(stat -c %s "$stage/payload.tar.gz") || return 1
    ((size>0 && size<=ARCHIVE_MAX_BYTES)) || return 1
    gzip -t "$stage/payload.tar.gz" || { usr_ops_log_line ERROR archive "$(printf 'Archive failed: gzip CRC verification failed.\n')" >&2; return 1; }
    tar -tzf "$stage/payload.tar.gz" >"$work/archive-list" 2>"$work/verify.err" || {
        usr_ops_log_line ERROR archive "$(printf 'Archive failed: compressed archive verification failed.\n')" >&2; return 1;
    }
    archive_source_inventory "$work/after-files" "$work/after-inventory" || return 1
    after=$(sha256sum "$work/after-inventory" | awk '{print $1}') || return 1
    count=$(tr -cd '\000' <"$files" | wc -c)
    jq -n --arg version "$SCRIPT_VERSION" --arg boot "$boot" --arg reason "$reason" --arg source "$RAMLOG_PATH" \
        --arg hash "$fingerprint" --arg after "$after" --argjson epoch "$now" --argjson count "$count" --argjson bytes "$size" --argjson tarStatus "$rc" \
        '{schema:1,scriptVersion:$version,bootId:$boot,reason:$reason,createdAt:$epoch,source:$source,
          sourceFingerprint:$hash,sourceAfterFingerprint:$after,selectedFiles:$count,compressedBytes:$bytes,tarStatus:$tarStatus,
          consistency:(if $hash==$after and $tarStatus==0 then "source metadata stable during capture" else "live best-effort; files changed during capture" end),
          recovery:"review only; never automatically restore archived logs into active application folders"}' >"$stage/manifest.json" || return 1
    (cd "$stage" && sha256sum payload.tar.gz manifest.json >SHA256SUMS && sha256sum -c SHA256SUMS >/dev/null) || return 1
    sync -- "$stage/payload.tar.gz" "$stage/manifest.json" "$stage/SHA256SUMS" "$stage/.owner" "$stage" || return 1
    target="$ARCHIVE_ROOT/ramlogs_$(date -u +%Y%m%d_%H%M%S)_${boot}_${stage##*.ramlog-$boot.}"
    target=${target%.partial}
    [[ ! -e "$target" ]] || return 1
    mv -- "$stage" "$target" || return 1
    stage=''
    sync -- "$ARCHIVE_ROOT" || return 1
    prune_ram_logs_watchdog_archives "$target" || { usr_ops_log_line INFO archive "$(printf 'Archive completed but retention needs review; existing generations preserved.\n')" >&2; return 1; }
    usr_ops_log_line INFO archive "Completed RAM-log archive: reason=$reason; files=$count; compressed=$size bytes; destination=$target; retained=at most two boot snapshots"
)

run_ramlog_archive() {
    local reason="$1" result rc=0
    mkdir -p -- "$STATE_DIR" || return 1
    result=$(mktemp "$STATE_DIR/.archive-result.XXXXXX") || return 1
    timeout --kill-after=2 "$ARCHIVE_TIMEOUT_SECONDS" /bin/bash "$SELF_PATH" --archive "$reason" >"$result" 2>&1 || rc=$?
    cat "$result"
    if ((rc==0)) && grep -Eq 'Archive checkpoint (not due|unchanged)|Completed RAM-log archive:|Archive skipped: RAM log tree has no regular files' "$result";then
        local checked_tmp checkpoint newest='' candidate boot
        boot=$(cat /proc/sys/kernel/random/boot_id)
        while IFS= read -r candidate;do
            if archive_generation_valid "$candidate" && [[ $(jq -r .bootId "$candidate/manifest.json") == "$boot" ]];then newest="$candidate";break;fi
        done < <(find "$ARCHIVE_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'ramlogs_*' | sort -r)
        if grep -q 'Archive skipped: RAM log tree has no regular files' "$result";then
            checkpoint=$(mktemp "$STATE_DIR/.checkpoint.XXXXXX") || return 1
            jq -n --arg boot "$boot" --arg source "$RAMLOG_PATH" --argjson at "$(date +%s)" '{schema:1,bootId:$boot,checkedAt:$at,empty:true,source:$source}' >"$checkpoint" && mv "$checkpoint" "$STATE_DIR/checkpoint.json" || rc=1
        elif [[ -n "$newest" ]];then
            checkpoint=$(mktemp "$STATE_DIR/.checkpoint.XXXXXX") || return 1
            jq -n --arg boot "$boot" --arg path "$newest" --arg manifest "$(sha256sum "$newest/manifest.json"|cut -d ' ' -f1)" --argjson bytes "$(stat -c %s "$newest/payload.tar.gz")" --argjson at "$(date +%s)" '{schema:1,bootId:$boot,checkedAt:$at,path:$path,manifestSha256:$manifest,payloadBytes:$bytes}' >"$checkpoint" && mv "$checkpoint" "$STATE_DIR/checkpoint.json" || rc=1
        fi
        checked_tmp=$(mktemp "$STATE_DIR/.archive-checked.XXXXXX") && date +%s >"$checked_tmp" && mv "$checked_tmp" "$STATE_DIR/archive-checked.epoch" || rc=1
    fi
    if ((rc!=0)); then ARCHIVE_LAST_ERROR="Archive attempt failed (exit=$rc). $(tail -n 3 "$result") Previous completed snapshots were retained."; fi
    rm -f -- "$result"
    return "$rc"
}

prepare_ramlogs() {
    [[ "$RAMLOG_PATH" == /mnt/* && "$RAMLOG_PATH" != /mnt/ && ! -L "$RAMLOG_PATH" &&
       $(realpath -m "$RAMLOG_PATH") == "$RAMLOG_PATH" && "$RAMLOG_SIZE" =~ ^[1-9][0-9]*[MG]$ ]] || return 1
    if mountpoint -q "$RAMLOG_PATH"; then
        [[ $(findmnt -rn -T "$RAMLOG_PATH" -o FSTYPE) == tmpfs ]] || return 1
        usr_ops_log_line INFO archive "$(printf 'RAM logs: existing tmpfs retained; mount size and files unchanged.\n')"
    else
        if pgrep -x dockerd >/dev/null || [[ -d "$RAMLOG_PATH" && -n $(find "$RAMLOG_PATH" -mindepth 1 -print -quit) ]]; then
            usr_ops_log_line ERROR archive "$(printf 'RAM-log preparation refused: Docker is active or unmounted path is nonempty; no files changed.\n')" >&2; return 1
        fi
        mkdir -p -- "$RAMLOG_PATH" || return 1
        mount -t tmpfs -o "size=$RAMLOG_SIZE,noatime,nosuid,nodev" tmpfs "$RAMLOG_PATH" || return 1
        usr_ops_log_line INFO archive "$(printf 'RAM logs: mounted %s tmpfs before Docker startup.\n' "$RAMLOG_SIZE")"
    fi
    local app
    for app in "${RAMLOG_APPS[@]}"; do
        [[ ! -L "$RAMLOG_PATH/$app" ]] || return 1
        mkdir -p -- "$RAMLOG_PATH/$app" || return 1
        # Only the declared tmpfs root/direct application directories, never
        # recursive file ownership changes or other host directories.
        chown 99:100 "$RAMLOG_PATH/$app" || return 1
        chmod 775 "$RAMLOG_PATH/$app" || return 1
    done
    chown 99:100 "$RAMLOG_PATH" && chmod 775 "$RAMLOG_PATH"
}

monitor_ramlogs() {
    local condition=OK reason='' usage=0 previous=OK last=0 now temp details='' largest='' bytes path severity=normal
    local -a findings=()
    for dependency in jq flock timeout findmnt mountpoint df stat du date; do command -v "$dependency" >/dev/null || { usr_ops_log_line INFO archive "$(printf 'Missing dependency: %s\n' "$dependency")" >&2; return 1; }; done
    mkdir -p -- "$STATE_DIR" || return 1
    exec 9>"$STATE_DIR/monitor.lock" || return 1
    flock -n 9 || return 0
    now=$(date +%s)
    if [[ -f "$STATE_DIR/state.json" ]]; then
        jq -e '.condition|type=="string"' "$STATE_DIR/state.json" >/dev/null || { usr_ops_log_line INFO archive "$(printf 'Invalid RAM-log state preserved; no notification baseline overwritten.\n')" >&2; return 1; }
        previous=$(jq -r .condition "$STATE_DIR/state.json")
        last=$(jq -r '.notifiedAt // 0' "$STATE_DIR/state.json")
        [[ "$last" =~ ^[0-9]+$ ]] || return 1
    fi
    if ! mountpoint -q "$RAMLOG_PATH"; then
        condition=CRITICAL; reason='Dedicated RAM-log filesystem is not mounted; inspect pre-Docker boot preparation. No files were changed.'
    elif [[ $(findmnt -rn -T "$RAMLOG_PATH" -o FSTYPE) != tmpfs ]]; then
        condition=CRITICAL; reason='RAM-log path is mounted on the wrong filesystem; automatic mounting/removal prohibited while apps are running.'
    else
        usage=$(df -P "$RAMLOG_PATH" | awk 'NR==2 {gsub(/%/,"",$5);print $5}')
        [[ "$usage" =~ ^[0-9]+$ ]] || return 1
        if (( usage>=CRITICAL_PERCENT )); then condition=CRITICAL
        elif (( usage>=WARNING_PERCENT )) || [[ "$previous" != OK && "$usage" -gt "$RECOVER_PERCENT" ]]; then condition=WARNING; fi
        reason="RAM logs use ${usage}%; warning=${WARNING_PERCENT}%, critical=${CRITICAL_PERCENT}%, recovery<=${RECOVER_PERCENT}%."
        temp=$(mktemp "$STATE_DIR/.usage.XXXXXX") || return 1
        if timeout 8 du -sb -- "$RAMLOG_PATH"/* >"$temp" 2>/dev/null; then
            largest=$(sort -nr "$temp" | head -n 3 | awk '{printf "%s (%0.1f MiB)\n",$2,$1/1048576}')
            while read -r bytes path; do
                [[ "$bytes" =~ ^[0-9]+$ ]] || continue
                if (( bytes>=APP_WARNING_BYTES )); then findings+=("${path##*/}: $((bytes/1048576)) MiB; review its native log retention. Active logs were not deleted/truncated."); fi
            done <"$temp"
        fi
        rm -f -- "$temp"
        if (( ${#findings[@]}>0 )) && [[ "$condition" == OK ]]; then condition=WARNING; fi
        details="Largest application directories:"$'\n'"${largest:-none}"
        if (( ${#findings[@]}>0 )); then details+=$'\n'"$(printf '%s\n' "${findings[@]}")"; fi
    fi
    if [[ -n "$ARCHIVE_LAST_ERROR" ]]; then
        [[ "$condition" != OK ]] || condition=WARNING
        details+=$'\n'"$ARCHIVE_LAST_ERROR"
        reason+=" Archive protection needs attention."
    fi
    usr_ops_log_line "$( [[ "$condition" == CRITICAL ]] && printf CRITICAL || printf INFO )" monitoring "$condition: $reason | $details"
    if [[ "$condition" != "$previous" ]] || { [[ "$condition" != OK ]] && (( now-last>=REMINDER_SECONDS )); }; then
        [[ "$condition" != CRITICAL ]] || severity=alert
        [[ "$condition" != WARNING ]] || severity=warning
        if [[ ! -x "$NOTIFY" ]] || ! usr_ops_notify timeout 30 "$NOTIFY" -i "$severity" -s 'RAM Logs Watchdog' -d "RAM logs: $previous -> $condition" -m "$reason"$'\n'"$details"$'\n''Action: readiness/usage checked; existing application logs preserved.'; then
            printf 'Notification delivery failed; transition remains pending.\n' >&2; return 1
        fi
        last=$now
    fi
    temp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 1
    jq -n --arg condition "$condition" --arg reason "$reason" --argjson notifiedAt "$last" --argjson epoch "$now" '{condition:$condition,reason:$reason,notifiedAt:$notifiedAt,epoch:$epoch}' >"$temp" && mv "$temp" "$STATE_DIR/state.json" || return 1
    if mountpoint -q /mnt/vault; then
        mkdir -p -- "$STATUS_DIR" || return 1
        temp=$(mktemp "$STATUS_DIR/.ramlog.XXXXXX") || return 1
        jq --slurpfile checkpoint <(cat "$STATE_DIR/checkpoint.json" 2>/dev/null || printf '{}') --argjson checked "$(cat "$STATE_DIR/archive-checked.epoch" 2>/dev/null || printf 0)" --arg name ram_logs_watchdog '{name:$name,status:.condition,summary:.reason,epoch:.epoch,archiveCheckedAt:$checked,checkpoint:($checkpoint[0] // {})}' "$STATE_DIR/state.json" >"$temp" && mv "$temp" "$STATUS_DIR/ram_logs_watchdog.json" || return 1
    fi
    [[ "$condition" != CRITICAL ]]
}
main() {
    case "${1:-}" in
        --prepare) prepare_ramlogs && install_archive_hook;;
        --install-hook) install_archive_hook;;
        --archive) archive_ramlogs "${2:-manual}";;
        --version) printf 'ram_logs_watchdog.sh %s\n' "$SCRIPT_VERSION";;
        --help) printf 'Usage: bash script [--prepare|--install-hook|--archive [manual|checkpoint|shutdown]|--version]\nNormal schedule stays */10 * * * *: health checks plus changed-log checkpoints. Two boot snapshots maximum, 256 MiB compressed each. --prepare mounts RAM logs before Docker and installs the shutdown event hook. --install-hook changes only the owned RAM-resident event adapter. --archive writes a vault snapshot; never restores old logs. Sudden power loss loses changes since the last successful checkpoint.\n';;
        '')
            if ! install_archive_hook; then ARCHIVE_LAST_ERROR='Archive shutdown hook unavailable; checkpoint protection remains best effort.'; fi
            run_ramlog_archive checkpoint || true
            monitor_ramlogs
            ;;
        *) return 2;;
    esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
