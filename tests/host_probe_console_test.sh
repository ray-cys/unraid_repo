#!/bin/bash
# Presentation fixtures: no collection, delivery, hardware or persistent state.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/tools/host_health_probes.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
log(){ printf '%s | %s | %s\n' "$1" "$2" "$3" >> "$work/console"; }
notify_unraid(){ printf 'Unexpected notification\n' >&2;return 1; }
HH_STATE='{"conditions":{"cpu:test":{"active":true,"good":1,"bad":0,"pending":""},"memory":{"active":false,"good":0,"bad":1}},"baselines":{"network":{}}}'
HH_OBSERVATIONS='[]'
hh_observe mount:/boot ok 'Required mount /boot' 'Mounted; writable.' 1
hh_observe space:/ ok 'Root capacity' 'Used 12%.'
hh_observe inodes:/ ok 'Root inodes' 'Used 4%.'
hh_observe memory warning 'Available memory' 'Available 8%.' 2
hh_observe cpu:test ok 'CPU temperature' 'Package 50C.' 1
hh_observe network:errors:eth0 unknown 'LAN errors' 'New baseline; not a clean interval.'
hh_observe btrfs:/mnt/vault ok 'Vault pool' 'Metadata 12%; headroom available.'
hh_observe monitor:external-observer ok 'External observer' 'Recent scan; no SMTP failure.'
hh_observe cpu:coverage unsupported 'Additional CPU coverage' $'Not supported.\nNo guessed limit.'
before="$HH_STATE|$HH_OBSERVATIONS"
hh_log_observations
[[ "$before" == "$HH_STATE|$HH_OBSERVATIONS" ]]
for category in MOUNTS CAPACITY INODES MEMORY CPU LAN BTRFS OBSERVER HOST;do
 grep -q "^$category | " "$work/console"
done
grep -q 'MEMORY | WARNING | .*Confirmation pending 1/3' "$work/console"
grep -q 'CPU | INFO | .*Active incident retained; recovery confirmation 1/2' "$work/console"
grep -q 'LAN | WARNING | .*observed=UNKNOWN' "$work/console"
grep -q 'unsupported=1; active incidents=1' "$work/console"
(( $(wc -l < "$work/console") == 10 ))
printf '[PASS] Every observed probe has a console result; uncertainty and pending recovery remain explicit; no state mutation or delivery\n'
HH_OBSERVATIONS='[]';: > "$work/console"
hh_log_observations
grep -q 'LAN coverage: not collected' "$work/console"
grep -q 'Btrfs pressure coverage: not collected' "$work/console"
printf '[PASS] Uncollected LAN/Btrfs coverage is explicit and never presented as healthy\n'
