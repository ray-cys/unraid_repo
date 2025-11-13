#!/bin/bash

# Use set -eu for safer scripting
set -eu

noParity=false # set to true to disable script during parity checks / rebuild
clearLog=false # set to true to delete logs prior to script execution

# Stop if another instance is running
pidof -o %PPID -x "$0" >/dev/null && \
  logger -p err "Error: Script $0 already running, exiting!" && \
  exit 1

# --------------------------------------------------------------------------------
# SETTINGS

src_dir="/mnt/user/appdata"
flash_dir="/boot/config/plugins/"
dest_dir="/mnt/user/node/data"
plex_dir1="plex-media-server/Library/Application Support/Plex Media Server/Plug-in Support/Databases"
plex_dir2="plex-media/Library/Application Support/Plex Media Server/Plug-in Support/Databases"
plex_dest_dir="$dest_dir/plexdb"
max_logs=10
max_bu=10
log_dir="/boot/logs/backup-logs/"
logfile="$log_dir/rsync_backup_$(date +%Y%m%d_%H%M%S).log"

# --------------------------------------------------------------------------------

# Function for rsync backup and logging
backup_rsync() {
  local src="$1"
  local dest="$2"
  local label="$3"
  log_msg="Start $label backup"
  echo "$(date "+%Y/%m/%d %T") : $log_msg" | tee -a "$logfile"
  rsync "$src" "$dest" -ah --update --delete --itemize-changes --stats >> "$logfile" 2>&1
  log_msg="$label backup complete"
  echo "$(date "+%Y/%m/%d %T") : $log_msg" | tee -a "$logfile"
}

# Function for removing old files
remove_old_files() {
  local dir="$1"
  local max="$2"
  local label="$3"
  files=($(find "$dir" -type f -printf '%T+\t%p\n' | sort | cut -f2))
  while [ "${#files[@]}" -gt "$max" ]; do
    rm -rf "${files[0]}"
    log_msg="Remove old $label, allow only ($max) backups"
    echo "$(date "+%Y/%m/%d %T") : $log_msg" | tee -a "$logfile"
    files=("${files[@]:1}")
  done
}

# Record start time
start_time=$(date +%s)
logger "Backup data start: $(date)"
log_msg="Backup data start: $(date)"
echo "$(date "+%Y/%m/%d %T") : $log_msg" | tee -a "$logfile"

# Use function for each backup
backup_rsync "$flash_dir/user.scripts/scripts/" "$dest_dir/scripts/" "User Scripts"
backup_rsync "$src_dir/sonarr/backup/" "$dest_dir/sonarr/" "Sonarr"
backup_rsync "$src_dir/radarr/backup/" "$dest_dir/radarr/" "Radarr"
backup_rsync "$src_dir/bazarr/backup/" "$dest_dir/bazarr/" "Bazarr"
backup_rsync "$src_dir/sabnzbd/backup/" "$dest_dir/sabnzbd/" "Sabnzbd"
remove_old_files "$src_dir/sabnzbd/backup/" "$max_bu" "Sabnzbd"
backup_rsync "$src_dir/tautulli/backups/" "$dest_dir/tautulli/" "Tautulli"

# Plex DB backup
log_msg="Start Plex DB backup"
echo "$(date "+%Y/%m/%d %T") : $log_msg" | tee -a "$logfile"
rsync -ah --update --delete --stats --protect-args --itemize-changes \
  "$src_dir/$plex_dir1/com.plexapp.plugins.library.blobs.db" \
  "$plex_dest_dir/hubble/com.plexapp.plugins.library.blobs.db-$(date +%Y-%m-%d)" >> "$logfile" 2>&1
rsync -ah --update --delete --stats --protect-args --itemize-changes \
  "$src_dir/$plex_dir1/com.plexapp.plugins.library.db" \
  "$plex_dest_dir/hubble/com.plexapp.plugins.library.db-$(date +%Y-%m-%d)" >> "$logfile" 2>&1
rsync -ah --update --delete --stats --protect-args --itemize-changes \
  "$src_dir/$plex_dir2/com.plexapp.plugins.library.blobs.db" \
  "$plex_dest_dir/node/com.plexapp.plugins.library.blobs.db-$(date +%Y-%m-%d)" >> "$logfile" 2>&1
rsync -ah --update --delete --stats --protect-args --itemize-changes \
  "$src_dir/$plex_dir2/com.plexapp.plugins.library.db" \
  "$plex_dest_dir/node/com.plexapp.plugins.library.db-$(date +%Y-%m-%d)" >> "$logfile" 2>&1
log_msg="Plex DB backup complete"
echo "$(date "+%Y/%m/%d %T") : $log_msg" | tee -a "$logfile"
remove_old_files "$plex_dest_dir" "$max_bu" "Plex DB"

# Rsync backup verification and error handling
backup_status=$?
if [ "$backup_status" -eq 0 ]; then
  log_msg="Backup data complete: Status $backup_status"
  echo "$(date "+%Y/%m/%d %T") : $log_msg" | tee -a "$logfile"
else
  logger -p err "Backup data fail! Error: $backup_status"
  log_msg="Backup fail! Error: $backup_status"
  echo "$(date "+%Y/%m/%d %T") : $log_msg" | tee -a "$logfile"
fi

# Record end time
runtime=$(($(date +%s) - start_time))
runtime_converted=$(printf '%dh:%dm:%ds\n' $((runtime / 3600)) $((runtime % 3600 / 60)) $((runtime % 60)))

# Log runtime status
logger "Backup data complete == Runtime: $runtime_converted."
log_msg="Backup data complete == Runtime: $runtime_converted."
echo "$(date "+%Y/%m/%d %T") : $log_msg" | tee -a "$logfile"

# Remove old logs
remove_old_files "$log_dir" "$max_logs" "Log"

exit 0