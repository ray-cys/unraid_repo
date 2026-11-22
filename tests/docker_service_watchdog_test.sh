#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/docker_watchdog_test.XXXXXX)"
trap 'rm -rf -- "${TEST_ROOT:?}"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC1091
source "$ROOT/user_script/docker_service_watchdog.sh"
[[ "${SERVICE_SPECS[*]}" == *'lumunarr||always|0'* ]] || fail 'Lumunarr policy missing'
STATE_DIR="$TEST_ROOT/state"; mkdir -p "$STATE_DIR"
HEARTBEAT_FILE="$TEST_ROOT/heartbeat/heartbeat.json"
STATE_FILE="$STATE_DIR/state.json"; STATE_WORK="$TEST_ROOT/work.json"
TMP_DIR="$TEST_ROOT/tmp"; mkdir -p "$TMP_DIR"
LOG_FILE="$STATE_DIR/watchdog.log"
DOCKER_MAINTENANCE_DIR="$TEST_ROOT/leases"; mkdir -p "$DOCKER_MAINTENANCE_DIR"
BOOT_ID=fixture-boot
NOTIFY_BIN="$TEST_ROOT/notify"
printf '#!/bin/sh\n[ ! -e "%s/fail-notify" ] || exit 1\nprintf "sent\\n" >>"%s/notifications"\n' "$TEST_ROOT" "$TEST_ROOT" >"$NOTIFY_BIN"
chmod 755 "$NOTIFY_BIN"
# GNU interfaces match the production host; flock is mocked because these
# fixtures are single-process. Recovery serialization uses real flock on Unraid.
stat() { if command -v gstat >/dev/null; then gstat "$@"; else command stat "$@"; fi; }
date() { if command -v gdate >/dev/null; then gdate "$@"; else command date "$@"; fi; }
flock() { return 0; }
sleep() { :; }
fresh() {
    printf '{"version":2,"bootId":"fixture-boot","services":{},"recovery":{},"observations":{},"notification":{"issues":{}}}\n' >"$STATE_WORK"
    SEEN=(); FROZEN=(); FROZEN_KEYS=(); RECOVERY_BLOCKED=(); PROFILE_BY_NAME=(); PROBE_FAILURES=(); RECOVERY_CANDIDATES=(); RECOVERY_SAFE=true
}
scan() {
    local candidate name url status allowed
    SEEN=(); FROZEN=(); FROZEN_KEYS=(); RECOVERY_CANDIDATES=()
    check_service "$1" || fail 'service scan failed'
    finish_observations || fail 'observation completion failed'
    for candidate in "${RECOVERY_CANDIDATES[@]}"; do
        IFS='|' read -r name url status allowed <<<"$candidate"
        attempt_recovery "$name" "$url" "$status" "$allowed" || fail 'recovery failed'
    done
}
active() { jq -e --arg key "$1" '.observations[$key].active == true' "$STATE_WORK" >/dev/null; }
make_info() {
    MOCK_INFO="$(jq -nc --arg state "$1" --arg health "${2:-none}" --argjson oom "${3:-false}" --argjson restart "${4:-0}" \
        '[{Id:"container-1",RestartCount:$restart,LogPath:"",State:{Status:$state,Health:{Status:$health},OOMKilled:$oom,StartedAt:"2020-01-01T00:00:00Z"}}]')"
}
MOCK_INSPECT_FAIL=false; MOCK_RESTART_FAIL=false; MOCK_ENDPOINT=true; MOCK_LOGS=""; MOCK_NATIVE='{}'
MOCK_INVENTORY=service
MOCK_PEER_INFO=""
docker_cmd() {
    case "$1" in
        inspect)
            [[ "$MOCK_INSPECT_FAIL" != true ]] || return 124
            if [[ "$2" == vpn && -n "$MOCK_PEER_INFO" ]]; then printf '%s\n' "$MOCK_PEER_INFO"; else printf '%s\n' "$MOCK_INFO"; fi ;;
        container) printf '%s\n' "$MOCK_INVENTORY" ;;
        logs) printf '%s\n' "$MOCK_LOGS" ;;
        exec) printf '%s\n' "$MOCK_NATIVE" ;;
        restart)
            printf 'attempt\n' >>"$TEST_ROOT/restarts"
            [[ "$MOCK_RESTART_FAIL" != true ]] || return 124
            make_info running healthy
            ;;
        *) return 0 ;;
    esac
}
endpoint_healthy() { PROBE_RESULT=ready; [[ "$MOCK_ENDPOINT" == true ]]; }

fresh; make_info exited
scan 'kometa||on-demand|0'
[[ "$(jq '.observations | length' "$STATE_WORK")" == 0 ]] || fail 'intentional on-demand stop alerted'
scan 'service||always|0'
active service:availability && fail 'single scan activated failure'
scan 'service||always|0'
active service:availability || fail 'confirmed failure missing'
notify_changes || fail 'initial failure notification'
scan 'service||always|0'; notify_changes || fail 'repeated failure notification'
[[ "$(wc -l <"$TEST_ROOT/notifications")" -eq 1 ]] || fail 'failure counter bypassed deduplication'
make_info running healthy
scan 'service||always|0'
active service:availability || fail 'recovery resolved without grace'
scan 'service||always|0'; notify_changes || fail 'recovery notification'
active service:availability && fail 'stable recovery unresolved'
[[ "$(wc -l <"$TEST_ROOT/notifications")" -eq 2 ]] || fail 'missing grouped recovery'

# OOM is a new event, not a permanent failure on every scan.
make_info running healthy true
scan 'service||always|0'; active service:oom-event || fail 'OOM event missing'
scan 'service||always|0'; scan 'service||always|0'
active service:oom-event && fail 'historical OOM never cleared'

# A maintenance lease freezes a confirmed issue without triggering recovery.
make_info exited
scan 'service||always|0'; scan 'service||always|0'
set_manual_maintenance service 10 'Fixture maintenance' || fail 'lease creation'
SEEN=(); FROZEN=(); scan 'service||always|1'
[[ -n "${FROZEN[service]:-}" ]] || fail 'maintenance did not freeze observations'
active service:availability || fail 'maintenance falsely resolved prior failure'
jq '.expires=1' "$DOCKER_MAINTENANCE_DIR/service.manual.json" >"$TEST_ROOT/expired"
mv "$TEST_ROOT/expired" "$DOCKER_MAINTENANCE_DIR/service.manual.json"
scan 'service||always|0'; active service:maintenance-expired || fail 'expired marker remained silently suppressive'
rm "$DOCKER_MAINTENANCE_DIR/service.manual.json"

# Attempts are reserved durably, failures consume budget, cooldown prevents
# immediate retries, and verified recovery records its evidence.
fresh; AUTO_RESTART=true; RESTART_COOLDOWN_SECONDS=1; MAX_RESTART_ATTEMPTS=1
RESTART_STOPPED_CONTAINERS=false; MOCK_ENDPOINT=false; make_info running unhealthy
scan 'service|http://fixture|always|1'; scan 'service|http://fixture|always|1'
MOCK_RESTART_FAIL=true
scan 'service|http://fixture|always|1'
[[ "$(wc -l <"$TEST_ROOT/restarts")" -eq 1 ]] || fail 'recovery attempt missing'
jq -e '.recovery.service.attempts == 1' "$STATE_FILE" >/dev/null || fail 'restart reservation not durable'
NOW=$((NOW + 2)); scan 'service|http://fixture|always|1'
active service:recovery-budget || fail 'budget exhaustion not reported'
[[ "$(wc -l <"$TEST_ROOT/restarts")" -eq 1 ]] || fail 'recovery exceeded budget'

fresh; NOW="$(date +%s)"; MOCK_RESTART_FAIL=false; MOCK_ENDPOINT=true; make_info running unhealthy
scan 'service||always|1'; scan 'service||always|1'; scan 'service||always|1'
active service:recovery-action || fail 'verified restart not recorded'

# Corrupt primary state falls back to validated backup and prohibits recovery.
cp "$STATE_WORK" "$STATE_FILE.bak"; printf '{broken' >"$STATE_FILE"
load_state || fail 'corrupt-state handling failed'
[[ "$RECOVERY_SAFE" == false && -f "$STATE_FILE.invalid" ]] || fail 'corrupt state did not inhibit recovery'
active monitor:state || fail 'state repair event missing'

# Inspection timeouts must never be interpreted as permission to restart.
fresh; MOCK_INSPECT_FAIL=true; scan 'service||always|1'
[[ "$(jq '.services | length' "$STATE_WORK")" == 0 ]] || fail 'failed inspection produced recovery state'
MOCK_INSPECT_FAIL=false
observe delivery:test WARNING 'Pending notification' 1 >/dev/null
touch "$TEST_ROOT/fail-notify"
if notify_changes; then fail 'notification failure swallowed'; fi
jq -e '.notification.issues == {}' "$STATE_WORK" >/dev/null || fail 'failed delivery advanced checkpoint'
rm "$TEST_ROOT/fail-notify"
notify_changes || fail 'failed notification was not retried'
LOG_MAX_BYTES=4096
head -c 20000 /dev/zero >"$LOG_FILE"
bound_existing_logs || fail 'legacy log bounding failed'
log INFO 'Fixture rotation' >/dev/null
[[ "$(stat -c %s "$LOG_FILE.1")" -le "$LOG_MAX_BYTES" ]] || fail 'legacy log exceeded retained cap'

# Discovery uses exact names/aliases, never silently grants restart permission.
fresh; make_info running healthy
SERVICE_SPECS=("kometa||always|0" "pms||always|0")
MOCK_INVENTORY=$'lometa\npms\npihole\nnew-app'
resolve_inventory || fail 'inventory resolution failed'
[[ "${EFFECTIVE_SPECS[0]}" == 'lometa||always|0' ]] || fail 'container alias not resolved'
[[ -n "${SEEN[new-app:unclassified]:-}" && -z "${SEEN[pihole:unclassified]:-}" ]] || fail 'unclassified/delegated coverage incorrect'

# Readiness interprets body and authentication separately from transport.
MOCK_HTTP_CODE=200; MOCK_HTTP_BODY='<MediaContainer machineIdentifier="fixture"/>'; MOCK_CURL_RC=0
MOCK_REDIRECT_FIRST=""; MOCK_REDIRECT_TO=""
MOCK_TRANSPORT_URL=""
curl() {
    local output="" argument previous="" limit=65536 url="${*: -1}"
    for argument in "$@"; do
        [[ "$previous" != --output ]] || output="$argument"
        [[ "$previous" != --max-filesize ]] || limit="$argument"
        previous="$argument"
    done
    printf '%s\n' "$url" >>"$TEST_ROOT/requests"
    if [[ -n "$MOCK_TRANSPORT_URL" && "$url" == "$MOCK_TRANSPORT_URL" ]]; then : >"$output"; printf '000'; return 28; fi
    printf '%s\n' "$limit" >"$TEST_ROOT/probe-limit"
    if [[ -n "$MOCK_REDIRECT_FIRST" && "$url" == "$MOCK_REDIRECT_FIRST" ]]; then
        : >"$output"; printf '302\n%s' "$MOCK_REDIRECT_TO"; return 0
    fi
    if (( ${#MOCK_HTTP_BODY} > limit )); then : >"$output"; printf '%s' "$MOCK_HTTP_CODE"; return 63; fi
    printf '%s' "$MOCK_HTTP_BODY" >"$output"
    printf '%s' "$MOCK_HTTP_CODE"
    return "$MOCK_CURL_RC"
}
readiness_probe plex-media-server http://fixture/identity || fail 'valid Plex identity rejected'
[[ "$PROBE_RESULT" == ready ]] || fail 'Plex identity not verified'
MOCK_HTTP_CODE=403
readiness_probe qbittorrent http://fixture/api/v2/app/version || fail 'authentication misclassified as transport'
[[ "$PROBE_RESULT" == authentication ]] || fail 'auth failure reported ready'
MOCK_HTTP_CODE=200; MOCK_HTTP_BODY='<html>Login</html>'
if readiness_probe plex-media-server http://fixture/identity; then fail 'login page accepted as Plex readiness'; fi
MOCK_CURL_RC=28
if readiness_probe plex-media-server http://fixture/identity; then fail 'transport failure accepted'; fi
[[ "$PROBE_RESULT" == transport ]] || fail 'transport not classified'
MOCK_CURL_RC=63
readiness_probe plex-media-server http://fixture/identity || fail 'oversize probe treated as service failure'
[[ "$PROBE_RESULT" == unconfigured ]] || fail 'oversize response could trigger restart'
MOCK_CURL_RC=0

# Web UI bodies may exceed the API cap. Normal local login/base-path redirects
# are followed only for UI recognition and only within the original origin.
printf -v large_ui '%*s' 100000 ''
MOCK_HTTP_BODY="SABnzbd$large_ui"
readiness_probe sabnzbd http://fixture/ || fail 'large SAB UI rejected'
[[ "$PROBE_RESULT" == reachable && "$(cat "$TEST_ROOT/probe-limit")" == "$PROBE_UI_MAX_BYTES" ]] || fail 'UI cap not used'
MOCK_HTTP_BODY='Tautulli login'; MOCK_REDIRECT_FIRST=http://fixture/; MOCK_REDIRECT_TO=http://fixture/auth/login
: >"$TEST_ROOT/requests"
readiness_probe tautulli http://fixture/ || fail 'same-origin UI redirect rejected'
[[ "$PROBE_RESULT" == reachable && "$(wc -l <"$TEST_ROOT/requests")" -eq 2 ]] || fail 'normal redirect not recognized'
MOCK_REDIRECT_TO=http://other-host/login; : >"$TEST_ROOT/requests"
readiness_probe tautulli http://fixture/ || fail 'cross-origin handling failed'
[[ "$PROBE_RESULT" == unconfigured && "$(wc -l <"$TEST_ROOT/requests")" -eq 1 ]] || fail 'cross-origin redirect followed'
MOCK_REDIRECT_TO=http://fixture/; : >"$TEST_ROOT/requests"
readiness_probe photoprism http://fixture/ || fail 'redirect-loop handling failed'
[[ "$PROBE_RESULT" == unconfigured && "$(wc -l <"$TEST_ROOT/requests")" -eq $((PROBE_MAX_REDIRECTS + 1)) ]] || fail 'redirect loop not bounded'
MOCK_REDIRECT_FIRST=""; MOCK_REDIRECT_TO=""

# Resolve qBittorrent's configured internal port through a VPN peer's mapping.
MOCK_PEER_INFO="$(jq '.[0].HostConfig={NetworkMode:"bridge"} | .[0].NetworkSettings={Ports:{"8090/tcp":[{HostIp:"0.0.0.0",HostPort:"18090"}]}}' <<<"$MOCK_INFO")"
qbit_info="$(jq '.[0].Config.Env=["WEBUI_PORT=8090"] | .[0].HostConfig={NetworkMode:"container:vpn"}' <<<"$MOCK_INFO")"
resolved="$(probe_url qbittorrent "$qbit_info" 8080 /api/v2/app/version)" || fail 'VPN peer route resolution failed'
[[ "$resolved" == "http://$DOCKER_HOST_IP:18090/api/v2/app/version" ]] || fail 'qBittorrent port/VPN mapping ignored'

# Reproduce Hubble's published-port timeout, followed by a validated loopback
# response. Explicit URLs must never be silently replaced by fallback routes.
MOCK_INFO="$(jq '.[0].HostConfig={NetworkMode:"bridge"} | .[0].Config.Env=[] |
    .[0].NetworkSettings={Ports:{"8080/tcp":[{HostIp:"0.0.0.0",HostPort:"8686"}]},Networks:{bridge:{IPAddress:"172.17.0.10"}}}' <<<"$MOCK_INFO")"
MOCK_HTTP_BODY=v5.1.0; MOCK_HTTP_CODE=200
MOCK_TRANSPORT_URL="http://$DOCKER_HOST_IP:8686/api/v2/app/version"
: >"$TEST_ROOT/requests"
readiness_probe qbittorrent '' || fail 'metadata fallback did not recover readiness'
[[ "$PROBE_RESULT" == ready && "$PROBE_MESSAGE" == *127.0.0.1:8686* ]] || fail 'fallback lacked qBittorrent validation'
[[ "$(wc -l <"$TEST_ROOT/requests")" -eq 2 ]] || fail 'unexpected fallback request count'
: >"$TEST_ROOT/requests"
if readiness_probe qbittorrent "$MOCK_TRANSPORT_URL"; then fail 'explicit failing URL replaced silently'; fi
[[ "$(wc -l <"$TEST_ROOT/requests")" -eq 1 ]] || fail 'explicit URL used extra routes'
MOCK_TRANSPORT_URL=""
safe="$(safe_probe_target 'http://user:password@fixture/path?apikey=secret')"
[[ "$safe" != *password* && "$safe" != *secret* ]] || fail 'probe diagnostics expose credentials'

# Shared transport failures inhibit ALL candidate restarts before actions run.
fresh; PROBE_FAILURES=([one]=1 [two]=1 [three]=1)
RECOVERY_CANDIDATES=('one||running|1' 'two||running|1')
evaluate_shared_failure || fail 'shared guard failed'
[[ "$SHARED_FAILURE" == true && -n "${RECOVERY_BLOCKED[one]:-}" && -n "${RECOVERY_BLOCKED[two]:-}" ]] || fail 'shared outage allowed recovery'
observe one:availability CRITICAL 'Existing individual failure' 1 >/dev/null
notify_changes || fail 'pending shared grouping notification failed'
jq -e '.notification.issues["one:availability"] == "CRITICAL"' "$STATE_WORK" >/dev/null || fail 'unconfirmed shared incident falsely cleared individual failure'
evaluate_shared_failure; notify_changes || fail 'confirmed shared grouping notification failed'
jq -e '.notification.issues["monitor:shared-dependency"] == "CRITICAL" and .notification.issues["one:availability"] == null' "$STATE_WORK" >/dev/null || fail 'confirmed shared incident not grouped'

# Internal job outcome comes from native status, not Docker uptime. Invalid
# evidence must not clear the last failure; stale runs and overruns are distinct.
fresh; PROFILE_BY_NAME[metafusion]=metafusion
MOCK_NATIVE="$(jq -nc --argjson now "$NOW" '{state:"idle",heartbeat_at:"2026-11-21T00:00:00Z",pid:1,last_run_started:($now-60),last_run_finished:$now,last_success:$now,last_run_status:"success"}')"
check_job metafusion "$MOCK_INFO" || fail 'native job status rejected'
jq -e --argjson now "$NOW" '.jobs.metafusion.success == $now' "$STATE_WORK" >/dev/null || fail 'native success missing'
NOW=$((NOW + 7*3600)); check_job metafusion "$MOCK_INFO" || fail 'native stale check failed'
[[ -n "${SEEN[metafusion:job-overdue]:-}" ]] || fail 'missed internal run not detected'
MOCK_NATIVE="$(jq -nc --argjson now "$NOW" '{state:"idle",heartbeat_at:"2026-11-21T00:00:00Z",pid:1,last_run_started:($now-60),last_run_finished:$now,last_run_status:"failed",last_error:"Provider request failed token=supersecret Authorization: Bearer hiddensecret https://user:secretpw@fixture/problem"}')"
check_job metafusion "$MOCK_INFO"; check_job metafusion "$MOCK_INFO"
active metafusion:job-failed || fail 'native failed job not classified'
detail="$(jq -r '.observations["metafusion:job-failed"].message' "$STATE_WORK")"
[[ "$detail" == *'Provider request failed'* && "$detail" != *supersecret* && "$detail" != *hiddensecret* && "$detail" != *secretpw* ]] || fail 'native failure detail missing or credentials exposed'
MOCK_NATIVE='{}'; SEEN=(); FROZEN_KEYS=()
check_job metafusion "$MOCK_INFO"; finish_observations
active metafusion:job-failed || fail 'invalid evidence falsely cleared failure'
NOW=$((NOW + 60))
MOCK_NATIVE="$(jq -nc --argjson now "$NOW" '{state:"idle",heartbeat_at:"2026-11-21T00:00:00Z",pid:1,last_run_started:($now-30),last_run_finished:$now,last_success:$now,last_run_status:"success"}')"
for recovery_scan in 1 2; do
    SEEN=(); FROZEN_KEYS=()
    check_job metafusion "$MOCK_INFO"; finish_observations
done
active metafusion:job-failed && fail 'verified successful job did not clear prior failure'

# A whole-run log banner counts completion but must not invent success.
fresh; NOW="$(date +%s)"
MOCK_LOGS="$(date -u '+%Y-%m-%dT%H:%M:%SZ') | Finished 04:00 Run |"
# Simulate a shell tail override that misinterprets a separated byte count.
# Production byte/line calls must bypass it and attach counts to options.
tail() { printf "tail: cannot open '262144' for reading\n" >&2; return 1; }
check_job kometa "$MOCK_INFO" || fail 'Kometa log completion check failed'
unset -f tail
[[ -n "${SEEN[kometa:job-unverified]:-}" ]] || fail 'completion banner reported verified success'
jq -e '.jobs.kometa.finished > 0 and .jobs.kometa.success == 0' "$STATE_WORK" >/dev/null || fail 'completion evidence incorrect'
MOCK_LOGS=""
check_job kometa "$MOCK_INFO" || fail 'cached log evidence failed'
[[ "$(jq -r .jobs.kometa.result "$STATE_WORK")" == completed-unverified ]] || fail 'unverified state silently cleared'

# Recyclarr frequency accepts a producer receipt, counts distinct completions,
# and permits a full initial window before flagging fewer than two runs.
mountpoint() { return 0; }
record_job recyclarr 0 "$((NOW-60))" || fail 'producer receipt creation failed'
check_job recyclarr "$MOCK_INFO" || fail 'producer receipt rejected'
NOW=$((NOW + 3600))
record_job recyclarr 0 "$((NOW-60))" || fail 'second producer receipt failed'
check_job recyclarr "$MOCK_INFO" || fail 'second producer receipt rejected'
jq -e '.jobs.recyclarr.history | length == 2' "$STATE_WORK" >/dev/null || fail 'successful completion history lost'
NOW=$((NOW + 192*3600 + 1)); SEEN=()
check_job recyclarr "$MOCK_INFO" || fail 'frequency audit failed'
[[ -n "${SEEN[recyclarr:job-frequency]:-}" ]] || fail 'twice-weekly completion frequency not checked'

# Recyclarr's actual resident cron output is sufficient without a receipt.
# Per-library completion alone is not. Preserve error/start context between scans.
fresh; NOW="$(date +%s)"; rm "$STATE_DIR/jobs/recyclarr.json"
start_stamp="$(date -u -d "@$((NOW-10))" '+%Y-%m-%dT%H:%M:%SZ')"
end_stamp="$(date -u -d "@$((NOW-1))" '+%Y-%m-%dT%H:%M:%SZ')"
MOCK_LOGS="$start_stamp level=info msg=starting iteration=0 job.command=/cron.sh job.position=0 job.schedule=\"0 6 * * 3,7\"
$end_stamp [INF] radarr: Completed at 11/22/2026 06:00:03
$end_stamp [INF] sonarr: Completed at 11/22/2026 06:00:03
$end_stamp level=info msg=\"job succeeded\" iteration=0 job.command=/cron.sh job.position=0 job.schedule=\"0 6 * * 3,7\""
check_job recyclarr "$MOCK_INFO" || fail 'native cron success parse failed'
jq -e '.jobs.recyclarr.result == "success" and .jobs.recyclarr.success > 0 and (.jobs.recyclarr.history | length) == 1' "$STATE_WORK" >/dev/null || fail 'native cron success not recorded'
[[ -z "${SEEN[recyclarr:job-evidence]:-}" && -z "${SEEN[recyclarr:job-unverified]:-}" ]] || fail 'valid scheduler result still requires receipt'

fresh
MOCK_LOGS="$start_stamp level=info msg=starting iteration=1 job.command=/cron.sh job.position=0
$end_stamp [ERR] Failed to synchronize Sonarr"
check_job recyclarr "$MOCK_INFO" || fail 'open cron context failed'
MOCK_LOGS="$end_stamp level=info msg=\"job succeeded\" iteration=1 job.command=/cron.sh job.position=0"
check_job recyclarr "$MOCK_INFO" || fail 'terminal cron context failed'
[[ "$(jq -r '.jobs.recyclarr.result' "$STATE_WORK")" == failed ]] || fail 'scheduler zero exit hid application error'

fresh; MOCK_LOGS="$end_stamp [INF] radarr: Completed at 11/22/2026 06:00:03"
check_job recyclarr "$MOCK_INFO" || fail 'library-only parse failed'
jq -e '.jobs.recyclarr.success == 0 and .jobs.recyclarr.finished == 0' "$STATE_WORK" >/dev/null || fail 'per-library line invented whole-job success'
MOCK_LOGS=""; check_job recyclarr "$MOCK_INFO" || fail 'empty cached context broke next scan'

fresh
MOCK_LOGS="$end_stamp level=info msg=\"job succeeded\" iteration=5 job.command=/cron.sh job.position=0"
check_job recyclarr "$MOCK_INFO" || fail 'truncated cron window failed'
[[ "$(jq -r '.jobs.recyclarr.result' "$STATE_WORK")" == completed-unverified ]] || fail 'missing start/error scope invented success'

# Flapping collapses oscillations into a stable incident and blocks recovery.
fresh; EFFECTIVE_SPECS=('service||always|0'); NOW="$(date +%s)"
for state in false true false true false true; do
    if [[ "$state" == true ]]; then observe service:availability CRITICAL 'Fixture down' 1 >/dev/null
    else mutate 'del(.observations["service:availability"])'; fi
    apply_flapping || fail 'flapping update failed'
    NOW=$((NOW + 30))
done
active service:unstable || fail 'flapping not detected'
[[ -n "${RECOVERY_BLOCKED[service]:-}" ]] || fail 'flapping recovery not inhibited'

# Application incident exit code 1 still represents a successful monitor scan.
NOW="$(date +%s)"; EXECUTION_COMPLETE=false
heartbeat_event start || fail 'execution heartbeat start failed'
EXECUTION_COMPLETE=true; heartbeat_event finish 1 || fail 'execution completion heartbeat failed'
jq -e '.failures == 0 and .lastSuccessful > 0 and .exitCode == 1' "$HEARTBEAT_FILE" >/dev/null || fail 'container incident counted as monitor crash'
EXECUTION_COMPLETE=false; heartbeat_event start; heartbeat_event finish 2
jq -e '.failures == 1' "$HEARTBEAT_FILE" >/dev/null || fail 'monitor failure not recorded'

# End-to-end main orchestration: discovery precedes scans, state/receipt commit,
# and EXIT checkpoint is emitted from an independent shell invocation.
fresh; NOW="$(date +%s)"; save_state || fail 'fixture state save failed'
SERVICE_SPECS=('service||always|0'); PROBE_RULES=(); JOB_RULES=(); JOB_FREQUENCY_RULES=()
MOCK_INVENTORY=service; MOCK_ENDPOINT=true; make_info running healthy
AUTO_RESTART=false; LOG_MAX_BYTES=1048576; LOCK_FILE="$TEST_ROOT/main.lock"
STATUS_DIR="$TEST_ROOT/status"; UPTIME_FILE="$TEST_ROOT/uptime"
printf '99999.00 0.00\n' >"$UPTIME_FILE"
docker() { return 0; }
(main) >"$TEST_ROOT/main.log" 2>&1 || { cat "$TEST_ROOT/main.log" >&2; fail 'main orchestration failed'; }
jq -e '.status == "OK" and .scriptVersion == "3.2"' "$STATUS_DIR/docker_service_watchdog.json" >/dev/null || fail 'main receipt incorrect'
jq -e '.phase == "completed" and .executionComplete == true and .failures == 0' "$HEARTBEAT_FILE" >/dev/null || fail 'main heartbeat not finalized'
printf 'docker_service_watchdog fixture tests passed\n'
