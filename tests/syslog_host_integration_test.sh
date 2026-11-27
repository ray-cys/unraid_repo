#!/bin/bash
# Live read-only probes, isolated RAM/cursor/delivery state. No actual mail.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/syslog-host-test.XXXXXX) || exit 1
trap 'rm -rf "$work"' EXIT
HH_RAM_ROOT=$work;HH_MIRROR="$work/mirror.json"
HH_EXTERNAL_OBSERVER_CONFIG="$work/no-enrolled-pi.json"
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
HH_FAST_RECEIPT="$work/host-health-receipt.json"
before=$(sha256sum "$HH_FAST_RECEIPT" | cut -d ' ' -f1)
host_external_status > "$work/external-status.json" || exit 1
jq -e '.schema==1 and (.bootId|type)=="string" and (.epoch|type)=="number" and (.uptimeSeconds|type)=="number"' "$work/external-status.json" >/dev/null || exit 1
[[ $(sha256sum "$HH_FAST_RECEIPT"|cut -d ' ' -f1) == "$before" ]] || exit 1
printf '[PASS] Restricted external status endpoint returns bounded identity/freshness without changing producer state\n'
printf '5 host/syslog integration fixtures passed; no notifications sent.\n'
