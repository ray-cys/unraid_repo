#!/bin/bash
#
# SABnzbd Pre-Queue Script to enforce CoW=OFF (NOCOW) on new job folders
# Applies recursively to both incomplete and complete folders
# Logs actions to /config/scripts/disable_cow.log
#

# SAB arguments
NZB_NAME="$2"
CATEGORY="$6"

# Paths
INCOMPLETE="/data/net/incomplete"
COMPLETE="/data/net/complete"

# Log file
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
LOG_FILE="$SCRIPT_DIR/disable_cow.log"

log() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
}

# Create job directories if they don't exist
JOB_INCOMPLETE="$INCOMPLETE/$NZB_NAME"
JOB_COMPLETE="$COMPLETE/$NZB_NAME"

mkdir -p "$JOB_INCOMPLETE"
mkdir -p "$JOB_COMPLETE"

# Apply NOCOW recursively
chattr +C -R "$JOB_INCOMPLETE" 2>/dev/null && log "Applied NOCOW to incomplete: $JOB_INCOMPLETE"
chattr +C -R "$JOB_COMPLETE" 2>/dev/null && log "Applied NOCOW to complete: $JOB_COMPLETE"

# Output required by SABnzbd: "cat priority pp script dest_dir"
echo "$CATEGORY $7 $4 $5 $INCOMPLETE"
exit 0