# shellcheck shell=bash
# Shared, embedded runtime check for media monitor backup deferral.
# Return success only for a verified live producer or its bounded recovery grace.
# Invalid/stale ownership never suppresses monitoring; the Docker watchdog reports it.
appdata_backup_deferred() {
    local file="${DOCKER_MAINTENANCE_DIR:-/run/docker-service-maintenance}/backup-active.json"
    local now boot pid start phase actual
    APPDATA_BACKUP_REASON=''
    [[ -f "$file" && ! -L "$file" ]] || return 1
    [[ $(stat -c %u "$file" 2>/dev/null) == "$(id -u)" ]] || return 1
    now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id) || return 1
    jq -e --arg boot "$boot" --argjson now "$now" '
      .schema==1 and .producer=="backup_cache_appdata" and .boot==$boot and
      (.pid|type=="number" and .>0 and .==floor) and (.processStart|type=="string" and length>0) and
      (.startedAt|type=="number" and .>0 and .==floor) and .startedAt<=$now and
      (.expires|type=="number" and .>0 and .==floor) and .expires>$now and
      (if .phase=="active" then .expires==(.startedAt+86400)
       elif .phase=="grace" then (.finishedAt|type=="number" and .>0 and .==floor) and
         .finishedAt>=.startedAt and .finishedAt<=$now and .expires==(.finishedAt+120)
       else false end)' "$file" >/dev/null 2>&1 || return 1
    read -r pid start phase < <(jq -r '[.pid,.processStart,.phase]|@tsv' "$file")
    if [[ "$phase" == active ]];then
        kill -0 "$pid" 2>/dev/null || return 1
        actual=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')
        [[ -n "$actual" && "$actual" == "$start" ]] || return 1
        APPDATA_BACKUP_REASON='Appdata backup active; checks, notifications and automated actions deferred'
    else
        APPDATA_BACKUP_REASON='Appdata backup recovery grace; checks, notifications and automated actions deferred'
    fi
}
