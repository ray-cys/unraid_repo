#!/bin/bash
set -euo pipefail
LOCKFILE="/tmp/flash_backup.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another flash_backup.sh run is active, exiting (lock: $LOCKFILE)"
  exit 1
fi

noParity=true
clearLog=false

# --------------------------------------------------------------------------------
# SETTINGS

# Set source directories
backup_dir="/mnt/user/node/flash"

# Set maximum number of backups to keep
max_backups=3

# Unraid notify helper
notify_bin="/usr/local/emhttp/webGui/scripts/notify"

# --------------------------------------------------------------------------------

# Record start time
start_time=$(date +%s)

# Logging function
log() {
  local msg="$*"
  echo "$(date '+%Y/%m/%d %T') : $msg"
}

syslog() {
  local level="$1"; shift || true
  local msg="$*"
  local prio
  case "$level" in
    debug) prio="user.debug" ;;
    info) prio="user.info" ;;
    notice) prio="user.notice" ;;
    warning|warn) prio="user.warning" ;;
    err|error) prio="user.err" ;;
    crit) prio="user.crit" ;;
    *) prio="user.notice" ;;
  esac
  logger -i -t flash_backup -p "$prio" "$msg"
}

# Convert a bytes integer into a human-readable string using binary units
bytes_human() {
  local bytes=${1:-0}
  local TB=1099511627776
  local GB=1073741824
  local MB=1048576
  local KB=1024
  if [ "$bytes" -ge "$TB" ]; then
    awk "BEGIN{printf \"%.2f TB\", $bytes/$TB}"
  elif [ "$bytes" -ge "$GB" ]; then
    awk "BEGIN{printf \"%.2f GB\", $bytes/$GB}"
  elif [ "$bytes" -ge "$MB" ]; then
    awk "BEGIN{printf \"%.2f MB\", $bytes/$MB}"
  elif [ "$bytes" -ge "$KB" ]; then
    awk "BEGIN{printf \"%.2f KB\", $bytes/$KB}"
  else
    printf "%d B" "$bytes"
  fi
}

# Returns human runtime string computed from start time
format_runtime() {
  if [ -z "${start_time:-}" ]; then
    echo "0h:0m:0s"
    return
  fi
  local secs=$(( $(date +%s) - start_time ))
  printf '%dh:%dm:%ds' $((secs/3600)) $((secs%3600/60)) $((secs%60))
}

# Centralized wrapper around the Unraid notify command to ensure consistent
notify_send() {
  local level="$1"; shift
  local subject="$1"; shift
  local detail="$1"; shift
  local body="$1"; shift || true
  "$notify_bin" -i "$level" -b -s "$subject" -d "$detail" -m "$body"
  local nrc=$?
  if [ $nrc -ne 0 ]; then
    log "Notification command failed with exit code $nrc for subject: $subject"
  fi
  return $nrc
}

# Function to prune old files in a directory
prune_old_files() {
  local dir="$1"
  local max="$2"
  local pattern="${3:-*}"
  [ -d "$dir" ] || return 0
  mapfile -t files < <(find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{print $2}')
  local i=0
  local total=${#files[@]}
  for f in "${files[@]}"; do
    if [ $i -ge "$max" ]; then
      log "Deleting old backup: $f (keeping last ${max} backups; total found: ${total})"
      if rm -f -- "$f" 2>/dev/null; then
        log "Deleted old backup: $f"
      else
        syslog warning "Failed to remove old flash backup $f"
      fi
    fi
    i=$((i+1))
  done
}

# Start flash backup
log 'Initialize Unraid flash backup'
helper_out=$(mktemp -t flash_backup_helper.XXXXXX) || helper_out="/tmp/flash_backup_helper.$$"
if /usr/local/emhttp/webGui/scripts/flash_backup >"$helper_out" 2>&1; then
  while IFS= read -r _line; do
    echo "$(date '+%Y/%m/%d %T') : ${_line}"
  done <"$helper_out"
  log "Flash backup helper finished (exit 0); searching for created zip"
else
  rc=$?
  while IFS= read -r _line; do
    echo "$(date '+%Y/%m/%d %T') : ${_line}"
  done <"$helper_out"
  syslog err "Flash backup helper failed with exit $rc"
  excerpt=$(tail -n 40 "$helper_out" 2>/dev/null || true)
  notify_send alert "🔴 Flash Backup - FAIL" "💾 Flash backup failed" "Exit code: ${rc}\n\nExcerpt:\n${excerpt}\n\nRuntime: $(format_runtime)"
  log "Flash backup failed; see job log"
  rm -f -- "$helper_out" 2>/dev/null || true
  exit $rc
fi

# Creating flash backup directory and ensure correct permissions
if [ ! -d "$backup_dir" ] ; then
  log "Create backup directory as it does not exist"
  if mkdir -p "$backup_dir" 2>/dev/null; then
    # Set conservative permissions and ownership
    chmod 0755 "$backup_dir" 2>/dev/null || syslog warning "chmod failed for $backup_dir"
    chown -R nobody:users "$backup_dir" 2>/dev/null || syslog warning "chown failed for $backup_dir"
    log "Created $backup_dir backup directory with mode 0755 and owner nobody:users"
  else
    syslog err "Failed to create backup directory $backup_dir"
    log "Failed to create $backup_dir"
    exit 2
  fi
else
  # Ensure correct permissions/ownership on existing directory
  chmod 0775 "$backup_dir" 2>/dev/null || syslog warning "chmod failed for $backup_dir"
  chown -R nobody:users "$backup_dir" 2>/dev/null || syslog warning "chown failed for $backup_dir"
  log "Directory $backup_dir exists; ensured mode 0775 and owner nobody:users"
fi

# Find the latest flash backup zip file in /usr/local/emhttp
find_latest_flash_zip() {
  local d="/usr/local/emhttp"
  local pattern='*flash-backup-*.zip'
  local best=''
  local best_mtime=0
  local candidate target mtime
  [ -d "$d" ] || { printf '%s' ""; return; }

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ -L "$candidate" ]; then
      if command -v realpath >/dev/null 2>&1; then
        target=$(realpath "$candidate" 2>/dev/null || true)
      else
        target=$(readlink -f "$candidate" 2>/dev/null || readlink "$candidate" 2>/dev/null || true)
      fi
      [ -n "$target" ] || continue
      [ -f "$target" ] || continue
      mtime=$(stat -c%Y "$target" 2>/dev/null || stat -f%m "$target" 2>/dev/null || echo 0)
      if [ "$mtime" -gt "$best_mtime" ]; then
        best_mtime=$mtime
        best="$target"
      fi
    else
      [ -f "$candidate" ] || continue
      mtime=$(stat -c%Y "$candidate" 2>/dev/null || stat -f%m "$candidate" 2>/dev/null || echo 0)
      if [ "$mtime" -gt "$best_mtime" ]; then
        best_mtime=$mtime
        best="$candidate"
      fi
    fi
  done < <(find "$d" -maxdepth 1 -name "$pattern" -printf '%p\n' 2>/dev/null)

  printf '%s' "$best"
}

# Retry a few times in case the file appears slightly later.
retries=6
latest_zip=''
for i in $(seq 1 $retries); do
  latest_zip=$(find_latest_flash_zip)
  if [ -n "$latest_zip" ]; then
    break
  fi
  sleep 1
done

# Move the latest flash backup zip to the backup directory
log "Search result for flash zip: ${latest_zip:-<none>}"
if [ -n "$latest_zip" ] && [ -f "$latest_zip" ]; then
  src_bytes=$(stat -c%s "$latest_zip" 2>/dev/null || stat -f%z "$latest_zip" 2>/dev/null || echo 0)
  dest_avail=$(df --output=avail -B1 "$backup_dir" 2>/dev/null | tail -n1 || echo 0)
  src_bytes=${src_bytes:-0}
  dest_avail=${dest_avail:-0}
  human_src_size=$(bytes_human "$src_bytes")
  need_bytes=$(( src_bytes + 1024 * 1024 )) # 1MB safety buffer
    if [ "$dest_avail" -lt "$need_bytes" ]; then
    human_need=$(bytes_human "$need_bytes")
    human_avail=$(bytes_human "$dest_avail")
    syslog err "Insufficient space to move flash zip: need ${human_need}, available ${human_avail}"
  notify_send alert "🔴 Flash Backup - NO SPACE" "🔵 Insufficient space" "Need ${human_need}, available ${human_avail}"
    log "Insufficient space for moving $latest_zip: need ${human_need} available ${human_avail}"
  else
    target="$latest_zip"
    if mv -- "$target" "$backup_dir/"; then
      moved_file="$backup_dir/$(basename "$target")"
      moved_size=$(stat -c%s "$moved_file" 2>/dev/null || stat -f%z "$moved_file" 2>/dev/null || echo 0)
      human_moved_size=$(bytes_human "$moved_size")
      log "Moved $target to $backup_dir"
      log "Moved file: $moved_file size: ${human_moved_size}"

      if [ -d "/usr/local/emhttp" ]; then
        while IFS= read -r sl; do
          [ -L "$sl" ] || continue
          if command -v readlink >/dev/null 2>&1; then
            sl_target=$(readlink -f "$sl" 2>/dev/null || true)
          else
            sl_target=$(realpath "$sl" 2>/dev/null || true)
          fi
          if [ -n "$sl_target" ] && [ "$sl_target" = "$target" ]; then
            rm -f -- "$sl" 2>/dev/null || syslog warning "Failed to remove symlink $sl"
            log "Removed symlink $sl that pointed to moved file"
          fi
        done < <(find /usr/local/emhttp -maxdepth 1 -name '*flash-backup-*.zip' -print 2>/dev/null)
      fi

    else
      rc=$?
      syslog warning "mv failed with exit $rc; attempting copy+remove fallback for $target"
      if cp --preserve=mode,timestamps -- "$target" "$backup_dir/" 2>/dev/null && rm -f -- "$target" 2>/dev/null; then
        moved_file="$backup_dir/$(basename "$target")"
        moved_size=$(stat -c%s "$moved_file" 2>/dev/null || stat -f%z "$moved_file" 2>/dev/null || echo 0)
        human_moved_size=$(bytes_human "$moved_size")
        log "Copied and removed original: $target -> $moved_file"

        if [ -d "/usr/local/emhttp" ]; then
          while IFS= read -r sl; do
            [ -L "$sl" ] || continue
            if command -v readlink >/dev/null 2>&1; then
              sl_target=$(readlink -f "$sl" 2>/dev/null || true)
            else
              sl_target=$(realpath "$sl" 2>/dev/null || true)
            fi
            if [ -n "$sl_target" ] && [ "$sl_target" = "$target" ]; then
              rm -f -- "$sl" 2>/dev/null || syslog warning "Failed to remove symlink $sl"
              log "Removed symlink $sl that pointed to moved file"
            fi
          done < <(find /usr/local/emhttp -maxdepth 1 -name '*flash-backup-*.zip' -print 2>/dev/null)
        fi

      else
        syslog err "Failed to move or copy $target to $backup_dir"
        log "mv/copy failed for $target"
      fi
    fi
  fi
else
  log "No flash backup zip found in /usr/local/emhttp to move"
fi

# Remove old backups
prune_old_files "$backup_dir" "$max_backups" "*flash-backup-*.zip"

 # Syslog and notification
 runtime_now=$(format_runtime)
 if [ -n "${moved_file:-}" ]; then
  syslog info "Flash Backup: Unraid OS backed up on $(date) (Runtime: ${runtime_now})"
  notify_body="Flash backup moved to ${backup_dir}\nRuntime: ${runtime_now}"
  notify_body+="\nMoved: $(basename "${moved_file}") (${human_moved_size})"
  notify_send normal "🟢 Flash Backup - OK" "💾 Flash backup successful" "$notify_body"
else
  syslog err "Flash Backup: No backup moved on $(date) (Runtime: ${runtime_now})"
  notify_body="Flash backup did NOT move to ${backup_dir}\nRuntime: ${runtime_now}"
  if [ -n "${latest_zip:-}" ] && [ -f "${latest_zip}" ]; then
    notify_body+="\nFound source zip: ${latest_zip} (${human_src_size})"
  else
    notify_body+="\nNo flash backup zip found in /usr/local/emhttp"
  fi
  notify_send alert "🔴 Flash Backup - FAIL" "💾 Flash backup not moved" "$notify_body"
  exit 1
fi

# Cleanup helper output temporary file
rm -f -- "${helper_out:-/tmp/flash_backup_helper.$$}" 2>/dev/null || true

exit 0
