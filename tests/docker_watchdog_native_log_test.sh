#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/docker_watchdog_native.XXXXXX)"
trap 'rm -rf -- "${TEST_ROOT:?}"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC1091
source "$ROOT/user_script/docker_service_watchdog.sh"
date() { if command -v gdate >/dev/null; then gdate "$@"; else command date "$@"; fi; }
stat() { if command -v gstat >/dev/null; then gstat "$@"; else command stat "$@"; fi; }
export TZ=Asia/Singapore
NOW="$(date -d '2026-11-22 18:00:00' +%s)"
TMP_DIR="$TEST_ROOT/tmp"; mkdir -p "$TMP_DIR"
STATE_DIR="$TEST_ROOT/state"; mkdir -p "$STATE_DIR"
STATE_WORK="$TEST_ROOT/work.json"; LOG_FILE="$TEST_ROOT/watchdog.log"
DOCKER_MAINTENANCE_DIR="$TEST_ROOT/maintenance"; mkdir -p "$DOCKER_MAINTENANCE_DIR"
HEARTBEAT_FILE="$TEST_ROOT/heartbeat.json"; BOOT_ID=fixture
STATE_FILE="$STATE_DIR/state.json"
MOCK_INFO='[{"Id":"native-1","RestartCount":0,"LogPath":"","State":{"Status":"running","Health":{"Status":"healthy"},"OOMKilled":false,"StartedAt":"2026-11-20T00:00:00Z"}}]'
old='{}'; path="$TEST_ROOT/meta.log"; result="$TEST_ROOT/result.json"
profile=kometa
MOCK_RESTART_HEALTH=healthy
docker_cmd() {
    if [[ "$1" == exec && "$2" == -i ]]; then shift 3; "$@"
    elif [[ "$1" == inspect ]]; then printf '%s\n' "$MOCK_INFO"
    elif [[ "$1" == events ]]; then
        printf '{"Actor":{"ID":"native-1"},"Action":"die","time":%s}\n' "$((NOW-60))"
    elif [[ "$1" == restart || "$1" == start ]]; then
        printf 'restart\n' >>"$TEST_ROOT/restarts"
        MOCK_INFO="$(jq --arg health "$MOCK_RESTART_HEALTH" '.[0].State.Status="running" | if $health == "none" then del(.[0].State.Health) else .[0].State.Health.Status=$health end' <<<"$MOCK_INFO")"
    else return 1; fi
}
flock() { return 0; }
sleep() { :; }
fresh() {
    printf '{"version":2,"bootId":"fixture","services":{},"recovery":{},"observations":{},"notification":{"issues":{}}}\n' >"$STATE_WORK"
    SEEN=(); FROZEN=(); FROZEN_KEYS=(); RECOVERY_BLOCKED=(); PROFILE_BY_NAME=(); RECOVERY_CANDIDATES=()
}
emit() { printf '[%s,123] %-27s %-10s | %s |\n' "$1" "[$profile.py:499]" "[$2]" "$3" >>"$path"; }
begin() { emit "$1" INFO "${2:-Starting Run}"; }
end_run() {
    emit "$1" INFO 'Finished Run'
    emit "$1" INFO 'Start Time: 12:00:00 2026-11-22     Finished: 12:01:00 2026-11-22     Run Time: 0:01:00'
}
read_log() {
    read_native_run_log "$profile" "$profile" "$path" "$MOCK_INFO" "$old" >"$result" || fail 'native reader failed'
    jq -e . "$result" >/dev/null || fail 'reader did not return JSON'
    old="$(jq -c '{runLog:.reader}' "$result")"
}
assert_json() { jq -e "$1" "$result" >/dev/null || { cat "$result" >&2; fail "$2"; }; }

# Full run, local-time timestamps, duplicate error and summary text, and a
# message containing credentials. A completion banner alone is insufficient.
begin '2026-11-22 12:00:00'
emit '2026-11-22 12:00:10' ERROR 'Collection A: Plex update failed token=private-secret'
emit '2026-11-22 12:00:11' ERROR 'Collection A: Plex update failed token=private-secret'
emit '2026-11-22 12:00:12' INFO 'Error Summary'
emit '2026-11-22 12:00:13' INFO '    2 | Collection A: Plex update failed'
emit '2026-11-22 12:01:00' INFO 'Finished Run'
read_log
assert_json '.finished == 0 and .success == 0' 'banner without footer became success'
emit '2026-11-22 12:01:00' INFO 'Start Time: 12:00:00     Finished: 12:01:00     Run Time: 0:01:00'
read_log
assert_json '.result == "completed-errors" and (.findings.errors.keys | length) == 1 and .success == 0' 'partial errors not classified/deduplicated'
if grep -q private-secret "$result"; then fail 'secret persisted in reader state'; fi
saved_cursor="$(jq -c .reader.cursor "$result")"
read_log
[[ "$(jq -c .reader.cursor "$result")" == "$saved_cursor" ]] || fail 'unchanged log moved cursor'
assert_json '.result == "completed-errors"' 'unchanged log lost prior failure'

# Error is near the beginning of a large run, outside the previous 256 KiB
# tail. A low scan budget must checkpoint and resume without inventing success.
rm "$path"; old='{}'
begin '2026-11-22 12:10:00'
emit '2026-11-22 12:10:01' ERROR 'Early-run failure outside tail'
python3 -c 'import sys; open(sys.argv[1], "a").write("[2026-11-22 12:10:02,123] [kometa.py:499] [DEBUG] | ordinary activity |\n" * 6000)' "$path"
end_run '2026-11-22 12:11:00'
JOB_LOG_SCAN_MAX_BYTES=65536
read_log
assert_json '.backlog and .finished == 0' 'partial bootstrap reported success'
for pass in {1..8}; do read_log; [[ "$(jq -r .backlog "$result")" == true ]] || break; done
assert_json '.backlog == false and .result == "completed-errors"' 'cursor lost early-run error'
JOB_LOG_SCAN_MAX_BYTES=$((128*1024*1024))

# Rotation drains the old descriptor's remainder, then reads a new run. The
# old failure remains visible while the new run is active, then resolves.
mv "$path" "$TEST_ROOT/meta-1.log"
begin '2026-11-22 13:00:00'
read_log
assert_json '.result == "completed-errors" and .started > .finished' 'new active run concealed prior failure'
end_run '2026-11-22 13:01:00'
read_log
assert_json '.result == "success" and .success == .finished and .success > 0' 'new clean run did not resolve failure'

# Both the current and immediately previous native log are read on bootstrap.
old='{}'
mv "$path" "$TEST_ROOT/meta-1.log"
begin '2026-11-22 14:00:00'
read_log
assert_json '.result == "success" and .started > .finished' 'bootstrap missed previous completed run'

# Copytruncate/rewrite on the same inode must invalidate the offset/anchors.
: >"$path"
begin '2026-11-22 14:10:00'
emit '2026-11-22 14:10:01' CRITICAL 'Configuration cannot load'
end_run '2026-11-22 14:11:00'
read_log
assert_json '.result == "failed" and .incomplete == false' 'rewritten native log falsely remained healthy'

# Test-run completion and a naked completion tail never establish success.
rm "$path" "$TEST_ROOT/meta-1.log"; old='{}'
begin '2026-11-22 14:20:00' 'Starting Test Run'
emit '2026-11-22 14:20:01' CRITICAL 'Manual test failure'
emit '2026-11-22 14:21:00' INFO 'Finished Test Run'
read_log
assert_json '.success == 0 and .finished == 0 and .activeFatal == {}' 'test run counted as scheduled outcome'
: >"$path"; old='{}'
end_run '2026-11-22 14:31:00'
read_log
assert_json '.result == "completed-unverified" and .success == 0' 'missing run start became success'

# A future/changed log-record format must not silently turn a run clean.
: >"$path"; old='{}'
begin '2026-11-22 14:40:00'
printf '[2026-11-22 14:40:01] new-format level=ERROR processing failed\n' >>"$path"
end_run '2026-11-22 14:41:00'
read_log
assert_json '.result == "completed-unverified" and .success == 0 and .incomplete' 'unsupported format reported clean'

# Exercise Hubble's actual scale without copying the native log through the
# Bash monitor: the error at its beginning must survive a 70 MiB run.
rm "$path"; old='{}'
begin '2026-11-22 14:45:00'
emit '2026-11-22 14:45:01' ERROR 'Early error in 70 MiB run'
python3 - "$path" <<'PY'
import sys
line = b"[2026-11-22 14:45:02,123] [kometa.py:499] [DEBUG] | ordinary activity |\n"
chunk = line * 1024
with open(sys.argv[1], "ab") as handle:
    for _ in range((70 * 1024 * 1024) // len(chunk) + 1):
        handle.write(chunk)
PY
end_run '2026-11-22 14:46:00'
for pass in 1 2 3; do read_log; [[ "$(jq -r .backlog "$result")" == true ]] || break; done
assert_json '.backlog == false and .result == "completed-errors" and .reader.cursor.offset > 70000000' 'large native run lost early failure or did not drain'
read_log
assert_json '.backlog == false and .result == "completed-errors"' 'unchanged large run rescanned incorrectly'

# ImageMaid does not write "Script Started" to its native log. Its validation
# header is the start, and caught exceptions may still print the normal footer.
profile=imagemaid; path="$TEST_ROOT/imagemaid.log"; old='{}'
begin '2026-11-22 07:00:00' 'Validating Options'
emit '2026-11-22 07:00:01' CRITICAL 'Directory Error: Plex databases not found'
emit '2026-11-22 07:00:02' INFO 'Critical Report'
emit '2026-11-22 07:00:03' ERROR 'Directory Error: Plex databases not found'
emit '2026-11-22 07:00:04' INFO 'ImageMaid Summary'
emit '2026-11-22 07:01:00' INFO 'ImageMaid Finished'
emit '2026-11-22 07:01:00' INFO 'Total Runtime      | 0:01:00'
read_log
assert_json '.result == "failed" and (.findings.fatal.keys | length) == 1 and (.findings.errors // {} | length) == 0' 'ImageMaid caught exception falsely became success'
mv "$path" "$TEST_ROOT/imagemaid-1.log"
begin '2026-11-22 15:00:00' 'Validating Options'
emit '2026-11-22 15:00:01' WARNING 'One optional operation was skipped'
emit '2026-11-22 15:01:00' INFO 'ImageMaid Summary'
emit '2026-11-22 15:01:00' INFO 'ImageMaid Finished'
emit '2026-11-22 15:01:00' INFO 'Total Runtime      | 0:01:00'
read_log
assert_json '.result == "completed-warnings" and .success == 0' 'ImageMaid warning severity incorrect'

# Literal records supplied from Hubble, including fmt_filter's [filename:line]
# and [LEVEL] decorations. An idle weekly job must resolve from its existing
# completed native log; no new scheduled/manual processing is required.
path="$TEST_ROOT/idle-imagemaid.log"; old='{}'
cat >"$path" <<'LOG'
[2026-11-22 07:00:51,335] [imagemaid.py:110]          [INFO]     |====================================================================================================|
[2026-11-22 07:00:51,402] [imagemaid.py:111]          [INFO]     |======================================== Validating Options ========================================|
[2026-11-22 07:02:52,479] [imagemaid.py:499]          [INFO]     |======================================== ImageMaid Finished ========================================|
[2026-11-22 07:02:52,479] [imagemaid.py:499]          [INFO]     | Total Runtime      | 0:02:01                                                                       |
LOG
read_log
assert_json '.result == "success" and .incomplete == false and .finished > 0 and .reader.parserVersion == 2' 'Hubble idle ImageMaid log rejected'
old="$(jq -c '{runLog:(.reader | del(.parserVersion, .active) | .gap=true | .completed={} | .successfulAt=0)}' "$result")"
read_log
assert_json '.result == "success" and .incomplete == false and .reader.parserVersion == 2' 'v3.4 EOF/gap state prevented idle-log repair'

# The running Kometa job has no normal whole-run footer yet. Collection names
# containing "Run" must not count as completed scheduled work.
profile=kometa; path="$TEST_ROOT/live-meta.log"; old='{}'
cat >"$path" <<'LOG'
[2026-11-22 16:00:45,362] [kometa.py:498]             [INFO]     |====================================================================================================|
[2026-11-22 16:00:48,186] [kometa.py:644]             [INFO]     |                                         Starting 16:00 Run                                         |
[2026-11-22 16:03:17,887] [kometa.py:1385]            [INFO]     |                                  Finished Blade Runner Collection                                  |
[2026-11-22 16:04:53,071] [kometa.py:1385]            [INFO]     |                                Finished The Maze Runner Collection                                 |
LOG
read_log
assert_json '.started > 0 and .finished == 0 and .success == 0 and .incomplete == false' 'running Hubble Kometa run misclassified'
emit '2026-11-22 16:05:00' ERROR 'An actual bracketed processing error'
end_run '2026-11-22 16:06:00'
read_log
assert_json '.result == "completed-errors" and .success == 0' 'bracketed ERROR did not affect outcome'

# Bash integration: grouped failures recover after two clean scans. The
# application result cannot enqueue a restart for an otherwise healthy Docker.
fresh; profile=kometa; path="$TEST_ROOT/integrated.log"
JOB_RULES=("kometa|6|24|runlog:$path")
begin '2026-11-22 16:00:00'
emit '2026-11-22 16:00:01' ERROR 'Collection failed'
end_run '2026-11-22 16:01:00'
native_finished="$(date -d '2026-11-22 16:01:00' +%s)"
mutate --argjson received "$((native_finished+2))" --arg source "$path" '.jobs={kometa:{firstSeen:$received,started:0,finished:$received,success:0,result:"completed-unverified",scanned:$received,history:[],logState:{},runLog:{version:1,source:$source,containerId:"native-1",gap:true}}}'
for pass in 1 2; do SEEN=(); check_service 'kometa||always|1'; finish_observations; done
jq -e '.observations["kometa:job-errors"].active == true' "$STATE_WORK" >/dev/null || fail 'partial failure not confirmed'
jq -e --argjson native "$native_finished" '.jobs.kometa.result == "completed-errors" and .jobs.kometa.finished == $native' "$STATE_WORK" >/dev/null || fail 'Docker receive timestamp prevented native evidence upgrade'
[[ ${#RECOVERY_CANDIDATES[@]} == 0 && ! -e "$TEST_ROOT/restarts" ]] || fail 'job failure restarted a healthy container'
: >"$path"; begin '2026-11-22 17:00:00'; end_run '2026-11-22 17:01:00'
for pass in 1 2; do SEEN=(); check_service 'kometa||always|1'; finish_observations; done
jq -e '.observations["kometa:job-errors"] == null and .jobs.kometa.result == "success"' "$STATE_WORK" >/dev/null || fail 'clean run did not resolve grouped error'
state_valid "$STATE_WORK" || fail 'native reader checkpoint violates state schema'

# A late report/notification error revises the same run, retracting the prior
# clean timestamp and history entry instead of preserving a false success.
emit '2026-11-22 17:01:01' ERROR 'Report delivery failed'
SEEN=(); check_job kometa "$MOCK_INFO" || fail 'late report error scan failed'
jq -e '.jobs.kometa.result == "completed-errors" and .jobs.kometa.success == 0 and (.jobs.kometa.history | length) == 0' "$STATE_WORK" >/dev/null || fail 'late error retained false successful completion'

# Evidence gaps do not conceal an already-overdue completion deadline.
NOW=$((NOW + 7*3600)); rm "$path"
SEEN=(); check_job kometa "$MOCK_INFO" || fail 'unavailable overdue log check failed'
[[ -n "${SEEN[kometa:job-overdue]:-}" ]] || fail 'missing log hid missed completion'
NOW=$((NOW - 7*3600))

# A missing log/failed docker exec does not inhibit genuine Docker health
# recovery. Existing global/per-container switches and budget still apply.
fresh
MOCK_INFO="$(jq '.[0].State.Health.Status="unhealthy"' <<<"$MOCK_INFO")"
AUTO_RESTART=true; CONSECUTIVE_FAILURES_BEFORE_RESTART=1
check_service 'kometa||always|1' || fail 'unhealthy container scan failed'
[[ -z "${RECOVERY_BLOCKED[kometa]:-}" ]] || fail 'missing native log blocked Docker recovery'
AUTO_RESTART=false
attempt_recovery kometa '' running 1
[[ ! -e "$TEST_ROOT/restarts" ]] || fail 'global restart opt-out bypassed'
AUTO_RESTART=true
attempt_recovery kometa '' running 0
[[ ! -e "$TEST_ROOT/restarts" ]] || fail 'per-container restart opt-out bypassed'
attempt_recovery kometa '' running 1
[[ "$(wc -l <"$TEST_ROOT/restarts")" -eq 1 ]] || fail 'Docker health recovery no longer works'

# Unknown stopped containers stay stopped; native exit proof is required. Images with no health
# check/probe can verify Docker state only and must say so in the notification.
fresh; MOCK_RESTART_HEALTH=none
MOCK_INFO="$(jq '.[0].State.Status="exited" | del(.[0].State.Health)' <<<"$MOCK_INFO")"
check_service 'kometa||always|1' || fail 'stopped container scan failed'
RECOVER_UNEXPECTED_EXITS=false
RESTART_STOPPED_CONTAINERS=false
attempt_recovery kometa '' exited 1
[[ "$(wc -l <"$TEST_ROOT/restarts")" -eq 1 ]] || fail 'stopped container restarted without permission'
RESTART_STOPPED_CONTAINERS=true
attempt_recovery kometa '' exited 1
[[ "$(wc -l <"$TEST_ROOT/restarts")" -eq 1 ]] || fail 'blanket stopped opt-in bypassed missing history'
RECOVER_UNEXPECTED_EXITS=true; RESTART_STOPPED_CONTAINERS=false
MOCK_INFO="$(jq --arg finished "$(date -d "@$((NOW-60))" -Iseconds)" '.[0].State.FinishedAt=$finished' <<<"$MOCK_INFO")"
mutate --argjson last "$((NOW-120))" '.services.kometa.lastRunningAt=$last'
attempt_recovery kometa '' exited 1
[[ "$(wc -l <"$TEST_ROOT/restarts")" -eq 2 ]] || fail 'permitted stopped-container recovery failed'
jq -e '.observations["kometa:recovery-action"].message | contains("no Docker healthcheck")' "$STATE_WORK" >/dev/null || fail 'state-only recovery claimed application readiness'
printf 'docker watchdog native-log tests passed\n'
