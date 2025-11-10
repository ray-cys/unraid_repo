#!/bin/bash
set -eu

noParity=true
clearLog=false

# Stop if another instance is running
pidof -o %PPID -x "$0" >/dev/null && \
  logger -p err "Error: Script $0 already running, exiting!" && \
  exit 1

# --------------------------------------------------------------------------------
# SETTINGS

plex_dir="/mnt/user/appdata/plex-media-server"
backup_dir="/mnt/user/node/plex"
plex="plex-media-server"
plex_dir_name="plex"
datetime="$(date +%Y%m%d_%H%M%S)"
log_file_subdir="/boot/logs/$plex_dir_name-logs"
log_file="$log_file_subdir/$plex_dir_name-$datetime.log"
max_backup=3
max_logs=3

# --------------------------------------------------------------------------------

# Function for logging
log() {
  local msg="$1"
  echo "$(date "+%Y/%m/%d %T") : $msg" | tee -a "$log_file"
}

# Function to remove old files
remove_old_files() {
  local dir="$1"
  local max="$2"
  local label="$3"
  files=($(find "$dir" -mindepth 1 -maxdepth 1 -type f -printf '%T+\t%p\n' | sort | cut -f2))
  while [ "${#files[@]}" -gt "$max" ]; do
    rm -rf "${files[0]}"
    log "Remove old $label, allow only ($max) $label"
    files=("${files[@]:1}")
  done
}

# Ensure log sub-directory exists
if [ ! -d "$log_file_subdir" ]; then
  mkdir -p "$log_file_subdir"
  chown -R nobody:users "$log_file_subdir"
fi

# Record start time
start_time=$(date +%s)
logger -i "Plex Server backup start: $(date)"
log "Plex Server backup start: $(date)"

# Check destination has enough free space
plex_dir_size=$(du -sb "$plex_dir" | awk '{print $1}')
backup_dir_free=$(df -B1 "$backup_dir" | awk 'NR==2 {print $4}')
if [ "$plex_dir_size" -gt "$backup_dir_free" ]; then
  logger -p crit "$backup_dir not enough free space, exiting! $plex_dir_size required"
  log "$backup_dir not enough free space, exiting! $plex_dir_size required"
  exit 1
fi

# Stop Plex container with retry logic
fail_counter=0
log "Start backup $plex_dir_name, stop container"
while [ "$(docker inspect -f '{{.State.Running}}' $plex)" = "true" ]; do
  fail_counter=$((fail_counter+1))
  docker stop "$plex"
  log "Stop $plex_dir_name attempt #$fail_counter of #5"
  if ((fail_counter == 5)); then
    docker start "$plex"
    logger -p err "$plex_dir_name fail to stop. Start container.."
    log "$plex_dir_name fail to stop. Start container.."
    exit 1
  fi
done

# Start backup .tar.gz Plex
log "Start $plex_dir_name backup"
log "Compress $plex_dir_name to disk"
tar -czPf "$backup_dir/pms_$datetime.tar.gz" --totals "$plex_dir"
backup_status=$?

# Backup verification and error handling
if [ "$backup_status" -eq 0 ]; then
  docker start "$plex"
  log "Backup $plex_dir_name complete, start container"
else
  logger -p err "Backup error, $plex_dir_name fail! == Error: $backup_status"
  log "Backup error, $plex_dir_name fail! == Error: $backup_status"
  /usr/local/emhttp/webGui/scripts/notify -i alert -b -s "Scheduled Plex Backup" \
    -d "Backup error, $plex_dir_name fail!" -m "Error: $backup_status"
  exit 1
fi

# Remove old backups and logs
remove_old_files "$backup_dir" "$max_backup" "backup"
remove_old_files "$log_file_subdir" "$max_logs" "log"

# Record end time and log status
runtime=$(($(date +%s) - start_time))
runtime_converted=$(printf '%dh:%dm:%ds\n' $((runtime / 3600)) $((runtime % 3600 / 60)) $((runtime % 60)))
logger -i "Plex Server backup complete == Runtime: $runtime_converted"
log "Plex Server backup complete == Runtime: $runtime_converted"
 /usr/local/emhttp/webGui/scripts/notify -i normal -b -s "Scheduled Plex Backup" \
  -d "Plex Server backup complete" -m "Runtime: $runtime_converted"

exit 0