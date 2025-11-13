#!/bin/bash
# Disable CoW safely for job folders
# SAB sets $SABNZBD_COMPLETE_DIR (for complete) and $SABNZBD_INCOMPLETE_DIR (if set)
# SAB can also use $SABNZBD_JOB_DIR if available

JOB_NAME="$SABNZBD_NZB_NAME"
INCOMPLETE="/data/net/incomplete/$JOB_NAME"
COMPLETE="/data/net/complete/$JOB_NAME"
LOG_FILE="/config/scripts/disable_cow.log"

# Ensure directories exist
mkdir -p "$INCOMPLETE"
mkdir -p "$COMPLETE"

# Apply NOCOW recursively
chattr +C -R "$INCOMPLETE" 2>/dev/null
chattr +C -R "$COMPLETE" 2>/dev/null

# Logging
echo "$(date '+%Y-%m-%d %H:%M:%S') - Applied NOCOW to $INCOMPLETE and $COMPLETE" >> "$LOG_FILE"