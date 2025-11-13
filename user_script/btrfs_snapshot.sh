#!/bin/bash
set -euo pipefail
LOCKFILE="/tmp/btrfs_snapshot.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another btrfs_snapshot.sh run is active, exiting (lock: $LOCKFILE)"
  exit 1
fi

noParity=true
clearLog=false

# --------------------------------------------------------------------------------
# SETTINGS

POOLS=(/mnt/cache)                    # List of BTRFS pools to snapshot, enter directory with spaces for multiple
SHARES=("appdata" "domains" "system") # List of shares (subvolumes) to snapshot per pool
SNAPSHOT_USAGE_WARN_PCT=20            # Warn if snapshots exceed % of pool
SNAPSHOT_USAGE_CRITICAL_PCT=90        # Percent threshold for CRITICAL
SNAPSHOT_USAGE_WARNING_PCT=65         # Percent threshold for WARNING
FORCE_PRUNE_FREE_GB=300               # Force prune if free < X GB
MIN_SNAPSHOTS_KEEP=1                  # Minimum number of snapshots to keep
DEFAULT_KEEP_RAID1=3                  # Default snapshots to keep for RAID1
DEFAULT_KEEP_SINGLE=2                 # Default snapshots to keep for single disk
DEFAULT_KEEP_RAID0=2                  # Default snapshots to keep for RAID0
STOP_DOCKER_VMS=false                 # Set true to stopping Docker/VMs
SUPPRESS_LOGICAL_WARNINGS=true        # If true, do not warn/critical on logical-only totals unless free space is low
LOG_LEVEL="INFO"                      # INFO (default) or DEBUG for verbose per-snapshot logs
SEND_THROTTLE="200m"                  # pv throttle limit for streamed sends (empty = no throttle)

# --------------------------------------------------------------------------------

# Logging function
timestamp() { date +"%Y-%m-%d_%H-%M-%S"; }
log() { echo "[$(timestamp)] $*"; }

# Logging helpers
log_info() { echo "[$(timestamp)] $*"; }
log_debug() {
  if [ "${LOG_LEVEL:-INFO}" = "DEBUG" ]; then
    echo "[$(timestamp)] DEBUG: $*"
  fi
}

# Human-readable bytes helper used in debug logging. Uses numfmt if available.
bytes_human() {
  local b=${1:-0}
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --format="%.0f" "$b" 2>/dev/null || echo "$b"
  else
    awk -v b="$b" 'BEGIN{printf "%dG", b/1024/1024/1024}'
  fi
}

# Convert human-readable strings
human_to_bytes() {
  local s="$1"
  s=${s//,/} 
  awk -v s="$s" 'BEGIN{
    if (s=="" ) {print 0; exit}
    # extract number
    if (match(s, /([0-9]+(\.[0-9]+)?)/, m)) num = m[1]; else num = 0
    # extract unit (KiB, MiB, GiB, TiB, PiB) case-insensitive
    unit = ""
    if (match(s, /(K|M|G|T|P)i?[bB]/, u)) unit = toupper(u[0])
    mult = 1
    if (unit ~ /^K/) mult = 1024
    else if (unit ~ /^M/) mult = 1024*1024
    else if (unit ~ /^G/) mult = 1024*1024*1024
    else if (unit ~ /^T/) mult = 1024*1024*1024*1024
    else if (unit ~ /^P/) mult = 1024*1024*1024*1024*1024
    bytes = num * mult
    printf "%.0f", bytes
  }'
}

# Helper: get pool-level usage using btrfs filesystem df
get_pool_usage() {
  local pool="$1"
  local alloc=0 avail=0
  if command -v btrfs >/dev/null 2>&1; then
    out=$(btrfs filesystem df -b "$pool" 2>/dev/null || true)
    if [ -n "$out" ]; then
      alloc=$(printf '%s' "$out" | awk -F"[ =,]+" '/Data,/ {for(i=1;i<=NF;i++) if($i=="used") {print $(i+1); exit}}' || true)
      meta=$(printf '%s' "$out" | awk -F"[ =,]+" '/Metadata,/ {for(i=1;i<=NF;i++) if($i=="used") {print $(i+1); exit}}' || true)
      if [ -n "$meta" ] && [ -n "$alloc" ]; then
        alloc=$((alloc + meta))
      elif [ -z "$alloc" ] && [ -n "$meta" ]; then
        alloc=$meta
      fi
    fi
  fi
  if [ -z "$alloc" ] || [ "$alloc" -eq 0 ]; then
    alloc=0
  fi
  if [ -d "$pool" ]; then
    avail=$(df -B1 "$pool" 2>/dev/null | awk 'NR==2 {gsub(/,/,""); print $4}' || echo 0)
  fi
  printf '%s %s' "$alloc" "$avail"
}

# Helper: best-effort physical bytes used by a snapshot path
get_snapshot_physical_bytes() {
  local snap="$1"
  if command -v btrfs >/dev/null 2>&1; then
    out=$(btrfs filesystem du -s -b "$snap" 2>/dev/null || true)
    if [ -n "$out" ]; then
      bytes=$(printf '%s' "$out" | awk '/Exclusive:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) {print $i; exit}}')
      if [ -n "$bytes" ]; then
        printf '%s' "$bytes"
        return 0
      fi
      bytes=$(printf '%s' "$out" | awk '/Total:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) {print $i; exit}}')
      if [ -n "$bytes" ]; then
        printf '%s' "$bytes"
        return 0
      fi
    fi
  fi
  if command -v du >/dev/null 2>&1; then
    du -sB1 "$snap" 2>/dev/null | awk '{print $1}' || echo 0
    return 0
  fi
  echo 0
}

# Helper: estimate send-stream size between parent and snapshot
estimate_send_size() {
  local parent="$1" snap="$2"
  local cmd_bytes=0
  if ! command -v btrfs >/dev/null 2>&1; then
    echo 0; return 0
  fi

  # Build the send command with optional parent
  if [ -n "$parent" ]; then
    send_cmd=(btrfs send -p "$parent" "$snap")
  else
    send_cmd=(btrfs send "$snap")
  fi

  # If SEND_THROTTLE is set and pv is available, use it to throttle the stream
  if [ -n "${SEND_THROTTLE:-}" ] && command -v pv >/dev/null 2>&1; then
    if ! cmd_out=$("${send_cmd[@]}" 2>/dev/null | pv -q -L "$SEND_THROTTLE" | wc -c); then
      cmd_bytes=0
    else
      cmd_bytes=${cmd_out:-0}
    fi
  else
    if ! cmd_out=$("${send_cmd[@]}" 2>/dev/null | wc -c); then
      cmd_bytes=0
    else
      cmd_bytes=${cmd_out:-0}
    fi
  fi

  # If the send-based measurement failed or returned zero, fall back to du
  if ! printf '%s' "$cmd_bytes" | grep -Eq '^[0-9]+$' || [ "$cmd_bytes" -le 0 ]; then
    if command -v du >/dev/null 2>&1; then
      du -sB1 "$snap" 2>/dev/null | awk '{print $1}' || echo 0
      return 0
    fi
    echo 0
    return 0
  fi

  printf '%s' "$cmd_bytes"
}

# Stop Docker & VMs if enabled
if [ "$STOP_DOCKER_VMS" = true ]; then
  if docker info &>/dev/null; then
    log "Stopping Docker..."
    /etc/rc.d/rc.docker stop
  fi
  if [ "$(virsh list --all 2>/dev/null | wc -l)" -gt 1 ]; then
    log "Stopping VMs..."
    /etc/rc.d/rc.libvirt stop
  fi
fi

# Snapshot creation
DATE=$(timestamp)
START_TS=$(date +%s)

for POOL in "${POOLS[@]}"; do
  [ -d "$POOL" ] || { log "Pool $POOL not found, skipping"; continue; }
  POOL_SNAP_BASE="$POOL/.snapshots"
  mkdir -p "$POOL_SNAP_BASE"
  chown -R nobody:users "$POOL_SNAP_BASE" 2>/dev/null || true

  # Detect RAID type for this pool
  RAID_TYPE=$(btrfs fi df "$POOL" 2>/dev/null | grep -m1 "Data," | awk -F',' '{print $2}' | awk '{print tolower($1)}')
  RAID_TYPE=${RAID_TYPE%:}
  RAID_TYPE=${RAID_TYPE:-unknown}
  log "Pool $POOL: Detected RAID = $RAID_TYPE"

  # Compute pool size/avail in GB
  POOL_SIZE_BYTES=$(df -B1 "$POOL" | awk 'NR==2 {gsub(/,/,""); print $2}')
  POOL_AVAIL_BYTES=$(df -B1 "$POOL" | awk 'NR==2 {gsub(/,/,""); print $4}')
  POOL_SIZE=$(( POOL_SIZE_BYTES / 1024 / 1024 / 1024 ))
  POOL_AVAIL=$(( POOL_AVAIL_BYTES / 1024 / 1024 / 1024 ))
  FREE_PCT=$(( POOL_AVAIL * 100 / (POOL_SIZE>0?POOL_SIZE:1) ))
  log "Pool $POOL: Pool size ${POOL_SIZE}G, available ${POOL_AVAIL}G (${FREE_PCT}% free)"

  # Determine snapshots to keep per pool
  case "$RAID_TYPE" in
    *raid1*) KEEP_DEFAULT=$DEFAULT_KEEP_RAID1 ;;
    *raid0*) KEEP_DEFAULT=$DEFAULT_KEEP_RAID0 ;;
    *)       KEEP_DEFAULT=$DEFAULT_KEEP_SINGLE ;;
  esac

  if [ "$POOL_AVAIL" -lt "$FORCE_PRUNE_FREE_GB" ]; then
    SNAPSHOTS_TO_KEEP=$MIN_SNAPSHOTS_KEEP
  elif [ "$FREE_PCT" -lt 20 ]; then
    SNAPSHOTS_TO_KEEP=$(( KEEP_DEFAULT / 4 ))
  elif [ "$FREE_PCT" -lt 35 ]; then
    SNAPSHOTS_TO_KEEP=$(( KEEP_DEFAULT / 2 ))
  else
    SNAPSHOTS_TO_KEEP=$KEEP_DEFAULT
  fi
  (( SNAPSHOTS_TO_KEEP < MIN_SNAPSHOTS_KEEP )) && SNAPSHOTS_TO_KEEP=$MIN_SNAPSHOTS_KEEP
  log "Pool $POOL: Retained last ${SNAPSHOTS_TO_KEEP} snapshots per share"
  POOL_KEEP+=("$SNAPSHOTS_TO_KEEP")

  for SHARE in "${SHARES[@]}"; do
    SRC="$POOL/$SHARE"
    DEST="$POOL_SNAP_BASE/$SHARE/$DATE"
    if [ ! -d "$SRC" ]; then
      log "Pool $POOL: Skipping $SHARE — not found."
      continue
    fi
    mkdir -p "$POOL_SNAP_BASE/$SHARE"

    if ! btrfs subvolume show "$SRC" &>/dev/null; then
      log "Pool $POOL: $SRC is not a BTRFS subvolume. Creating one..."
      mv "$SRC" "${SRC}_old"
      btrfs subvolume create "$SRC"
      mv "${SRC}_old"/* "$SRC"/ 2>/dev/null || true
      rm -rf "${SRC}_old"
    fi

    log "Pool $POOL: Creating read-only snapshot of $SHARE..."
    if ! btrfs subvolume snapshot -r "$SRC" "$DEST" &>/dev/null; then
      log "Pool $POOL: ERROR: Snapshot failed for $SHARE"
      continue
    fi
  done
  
  # Default: prune per-share (retain SNAPSHOTS_TO_KEEP per share)
  for SHARE in "${SHARES[@]}"; do
    share_dir="$POOL_SNAP_BASE/$SHARE"
    if [ ! -d "$share_dir" ]; then
      continue
    fi
    mapfile -d $'\0' snaps < <(find "$share_dir" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null || true)
    num_snaps=${#snaps[@]}
    if [ "$num_snaps" -gt "$SNAPSHOTS_TO_KEEP" ]; then
      to_delete=$(( num_snaps - SNAPSHOTS_TO_KEEP ))
      entries=()
      for s in "${snaps[@]:-}"; do
        [ -n "$s" ] || continue
        mtime=0
        if command -v btrfs >/dev/null 2>&1 && btrfs subvolume show "$s" >/dev/null 2>&1; then
          creation=$(btrfs subvolume show "$s" 2>/dev/null | awk -F': ' '/Creation time/ {print $2; exit}' || true)
          if [ -n "$creation" ]; then
            if date -d "$creation" +%s >/dev/null 2>&1; then
              mtime=$(date -d "$creation" +%s)
            fi
          fi
        fi
        if [ "$mtime" -eq 0 ]; then
          mtime=$(stat -c %Y "$s" 2>/dev/null || echo 0)
        fi
        entries+=("${mtime}|${s}")
      done
      IFS=$'\n' sorted=( $(printf '%s\n' "${entries[@]}" | sort -n) )
      unset IFS
      i=0
      while [ $i -lt "$to_delete" ]; do
        entry="${sorted[$i]:-}"
        [ -n "$entry" ] || break
        path=${entry#*|}
        if command -v btrfs >/dev/null 2>&1 && btrfs subvolume show "$path" >/dev/null 2>&1; then
          log "Prune: deleting subvolume (btrfs): $path"
          if ! btrfs subvolume delete "$path" 2>/dev/null; then
            log "Prune: btrfs delete failed for $path — falling back to rm -rf"
            rm -rf -- "$path" || log "Prune: rm failed for $path"
          fi
        else
          log "Prune: deleting directory (rm): $path"
          rm -rf -- "$path" || log "Prune: rm failed for $path"
        fi
        i=$((i+1))
      done
    fi
  done
done

# Restart Docker & VMs if stopped
if [ "$STOP_DOCKER_VMS" = true ]; then
  if ! docker info &>/dev/null; then
    log "Starting Docker..."
    /etc/rc.d/rc.docker start
  fi
  if ! virsh list --all &>/dev/null; then
    log "Starting VMs..."
    /etc/rc.d/rc.libvirt start
  fi
fi

# Aggregate health check across configured POOLS
TOTAL_SNAP_BYTES=0
TOTAL_POOL_BYTES=0
TOTAL_POOL_AVAIL_BYTES=0
declare -A POOL_SNAP_PHYS_BYTES
declare -A POOL_MATCHED_COUNT
declare -A POOL_DU_COUNT
declare -A POOL_MATCHED_PHYS_BYTES
declare -A POOL_MATCHED_DU_BYTES
for POOL in "${POOLS[@]}"; do
  POOL_SNAP_BASE="$POOL/.snapshots"
  if [ -d "$POOL_SNAP_BASE" ]; then
    p_snap_bytes=$(du -sB1 "$POOL_SNAP_BASE" 2>/dev/null | awk '{print $1}' || echo 0)
  else
    p_snap_bytes=0
  fi
  p_pool_bytes=$(df -B1 "$POOL" 2>/dev/null | awk 'NR==2 {gsub(/,/,""); print $2}' || echo 0)
  p_pool_avail=$(df -B1 "$POOL" 2>/dev/null | awk 'NR==2 {gsub(/,/,"" ); print $4}' || echo 0)
  p_snap_phys_bytes=0
  matched_count=0; du_count=0; matched_phys_bytes=0; matched_du_bytes=0
  p_pct_est_trigger=0
  if [ "$p_pool_bytes" -gt 0 ]; then
    p_pct_est_trigger=$(( p_snap_bytes * 100 / p_pool_bytes ))
  fi
  allow_estimate=true

  # Process snapshots per-share so parent-based estimates are computed within the same share
  for SHARE in "${SHARES[@]}"; do
    share_snap_dir="$POOL_SNAP_BASE/$SHARE"
    if [ ! -d "$share_snap_dir" ]; then
      continue
    fi
    mapfile -d $'\0' share_snaps < <(find "$share_snap_dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
    j=0
    for snap in "${share_snaps[@]:-}"; do
      [ -n "$snap" ] || { j=$((j+1)); continue; }
      if command -v btrfs >/dev/null 2>&1 && ! btrfs subvolume show "$snap" >/dev/null 2>&1; then
        j=$((j+1)); continue
      fi
      phys=$(get_snapshot_physical_bytes "$snap" 2>/dev/null || echo 0)
      phys=${phys:-0}
      if printf '%s' "$phys" | grep -Eq '^[0-9]+$' && [ "$phys" -gt 0 ]; then
        p_snap_phys_bytes=$(( p_snap_phys_bytes + phys ))
        matched_count=$((matched_count+1))
        matched_phys_bytes=$((matched_phys_bytes + phys))
        log_debug "$snap method=filesystem_du bytes=$phys"
      else
        if [ "$allow_estimate" = true ]; then
          parent=""
          if [ "$j" -gt 0 ]; then
            parent=${share_snaps[$((j-1))]}
          fi
          est=$(estimate_send_size "$parent" "$snap" 2>/dev/null || echo 0)
          est=${est:-0}
          if printf '%s' "$est" | grep -Eq '^[0-9]+$' && [ "$est" -gt 0 ]; then
            p_snap_phys_bytes=$(( p_snap_phys_bytes + est ))
            matched_count=$((matched_count+1))
            matched_phys_bytes=$((matched_phys_bytes + est))
            log_debug "$snap method=send_estimate parent=$(basename "$parent") bytes=$est"
            j=$((j+1))
            continue
          fi
        fi
        duv=$(du -sB1 "$snap" 2>/dev/null | awk '{print $1}' || echo 0)
        duv=${duv:-0}
        if [ "$duv" -gt 0 ]; then
          p_snap_phys_bytes=$(( p_snap_phys_bytes + duv ))
          du_count=$((du_count+1))
          matched_du_bytes=$((matched_du_bytes + duv))
          log_debug "$snap method=du bytes=$duv"
        fi
      fi
      j=$((j+1))
    done
  done

  # Store per-pool counters for later reporting
  POOL_SNAP_PHYS_BYTES["$POOL"]=$p_snap_phys_bytes
  POOL_MATCHED_COUNT["$POOL"]=$matched_count
  POOL_DU_COUNT["$POOL"]=$du_count
  POOL_MATCHED_PHYS_BYTES["$POOL"]=$matched_phys_bytes
  POOL_MATCHED_DU_BYTES["$POOL"]=$matched_du_bytes

  TOTAL_SNAP_BYTES=$(( TOTAL_SNAP_BYTES + p_snap_bytes ))
  TOTAL_SNAP_PHYS_BYTES=$(( ${TOTAL_SNAP_PHYS_BYTES:-0} + p_snap_phys_bytes ))
  POOL_SNAP_PHYS_BYTES["$POOL"]=$p_snap_phys_bytes
  TOTAL_POOL_BYTES=$(( TOTAL_POOL_BYTES + p_pool_bytes ))
  TOTAL_POOL_AVAIL_BYTES=$(( TOTAL_POOL_AVAIL_BYTES + p_pool_avail ))
done

TOTAL_SNAP_GB=$(awk -v b="$TOTAL_SNAP_BYTES" 'BEGIN{printf "%.0f", b/1024/1024/1024}')
TOTAL_POOL_GB=$(awk -v b="$TOTAL_POOL_BYTES" 'BEGIN{printf "%.0f", b/1024/1024/1024}')
TOTAL_POOL_AVAIL_GB=$(awk -v b="$TOTAL_POOL_AVAIL_BYTES" 'BEGIN{printf "%.0f", b/1024/1024/1024}')

if [ "$TOTAL_POOL_BYTES" -gt 0 ]; then
  if [ -n "${TOTAL_SNAP_PHYS_BYTES:-}" ] && [ "${TOTAL_SNAP_PHYS_BYTES:-0}" -gt 0 ]; then
    if [ "${TOTAL_SNAP_PHYS_BYTES:-0}" -gt "$TOTAL_POOL_BYTES" ] && [ "${SUPPRESS_LOGICAL_WARNINGS:-true}" = "true" ] && [ "$TOTAL_POOL_AVAIL_GB" -gt "$FORCE_PRUNE_FREE_GB" ]; then
      TOTAL_SNAP_PCT=$(( TOTAL_SNAP_BYTES * 100 / TOTAL_POOL_BYTES ))
      USED_MODE="logical"
      LOGICAL_SUPPRESSED=1
    else
      TOTAL_SNAP_PCT=$(( TOTAL_SNAP_PHYS_BYTES * 100 / TOTAL_POOL_BYTES ))
      USED_MODE="physical"
    fi
  else
    TOTAL_SNAP_PCT=$(( TOTAL_SNAP_BYTES * 100 / TOTAL_POOL_BYTES ))
    USED_MODE="logical"
  fi
else
  TOTAL_SNAP_PCT=0
  USED_MODE="logical"
fi

# Cap percent at 100 to avoid confusing >100% reports; set OVERCOUNT_WARNING if overflow occurred
if [ "$TOTAL_SNAP_PCT" -gt 100 ]; then
  OVERCOUNT_WARNING=1
  TOTAL_SNAP_PCT=100
else
  OVERCOUNT_WARNING=0
fi

if [ "${OVERCOUNT_WARNING:-0}" -eq 1 ]; then
  notify_body+=$'\n\nNote: total snapshot size exceeded pool capacity when summing logical snapshot sizes.'
  notify_body+=$'\nThis often happens because shared data between snapshots is counted multiple times.'
  notify_body+=$'\nUse `btrfs filesystem du` or `btrfs send` (streaming parent-based) for per-subvolume physical usage; `du` is a logical fallback.'
fi

log "Snapshots: Occupy ${TOTAL_SNAP_GB}G (${TOTAL_SNAP_PCT}% of configured pools total ${TOTAL_POOL_GB}G, ${TOTAL_POOL_AVAIL_GB}G free)."

# Build per-pool breakdown
POOL_LINES=()
idx=0
for POOL in "${POOLS[@]}"; do
  POOL_SNAP_BASE="$POOL/.snapshots"
  if [ -d "$POOL_SNAP_BASE" ]; then
    p_snap_bytes=$(du -sB1 "$POOL_SNAP_BASE" 2>/dev/null | awk '{print $1}' || echo 0)
  else
    p_snap_bytes=0
  fi
  p_pool_bytes=$(df -B1 "$POOL" 2>/dev/null | awk 'NR==2 {gsub(/,/ ,""); print $2}' || echo 0)

  # Compute per-pool percent using physical if available
  p_snap_phys_bytes=${POOL_SNAP_PHYS_BYTES["$POOL"]:-0}
  if [ "$p_pool_bytes" -gt 0 ]; then
    if [ "$p_snap_phys_bytes" -gt 0 ]; then
      p_pct_raw=$(( p_snap_phys_bytes * 100 / p_pool_bytes ))
      p_used_human=$(awk -v b="$p_snap_phys_bytes" 'BEGIN{printf "%d", b/1024/1024/1024}')
      p_note="(phys)"
    else
      p_pct_raw=$(( p_snap_bytes * 100 / p_pool_bytes ))
      p_used_human=$(awk -v b="$p_snap_bytes" 'BEGIN{printf "%d", b/1024/1024/1024}')
      p_note="(logical)"
    fi
  else
    p_pct_raw=0
  fi

  # Decide on display percentage (cap at 100) but keep raw for debugging
  p_overcount=0
  p_pct=${p_pct_raw:-0}
  if [ "$p_pct" -gt 100 ]; then
    p_overcount=1
    p_pct=100
  fi
  num_snaps=0
  if [ -d "$POOL_SNAP_BASE" ]; then
    num_snaps=$(find "$POOL_SNAP_BASE" -mindepth 1 -maxdepth 2 -type d 2>/dev/null | wc -l || echo 0)
  fi
  if [ "$p_snap_phys_bytes" -gt 0 ]; then
    log "Pool $POOL: Snapshots physical total: $(bytes_human ${p_snap_phys_bytes}) across ${num_snaps} snapshots"
  else
    log "Pool $POOL: Snapshot physical accounting unavailable; logical total: $(bytes_human ${p_snap_bytes:-0}) across ${num_snaps} snapshots (may overcount shared data)"
  fi
p_snap_gb=$(awk -v b="$p_snap_bytes" 'BEGIN{printf "%.0f", b/1024/1024/1024}')
p_emoji="✅"
  if [ "$p_pct" -ge "$SNAPSHOT_USAGE_CRITICAL_PCT" ]; then
      if [ "$p_snap_phys_bytes" -gt 0 ]; then
        p_emoji="⛔"
    else
      p_emoji="⚠️"
    fi
  elif [ "$p_pct" -ge "$SNAPSHOT_USAGE_WARNING_PCT" ]; then
    p_emoji="⚠️"
  fi

# Include physical/logical note if physical data present
  if [ "$p_snap_phys_bytes" -gt 0 ]; then
    p_snap_phys_gb=$(awk -v b="$p_snap_phys_bytes" 'BEGIN{printf "%.0f", b/1024/1024/1024}')
    line_text="$p_emoji $POOL — ${p_snap_phys_gb}G physical / ${p_snap_gb}G logical (${p_pct}%)"
  else
    line_text="$p_emoji $POOL — ${p_snap_gb}G (${p_pct}%)"
    if [ "$p_overcount" -eq 1 ]; then
      line_text+=" (may overcount)"
    fi
  fi
suggested_keep="${POOL_KEEP[$idx]:-}" 
if [ -n "$suggested_keep" ] && [ "$p_pct" -ge "$SNAPSHOT_USAGE_WARN_PCT" ]; then
  line_text+=" — suggested keeping: ${suggested_keep}"
fi
POOL_LINES+=("$line_text")
idx=$((idx+1))
done

decide_status() {
  # Centralized status decision and suppression logic
  overall_emoji="🟢"; status_text="OK"
  CRITICAL_SUPPRESSED=0
  LOGICAL_SUPPRESSED=0

  if [ "$TOTAL_SNAP_PCT" -ge "$SNAPSHOT_USAGE_CRITICAL_PCT" ]; then
    if [ "$USED_MODE" = "physical" ]; then
      overall_emoji="🔴"; status_text="CRITICAL"
    else
      if [ "${SUPPRESS_LOGICAL_WARNINGS:-true}" = "true" ] && [ "$TOTAL_POOL_AVAIL_GB" -gt "$FORCE_PRUNE_FREE_GB" ]; then
        overall_emoji="🟢"; status_text="OK"
        CRITICAL_SUPPRESSED=1
        LOGICAL_SUPPRESSED=1
      else
        overall_emoji="🟡"; status_text="WARNING"
        CRITICAL_SUPPRESSED=1
      fi
    fi
  elif [ "$TOTAL_SNAP_PCT" -ge "$SNAPSHOT_USAGE_WARNING_PCT" ]; then
    overall_emoji="🟡"; status_text="WARNING"
  fi
}

# Decide final overall status using centralized logic
decide_status

notify_subject="BTRFS Snapshot — ${status_text} (${TOTAL_SNAP_PCT}% used)"
TOTAL_SNAP_PHYS_GB=$(awk -v b="${TOTAL_SNAP_PHYS_BYTES:-0}" 'BEGIN{printf "%.0f", b/1024/1024/1024}')
notify_short="💾 ${TOTAL_SNAP_GB}G logical / ${TOTAL_SNAP_PHYS_GB}G phys (${TOTAL_SNAP_PCT}% of ${TOTAL_POOL_GB}G), ${TOTAL_POOL_AVAIL_GB}G free"

# Include which mode (physical/logical) was used for percent
notify_body="$overall_emoji Overall: Snapshot usage ${TOTAL_SNAP_PCT}% (${TOTAL_SNAP_GB}G logical"
if [ -n "${TOTAL_SNAP_PHYS_BYTES:-}" ] && [ "${TOTAL_SNAP_PHYS_BYTES:-0}" -gt 0 ]; then
  TOTAL_SNAP_PHYS_GB=$(awk -v b="$TOTAL_SNAP_PHYS_BYTES" 'BEGIN{printf "%.0f", b/1024/1024/1024}')
  notify_body+=" / ${TOTAL_SNAP_PHYS_GB}G physical (used ${USED_MODE})"
fi
notify_body+=") of ${TOTAL_POOL_GB}G."$'\n\n'
for line in "${POOL_LINES[@]}"; do
  notify_body+="$line"$'\n'
done

# Add per-pool detailed counts
notify_body+=$'\nPer-pool detail:\n'
for POOL in "${POOLS[@]}"; do
  p_mc=${POOL_MATCHED_COUNT["$POOL"]:-0}
  p_dc=${POOL_DU_COUNT["$POOL"]:-0}
  p_mp=${POOL_MATCHED_PHYS_BYTES["$POOL"]:-0}
  p_md=${POOL_MATCHED_DU_BYTES["$POOL"]:-0}
  # Build a human summary only for available methods
  details=()
  if [ "$p_mp" -gt 0 ]; then
    p_mp_gb=$(awk -v b="$p_mp" 'BEGIN{printf "%dG", (b/1024/1024/1024)}')
    details+=("${p_mc} via estimate (${p_mp_gb})")
  fi
  if [ "$p_md" -gt 0 ]; then
    p_md_gb=$(awk -v b="$p_md" 'BEGIN{printf "%dG", (b/1024/1024/1024)}')
    details+=("${p_dc} via du (${p_md_gb})")
  fi
  if [ ${#details[@]} -eq 0 ]; then
    # Fallback to logical snapshot directory size (may overcount shared extents)
    p_snap_bytes=0
    POOL_SNAP_BASE="$POOL/.snapshots"
    if [ -d "$POOL_SNAP_BASE" ]; then
      p_snap_bytes=$(du -sB1 "$POOL_SNAP_BASE" 2>/dev/null | awk '{print $1}' || echo 0)
    fi
    p_snap_gb=$(awk -v b="$p_snap_bytes" 'BEGIN{printf "%dG", (b/1024/1024/1024)}')
    details+=("logical total ${p_snap_gb} (may overcount)")
  fi
  notify_body+="$POOL: ${details[*]}"$'\n'
done

if [ "$TOTAL_SNAP_PCT" -ge "$SNAPSHOT_USAGE_WARN_PCT" ]; then
  notify_body+=$'\n🔧 Suggested: run snapshot prune or reduce per-share retention for high-usage pools (or lower the default keep counts).'
fi

if [ "${OVERCOUNT_WARNING:-0}" -eq 1 ] || [ "${CRITICAL_SUPPRESSED:-0}" -eq 1 ]; then
  notify_body+=$'\n\nNote: snapshot size calculations may be inflated because logical totals can double-count shared extents.'
  notify_body+=$'\nUse `btrfs filesystem du` or streaming `btrfs send` (parent-based) for accurate physical accounting; `du` is a logical fallback.'
  if [ "${OVERCOUNT_WARNING:-0}" -eq 1 ]; then
    notify_body+=$'\n(Reason: logical totals exceeded pool capacity when summed.)'
  fi
  if [ "${CRITICAL_SUPPRESSED:-0}" -eq 1 ]; then
    notify_body+=$'\n(Info: CRITICAL was downgraded to WARNING because physical totals were not available.)'
  fi
fi

# Compute script runtime 
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
hours=$((ELAPSED/3600))
mins=$(((ELAPSED%3600)/60))
secs=$((ELAPSED%60))
if [ "$hours" -gt 0 ]; then
  runtime="${hours}h ${mins}m ${secs}s"
elif [ "$mins" -gt 0 ]; then
  runtime="${mins}m ${secs}s"
else
  runtime="${secs}s"
fi

# Add runtime to notification
notify_body+=$'\n\nRuntime: '
notify_body+="$runtime"

# Immediate notification
log_debug "Summary: $notify_subject - $notify_short"
if [ -x /usr/local/emhttp/webGui/scripts/notify ]; then
  if [ "$LOG_LEVEL" = "DEBUG" ]; then
    log_info "DEBUG mode: Notification suppressed. Summary: $notify_subject - $notify_short"
  else
    if [ "${status_text:-OK}" != "OK" ]; then
      /usr/local/emhttp/webGui/scripts/notify \
        -e "BTRFS Snapshot" \
        -s "$notify_subject" \
        -d "$notify_body" \
        -i "warning"
    else
      log_info "Status OK: Notification suppressed. Summary: $notify_subject - $notify_short"
    fi
  fi
fi

log_info "BTRFS snapshot run completed. Runtime: ${runtime}"

exit 0