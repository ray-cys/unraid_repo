#!/bin/bash

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/user_script/dns_redundancy_watchdog.sh"
TEST_ROOT="$(mktemp -d /tmp/dns_redundancy_watchdog_test.XXXXXX)"

cleanup() {
    case "$TEST_ROOT" in
        /tmp/dns_redundancy_watchdog_test.*)
            rm -rf -- "$TEST_ROOT"
            ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local pattern="$2"

    grep -Fq -- "$pattern" "$file" ||
        fail "expected '$pattern' in $file"
}

make_mocks() {
    local root="$1"

    mkdir -p -- "$root/bin" "$root/state" "$root/status"

    cat >"$root/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF

    cat >"$root/bin/mountpoint" <<'EOF'
#!/bin/sh
exit 0
EOF

    cat >"$root/bin/ping" <<'EOF'
#!/bin/sh
exit 0
EOF

    cat >"$root/bin/notify" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${MOCK_NOTIFY_LOG}"
printf 'call\n' >>"${MOCK_NOTIFY_COUNT}"
EOF

    cat >"$root/bin/dig" <<'EOF'
#!/bin/sh
server=""
domain=""
transport="udp"

for argument in "$@"; do
    case "$argument" in
        @*) server="${argument#@}" ;;
        +tcp) transport="tcp" ;;
        +*) ;;
        A) ;;
        *)
            if [ -z "$domain" ]; then
                domain="$argument"
            fi
            ;;
    esac
done

mode="healthy"
if [ "$server" = "$MOCK_PRIMARY_IP" ]; then
    mode="${MOCK_PRIMARY_MODE:-healthy}"
    [ -e "${MOCK_DIR}/primary_restarted" ] && mode="healthy"
elif [ "$server" = "$MOCK_FALLBACK_IP" ]; then
    mode="${MOCK_FALLBACK_MODE:-healthy}"
    [ -e "${MOCK_DIR}/fallback_restarted" ] && mode="healthy"
fi

if [ "$mode" = "service_down" ]; then
    exit 9
fi

if [ "$domain" = "$MOCK_EXTERNAL_DOMAIN" ] &&
   [ "$mode" = "upstream_down" ]; then
    printf ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1\n'
    printf ';; Query time: 1 msec\n'
    exit 0
fi

answer="203.0.113.10"
if [ "$domain" = "$MOCK_LOCAL_DOMAIN" ]; then
    answer="$server"
elif [ "$domain" = "${MOCK_DRIFT_DOMAIN:-drift.test}" ]; then
    if [ "$server" = "$MOCK_PRIMARY_IP" ]; then
        answer="203.0.113.11"
    else
        answer="203.0.113.12"
    fi
fi

printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n'
printf '%s. 60 IN A %s\n' "$domain" "$answer"
if [ "$transport" = "tcp" ]; then
    printf ';; Query time: 2 msec\n'
else
    printf ';; Query time: 1 msec\n'
fi
EOF

    cat >"$root/bin/docker" <<'EOF'
#!/bin/sh
command_name="${1:-}"
shift || true

case "$command_name" in
    inspect)
        cat <<JSON
[{"State":{"Status":"running","Health":{"Status":"healthy"},"OOMKilled":false,"StartedAt":"2020-01-01T00:00:00Z"},"RestartCount":0}]
JSON
        ;;
    info)
        exit 0
        ;;
    restart|start)
        : >"${MOCK_DIR}/primary_restarted"
        ;;
    exec)
        printf '[]\n'
        ;;
    *)
        exit 1
        ;;
esac
EOF

    cat >"$root/bin/ssh" <<'EOF'
#!/bin/sh

while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            shift 2
            ;;
        *)
            shift
            break
            ;;
    esac
done

remote_command="$*"

case "$remote_command" in
    *"systemctl restart pihole-FTL"*)
        : >"${MOCK_DIR}/fallback_restarted"
        ;;
    *"printf 'ftl='"*)
        printf 'ftl=active\n'
        printf 'disk=50\n'
        printf 'temp=45.0\n'
        ;;
    *"pihole-FTL --config dns.upstreams"*)
        printf '[]\n'
        ;;
    *)
        exit 0
        ;;
esac
EOF

    chmod +x "$root/bin/"*
}

run_watchdog() {
    local root="$1"
    local primary_mode="$2"
    local fallback_mode="$3"
    local output="$4"
    shift 4

    env \
        PATH="$root/bin:$PATH" \
        PRIMARY_DNS_IP=192.0.2.10 \
        PRIMARY_CONTAINER=pihole \
        FALLBACK_DNS_IP=192.0.2.20 \
        FALLBACK_SSH_USER=admin \
        LOCAL_TEST_DOMAIN=pi.hole \
        EXTERNAL_TEST_DOMAIN=example.com \
        PRIMARY_FAIL_THRESHOLD=1 \
        FALLBACK_FAIL_THRESHOLD=1 \
        BOTH_FAIL_THRESHOLD=1 \
        RECOVERY_COOLDOWN_SECONDS=0 \
        PRIMARY_RESTART_WAIT_SECONDS=0 \
        FALLBACK_RESTART_WAIT_SECONDS=0 \
        BOOT_GRACE_SECONDS=0 \
        CONTAINER_START_GRACE_SECONDS=0 \
        REMINDER_SECONDS=999999 \
        DEEP_CHECK_INTERVAL_SECONDS=9999999999 \
        DEEP_FAILURE_RECHECK_SECONDS=9999999999 \
        REQUIRE_VAULT_MOUNT=false \
        STATE_DIR="$root/state" \
        STATE_FILE="$root/state/state.json" \
        MAINTENANCE_DIR="$root/state/maintenance" \
        LOG_FILE="$root/state/watchdog.log" \
        STATUS_DIR="$root/status" \
        NOTIFY_BIN="$root/bin/notify" \
        LOCK_FILE="$root/watchdog.lock" \
        MOCK_DIR="$root" \
        MOCK_NOTIFY_LOG="$root/notify.log" \
        MOCK_NOTIFY_COUNT="$root/notify.count" \
        MOCK_PRIMARY_IP=192.0.2.10 \
        MOCK_FALLBACK_IP=192.0.2.20 \
        MOCK_LOCAL_DOMAIN=pi.hole \
        MOCK_EXTERNAL_DOMAIN=example.com \
        MOCK_DRIFT_DOMAIN=drift.test \
        MOCK_PRIMARY_MODE="$primary_mode" \
        MOCK_FALLBACK_MODE="$fallback_mode" \
        "$@" \
        bash "$SCRIPT" >"$output" 2>&1
}


###############################################################################
# Both resolvers healthy: no alert and an OK receipt
###############################################################################

HEALTHY_ROOT="${TEST_ROOT}/healthy"
make_mocks "$HEALTHY_ROOT"
run_watchdog "$HEALTHY_ROOT" healthy healthy "$HEALTHY_ROOT/run.out" ||
    fail "healthy watchdog run failed"

assert_contains "$HEALTHY_ROOT/run.out" "Initial classification=HEALTHY"
assert_contains "$HEALTHY_ROOT/status/dns_redundancy_watchdog.json" '"status": "OK"'
[[ ! -s "$HEALTHY_ROOT/notify.log" ]] ||
    fail "healthy initial run sent a notification"


###############################################################################
# Daily deep check detects DNS configuration drift
###############################################################################

DEEP_ROOT="${TEST_ROOT}/deep"
make_mocks "$DEEP_ROOT"
run_watchdog \
    "$DEEP_ROOT" \
    healthy \
    healthy \
    "$DEEP_ROOT/run.out" \
    DEEP_CHECK_INTERVAL_SECONDS=1 \
    CONSISTENCY_TEST_DOMAIN=drift.test ||
    fail "deep-health watchdog run failed"

assert_contains "$DEEP_ROOT/notify.log" \
    "DNS consistency mismatch for drift.test"
assert_contains "$DEEP_ROOT/status/dns_redundancy_watchdog.json" \
    '"status": "WARNING"'


###############################################################################
# Primary fails: Docker restart restores it while fallback remains available
###############################################################################

PRIMARY_ROOT="${TEST_ROOT}/primary"
make_mocks "$PRIMARY_ROOT"
run_watchdog "$PRIMARY_ROOT" service_down healthy "$PRIMARY_ROOT/run.out" ||
    fail "primary automatic recovery failed"

[[ -e "$PRIMARY_ROOT/primary_restarted" ]] ||
    fail "primary container restart was not attempted"
assert_contains "$PRIMARY_ROOT/notify.log" "DNS redundancy automatically recovered"
assert_contains "$PRIMARY_ROOT/notify.log" \
    "Primary: container restart restored UDP and TCP DNS"


###############################################################################
# Fallback fails: SSH FTL restart restores redundancy
###############################################################################

FALLBACK_ROOT="${TEST_ROOT}/fallback"
make_mocks "$FALLBACK_ROOT"
run_watchdog "$FALLBACK_ROOT" healthy service_down "$FALLBACK_ROOT/run.out" ||
    fail "fallback automatic recovery failed"

[[ -e "$FALLBACK_ROOT/fallback_restarted" ]] ||
    fail "fallback FTL restart was not attempted"
assert_contains "$FALLBACK_ROOT/notify.log" \
    "Fallback: pihole-FTL restart restored UDP and TCP DNS"


###############################################################################
# Both services fail: both recoveries are grouped into one notification
###############################################################################

BOTH_ROOT="${TEST_ROOT}/both"
make_mocks "$BOTH_ROOT"
run_watchdog "$BOTH_ROOT" service_down service_down "$BOTH_ROOT/run.out" ||
    fail "dual automatic recovery failed"

[[ -e "$BOTH_ROOT/primary_restarted" &&
   -e "$BOTH_ROOT/fallback_restarted" ]] ||
    fail "dual failure did not attempt both recoveries"

[[ "$(wc -l <"$BOTH_ROOT/notify.count" | tr -d '[:space:]')" -eq 1 ]] ||
    fail "dual recovery did not use one grouped notification"


###############################################################################
# Shared upstream failure: no restart storm and no duplicate reminder
###############################################################################

UPSTREAM_ROOT="${TEST_ROOT}/upstream"
make_mocks "$UPSTREAM_ROOT"

if run_watchdog \
    "$UPSTREAM_ROOT" upstream_down upstream_down "$UPSTREAM_ROOT/run-one.out"
then
    fail "shared upstream outage unexpectedly returned healthy"
fi

assert_contains "$UPSTREAM_ROOT/run-one.out" \
    "Initial classification=SHARED_UPSTREAM_FAILURE"
assert_contains "$UPSTREAM_ROOT/notify.log" \
    "Both Pi-holes have an upstream DNS failure"

[[ ! -e "$UPSTREAM_ROOT/primary_restarted" &&
   ! -e "$UPSTREAM_ROOT/fallback_restarted" ]] ||
    fail "shared upstream outage triggered a resolver restart"

if run_watchdog \
    "$UPSTREAM_ROOT" upstream_down upstream_down "$UPSTREAM_ROOT/run-two.out"
then
    fail "second shared upstream outage unexpectedly returned healthy"
fi

[[ "$(wc -l <"$UPSTREAM_ROOT/notify.count" | tr -d '[:space:]')" -eq 1 ]] ||
    fail "unchanged upstream outage sent a duplicate notification"

printf 'dns_redundancy_watchdog fixture tests passed\n'
