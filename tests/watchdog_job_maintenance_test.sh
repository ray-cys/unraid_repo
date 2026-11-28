#!/bin/bash
# Isolated state, Docker/config/auth/HTTP fixtures; no live apps or notifications.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/watchdog-job-maintenance.XXXXXX)
trap 'rm -rf "$work"' EXIT
source "$root/user_script/docker_service_watchdog.sh"
TMP_DIR="$work";STATE_WORK="$work/state.json";BOOT_ID=fixture;NOW=2000
STATE_FILE="$work/unused";LOG_FILE="$work/log";STATE_DIR="$work"
log(){ printf '%s %s\n' "$1" "$2" >> "$work/log"; }
flock(){ :; }
printf '{"version":2,"jobs":{"metafusion":{"result":"failed","success":0}},"observations":{"metafusion:job-failed":{"active":true,"bad":245,"good":0,"first":1,"severity":"CRITICAL","message":"legacy"}},"plannedDowntime":{"window":{"id":"window","container":"plex-media-server","containerId":"server","boot":"fixture","startedAt":1000,"endedAt":1800}},"notification":{"issues":{"metafusion:job-failed":"CRITICAL"}}}' > "$STATE_WORK"
printf '{"last_error":"Plex connector preflight failed"}' > "$work/native"
printf '{"findings":{"fatal":{"keys":["a"],"examples":["Config Error: No libraries were found in config"]},"errors":{"keys":["b"],"examples":["Plex Error: Plex URL is probably invalid"]}}}' > "$work/kometa"
docker_cmd(){ printf '[{"Id":"server","State":{"Running":true,"Status":"running","OOMKilled":false},"RestartCount":0,"NetworkSettings":{"Ports":{},"Networks":{}},"HostConfig":{"PortBindings":{}}}]'; }
probe_url(){ printf 'http://fixture:32400/identity\n'; }
AUTH_VALID=true
wd_plex_job_evidence(){
 [[ "$3" != check || "$AUTH_VALID" == true ]] || return 1
 printf '{"schema":1,"verified":true,"target":"http://fixture:32400","machineIdentifier":"plex-id","libraryCount":3}\n'
}
curl(){ printf '<MediaContainer machineIdentifier="plex-id" />\n'; }
wd_match_job_maintenance metafusion metafusion 1100 1120 "$work/native"
jq -e '.jobs.metafusion.result=="failed" and .jobs.metafusion.success==0 and .jobs.metafusion.maintenanceOutcome.status=="maintenance-blocked" and .observations["metafusion:job-failed"]==null and .jobIncidentHistory[0].observation.bad==245' "$STATE_WORK" >/dev/null
wd_match_job_maintenance kometa kometa 1200 1220 "$work/kometa"
# Outside-window, wrong authentication, mixed/non-Plex errors, incomplete
# examples, unsupported producer and unresolved window never imply recovery.
if wd_match_job_maintenance metafusion metafusion 1900 1920 "$work/native";then exit 1;fi
AUTH_VALID=false
if wd_match_job_maintenance metafusion metafusion 1100 1120 "$work/native";then exit 1;fi
AUTH_VALID=true
jq '.findings.errors.examples+=["Unrelated YAML error"]|.findings.errors.keys+=["c"]' "$work/kometa" > "$work/mixed"
if wd_match_job_maintenance kometa kometa 1200 1220 "$work/mixed";then exit 1;fi
jq '.findings.errors.keys+=["hidden"]' "$work/kometa" > "$work/incomplete"
if wd_match_job_maintenance kometa kometa 1200 1220 "$work/incomplete";then exit 1;fi
if wd_match_job_maintenance recyclarr recyclarr 1200 1220 "$work/native";then exit 1;fi
jq '.backlog=true' "$work/kometa" > "$work/gap"
if wd_match_job_maintenance kometa kometa 1200 1220 "$work/gap";then exit 1;fi
# Closed proof survives a reboot; current authenticated Plex identity must still match.
BOOT_ID=next-boot
wd_match_job_maintenance metafusion metafusion 1100 1120 "$work/native"
BOOT_ID=fixture
# A new failed-run identity resets its poll count and first observation while
# retaining the old real incident; same-run polls do not repeatedly reset.
observe service:job-failed CRITICAL 'first run' 1 service:1500
NOW=2100;observe service:job-failed CRITICAL 'same run' 1 service:1500
jq -e '.observations["service:job-failed"].bad==2 and .observations["service:job-failed"].first==2000' "$STATE_WORK" >/dev/null
NOW=2200;observe service:job-failed CRITICAL 'next run' 1 service:2100
jq -e '.observations["service:job-failed"].bad==1 and .observations["service:job-failed"].first==2200 and .observations["service:job-failed"].active' "$STATE_WORK" >/dev/null
# Exact active lease capture and native restart closure; journal-only holds
# without a verified lease cannot excuse a failed job.
DOCKER_MAINTENANCE_DIR="$work/leases";mkdir "$DOCKER_MAINTENANCE_DIR"
lease="$DOCKER_MAINTENANCE_DIR/plex-media-server.appdata.json"
printf '{"boot":"fixture","pid":0,"expires":5000,"reason":"fixture maintenance"}' > "$lease"
touch -d '@1000' "$lease"
FIXTURE_LEASE="$lease"
stopped='[{"Id":"server","State":{"Running":false,"Status":"exited","OOMKilled":false,"FinishedAt":"1970-01-01T00:16:40Z"},"RestartCount":0,"NetworkSettings":{"Ports":{},"Networks":{}},"HostConfig":{"PortBindings":{}}}]'
wd_capture_downtime plex-media-server "$stopped" "$lease"
mutate '.plannedDowntime |= with_entries(select(.value.endedAt==0))'
jq -e '.plannedDowntime|length==1' "$STATE_WORK" >/dev/null
MOCK_INFO="$stopped"
docker_cmd(){ printf '%s\n' "$MOCK_INFO"; }
maintenance_active(){ ACTIVE_MAINTENANCE_LEASE='';return 0; }
if wd_match_job_maintenance metafusion metafusion 1100 1120 "$work/native";then exit 1;fi
maintenance_active(){ ACTIVE_MAINTENANCE_LEASE="$FIXTURE_LEASE";return 0; }
AUTH_VALID=false
wd_match_job_maintenance metafusion metafusion 1100 1120 "$work/native"
MOCK_INFO=$(jq '.[0].State.Running=true|.[0].State.Status="running"|.[0].State.StartedAt="1970-01-01T00:30:00Z"' <<<"$stopped")
wd_close_downtime plex-media-server "$MOCK_INFO"
jq -e 'all(.plannedDowntime[];.endedAt==1800)' "$STATE_WORK" >/dev/null
AUTH_VALID=true
wd_match_job_maintenance metafusion metafusion 1100 1120 "$work/native"
# A recreated container can retain the same Plex server, but a different Plex
# machine identity must never inherit the old maintenance excuse.
MOCK_INFO=$(jq '.[0].Id="new-server-container"' <<<"$MOCK_INFO")
wd_match_job_maintenance metafusion metafusion 1100 1120 "$work/native"
curl(){ printf '<MediaContainer machineIdentifier="different-server" />\n'; }
if wd_match_job_maintenance metafusion metafusion 1100 1120 "$work/native";then exit 1;fi
# Missing maintenance evidence is always a real failure, not a global mute.
mutate 'del(.plannedDowntime)'
if wd_match_job_maintenance metafusion metafusion 1100 1120 "$work/native";then exit 1;fi
printf '[PASS] Exact maintenance correlation, retained native failure/history, authentication/window/mixed-error safeguards and run-scoped observation counters\n'
