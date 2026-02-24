#!/bin/bash
LOCKFILE="/tmp/plex_dbrepair_update.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another plex_dbrepair_update.sh run is active, exiting (lock: $LOCKFILE)"
  exit 1
fi

# ---- CONFIGURE YOUR PLEX APPDATA PATHS HERE ----
PLEX1="/mnt/cache/appdata/plex-media-server/DBRepair"
PLEX2="/mnt/cache/appdata/plex-media/DBRepair"

TMP_FILE="/tmp/DBRepair.sh"
DOWNLOAD_URL="https://github.com/ChuckPa/DBRepair/releases/latest/download/DBRepair.sh"

echo "Downloading latest DBRepair..."

# Download to temp first
curl -fsSL "$DOWNLOAD_URL" -o "$TMP_FILE"

# Check if download succeeded
if [ ! -f "$TMP_FILE" ]; then
    echo "Download failed. Aborting."
    exit 1
fi

echo "Updating Plex main instance..."
mkdir -p "$PLEX1"
cp "$TMP_FILE" "$PLEX1/DBRepair.sh"
chmod +x "$PLEX1/DBRepair.sh"

echo "Updating Plex secondary instance..."
mkdir -p "$PLEX2"
cp "$TMP_FILE" "$PLEX2/DBRepair.sh"
chmod +x "$PLEX2/DBRepair.sh"

# Cleanup
rm -f "$TMP_FILE"

echo "Both Plex instances updated successfully."