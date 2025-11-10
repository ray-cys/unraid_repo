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
SNAPSHOT_USAGE_WARN_PCT=20           # warn if snapshots exceed % of pool
SNAPSHOT_USAGE_CRITICAL_PCT=75       # percent threshold for CRITICAL
SNAPSHOT_USAGE_WARNING_PCT=55        # percent threshold for WARNING
FORCE_PRUNE_FREE_GB=300              # force prune if free < X GB
RESCAN_IF_QGROUPS_ENABLED=true       # if true, run a quota rescan even when qgroups already enabled
MIN_SNAPSHOTS_KEEP=3                 # minimum number of snapshots to keep
DEFAULT_KEEP_RAID1=14                # default snapshots to keep for RAID1
DEFAULT_KEEP_SINGLE=7                # default snapshots to keep for single disk
DEFAULT_KEEP_RAID0=5                 # default snapshots to keep for RAID0
STOP_DOCKER_VMS=false                # set true to stopping Docker/VMs
NOTIFY_ICON="normal"                 # notification icon
REQUIRE_PHYSICAL_FOR_CRITICAL=true   # if true, only trigger CRITICAL when qgroup (physical) totals are available
SUPPRESS_LOGICAL_WARNINGS=true       # if true, do not warn/critical on logical-only totals unless free space is low

# --------------------------------------------------------------------------------

# Logging function
timestamp() { date +"%Y-%m-%d_%H-%M-%S"; }
log() { echo "[$(timestamp)] $*"; }

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

# Ensure btrfs qgroups (quota) are enabled for a list of pools and run a rescan with progress logging.
ensure_qgroups_enabled_for_pools() {
  local pool rc
  if ! command -v btrfs >/dev/null 2>&1; then
    log "BTRFS binary not found; skipping qgroup enable/rescan"
    return 0
  fi

  for pool in "$@"; do
    [ -n "$pool" ] || continue
    if [ ! -d "$pool" ]; then
      log "Pool $pool not mounted or path missing; skipping"
      continue
    fi

    # Detect current qgroup state
    if btrfs qgroup show "$pool" >/dev/null 2>&1; then
        log "Metadata quota accounting already enabled on $pool"
        if [ "$RESCAN_IF_QGROUPS_ENABLED" = true ]; then
          log "Rescanning metadata quota accounting on $pool"
          btrfs quota rescan -w "$pool" 2>&1 | while IFS= read -r _line; do
            log "BTRFS $_line"
          done
        rc=${PIPESTATUS[0]:-1}
        if [ "$rc" -ne 0 ]; then
          log "BTRFS metadata rescan failed on $pool (rc=$rc). Physical qgroup sizes may be stale."
        else
          log "BTRFS metadata rescan completed for $pool"
        fi
      fi
      continue
    fi

  log "Quota accounting not enabled on $pool — enabling quota subsystem"
    # Run enable and stream any output to the log
    btrfs quota enable "$pool" 2>&1 | while IFS= read -r _line; do
      log "quota-enable: $_line"
    done
    rc=${PIPESTATUS[0]:-1}
    if [ "$rc" -ne 0 ]; then
      log "Failed to enable qgroups on $pool (rc=$rc); continuing without qgroups for this pool"
      continue
    fi

  log "Starting BTRFS metadata rescan on $pool (this can take a long time). Progress will be logged."
    # Stream progress lines into the log while preserving the rescan exit code
    btrfs quota rescan -w "$pool" 2>&1 | while IFS= read -r _line; do
      log "qgroup-rescan: $_line"
    done
    rc=${PIPESTATUS[0]:-1}
    if [ "$rc" -ne 0 ]; then
      log "BTRFS metadata rescan failed on $pool (rc=$rc). The script will continue but physical qgroup sizes may be missing."
    else
      log "BTRFS metadata rescan completed for $pool"
    fi
  done
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

    # Prune old snapshots — prefer deleting oldest by btrfs creation time, fall back to mtime
    mapfile -d $'\0' snaps < <(find "$POOL_SNAP_BASE/$SHARE" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null || true)
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

      # Sort entries (oldest first) and delete the oldest snapshots
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

# Ensure qgroups are enabled and rescanned for all pools before starting snapshots creation.
ensure_qgroups_enabled_for_pools "${POOLS[@]}"

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
for POOL in "${POOLS[@]}"; do
  POOL_SNAP_BASE="$POOL/.snapshots"
  if [ -d "$POOL_SNAP_BASE" ]; then
    p_snap_bytes=$(du -sB1 "$POOL_SNAP_BASE" 2>/dev/null | awk '{print $1}' || echo 0)
  else
    p_snap_bytes=0
  fi
  p_pool_bytes=$(df -B1 "$POOL" 2>/dev/null | awk 'NR==2 {gsub(/,/,""); print $2}' || echo 0)
  p_pool_avail=$(df -B1 "$POOL" 2>/dev/null | awk 'NR==2 {gsub(/,/,""); print $4}' || echo 0)

# Attempt to get physical snapshot usage via btrfs qgroup (exclusive bytes)
p_snap_phys_bytes=0
if command -v btrfs >/dev/null 2>&1; then
  if btrfs qgroup show "$POOL" >/dev/null 2>&1; then
    qout=$(btrfs qgroup show -p "$POOL" 2>/dev/null || true)

    # Build a map of path->exclusive_bytes from qout (handles human units)
    declare -A QPATH_EXCL
    while IFS= read -r _line; do
      # Skip header or empty lines
      [ -z "$_line" ] && continue
      case "$_line" in
        Qgroupid*|--------*) continue ;;
      esac
      path_field=$(printf '%s' "$_line" | awk '{print $NF}')
      excl_field=$(printf '%s' "$_line" | awk '{print $3}')
      excl_bytes=$(human_to_bytes "$excl_field" 2>/dev/null || echo 0)
      QPATH_EXCL["$path_field"]=$excl_bytes
    done <<EOF
${qout}
EOF

    # Find snapshots under the pool snap base (share/timestamp dirs).
    mapfile -d $'\0' _snaps < <(find "$POOL_SNAP_BASE" -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null || true)
    filtered_snaps=()
    for snap in "${_snaps[@]:-}"; do
      [ -n "$snap" ] || continue
      if btrfs subvolume show "$snap" >/dev/null 2>&1; then
        filtered_snaps+=("$snap")
      else
        :
      fi
    done

    # Counters for summary
    matched_count=0; du_count=0; matched_qgroup_bytes=0; matched_du_bytes=0

    for snap in "${filtered_snaps[@]:-}"; do
      [ -n "$snap" ] || continue
      subvol_id=$(btrfs subvolume show "$snap" 2>/dev/null | awk -F: '/Subvolume ID/ {gsub(/ /,"",$2); print $2; exit}' || true)

      matched=0
      match_method=""
      excl_bytes=0

      if [ -n "$subvol_id" ]; then
        qline=$(printf '%s
' "$qout" | awk -v id="$subvol_id" '$1==("0/"id){print $0; exit}' || true)
        if [ -n "$qline" ]; then
          excl_field=$(printf '%s' "$qline" | awk '{print $3}' || echo 0)
          excl_bytes=$(human_to_bytes "$excl_field" 2>/dev/null || echo 0)
          matched=1; match_method="id"
        fi
      fi

      # Try match by path (last field) — use relative path under pool (strip leading pool/)
      if [ $matched -eq 0 ]; then
        snap_rel=${snap#"$POOL"/}
        for k in "${!QPATH_EXCL[@]}"; do
          if [ "$k" = "$snap_rel" ] || printf '%s' "$k" | grep -qE "/${snap_rel}$"; then
            excl_bytes=${QPATH_EXCL[$k]}
            matched=1; match_method="path"
            break
          fi
        done
      fi

      # If still not matched, try basename match on the last path component (timestamp)
      if [ $matched -eq 0 ]; then
        snap_base=$(basename "$snap")
        for k in "${!QPATH_EXCL[@]}"; do
          if [ "$(basename "$k")" = "$snap_base" ]; then
            excl_bytes=${QPATH_EXCL[$k]}
            matched=1; match_method="basename"
            break
          fi
        done
      fi

      if [ $matched -eq 1 ] && [[ "$excl_bytes" =~ ^[0-9]+$ ]] && [ "$excl_bytes" -gt 0 ]; then
        p_snap_phys_bytes=$(( p_snap_phys_bytes + excl_bytes ))
        matched_count=$((matched_count+1))
        matched_qgroup_bytes=$((matched_qgroup_bytes + excl_bytes))
      fi
    done

    # If found nothing via qgroups (phys=0) optionally fall back to btrfs filesystem du per-snapshot
    if [ "$p_snap_phys_bytes" -eq 0 ]; then
      log "No quota accounting matched snapshots on $POOL; using slow per-snapshot scan for physical usage"
      for snap in "${filtered_snaps[@]:-}"; do
        [ -n "$snap" ] || continue
        du_out=$(btrfs filesystem du -s -B1 "$snap" 2>/dev/null || true)
        du_excl=$(printf '%s' "$du_out" | awk '/Exclusive/ {print $2; exit}' || true)
        if [ -z "$du_excl" ]; then
          du_excl=$(printf '%s' "$du_out" | awk 'match($0, /([0-9]+)/,m){print m[1]; exit}' || true)
        fi
        du_excl=${du_excl//,/}
        if [[ "$du_excl" =~ ^[0-9]+$ ]] && [ "$du_excl" -gt 0 ]; then
          p_snap_phys_bytes=$(( p_snap_phys_bytes + du_excl ))
          du_count=$((du_count+1))
          matched_du_bytes=$((matched_du_bytes + du_excl))
        fi
      done
    fi
  fi
fi

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
    TOTAL_SNAP_PCT=$(( TOTAL_SNAP_PHYS_BYTES * 100 / TOTAL_POOL_BYTES ))
    USED_MODE="physical"
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
  notify_body+=$'\nEnable BTRFS qgroups (quota) and use btrfs qgroup or btrfs filesystem du to get physical usage per subvolume.'
fi

# If logical snapshot totals exceed pool size (shared extents counted multiple times) cap displayed percentage at 100% and mark a warning
if [ "$TOTAL_SNAP_PCT" -gt 100 ]; then
  OVERCOUNT_WARNING=1
  TOTAL_SNAP_PCT=100
else
  OVERCOUNT_WARNING=0
fi

log "Snapshots occupy ${TOTAL_SNAP_GB}G (${TOTAL_SNAP_PCT}% of configured pools total ${TOTAL_POOL_GB}G, ${TOTAL_POOL_AVAIL_GB}G free)."

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
  summary_parts=()
  if [ "$matched_count" -gt 0 ]; then
    summary_parts+=("${matched_count} snaps via metadata scans: $(bytes_human ${matched_qgroup_bytes:-0})")
  fi
  if [ "$du_count" -gt 0 ]; then
    summary_parts+=("${du_count} snaps via slow scan: $(bytes_human ${matched_du_bytes:-0})")
  fi
  if [ ${#summary_parts[@]} -gt 0 ]; then
    log "Snapshot for $POOL: ${summary_parts[*]} — total physical: $(bytes_human ${p_snap_phys_bytes:-0})"
  else
    log "Snapshot for $POOL: no physical metadata available; logical total: $(bytes_human ${p_snap_bytes:-0})"
  fi
p_snap_gb=$(awk -v b="$p_snap_bytes" 'BEGIN{printf "%.0f", b/1024/1024/1024}')
p_emoji="✅"
  if [ "$p_pct" -ge "$SNAPSHOT_USAGE_CRITICAL_PCT" ]; then
    if [ "$p_snap_phys_bytes" -gt 0 ] || [ "$REQUIRE_PHYSICAL_FOR_CRITICAL" = false ]; then
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
    line_text="$p_emoji $POOL — ${p_snap_phys_gb}G phys / ${p_snap_gb}G logical (${p_pct}%)"
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

# Overall emoji/status
overall_emoji="🟢"; status_text="OK"
CRITICAL_SUPPRESSED=0
LOGICAL_SUPPRESSED=0
if [ "$TOTAL_SNAP_PCT" -ge "$SNAPSHOT_USAGE_CRITICAL_PCT" ]; then
  if [ "$USED_MODE" = "physical" ] || [ "$REQUIRE_PHYSICAL_FOR_CRITICAL" = false ]; then
    overall_emoji="🔴"; status_text="CRITICAL"
  else
    if [ "$SUPPRESS_LOGICAL_WARNINGS" = true ] && [ "$TOTAL_POOL_AVAIL_GB" -gt "$FORCE_PRUNE_FREE_GB" ]; then
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

notify_subject="${overall_emoji} BTRFS Snapshot — ${status_text} (${TOTAL_SNAP_PCT}% used)"
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

if [ "$TOTAL_SNAP_PCT" -ge "$SNAPSHOT_USAGE_WARN_PCT" ]; then
  notify_body+=$'\n🔧 Suggested: run snapshot prune or reduce per-pool retention for high-usage pools.'
fi

if [ "${OVERCOUNT_WARNING:-0}" -eq 1 ] || [ "${CRITICAL_SUPPRESSED:-0}" -eq 1 ]; then
  notify_body+=$'\n\n\u26A0\ufe0f Note: snapshot size calculations may be inflated because logical totals can double-count shared extents.'
  notify_body+=$'\nEnable BTRFS metadata quota (qgroups) and run a quota rescan for accurate physical accounting, or use `btrfs filesystem du` as a fallback.'
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