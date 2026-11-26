#!/usr/bin/env bash
# Isolated receipt generations; no producer, archive or notification actions.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/backup_health_audit.sh"
saved_worker=$(declare -f audit_execution_worker_active)
fixture=$(mktemp -d /tmp/audit-execution.XXXXXX);trap 'rm -rf -- "$fixture"' EXIT
source_receipt="$fixture/source";snapshot="$fixture/snapshot";reads=0;transition=complete
make_running(){ jq -n '{schema:1,executionStatus:"RUNNING",startedAt:1000,pid:100,processStart:"old",boot:"fixture"}' >"$source_receipt"; }
audit_execution_worker_active(){ [[ $(jq -r .pid "$1") == 101 ]]; }
sleep(){
 reads=$((reads+1))
 case "$transition" in
 complete) jq '.executionStatus="COMPLETED"|.finishedAt=1001|.lastCompletedAt=1001|.lastExitCode=0' "$source_receipt" >"$fixture/next";;
 failed) jq '.executionStatus="FAILED"|.finishedAt=1001|.lastExitCode=143' "$source_receipt" >"$fixture/next";;
 newer) jq '.pid=101|.processStart="new"|.startedAt=1002' "$source_receipt" >"$fixture/next";;
 unchanged) return 0;;
 esac
 mv "$fixture/next" "$source_receipt"
}
# Exit-to-parent completion handoff is re-read, not called interruption.
make_running
audit_snapshot_execution "$source_receipt" "$snapshot" fixture
[[ "$reads" == 1 ]]
jq -e '.executionStatus=="COMPLETED" and .lastExitCode==0' "$snapshot" >/dev/null
# A genuine failed exit during read-back remains a failure.
transition=failed;reads=0;make_running
audit_snapshot_execution "$source_receipt" "$snapshot" fixture
jq -e '.executionStatus=="FAILED" and .lastExitCode==143' "$snapshot" >/dev/null
# A superseding invocation is read coherently, with matching PID/run metadata.
transition=newer;reads=0;make_running
audit_snapshot_execution "$source_receipt" "$snapshot" fixture
[[ "$AUDIT_EXECUTION_WORKER_ACTIVE" == true ]]
jq -e '.startedAt==1002 and .pid==101 and .processStart=="new"' "$snapshot" >/dev/null
jq '.pid=999|.startedAt=2000' "$source_receipt" >"$fixture/next";mv "$fixture/next" "$source_receipt"
jq -e '.startedAt==1002 and .pid==101' "$snapshot" >/dev/null
# Dead workers cannot be hidden indefinitely by the handoff retry.
transition=unchanged;reads=0;make_running
audit_snapshot_execution "$source_receipt" "$snapshot" fixture
[[ "$AUDIT_EXECUTION_WORKER_ACTIVE" == false && "$reads" == 2 ]]
jq -e '.executionStatus=="RUNNING"' "$snapshot" >/dev/null
# Previous-boot interruptions are definite; no closing-process delay is needed.
reads=0;audit_snapshot_execution "$source_receipt" "$snapshot" different-boot
[[ "$AUDIT_EXECUTION_WORKER_ACTIVE" == false && "$reads" == 0 ]]
printf '{bad JSON' >"$source_receipt"
if audit_snapshot_execution "$source_receipt" "$snapshot" fixture 2>/dev/null;then echo 'Invalid receipt accepted';exit 1;fi
printf 'Completion handoff, failed exits, coherent newer runs, stale interruption and invalid receipt checks passed\n'

# The native identity guard rejects a reused PID and non-positive process IDs.
eval "$saved_worker"
if [[ -r /proc/$$/stat ]];then
 boot=$(cat /proc/sys/kernel/random/boot_id)
 start=$(sed 's/.*) //' "/proc/$$/stat"|awk '{print $20}')
 jq -n --arg boot "$boot" --arg start "$start" --argjson pid "$$" '{pid:$pid,processStart:$start,boot:$boot}' >"$snapshot"
 audit_execution_worker_active "$snapshot" "$boot"
 jq '.processStart="reused"' "$snapshot" >"$source_receipt"
 if audit_execution_worker_active "$source_receipt" "$boot";then exit 1;fi
 jq '.pid=0' "$snapshot" >"$source_receipt"
 if audit_execution_worker_active "$source_receipt" "$boot";then exit 1;fi
 printf 'Native PID/start-time/boot identity checks passed\n'
fi
