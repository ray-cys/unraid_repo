#!/bin/bash
# Temporary inventory, policy, installer, readiness and notifier fixtures only.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/system-update-test.XXXXXX);fixture=$(realpath "$fixture")
trap 'rm -rf -- "$fixture"' EXIT
export repo fixture
bash <<'CORE'
set -euo pipefail
source "$repo/user_script/system_update_coordinator.sh"
STATE_DIR="$fixture/state";STATUS_DIR="$fixture/status";STATE_FILE="$STATE_DIR/state.json";POLICY_FILE="$STATE_DIR/policy.json";LOG_FILE="$STATE_DIR/log";STATE_EXPORT_LOCK="$fixture/export.lock";mkdir "$STATE_DIR" "$STATUS_DIR"
START_EPOCH=$(date +%s);RUN_ID=fixture;VAULT_MOUNT="$fixture/vault";mkdir -p "$VAULT_MOUNT/backup"
mountpoint(){ return 0; }
jq -n '{schema:1,complete:true,docker:{prowlarr:{repository:"lscr.io/linuxserver/prowlarr",id:"old",running:true,managed:"dockerman",templateHash:"template-hash"},seerr:{repository:"ghcr.io/seerr-team/seerr:latest",running:false,managed:"dockerman"},sabnzbd:{repository:"lscr.io/linuxserver/sabnzbd:unstable",running:true,managed:"dockerman"}},plugins:{"community.applications.plg":{installed:{url:"https://source/ca"}},"tailscale.plg":{installed:{url:"https://source/tailscale"}}}}' >"$fixture/inventory"
adapter(){ case "$1" in inventory) cat "$fixture/inventory";;*) return 1;;esac; }
docker_cmd(){ case "$1 ${2:-}" in 'info ') return 0;;'container ls') jq -r '.docker|keys[]' "$fixture/inventory";;*) return 1;;esac; }
initialize
trap 'rm -rf -- "$TMP_DIR"' EXIT
jq -e '.enabled==true and .docker.prowlarr.allow==true and .docker.seerr.allow==true and .docker.sabnzbd.allow==true and .docker.sabnzbd.candidateHoldHours==12 and .plugins["community.applications.plg"].allow==true and .plugins["tailscale.plg"].allow==true' "$POLICY_FILE" >/dev/null
policy_update '.reportTime="00:00"'
collect_inventory
# Installed-but-stopped does not mean retired and never grants an autostart.
jq -e '.items["docker:seerr"].missingScans==0' "$STATE_FILE" >/dev/null
jq 'del(.docker.seerr)' "$fixture/inventory" >"$fixture/next";mv "$fixture/next" "$fixture/inventory"
collect_inventory
jq -e '.items["docker:seerr"].missingScans==1' "$STATE_FILE" >/dev/null
jq -e '.docker.seerr.allow==true' "$POLICY_FILE" >/dev/null
collect_inventory
jq -e '.items["docker:seerr"]==null and .retired["docker:seerr"]!=null' "$STATE_FILE" >/dev/null
jq -e '.docker.seerr==null' "$POLICY_FILE" >/dev/null
before=$(sha256sum "$STATE_FILE")
jq '.complete=false' "$fixture/inventory" >"$fixture/next";mv "$fixture/next" "$fixture/inventory"
if collect_inventory;then exit 1;fi
[[ "$before" == "$(sha256sum "$STATE_FILE")" ]]
jq '.complete=true' "$fixture/inventory" >"$fixture/next";mv "$fixture/next" "$fixture/inventory"
cp "$POLICY_FILE" "$fixture/policy.good"
jq '.limits.dailyTotal="invalid"' "$POLICY_FILE" >"$fixture/policy.invalid"
if policy_valid "$fixture/policy.invalid";then exit 1;fi
# Independent rolling budgets must not consume the other application type.
mutate --argjson now "$(date +%s)" '.jobs=([range(0;6)|{key:("docker"+tostring),value:{kind:"docker",dispatchedAt:$now,status:"COMPLETED"}}]|from_entries)'
if quota_available docker;then exit 1;fi
quota_available plugin
mutate --argjson now "$(date +%s)" '.jobs=([range(0;2)|{key:("plugin"+tostring),value:{kind:"plugin",dispatchedAt:$now,status:"COMPLETED"}}]|from_entries)'
quota_available docker
if quota_available plugin;then exit 1;fi
mutate --argjson now "$(date +%s)" '.jobs={old:{kind:"plugin",dispatchedAt:($now-86401),status:"COMPLETED"}}'
quota_available plugin
mutate '.jobs={}'
printf 'Automatic identity-bound allowlist, stopped preservation, confirmed retirement and partial-inventory veto passed\n'
# Full native-action orchestration uses a fake installer with actual journal writes.
now=$(date +%s);candidate="sha256:$(printf '%064d' 1)"
mutate --arg c "$candidate" --argjson now "$now" '.items["docker:prowlarr"] += {candidate:$c,candidateSeenAt:($now-90000),available:true,checkStatus:"VERIFIED",checkedAt:$now}'
window_open(){ return 0; };adapter_compatible(){ return 0; };maintenance_guard(){ return 0; };readiness(){ return 0; }
backup_evidence(){ printf '{"verified":true}' >"$TMP_DIR/backup-evidence.json"; }
ROLLBACK_ROOT="$VAULT_MOUNT/backup/system_updates"
prepare_recovery_set(){ mkdir -p "$ROLLBACK_ROOT/$3";cp "$TMP_DIR/definition-before.json" "$ROLLBACK_ROOT/$3/definition-before.json"; }
start_container_lease(){ return 0; }
NATIVE_DOCKER_UPDATE="$fixture/native-update"
printf '#!/bin/bash\nprintf "called\\n" >>"%s/native-calls"\ntouch "%s/installed"\n' "$fixture" "$fixture" >"$NATIVE_DOCKER_UPDATE";chmod +x "$NATIVE_DOCKER_UPDATE"
adapter(){ case "$1" in
 inventory) cat "$fixture/inventory";;
 docker-check) jq -n --arg c "$candidate" '{schema:1,remote:$c,local:"old",available:true}';;
 docker-local) jq -n --arg c "${DRIFT_DIGEST:-$candidate}" '{schema:1,local:$c}';;
 definition) local id=old;[[ ! -e "$fixture/installed" ]] || id=new
 jq -n --arg id "$id" --argjson memory "${DRIFT_MEMORY:-0}" '{schema:1,id:$id,running:true,runtimeImage:"lscr.io/linuxserver/prowlarr",templateHash:"template-hash",definition:{host:{Memory:$memory}}}';;
 *) return 1;;esac; }
docker_cmd(){ case "$1 ${2:-}" in 'inspect prowlarr') printf 'old\n';;*) return 1;;esac; }
window_open(){ return 1; };install_one;[[ ! -e "$fixture/native-calls" ]]
window_open(){ return 0; }
mutate --argjson now "$now" '.items["docker:prowlarr"].candidateSeenAt=$now'
install_one;[[ ! -e "$fixture/native-calls" ]]
mutate --argjson now "$now" '.items["docker:prowlarr"].candidateSeenAt=($now-90000)'
backup_evidence(){ return 1; };install_one;[[ ! -e "$fixture/native-calls" ]]
backup_evidence(){ printf '{"verified":true}' >"$TMP_DIR/backup-evidence.json"; }
policy_update '.docker.prowlarr.candidateHoldHours=12'
mutate --argjson now "$now" '.items["docker:prowlarr"].candidateSeenAt=($now-13*3600)'
install_one
[[ $(wc -l <"$fixture/native-calls") == 1 ]]
id=$(jq -r '.jobs|keys[0]' "$STATE_FILE")
jq -e --arg id "$id" '.jobs[$id].status=="VERIFYING" and .jobs[$id].verifiedScans==1' "$STATE_FILE" >/dev/null
install_one
[[ $(wc -l <"$fixture/native-calls") == 1 ]]
# A healthy HTTP response cannot excuse unexpected digest/configuration changes.
DRIFT_MEMORY=1
if job_verified "$id";then exit 1;fi
unset DRIFT_MEMORY
DRIFT_DIGEST="sha256:$(printf '%064d' 2)"
if job_verified "$id";then exit 1;fi
unset DRIFT_DIGEST
reconcile_jobs
jq -e --arg id "$id" '.jobs[$id].status=="COMPLETED"' "$STATE_FILE" >/dev/null
# A zero native exit plus failed read-back remains attention, never replayed.
job_update "$id" '.jobs[$id].status="INTENT" | .jobs[$id].verifiedScans=0'
DRIFT_MEMORY=1;reconcile_jobs
jq -e --arg id "$id" '.jobs[$id].status=="ATTENTION"' "$STATE_FILE" >/dev/null
install_one;[[ $(wc -l <"$fixture/native-calls") == 1 ]]
unset DRIFT_MEMORY
# Normal startup does not become a failed-update alert; persistent lack of
# readiness after grace does, and later actual recovery still reconciles.
job_update "$id" '.jobs[$id].status="VERIFYING" | .jobs[$id].verifiedScans=0 | .jobs[$id].dispatchedAt=$now' --argjson now "$(date +%s)"
readiness(){ return 1; };reconcile_jobs
jq -e --arg id "$id" '.jobs[$id].status=="VERIFYING"' "$STATE_FILE" >/dev/null
job_update "$id" '.jobs[$id].dispatchedAt=1'
reconcile_jobs
jq -e --arg id "$id" '.jobs[$id].status=="ATTENTION"' "$STATE_FILE" >/dev/null
readiness(){ return 0; }
# Removal also closes pending update follow-up, without claiming recovery.
mutate '.retired["docker:prowlarr"]={retiredAt:1}'
reconcile_jobs
jq -e --arg id "$id" '.jobs[$id].status=="RETIRED"' "$STATE_FILE" >/dev/null
printf 'One-shot journaled install, strict read-back, two-observation completion, uncertainty hold and pending-job retirement passed\n'
# Interrupted preparation is known non-dispatch and can be reconciled safely.
mkdir -p "$ROLLBACK_ROOT/interrupted";printf 'interrupted\n' >"$ROLLBACK_ROOT/interrupted/.owner"
printf partial >"$ROLLBACK_ROOT/interrupted/image.tar.gz.partial"
mutate --arg path "$ROLLBACK_ROOT/interrupted" '.jobs.interrupted={status:"PREPARING",recoveryPath:$path,startedAt:1}'
recover_preparation
jq -e '.jobs.interrupted.status=="DEFERRED"' "$STATE_FILE" >/dev/null
[[ ! -e "$ROLLBACK_ROOT/interrupted" && $(wc -l <"$fixture/native-calls") == 1 ]]
printf 'Window/age/backup vetoes, invalid policy rejection and interrupted preparation reconciliation passed\n'
# Delivery failure must retain all exact action details and acceptance state.
NOTIFY_BIN="$fixture/notify";printf '#!/bin/bash\nexit 1\n' >"$NOTIFY_BIN";chmod +x "$NOTIFY_BIN"
count=$(jq '.outbox|length' "$STATE_FILE")
if flush_notifications;then exit 1;fi
[[ $(jq '.outbox|length' "$STATE_FILE") == "$count" ]]
printf '#!/bin/bash\nexit 0\n' >"$NOTIFY_BIN"
flush_notifications
[[ $(jq '.outbox|length' "$STATE_FILE") == 0 ]]
printf 'Durable grouped update notifications retain exact actions until accepted\n'
CORE
