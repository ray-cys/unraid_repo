#!/bin/bash
LOCKFILE="/tmp/plex_dbrepair.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another plex_dbrepair.sh run is active, exiting (lock: $LOCKFILE)"
  exit 1
fi

################################################################################
# ---------------- Configuration ----------------
################################################################################

CONTAINERS=("plex-media-server" "plex-media")
REPAIR_PATHS=("/config/DBRepair/DBRepair.sh")
DBREPAIR_ARGS=("stop" "auto" "start" "exit")

DOWNLOAD_URL="https://github.com/ChuckPa/DBRepair/releases/latest/download/DBRepair.sh"
TMP_FILE="/tmp/DBRepair.sh"

# --- Logging ---
DATETIME="$(date +%Y%m%d_%H%M%S)"
LOG_FILE_SUBDIR="/mnt/vault/cloud/logs/dbrepair_logs"
LOG_FILE="${LOG_FILE_SUBDIR}/dbrepair-${DATETIME}.log"
mkdir -p "$LOG_FILE_SUBDIR" 2>/dev/null || true
: > "$LOG_FILE"

log() {
  local msg="$*"
  echo "$(date '+%Y/%m/%d %T') : [DBREPAIR][INFO] ${msg}" | tee -a "$LOG_FILE"
}

err() {
  local msg="$*"
  echo "$(date '+%Y/%m/%d %T') : [DBREPAIR][ERROR] ${msg}" | tee -a "$LOG_FILE" >&2
}
################################################################################

# Keep only the newest 3 dbrepair logs, delete older ones
cleanup_old_logs() {
  local max_logs=3
  local logs=()
  if [ -d "$LOG_FILE_SUBDIR" ]; then
    mapfile -t logs < <(find "${LOG_FILE_SUBDIR}/" -mindepth 1 -maxdepth 1 -type f -printf '%T+\t%p\n' 2>/dev/null | sort | cut -f2)
    while [ "${#logs[@]}" -gt "$max_logs" ]; do
      rm -f -- "${logs[0]}" 2>/dev/null || true
      logs=("${logs[@]:1}")
    done
  fi
}

################################################################################
# ---------------- Update DBRepair Script ----------------
################################################################################

log "Downloading latest DBRepair script..."

if curl -fsSL "$DOWNLOAD_URL" -o "$TMP_FILE"; then
  chmod +x "$TMP_FILE"
  log "Download successful."
else
  err "Failed to download DBRepair. Continuing with existing version."
fi

################################################################################
# ---------------- Process Containers ----------------
################################################################################

if ! command -v docker >/dev/null 2>&1; then
  err "Docker CLI not found in PATH. Aborting."
  exit 1
fi

log "Starting automated Plex DBRepair for containers: ${CONTAINERS[*]}"

for CONTAINER in "${CONTAINERS[@]}"; do
  log "Processing container: $CONTAINER"

  if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    err "Container '$CONTAINER' not found. Skipping."
    continue
  fi

  was_running=true
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]; then
    was_running=false
    log "Container $CONTAINER not running — starting"
    docker start "$CONTAINER" >/dev/null 2>&1 || { err "Failed to start $CONTAINER"; continue; }
    sleep 3
  fi

  ##############################################################################
  # Inject updated DBRepair into container
  ##############################################################################

  if [ -f "$TMP_FILE" ]; then
    log "Updating DBRepair inside $CONTAINER"
    docker exec "$CONTAINER" mkdir -p /config/DBRepair >/dev/null 2>&1 || true
    docker cp "$TMP_FILE" "$CONTAINER:/config/DBRepair/DBRepair.sh"
    docker exec "$CONTAINER" chmod +x /config/DBRepair/DBRepair.sh >/dev/null 2>&1 || true
  fi

  ##############################################################################
  # Locate DBRepair script
  ##############################################################################

  found_path=""
  for p in "${REPAIR_PATHS[@]}"; do
    if docker exec "$CONTAINER" test -f "$p" >/dev/null 2>&1; then
      found_path="$p"
      break
    fi
  done

  if [ -z "$found_path" ]; then
    err "DBRepair not found in $CONTAINER. Skipping."
    [ "$was_running" = false ] && docker stop "$CONTAINER" >/dev/null 2>&1 || true
    continue
  fi

  log "Executing DBRepair in $CONTAINER"
  docker exec -i "$CONTAINER" bash -lc "\"$found_path\" ${DBREPAIR_ARGS[*]}"
  rc=$?

  if [ "$rc" -eq 0 ]; then
    log "DBRepair completed successfully for $CONTAINER"
  else
    err "DBRepair returned exit code $rc for $CONTAINER"
  fi

  if [ "$was_running" = false ]; then
    log "Stopping container $CONTAINER (auto-stop)"
    docker stop "$CONTAINER" >/dev/null 2>&1 || true
  fi
done

rm -f "$TMP_FILE"
log "All Plex DBRepair operations completed."
cleanup_old_logs
exit 0