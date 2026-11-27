#!/bin/bash
# Live read-only probes, isolated RAM/cursor/delivery state. No actual mail.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/syslog-host-test.XXXXXX) || exit 1
trap 'rm -rf "$work"' EXIT
HH_RAM_ROOT=$work;HH_MIRROR="$work/mirror.json"
source "$ROOT/user_script/host_health_watchdog.sh"
log(){ :; }
# The only delivery function is intercepted before any notification can occur.
NOTIFY_BIN=/bin/true;FAIL_NOTIFY=0
usr_ops_notify(){ printf '%s\n' "$*" >> "$work/delivery";return "$FAIL_NOTIFY"; }
hh_prepare || exit 1
jq -e '.activeConditions==0 and any(.observations[];.id=="memory" and .severity=="ok") and any(.observations[];(.id|startswith("network:link:")) and .severity=="ok")' "$work/host-health-receipt.json" >/dev/null || exit 1
printf '[PASS] Native fast probes are healthy with isolated state\n'
hh_flush || exit 1
[[ ! -f "$work/delivery" ]] || exit 1
printf '[PASS] Healthy probes generate no notification\n'
HH_OBSERVATIONS='[]';hh_observe fixture critical 'Isolated failure' 'Read-only fixture; no host change.' 1
hh_lifecycle || exit 1
FAIL_NOTIFY=1
if notify_unraid warning 'Fixture syslog finding' 'Existing syslog evidence';then exit 1;fi
jq -e '.conditions.fixture.pending=="RAISED"' <<< "$HH_STATE" >/dev/null || exit 1
printf '[PASS] Failed grouped delivery retains host lifecycle events\n'
FAIL_NOTIFY=0
notify_unraid warning 'Fixture syslog finding' 'Existing syslog evidence' || exit 1
jq -e '.conditions.fixture.pending==""' <<< "$HH_STATE" >/dev/null || exit 1
[[ $(grep -c 'Host conditions:' "$work/delivery") == 2 ]] || exit 1
hh_flush || exit 1
[[ $(grep -c 'Host conditions:' "$work/delivery") == 2 ]] || exit 1
printf '[PASS] Successful delivery groups host/syslog evidence once and consumes only delivered events\n'
printf '4 host/syslog integration fixtures passed; no notifications sent.\n'
