#!/bin/bash
set -euo pipefail
LOCKFILE="/tmp/data_management.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another data_management.sh run is active, exiting (lock: $LOCKFILE)"
  exit 1
fi

noParity=true
clearLog=false


# --------------------------------------------------------------------------------
# SETTINGS

# Source and destination directories
src_dir="/mnt/user/secure/torrent"
dest_dir="/mnt/user/secure"

# Ownership settings: Set OWNER as needed.
# Common pattern: 'nobody', 'root', 'user'
OWN_USER="nobody"

# Permission settings: directory and file modes (octal).
# Common pattern: CHMOD_DIR=0775, CHMOD_FILE=0664
CHMOD_DIR=0775
CHMOD_FILE=0775

# --------------------------------------------------------------------------------

# Helper logging functions
log_info() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  printf '%s %s\n' "$ts" "$*"
}

log_warn() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  printf '%s WARN: %s\n' "$ts" "$*"
}

log_err() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  printf '%s ERROR: %s\n' "$ts" "$*" >&2
}

# Warn if not running as root
if [ "$(id -u)" -ne 0 ]; then
  log_warn "This script is not running as root (uid=$(id -u)). Chown operations may fail unless you run as root or adjust permissions."
fi

# Helper run rsync with timestamp
run_with_timestamp() {
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL "$@" 2>&1 | while IFS= read -r line; do
      printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
    done
  else
    "$@" 2>&1 | while IFS= read -r line; do
      printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
    done
  fi
}

# Helper return success if directory has any entry (file or dir)
has_any_entry() {
  local d="$1"
  [ -d "$d" ] && find "$d" -mindepth 1 -print -quit >/dev/null 2>&1
}

# Helper return success if directory has any regular file under it
has_files_under() {
  local d="$1"
  [ -d "$d" ] && find "$d" -type f -print -quit >/dev/null 2>&1
}

# Helper same as has_files_under but excluding a path pattern
has_files_under_excluding() {
  local base="$1"; shift
  local exclude_path="$1"; shift
  [ -d "$base" ] && find "$base" -not \( -path "$exclude_path" -prune \) -type f -print -quit >/dev/null 2>&1
}

# Helper returns file size in bytes (works on GNU and BSD stat)
filesize() {
  local f="$1"
  if [ ! -e "$f" ]; then
    echo 0
    return 0
  fi
  local s
  s=$(stat -c%s "$f" 2>/dev/null) && { echo "$s"; return 0; } || true
  s=$(stat -f%z "$f" 2>/dev/null) && { echo "$s"; return 0; } || true
  s=$(ls -nl "$f" 2>/dev/null | awk '{print $5}')
  if [ -n "$s" ] && printf '%s' "$s" | grep -Eq '^[0-9]+$'; then
    echo "$s"; return 0
  fi
  s=$(wc -c <"$f" 2>/dev/null) && { echo "$s"; return 0; } || true
  echo 0
}

# Validate an octal mode like 0755 or 644 (allow 3- or 4-digit octal)
validate_mode() {
  case "$1" in
    [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) return 0 ;;
    *) return 1 ;;
  esac
}

# Check whether the owner user exists on the system
owner_exists() {
  id -u "$1" >/dev/null 2>&1
}

# Helper set owner and permissions on a directory tree.
set_owner_and_perms() {
  local target="$1"
  local owner="${2:-$OWN_USER}"
  local dir_mode="${3:-$CHMOD_DIR}"
  local file_mode="${4:-$CHMOD_FILE}"

  if ! owner_exists "$owner"; then
    log_warn "Directory owner '$owner' does not exist on this system; chown will likely fail"
  fi

  if ! validate_mode "$dir_mode"; then
    log_err "Directory mode value '$dir_mode' is not a valid octal mode"
    return 1
  fi
  if ! validate_mode "$file_mode"; then
    log_err "File mode value '$file_mode' is not a valid octal mode"
    return 1
  fi

  if chown -R "$owner" "$target"; then
    :
  else
    log_warn "Chown $owner failed on $target — running without privilege?"
  fi

  if ! chmod -R "$dir_mode" "$target"; then
    log_err "Chmod $dir_mode failed on $target — check permissions"
    return 1
  fi

  find "$target" -type f -exec chmod "$file_mode" {} \; >/dev/null 2>&1 || true
  find "$target" -type d -exec chmod g+s {} \; >/dev/null 2>&1 || true
  log_info "Directory ownership and permissions set on $target"
  return 0
}

# Ensure ownership and permissions on a destination directory after move/rsync
ensure_dest_owner_perms() {
  local destdir="$1"
  local owner="${2:-$OWN_USER}"
  local dir_mode="${3:-$CHMOD_DIR}"
  local file_mode="${4:-$CHMOD_FILE}"

  local owner_group
  owner_group=$(id -gn "$owner" 2>/dev/null || true)
  if [[ -n "$owner_group" ]]; then
    if ! chown -R "${owner}:${owner_group}" "$destdir" 2>/dev/null; then
      log_warn "Failed to chown $destdir to ${owner}:${owner_group} — you may need root privileges"
    fi
  else
    if ! chown -R "$owner" "$destdir" 2>/dev/null; then
      log_warn "Failed to chown $destdir to $owner — you may need root privileges"
    fi
  fi
  log_info "Permission: owner and permission modified to ${owner}${owner_group:+:${owner_group}} on $destdir"

  if ! chmod -R "$dir_mode" "$destdir" 2>/dev/null; then
    log_warn "Failed to chmod -R $dir_mode on $destdir"
  fi
  find "$destdir" -type f -exec chmod "$file_mode" {} \; >/dev/null 2>&1 || true
  find "$destdir" -type d -exec chmod g+s {} \; >/dev/null 2>&1 || true
}

# Convert bytes to human-readable units (B KB MB GB TB PB)
human_readable() {
  local bytes="$1"
  if [[ -z "$bytes" ]] || [[ "$bytes" -eq 0 ]]; then
    printf '0B'
    return 0
  fi
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=si --format='%.1f' "$bytes" | awk '{print $1$2}'
    return 0
  fi
  awk -v b="$bytes" 'function hr(x){s="B KB MB GB TB PB"; n=0; while(x>=1024 && n<5){x/=1024;n++} split(s,a," "); printf("%.1f %s", x, a[n+1])} {hr(b)}'
}

# Function to rename patterns in files
rename_patterns() {
  local dir="$1"
  local patterns=("hhd800.com@" "gg5.co@" "-C_GG5" "ch")

  for pattern in "${patterns[@]}"; do
    mapfile -d '' files < <(find "$dir" -not \( -path "$dir/incomplete" -prune \) -type f -name "*${pattern}*" -print0 2>/dev/null)
    local count=${#files[@]}
    if [[ $count -eq 0 ]]; then
      log_info "Rename files: no files match pattern '$pattern' in $dir"
      continue
    fi

    # Compute total size of matched files
    local total_bytes=0
    for ef in "${files[@]}"; do
      ef="${ef%$'\0'}"
      total_bytes=$((total_bytes + $(filesize "$ef")))
    done
    local human_total
    human_total=$(human_readable "$total_bytes")

    log_info "Rename files: removing literal pattern '$pattern' from $count files in $dir (total size: $human_total)"

    for f in "${files[@]}"; do
      f="${f%$'\0'}"
      local dirpath base newbase newpath
      dirpath=$(dirname -- "$f")
      base=$(basename -- "$f")
      newbase="${base//${pattern}/}"
      if [[ "$newbase" == "$base" ]]; then
        continue
      fi
      newpath="$dirpath/$newbase"

      if [[ -e "$newpath" ]]; then
        if [[ $(filesize "$f") -eq $(filesize "$newpath") ]]; then
          if command -v shasum >/dev/null 2>&1; then
            if [[ "$(shasum -a 256 "$f" | awk '{print $1}')" == "$(shasum -a 256 "$newpath" | awk '{print $1}')" ]]; then
              local size
              size=$(human_readable "$(filesize "$f")")
              log_info "Rename files: '$f' identical to '$newpath' -> removing source (size: $size)"
              rm -f -- "$f"
              continue
            fi
          fi
        fi
        local i=1 candidate
        while :; do
          candidate="${newpath}.dup${i}"
          if [[ ! -e "$candidate" ]]; then
            newpath="$candidate"
            break
          fi
          i=$((i+1))
        done
      fi

      if mv -n -- "$f" "$newpath"; then
        local rsize
        rsize=$(human_readable "$(filesize "$newpath")")
        log_info "Rename files: renamed '$f' -> '$newpath' (size: $rsize)"
      else
        local fsize
        fsize=$(human_readable "$(filesize "$f")")
        log_warn "Rename files: failed to rename '$f' -> '$newpath' (size: $fsize)"
      fi
    done

    log_info "Rename files: finished removing files pattern '$pattern' (total size: $human_total)"
  done
}

# Function to remove unwanted file extensions
remove_unwanted_files() {
  local dir="$1"
  local pattern_count
  pattern_count=$(find "$dir" -not \( -path "$dir/incomplete" -prune \) -type f \
    \( -iname "*.url" -o -iname "*.html" -o -iname "*.mht" -o -iname "*.gif" -o -iname "*.txt" -o -iname "*.rar" -o -iname "*.apk" -o -iname "*.jpg" \) -print 2>/dev/null | wc -l)
  if [[ "$pattern_count" -gt 0 ]]; then
    log_info "Remove unwanted files: removing $pattern_count unwanted files under $dir"
    local total_removed_bytes=0
    while IFS= read -r -d '' remfile; do
      local rb=$(filesize "$remfile")
      total_removed_bytes=$((total_removed_bytes + rb))
      local rsize=$(human_readable "$rb")
      log_info "Removing unwanted file '$remfile' of size $rsize"
      rm -f -- "$remfile"
    done < <(find "$dir" -not \( -path "$dir/incomplete" -prune \) -type f \
      \( -iname "*.url" -o -iname "*.html" -o -iname "*.mht" -o -iname "*.gif" -o -iname "*.txt" -o -iname "*.rar" -o -iname "*.apk" -o -iname "*.jpg" \) -print0)
    log_info "Remove unwanted files: removed $pattern_count unwanted files under $dir"
    log_info "Total size of removed files: $(human_readable "$total_removed_bytes")"
  else
    log_info "Remove unwanted files: no unwanted files found under $dir"
  fi
}

# Function to safely move files from source to destination
safe_move() {
  local src="$1"
  local dest="$2"

  if [[ ! -d "$src" ]]; then
      log_warn "Safe move: source '$src' does not exist, skipping"
    return 0
  fi

  if [[ -z "$(find "$src" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
      log_info "Safe move: source '$src' empty, skipping"
    return 0
  fi
  mkdir -p "$dest"

  if ! command -v rsync >/dev/null 2>&1; then
      log_err "Safe move: rsync is required but not found in PATH"
    return 1
  fi

  # Determine owner primary group for use with rsync --chown
  local owner_group
  owner_group=$(id -gn "$OWN_USER" 2>/dev/null || true)
  local rsync_chown_arg
  if [[ -n "$owner_group" ]]; then
    rsync_chown_arg="--chown=${OWN_USER}:${owner_group}"
  else
    rsync_chown_arg="--chown=${OWN_USER}"
  fi

  find "$src" -type f -print0 | while IFS= read -r -d '' srcfile; do
    relpath="${srcfile#$src/}"
    destfile="$dest/$relpath"

    if [[ -f "$destfile" ]]; then
  if [[ $(filesize "$srcfile") -eq $(filesize "$destfile") ]]; then
        if command -v shasum >/dev/null 2>&1; then
          if [[ "$(shasum -a 256 "$srcfile" | awk '{print $1}')" == "$(shasum -a 256 "$destfile" | awk '{print $1}')" ]]; then
            local size
            size=$(human_readable "$(filesize "$srcfile")")
            log_info "Identical file: removing source '$srcfile' (size: $size)"
            rm -f -- "$srcfile"
            continue
          fi
        fi
      fi

      mkdir -p "$(dirname "$destfile")"
  local osize
  osize=$(human_readable "$(filesize "$srcfile")")
  log_info "Overwriting: '$destfile' with '$srcfile' (size: $osize)"
        if rsync --version >/dev/null 2>&1 && rsync --help 2>&1 | grep -q -- --chown; then
          run_with_timestamp rsync -a $rsync_chown_arg --checksum --inplace --partial --progress --remove-source-files -- "$srcfile" "${destfile%/*}/"
          destdir="${destfile%/*}"
          ensure_dest_owner_perms "$destdir"
        else
          run_with_timestamp rsync -a --inplace --partial --progress --remove-source-files -- "$srcfile" "${destfile%/*}/"
          destdir="${destfile%/*}"
          ensure_dest_owner_perms "$destdir"
        fi
      continue
    fi

    mkdir -p "$(dirname "$destfile")"
    local size
    size=$(human_readable "$(filesize "$srcfile")")
    log_info "Safe move: moving '$srcfile' -> '$destfile' (size: $size)"
      if rsync --version >/dev/null 2>&1 && rsync --help 2>&1 | grep -q -- --chown; then
        run_with_timestamp rsync -a $rsync_chown_arg --inplace --partial --progress --remove-source-files -- "$srcfile" "${destfile%/*}/"
        destdir="${destfile%/*}"
        ensure_dest_owner_perms "$destdir"
      else
        run_with_timestamp rsync -a --inplace --partial --progress --remove-source-files -- "$srcfile" "${destfile%/*}/"
        destdir="${destfile%/*}"
        ensure_dest_owner_perms "$destdir"
      fi
  done

  find "$src" -mindepth 1 -type d -empty -delete

  if [[ -d "$src" ]] && [[ -z "$(find "$src" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
      log_info "Directory: '$src' (empty)"
  fi
}

# Function to move プライベート subdirectories
move_private_subdirs() {
  local src_base="$1"
  local dest_base="$2"
  local subdirs=(
    "Ai.Kano.叶爱"
    "Aika.Yumeno.夢乃あいか"
    "Akari.Niimura.新村あかり"
    "Ena.Satsuki.沙月恵奈"
    "Karen.Yuzuriha.楪カレン"
    "Sora.Amakawa.天川そら"
    "Sui.Twinkle.月野江すい"
    "Yui.Tenma.天馬ゆい"
  )
  for subdir in "${subdirs[@]}"; do
    local sub_total=0
    if [ -d "$src_base/$subdir" ]; then
      while IFS= read -r -d '' sf; do
        sub_total=$((sub_total + $(filesize "$sf")))
      done < <(find "$src_base/$subdir" -type f -print0 2>/dev/null)
    fi
    log_info "Safe move: processing sub-directory '$subdir' (size: $(human_readable "$sub_total"))"
    if safe_move "$src_base/$subdir" "$dest_base/$subdir"; then
      log_info "Safe move: finished sub-directory '$subdir' (size: $(human_readable "$sub_total"))"
    else
      log_warn "Safe move: failure for sub-directory '$subdir'"
    fi
  done
}

# Record start time and announce processing start
START_TS=$(date +%s)
log_info "Starting data processing for source: $src_dir"

if ! has_files_under "$src_dir"; then
  log_info "Source $src_dir directory empty, script exit!"
  end_ts=$(date +%s)
  elapsed=$((end_ts - START_TS))
  hours=$((elapsed/3600))
  mins=$(((elapsed%3600)/60))
  secs=$((elapsed%60))
  if [ "$hours" -gt 0 ]; then
    runtime="${hours}h ${mins}m ${secs}s"
  elif [ "$mins" -gt 0 ]; then
    runtime="${mins}m ${secs}s"
  else
    runtime="${secs}s"
  fi
  log_info "Processing finished (Runtime: ${runtime})"
  exit 1
else
  if ! set_owner_and_perms "$src_dir" "$OWN_USER" "$CHMOD_DIR" "$CHMOD_FILE"; then
    end_ts=$(date +%s)
    elapsed=$((end_ts - START_TS))
    hours=$((elapsed/3600))
    mins=$(((elapsed%3600)/60))
    secs=$((elapsed%60))
    if [ "$hours" -gt 0 ]; then
      runtime="${hours}h ${mins}m ${secs}s"
    elif [ "$mins" -gt 0 ]; then
      runtime="${mins}m ${secs}s"
    else
      runtime="${secs}s"
    fi
    log_info "Processing finished (Runtime: ${runtime})"
    exit 1
  fi
fi

# Rename files for metadata scans
rename_patterns "$src_dir"

# Remove unwanted files
remove_unwanted_files "$src_dir"
while IFS= read -r -d '' remmp4; do
  rbs=$(filesize "$remmp4")
  log_info "Removing unwanted file: unwanted file '$remmp4' of size $(human_readable "$rbs")"
  rm -f -- "$remmp4"
done < <(find "$src_dir/complete/" -iname "18+游戏大全(996gg.cc)-七龍珠H版-三國志H版-三國群淫傳等.mp4" -type f -print0)

# Atomic move for ポルノ
if has_files_under "$src_dir/complete/ポルノ"; then
  safe_move "$src_dir/complete/ポルノ" "$dest_dir/ポルノ"
else
  log_info "Safe move: ポルノ directory empty, skipping!"
fi

# Atomic move for プライベート subdirectories
if has_files_under_excluding "$src_dir/complete" "$src_dir/complete/ポルノ"; then
  move_private_subdirs "$src_dir/complete" "$dest_dir/プライベート"
else
  log_info "Safe move: プライベート directory empty, skipping!"
  exit 1
fi

# Update qBittorrent VueTorrent webui
log_info "Updating qBittorrent webui with VueTorrent "
if cd /mnt/user/appdata/qbittorrent/webui 2>/dev/null; then
  rm -rf VueTorrent
  log_info "Cloning VueTorrent latest-release branch from GitHub"
  GIT_TERMINAL_PROMPT=0
  if command -v timeout >/dev/null 2>&1; then
    if timeout 300 git clone --quiet --depth 1 --single-branch --branch latest-release https://github.com/VueTorrent/VueTorrent.git; then
      log_info "qBittorrent webui VueTorrent updated"
    else
      log_warn "qBittorrent webui VueTorrent git clone failed or timed out"
    fi
  else
    if git clone --quiet --depth 1 --single-branch --branch latest-release https://github.com/VueTorrent/VueTorrent.git; then
      log_info "qBittorrent webui VueTorrent updated"
    else
      log_warn "qBittorrent webui VueTorrent git clone failed"
    fi
  fi
  cd ~ || true
else
  log_warn "Cannot cd to /mnt/user/appdata/qbittorrent/webui — skipping VueTorrent update"
fi

end_ts=$(date +%s)
elapsed=$((end_ts - START_TS))
hours=$((elapsed/3600))
mins=$(((elapsed%3600)/60))
secs=$((elapsed%60))
if [ "$hours" -gt 0 ]; then
  runtime="${hours}h ${mins}m ${secs}s"
elif [ "$mins" -gt 0 ]; then
  runtime="${mins}m ${secs}s"
else
  runtime="${secs}s"
fi
log_info "Processing finished successfully (Runtime: ${runtime})"
exit 0