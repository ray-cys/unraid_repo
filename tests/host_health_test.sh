#!/bin/bash
# shellcheck disable=SC2034,SC2218
# Native jq/PHP/Linux fixtures. All mutation and emergency evidence is isolated.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/tools/host_health_common.sh"
source "$ROOT/tools/host_health_probes.sh"
work=$(mktemp -d /tmp/host-health-test.XXXXXX)
trap 'rm -rf "$work"' EXIT
HH_RAM_ROOT=$work;HH_MIRROR="$work/mirror.json";HH_BOOT=fixture;HH_NOW=1000000
HH_STATE='{"schema":1,"bootId":"fixture","conditions":{},"baselines":{"network":{}}}'
HH_OBSERVATIONS='[]';count=0
pass(){ count=$((count+1));printf '[PASS] %s\n' "$1"; }
assert(){ jq -e "$1" <<< "$2" >/dev/null || { printf '[FAIL] %s\n' "$3";exit 1; };pass "$3"; }
sample(){ HH_NOW=$((HH_NOW+300));HH_OBSERVATIONS='[]';hh_observe test "$1" 'Fixture condition' "$1 evidence" "${2:-2}";hh_lifecycle; }
sample warning;assert '.conditions.test.active!=true' "$HH_STATE" 'First warning is pending'
sample warning;assert '.conditions.test.active!=true' "$HH_STATE" 'Second warning is pending'
sample warning;assert '.conditions.test.active and .conditions.test.pending=="RAISED"' "$HH_STATE" 'Third warning raises one event'
hh_mount_info(){ printf '{"mounted":false,"readOnly":false,"type":""}\n'; }
hh_delivered
sample warning;assert '.conditions.test.pending==""' "$HH_STATE" 'Unchanged warning is quiet after delivery'
sample unknown;assert '.conditions.test.active' "$HH_STATE" 'Unknown cannot resolve an incident'
sample ok;assert '.conditions.test.active' "$HH_STATE" 'One good sample cannot resolve'
sample ok;assert '.conditions.test.active==false and .conditions.test.pending=="RECOVERED"' "$HH_STATE" 'Two good samples resolve with evidence'
hh_delivered
sample critical 1;assert '.conditions.test.active and .conditions.test.pending=="RAISED"' "$HH_STATE" 'Critical mount-like condition raises immediately'
# No delivery call: the event must survive another invocation.
sample critical 1;assert '.conditions.test.pending=="RAISED"' "$HH_STATE" 'Failed delivery remains pending'
hh_delivered
sample warning;assert '.conditions.test.pending=="SEVERITY CHANGED"' "$HH_STATE" 'Severity transition is reported'
hh_delivered
HH_NOW=$((HH_NOW+86400));sample warning
# Sampling gap resets persistence but existing active condition remains active.
sample warning;sample warning;assert '.conditions.test.pending=="REMINDER"' "$HH_STATE" 'Daily reminder requires confirmed current evidence'
usage=$'Device size: 1000213626880\nDevice unallocated: 577092239360\nDevice missing: 0\nFree (estimated): 303595749376\nGlobal reserve: 246611968 (used: 0)\nMetadata,RAID1: Size:2147483648, Used:213794816 (9.96%)\nData,RAID1: Size:209379655680, Used:194330025984 (92.81%)'
result=$(hh_btrfs_metrics "$usage" '')
assert '.valid and .severity=="ok"' "$result" 'Highly used data chunks do not falsely imply a full pool'
assert '.severity=="critical"' "$(hh_btrfs_metrics "$usage" 'Some devices missing')" 'Missing Btrfs member is critical'
assert '.severity=="unknown"' "$(hh_btrfs_metrics '' '')" 'Unavailable metrics stay unknown'
usage=${usage/577092239360/1024};usage=${usage/213794816/2137483648};usage=${usage/used: 0/used: 4096}
assert '.severity=="critical"' "$(hh_btrfs_metrics "$usage" '')" 'Metadata exhaustion correlates low headroom and reserve use'
now=$(TZ=Asia/Singapore date -d '2026-11-27 12:00:00' +%s)
result=$(hh_cron_last_due '30 2 28 * *' "$now")
assert '.valid and (.dueLocal|startswith("2026-10-28 02:30"))' "$result" 'Native monthly deadline does not falsely age out before next due date'
assert '.valid==false' "$(hh_cron_last_due 'bad cron' "$now")" 'Invalid enabled cron stays unverified'
assert '.valid and .dueEpoch>0' "$(hh_cron_last_due '*/5 6-8 * * 0,3' "$now")" 'Cron ranges, lists and steps are supported'
# Real mount parser only, mocked native response; ro must be an exact option.
source "$ROOT/tools/host_health_common.sh"
timeout(){ shift 2;shift;printf 'xfs rw,relatime,errors=remount-ro\n'; }
assert '.mounted and (.readOnly|not)' "$(hh_mount_info /fixture)" 'errors=remount-ro is not a read-only mount'
timeout(){ printf 'xfs ro,relatime\n'; }
assert '.readOnly' "$(hh_mount_info /fixture)" 'Exact read-only mount option is detected'
unset -f timeout
# Guard rejects absent vault without creating any persistent state or notifying.
source "$ROOT/user_script/host_health_monitor.sh"
HM_RAM_ROOT=$work;hh_mount_info(){ printf '{"mounted":false,"readOnly":false,"type":""}\n'; };hh_array_state(){ printf stopped; }
if hm_storage_guard;then exit 1;fi
assert '.healthy==false' "$(cat "$work/host-health-monitor-emergency.json")" 'Absent vault records only RAM emergency evidence'
# No native tests, disks, network actions or Unraid notifications are executed.
# Native empty slots retain fsType; assigned or disabled slots still need mounts.
cat > "$work/disks.ini" <<'INI'
["disk1"]
type="Data"
device="sda"
fsType="xfs"
["disk9"]
type="Data"
device=""
status="DISK_NP"
fsType="xfs"
["vault"]
type="Cache"
device="sdz"
fsType="btrfs"
INI
HH_DISKS_INI="$work/disks.ini";HH_DOCKER_CFG="$work/docker.cfg"
printf 'DOCKER_ENABLED="no"\n' > "$HH_DOCKER_CFG"
hh_array_state(){ printf started; }
mounts=$(hh_expected_mounts)
[[ "$mounts" == *'/mnt/disk1'* && "$mounts" == *'/mnt/vault'* && "$mounts" != *'/mnt/disk9'* && "$mounts" != *'/var/lib/docker'* ]]
pass 'Dynamic inventory ignores unused slots and disabled Docker'
hh_array_state(){ printf stopped; }
[[ "$(hh_expected_mounts)" == /boot ]];pass 'Planned array stop does not create missing storage alerts'
# Healthy inventory is still actionable after earlier failures.
HH_STATE='{"conditions":{},"baselines":{"network":{}}}';HH_NOW=2000000
sample warning;sample unknown;sample warning;sample warning
assert '.conditions.test.active!=true' "$HH_STATE" 'Unknown breaks consecutive warning confirmation'
sample warning;hh_delivered;HH_NOW=$((HH_NOW+1800));sample ok
assert '.conditions.test.active' "$HH_STATE" 'A gap cannot manufacture a recovery'
sample unknown;sample ok
assert '.conditions.test.active' "$HH_STATE" 'Unknown breaks consecutive recovery confirmation'
sample ok;assert '.conditions.test.active==false' "$HH_STATE" 'Fresh sustained recovery resolves'
# Safe guard and native scrub deadlines in isolated state, with no btrfs command.
STATE_DIR="$work/disk-state";POOL_HEALTH_FILE="$STATE_DIR/filesystems/pool_health.json"
mkdir -p "$STATE_DIR/filesystems" "$work/cron";chmod 700 "$STATE_DIR" "$STATE_DIR/filesystems"
HH_SCRUB_CRON_ROOT="$work/cron";printf '30 2 28 * * /native/btrfs_scrub start /mnt/vault -r\n' > "$work/cron/scrub_vault.cron"
RUN_EPOCH=$(TZ=Asia/Singapore date -d '2026-11-27 12:00' +%s)
CURRENT_COLLECTOR='';RUN_DIR=$work;COLLECTOR_EVENT_FILE="$work/events";touch "$COLLECTOR_EVENT_FILE"
# Mock only read-only Btrfs output; all atomic-write and deadline code is real.
timeout(){
    if [[ " $* " == *' filesystem usage '* ]];then printf '%s\n' "$FIXTURE_USAGE";return 0;fi
    if [[ " $* " == *' filesystem show '* ]];then printf 'UUID: fixture\n';return 0;fi
    shift 2;"$@"
}
# Restore the healthy allocation fixture used above.
FIXTURE_USAGE=$'Device size: 1000000000000\nDevice unallocated: 500000000000\nDevice missing: 0\nFree (estimated): 300000000000\nGlobal reserve: 1000000 (used: 0)\nMetadata,RAID1: Size:2147483648, Used:213794816'
status=$'Scrub started: Wed Oct 28 02:30:01 2026\nStatus: finished\nError summary: no errors found'
hm_pool_health /mnt/vault "$status" 0 >/dev/null
[[ -z "${FINDING_SEEN['mount:/mnt/vault|native_scrub_overdue']:-}" ]];pass 'Cached October scrub is valid before November deadline'
RUN_EPOCH=$(TZ=Asia/Singapore date -d '2026-12-02 12:00' +%s)
hm_pool_health /mnt/vault "$status" 0 >/dev/null
[[ "${FINDING_SEEN['mount:/mnt/vault|native_scrub_overdue']:-}" == 1 ]];pass 'Missed scheduled clean scrub raises after 72-hour grace'
status=$'Scrub started: Sat Nov 28 02:30:01 2026\nStatus: finished\nError summary: no errors found'
hm_pool_health /mnt/vault "$status" 1 >/dev/null
[[ "${FRESH_FILESYSTEM['native_scrub:/mnt/vault']:-}" == 1 ]];pass 'Fresh completed clean scrub supplies exact recovery evidence'
assert '.pools["/mnt/vault"].lastRecordedStart>0 and .pools["/mnt/vault"].recordedClean' "$(cat "$POOL_HEALTH_FILE")" 'One atomic structured pool state retains completion evidence'

# Discover only physical active LAN members and compare deltas, not lifetime counts.
HH_SYS_ROOT="$work/sys";mkdir -p "$HH_SYS_ROOT/class/net/br0/brif/ethfixture" "$HH_SYS_ROOT/class/net/ethfixture/device" "$HH_SYS_ROOT/class/net/ethfixture/statistics"
net="$HH_SYS_ROOT/class/net/ethfixture";printf '0x1003\n' > "$net/flags";printf '1\n' > "$net/carrier";printf '2500\n' > "$net/speed";printf '00:11:22:33:44:55\n' > "$net/address"
for metric in rx_errors tx_errors;do printf '100\n' > "$net/statistics/$metric";done
for metric in rx_packets tx_packets;do printf '100000\n' > "$net/statistics/$metric";done
ip(){ printf 'default via 192.0.2.1 dev br0\n'; }
ethtool(){ printf 'Supported link modes: 1000baseT/Full 2500baseT/Full\nSupported pause frame use: No\n'; }
HH_STATE='{"conditions":{},"baselines":{"network":{}}}';HH_OBSERVATIONS='[]';HH_NOW=3000000
hh_network
assert 'any(.[];(.id|startswith("network:errors:")) and .severity=="unknown")' "$HH_OBSERVATIONS" 'First network sample does not alert on historical error counters'
printf '1000\n' > "$net/speed";printf '110\n' > "$net/statistics/rx_errors";printf '101000\n' > "$net/statistics/rx_packets";HH_NOW=$((HH_NOW+300));HH_OBSERVATIONS='[]';hh_network
assert 'any(.[];(.id|startswith("network:link:")) and .severity=="warning")' "$HH_OBSERVATIONS" '2.5Gb LAN downgrade is detected from supported hardware'
assert 'any(.[];(.id|startswith("network:errors:")) and .severity=="warning")' "$HH_OBSERVATIONS" 'Network errors use a current packet-relative delta'
printf '0\n' > "$net/statistics/rx_errors";HH_NOW=$((HH_NOW+300));HH_OBSERVATIONS='[]';hh_network
assert 'any(.[];(.id|startswith("network:errors:")) and .severity=="unknown")' "$HH_OBSERVATIONS" 'Counter reset cannot fabricate an error or recovery'
ethtool(){ printf 'Supported link modes: 1000baseT/Full\nSupported pause frame use: No\n'; }
HH_OBSERVATIONS='[]';hh_network
assert 'any(.[];(.id|startswith("network:link:")) and .severity=="ok")' "$HH_OBSERVATIONS" 'Replacement 1Gb hardware does not inherit a false 2.5Gb expectation'
mkdir -p "$HH_SYS_ROOT/class/hwmon/hwmon0" "$HH_SYS_ROOT/class/hwmon/hwmon1"
cpu="$HH_SYS_ROOT/class/hwmon/hwmon0";printf 'coretemp\n' > "$cpu/name";printf 'Package id 0\n' > "$cpu/temp1_label";printf '81000\n' > "$cpu/temp1_input";printf '80000\n' > "$cpu/temp1_max";printf '100000\n' > "$cpu/temp1_crit"
printf 'nct6798\n' > "$HH_SYS_ROOT/class/hwmon/hwmon1/name";printf '150000\n' > "$HH_SYS_ROOT/class/hwmon/hwmon1/temp1_input"
HH_OBSERVATIONS='[]';hh_cpu
assert 'length==1 and .[0].severity=="warning"' "$HH_OBSERVATIONS" 'CPU uses trusted package limits and ignores arbitrary motherboard inputs'
printf '101000\n' > "$cpu/temp1_input";HH_OBSERVATIONS='[]';hh_cpu
assert '.[0].severity=="critical"' "$HH_OBSERVATIONS" 'Firmware CPU critical limit is recognized'
# No test sends a notification or touches native network configuration.

# The enrolled Pi is checked without reading its SMTP credentials or changing DNS.
HH_EXTERNAL_OBSERVER_CONFIG="$work/external-observer.json"
printf '{"schema":1,"enabled":true,"sshTarget":"admin@192.0.2.100","installedAt":1}' > "$HH_EXTERNAL_OBSERVER_CONFIG";chmod 600 "$HH_EXTERNAL_OBSERVER_CONFIG"
OBSERVER_FIXTURE=$(jq -nc --argjson now "$HH_NOW" '{schema:1,lastRun:{epoch:$now},delivery:{failures:0}}')
timeout(){ [[ " $* " == *' ssh -n -T '* ]] || return 1;printf '%s\n' "$OBSERVER_FIXTURE"; }
HH_OBSERVATIONS='[]';hh_external_observer
assert '.[0].severity=="ok"' "$HH_OBSERVATIONS" 'External observer scan and delivery freshness validated'
OBSERVER_FIXTURE=$(jq -nc --argjson now "$((HH_NOW-1000))" '{schema:1,lastRun:{epoch:$now},delivery:{failures:0}}')
HH_OBSERVATIONS='[]';hh_external_observer
assert '.[0].severity=="warning"' "$HH_OBSERVATIONS" 'Stopped Pi cron cannot remain silently healthy'
OBSERVER_FIXTURE=$(jq -nc --argjson now "$HH_NOW" '{schema:1,lastRun:{epoch:$now},delivery:{failures:2}}')
HH_OBSERVATIONS='[]';hh_external_observer
assert '.[0].severity=="warning" and (.[0].detail|contains("SMTP"))' "$HH_OBSERVATIONS" 'Pi mail submission failure is visible from Hubble'
printf '{"schema":1,"enabled":false}' > "$HH_EXTERNAL_OBSERVER_CONFIG"
HH_OBSERVATIONS='[]';hh_external_observer
assert 'length==0' "$HH_OBSERVATIONS" 'Explicitly retired external observer requires no code edit'

printf '%s native host-health fixtures passed.\n' "$count"
