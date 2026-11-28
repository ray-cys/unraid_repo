#!/bin/bash
# Native JSON/PHP/sysfs fixtures. No real mail, hardware actions or live state.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tools/host_health_common.sh"
source "$root/tools/host_health_coordination.sh"
source "$root/tools/host_health_probes.sh"
work=$(mktemp -d /tmp/host-coordination.XXXXXX)
trap 'rm -rf "$work"' EXIT
HH_SYS_ROOT="$work/sys";HH_RAM_ROOT="$work/ram";HH_MIRROR="$work/mirror.json";mkdir -p "$HH_SYS_ROOT" "$HH_RAM_ROOT"
HC_DAILY_RECEIPT="$work/daily.json";HC_SCHEDULE_FILE="$work/schedule.json";HH_DISKS_INI="$work/disks.ini"
fixture_now=$(command date -d '2026-11-28 14:30:00 +0800' +%s)
date(){ if [[ "$*" == +%s ]];then printf '%s' "$fixture_now";else command date "$@";fi; }
HH_NOW=$fixture_now;HH_BOOT=$(cat /proc/sys/kernel/random/boot_id)
HH_STATE='{"schema":1,"bootId":"fixture","conditions":{},"baselines":{"network":{}}}';HH_OBSERVATIONS='[]'
count=0
assert(){ jq -e "$1" <<< "$2" >/dev/null || { printf 'FAIL: %s\n' "$3";exit 1; };count=$((count+1)); }
jq -nc '{"/boot/config/plugins/user.scripts/scripts/host_health_monitor/script":{frequency:"custom",custom:"30 6 * * *"}}' > "$HC_SCHEDULE_FILE"
jq -nc --arg boot "$HH_BOOT" --argjson at "$((HH_NOW-600))" '{schema:1,status:"complete",notification:"delivered",healthEvidence:{schema:1,bootId:$boot,observedAt:$at,findings:[{id:"device:/dev/sda|pending_sectors",device:"/dev/sda",severity:"critical",title:"Pending sectors",detail:"Confirmed count 2",action:"Keep backup current and inspect device"}],coverage:{inventory:14}}}' > "$HC_DAILY_RECEIPT"
HC_DAILY_SNAPSHOT=$(hc_daily_snapshot "$HH_NOW")
assert '.freshness=="CURRENT" and (.findings|length)==1' "$HC_DAILY_SNAPSHOT" 'Fresh daily findings recognised from native schedule'
combined=$(hc_combined_health '[]' "$HH_STATE" "$HH_NOW")
assert '.healthStatus=="CRITICAL" and .daily.findings[0].title=="Pending sectors"' "$combined" 'Successful execution cannot hide a disk fault'
jq '.status="running"' "$HC_DAILY_RECEIPT" > "$work/changed";mv "$work/changed" "$HC_DAILY_RECEIPT"
HC_DAILY_SNAPSHOT=$(hc_daily_snapshot "$HH_NOW")
assert '.executionStatus=="running" and (.findings|length)==1' "$HC_DAILY_SNAPSHOT" 'Starting new run preserves previous incident snapshot'
jq '.healthEvidence.observedAt=1' "$HC_DAILY_RECEIPT" > "$work/changed";mv "$work/changed" "$HC_DAILY_RECEIPT"
HC_DAILY_SNAPSHOT=$(hc_daily_snapshot "$HH_NOW")
assert '.freshness=="STALE" and (.findings|length)==1' "$HC_DAILY_SNAPSHOT" 'Stale evidence retains unresolved findings'
printf '{}' > "$HC_SCHEDULE_FILE"
HC_DAILY_SNAPSHOT=$(hc_daily_snapshot "$HH_NOW")
assert '.freshness=="NOT_SCHEDULED" and .findings==[]' "$HC_DAILY_SNAPSHOT" 'Retired schedule does not create an expected-run warning'
# Temperature source is only native metadata; no smartctl command is available.
HC_DAILY_SNAPSHOT='{"freshness":"CURRENT","executionStatus":"complete","findings":[],"thresholds":{}}'
mkdir -p "$HH_SYS_ROOT/class/block/sda/queue"
printf '1\n' > "$HH_SYS_ROOT/class/block/sda/queue/rotational"
write_temp(){ printf '["disk1"]\ndevice="sda"\nid="fixture-drive"\ntemp="%s"\n' "$1" > "$HH_DISKS_INI";touch -d "@$fixture_now" "$HH_DISKS_INI"; }
write_temp 65
hc_disk_temperatures;hh_lifecycle
assert 'any(.conditions[];.active==true and .severity=="critical")' "$HH_STATE" 'Critical native disk temperature raises promptly'
assert 'contains("Action:")' "$(jq -Rn --arg text "$HH_PENDING_BODY" '$text')" 'Temperature email includes an action'
hot_id=$(jq -r '.[]|select(.id|startswith("disk-temperature:"))|.id' <<< "$HH_OBSERVATIONS")
write_temp '*';HH_NOW=$((HH_NOW+300));HH_OBSERVATIONS='[]';hc_disk_temperatures;hh_lifecycle
assert 'any(.conditions[];.active==true and .severity=="critical")' "$HH_STATE" 'Sleeping/unavailable temperature does not resolve overheating'
for n in 1 2;do write_temp 40;HH_NOW=$((HH_NOW+300));HH_OBSERVATIONS='[]';hc_disk_temperatures;hh_lifecycle;done
assert 'any(.conditions[];.pending=="RECOVERED")' "$HH_STATE" 'Recovery requires two current healthy samples'
# Same incident can have a daily fallback owner, avoiding a duplicate watchdog alert.
HC_DAILY_SNAPSHOT='{"freshness":"CURRENT","executionStatus":"complete","findings":[{"id":"device:/dev/sda|temp","device":"/dev/sda","severity":"critical","title":"Temp","detail":"65C","action":"Review cooling"}],"thresholds":{}}'
write_temp 65;HH_NOW=$fixture_now;HH_OBSERVATIONS='[]';hc_disk_temperatures;hh_lifecycle
assert '[.conditions[]|select(.active)]|length==0' "$HH_STATE" 'Daily fallback incident retains single notification/recovery ownership'
combined=$(hc_combined_health "$HH_OBSERVATIONS" "$HH_STATE" "$HH_NOW")
assert '.healthStatus=="CRITICAL"' "$combined" 'Delegated fault remains visible in combined health'
# Real owner checks require delivered, recent same-boot matching evidence.
HC_FAST_RECEIPT="$work/fast.json";MONITOR_RECEIPT_FILE="$work/no-other-daily"
jq -nc --arg boot "$HH_BOOT" --arg id "$hot_id" --argjson at "$fixture_now" '{schema:1,bootId:$boot,observedAt:$at,observations:[{id:$id,device:"/dev/sda"}],health:{fastFindings:[{id:$id,severity:"critical",pending:""}]}}' > "$HC_FAST_RECEIPT"
hc_fast_temperature_owns /dev/sda critical || { echo 'FAIL: delivered owner not accepted';exit 1; }
jq '.health.fastFindings[0].pending="RAISED"' "$HC_FAST_RECEIPT" > "$work/changed";mv "$work/changed" "$HC_FAST_RECEIPT"
if hc_fast_temperature_owns /dev/sda critical;then echo 'FAIL: failed/pending delivery muted fallback';exit 1;fi
hc_thermal_only_messages 'NVMe Temp 90C >= 80C; TBW ~ 20 TB' || exit 1
if hc_thermal_only_messages 'NVMe Temp 90C >= 80C; Pending sectors=4';then echo 'FAIL: mixed storage fault delegated';exit 1;fi
# Sensor presence and CPU firmware limits are independently probed.
sensor="$HH_SYS_ROOT/class/hwmon/hwmon0";mkdir -p "$sensor"
printf 'coretemp\n' > "$sensor/name";printf 'Package id 0' > "$sensor/temp1_label"
printf 100000 > "$sensor/temp1_input";printf 80000 > "$sensor/temp1_max";printf 100000 > "$sensor/temp1_crit"
HH_STATE='{"conditions":{},"baselines":{"network":{}}}';HH_OBSERVATIONS='[]';hh_cpu;hh_lifecycle
assert 'any(.conditions[];.active and .title=="CPU temperature" and .severity=="critical")' "$HH_STATE" 'CPU overheating is independent and immediately critical at firmware limit'
# Enabled user shares are required only when the native array is started.
HH_VAR_INI="$work/var.ini";HH_DOCKER_CFG="$work/docker.cfg"
printf 'mdState="STARTED"\nshareUser="e"\n' > "$HH_VAR_INI"
printf 'DOCKER_ENABLED="no"\n' > "$HH_DOCKER_CFG"
hh_expected_mounts | grep -Fx /mnt/user >/dev/null || exit 1
printf 'mdState="STOPPED"\nshareUser="e"\n' > "$HH_VAR_INI"
if hh_expected_mounts | grep -Fx /mnt/user >/dev/null;then echo 'FAIL: stopped array requires FUSE mount';exit 1;fi
# Optional historical data corruption must not block a live critical observation.
SYSLOG_INCIDENT_ROOT="$work/incidents";mkdir -p "$SYSLOG_INCIDENT_ROOT"
printf '{broken' > "$SYSLOG_INCIDENT_ROOT/incidents.json"
combined=$(hc_combined_health "$HH_OBSERVATIONS" "$HH_STATE" "$HH_NOW")
assert '.healthStatus=="CRITICAL" and .storage.evidenceVerified==false' "$combined" 'Optional summary failure cannot hide active CPU overheating'
printf 'PASS: %s coordination assertions plus delivered-owner, failed-delivery and mixed-fault checks\n' "$count"
