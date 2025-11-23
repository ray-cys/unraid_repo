#!/bin/bash
set -euo pipefail
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

# Get most recent syslog file (handle multi-digit + compressed rotations gracefully)
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
# Words that would cause a notification
ERROR_WORDS="corrupt|error|fail|tainted"
# Store line number of last found error in this file
LAST_ERROR_LINE_FILE="/tmp/syslog-notify-last-error-line-number.log"
# Ignore these phrases (no more than 4 wildcards per line)
IGNORE_LINES=(
  'kernel: CIFS: VFS: \\*\* error -9 on ioctl to get interface list'        # Unsolvable message from UD plugin
  'sshd[*]: Read error from remote host * port *: Connection reset by peer' # Interrupted ssh connection
  'sshd[*]: Read error from remote host * port *: Connection timed out'     # Interrupted ssh connection
)

################################################################################

# Make script race condition safe
if [[ -d "/tmp/${0//\//_}" ]] || ! mkdir "/tmp/${0//\//_}"; then 
  echo "Script is already running!" && 
  exit 1; 
fi; trap 'rmdir "/tmp/${0//\//_}"' EXIT;

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

# Parse logs
EOL=$'\n'
errors=""
while read -r line; do
  skip_line=0
  for ignore_line in "${IGNORE_LINES[@]}"; do
    IFS=\* read -r one two three four <<< "$ignore_line"
    if [[ $line == *"$one"*"$two"*"$three"*"$four" ]]; then
      skip_line=1
      break
    fi
  done
  if [ $skip_line -eq 1 ]; then
    continue
  fi
  last_line="$line"
  errors="$errors$EOL$line"
done < <(tail -n +"$((line_number_start+1))" "$SYSLOG_FILE" | grep -Ei "($ERROR_WORDS)")

# Create notification for new errors
if [[ $errors ]]; then
  line_number_start=$(grep -nFx "$last_line" "$SYSLOG_FILE" | cut -f 1 -d ":")
  echo "$line_number_start" > "$LAST_ERROR_LINE_FILE"
  /usr/local/emhttp/webGui/scripts/notify -i "alert" -s "Syslog $(echo "$errors" \
  | grep -Eio "($ERROR_WORDS)" | tr '[:upper:]' '[:lower:]' | sort -u | xargs)" -d "${errors:1}"
  exit
else
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