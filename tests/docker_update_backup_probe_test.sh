#!/bin/bash
# Host /proc fixture: a held file descriptor stands in for a native backup.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d);trap 'rm -rf "$fixture"' EXIT
source "$repo/user_script/docker_service_watchdog.sh"
probe_pid=$$
docker_cmd(){
 case "$1" in
   inspect) jq -n --arg p "$fixture/unused-env" '[{Config:{Env:[("PHOTOPRISM_BACKUP_PATH="+$p)]}}]';;
   top) printf 'PID COMMAND\n%s bash\n' "$probe_pid";;
   exec)
     if [[ "$3" == photoprism ]];then printf 'backup-path\t%s\n' "$fixture/native"
     else find "$fixture/native" -maxdepth 3 -type f -mmin -2 -print -quit;fi;;
   *) return 1;;
 esac
}
mkdir "$fixture/native"
exec 9>"$fixture/native/fixture.sql"
photoprism_backup_readiness | jq -e '.ready==false and .classification=="busy"' >/dev/null
exec 9>&-
photoprism_backup_readiness | jq -e '.ready==false and (.detail|contains("two minutes"))' >/dev/null
touch -d '5 minutes ago' "$fixture/native/fixture.sql"
photoprism_backup_readiness | jq -e .ready >/dev/null
printf 'Effective backup directory overrides stale env safely; open file/recent writes defer; idle backup permits updates\n'
