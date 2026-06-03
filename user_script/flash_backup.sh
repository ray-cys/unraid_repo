#!/bin/bash
LOCKFILE="/tmp/flash_backup.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another flash_backup.sh run is active, exiting (lock: $LOCKFILE)"
  exit 1
fi
################################################################################
# ---------------- Configuration ----------------
# Flash Backup Settings
################################################################################

BACKUP_DIR="/mnt/vault/backup/flash"                              # Destination directory for flash backups
MAX_BACKUP=3                                                      # Number of backups to keep

################################################################################

# Record start time
start_time=$(date +%s)

# === Helpers Functions ===
# Logging
log() {
  local msg="$*"
  echo "$(date '+%Y/%m/%d %T') : $msg"
}

# === Helpers Functions ===
# Centralized syslog function
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

# === Helpers Functions ===
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

# === Helpers Functions ===
# Returns human runtime string computed from start time
format_runtime() {
  if [ -z "${start_time:-}" ]; then
    echo "0h:0m:0s"
    return
  fi
  local secs=$(( $(date +%s) - start_time ))
  printf '%dh:%dm:%ds' $((secs/3600)) $((secs%3600/60)) $((secs%60))
}

# === Helpers Functions ===
# Centralized wrapper around the Unraid notify command to ensure consistent
notify_send() {
  local level="$1"; shift
  local subject="$1"; shift
  local detail="$1"; shift
  local body="$1"; shift || true
  /usr/local/emhttp/webGui/scripts/notify -i "$level" -b -s "$subject" -d "$detail" -m "$body"
  local nrc=$?
  if [ $nrc -ne 0 ]; then
    log "Notification command failed with exit code $nrc for subject: $subject"
  fi
  return $nrc
}

# === Helpers Functions ===
# Check whether a file looks like a zip archive without relying on its name.
is_zip_file() {
  local candidate="$1"
  local signature
  [ -f "$candidate" ] || return 1
  [ -s "$candidate" ] || return 1
  signature=$(head -c 4 "$candidate" 2>/dev/null || true)
  case "$signature" in
    $'PK\003\004'|$'PK\005\006'|$'PK\007\008') return 0 ;;
  esac
  return 1
}

# === Helpers Functions ===
# Resolve the built-in Unraid helper responsible for creating the boot-device zip.
resolve_backup_helper() {
  local candidate
  for candidate in \
    "/usr/local/emhttp/webGui/scripts/boot_device_backup" \
    "/usr/local/emhttp/webGui/scripts/flash_backup" \
    "/usr/local/emhttp/webGui/scripts/boot_backup"
  do
    [ -x "$candidate" ] || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# === Helpers Functions ===
# Extract absolute zip paths that the Unraid helper mentioned while running.
extract_helper_zip_paths() {
  local helper_log="$1"
  [ -f "$helper_log" ] || return 0
  grep -Eo '/[^[:space:]]+\.zip' "$helper_log" 2>/dev/null | sort -u
}

# === Helpers Functions ===
# Extract zip basenames mentioned by the helper, including newer boot-device naming.
extract_helper_zip_basenames() {
  local helper_log="$1"
  [ -f "$helper_log" ] || return 0
  grep -Eio '([[:alnum:]_.-]*(flash|boot|backup|unraid|config)[[:alnum:]_.-]*\.zip)' "$helper_log" 2>/dev/null | sort -u
}

# === Helpers Functions ===
# Search likely Unraid locations for zip files created after the helper started.
find_recent_backup_zips() {
  local marker="$1"
  local spec dir depth
  [ -f "$marker" ] || return 0

  for spec in \
    "/usr/local/emhttp:4" \
    "/boot:4" \
    "/tmp:2" \
    "/var/tmp:2" \
    "/var/lib:4" \
    "/root:3"
  do
    dir=${spec%:*}
    depth=${spec##*:}
    [ -d "$dir" ] || continue
    find "$dir" -maxdepth "$depth" -type f -name '*.zip' -newer "$marker" -printf '%T@|%p\n' 2>/dev/null
  done | sort -t'|' -k1,1nr | cut -d'|' -f2-
}

# === Helpers Functions ===
# Resolve the newest backup zip created by the helper using output hints first,
# then a timestamp-based search across common Unraid locations.
find_latest_backup_zip() {
  local marker="$1"
  local helper_log="$2"
  local candidate best='' best_mtime=0 mtime hinted_name

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [ -f "$candidate" ] || continue
    mtime=$(stat -c%Y "$candidate" 2>/dev/null || stat -f%m "$candidate" 2>/dev/null || echo 0)
    if [ "$mtime" -gt "$best_mtime" ]; then
      best_mtime=$mtime
      best="$candidate"
    fi
  done < <(extract_helper_zip_paths "$helper_log")

  if [ -n "$best" ]; then
    printf '%s' "$best"
    return 0
  fi

  while IFS= read -r hinted_name; do
    [ -n "$hinted_name" ] || continue
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      [ "$(basename "$candidate")" = "$hinted_name" ] || continue
      printf '%s' "$candidate"
      return 0
    done < <(find_recent_backup_zips "$marker")
  done < <(extract_helper_zip_basenames "$helper_log")

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    case "$(basename "$candidate")" in
      *flash*backup*.zip|*boot*backup*.zip|*backup*.zip|*unraid*.zip|*config*.zip)
        printf '%s' "$candidate"
        return 0
        ;;
    esac
  done < <(find_recent_backup_zips "$marker")

  find_recent_backup_zips "$marker" | head -n 1
}

# === Helpers Functions ===
# Remove stale symlinks left behind by the WebGUI helper once the zip is moved.
cleanup_helper_symlinks() {
  local source_path="$1"
  local sl sl_target
  [ -n "$source_path" ] || return 0
  [ -d "/usr/local/emhttp" ] || return 0

  while IFS= read -r sl; do
    [ -L "$sl" ] || continue
    if command -v readlink >/dev/null 2>&1; then
      sl_target=$(readlink -f "$sl" 2>/dev/null || true)
    else
      sl_target=$(realpath "$sl" 2>/dev/null || true)
    fi
    if [ -n "$sl_target" ] && [ "$sl_target" = "$source_path" ]; then
      rm -f -- "$sl" 2>/dev/null || syslog warning "Failed to remove symlink $sl"
      log "Removed symlink $sl that pointed to moved file"
    fi
  done < <(find /usr/local/emhttp -maxdepth 2 -type l -name '*.zip' -print 2>/dev/null)
}

# === Helpers Functions ===
# Function to prune old files in a directory
prune_old_files() {
  local dir="$1"
  local max="$2"
  local pattern="${3:-*}"
  [ -d "$dir" ] || return 0
  mapfile -t files < <(find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{print $2}')
  local total=${#files[@]}
  if [ "$total" -le "$max" ]; then
    return 0
  fi
  local to_delete=$(( total - max ))
  local i
  for ((i=0; i<to_delete; i++)); do
    local f="${files[i]}"
    log "Deleting old backup: $f (keeping newest ${max}; total found: ${total})"
    if rm -f -- "$f" 2>/dev/null; then
      log "Deleted old backup: $f"
    else
      syslog warning "Failed to remove old flash backup $f"
    fi
  done
}

# === Main Script Execution ===
log 'Initialize Unraid boot-device backup'

backup_helper=$(resolve_backup_helper)
if [ -z "$backup_helper" ]; then
  syslog err "Unraid boot-device backup helper not found"
  notify_send alert "Flash Backup - FAIL" "Boot-device backup helper missing" "Unable to find Unraid backup helper under /usr/local/emhttp/webGui/scripts\n\nRuntime: $(format_runtime)"
  exit 127
fi

helper_started_marker=$(mktemp -t flash_backup_started.XXXXXX) || helper_started_marker="/tmp/flash_backup_started.$$"
helper_out=$(mktemp -t flash_backup_helper.XXXXXX) || helper_out="/tmp/flash_backup_helper.$$"
helper_stdout=$(mktemp -t flash_backup_stdout.XXXXXX) || helper_stdout="/tmp/flash_backup_stdout.$$"
helper_stderr=$(mktemp -t flash_backup_stderr.XXXXXX) || helper_stderr="/tmp/flash_backup_stderr.$$"

if "$backup_helper" >"$helper_stdout" 2>"$helper_stderr"; then
  cat "$helper_stdout" "$helper_stderr" >"$helper_out" 2>/dev/null || true
  if ! is_zip_file "$helper_stdout"; then
    while IFS= read -r _line; do
      echo "$(date '+%Y/%m/%d %T') : ${_line}"
    done <"$helper_out"
  fi
  log "Boot-device backup helper finished (exit 0); searching for created zip"
else
  rc=$?
  cat "$helper_stdout" "$helper_stderr" >"$helper_out" 2>/dev/null || true
  if ! is_zip_file "$helper_stdout"; then
    while IFS= read -r _line; do
      echo "$(date '+%Y/%m/%d %T') : ${_line}"
    done <"$helper_out"
  fi
  syslog err "Boot-device backup helper failed with exit $rc"
  excerpt=$(tail -n 40 "$helper_out" 2>/dev/null || true)
  notify_send alert "Flash Backup - FAIL" "Boot-device backup failed" "Exit code: ${rc}\n\nExcerpt:\n${excerpt}\n\nRuntime: $(format_runtime)"
  log "Boot-device backup failed; see job log"
  rm -f -- "$helper_out" "$helper_stdout" "$helper_stderr" "$helper_started_marker" 2>/dev/null || true
  exit $rc
fi

# Creating flash backup directory and ensure correct permissions
if [ ! -d "$BACKUP_DIR" ] ; then
  log "Create backup directory as it does not exist"
  if mkdir -p "$BACKUP_DIR" 2>/dev/null; then
    chmod 0755 "$BACKUP_DIR" 2>/dev/null || syslog warning "chmod failed for $BACKUP_DIR"
    chown -R nobody:users "$BACKUP_DIR" 2>/dev/null || syslog warning "chown failed for $BACKUP_DIR"
    log "Created $BACKUP_DIR backup directory with mode 0755 and owner nobody:users"
  else
    syslog err "Failed to create backup directory $BACKUP_DIR"
    log "Failed to create $BACKUP_DIR"
    rm -f -- "$helper_out" "$helper_stdout" "$helper_stderr" "$helper_started_marker" 2>/dev/null || true
    exit 2
  fi
else
  chmod 0775 "$BACKUP_DIR" 2>/dev/null || syslog warning "chmod failed for $BACKUP_DIR"
  chown -R nobody:users "$BACKUP_DIR" 2>/dev/null || syslog warning "chown failed for $BACKUP_DIR"
  log "Directory $BACKUP_DIR exists; ensured mode 0775 and owner nobody:users"
fi

# Retry a few times in case the file appears slightly later.
retries=6
latest_zip=''
if is_zip_file "$helper_stdout"; then
  streamed_zip="$helper_stdout"
  log "Detected boot-device backup zip streamed directly from helper stdout"
fi
for i in $(seq 1 $retries); do
  if [ -n "${streamed_zip:-}" ]; then
    latest_zip="$streamed_zip"
    break
  fi
  latest_zip=$(find_latest_backup_zip "$helper_started_marker" "$helper_out")
  if [ -n "$latest_zip" ]; then
    break
  fi
  sleep 1
done

log "Search result for boot-device backup zip: ${latest_zip:-<none>}"
if [ -n "$latest_zip" ] && [ -f "$latest_zip" ]; then
  src_bytes=$(stat -c%s "$latest_zip" 2>/dev/null || stat -f%z "$latest_zip" 2>/dev/null || echo 0)
  dest_avail=$(df --output=avail -B1 "$BACKUP_DIR" 2>/dev/null | tail -n1 || echo 0)
  dest_total=$(df --output=size -B1 "$BACKUP_DIR" 2>/dev/null | tail -n1 || echo 0)
  src_bytes=${src_bytes:-0}
  dest_avail=${dest_avail:-0}
  dest_total=${dest_total:-0}
  if ! [[ "$dest_avail" =~ ^[0-9]+$ ]]; then dest_avail=0; fi
  if ! [[ "$dest_total" =~ ^[0-9]+$ ]]; then dest_total=0; fi
  human_src_size=$(bytes_human "$src_bytes")
  need_bytes=$(( src_bytes + 1024 * 1024 ))

  if [ "$dest_avail" -lt "$need_bytes" ]; then
    human_need=$(bytes_human "$need_bytes")
    human_avail=$(bytes_human "$dest_avail")
    syslog err "Insufficient space to move boot-device backup zip: need ${human_need}, available ${human_avail}"
    if [[ "$dest_avail" =~ ^[0-9]+$ ]] && [ "$dest_avail" -gt 0 ]; then
      req_pct_of_free=$(awk -v r="$need_bytes" -v f="$dest_avail" 'BEGIN{printf "%.2f", (r*100)/f}')
      no_space_body="Space: Free = ${human_avail}, Required = ${human_need}\nRequired vs Free: ${req_pct_of_free}%"
    else
      no_space_body="Space: Free = ${human_avail}, Required = ${human_need}\nRequired vs Free: Unknown"
    fi
    notify_send alert "Flash Backup" "🔵 Backup - NO SPACE" "$no_space_body"
    log "Insufficient space for moving $latest_zip: need ${human_need} available ${human_avail}"
  else
    target="$latest_zip"
    final="$BACKUP_DIR/$(basename "$target")"
    tmp="$BACKUP_DIR/.tmp.$(basename "$target").$$"
    src_dev=$(stat -c %d "$target" 2>/dev/null || echo "")
    dest_dev=$(stat -c %d "$BACKUP_DIR" 2>/dev/null || echo "")

    if [ -n "$src_dev" ] && [ -n "$dest_dev" ] && [ "$src_dev" = "$dest_dev" ]; then
      if mv -- "$target" "$final"; then
        moved_file="$final"
        moved_size=$(stat -c%s "$moved_file" 2>/dev/null || stat -f%z "$moved_file" 2>/dev/null || echo 0)
        human_moved_size=$(bytes_human "$moved_size")
        log "Moved $target to $final"
        log "Moved file: $moved_file size: ${human_moved_size}"
        cleanup_helper_symlinks "$target"
      else
        rc=$?
        syslog warning "mv (same FS) failed with exit $rc; attempting copy-to-temp+rename fallback for $target"
        if cp --reflink=auto --sparse=always --preserve=mode,timestamps -- "$target" "$tmp" 2>/dev/null \
           && mv -f -- "$tmp" "$final" 2>/dev/null \
           && rm -f -- "$target" 2>/dev/null; then
          moved_file="$final"
          moved_size=$(stat -c%s "$moved_file" 2>/dev/null || stat -f%z "$moved_file" 2>/dev/null || echo 0)
          human_moved_size=$(bytes_human "$moved_size")
          log "Copied via temp and removed original: $target -> $final"
          cleanup_helper_symlinks "$target"
        else
          rm -f -- "$tmp" 2>/dev/null || true
          syslog err "Failed to move (same FS) $target to $final via fallback"
          log "mv/copy fallback failed for $target"
        fi
      fi
    else
      if cp --reflink=auto --sparse=always --preserve=mode,timestamps -- "$target" "$tmp" 2>/dev/null; then
        if mv -f -- "$tmp" "$final" 2>/dev/null; then
          if rm -f -- "$target" 2>/dev/null; then
            moved_file="$final"
            moved_size=$(stat -c%s "$moved_file" 2>/dev/null || stat -f%z "$moved_file" 2>/dev/null || echo 0)
            human_moved_size=$(bytes_human "$moved_size")
            log "Copied to dest (reflink where possible) and finalized: $target -> $final"
            cleanup_helper_symlinks "$target"
          else
            moved_file="$final"
            moved_size=$(stat -c%s "$moved_file" 2>/dev/null || stat -f%z "$moved_file" 2>/dev/null || echo 0)
            human_moved_size=$(bytes_human "$moved_size")
            syslog warning "Copied and finalized at destination but failed to remove source $target"
            log "Copied and finalized at destination; please manually remove source: $target"
          fi
        else
          rc=$?
          rm -f -- "$tmp" 2>/dev/null || true
          syslog err "Failed to finalize rename of $tmp to $final (exit $rc)"
          log "Failed to finalize move at destination"
        fi
      else
        rc=$?
        rm -f -- "$tmp" 2>/dev/null || true
        syslog err "Failed to copy $target to temporary file $tmp in $BACKUP_DIR (exit $rc)"
        log "Copy to destination temp failed for $target"
      fi
    fi
  fi
else
  log "No boot-device backup zip found after helper run"
fi

# Remove old backups
prune_old_files "$BACKUP_DIR" "$MAX_BACKUP" "*.zip"

# Syslog and notification
runtime_now=$(format_runtime)
if [ -n "${moved_file:-}" ]; then
  syslog info "Flash Backup: Unraid boot device backed up on $(date) (Runtime: ${runtime_now})"
  notify_body="Boot-device backup moved to ${BACKUP_DIR}\nRuntime: ${runtime_now}"
  notify_body+="\nMoved: $(basename "${moved_file}") (${human_moved_size})"
  if [ -n "${need_bytes:-}" ]; then
    req_human=$(bytes_human "$need_bytes")
    free_human=$(bytes_human "${dest_avail:-0}")
    notify_body+=$'\n'"Space: Free = ${free_human}, Required = ${req_human}"
    if [[ "${dest_avail:-0}" =~ ^[0-9]+$ ]] && [ "${dest_avail:-0}" -gt 0 ]; then
      req_pct_of_free=$(awk -v r="$need_bytes" -v f="${dest_avail:-0}" 'BEGIN{printf "%.2f", (r*100)/f}')
      notify_body+=$'\n'"Required vs Free: ${req_pct_of_free}%"
    else
      notify_body+=$'\n'"Required vs Free: Unknown"
    fi
  fi
  notify_send normal "Flash Backup" "🟢 Backup - OK" "$notify_body"
else
  syslog err "Flash Backup: No boot-device backup moved on $(date) (Runtime: ${runtime_now})"
  notify_body="Boot-device backup did NOT move to ${BACKUP_DIR}\nRuntime: ${runtime_now}"
  if [ -n "${latest_zip:-}" ] && [ -f "${latest_zip}" ]; then
    notify_body+="\nFound source zip: ${latest_zip} (${human_src_size})"
  else
    notify_body+="\nNo boot-device backup zip was found after the helper completed"
  fi
  notify_send alert "Flash Backup" "🔴 Backup - FAIL" "$notify_body"
  rm -f -- "${helper_out:-/tmp/flash_backup_helper.$$}" "${helper_stdout:-/tmp/flash_backup_stdout.$$}" "${helper_stderr:-/tmp/flash_backup_stderr.$$}" "${helper_started_marker:-/tmp/flash_backup_started.$$}" 2>/dev/null || true
  exit 1
fi

# Cleanup helper output temporary file
rm -f -- "${helper_out:-/tmp/flash_backup_helper.$$}" "${helper_stdout:-/tmp/flash_backup_stdout.$$}" "${helper_stderr:-/tmp/flash_backup_stderr.$$}" "${helper_started_marker:-/tmp/flash_backup_started.$$}" 2>/dev/null || true
exit 0
