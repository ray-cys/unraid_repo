#!/bin/bash

###############################################################################
# Unraid RAM Logs Monitor
#
# PURPOSE
# -------
# Monitor the dedicated /mnt/ramlogs tmpfs used for disposable Docker logs.
#
# Alerts:
#   >= 70% usage  -> Warning
#   >= 90% usage  -> Critical
#   Not mounted   -> Critical
#
# Designed for Unraid User Scripts.
###############################################################################

set -uo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

RAMLOG_PATH="/mnt/ramlogs"

WARNING_PERCENT=70
CRITICAL_PERCENT=90

# Unraid notification command
NOTIFY="/usr/local/emhttp/webGui/scripts/notify"

###############################################################################
# FUNCTIONS
###############################################################################

notify_unraid() {
    local subject="$1"
    local description="$2"
    local importance="$3"

    if [[ -x "$NOTIFY" ]]; then
        "$NOTIFY" \
            -e "Unraid RAM Logs Monitor" \
            -s "$subject" \
            -d "$description" \
            -i "$importance"
    else
        logger -t ramlogs-monitor "$subject - $description"
    fi
}

bytes_to_human() {
    local bytes="$1"

    awk -v b="$bytes" '
    function human(x) {
        split("B KB MB GB TB", u, " ")
        i = 1

        while (x >= 1024 && i < 5) {
            x /= 1024
            i++
        }

        return sprintf("%.2f %s", x, u[i])
    }

    BEGIN {
        print human(b)
    }'
}

###############################################################################
# VERIFY DIRECTORY
###############################################################################

if [[ ! -d "$RAMLOG_PATH" ]]; then

    notify_unraid \
        "RAM log directory missing" \
        "$RAMLOG_PATH does not exist. Docker applications configured to use this location may not be writing logs to the intended RAM filesystem." \
        "alert"

    exit 1
fi

###############################################################################
# VERIFY TMPFS MOUNT
###############################################################################

if ! mountpoint -q "$RAMLOG_PATH"; then

    notify_unraid \
        "RAM logs tmpfs NOT mounted" \
        "$RAMLOG_PATH exists but is not a mounted filesystem. Check the Unraid go file before allowing Docker applications to write logs here." \
        "alert"

    exit 1
fi


FILESYSTEM_TYPE="$(findmnt -n -o FSTYPE "$RAMLOG_PATH" 2>/dev/null || true)"

if [[ "$FILESYSTEM_TYPE" != "tmpfs" ]]; then

    notify_unraid \
        "RAM logs filesystem incorrect" \
        "$RAMLOG_PATH is mounted as '${FILESYSTEM_TYPE:-unknown}' instead of tmpfs." \
        "alert"

    exit 1
fi

###############################################################################
# GET TMPFS USAGE
###############################################################################

read -r TOTAL_KB USED_KB AVAILABLE_KB USED_PERCENT_RAW \
    < <(df -Pk "$RAMLOG_PATH" | awk 'NR==2 {print $2, $3, $4, $5}')

USED_PERCENT="${USED_PERCENT_RAW%\%}"

if ! [[ "$USED_PERCENT" =~ ^[0-9]+$ ]]; then

    notify_unraid \
        "Unable to determine RAM log usage" \
        "Failed to read filesystem utilization for $RAMLOG_PATH." \
        "alert"

    exit 1
fi

TOTAL_BYTES=$(( TOTAL_KB * 1024 ))
USED_BYTES=$(( USED_KB * 1024 ))
AVAILABLE_BYTES=$(( AVAILABLE_KB * 1024 ))

TOTAL_HUMAN="$(bytes_to_human "$TOTAL_BYTES")"
USED_HUMAN="$(bytes_to_human "$USED_BYTES")"
AVAILABLE_HUMAN="$(bytes_to_human "$AVAILABLE_BYTES")"

###############################################################################
# FIND LARGEST APPLICATION LOG DIRECTORY
###############################################################################

LARGEST_APP=""
LARGEST_SIZE=""

while IFS=$'\t' read -r size path; do

    [[ -z "$path" ]] && continue

    LARGEST_APP="$(basename "$path")"
    LARGEST_SIZE="$size"

    break

done < <(
    du -sk "$RAMLOG_PATH"/* 2>/dev/null \
        | sort -nr
)

if [[ -n "$LARGEST_SIZE" ]]; then
    LARGEST_BYTES=$(( LARGEST_SIZE * 1024 ))
    LARGEST_HUMAN="$(bytes_to_human "$LARGEST_BYTES")"
else
    LARGEST_APP="none"
    LARGEST_HUMAN="0 B"
fi

###############################################################################
# ALERT LOGIC
###############################################################################

if (( USED_PERCENT >= CRITICAL_PERCENT )); then

    notify_unraid \
        "RAM logs CRITICAL - ${USED_PERCENT}% full" \
        "$RAMLOG_PATH is ${USED_PERCENT}% full.

Used: ${USED_HUMAN}
Free: ${AVAILABLE_HUMAN}
Capacity: ${TOTAL_HUMAN}

Largest application directory:
${LARGEST_APP} (${LARGEST_HUMAN})

Immediate investigation is recommended before the tmpfs becomes full." \
        "alert"

    exit 2

elif (( USED_PERCENT >= WARNING_PERCENT )); then

    notify_unraid \
        "RAM logs warning - ${USED_PERCENT}% full" \
        "$RAMLOG_PATH has reached ${USED_PERCENT}% utilization.

Used: ${USED_HUMAN}
Free: ${AVAILABLE_HUMAN}
Capacity: ${TOTAL_HUMAN}

Largest application directory:
${LARGEST_APP} (${LARGEST_HUMAN})

Check application log rotation if utilization continues increasing." \
        "warning"

    exit 0

fi

###############################################################################
# NORMAL STATUS
###############################################################################

echo "RAM Logs Monitor"
echo "================"
echo
echo "Path:        $RAMLOG_PATH"
echo "Filesystem:  $FILESYSTEM_TYPE"
echo "Usage:       ${USED_PERCENT}%"
echo "Used:        $USED_HUMAN"
echo "Free:        $AVAILABLE_HUMAN"
echo "Capacity:    $TOTAL_HUMAN"
echo
echo "Largest directory:"
echo "  $LARGEST_APP - $LARGEST_HUMAN"
echo
echo "Status: OK"

exit 0