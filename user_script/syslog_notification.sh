#!/bin/bash
LOCKFILE="/tmp/syslog_notification.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another syslog_notification.sh run is active, exiting (lock: $LOCKFILE)"
  exit 1
fi
################################################################################
# ---------------- Configuration ----------------
# Syslog Notification Script
# Monitors syslog for specific error keywords and sends notifications for new errors.
################################################################################

# == Error keywords (extended regex OR list) ===
ERROR_WORDS="corrupt|error|fail|tainted"
# Persistent state files
STATE_DIR="/tmp/syslog_notify_state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
LAST_ERROR_LINE_FILE="$STATE_DIR/last_line"
LAST_NOTIFY_HASH_FILE="$STATE_DIR/last_hash"
LAST_NOTIFY_TS_FILE="$STATE_DIR/last_ts"
MIN_NOTIFY_INTERVAL=60   # seconds between identical grouped notifications

# == Regex patterns to ignore. Use anchored flexible patterns. ===
IGNORE_REGEX=(
  '^.*kernel:[[:space:]]+CIFS:[[:space:]]+VFS:[[:space:]].*error[[:space:]]+-9[[:space:]]+on[[:space:]]+ioctl[[:space:]]+to[[:space:]]+get[[:space:]]+interface[[:space:]]+list.*$'
  '^.*sshd[^:]*:[[:space:]]+Read[[:space:]]+error[[:space:]]+from[[:space:]]+remote[[:space:]]+host[[:space:]].*[[:space:]]+port[[:space:]].*:[[:space:]].*$'
  '^.*nginx[^:]*:.*ace/mode-log\.js"?[[:space:]]+failed[[:space:]].*[[:space:]]+while[[:space:]]+sending[[:space:]]+to[[:space:]]+client.*$'
  '^.*smbd[^:]*:[[:space:]]+sys_path_to_bdev\(\)[[:space:]]+failed[[:space:]]+for[[:space:]]+path[[:space:]]+\[.*\]!.*$'
)

################################################################################

# Get recent syslog (handle multi-digit + compressed rotations)
latest=""
for f in /var/log/syslog*; do
  [[ -f "$f" ]] || continue
  if [[ "$f" =~ ^/var/log/syslog(\.[0-9]+(\.gz)?)?$ ]]; then
    if [[ -z "$latest" || "$f" -nt "$latest" ]]; then
      latest="$f"
    fi
  fi
done
SYSLOG_FILE="$latest"
if [[ -z "${SYSLOG_FILE:-}" || ! -f "$SYSLOG_FILE" ]]; then
  SYSLOG_FILE="/var/log/syslog"
fi
if [[ ! -r "$SYSLOG_FILE" ]]; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Syslog file '$SYSLOG_FILE' not readable, exiting." >&2
  exit 1
fi

# Obtain line number of last check
if [[ -f "$LAST_ERROR_LINE_FILE" ]]; then
  line_number_start=$(cat "$LAST_ERROR_LINE_FILE")
  if [[ $line_number_start -gt $(grep -c ^ "$SYSLOG_FILE") ]]; then
    line_number_start=0
  fi
# Store last line number on first execution
else
  line_number_start=$(grep -c ^ "$SYSLOG_FILE")
  line_number_start=$((line_number_start-100))
  if (( line_number_start < 0 )); then line_number_start=0; fi
  echo "$line_number_start" > "$LAST_ERROR_LINE_FILE"
fi

# Parse new lines since last checkpoint
new_chunk=$(tail -n +"$((line_number_start+1))" "$SYSLOG_FILE")
candidate_lines=$(printf '%s\n' "$new_chunk" | grep -Ei "($ERROR_WORDS)" || true)
errors=""
last_line=""
if [ -n "$candidate_lines" ]; then
  while IFS= read -r line; do
    skip_line=0
    for rx in "${IGNORE_REGEX[@]}"; do
      if printf '%s\n' "$line" | grep -Eq "$rx"; then
        skip_line=1; break
      fi
    done
    [ $skip_line -eq 1 ] && continue
    errors+="$line"$'\n'
    last_line="$line"
  done <<< "$candidate_lines"
fi

if [ -n "$errors" ]; then
  # Remove trailing newline
  errors=${errors%$'\n'}
  # Group keywords for subject line
  kw_summary=$(printf '%s' "$errors" | grep -Eio "($ERROR_WORDS)" | tr '[:upper:]' '[:lower:]' | sort -u | xargs || true)
  # Hash content to suppress duplicates in short interval
  cur_hash=$(printf '%s' "$errors" | md5sum | awk '{print $1}')
  prev_hash=""; prev_ts=0; now_ts=$(date +%s)
  [ -f "$LAST_NOTIFY_HASH_FILE" ] && prev_hash=$(cat "$LAST_NOTIFY_HASH_FILE" 2>/dev/null || echo "")
  [ -f "$LAST_NOTIFY_TS_FILE" ] && prev_ts=$(cat "$LAST_NOTIFY_TS_FILE" 2>/dev/null || echo 0)
  allow_notify=1
  if [ -n "$prev_hash" ] && [ "$prev_hash" = "$cur_hash" ]; then
    if [ $(( now_ts - prev_ts )) -lt ${MIN_NOTIFY_INTERVAL:-60} ]; then
      allow_notify=0
    fi
  fi
  if [ "$allow_notify" -eq 1 ]; then
    echo "$cur_hash" > "$LAST_NOTIFY_HASH_FILE"
    echo "$now_ts" > "$LAST_NOTIFY_TS_FILE"
    # Update line pointer to last matched line number
    if [ -n "$last_line" ]; then
      line_number_start=$(grep -nF "${last_line}" "$SYSLOG_FILE" | tail -n1 | cut -d: -f1 || echo 0)
      echo "$line_number_start" > "$LAST_ERROR_LINE_FILE"
    fi
    /usr/local/emhttp/webGui/scripts/notify -i "alert" -s "Syslog ${kw_summary}" -d "$errors"
    exit 0
  else
    # Still advance pointer even if notification suppressed
    line_number_start=$(grep -c ^ "$SYSLOG_FILE")
    echo "$line_number_start" > "$LAST_ERROR_LINE_FILE"
    exit 0
  fi
else
  # No (non-ignored) errors; advance pointer
  line_number_start=$(grep -c ^ "$SYSLOG_FILE")
  echo "$line_number_start" > "$LAST_ERROR_LINE_FILE"
fi

# Create notificaton if log exceeds usage of 90%
log_size=$(df /var/log | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
if [[ ! -f /tmp/syslog-notify.size ]] && [[ $log_size -gt 90 ]]; then
  touch /tmp/syslog-notify.size
  /usr/local/emhttp/webGui/scripts/notify -i "alert" \
  -s "Syslog utilizes more than 90%!" -d "$(du -h /var/log/* | sort -h | tail)"
elif [[ -f /tmp/syslog-notify.size ]]; then
  rm /tmp/syslog-notify.size
fi