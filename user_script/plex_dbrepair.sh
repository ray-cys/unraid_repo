#!/bin/bash
set -euo pipefail
LOCKFILE="/tmp/plex_dbrepair.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another plex_dbrepair.sh run is active, exiting (lock: $LOCKFILE)"
  exit 1
fi

noParity=true
clearLog=false

# --------------------------------------------------------------------------------
# Configuration section
# Adjust the settings below to configure the remote backup behavior.

# Plex container names (mutliple instances)
CONTAINERS=("plex-media-server" "plex-media")
# Path (inside the container) for DBRepair
REPAIR_PATHS=("/config/PlexDBRepair/DBRepair.sh")
# Arguments to pass to DBRepair script to run non-interactively. 
DBREPAIR_ARGS=("stop" "auto" "start" "exit")

# --------------------------------------------------------------------------------

# Logging to stdout/stderr 
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err() { printf '%s ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# Format seconds into human readable H M S
human_runtime() {
  local s=$1
  local h m sec
  h=$((s/3600))
  m=$(((s%3600)/60))
  sec=$((s%60))
  if [ "$h" -gt 0 ]; then
    printf '%dh %dm %ds' "$h" "$m" "$sec"
  elif [ "$m" -gt 0 ]; then
    printf '%dm %ds' "$m" "$sec"
  else
    printf '%ds' "$sec"
  fi
}

# Docker container processing
if ! command -v docker >/dev/null 2>&1; then
  err "Docker CLI not found in PATH. Aborting."
  exit 1
fi

# Start time
log "Starting automated Plex DBRepair for containers: ${CONTAINERS[*]}"
START_TS=$(date +%s)

for CONTAINER in "${CONTAINERS[@]}"; do
  log "Processing container: $CONTAINER"
  CON_START=$(date +%s)

  if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    err "Plex container '$CONTAINER' not found. Skipping."
    continue
  fi

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

  found_path=""
  for p in "${REPAIR_PATHS[@]}"; do
    if docker exec "$CONTAINER" test -f "$p" >/dev/null 2>&1; then
      found_path="$p"
      break
    fi
  done

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
  CON_END=$(date +%s)
  CON_ELAPSED=$((CON_END - CON_START))
  CON_RUNTIME=$(human_runtime "$CON_ELAPSED")
  log "Plex container $CONTAINER runtime: ${CON_RUNTIME}"

done

# End time
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
RUNTIME=$(human_runtime "$ELAPSED")
log "Plex DBRepair completed. Total runtime: ${RUNTIME}"

exit 0