#!/bin/bash
# disk_health_storage_report.sh
# Combined nightly storage usage + light disk & pool health checks
# - Auto-discover array and pool devices
# - Exclude parity drives (auto-detect or set PARITY_BY_ID)
# - Exclude NVMe devices from nightly SMART reads (they're listed but not polled)
# - Safe spin-up via tiny read (dd) only when needed
# - No long SMART tests; no automatic scrubs (scheduled in Unraid GUI)
# - Single nightly email via Unraid notify (keeps existing storage formatting)
#
# Place in User Scripts and schedule nightly. Requires smartctl (smartmontools) and lsblk (present on Unraid).
set -euo pipefail

LOCKFILE="/tmp/disk_health_storage_report.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%F %T')" "Another run is active, exiting" >&2
  exit 1
fi

# ------------------- Configuration -------------------
NOTIFY="/usr/local/emhttp/webGui/scripts/notify"    # Unraid notify
SMARTCTL=$(command -v smartctl || true)
LSBLK=$(command -v lsblk || true)
BTRFS_BIN=$(command -v btrfs || true)
FINDMNT=$(command -v findmnt || true)

# Thresholds (tweak as desired)
HDD_TEMP_WARN=45
HDD_TEMP_CRIT=55
SMART_REALLOC_WARN=1
SMART_REALLOC_CRIT=10
UDMA_CRC_WARN=1

# Spin-up wait time after tiny read (seconds)
SPINUP_SLEEP=6

# If you want to explicitly exclude parity, set PARITY_BY_ID to a space-separated list:
# PARITY_BY_ID="/dev/disk/by-id/ata-WD_... /dev/disk/by-id/ata-WD_..."
PARITY_BY_ID="${PARITY_BY_ID:-}"

# ------------------- Helpers -------------------
safe_cmd() { "$@" 2>/dev/null || true; }

# return resolved device node from by-id path
resolve_dev() {
  local byid="$1"
  readlink -f "$byid" 2>/dev/null || true
}

# check if device is in standby; returns 0 if in standby
device_is_standby() {
  local dev="$1"
  if [ -n "$SMARTCTL" ]; then
    if "$SMARTCTL" -n standby "$dev" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# try to spin up a device via harmless read (works across HBAs)
spinup_via_read() {
  local dev="$1"
  # tiny read to wake device
  dd if="$dev" of=/dev/null bs=1 count=1 >/dev/null 2>&1 || true
  sleep "$SPINUP_SLEEP"
}

# tidily parse SMART output for common attributes (best-effort)
parse_smart_attrs() {
  local out="$1"
  local realloc pending crc temp
  realloc=$(printf "%s" "$out" | awk 'tolower($0) ~ /reallocated/ {print $NF; exit}' )
  pending=$(printf "%s" "$out" | awk 'tolower($0) ~ /pending/ {print $NF; exit}' )
  crc=$(printf "%s" "$out" | awk 'tolower($0) ~ /udma_crc/ {print $NF; exit}' )
  temp=$(printf "%s" "$out" | awk 'tolower($0) ~ /temperature_celsius/ {print $NF; exit}' )
  if [ -z "$temp" ]; then
    temp=$(printf "%s" "$out" | awk 'tolower($0) ~ /temperature/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' | head -n1)
  fi
  realloc=${realloc:-0}
  pending=${pending:-0}
  crc=${crc:-0}
  temp=${temp:-0}
  printf "%s|%s|%s|%s" "$realloc" "$pending" "$crc" "$temp"
}

# detect parity drives (best-effort). prints newline-separated by-id paths
detect_parity() {
  local results=()

  # 1) Use /var/local/emhttp/disks.ini if present
  if [ -f /var/local/emhttp/disks.ini ]; then
    grep -Ei 'parity' /var/local/emhttp/disks.ini 2>/dev/null | while IFS= read -r line; do
      dev=$(printf "%s" "$line" | grep -oE '/dev/sd[a-z]+' || true)
      [ -n "$dev" ] || continue
      for p in /dev/disk/by-id/*; do
        [ -e "$p" ] || continue
        if [ "$(readlink -f "$p")" = "$dev" ]; then results+=("$p"); fi
      done
    done
  fi

  # 2) /boot/config/disks.cfg (older)
  if [ -f /boot/config/disks.cfg ]; then
    grep -Ei 'parity' /boot/config/disks.cfg 2>/dev/null | while IFS= read -r line; do
      dev=$(printf "%s" "$line" | grep -oE '/dev/sd[a-z]+' || true)
      [ -n "$dev" ] || continue
      for p in /dev/disk/by-id/*; do
        [ -e "$p" ] || continue
        if [ "$(readlink -f "$p")" = "$dev" ]; then results+=("$p"); fi
      done
    done
  fi

  # 3) /var/local/emhttp/disks.json
  if [ -f /var/local/emhttp/disks.json ]; then
    grep -i 'parity' /var/local/emhttp/disks.json 2>/dev/null | while IFS= read -r line; do
      dev=$(printf "%s" "$line" | grep -oE '/dev/sd[a-z]+' || true)
      [ -n "$dev" ] || continue
      for p in /dev/disk/by-id/*; do
        [ -e "$p" ] || continue
        if [ "$(readlink -f "$p")" = "$dev" ]; then results+=("$p"); fi
      done
    done
  fi

  # 4) /proc/mdstat heuristic
  if [ -f /proc/mdstat ]; then
    awk '/^md[0-9]+/ {print $1}' /proc/mdstat 2>/dev/null | while IFS= read -r md; do
      awk "/^$md / {print; exit}" /proc/mdstat 2>/dev/null | grep -oE '[a-z]{3,}[0-9]*' | while IFS= read -r member; do
        devpath="/dev/$member"
        [ -e "$devpath" ] || continue
        for p in /dev/disk/by-id/*; do
          [ -e "$p" ] || continue
          if [ "$(readlink -f "$p")" = "$devpath" ]; then results+=("$p"); fi
        done
      done
    done
  fi

  if [ ${#results[@]} -gt 0 ]; then
    printf "%s\n" "${results[@]}" | sort -u
  fi
}

# discover pool devices from /boot/config/pools/*.cfg if present
discover_pool_devices_from_config() {
  local devices=()
  if [ -d /boot/config/pools ]; then
    for cfg in /boot/config/pools/*.cfg; do
      [ -f "$cfg" ] || continue
      # each cfg may contain lines like device=/dev/sdX or /dev/nvme0n1
      while IFS= read -r line; do
        dev=$(printf "%s" "$line" | grep -oE 'device=/dev/[a-z0-9]+' | cut -d= -f2 || true)
        [ -n "$dev" ] || continue
        # resolve to by-id if available
        for p in /dev/disk/by-id/*; do
          [ -e "$p" ] || continue
          if [ "$(readlink -f "$p")" = "$dev" ]; then
            devices+=( "$p" )
            continue 2
          fi
        done
        # fallback: use raw dev path
        devices+=( "$dev" )
      done < "$cfg"
    done
  fi
  # unique
  printf "%s\n" "${devices[@]}" | sort -u
}

# gather mounted pools under /mnt that are not array disks (/mnt/disk*)
discover_mounted_pools() {
  local pools=()
  for p in /mnt/*; do
    [ -d "$p" ] || continue
    # exclude diskX mounts
    if [[ "$(basename "$p")" =~ ^disk[0-9]+$ ]]; then
      continue
    fi
    # common pool directories: cache, appdata, user pools etc
    pools+=( "$p" )
  done
  printf "%s\n" "${pools[@]}" | sort -u
}

# ------------------- Compose Report Header -------------------
NOW=$(date '+%F %T')
SUBJECT="Unraid Storage & Health Report - ${NOW}"
BODY="Unraid Storage & Health Report - ${NOW}\n\n"

# ------------------- Filesystem usage (preserve your df formatting) -------------------
BODY+="--- Filesystem usage ---\n"
while read -r src size used avail pct mount; do
  BODY+=$(printf "%s: used %s (%s), free %s, mounted on %s\n" "$src" "$used" "$pct" "$avail" "$mount")
done < <(df -h --output=source,size,used,avail,pcent,target | tail -n +2)
BODY+="\n"

# ------------------- Discover SATA devices (by-id) - excludes NVMe -------------------
mapfile -t sata_byid < <(ls -1 /dev/disk/by-id/ata-* 2>/dev/null || true)

if [ ${#sata_byid[@]} -eq 0 ]; then
  BODY+="WARNING: No SATA (ata-*) devices discovered under /dev/disk/by-id/. Check device paths or permissions.\n\n"
fi

# ------------------- Parity detection or override -------------------
parity_list=""
if [ -n "${PARITY_BY_ID:-}" ]; then
  parity_list=$(printf "%s\n" $PARITY_BY_ID)
else
  parity_list=$(detect_parity || true)
fi

# ------------------- Build target list (SATA devices excluding parity) -------------------
targets=()
for byid in "${sata_byid[@]}"; do
  [ -e "$byid" ] || continue
  devnode=$(resolve_dev "$byid")
  [ -n "$devnode" ] || continue
  skip=0
  if [ -n "$parity_list" ]; then
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      if [ "$(readlink -f "$p")" = "$devnode" ]; then
        skip=1
        break
      fi
    done <<< "$parity_list"
  fi
  if [ $skip -eq 0 ]; then
    targets+=( "$devnode" )
  fi
done

BODY+="Detected SATA devices to be checked (by-id -> devnode):\n"
for t in "${targets[@]}"; do
  bidname=$(for p in /dev/disk/by-id/ata-*; do [ -e "$p" ] || continue; [ "$(readlink -f "$p")" = "$t" ] && echo "$(basename "$p")" && break; done)
  BODY+="  ${bidname:-unknown} -> ${t}\n"
done
BODY+="\n"

if [ -n "$parity_list" ]; then
  BODY+="Detected parity devices (excluded from checks):\n"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    BODY+="  $(basename "$p") -> $(readlink -f "$p")\n"
  done <<< "$parity_list"
  BODY+="\n"
else
  BODY+="Parity device could not be confidently auto-detected. If you want to exclude parity, set PARITY_BY_ID to the by-id paths.\n\n"
fi

# ------------------- Pool device discovery -------------------
BODY+="--- Pool discovery ---\n"
# 1) Devices mentioned in /boot/config/pools/*.cfg
mapfile -t pool_cfg_devices < <(discover_pool_devices_from_config 2>/dev/null || true)
# 2) Mounted pools under /mnt (list mountpoints)
mapfile -t mounted_pools < <(discover_mounted_pools 2>/dev/null || true)

BODY+="Pools discovered from config: ${#pool_cfg_devices[@]} devices\n"
for p in "${pool_cfg_devices[@]}"; do
  BODY+="  $(basename "$p") -> $(readlink -f "$p")\n"
done
BODY+="Mounted pools: ${#mounted_pools[@]}\n"
for m in "${mounted_pools[@]}"; do
  BODY+="  $m\n"
done
BODY+="\n"

# -------------- Health checks: SATA targets (spin up + SMART) --------------
BODY+="--- Health checks (SATA targets) ---\n"
health_messages=()

if [ -z "$SMARTCTL" ]; then
  BODY+="smartctl not found; install smartmontools plugin to enable SMART checks.\n"
else
  for dev in "${targets[@]}"; do
    [ -b "$dev" ] || continue
    BODY+="Checking $dev ...\n"

    # detect standby
    if device_is_standby "$dev"; then
      BODY+="  Device in standby -> spinning up via tiny read\n"
      spinup_via_read "$dev"
    fi

    # attempt SMART read (-d sat first, fallback -d auto)
    smart_out="$("$SMARTCTL" -A -d sat "$dev" 2>&1 || true)"
    if [ -z "$smart_out" ]; then
      smart_out="$("$SMARTCTL" -A -d auto "$dev" 2>&1 || true)"
    fi

    if [ -z "$smart_out" ]; then
      BODY+="  $dev: SMART unreadable or permission/HBA issue\n"
      continue
    fi

    # parse attributes
    parsed=$(parse_smart_attrs "$smart_out")
    realloc=$(printf "%s" "$parsed" | cut -d'|' -f1)
    pending=$(printf "%s" "$parsed" | cut -d'|' -f2)
    crc=$(printf "%s" "$parsed" | cut -d'|' -f3)
    temp=$(printf "%s" "$parsed" | cut -d'|' -f4)

    BODY+="  realloc=${realloc} pending=${pending} crc=${crc} temp=${temp}°C\n"

    # threshold checks
    if [ "$realloc" -ge "$SMART_REALLOC_WARN" ]; then
      if [ "$realloc" -ge "$SMART_REALLOC_CRIT" ]; then
        health_messages+=("CRITICAL: $dev reallocated sectors = $realloc")
      else
        health_messages+=("WARNING: $dev reallocated sectors = $realloc")
      fi
    fi
    if [ "$pending" -gt 0 ]; then
      health_messages+=("WARNING: $dev pending sectors = $pending")
    fi
    if [ "$crc" -ge "$UDMA_CRC_WARN" ]; then
      health_messages+=("WARNING: $dev UDMA CRC errors = $crc (check cable/port)")
    fi
    if [ "$temp" -ge "$HDD_TEMP_WARN" ]; then
      if [ "$temp" -ge "$HDD_TEMP_CRIT" ]; then
        health_messages+=("CRITICAL: $dev temperature = ${temp}°C")
      else
        health_messages+=("WARNING: $dev temperature = ${temp}°C")
      fi
    fi
  done
fi

BODY+="\n"

# -------------- Pool device SMART checks (if any) --------------
# pool_cfg_devices may include /dev/disk/by-id/... or direct dev paths
if [ ${#pool_cfg_devices[@]} -gt 0 ]; then
  BODY+="--- Pool devices (light checks) ---\n"
  for p in "${pool_cfg_devices[@]}"; do
    [ -e "$p" ] || continue
    # resolve to devnode if by-id
    devnode=$(readlink -f "$p" 2>/dev/null || true)
    if [ -z "$devnode" ]; then
      devnode="$p"
    fi

    # Skip NVMe SMART reads per user request, but list them
    if [[ "$devnode" =~ ^/dev/nvme ]]; then
      BODY+="  $devnode: NVMe device detected — SKIPPED SMART (per nightly policy)\n"
      continue
    fi

    # If parity_skip matches, skip
    skip=0
    if [ -n "$parity_list" ]; then
      while IFS= read -r q; do
        [ -z "$q" ] && continue
        if [ "$(readlink -f "$q")" = "$devnode" ]; then skip=1; break; fi
      done <<< "$parity_list"
    fi
    if [ $skip -eq 1 ]; then
      BODY+="  $devnode: parity/excluded -> skipped\n"
      continue
    fi

    # only handle SATA-like devices here
    if [ -b "$devnode" ]; then
      BODY+="  Checking pool device $devnode ...\n"
      if device_is_standby "$devnode"; then
        BODY+="    Device in standby -> spinning up via tiny read\n"
        spinup_via_read "$devnode"
      fi

      smart_out="$("$SMARTCTL" -A -d sat "$devnode" 2>&1 || true)"
      if [ -z "$smart_out" ]; then
        smart_out="$("$SMARTCTL" -A -d auto "$devnode" 2>&1 || true)"
      fi
      if [ -z "$smart_out" ]; then
        BODY+="    SMART unreadable for $devnode\n"
        continue
      fi
      parsed=$(parse_smart_attrs "$smart_out")
      realloc=$(printf "%s" "$parsed" | cut -d'|' -f1)
      pending=$(printf "%s" "$parsed" | cut -d'|' -f2)
      crc=$(printf "%s" "$parsed" | cut -d'|' -f3)
      temp=$(printf "%s" "$parsed" | cut -d'|' -f4)
      BODY+="    realloc=${realloc} pending=${pending} crc=${crc} temp=${temp}°C\n"

      # propagate messages
      if [ "$realloc" -ge "$SMART_REALLOC_WARN" ]; then
        if [ "$realloc" -ge "$SMART_REALLOC_CRIT" ]; then
          health_messages+=("CRITICAL: $devnode reallocated sectors = $realloc (pool device)")
        else
          health_messages+=("WARNING: $devnode reallocated sectors = $realloc (pool device)")
        fi
      fi
      if [ "$pending" -gt 0 ]; then
        health_messages+=("WARNING: $devnode pending sectors = $pending (pool device)")
      fi
      if [ "$crc" -ge "$UDMA_CRC_WARN" ]; then
        health_messages+=("WARNING: $devnode UDMA CRC errors = $crc (pool device; check cable/port)")
      fi
      if [ "$temp" -ge "$HDD_TEMP_WARN" ]; then
        if [ "$temp" -ge "$HDD_TEMP_CRIT" ]; then
          health_messages+=("CRITICAL: $devnode temperature = ${temp}°C (pool device)")
        else
          health_messages+=("WARNING: $devnode temperature = ${temp}°C (pool device)")
        fi
      fi
    fi
  done
  BODY+="\n"
fi

# -------------- BTRFS pool status (non-invasive reporting) --------------
if [ -n "$BTRFS_BIN" ] && [ -n "$FINDMNT" ]; then
  BODY+="--- BTRFS pool status ---\n"
  while IFS= read -r src mnt; do
    BODY+="BTRFS filesystem: $src mounted on $mnt\n"
    # device stats
    ds=$(safe_cmd btrfs device stats "$mnt")
    if [ -n "$ds" ]; then
      BODY+="  device stats: $(echo "$ds" | tr '\n' ' ')\n"
    fi
    # scrub status (non-destructive, just report)
    scrub_out=$(safe_cmd btrfs scrub status "$mnt")
    if [ -n "$scrub_out" ]; then
      BODY+="  scrub status: $(echo "$scrub_out" | tr '\n' ' ')\n"
      errs=$(printf "%s" "$scrub_out" | awk -F: 'tolower($0) ~ /errors/ { for (i=1;i<=NF;i++) if ($i ~ /errors/) print $(i-1) }' | head -n1)
      errs=${errs:-0}
      if [ "$errs" -gt 0 ]; then
        health_messages+=("WARNING: BTRFS scrub on $mnt reported $errs errors")
      fi
    fi
  done < <(findmnt -n -t btrfs -o SOURCE,TARGET 2>/dev/null || true)
  BODY+="\n"
fi

# -------------- Finalize report ----------------
BODY+="$BODY"   # ensure appended health summary (we've been adding to BODY)
BODY+="--- Summary ---\n"
if [ ${#health_messages[@]} -eq 0 ]; then
  BODY+="No issues detected.\n"
else
  BODY+="Issues detected:\n"
  for msg in "${health_messages[@]}"; do
    BODY+="- $msg\n"
  done
fi

BODY+="\n(Report generated by disk_health_storage_report.sh)\n"

# -------------- Send Notification (single nightly email) --------------
SUBJ="$SUBJECT"
if printf "%s\n" "${health_messages[@]}" | grep -qi "CRITICAL"; then
  SUBJ="❌ $SUBJECT - CRITICAL"
elif [ ${#health_messages[@]} -gt 0 ]; then
  SUBJ="⚠️ $SUBJECT - WARNINGS"
fi

if [ -x "$NOTIFY" ]; then
  "$NOTIFY" -e "Unraid Storage & Health Report" -s "$SUBJ" -d "$BODY" -i "info"
else
  # fallback to stdout and mail if available
  echo -e "$BODY"
  if command -v mail >/dev/null 2>&1; then
    printf "%s\n" "$BODY" | mail -s "$SUBJ" you@domain.tld
  fi
fi

# release lock
flock -u 9
exit 0