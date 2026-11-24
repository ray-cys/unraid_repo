#!/usr/bin/env bash
# Isolated grouped delivery, bounded logs and orchestration. No live API/actions.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/media_cleanup.sh"
fixture=$(mktemp -d /tmp/media-cleanup-delivery.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
MC_ROOT="$fixture/state"; mkdir -p "$MC_ROOT"
MC_LOCK="$fixture/run.lock"; MC_NOTIFY_LOCK="$fixture/notify.lock"; MC_LOG_LOCK="$fixture/log.lock"
MC_STATUS_DIR="$fixture/status"
STATE_EXPORT_LOCK="$fixture/export.lock"
MC_MAIL_MAX_BYTES=5000; MC_LOG_MAX_BYTES=4096
MC_RUN_ID=fixture; MC_OUTCOMES='arr=COMPLETED; sab=COMPLETED; quarantine=COMPLETED'
mc_state_ready() { return 0; }
MC_NOTIFY_BIN="$fixture/notify"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>%q\n' "$fixture/mail" >"$MC_NOTIFY_BIN"
chmod +x "$MC_NOTIFY_BIN"
mc_collect arr -i warning -s Arr -d 'Actions' -m 'Quarantined named poster.jpg and removed the empty directory'
mc_collect arr -i warning -s Arr -d 'Actions' -m 'Quarantined named poster.jpg and removed the empty directory'
jq -e '.events|length==1' "$MC_ROOT/notification-outbox.json" >/dev/null
mc_collect sab -i normal -s SAB -d 'Actions' -m 'Purged expired completed payload Example Movie; receipt retained'
mc_flush
[[ $(wc -l <"$fixture/mail") -ge 1 ]]
grep -q 'poster.jpg' "$fixture/mail"; grep -q 'Example Movie' "$fixture/mail"
jq -e '.events|length==0' "$MC_ROOT/notification-outbox.json" >/dev/null
mc_collect quarantine -i normal -s Bin -m 'Purged 4 old NFO files'
cp "$fixture/mail" "$fixture/before"
mc_flush
cmp "$fixture/mail" "$fixture/before"
jq -e '.events|length==1' "$MC_ROOT/notification-outbox.json" >/dev/null
# A failed command acknowledges neither the queue nor the delivery date.
jq '.lastSentDate=""' "$MC_ROOT/notification-outbox.json" >"$fixture/next"; mv "$fixture/next" "$MC_ROOT/notification-outbox.json"
printf '#!/bin/bash\nexit 1\n' >"$MC_NOTIFY_BIN"
if mc_flush; then echo 'Failed delivery accepted' >&2; exit 1; fi
jq -e '.lastSentDate=="" and (.events|length)==1' "$MC_ROOT/notification-outbox.json" >/dev/null
# Oversized UTF-8 + another report progress without losing either remainder.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>%q\n' "$fixture/mail" >"$MC_NOTIFY_BIN"
large=$(jq -nr '[range(0;6000)|"漢"]|join("")')
mc_collect arr -i alert -s 'Large report' -m "$large"
mc_flush
jq -e '.events|length==2' "$MC_ROOT/notification-outbox.json" >/dev/null
remaining=$(jq -r '.events[]|select(.module=="arr")|.message|utf8bytelength' "$MC_ROOT/notification-outbox.json")
(( remaining>0 && remaining<18000 ))
for ((n=0;n<10;n++)); do
 jq '.lastSentDate=""' "$MC_ROOT/notification-outbox.json" >"$fixture/next"; mv "$fixture/next" "$MC_ROOT/notification-outbox.json"
 mc_flush
 done
jq -e '.events|length==0' "$MC_ROOT/notification-outbox.json" >/dev/null
# One common bounded log; stale and excess generations are removed.
for ((n=0;n<150;n++)); do mc_write_line "INFO fixture $n $(printf '%300s' x)"; done
for file in "$MC_ROOT/media-cleanup.log"*; do (( $(stat -c %s "$file")<=MC_LOG_MAX_BYTES )); done
[[ ! -e "$MC_ROOT/media-cleanup.log.3" ]]
# Module failures retain their exit and do not prevent independent safe modules.
MC_TMP="$fixture/work";mkdir "$MC_TMP";printf '[]' >"$MC_TMP/outcomes.json"
MC_RESULT=OK;MC_OUTCOMES=''
mc_arr() { printf 'API unreachable; no payload mutated\n'; return 2; }
mc_sab() { printf 'Completed independent SAB inspection\n'; }
mc_quarantine() { printf 'Operational-state export active; lifecycle deferred without changes.\n'; }
MC_MODULE=arr;mc_run_module arr
MC_MODULE=sab;mc_run_module sab
MC_MODULE=quarantine;mc_run_module quarantine
jq -e '.[0].status=="FAILED" and .[0].exit==2 and .[1].status=="COMPLETED" and .[2].status=="DEFERRED"' "$MC_TMP/outcomes.json" >/dev/null
[[ "$MC_RESULT" == ATTENTION ]]
# Native structured deferral is honored even without a matching console line.
mc_quarantine() { RESULT_STATUS=DEFERRED;RESULT_SUMMARY='Export lease busy';mc_finish_module quarantine 0; }
MC_RESULT=OK;MC_MODULE=quarantine;mc_run_module quarantine
jq -e '.[-1].status=="DEFERRED"' "$MC_TMP/outcomes.json" >/dev/null
MC_MODE=arr;MC_STARTED=$(date +%s)
mc_record_status
[[ ! -e "$MC_STATUS_DIR/media_cleanup.json" ]]
MC_MODE=all;mc_record_status
jq -e '.mode=="all"' "$MC_STATUS_DIR/media_cleanup.json" >/dev/null
printf 'Durable single daily delivery, UTF-8 overflow, failed-send retention, log bounds, independent outcomes passed\n'
