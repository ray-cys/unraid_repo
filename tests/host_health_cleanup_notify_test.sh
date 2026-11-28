#!/bin/bash
# Exercise the actual notification wrapper with a local fake executable only.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/user_script/host_health_watchdog.sh"
work=$(mktemp -d /tmp/host-cleanup-notify.XXXXXX) || exit 1
trap 'rm -rf "$work"' EXIT
export HC_CAPTURE="$work/capture" HC_RETURN=0
cat > "$work/notifier" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" >> "$HC_CAPTURE"
exit "$HC_RETURN"
MOCK
chmod 700 "$work/notifier"
usr_ops_notify "$work/notifier" -i warning -s Fixture -d 'Action required' -m 'Fixture evidence' || exit 1
grep -F 'Status: ATTENTION' "$HC_CAPTURE" >/dev/null || exit 1
grep -F 'Actions and findings:' "$HC_CAPTURE" >/dev/null || exit 1
HC_RETURN=17
rc=0
usr_ops_notify "$work/notifier" -i alert -s Fixture -d 'Delivery failure' -m 'Pending evidence' || rc=$?
[[ "$rc" == 17 ]] || exit 1
printf 'Actual host notification wrapper retains operational wording and propagates delivery failures; no mail sent\n'
