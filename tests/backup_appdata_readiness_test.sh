#!/bin/bash
# Fixture Docker/readiness only. No containers, archive payloads or email touched.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/appdata-readiness.XXXXXX)
trap 'rm -rf "$work"' EXIT
export DOCKER_MAINTENANCE_DIR="$work/maintenance"
source "$root/user_script/backup_cache_appdata.sh"
mkdir -p "$DOCKER_MAINTENANCE_DIR"
log(){ printf '%s | %s | %s\n' "$1" "$2" "$3" >> "$work/log"; }
MOCK_RUNNING=true;MOCK_START=true
TARGET_CONTAINERS=(photoprism)
APP_CONTAINERS[photoprism]=photoprism
CONTAINER_PENDING_APPS[photoprism]=1
CONTAINER_STOPPED[photoprism]=true
CONTAINER_STOP_STARTED[photoprism]=$(date +%s)
docker(){
 case "$1" in
  start) printf 'start\n' >> "$work/starts";[[ "$MOCK_START" != true ]] || MOCK_RUNNING=true;;
  inspect) printf '%s\n' "$MOCK_RUNNING";;
  *) printf 'Unexpected Docker command\n' >&2;return 1;;
 esac
}
sleep(){ :; }
DOCKER_WATCHDOG_SCRIPT="$work/provider.sh"
printf '#!/bin/bash\ncat "%s/readiness.json"\n' "$work" > "$DOCKER_WATCHDOG_SCRIPT"
APPDATA_READINESS_WAIT_SECONDS=1
printf '{"schema":1,"ready":false,"classification":"transport","detail":"Backend startup timeout"}\n' > "$work/readiness.json"
complete_container_scope_for_app photoprism
[[ "${CONTAINER_STOPPED[photoprism]}" == false && "$CONTAINERS_NEED_RESTART" == false ]]
[[ "${CONTAINER_READINESS_PENDING[photoprism]}" == 'transport: Backend startup timeout' ]]
[[ $(wc -l < "$work/starts") -eq 1 ]]
# Backend still pending: valid archives may finalize, but warning stays visible.
recheck_application_readiness
[[ -n "${CONTAINER_READINESS_PENDING[photoprism]}" && "$RESTART_FAILED" -eq 0 ]]
# Native startup later succeeds without issuing a second Docker start/restart.
printf '{"schema":1,"ready":true,"classification":"ready","detail":"Backend operational"}\n' > "$work/readiness.json"
recheck_application_readiness
[[ ${#CONTAINER_READINESS_PENDING[@]} -eq 0 && -n "${CONTAINER_READINESS_RECOVERED[photoprism]}" ]]
[[ $(wc -l < "$work/starts") -eq 1 ]]
# A genuinely stopped container still fails recovery and preserves restart intent.
CONTAINER_STOPPED[photoprism]=true;MOCK_START=false;MOCK_RUNNING=false
if start_container_with_retry photoprism;then echo 'Stopped container was accepted';exit 1;fi
[[ "${CONTAINER_STOPPED[photoprism]}" == true ]]
CONTAINER_READINESS_PENDING[photoprism]='Backend unavailable'
if recheck_application_readiness;then echo 'Final stopped state was accepted';exit 1;fi
[[ "$RESTART_FAILED" -gt 0 ]]
printf '[PASS] Delayed backend readiness preserves backup progress, records/rechecks warning and recovery, avoids extra restarts; real stopped containers remain failures\n'
