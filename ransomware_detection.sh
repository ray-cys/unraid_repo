#!/bin/bash
#
# ransom_watch.sh - Behavioral ransomware detector for unRAID (Policy 2 = Auto-Lockdown)
# Run at startup via User Scripts (set to "Run at Startup") and keep running (nohup recommended).
#
# Policy 2 behaviour:
#  - Detect suspicious rename/delete spikes and extension-mutation patterns.
#  - On CONFIRMED encryption pattern, perform auto-lockdown:
#       1) Attempt to disconnect SMB clients (smbcontrol / smbstatus)
#       2) Stop Samba service (best-effort if unRAID provides /etc/rc.d/rc.samba)
#       3) Attempt to remount /mnt/user read-only (best-effort)
#       4) Create /var/run/ransom_watch.lockdown marker and detailed log snapshot in /var/log
#  - All actions logged to /var/log/ransom_watch.log and reported via Unraid notify.
#
# Requirements: inotifywait (inotify-tools), smbstatus/smbcontrol optional, Unraid notify helper
#
LOG="/var/log/ransom_watch.log"
EVENT_LOG_DIR="/var/log/ransom_events"
NOTIFY="/usr/local/emhttp/webGui/scripts/notify"
INOTIFY=$(command -v inotifywait || true)
WATCH_PATHS=(/mnt/user)        # default: monitor user shares only (recommended)
EXCLUDE_PATHS=("/mnt/user/appdata" "/mnt/user/system" "/mnt/user/isos")  # exclude noisy paths
EVENT_WINDOW=30               # seconds to collect events for analysis
EVENT_THRESHOLD=250           # events in window considered suspicious (tune)
RENAME_RATIO=0.35             # fraction of rename events among total that suggests encryption
EXTENSION_PATTERNS=("*.locked" "*.encrypted" "*.crypt" "*.crypt1" "*.crypto" "*.lockedfile") # detect mutated extensions
QUARANTINE=false              # do NOT move files automatically by default
SMB_LOGIC=true                # attempt to use smbstatus / smbcontrol
LOCKDOWN_MARKER="/var/run/ransom_watch.lockdown"  # exists when auto-lockdown was activated
ALERT_LEVEL_CRITICAL="critical"
ALERT_LEVEL_WARN="normal"
WHITELIST_PROCESS_PATTERNS=("mover" "rsync" "docker" "duplicati" "rclone" "crond")

timestamp(){ date '+%F %T'; }
log(){ echo "$(timestamp) $*" >> "$LOG"; }

send_notify(){
  local title="$1"; local message="$2"; local level="${3:-normal}"
  if [ -x "$NOTIFY" ]; then
    "$NOTIFY" -e "Ransom Watch" -s "$title" -d "$message" -i "$level"
  else
    log "NOTIFY MISSING: $title - $message"
  fi
}

if [ -z "$INOTIFY" ]; then
  send_notify "Ransom Watch disabled" "inotifywait not found. Install inotify-tools via Community Applications." "critical"
  exit 1
fi

mkdir -p "$EVENT_LOG_DIR"

# utility: is path excluded?
is_excluded(){
  local p="$1"
  for e in "${EXCLUDE_PATHS[@]}"; do
    if [[ "$p" == "$e"* ]]; then return 0; fi
  done
  return 1
}

# identify top SMB client if possible
identify_top_smb_client(){
  if ! command -v smbstatus >/dev/null 2>&1; then
    echo ""
    return
  fi
  # try to find clients with most open files / connections
  smbstatus -S 2>/dev/null | awk 'NR>1{print $1,$5}' | sort | uniq -c | sort -rn | head -n3
}

# attempt to disconnect all smb clients (best-effort)
disconnect_smb_clients(){
  if command -v smbcontrol >/dev/null 2>&1; then
    log "Attempting smbcontrol all close-share"
    smbcontrol all close-share 2>/dev/null || true
  fi
  # fallback: try killing smbd processes (last resort) - but we prefer service stop
  if [ -x /etc/rc.d/rc.samba ]; then
    log "Stopping Samba via /etc/rc.d/rc.samba stop"
    /etc/rc.d/rc.samba stop 2>/dev/null || true
  elif command -v systemctl >/dev/null 2>&1; then
    log "Attempting systemctl stop smbd nmbd (if present)"
    systemctl stop smbd nmbd 2>/dev/null || true
  fi
}

# attempt remount /mnt/user read-only (best-effort)
remount_user_ro(){
  if mount | grep " /mnt/user " >/dev/null 2>&1; then
    # try remount read-only
    if mount -o remount,ro /mnt/user 2>/dev/null; then
      log "Remounted /mnt/user read-only"
      return 0
    else
      log "Remount /mnt/user read-only failed - attempting per-share remounts"
      # try remount each merged share mountpoint (best-effort)
      for mp in $(mount | awk '/mnt\/user/ {print $3}' | sort -u); do
        mount -o remount,ro "$mp" 2>/dev/null || log "Failed remount $mp"
      done
    fi
  else
    log "/mnt/user not found in mount table; skipping remount"
  fi
  return 1
}

# main monitor: forever loop collecting EVENT_WINDOW seconds of events
while true; do
  tmpfile="/tmp/ransom_events_$$.log"
  # Watch CREATE, MODIFY, DELETE, MOVED_FROM, MOVED_TO recursively
  # Output format: %T|%e|%w|%f  (timestamp|events|dir|filename)
  timeout $EVENT_WINDOW inotifywait -m -r -e create,modify,delete,moved_from,moved_to --format '%T|%e|%w|%f' --timefmt '%s' "${WATCH_PATHS[@]}" 1> "$tmpfile" 2>/dev/null &
  pid=$!
  sleep $EVENT_WINDOW
  kill $pid 2>/dev/null || true

  if [ ! -s "$tmpfile" ]; then
    rm -f "$tmpfile"
    sleep 1
    continue
  fi

  total=$(wc -l < "$tmpfile")
  moves=$(grep -c "MOVED_FROM\|MOVED_TO" "$tmpfile" || true)
  deletes=$(grep -c "DELETE" "$tmpfile" || true)
  creates=$(grep -c "CREATE" "$tmpfile" || true)
  modifies=$(grep -c "MODIFY" "$tmpfile" || true)
  rename_fraction=0
  if [ "$total" -gt 0 ]; then
    rename_fraction=$(awk -v m="$moves" -v t="$total" 'BEGIN{printf "%.3f", m/t}')
  fi

  # check for extension-pattern hits (strong signal)
  ext_hits=0
  for pat in "${EXTENSION_PATTERNS[@]}"; do
    count=$(awk -F'|' '{print $4}' "$tmpfile" | grep -E "$(echo "$pat" | sed 's/\*/.*/g')" | wc -l)
    ext_hits=$((ext_hits + count))
  done

  suspicious=0
  # Heuristics:
  # - many events AND rename-heavy -> suspicious
  # - OR extension mutation hits -> high confidence
  if [ "$total" -ge "$EVENT_THRESHOLD" ] && (( $(awk -v r="$rename_fraction" -v thr="$RENAME_RATIO" 'BEGIN{print (r>thr)}') )); then
    suspicious=1
    reason="High event rate + rename ratio ($moves/$total)"
  elif [ "$ext_hits" -gt 0 ]; then
    suspicious=2
    reason="Extension mutation hits ($ext_hits)"
  elif [ "$total" -ge $((EVENT_THRESHOLD * 2)) ]; then
    suspicious=1
    reason="Very high event rate ($total)"
  fi

  if [ "$suspicious" -ne 0 ]; then
    ts="$(timestamp)"
    snapshot="/var/log/ransom_events/ransom_snapshot_$(date '+%Y%m%d_%H%M%S').log"
    mv "$tmpfile" "$snapshot"
    # add smb session snapshot if possible
    if command -v smbstatus >/dev/null 2>&1; then
      smbstatus -S > "${snapshot}.smbstatus" 2>/dev/null || true
    fi

    details="Time window: ${EVENT_WINDOW}s
Total events: $total
Moves: $moves
Deletes: $deletes
Creates: $creates
Modifies: $modifies
Rename fraction: $rename_fraction
Extension hits: $ext_hits
Reason: $reason
Snapshot: $snapshot"

    log "Suspicious activity detected: $details"
    send_notify "Suspicious file activity" "$details" "$ALERT_LEVEL_CRITICAL"

    # Identify top SMB clients (best-effort) and attach to notify
    top_clients=$(identify_top_smb_client || true)
    if [ -n "$top_clients" ]; then
      send_notify "SMB client snapshot" "$top_clients" "normal"
    fi

    # AUTO-LOCKDOWN (Policy 2) - try best-effort actions
    log "AUTO-LOCKDOWN: attempting to disconnect SMB clients and stop Samba service"
    disconnect_smb_clients
    sleep 2

    # attempt to remount /mnt/user read-only
    if remount_user_ro; then
      log "Auto-lockdown: /mnt/user remounted read-only"
      send_notify "Ransom Watch - lockdown active" "Auto-lockdown engaged: /mnt/user remounted read-only. Check logs at $snapshot" "$ALERT_LEVEL_CRITICAL"
    else
      send_notify "Ransom Watch - partial lockdown" "Auto actions attempted: disconnected SMB clients and stopped Samba (best-effort). Remount read-only failed; please stop SMB manually and remount shares read-only." "$ALERT_LEVEL_CRITICAL"
    fi

    # mark lockdown file so admin knows
    echo "$ts - reason: $reason" > "$LOCKDOWN_MARKER"
    log "Lockdown marker created at $LOCKDOWN_MARKER"

    # Save a short forensic digest file
    head -n 500 "$snapshot" > "${snapshot}.digest"
    # Optionally move new files to quarantine (disabled by default)
    if [ "$QUARANTINE" = true ]; then
      qdir="/mnt/user/__quarantine_$(date '+%Y%m%d_%H%M%S')"
      mkdir -p "$qdir"
      # Move only files recorded in snapshot (best-effort)
      awk -F'|' '{print $3 $4}' "$snapshot" | while read -r p; do
        # skip directories and excluded paths
        if is_excluded "$p"; then continue; fi
        if [ -e "$p" ]; then
          mv "$p" "$qdir/" 2>/dev/null || log "Failed move $p to quarantine"
        fi
      done
      send_notify "Quarantine completed" "Moved suspicious files to $qdir (best-effort)." "normal"
    fi

    # escalate notification: critical + explicit instructions to admin
    send_notify "Ransom Watch - ACTION REQUIRED" "Auto-lockdown performed. DO NOT UNLOCK until you have investigated. To manually unlock: (1) stop smb if running; (2) remount /mnt/user rw: mount -o remount,rw /mnt/user; (3) remove $LOCKDOWN_MARKER. See /var/log/ransom_watch.log and snapshot files in /var/log/ransom_events." "$ALERT_LEVEL_CRITICAL"

    # After lockdown, sleep long to avoid repeated triggers
    sleep 60
  else
    rm -f "$tmpfile"
  fi

  # Short pause before next window
  sleep 1
done