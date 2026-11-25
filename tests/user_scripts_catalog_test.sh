#!/bin/bash
# Native schedule metadata fixtures only; no live scripts or real schedulers.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d);trap '[[ -z "${runner:-}" ]] || kill "$runner" 2>/dev/null || true; rm -rf "$fixture"' EXIT
source "$repo/tools/user_scripts_catalog.sh"
export USER_SCRIPTS_REGISTRY_FILE="$fixture/registry.json" USER_SCRIPTS_REGISTRY_LOCK="$fixture/registry.lock" USER_SCRIPTS_RUNTIME_SCHEDULE="$fixture/runtime.json" USER_SCRIPTS_CUSTOM_CRON="$fixture/customSchedule.cron" USER_SCRIPTS_SCHEDULE_ROLLBACK="$fixture/previous.json" STATE_EXPORT_LOCK="$fixture/export.lock" USER_SCRIPTS_RUNNING_ROOT="$fixture/running"
mkdir -p "$fixture/scripts/live" "$fixture/scripts/disabled" "$fixture/running"
printf '#!/bin/bash\nOPS_SCRIPT_ID="media_metadata_audit"\n' >"$fixture/scripts/live/script"
printf '#!/bin/bash\n' >"$fixture/scripts/disabled/script"
printf '{"/boot/config/plugins/user.scripts/scripts/live/script":{"script":"/boot/config/plugins/user.scripts/scripts/live/script","frequency":"custom","custom":"55 3 * * MON","future":{"empty":{},"items":[]}},"/boot/config/plugins/user.scripts/scripts/disabled/script":{"frequency":"disabled"},"/boot/config/plugins/user.scripts/scripts/orphan/script":{"frequency":"custom","custom":"0 2 * * *"}}' >"$fixture/schedule.json"
cp "$fixture/schedule.json" "$USER_SCRIPTS_RUNTIME_SCHEDULE"
printf '# Generated cron schedule for user.scripts\n55 3 * * MON /usr/local/emhttp/plugins/user.scripts/startCustom.php /boot/config/plugins/user.scripts/scripts/live/script > /dev/null 2>&1\n0 2 * * * /usr/local/emhttp/plugins/user.scripts/startCustom.php /boot/config/plugins/user.scripts/scripts/orphan/script > /dev/null 2>&1\n\n' >"$USER_SCRIPTS_CUSTOM_CRON"
usr_scripts_catalog "$fixture/schedule.json" "$fixture/scripts" >"$fixture/catalog"
jq -e '.valid and .jobs["/boot/config/plugins/user.scripts/scripts/live/script"].role=="media_metadata_audit" and .jobs["/boot/config/plugins/user.scripts/scripts/live/script"].cron=="55 3 * * 1" and (.jobs["/boot/config/plugins/user.scripts/scripts/disabled/script"].enabled|not)' "$fixture/catalog" >/dev/null
mountpoint(){ return 0; }
usr_scripts_reconcile "$fixture/schedule.json" "$fixture/scripts" fixture 1000 >"$fixture/first"
jq -e '.changed==false' "$fixture/first" >/dev/null
usr_scripts_reconcile "$fixture/schedule.json" "$fixture/scripts" fixture 1061 >"$fixture/second"
jq -e '.changed and .events[0].removed==["orphan"]' "$fixture/second" >/dev/null
jq -e 'has("/boot/config/plugins/user.scripts/scripts/orphan/script")|not' "$fixture/schedule.json" >/dev/null
jq -e '.["/boot/config/plugins/user.scripts/scripts/live/script"].future.empty=={} and .["/boot/config/plugins/user.scripts/scripts/live/script"].future.items==[] and has("/boot/config/plugins/user.scripts/scripts/disabled/script")' "$fixture/schedule.json" >/dev/null
cmp "$fixture/schedule.json" "$USER_SCRIPTS_RUNTIME_SCHEDULE"
if grep -q orphan "$USER_SCRIPTS_CUSTOM_CRON";then exit 1;fi
jq -e '.persistent|length>0' "$USER_SCRIPTS_SCHEDULE_ROLLBACK" >/dev/null
printf 'Confirmed orphan removed from both native JSON copies and cron; disabled scripts and unknown fields preserved\n'
# Removing a script that is still running must retain its reference until exit.
jq '.["/boot/config/plugins/user.scripts/scripts/busy/script"]={frequency:"custom",custom:"0 2 * * *"}' "$fixture/schedule.json" >"$fixture/next";mv "$fixture/next" "$fixture/schedule.json"
cp "$fixture/schedule.json" "$USER_SCRIPTS_RUNTIME_SCHEDULE"
bash -c 'while :; do sleep 1; done' /usr/local/emhttp/plugins/user.scripts/startBackground.php /tmp/user.scripts/tmpScripts/busy/script & runner=$!
printf '%s' "$runner" >"$USER_SCRIPTS_RUNNING_ROOT/busy"
exec 9>"$fixture/operation.lock";flock -x 9
usr_scripts_reconcile "$fixture/schedule.json" "$fixture/scripts" fixture 1200 >/dev/null
usr_scripts_reconcile "$fixture/schedule.json" "$fixture/scripts" fixture 1261 >/dev/null
jq -e 'has("/boot/config/plugins/user.scripts/scripts/busy/script")' "$fixture/schedule.json" >/dev/null
kill "$runner";wait "$runner" 2>/dev/null || true;runner=''
usr_scripts_reconcile "$fixture/schedule.json" "$fixture/scripts" fixture 1322 >/dev/null
usr_scripts_reconcile "$fixture/schedule.json" "$fixture/scripts" fixture 1383 >/dev/null
jq -e 'has("/boot/config/plugins/user.scripts/scripts/busy/script")|not' "$fixture/schedule.json" >/dev/null
if flock -s -n "$fixture/operation.lock" -c true;then echo 'Held operation lock was bypassed';exit 1;fi
exec 9>&-
printf 'Real running PID defers retirement; existing held lock remains protected\n'
# A removed job is retired even when native UI already cleaned its schedule.
rm "$fixture/scripts/live/script"
jq 'del(.["/boot/config/plugins/user.scripts/scripts/live/script"])' "$fixture/schedule.json" >"$fixture/next";mv "$fixture/next" "$fixture/schedule.json"
cp "$fixture/schedule.json" "$USER_SCRIPTS_RUNTIME_SCHEDULE"
usr_scripts_reconcile "$fixture/schedule.json" "$fixture/scripts" fixture 1400 >/dev/null
usr_scripts_reconcile "$fixture/schedule.json" "$fixture/scripts" fixture 1461 >"$fixture/retired"
jq -e 'any(.events[];.removed|index("live")!=null)' "$fixture/retired" >/dev/null
# Malformed source is never replaced by a guessed empty schedule.
printf 'invalid json' >"$fixture/schedule.json"
cp "$USER_SCRIPTS_RUNTIME_SCHEDULE" "$fixture/runtime.before"
if usr_scripts_reconcile "$fixture/schedule.json" "$fixture/scripts" fixture 1600 >"$fixture/invalid";then exit 1;fi
cmp "$USER_SCRIPTS_RUNTIME_SCHEDULE" "$fixture/runtime.before"
[[ $(cat "$fixture/schedule.json") == 'invalid json' ]]
printf 'Already-clean UI removals are retired; invalid persistent metadata is preserved\n'
# Native periodic frequencies use the actual system dispatcher, and renamed
# backup scripts keep their logical role without editing consumer scripts.
mkdir -p "$fixture/scripts/renamed_backup"
printf '#!/bin/bash\nOPS_SCRIPT_ID="backup_cache_appdata"\n' >"$fixture/scripts/renamed_backup/script"
printf '{"alias":{"script":"/boot/config/plugins/user.scripts/scripts/renamed_backup/script","frequency":"daily"}}' >"$fixture/schedule.json"
timeout(){ case "$*" in *'crontab -c'*) return 0;;*'crontab -l'*) printf '40 4 * * * /usr/bin/run-parts /etc/cron.daily > /dev/null\n';;*) command timeout "$@";;esac; }
usr_scripts_catalog "$fixture/schedule.json" "$fixture/scripts" >"$fixture/native"
jq -e '.jobs["/boot/config/plugins/user.scripts/scripts/renamed_backup/script"].cron=="40 4 * * *"' "$fixture/native" >/dev/null
now=$(TZ=Asia/Singapore date -d '2026-11-26 13:00:00' +%s)
expected=$(TZ=Asia/Singapore date -d '2026-11-25 04:40:00' +%s)
[[ $(usr_scripts_due_window "$fixture/native" backup_cache_appdata "$now" 0 | jq -r .cutoff) == "$expected" ]]
rm "$fixture/scripts/renamed_backup/script"
usr_scripts_catalog "$fixture/schedule.json" "$fixture/scripts" >"$fixture/native"
if usr_scripts_due_window "$fixture/native" backup_cache_appdata "$now" 0 >/dev/null;then echo 'Missing required backup bypassed';exit 1;fi
printf 'Native daily timing and renamed backup role discovered; removed backup protection cannot be bypassed\n'
ids=$(jq -c '[.events[].id]' "$USER_SCRIPTS_REGISTRY_FILE")
usr_scripts_registry_ack "$ids" true
jq -e '(.events|length)==0 and .cronReloadPending==false' "$USER_SCRIPTS_REGISTRY_FILE" >/dev/null
printf 'Durably queued reconciliation events acknowledge without repeated notifications\n'
