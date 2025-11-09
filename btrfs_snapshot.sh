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

POOLS=(/mnt/cache)                    # explicit list of btrfs pools to snapshot, enter directory with spaces for multiple
SHARES=("appdata" "domains" "system") # list of shares (subvolumes) to snapshot per pool
AUTO_DISCOVER_POOLS=false             # set true to auto-discover all mounted btrfs filesystems
EXCLUDE_POOLS=()                      # exact mountpoints to exclude
EXCLUDE_PATTERNS=(                    # regex patterns to exclude
  '^/var/lib/docker'
  '^/var/lib/libvirt'
  '^/mnt/removable'
  '^/mnt/user/system'
  '^/boot'
  '^/run'
  '^/tmp'
)
SNAPSHOT_USAGE_WARN_PCT=20            # warn if snapshots exceed % of pool
FORCE_PRUNE_FREE_GB=150               # force prune if free < X GB
MIN_SNAPSHOTS_KEEP=3                  # minimum number of snapshots to keep
DEFAULT_KEEP_RAID1=7                 # default snapshots to keep for RAID1
DEFAULT_KEEP_SINGLE=7                 # default snapshots to keep for single disk
DEFAULT_KEEP_RAID0=5                  # default snapshots to keep for RAID0
STOP_DOCKER_VMS=false                 # set true to stopping Docker/VMs
NOTIFY_ICON="normal"                  # notification icon

# --------------------------------------------------------------------------------

# Logging function
timestamp() { date +"%Y-%m-%d_%H-%M-%S"; }
log() { echo "[$(timestamp)] $*"; }

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

# Determine POOLS to process
if [ "$AUTO_DISCOVER_POOLS" = true ]; then
  mapfile -t _DISCOVERED_POOLS < <(findmnt -t btrfs -n -o TARGET || true)
  POOLS=()
  for _p in "${_DISCOVERED_POOLS[@]}"; do
    skip=false
    for ex in "${EXCLUDE_POOLS[@]}"; do
      if [ "$_p" = "$ex" ]; then
        skip=true
        break
      fi
    done
    [ "$skip" = true ] && continue

    for pat in "${EXCLUDE_PATTERNS[@]}"; do
      if printf '%s\n' "$_p" | grep -Eq "$pat"; then
        skip=true
        break
      fi
    done
    [ "$skip" = true ] && continue

    POOLS+=("$_p")
  done
  log "Autodiscover: discovered ${#_DISCOVERED_POOLS[@]} btrfs mount(s), using ${#POOLS[@]} after filtering"
fi

for POOL in "${POOLS[@]}"; do
  [ -d "$POOL" ] || { log "Pool $POOL not found, skipping"; continue; }
  POOL_SNAP_BASE="$POOL/.snapshots"
  mkdir -p "$POOL_SNAP_BASE"
  chown -R nobody:users "$POOL_SNAP_BASE" 2>/dev/null || true

  # Detect RAID type for this pool
  RAID_TYPE=$(btrfs fi df "$POOL" 2>/dev/null | grep -m1 "Data," | awk -F',' '{print $2}' | awk '{print tolower($1)}')
  RAID_TYPE=${RAID_TYPE%:}
  RAID_TYPE=${RAID_TYPE:-unknown}
  log "Pool $POOL detected RAID type: $RAID_TYPE"

  # Compute pool size/avail in GB
  POOL_SIZE_BYTES=$(df -B1 "$POOL" | awk 'NR==2 {gsub(/,/,""); print $2}')
  POOL_AVAIL_BYTES=$(df -B1 "$POOL" | awk 'NR==2 {gsub(/,/,""); print $4}')
  POOL_SIZE=$(( POOL_SIZE_BYTES / 1024 / 1024 / 1024 ))
  POOL_AVAIL=$(( POOL_AVAIL_BYTES / 1024 / 1024 / 1024 ))
  FREE_PCT=$(( POOL_AVAIL * 100 / (POOL_SIZE>0?POOL_SIZE:1) ))
  log "Pool $POOL size ${POOL_SIZE}G, avail ${POOL_AVAIL}G (${FREE_PCT}% free)"

  # Determine SNAPSHOTS_TO_KEEP per pool (reuse existing logic)
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
  log "Pool $POOL retention policy: keep last ${SNAPSHOTS_TO_KEEP} snapshots per share"
  POOL_KEEP+=("$SNAPSHOTS_TO_KEEP")

  for SHARE in "${SHARES[@]}"; do
    SRC="$POOL/$SHARE"
    DEST="$POOL_SNAP_BASE/$SHARE/$DATE"
    if [ ! -d "$SRC" ]; then
      log "Pool $POOL: skipping $SHARE — not found."
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

    # Prune old snapshots
    ls -dt "$POOL_SNAP_BASE/$SHARE"/* 2>/dev/null | tail -n +$((SNAPSHOTS_TO_KEEP+1)) | xargs -r rm -rf
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
for POOL in "${POOLS[@]}"; do
  POOL_SNAP_BASE="$POOL/.snapshots"
  if [ -d "$POOL_SNAP_BASE" ]; then
    p_snap_bytes=$(du -sB1 "$POOL_SNAP_BASE" 2>/dev/null | awk '{print $1}' || echo 0)
  else
    p_snap_bytes=0
  fi
  p_pool_bytes=$(df -B1 "$POOL" 2>/dev/null | awk 'NR==2 {gsub(/,/,""); print $2}' || echo 0)
  p_pool_avail=$(df -B1 "$POOL" 2>/dev/null | awk 'NR==2 {gsub(/,/,""); print $4}' || echo 0)

  TOTAL_SNAP_BYTES=$(( TOTAL_SNAP_BYTES + p_snap_bytes ))
  TOTAL_POOL_BYTES=$(( TOTAL_POOL_BYTES + p_pool_bytes ))
  TOTAL_POOL_AVAIL_BYTES=$(( TOTAL_POOL_AVAIL_BYTES + p_pool_avail ))
done

TOTAL_SNAP_GB=$(awk -v b="$TOTAL_SNAP_BYTES" 'BEGIN{printf "%.0f", b/1024/1024/1024}')
TOTAL_POOL_GB=$(awk -v b="$TOTAL_POOL_BYTES" 'BEGIN{printf "%.0f", b/1024/1024/1024}')
TOTAL_POOL_AVAIL_GB=$(awk -v b="$TOTAL_POOL_AVAIL_BYTES" 'BEGIN{printf "%.0f", b/1024/1024/1024}')

if [ "$TOTAL_POOL_BYTES" -gt 0 ]; then
  TOTAL_SNAP_PCT=$(( TOTAL_SNAP_BYTES * 100 / TOTAL_POOL_BYTES ))
else
  TOTAL_SNAP_PCT=0
fi

log "Snapshots occupy ${TOTAL_SNAP_GB}G (${TOTAL_SNAP_PCT}% of configured pools total ${TOTAL_POOL_GB}G, ${TOTAL_POOL_AVAIL_GB}G free)."

# Build per-pool breakdown (reuse available values where possible)
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
  if [ "$p_pool_bytes" -gt 0 ]; then
    p_pct=$(( p_snap_bytes * 100 / p_pool_bytes ))
  else
    p_pct=0
  fi
  p_snap_gb=$(awk -v b="$p_snap_bytes" 'BEGIN{printf "%.0f", b/1024/1024/1024}')
  p_emoji="✅"
  if [ "$p_pct" -ge 60 ]; then
    p_emoji="⛔"
  elif [ "$p_pct" -ge 40 ]; then
    p_emoji="⚠️"
  fi
  line_text="$p_emoji $POOL — ${p_snap_gb}G (${p_pct}%)"
  suggested_keep="${POOL_KEEP[$idx]:-}" 
  if [ -n "$suggested_keep" ] && [ "$p_pct" -ge "$SNAPSHOT_USAGE_WARN_PCT" ]; then
    line_text+=" — suggested keep: ${suggested_keep}"
  fi
  POOL_LINES+=("$line_text")
  idx=$((idx+1))
done

# Overall emoji/status
overall_emoji="🟢"; status_text="OK"
if [ "$TOTAL_SNAP_PCT" -ge 60 ]; then
  overall_emoji="🔴"; status_text="CRITICAL"
elif [ "$TOTAL_SNAP_PCT" -ge 40 ]; then
  overall_emoji="🟡"; status_text="WARNING"
fi

notify_subject="${overall_emoji} BTRFS Snapshot — ${status_text} (${TOTAL_SNAP_PCT}% used)"
notify_short="💾 ${TOTAL_SNAP_GB}G (${TOTAL_SNAP_PCT}% of ${TOTAL_POOL_GB}G), ${TOTAL_POOL_AVAIL_GB}G free"

notify_body="$overall_emoji Overall: Snapshot usage ${TOTAL_SNAP_PCT}% (${TOTAL_SNAP_GB}G of ${TOTAL_POOL_GB}G)."$'\n\n'
for line in "${POOL_LINES[@]}"; do
  notify_body+="$line"$'\n'
done

if [ "$TOTAL_SNAP_PCT" -ge "$SNAPSHOT_USAGE_WARN_PCT" ]; then
  notify_body+=$'\n🔧 Suggested: run snapshot prune or reduce per-pool retention for high-usage pools.'
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
notify_body+=$'\n\n⏱ Runtime: '
notify_body+="$runtime"

if [ "$TOTAL_SNAP_PCT" -ge "$SNAPSHOT_USAGE_WARN_PCT" ] && [ -x /usr/local/emhttp/webGui/scripts/notify ]; then
  /usr/local/emhttp/webGui/scripts/notify \
    -e "BTRFS Snapshot" \
    -s "$notify_subject" \
    -d "$notify_body" \
    -i "warning"
fi

log "BTRFS snapshot run completed. Runtime: ${runtime}"

exit 0