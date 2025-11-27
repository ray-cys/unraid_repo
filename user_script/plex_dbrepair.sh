#!/bin/bash
LOCKFILE="/tmp/plex_dbrepair.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another plex_dbrepair.sh run is active, exiting (lock: $LOCKFILE)"
  exit 1
fi
################################################################################
# ---------------- Configuration ----------------
# Plex DBRepair Automation Script
# Automates running the Plex DBRepair script inside specified Plex Docker containers.
################################################################################

CONTAINERS=("plex-media-server" "plex-media")         # Plex container names here (multiple instances)
REPAIR_PATHS=("/config/PlexDBRepair/DBRepair.sh")     # Common path for Plex DBRepair script inside container
DBREPAIR_ARGS=("stop" "auto" "start" "exit")          # DBRepair non-interactive run: ("stop" "auto" "start" "exit")

################################################################################

# Logging to stdout/stderr 
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err() { printf '%s ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
# Docker container processing
if ! command -v docker >/dev/null 2>&1; then
  err "Docker CLI not found in PATH. Aborting."
  exit 1
fi
# Start time
log "Starting automated Plex DBRepair for containers: ${CONTAINERS[*]}"
for CONTAINER in "${CONTAINERS[@]}"; do
  log "Processing container: $CONTAINER"

  if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    err "Plex container '$CONTAINER' not found. Skipping."
    continue
  fi
  # Check if container is running, start if not
  was_running=true
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]; then
    was_running=false
    log "Plex container $CONTAINER is not running — starting container"
    if ! docker start "$CONTAINER" >/dev/null 2>&1; then
      err "Failed to start Plex container $CONTAINER. Skipping."
      continue
    fi
    sleep 3
  fi
  # Locate the DBRepair script inside the container
  found_path=""
  for p in "${REPAIR_PATHS[@]}"; do
    if docker exec "$CONTAINER" test -f "$p" >/dev/null 2>&1; then
      found_path="$p"
      break
    fi
  done
  # Check if we found the DBRepair script
  if [ -z "$found_path" ]; then
    err "Plex DBRepair script not found in Plex container $CONTAINER. Checked: ${REPAIR_PATHS[*]}. Skipping."
    if [ "$was_running" = false ]; then
      log "Stopping Plex container $CONTAINER (Auto-stop by Plex DBRepair)"
      docker stop "$CONTAINER" >/dev/null 2>&1 || true
    fi
    continue
  fi
  log "Found Plex DBRepair at $found_path in Plex container $CONTAINER"
  # Ensure the script is executable every run
  log "Ensuring $found_path is executable inside Plex container $CONTAINER"
  if ! docker exec "$CONTAINER" chmod +x "$found_path" >/dev/null 2>&1; then
    err "Failed chmod +x $found_path inside Plex container $CONTAINER"
  fi
  # Execute the repair script inside container
  args="${DBREPAIR_ARGS[*]}"
  log "Executing Plex DBRepair non-interactively: $found_path $args"
    log "Starting Plex DBRepair for container: $CONTAINER"
    set +e
    docker exec -i "$CONTAINER" bash -lc "\"$found_path\" ${DBREPAIR_ARGS[*]}"
    rc=${PIPESTATUS[0]:-1}
    set -euo pipefail
    if [ "$rc" -eq 0 ]; then
      log "Plex DBRepair completed for container $CONTAINER (exit $rc)"
    else
      err "Plex DBRepair encountered errors for container $CONTAINER (exit $rc)"
    fi

  if [ "$was_running" = false ]; then
    log "Stopping Plex container $CONTAINER (Auto-stop by Plex DBRepair)"
    docker stop "$CONTAINER" >/dev/null 2>&1 || log "Failed to stop Plex container $CONTAINER"
  fi
done
log "Plex DBRepair completed."
exit 0