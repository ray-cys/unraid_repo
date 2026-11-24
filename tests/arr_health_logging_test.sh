#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/arr-health-log.XXXXXX)
source <(awk '/^# LOCK$/{exit} {print}' "$repo/user_script/media_health_monitor.sh")
trap - INT TERM HUP
trap 'rm -rf -- "$fixture"' EXIT
STATE_DIR="$fixture" LOG_FILE="$fixture/media_health_monitor.log"
LOG_MAX_SIZE_MB=1 LOG_BACKUPS=2 LOG_LINE_MAX_BYTES=256 LOG_RETENTION_DAYS=30
head -c $((1024*1024-100)) /dev/zero >"$LOG_FILE"
printf -v long '%*s' 3000 ''
persistent_log WARNING "$long"
[[ -f "$LOG_FILE.1" ]]
[[ "$(stat -c '%s' "$LOG_FILE")" -le 256 ]]
grep -q 'line truncated' "$LOG_FILE"
persistent_log INFO $'first line\nsecond line'
[[ "$(wc -l <"$LOG_FILE")" == 2 ]]
printf old >"$LOG_FILE.3"
head -c $((1024*1024+10)) /dev/zero >"$LOG_FILE.2"
prune_persistent_logs_by_age
[[ ! -e "$LOG_FILE.2" && ! -e "$LOG_FILE.3" ]]
for file in "$LOG_FILE" "$LOG_FILE.1"; do [[ "$(stat -c '%s' "$file")" -le $((1024*1024)) ]]; done
printf 'Health in-run log rotation, byte caps, multiline and inherited backup tests passed\n'
