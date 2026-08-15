#!/bin/bash

###############################################################################
# Plex DBRepair Scheduler Wrapper v2.0
#
# PURPOSE
# -------
# Scheduled wrapper for ChuckPa's Plex DBRepair script.
#
# For each configured Plex container this script:
#
#   1. Downloads and validates the latest DBRepair.sh when possible.
#   2. Starts the container temporarily if it was originally stopped.
#   3. Updates the in-container DBRepair.sh using a staged replacement.
#   4. Runs DBRepair with the configured arguments.
#   5. Restores the container to its original stopped state when applicable.
#   6. Records DBRepair output and a concise run summary.
#
#
# LOGGING
# -------
# Uses a rolling log rather than creating one log per run:
#
#   dbrepair.log
#   dbrepair.log.1
#   dbrepair.log.2
#
# Old timestamp-based logs from previous versions are automatically removed.
#
#
# FAILURE BEHAVIOR
# ----------------
# Failure to download the latest DBRepair.sh does NOT stop the run.
#
# The script will instead attempt to use the existing DBRepair.sh already
# present inside each Plex container.
#
###############################################################################

set -uo pipefail


###############################################################################
# CONFIGURATION
###############################################################################

VERSION="2.0"


# ---------------------------------------------------------------------------
# Plex containers
# ---------------------------------------------------------------------------

CONTAINERS=(
  "plex-media-server"
  "plex-media"
)


# ---------------------------------------------------------------------------
# DBRepair
# ---------------------------------------------------------------------------

REPAIR_PATHS=(
  "/config/DBRepair/DBRepair.sh"
)

DBREPAIR_ARGS=(
  "stop"
  "auto"
  "start"
  "exit"
)

DOWNLOAD_URL="https://github.com/ChuckPa/DBRepair/releases/latest/download/DBRepair.sh"

TMP_FILE="/tmp/DBRepair.sh"


# ---------------------------------------------------------------------------
# Logging
#
# LOG_KEEP=2 retains:
#
#   dbrepair.log
#   dbrepair.log.1
#   dbrepair.log.2
#
# Therefore a maximum of three rolling log files are normally retained.
# ---------------------------------------------------------------------------

LOG_DIR="/mnt/vault/cloud/logs/dbrepair_logs"

LOG_FILE="${LOG_DIR}/dbrepair.log"

LOG_MAX_BYTES=$((2 * 1024 * 1024))

LOG_KEEP=2


# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------

LOCK_FILE="/tmp/plex_dbrepair.lock"


###############################################################################
# INTERNAL STATE / COUNTERS
###############################################################################

DOWNLOAD_READY=0

LEGACY_LOGS_REMOVED=0

CONTAINERS_PROCESSED=0
CONTAINERS_SUCCESSFUL=0
CONTAINERS_FAILED=0
CONTAINERS_SKIPPED=0

CONTAINERS_TEMP_STARTED=0
CONTAINERS_UPDATED=0

WARNING_COUNT=0
ERROR_COUNT=0


###############################################################################
# GENERAL HELPERS
###############################################################################

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}


log() {
  local level="$1"
  shift

  printf '%s [%s] [DBREPAIR] %s\n' \
    "$(timestamp)" \
    "$level" \
    "$*" | tee -a "$LOG_FILE"
}


warn() {
  log "WARN" "$*"

  ((WARNING_COUNT+=1))
}


error() {
  log "ERROR" "$*" >&2

  ((ERROR_COUNT+=1))
}


die() {
  error "$*"

  exit 1
}


cleanup_temp() {
  rm -f -- \
    "$TMP_FILE" \
    "${TMP_FILE}.download" \
    2>/dev/null || true
}


trap cleanup_temp EXIT


###############################################################################
# LOCKING
###############################################################################

acquire_lock() {
  exec 9>"$LOCK_FILE"

  if ! flock -n 9; then
    printf '%s [INFO] [DBREPAIR] Another Plex DBRepair run is active; exiting.\n' \
      "$(timestamp)"

    exit 0
  fi
}


###############################################################################
# LOG MAINTENANCE
###############################################################################

rotate_log() {
  [[ -f "$LOG_FILE" ]] || return 0

  local size
  local i

  size="$(stat -c '%s' "$LOG_FILE" 2>/dev/null || printf '0')"

  (( size >= LOG_MAX_BYTES )) || return 0


  # If no historical logs are requested, simply clear the current log.

  if (( LOG_KEEP <= 0 )); then
    : > "$LOG_FILE"

    return 0
  fi


  # Remove the oldest retained log.

  rm -f -- \
    "${LOG_FILE}.${LOG_KEEP}" \
    2>/dev/null || true


  # Shift existing rotated logs.

  for ((i=LOG_KEEP-1; i>=1; i--)); do

    if [[ -f "${LOG_FILE}.${i}" ]]; then

      mv -f -- \
        "${LOG_FILE}.${i}" \
        "${LOG_FILE}.$((i + 1))"

    fi

  done


  # Rotate the current log.

  mv -f -- \
    "$LOG_FILE" \
    "${LOG_FILE}.1"
}


cleanup_legacy_logs() {
  local old_log

  while IFS= read -r -d '' old_log; do

    if rm -f -- "$old_log"; then

      ((LEGACY_LOGS_REMOVED+=1))

    else

      ((WARNING_COUNT+=1))

    fi

  done < <(
    find "$LOG_DIR" \
      -mindepth 1 \
      -maxdepth 1 \
      -type f \
      -name 'dbrepair-[0-9]*_[0-9]*.log' \
      -print0 \
      2>/dev/null
  )
}


###############################################################################
# VALIDATION
###############################################################################

require_commands() {
  local cmd
  local missing=0

  for cmd in \
    docker \
    flock \
    find \
    stat \
    rm \
    mv \
    tee \
    bash \
    chmod
  do

    if ! command -v "$cmd" >/dev/null 2>&1; then

      log "ERROR" "Required command not found: $cmd"

      missing=1

    fi

  done


  if (( missing != 0 )); then

    die "One or more required commands are unavailable."

  fi
}


validate_environment() {

  [[ -w "$LOG_DIR" ]] || \
    die "Log directory is not writable: $LOG_DIR"


  if ! docker info >/dev/null 2>&1; then

    die "Docker is unavailable or the Docker service is not running."

  fi


  if (( ${#CONTAINERS[@]} == 0 )); then

    die "No Plex containers are configured."

  fi


  if (( ${#REPAIR_PATHS[@]} == 0 )); then

    die "No DBRepair paths are configured."

  fi
}


###############################################################################
# DBREPAIR DOWNLOAD
###############################################################################

download_latest_dbrepair() {
  DOWNLOAD_READY=0


  # Prevent a failed download from accidentally reusing an old temporary file.

  rm -f -- \
    "$TMP_FILE" \
    "${TMP_FILE}.download" \
    2>/dev/null || true


  # curl is deliberately treated as optional.
  #
  # DBRepair can still run using the copy already installed inside the
  # container if downloading the newest release is unavailable.

  if ! command -v curl >/dev/null 2>&1; then

    warn "curl is not available; using existing in-container DBRepair copies."

    return 0
  fi


  log "INFO" "Downloading latest DBRepair script..."


  if ! curl \
      -fsSL \
      --retry 2 \
      --retry-delay 2 \
      --connect-timeout 15 \
      --max-time 90 \
      "$DOWNLOAD_URL" \
      -o "${TMP_FILE}.download"
  then

    rm -f -- \
      "${TMP_FILE}.download" \
      2>/dev/null || true

    warn "Failed to download DBRepair; using existing in-container copies."

    return 0
  fi


  # Make sure something was actually downloaded.

  if [[ ! -s "${TMP_FILE}.download" ]]; then

    rm -f -- \
      "${TMP_FILE}.download" \
      2>/dev/null || true

    warn "Downloaded DBRepair file is empty; using existing in-container copies."

    return 0
  fi


  # Validate Bash syntax before distributing the script to the Plex containers.

  if ! bash -n "${TMP_FILE}.download" >/dev/null 2>&1; then

    rm -f -- \
      "${TMP_FILE}.download" \
      2>/dev/null || true

    warn "Downloaded DBRepair failed Bash syntax validation; existing copies will be used."

    return 0
  fi


  if ! chmod +x "${TMP_FILE}.download"; then

    rm -f -- \
      "${TMP_FILE}.download" \
      2>/dev/null || true

    warn "Unable to mark downloaded DBRepair executable; existing copies will be used."

    return 0
  fi


  if ! mv -f -- \
      "${TMP_FILE}.download" \
      "$TMP_FILE"
  then

    warn "Unable to stage downloaded DBRepair; existing copies will be used."

    return 0
  fi


  DOWNLOAD_READY=1

  log "INFO" "DBRepair download and syntax validation completed successfully."
}


###############################################################################
# DBREPAIR INSTALLATION
###############################################################################

install_downloaded_dbrepair() {
  local container="$1"

  local target="${REPAIR_PATHS[0]}"

  local target_dir="${target%/*}"

  local staged="${target}.new"


  (( DOWNLOAD_READY == 1 )) || return 1


  # Ensure DBRepair directory exists.

  if ! docker exec \
      "$container" \
      mkdir -p "$target_dir" \
      >/dev/null 2>&1
  then

    return 1
  fi


  # Remove any abandoned staging file from an earlier interrupted run.

  docker exec \
    "$container" \
    rm -f "$staged" \
    >/dev/null 2>&1 || true


  # Copy to a staging location rather than immediately replacing the
  # currently working DBRepair.sh.

  if ! docker cp \
      "$TMP_FILE" \
      "$container:$staged" \
      >/dev/null 2>&1
  then

    docker exec \
      "$container" \
      rm -f "$staged" \
      >/dev/null 2>&1 || true

    return 1
  fi


  if ! docker exec \
      "$container" \
      chmod +x "$staged" \
      >/dev/null 2>&1
  then

    docker exec \
      "$container" \
      rm -f "$staged" \
      >/dev/null 2>&1 || true

    return 1
  fi


  # Replace DBRepair only after staging was successful.

  if ! docker exec \
      "$container" \
      mv -f "$staged" "$target" \
      >/dev/null 2>&1
  then

    docker exec \
      "$container" \
      rm -f "$staged" \
      >/dev/null 2>&1 || true

    return 1
  fi


  return 0
}


###############################################################################
# CONTAINER PROCESSING
###############################################################################

process_container() {
  local container="$1"

  local started_by_script=0

  local found_path=""

  local state=""

  local rc=0

  local p


  log "INFO" "Processing container: $container"


  # -------------------------------------------------------------------------
  # Verify configured container exists
  # -------------------------------------------------------------------------

  if ! docker inspect "$container" >/dev/null 2>&1; then

    error "Configured container not found: $container"

    ((CONTAINERS_SKIPPED+=1))

    ((CONTAINERS_FAILED+=1))

    return 1
  fi


  ((CONTAINERS_PROCESSED+=1))


  # -------------------------------------------------------------------------
  # Determine original container state
  # -------------------------------------------------------------------------

  state="$(
    docker inspect \
      -f '{{.State.Running}}' \
      "$container" \
      2>/dev/null || printf 'false'
  )"


  # -------------------------------------------------------------------------
  # Temporarily start container when required
  # -------------------------------------------------------------------------

  if [[ "$state" != "true" ]]; then

    log "INFO" "Container is stopped; starting temporarily: $container"


    if ! docker start "$container" >/dev/null 2>&1; then

      error "Failed to start container: $container"

      ((CONTAINERS_FAILED+=1))

      return 1
    fi


    started_by_script=1

    ((CONTAINERS_TEMP_STARTED+=1))


    sleep 3


    state="$(
      docker inspect \
        -f '{{.State.Running}}' \
        "$container" \
        2>/dev/null || printf 'false'
    )"


    if [[ "$state" != "true" ]]; then

      error "Container did not reach running state after start: $container"

      ((CONTAINERS_FAILED+=1))

      return 1
    fi

  fi


  # -------------------------------------------------------------------------
  # Install freshly downloaded DBRepair
  # -------------------------------------------------------------------------

  if (( DOWNLOAD_READY == 1 )); then

    if install_downloaded_dbrepair "$container"; then

      ((CONTAINERS_UPDATED+=1))

      log "INFO" "Updated DBRepair inside container: $container"

    else

      warn "Unable to update DBRepair inside $container; attempting existing copy instead."

    fi

  fi


  # -------------------------------------------------------------------------
  # Locate usable DBRepair script
  # -------------------------------------------------------------------------

  for p in "${REPAIR_PATHS[@]}"; do

    if docker exec \
        "$container" \
        test -s "$p" \
        >/dev/null 2>&1
    then

      found_path="$p"

      break
    fi

  done


  # -------------------------------------------------------------------------
  # Execute DBRepair
  # -------------------------------------------------------------------------

  if [[ -z "$found_path" ]]; then

    error "DBRepair script not found inside container: $container"

    rc=1

  else

    log "INFO" \
      "Executing DBRepair in $container: $found_path ${DBREPAIR_ARGS[*]}"


    log "INFO" \
      "----- DBRepair output begin: $container -----"


    docker exec -i \
      "$container" \
      bash "$found_path" "${DBREPAIR_ARGS[@]}" \
      2>&1 | tee -a "$LOG_FILE"


    rc=${PIPESTATUS[0]}


    log "INFO" \
      "----- DBRepair output end: $container -----"


    if (( rc == 0 )); then

      log "INFO" \
        "DBRepair completed successfully for: $container"

    else

      error \
        "DBRepair returned exit code $rc for: $container"

    fi

  fi


  # -------------------------------------------------------------------------
  # Restore original container state
  #
  # A container which was stopped before this wrapper ran should remain
  # stopped after DBRepair completes.
  # -------------------------------------------------------------------------

  if (( started_by_script == 1 )); then

    log "INFO" \
      "Restoring original container state; stopping: $container"


    if ! docker stop \
        "$container" \
        >/dev/null 2>&1
    then

      error \
        "Failed to restore stopped state for container: $container"

      rc=1

    fi

  fi


  # -------------------------------------------------------------------------
  # Container result
  # -------------------------------------------------------------------------

  if (( rc == 0 )); then

    ((CONTAINERS_SUCCESSFUL+=1))

    return 0
  fi


  ((CONTAINERS_FAILED+=1))

  return 1
}


###############################################################################
# MAIN
###############################################################################

main() {
  umask 022


  # -------------------------------------------------------------------------
  # Prepare logging
  # -------------------------------------------------------------------------

  if ! mkdir -p "$LOG_DIR" 2>/dev/null; then

    printf '%s [ERROR] [DBREPAIR] Unable to create log directory: %s\n' \
      "$(timestamp)" \
      "$LOG_DIR" \
      >&2

    return 1
  fi


  # -------------------------------------------------------------------------
  # Prevent overlapping scheduled runs
  # -------------------------------------------------------------------------

  acquire_lock


  # -------------------------------------------------------------------------
  # Log maintenance
  #
  # Run before writing this execution's normal log entries.
  # -------------------------------------------------------------------------

  rotate_log

  cleanup_legacy_logs


  # -------------------------------------------------------------------------
  # Start
  # -------------------------------------------------------------------------

  log "INFO" \
    "===== Plex DBRepair Scheduler START ====="


  log "INFO" \
    "Version: v${VERSION}"


  log "INFO" \
    "Configured containers: ${CONTAINERS[*]}"


  if (( LEGACY_LOGS_REMOVED > 0 )); then

    log "INFO" \
      "Removed ${LEGACY_LOGS_REMOVED} legacy timestamp log file(s)."

  fi


  # -------------------------------------------------------------------------
  # Validation
  # -------------------------------------------------------------------------

  require_commands

  validate_environment


  # -------------------------------------------------------------------------
  # Obtain latest DBRepair
  # -------------------------------------------------------------------------

  download_latest_dbrepair


  # -------------------------------------------------------------------------
  # Process Plex containers
  # -------------------------------------------------------------------------

  local container

  for container in "${CONTAINERS[@]}"; do

    process_container "$container" || true

  done


  # -------------------------------------------------------------------------
  # Summary
  # -------------------------------------------------------------------------

  local download_state="fallback-existing"


  if (( DOWNLOAD_READY == 1 )); then

    download_state="validated-latest"

  fi


  log "INFO" \
    "Run summary: configured=${#CONTAINERS[@]} processed=${CONTAINERS_PROCESSED} successful=${CONTAINERS_SUCCESSFUL} failed=${CONTAINERS_FAILED} skipped=${CONTAINERS_SKIPPED} temporarily_started=${CONTAINERS_TEMP_STARTED} updated=${CONTAINERS_UPDATED} download=${download_state} warnings=${WARNING_COUNT} errors=${ERROR_COUNT}"


  # -------------------------------------------------------------------------
  # Final result
  # -------------------------------------------------------------------------

  if (( CONTAINERS_FAILED > 0 || ERROR_COUNT > 0 )); then

    log "ERROR" \
      "===== Plex DBRepair Scheduler COMPLETE WITH ERRORS ====="

    return 1
  fi


  if (( WARNING_COUNT > 0 )); then

    log "WARN" \
      "===== Plex DBRepair Scheduler COMPLETE WITH WARNINGS ====="

    return 0
  fi


  log "INFO" \
    "===== Plex DBRepair Scheduler COMPLETE ====="


  return 0
}


main "$@"