#!/bin/bash

###############################################################################
# Raspberry Pi / Pi-hole External Watchdog
#
# PURPOSE
# -------
# Run from Unraid to externally monitor a Raspberry Pi running Pi-hole.
#
# Checks:
#   1. Raspberry Pi responds to ping
#   2. Pi-hole answers DNS queries
#
# Recovery:
#   - If RPi is reachable but DNS fails repeatedly:
#       Attempt remote restart of pihole-FTL over SSH
#   - Re-test DNS after restart
#
# Notifications:
#   - Unraid warning when Pi-hole DNS fails repeatedly
#   - Unraid critical alert when Raspberry Pi is unreachable
#   - Unraid normal notification when automatic recovery succeeds
#   - Recovery notification when a previously failed service becomes healthy
#
# Recommended schedule:
#   Every 5 minutes
#
###############################################################################

set -uo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

# Raspberry Pi
RPI_IP="192.168.50.100"
RPI_USER="admin"

# DNS test
TEST_DOMAIN="cloudflare.com"

# Number of consecutive failures required before action/notification
FAIL_THRESHOLD=3

# SSH recovery
ENABLE_SSH_RECOVERY=true
SSH_TIMEOUT=5
RESTART_WAIT=10

# State
STATE_DIR="/mnt/vault/cloud/logs/script/pihole_watchdog"
STATE_FILE="${STATE_DIR}/state"

# Lock
LOCK_FILE="/tmp/pihole_watchdog.lock"

###############################################################################
# LOCK
###############################################################################

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    exit 0
fi

###############################################################################
# INITIALIZATION
###############################################################################

mkdir -p "$STATE_DIR"

PING_FAILURES=0
DNS_FAILURES=0
LAST_STATE="healthy"

if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
fi

###############################################################################
# FUNCTIONS
###############################################################################

notify() {
    local importance="$1"
    local subject="$2"
    local message="$3"

    /usr/local/emhttp/webGui/scripts/notify \
        -e "Pi-hole Watchdog" \
        -s "$subject" \
        -d "$message" \
        -i "$importance"
}

save_state() {
    cat > "$STATE_FILE" <<EOF
PING_FAILURES=${PING_FAILURES}
DNS_FAILURES=${DNS_FAILURES}
LAST_STATE="${LAST_STATE}"
EOF
}

rpi_alive() {
    ping \
        -c 2 \
        -W 2 \
        "$RPI_IP" \
        >/dev/null 2>&1
}

dns_healthy() {
    dig \
        @"$RPI_IP" \
        "$TEST_DOMAIN" \
        +short \
        +time=3 \
        +tries=1 \
        2>/dev/null \
        | grep -q .
}

ssh_available() {
    ssh \
        -o BatchMode=yes \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        "${RPI_USER}@${RPI_IP}" \
        "true" \
        >/dev/null 2>&1
}

restart_pihole() {
    ssh \
        -o BatchMode=yes \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        "${RPI_USER}@${RPI_IP}" \
        "sudo systemctl restart pihole-FTL"
}

###############################################################################
# CHECK RASPBERRY PI
###############################################################################

if ! rpi_alive; then

    ((PING_FAILURES++))
    DNS_FAILURES=0

    if (( PING_FAILURES >= FAIL_THRESHOLD )); then

        if [[ "$LAST_STATE" != "rpi_down" ]]; then
            notify \
                "alert" \
                "Raspberry Pi unreachable" \
                "Pi-hole host ${RPI_IP} has failed ${PING_FAILURES} consecutive network checks.

The Raspberry Pi is not responding to ping.

Possible causes:
- Raspberry Pi powered off
- Network failure
- Raspberry Pi locked up
- Ethernet/Wi-Fi failure

Automatic recovery is not possible because the host is unreachable."
        fi

        LAST_STATE="rpi_down"
    fi

    save_state
    exit 1
fi

###############################################################################
# RPI IS ALIVE
###############################################################################

PING_FAILURES=0

###############################################################################
# CHECK PI-HOLE DNS
###############################################################################

if dns_healthy; then

    DNS_FAILURES=0

    if [[ "$LAST_STATE" != "healthy" ]]; then
        notify \
            "normal" \
            "Pi-hole recovered" \
            "Raspberry Pi ${RPI_IP} and Pi-hole DNS are responding normally again."
    fi

    LAST_STATE="healthy"
    save_state
    exit 0
fi

###############################################################################
# DNS FAILURE
###############################################################################

((DNS_FAILURES++))

if (( DNS_FAILURES < FAIL_THRESHOLD )); then
    save_state
    exit 1
fi

###############################################################################
# DNS FAILED REPEATEDLY
###############################################################################

if [[ "$LAST_STATE" != "dns_failed" ]]; then
    notify \
        "warning" \
        "Pi-hole DNS failure" \
        "Raspberry Pi ${RPI_IP} is reachable, but Pi-hole DNS has failed ${DNS_FAILURES} consecutive checks.

Automatic recovery will now be attempted if SSH recovery is enabled."
fi

LAST_STATE="dns_failed"

###############################################################################
# OPTIONAL SSH RECOVERY
###############################################################################

if [[ "$ENABLE_SSH_RECOVERY" == true ]]; then

    if ssh_available; then

        if restart_pihole; then

            sleep "$RESTART_WAIT"

            if dns_healthy; then

                DNS_FAILURES=0
                LAST_STATE="healthy"

                notify \
                    "normal" \
                    "Pi-hole automatically recovered" \
                    "Pi-hole DNS stopped responding on ${RPI_IP}.

Unraid successfully restarted pihole-FTL over SSH.

DNS resolution is working normally again."

                save_state
                exit 0
            fi
        fi

        notify \
            "alert" \
            "Pi-hole recovery failed" \
            "Raspberry Pi ${RPI_IP} is reachable, but Pi-hole DNS remains unavailable.

An automatic pihole-FTL restart was attempted over SSH but DNS did not recover.

Manual investigation is required."

    else

        notify \
            "alert" \
            "Pi-hole SSH recovery unavailable" \
            "Raspberry Pi ${RPI_IP} is reachable, but Pi-hole DNS is unavailable.

Automatic recovery could not be attempted because SSH access from Unraid failed."

    fi
fi

save_state
exit 1