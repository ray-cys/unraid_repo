#!/bin/bash
# Fixture reproduces an API-only PhotoPrism (no Docker healthcheck).
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/user_script/docker_service_watchdog.sh"
inspect_valid(){ return 0; }
readiness_probe(){ PROBE_RESULT=html;PROBE_MESSAGE='Fixture weak UI';return 1; }
docker_cmd(){
 if [[ "$1" == inspect ]];then printf '[{"State":{"Running":true,"Paused":false,"OOMKilled":false,"Health":{"Status":"none"}}}]'
 elif [[ "$1 $2" == 'exec photoprism' ]];then printf '{"status":"operational"}'
 else return 1;fi
}
photoprism_backup_readiness(){ printf '{"ready":false,"classification":"busy","source":"native-photoprism-backup","detail":"Fixture active backup"}'; }
readiness_json photoprism update | jq -e '.ready==false and .source=="native-photoprism-backup"' >/dev/null
photoprism_backup_readiness(){ printf '{"ready":true,"classification":"ready","source":"native-photoprism-backup","detail":"Fixture idle backup"}'; }
readiness_json photoprism update | jq -e '.ready==true and .source=="native-photoprism-backup"' >/dev/null
printf 'API-only readiness cannot bypass backup protection; idle app stays eligible\n'
