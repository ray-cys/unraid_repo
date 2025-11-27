#!/bin/bash
LOCKFILE="/tmp/data_management.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another data_management.sh run is active, exiting (lock: $LOCKFILE)"
  exit 1
fi
################################################################################
# ---------------- Configuration ----------------
# Data Management Settings
################################################################################

# ---------------- General Settings ----------------
SRC_DIR="/mnt/user/secure/torrent"    # Source directory to process
DEST_DIR="/mnt/user/secure"           # Destination base directory for processed data
CHMOD_DIR=0775                        # Directory permissions
CHMOD_FILE=0775                       # File permissions
OWN_USER="nobody"                     # Owner user for files and directories
# ---------------- Arrays (patterns / filters / subdirectories) ----------------
RENAME_PATTERNS=("hhd800.com@" "gg5.co@" "-C_GG5" "ch" "uncensored")
UNWANTED_EXTS=("url" "html" "mht" "gif" "txt" "rar" "apk" "jpg")
UNWANTED_NAMES=("18+游戏大全(996gg.cc)-七龍珠H版-三國志H版-三國群淫傳等.mp4")
PRIVATE_SUBDIRS=(
  "Ai.Kano.叶爱" "Aika.Yumeno.夢乃あいか" "Akari.Niimura.新村あかり" "Ena.Satsuki.沙月恵奈"
  "Karen.Yuzuriha.楪カレン" "Sora.Amakawa.天川そら" "Sui.Twinkle.月野江すい" "Yui.Tenma.天馬ゆい"
)
################################################################################

# ---------------- Script Helpers Functions ----------------
# Dynamic logging
log() {
  local level="${1:-info}"; shift || true
  local ts msg min="${LOG_MIN_LEVEL:-debug}"; ts=$(date '+%Y-%m-%d %H:%M:%S'); msg="$*"
  # Rank levels for filtering
  local rank_level rank_min
  case "$level" in
    debug) rank_level=10 ;;
    info)  rank_level=20 ;;
    warn|warning) rank_level=30 ; level=warn ;;
    err|error) rank_level=40 ; level=error ;;
    crit|critical) rank_level=50 ; level=crit ;;
    *) rank_level=20 ; level=info ;;
  esac
  case "$min" in
    debug) rank_min=10 ;;
    info)  rank_min=20 ;;
    warn|warning) rank_min=30 ;;
    err|error) rank_min=40 ;;
    crit|critical) rank_min=50 ;;
    *) rank_min=10 ;;
  esac
  [ "$rank_level" -lt "$rank_min" ] && return 0
  if [ "$level" = debug ]; then
    printf '%s DEBUG: %s\n' "$ts" "$msg"
  elif [ "$level" = info ]; then
    printf '%s %s\n' "$ts" "$msg"
  elif [ "$level" = warn ]; then
    printf '%s WARN: %s\n' "$ts" "$msg" >&2
  elif [ "$level" = error ]; then
    printf '%s ERROR: %s\n' "$ts" "$msg" >&2
  elif [ "$level" = crit ]; then
    printf '%s CRIT: %s\n' "$ts" "$msg" >&2
  else
    printf '%s %s %s\n' "$ts" "$level" "$msg"
  fi
}
# Elapsed seconds since start timestamp
elapsed() {
  local start="$1"
  echo $(( $(date +%s) - start ))
}
# Format runtime from elapsed seconds
format_runtime() {
  local secs="$1"
  printf '%dh %dm %ds' $((secs/3600)) $(((secs%3600)/60)) $((secs%60))
}
# Script finish handler
finish() {
  local code=${1:-0}
  shift || true
  local msg="$*"
  local rt_secs rt
  rt_secs=$(elapsed "$START_TS")
  rt=$(format_runtime "$rt_secs")
  log info "$msg (Runtime: $rt)"
  exit "$code"
}
# Generic has_files with optional exclude path: has_files <dir> [exclude]
has_files() {
  local d="$1"
  local ex="${2:-}"
  [ -d "$d" ] || return 1
  if [ -n "$ex" ]; then
    find "$d" -not \( -path "$ex" -prune \) -type f -print -quit >/dev/null 2>&1
  else
    find "$d" -type f -print -quit >/dev/null 2>&1
  fi
}
# Resolve collision by appending .dupN
resolve_collision() {
  local base="$1"
  local i=1
  local candidate="$base"
  while [ -e "$candidate" ]; do
    candidate="${base}.dup${i}"
    i=$((i+1))
  done
  printf '%s' "$candidate"
}
# Determine if two files are identical (size + sha256 if available)
is_same_file() {
  local a="$1" b="$2"
  [ -f "$a" ] || return 1
  [ -f "$b" ] || return 1
  local sa sb
  sa=$(stat -c%s "$a" 2>/dev/null || echo 0)
  sb=$(stat -c%s "$b" 2>/dev/null || echo 0)
  [ "$sa" = "$sb" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    local ha hb
    ha=$(shasum -a 256 "$a" | awk '{print $1}')
    hb=$(shasum -a 256 "$b" | awk '{print $1}')
    [ "$ha" = "$hb" ] || return 1
  fi
  return 0
}
# Rsync copy wrapper handling 
rsync_copy() {
  local src="$1" destdir="$2" overwrite="$3"
  local owner_group chown_flag
  owner_group=$(id -gn "$OWN_USER" 2>/dev/null || true)
  chown_flag=""
  if rsync --help 2>&1 | grep -q -- --chown; then
    chown_flag="--chown=${OWN_USER}${owner_group:+:$owner_group}"
  fi
  local base_args=( -a --inplace --partial --progress --remove-source-files )
  local extra=()
  if [ "$overwrite" = "yes" ]; then
    extra+=( --checksum )
  fi
  run_with_timestamp rsync "${base_args[@]}" ${chown_flag:+$chown_flag} "${extra[@]}" -- "$src" "$destdir/"
}
# Run rsync with timestamp
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
# Returns file size in bytes
filesize() { local f="$1"; [ -e "$f" ] || { echo 0; return 0; }; local s; s=$(stat -c%s "$f" 2>/dev/null) || s=$(wc -c <"$f" 2>/dev/null || echo 0); echo "${s:-0}"; }
# Final permission normalization helper (targeted; defaults to DEST_DIR)
apply_final_perms() {
  local owner="$OWN_USER" owner_group target
  local -a targets=("$@")
  [ ${#targets[@]} -eq 0 ] && targets=("$DEST_DIR")
  owner_group=$(id -gn "$owner" 2>/dev/null || true)
  for target in "${targets[@]}"; do
    [ -d "$target" ] || { log debug "PERM: skip non-dir $target"; continue; }
    log info "PERM: normalizing $target"
    if [ -n "$owner_group" ]; then
      chown -R "$owner:$owner_group" "$target" 2>/dev/null || log warn "PERM: chown ${owner}:${owner_group} failed on $target"
    else
      chown -R "$owner" "$target" 2>/dev/null || log warn "PERM: chown $owner failed on $target"
    fi
    chmod -R "$CHMOD_DIR" "$target" 2>/dev/null || log warn "PERM: chmod -R $CHMOD_DIR failed on $target"
    find "$target" -type f -exec chmod "$CHMOD_FILE" {} \; >/dev/null 2>&1 || true
    find "$target" -type d -exec chmod g+s {} \; >/dev/null 2>&1 || true
  done
  log debug "PERM: applied to ${#targets[@]} target(s)"
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
# Escape helper:
escape_literal() {
  local mode="$1" s="$2"
  case "$mode" in
    sed)
      printf '%s' "$s" | sed -e 's/[][\\.^$*+?(){}|]/\\&/g' -e 's,/,\\/,g'
      ;;
    glob)
      s=${s//\\/\\\\}
      s=${s//\*/[\*]}
      s=${s//\?/[?]}
      s=${s//\[/[[]}
      printf '%s' "$s"
      ;;
    *) printf '%s' "$s" ;;
  esac
}
# Function to rename patterns in files
rename_patterns() {
  local dir="$1"
  local -a patterns=("${RENAME_PATTERNS[@]:-}")
  [ ${#patterns[@]} -eq 0 ] && { log info "Rename: no patterns configured; skipping"; return 0; }
  for pattern in "${patterns[@]}"; do
    local esc_pat globpat
    esc_pat=$(escape_literal sed "$pattern")
    globpat=$(escape_literal glob "$pattern")
    # Directories
    local -a match_dirs=()
    while IFS= read -r -d '' d; do [[ $d == *$globpat* ]] && match_dirs+=("$d"); done < <(find "$dir" -depth \( -path "$dir/incomplete" -o -path "$dir/incomplete/*" \) -prune -o -type d -print0 2>/dev/null)
    local total_dir_bytes=0
    for md in "${match_dirs[@]}"; do while IFS= read -r -d '' f; do total_dir_bytes=$((total_dir_bytes + $(filesize "$f"))); done < <(find "$md" -type f -print0 2>/dev/null); done
    if [ ${#match_dirs[@]} -gt 0 ]; then
      log info "REN: dir pattern '$pattern' on ${#match_dirs[@]} dirs (size: $(human_readable "$total_dir_bytes"))"
      for d in "${match_dirs[@]}"; do
        local ddir dbase dnewbase dnewpath
        ddir=$(dirname -- "$d"); dbase=$(basename -- "$d"); dnewbase=$(printf '%s' "$dbase" | sed -e "s/${esc_pat}//g")
        [ "$dnewbase" = "$dbase" ] && continue
        dnewpath="$ddir/$dnewbase"
        [ -e "$dnewpath" ] && dnewpath=$(resolve_collision "$dnewpath")
        if mv -n -- "$d" "$dnewpath"; then
          log info "REN: dir '$d' -> '$dnewpath'"
        else
          log warn "REN: dir fail '$d' -> '$dnewpath'"
        fi
      done
    else
      log debug "REN: dir none match '$pattern'"
    fi
    # Files
    local -a match_files=()
    while IFS= read -r -d '' f; do [[ $f == *$globpat* ]] && match_files+=("$f"); done < <(find "$dir" \( -path "$dir/incomplete" -o -path "$dir/incomplete/*" \) -prune -o -type f -print0 2>/dev/null)
    local total_file_bytes=0
    for mf in "${match_files[@]}"; do total_file_bytes=$((total_file_bytes + $(filesize "$mf"))); done
    if [ ${#match_files[@]} -eq 0 ]; then
      log info "REN: file none match '$pattern'"
      continue
    fi
    log info "REN: file pattern '$pattern' on ${#match_files[@]} files (size: $(human_readable "$total_file_bytes"))"
    for f in "${match_files[@]}"; do
      local fdir fbase fnewbase fnewpath
      fdir=$(dirname -- "$f"); fbase=$(basename -- "$f"); fnewbase=$(printf '%s' "$fbase" | sed -e "s/${esc_pat}//g")
      [ "$fnewbase" = "$fbase" ] && continue
      fnewpath="$fdir/$fnewbase"
      if [ -e "$fnewpath" ]; then
        if is_same_file "$f" "$fnewpath"; then
          local rsize; rsize=$(human_readable "$(filesize "$f")")
          log info "REN: identical remove '$f' == '$fnewpath' (size: $rsize)"
          rm -f -- "$f"
          continue
        fi
        fnewpath=$(resolve_collision "$fnewpath")
      fi
      if mv -n -- "$f" "$fnewpath"; then
        local nrsize; nrsize=$(human_readable "$(filesize "$fnewpath")")
        log info "REN: file '$f' -> '$fnewpath' (size: $nrsize)"
      else
        local fsize; fsize=$(human_readable "$(filesize "$f")")
        log warn "REN: file fail '$f' -> '$fnewpath' (size: $fsize)"
      fi
    done
  done
}
# Function to remove unwanted file extensions
remove_unwanted_files() {
  local dir="$1"
  local -a exts=("${UNWANTED_EXTS[@]:-}")
  if [ ${#exts[@]} -eq 0 ]; then
    log info "PRUNE: no unwanted extensions configured; skipping"
    return 0
  fi
  local total_removed_bytes=0
  local removed_count=0
  local -a pred=( '(' )
  local first=1
  for ext in "${exts[@]}"; do
    if [ $first -eq 1 ]; then
      pred+=( -iname "*.${ext}" )
      first=0
    else
      pred+=( -o -iname "*.${ext}" )
    fi
  done
  pred+=( ')' )
  while IFS= read -r -d '' remfile; do
    local rb
    rb=$(filesize "$remfile")
    total_removed_bytes=$((total_removed_bytes + rb))
    removed_count=$((removed_count + 1))
    local rsize
    rsize=$(human_readable "$rb")
    log info "PRUNE: unwanted '$remfile' size=$rsize"
    rm -f -- "$remfile"
  done < <(find "$dir" -not \( -path "$dir/incomplete" -prune \) -type f "${pred[@]}" -print0 2>/dev/null)
  if [[ $removed_count -gt 0 ]]; then
    log info "PRUNE: removed $removed_count files under $dir (bytes: $(human_readable "$total_removed_bytes"))"
  else
    log info "PRUNE: none found under $dir"
  fi
}
# Safely move files from source to destination
safe_move() {
  local src="$1"
  local dest="$2"
  if [[ ! -d "$src" ]]; then
      log warn "MV: source missing '$src'"
    return 0
  fi
  if [[ -z "$(find "$src" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
      log info "MV: source empty '$src'"
    return 0
  fi
  mkdir -p "$dest"
  if ! command -v rsync >/dev/null 2>&1; then
      log error "MV: rsync is required but not found in PATH"
    return 1
  fi
  local moved_bytes=0
  find "$src" -type f -print0 | while IFS= read -r -d '' srcfile; do
    local relpath destfile destdir size
    relpath="${srcfile#"$src"/}"
    destfile="$dest/$relpath"
    destdir="${destfile%/*}"
    mkdir -p "$destdir"
    if [[ -f "$destfile" ]]; then
      if is_same_file "$srcfile" "$destfile"; then
        local size_bytes; size_bytes=$(filesize "$srcfile")
        size=$(human_readable "$size_bytes")
        log info "MV: identical remove '$srcfile' size=$size"
        rm -f -- "$srcfile"
        moved_bytes=$((moved_bytes + size_bytes))
        continue
      else
        local size_bytes; size_bytes=$(filesize "$srcfile")
        size=$(human_readable "$size_bytes")
        log info "MV: overwrite dest='$destfile' src='$srcfile' size=$size"
        rsync_copy "$srcfile" "$destdir" yes
        moved_bytes=$((moved_bytes + size_bytes))
      fi
    else
      local size_bytes; size_bytes=$(filesize "$srcfile")
      size=$(human_readable "$size_bytes")
      log info "MV: move '$srcfile' -> '$destfile' size=$size"
      rsync_copy "$srcfile" "$destdir" no
      moved_bytes=$((moved_bytes + size_bytes))
    fi
  done
  find "$src" -mindepth 1 -type d -empty -delete
  if [[ -d "$src" ]] && [[ -z "$(find "$src" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
      log info "MV: directory empty '$src'"
  fi
  SAFE_MOVE_LAST_BYTES=$moved_bytes
}
# Safely move プライベート subdirectories
move_private_subdirs() {
  local src_base="$1" dest_base="$2"
  local -a subdirs=("${PRIVATE_SUBDIRS[@]:-}")
  [ ${#subdirs[@]} -eq 0 ] && { log info "MV: no PRIVATE_SUBDIRS configured; skipping"; return 0; }
  for subdir in "${subdirs[@]}"; do
    log info "MV: processing private '$subdir'"
    SAFE_MOVE_LAST_BYTES=0
    if safe_move "$src_base/$subdir" "$dest_base/$subdir"; then
      local human_total; human_total=$(human_readable "${SAFE_MOVE_LAST_BYTES:-0}")
      log info "MV: finished private '$subdir' bytes=$human_total"
    else
      log warn "MV: failed private '$subdir'"
    fi
  done
}

# ---------------- Main Processing ----------------
# Record start time and announce processing start
START_TS=$(date +%s)
log info "Starting data processing for source: $SRC_DIR"

if ! has_files "$SRC_DIR"; then
  finish 1 "Source $SRC_DIR directory empty"
fi
# Rename files for metadata scans
rename_patterns "$SRC_DIR"
# Remove unwanted files
remove_unwanted_files "$SRC_DIR"
# Remove unwanted exact file names under "$SRC_DIR/complete"
if [ ${#UNWANTED_NAMES[@]} -gt 0 ]; then
  for ufn in "${UNWANTED_NAMES[@]}"; do
    while IFS= read -r -d '' rem; do
      rbs=$(filesize "$rem")
      log info "PRUNE: unwanted-exact '$rem' size=$(human_readable "$rbs")"
      rm -f -- "$rem"
    done < <(find "$SRC_DIR/complete/" -type f -name "$ufn" -print0 2>/dev/null)
  done
fi
# Atomic move for ポルノ
if has_files "$SRC_DIR/complete/ポルノ"; then
  safe_move "$SRC_DIR/complete/ポルノ" "$DEST_DIR/ポルノ"
else
  log info "MV: ポルノ directory empty, skipping"
fi
# Atomic move for プライベート subdirectories
if has_files "$SRC_DIR/complete" "$SRC_DIR/complete/ポルノ"; then
  move_private_subdirs "$SRC_DIR/complete" "$DEST_DIR/プライベート"
else
  finish 1 "MV: プライベート directory empty, skipping"
fi
# Final permission normalization ==
apply_final_perms "$DEST_DIR/ポルノ" "$DEST_DIR/プライベート" || log warn "PERM: final permission application encountered issues"
# Update qBittorrent VueTorrent webui
log info "Updating qBittorrent webui with VueTorrent "
if cd /mnt/user/appdata/qbittorrent/webui 2>/dev/null; then
  rm -rf VueTorrent
  log info "Cloning VueTorrent latest-release branch from GitHub"
  export GIT_TERMINAL_PROMPT=0
  if command -v timeout >/dev/null 2>&1; then
    if timeout 300 git clone --quiet --depth 1 --single-branch --branch latest-release https://github.com/VueTorrent/VueTorrent.git; then
      log info "qBittorrent webui VueTorrent updated"
    else
      log warn "qBittorrent webui VueTorrent git clone failed or timed out"
    fi
  else
    if git clone --quiet --depth 1 --single-branch --branch latest-release https://github.com/VueTorrent/VueTorrent.git; then
      log info "qBittorrent webui VueTorrent updated"
    else
      log warn "qBittorrent webui VueTorrent git clone failed"
    fi
  fi
  cd ~ || true
else
  log warn "Cannot cd to /mnt/user/appdata/qbittorrent/webui — skipping VueTorrent update"
fi
finish 0 "Processing finished successfully"