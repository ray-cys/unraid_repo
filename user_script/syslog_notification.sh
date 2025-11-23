#!/bin/bash
set -euo pipefail
LOCKFILE="/tmp/syslog_notification.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another syslog_notification.sh run is active, exiting (lock: $LOCKFILE)"
  exit 1
fi

# shellcheck disable=SC2034
clearLog=true

# --------------------------------------------------------------------------------
# Configuration

# Get most recent syslog file (handle multi-digit + compressed rotations gracefully) without ls|grep
latest=""
for f in /var/log/syslog*; do
  [[ -f "$f" ]] || continue
  if [[ "$f" =~ ^/var/log/syslog(\.[0-9]+(\.gz)?)?$ ]]; then
    if [[ -z "$latest" || "$f" -nt "$latest" ]]; then
      latest="$f"
    fi
  fi
done
syslog_file="$latest"
if [[ -z "${syslog_file:-}" || ! -f "$syslog_file" ]]; then
  syslog_file="/var/log/syslog"
fi
if [[ ! -r "$syslog_file" ]]; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Syslog file '$syslog_file' not readable, exiting." >&2
  exit 1
fi
# Words that would cause a notification
words="corrupt|error|fail|tainted"
# Store line number of last found error in this file
log_file="/tmp/syslog-notify-last-error-line-number.log"
# Ignore these phrases (you can't use more than 4 wildcards per line!)
ignore_lines=(
  'kernel: CIFS: VFS: \\*\* error -9 on ioctl to get interface list' # Unsolvable message from UD plugin
  'sshd[*]: Read error from remote host * port *: Connection reset by peer' # Interrupted ssh connection
  'sshd[*]: Read error from remote host * port *: Connection timed out' # Interrupted ssh connection
)

# --------------------------------------------------------------------------------

# Make script race condition safe
if [[ -d "/tmp/${0//\//_}" ]] || ! mkdir "/tmp/${0//\//_}"; then 
  echo "Script is already running!" && 
  exit 1; 
fi; trap 'rmdir "/tmp/${0//\//_}"' EXIT;

# Obtain line number of last check
if [[ -f "$log_file" ]]; then
  line_number_start=$(cat "$log_file")
  if [[ $line_number_start -gt $(grep -c ^ "$syslog_file") ]]; then
    line_number_start=0
  fi
# Store last line number on first execution
else
  line_number_start=$(grep -c ^ "$syslog_file")
  line_number_start=$((line_number_start-100))
  if (( line_number_start < 0 )); then line_number_start=0; fi
  echo "$line_number_start" > "$log_file"
fi

# Parse logs
EOL=$'\n'
errors=""
while read -r line; do
  skip_line=0
  for ignore_line in "${ignore_lines[@]}"; do
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
done < <(tail -n +"$((line_number_start+1))" "$syslog_file" | grep -Ei "($words)")

# Create notification for new errors
if [[ $errors ]]; then
  line_number_start=$(grep -nFx "$last_line" "$syslog_file" | cut -f 1 -d ":")
  echo "$line_number_start" > "$log_file"
  /usr/local/emhttp/webGui/scripts/notify -i "alert" -s "Syslog $(echo "$errors" \
  | grep -Eio "($words)" | tr '[:upper:]' '[:lower:]' | sort -u | xargs)" -d "${errors:1}"
  exit
else
  line_number_start=$(grep -c ^ "$syslog_file")
  echo "$line_number_start" > "$log_file"
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