#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/docker_watchdog_test.XXXXXX)"
trap 'rm -rf -- "${TEST_ROOT:?}"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC1091
source "$ROOT/user_script/docker_service_watchdog.sh"
STATE_DIR="$TEST_ROOT/state"; mkdir -p "$STATE_DIR"
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
    SEEN=(); FROZEN=(); RECOVERY_BLOCKED=(); RECOVERY_SAFE=true
}
scan() { SEEN=(); FROZEN=(); check_service "$1" || fail 'service scan failed'; finish_observations || fail 'observation completion failed'; }
active() { jq -e --arg key "$1" '.observations[$key].active == true' "$STATE_WORK" >/dev/null; }
make_info() {
    MOCK_INFO="$(jq -nc --arg state "$1" --arg health "${2:-none}" --argjson oom "${3:-false}" --argjson restart "${4:-0}" \
        '[{Id:"container-1",RestartCount:$restart,LogPath:"",State:{Status:$state,Health:{Status:$health},OOMKilled:$oom,StartedAt:"2020-01-01T00:00:00Z"}}]')"
}
MOCK_INSPECT_FAIL=false; MOCK_RESTART_FAIL=false; MOCK_ENDPOINT=true
docker_cmd() {
    case "$1" in
        inspect) [[ "$MOCK_INSPECT_FAIL" != true ]] || return 124; printf '%s\n' "$MOCK_INFO" ;;
        container) printf 'service\n' ;;
        restart)
            printf 'attempt\n' >>"$TEST_ROOT/restarts"
            [[ "$MOCK_RESTART_FAIL" != true ]] || return 124
            make_info running healthy
            ;;
        *) return 0 ;;
    esac
}
endpoint_healthy() { [[ "$MOCK_ENDPOINT" == true ]]; }

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
LOG_MAX_BYTES=4096
head -c 20000 /dev/zero >"$LOG_FILE"
bound_existing_logs || fail 'legacy log bounding failed'
log INFO 'Fixture rotation' >/dev/null
[[ "$(stat -c %s "$LOG_FILE.1")" -le "$LOG_MAX_BYTES" ]] || fail 'legacy log exceeded retained cap'
printf 'docker_service_watchdog fixture tests passed\n'
