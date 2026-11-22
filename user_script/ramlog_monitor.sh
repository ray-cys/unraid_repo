#!/bin/bash
# RAM-log readiness and lifecycle monitor v2.0 (Unraid User Scripts).
# Schedule: */10 * * * *. Normal runs never mount, delete, truncate or rotate
# application files. --prepare is an idempotent PRE-DOCKER boot hook only;
# it refuses a nonempty unmounted directory or a running Docker daemon.
set -uo pipefail
readonly SCRIPT_VERSION="2.0"
RAMLOG_PATH="${RAMLOG_PATH:-/mnt/ramlogs}"
RAMLOG_SIZE="${RAMLOG_SIZE:-2G}"
RAMLOG_APPS=(sonarr radarr prowlarr bazarr tautulli recyclarr sabnzbd qbittorrent imagemaid seerr lumunarr)
WARNING_PERCENT=70
CRITICAL_PERCENT=90
RECOVER_PERCENT=65
REMINDER_SECONDS=86400
APP_WARNING_BYTES=$((512 * 1024 * 1024))
STATE_DIR="${STATE_DIR:-/run/ramlog-monitor}"
NOTIFY="${NOTIFY:-/usr/local/emhttp/webGui/scripts/notify}"
STATUS_DIR="${STATUS_DIR:-/mnt/vault/cloud/logs/script/user_scripts_status}"

prepare_ramlogs() {
    [[ "$RAMLOG_PATH" == /mnt/* && "$RAMLOG_PATH" != /mnt/ && ! -L "$RAMLOG_PATH" &&
       $(realpath -m "$RAMLOG_PATH") == "$RAMLOG_PATH" && "$RAMLOG_SIZE" =~ ^[1-9][0-9]*[MG]$ ]] || return 1
    if mountpoint -q "$RAMLOG_PATH"; then
        [[ $(findmnt -rn -T "$RAMLOG_PATH" -o FSTYPE) == tmpfs ]] || return 1
        printf 'RAM logs: existing tmpfs retained; mount size and files unchanged.\n'
    else
        if pgrep -x dockerd >/dev/null || [[ -d "$RAMLOG_PATH" && -n $(find "$RAMLOG_PATH" -mindepth 1 -print -quit) ]]; then
            printf 'RAM-log preparation refused: Docker is active or unmounted path is nonempty; no files changed.\n' >&2; return 1
        fi
        mkdir -p -- "$RAMLOG_PATH" || return 1
        mount -t tmpfs -o "size=$RAMLOG_SIZE,noatime,nosuid,nodev" tmpfs "$RAMLOG_PATH" || return 1
        printf 'RAM logs: mounted %s tmpfs before Docker startup.\n' "$RAMLOG_SIZE"
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
    for dependency in jq flock timeout findmnt mountpoint df stat du date; do command -v "$dependency" >/dev/null || { printf 'Missing dependency: %s\n' "$dependency" >&2; return 1; }; done
    mkdir -p -- "$STATE_DIR" || return 1
    exec 9>"$STATE_DIR/monitor.lock" || return 1
    flock -n 9 || return 0
    now=$(date +%s)
    if [[ -f "$STATE_DIR/state.json" ]]; then
        jq -e '.condition|type=="string"' "$STATE_DIR/state.json" >/dev/null || { printf 'Invalid RAM-log state preserved; no notification baseline overwritten.\n' >&2; return 1; }
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
    printf 'RAM logs: %s. %s\n%s\n' "$condition" "$reason" "$details"
    if [[ "$condition" != "$previous" ]] || { [[ "$condition" != OK ]] && (( now-last>=REMINDER_SECONDS )); }; then
        [[ "$condition" != CRITICAL ]] || severity=alert
        [[ "$condition" != WARNING ]] || severity=warning
        if [[ ! -x "$NOTIFY" ]] || ! timeout 30 "$NOTIFY" -i "$severity" -s 'RAM Logs Monitor' -d "RAM logs: $previous -> $condition" -m "$reason"$'\n'"$details"$'\n''Action: readiness/usage checked; existing application logs preserved.'; then
            printf 'Notification delivery failed; transition remains pending.\n' >&2; return 1
        fi
        last=$now
    fi
    temp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 1
    jq -n --arg condition "$condition" --arg reason "$reason" --argjson notifiedAt "$last" --argjson epoch "$now" '{condition:$condition,reason:$reason,notifiedAt:$notifiedAt,epoch:$epoch}' >"$temp" && mv "$temp" "$STATE_DIR/state.json" || return 1
    if mountpoint -q /mnt/vault; then
        mkdir -p -- "$STATUS_DIR" || return 1
        temp=$(mktemp "$STATUS_DIR/.ramlog.XXXXXX") || return 1
        jq --arg name ramlog_monitor '{name:$name,status:.condition,summary:.reason,epoch:.epoch}' "$STATE_DIR/state.json" >"$temp" && mv "$temp" "$STATUS_DIR/ramlog_monitor.json" || return 1
    fi
    [[ "$condition" != CRITICAL ]]
}
main() {
    case "${1:-}" in
        --prepare) prepare_ramlogs;;
        --version) printf 'ramlog_monitor.sh %s\n' "$SCRIPT_VERSION";;
        --help) printf 'Usage: bash script [--prepare|--version]\nNormal runs monitor only; --prepare is called before emhttp/Docker at boot.\n';;
        '') monitor_ramlogs;;
        *) return 2;;
    esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
