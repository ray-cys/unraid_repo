#!/usr/bin/env bash
# Temporary-only notification lifecycle tests; no email, ISS or media actions.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/notification-noise.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
export fixture repo
bash <<'VAULT'
set -euo pipefail
source "$repo/user_script/backup_vault_remote.sh"
LOG_DIR="$fixture/vault";mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/log";ISS_REQUEST_FILE="$fixture/request.json"
NOTIFY_BIN="$fixture/notifier"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"$fixture/mail"\nprintf "accepted\\n" >>"$fixture/mail-count"\n' >"$NOTIFY_BIN";chmod +x "$NOTIFY_BIN"
export fixture
ISS_REQUEST_ID=gen-A;VAULT_NOTIFICATION_REASON=capacity
notify_unraid alert 'Backup failed' failed
notify_unraid alert 'Backup failed' failed
[[ "$NOTIFICATION_RESULT" == suppressed && $(wc -l <"$fixture/mail-count") == 1 ]]
# Repeated invocations share the same state, not shell globals.
(bash -c 'source "$repo/user_script/backup_vault_remote.sh";LOG_DIR="$fixture/vault";LOG_FILE="$LOG_DIR/log";NOTIFY_BIN="$fixture/notifier";ISS_REQUEST_ID=gen-A;VAULT_NOTIFICATION_REASON=capacity;notify_unraid alert "Backup failed" failed;[[ "$NOTIFICATION_RESULT" == suppressed ]]')
# The daily reminder is allowed without changing its incident identity.
jq '.activeFailure.lastSentAt-=86401' "$VAULT_NOTIFICATION_STATE" >"$fixture/old";mv "$fixture/old" "$VAULT_NOTIFICATION_STATE"
notify_unraid alert 'Backup failed' failed
[[ $(wc -l <"$fixture/mail-count") == 2 ]]
VAULT_NOTIFICATION_REASON=ssh-auth
notify_unraid alert 'Backup failed' failed
[[ $(wc -l <"$fixture/mail-count") == 3 ]]
ISS_REQUEST_ID=gen-B
notify_unraid alert 'Backup failed' failed
[[ $(wc -l <"$fixture/mail-count") == 4 ]]
notify_unraid normal 'Backup completed' verified
jq -e '.activeFailure==null' "$VAULT_NOTIFICATION_STATE" >/dev/null
grep -q 'Recovery: previously reported Backup failed is cleared' "$fixture/mail"
# Failed sends must not consume the first report for a new failure.
ISS_REQUEST_ID=gen-C
printf '#!/bin/bash\nexit 1\n' >"$NOTIFY_BIN"
notify_unraid alert 'Backup failed' failed
[[ "$NOTIFICATION_RESULT" == failed ]]
jq -e '.activeFailure==null' "$VAULT_NOTIFICATION_STATE" >/dev/null
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"$fixture/mail"\nprintf "accepted\\n" >>"$fixture/mail-count"\n' >"$NOTIFY_BIN"
notify_unraid alert 'Backup failed' failed
jq -e '.activeFailure.requestId=="gen-C"' "$VAULT_NOTIFICATION_STATE" >/dev/null
VAULT
bash <<'ARR'
set -euo pipefail
source <(awk '/^# LOCK$/{exit}{print}' "$repo/user_script/media_health_monitor.sh")
trap - EXIT INT TERM HUP
[[ "$ERROR_REMINDER_INTERVAL_HOURS" == 24 && "$REMINDER_MAX_COUNT" == 3 ]]
STATE_FILE="$fixture/arr-state";TMP_DIR="$fixture";NOTIFICATIONS_SUPPRESSED=0
now=$(date +%s)
jq -n --argjson time "$((now-86401))" '{issues:{example:{classification:"ARR_NATIVE_HEALTH",severity:"ERROR",notifiedSignature:"same",lastNotifiedAt:$time,reminderCount:2}}}' >"$STATE_FILE"
should_notify example same ERROR
[[ "$NOTIFICATION_DECISION_EVENT" == reminder ]]
jq '.issues.example.reminderCount=3' "$STATE_FILE" >"$fixture/next";mv "$fixture/next" "$STATE_FILE"
if should_notify example same ERROR;then exit 1;fi
should_notify example escalated ERROR
[[ "$NOTIFICATION_DECISION_EVENT" == new ]]
ARR
# Extract module definitions without invoking native operations.
python3 - <<'PY'
from pathlib import Path
import os
s=Path(os.environ['repo']+'/user_script/media_cleanup.sh').read_text()
a=s.index('mc_sab() (\n')+len('mc_sab() (\n');b=s.index('\nmain "$@"\n',a)
Path(os.environ['fixture']+'/sab.sh').write_text(s[:s.index('\n# MODULE: ARR')]+'\n'+s[a:b])
PY
bash <<'SAB'
set -euo pipefail
source "$fixture/sab.sh"
SEND_NOTIFICATIONS=true;DRY_RUN=false;TMP_DIR="$fixture";OPS_ATTENTION_DETAILS='';OPS_ATTENTION_FILE=''
OPS_NOTIFICATION_STATE="$fixture/sab-state";printf '{"outbox":[]}' >"$OPS_NOTIFICATION_STATE"
OPS_NOTIFICATION_DELIVERED=false
ops_set_topic(){ :; };ops_notify(){ printf '%s\n' "$*" >>"$fixture/sab-mail"; }
BACKUP_CLEANUP_STATUS=COMPLETED;STRANDED_CLEANUP_STATUS=COMPLETED;QUARANTINE_PURGE_STATUS=COMPLETED
NZB_BACKUPS_REMOVED=10;APP_BACKUPS_REMOVED=1;NZB_BACKUP_BYTES=100;APP_BACKUP_BYTES=200;ERRORS=0
BACKUP_DETAILS=('Removed nzb backup: exact-file.nzb');notify_summary
[[ ! -e "$fixture/sab-mail" ]]
QUARANTINED=1;QUARANTINE_DETAILS=('Moved exact media payload');notify_summary
grep -q 'removed 10 NZB backup(s), 1 application backup(s)' "$fixture/sab-mail"
if grep -q 'exact-file.nzb' "$fixture/sab-mail";then exit 1;fi
grep -q 'Moved exact media payload' "$fixture/sab-mail"
QUARANTINED=0;OPS_ATTENTION_DETAILS='Preserved unsafe directory';notify_summary
grep -q 'Preserved unsafe directory' "$fixture/sab-mail"
SAB
printf 'Daily/bounded Arr reminders, durable ISS cooldown/recovery/send retry and routine-only cleanup suppression passed\n'
