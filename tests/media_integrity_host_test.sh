#!/bin/bash
# shellcheck disable=SC2034
# Temporary host-state and notification fixtures; no Docker/library actions.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/media_integrity_audit.sh"
fixture=$(mktemp -d /tmp/media-integrity-host-test.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
STATE_DIR="$fixture/state";STATUS_DIR="$fixture/status";TMP_DIR="$fixture/tmp"
mkdir -p "$STATE_DIR" "$STATUS_DIR" "$TMP_DIR"
STATE_FILE="$STATE_DIR/state.json.gz";PREVIOUS_STATE_FILE="$STATE_DIR/state.previous.json.gz"
LOG_FILE="$STATE_DIR/audit.log";STATE_EXPORT_LOCK="$fixture/export.lock"
NOTIFY_BIN="$fixture/notify"
printf '{"schema":1,"files":{}}' | gzip -c >"$PREVIOUS_STATE_FILE"
printf corrupt >"$STATE_FILE"
load_state
[[ "$RECOVERY_NOTE" == *'previous validated'* ]]
gzip -dc "$PREVIOUS_STATE_FILE" | jq -e '.schema==1' >/dev/null
# JSON payload beyond exec argument limits travels through files/stdin only.
head -c 250000 /dev/urandom | base64 >"$fixture/blob"
jq -n --rawfile blob "$fixture/blob" '{schema:1,files:{},padding:$blob}' >"$fixture/large.json"
gzip -c "$fixture/large.json" | base64 | tr -d '\n' >"$fixture/payload"
jq -n --rawfile payload "$fixture/payload" '{type:"checkpoint",payload:$payload,stats:{inventoryFiles:0,inventoryComplete:true,quickPassed:0,segmentsPassed:0,cyclesCompleted:0}}' >"$fixture/event.json"
event=$(cat "$fixture/event.json")
save_checkpoint "$event"
unpack_state "$STATE_FILE"
[[ $(jq -r '.padding|length' "$TMP_DIR/state.json") -gt 200000 ]]
printf '#!/bin/sh\nexit 1\n' >"$NOTIFY_BIN";chmod 755 "$NOTIFY_BIN"
WORKER_FINISHED=true;MODE=scan
write_report OK fixture
[[ -f "$STATE_DIR/pending-notification.json" ]]
jq -e '.notification=="failed"' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
printf '#!/bin/sh\nprintf "sent\\n" >>"%s/calls"\n' "$fixture" >"$NOTIFY_BIN"
write_report OK fixture
[[ ! -e "$STATE_DIR/pending-notification.json" ]]
write_report OK fixture
[[ $(wc -l <"$fixture/calls") == 1 ]]
MODE=inventory;write_report INVENTORY_ONLY fixture
[[ $(wc -l <"$fixture/calls") == 1 ]]
# Routine healthy work and healthy recovery transitions remain silent.
RECOVERY_NOTE="";MODE=scan
write_report OK 'Healthy ordinary scan'
jq -e '.notification=="suppressed"' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
[[ $(wc -l <"$fixture/calls") == 1 ]]
# Progress changes alone never generate a healthy email.
printf '{"inventoryComplete":true,"quickPassed":99,"segmentsPassed":42}' >"$TMP_DIR/stats.json"
write_report OK 'More healthy progress'
[[ $(wc -l <"$fixture/calls") == 1 ]]
# An actual worker failure still notifies with operational detail.
write_report FAILED 'Decoder worker unexpectedly exited'
[[ $(wc -l <"$fixture/calls") == 2 ]]
# Resolving the failure does not produce a success email.
write_report OK 'Recovered worker'
[[ $(wc -l <"$fixture/calls") == 2 ]]
# Findings and recovery failures must contain useful actions/evidence, while
# changed progress alone must not resend the same incident.
RECOVERY_FILE="$STATE_DIR/recovery.json"
jq '.files["series/Example/episode.mkv"]={identity:["1","2","3","4","5"],issue:{id:"finding",kind:"decode_error",proofVersion:4,origin:"decode",confirmationMethod:"normal-isolated-streams-v1",streamEvidence:[{primary:true,kind:"decode_error",exit:1}],confirmationKey:"fixture",confirmed:true,confirmedRuns:2,evidence:"Invalid NAL unit",offset:600}}' "$TMP_DIR/state.json" >"$fixture/new-state"
gzip -c "$fixture/new-state" >"$STATE_FILE"
jq -n --argjson now "$(date +%s)" '{schema:1,workflow:"arr-native",actions:{("a"*64):{app:"Sonarr",parentId:20,fileId:31,targets:[32],path:"series/Example/episode.mkv",identity:["1","2","3","4","5"],events:[],status:"review",startedAt:$now,updatedAt:$now,reason:"Search response unavailable; no retry"}}}' >"$RECOVERY_FILE"
write_report WARNING 'Recovery needs review'
jq -e '.status=="WARNING" and .recoveryAttention==1 and (.body|contains("Search response unavailable; no retry")) and (.body|contains("Invalid NAL unit")) and (.body|contains("Next action:"))' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
[[ $(wc -l <"$fixture/calls") == 3 ]]
printf '{"inventoryComplete":true,"quickPassed":100,"segmentsPassed":99}' >"$TMP_DIR/stats.json"
write_report WARNING 'More progress with unchanged finding'
[[ $(wc -l <"$fixture/calls") == 3 ]]
# Verified replacements generate one grouped completion email, then deduplicate.
jq '.actions[].status="recovered"' "$RECOVERY_FILE" >"$fixture/new-recovery";mv "$fixture/new-recovery" "$RECOVERY_FILE"
jq '.files[].issue=null' "$fixture/new-state" | gzip -c >"$STATE_FILE"
write_report OK 'Recovery verified'
[[ $(wc -l <"$fixture/calls") == 4 ]]
write_report OK 'Repeated verified observation'
[[ $(wc -l <"$fixture/calls") == 4 ]]
# Completion delivery failure remains pending until acknowledged by notify;
# successful retry produces one completion message, then remains quiet.
jq '.actions[("b"*64)]=(.actions[("a"*64)]+{reason:"Another verified native replacement"})' "$RECOVERY_FILE" >"$fixture/new-recovery";mv "$fixture/new-recovery" "$RECOVERY_FILE"
printf '#!/bin/sh\nexit 1\n' >"$NOTIFY_BIN"
write_report OK 'Completion delivery failure'
[[ -f "$STATE_DIR/pending-notification.json" ]]
printf '#!/bin/sh\nprintf "sent\\n" >>"%s/calls"\n' "$fixture" >"$NOTIFY_BIN"
write_report OK 'Completion delivery retry'
[[ $(wc -l <"$fixture/calls") == 5 && ! -e "$STATE_DIR/pending-notification.json" ]]
write_report OK 'Duplicate completion poll'
[[ $(wc -l <"$fixture/calls") == 5 ]]
# A guard probe must release its shared lock immediately, never for the scan.
lock="$fixture/backup.lock";touch "$lock"
probe_lock "$lock"
flock -n "$lock" true
printf 'Previous-state recovery, file-backed large checkpoints, notification retry/dedup, inventory silence and short backup-lock checks passed\n'
# Legacy probe warnings produce one explanatory grouped correction, never a
# claim that a media file was repaired or fully verified.
jq '.resolved=[{id:"old-probe",path:"movies/Example.mkv",resolvedAt:123,resolution:"Legacy probe-only corruption classification withdrawn; media unchanged"}]' "$TMP_DIR/state.json" | gzip -c >"$STATE_FILE"
old_calls=$(wc -l <"$fixture/calls")
write_report OK 'Evidence review completed'
[[ $(wc -l <"$fixture/calls") == $((old_calls+1)) ]]
jq -e '(.body|contains("media unchanged")) and .notification=="sent"' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
write_report OK 'Repeated evidence review'
[[ $(wc -l <"$fixture/calls") == $((old_calls+1)) ]]
printf 'Evidence reclassification is explained and notified once\n'
# Initial transient resource/time failures remain visible locally but quiet.
jq '.resolved=[] | .files={"movies/transient.mkv":{identity:["1","2","3","4","5"],issue:{id:"transient",kind:"unverified_timeout",confirmed:false,confirmedRuns:0,alertable:false,evidence:"Decode time budget exceeded"}}}' "$TMP_DIR/state.json" | gzip -c >"$STATE_FILE"
old_calls=$(wc -l <"$fixture/calls")
write_report WARNING 'Initial transient audit problem; retry scheduled'
[[ $(wc -l <"$fixture/calls") == "$old_calls" ]]
jq -e '.notification=="suppressed" and .activeFindings==1 and .replacementCandidates==0 and .actionableFindings==0' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
gzip -dc "$STATE_FILE" | jq '.files[].issue.alertable=true' | gzip -c >"$fixture/persistent.gz";mv "$fixture/persistent.gz" "$STATE_FILE"
write_report WARNING 'Persistent audit problem; no replacement authorised'
[[ $(wc -l <"$fixture/calls") == $((old_calls+1)) ]]
jq -e '.notification=="sent" and .replacementCandidates==0 and (.body|contains("audit/review findings=1"))' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
printf 'Initial transient findings remain quiet; persistent audit problems notify without replacement candidates\n'
# Replacement counts and wording use the same primary-proof requirement.
gzip -dc "$STATE_FILE" | jq '.files["movies/transient.mkv"] |= (. as $f | .issue={id:"primary",kind:"decode_error",identity:$f.identity,proofVersion:4,origin:"decode",confirmationMethod:"normal-isolated-streams-v1",confirmationKey:"fixture",confirmed:true,confirmedRuns:2,streamEvidence:[{index:0,type:"video",codec:"h264",primary:true,kind:"decode_error",exit:1,complete:false}]})' | gzip -c >"$fixture/primary.gz";mv "$fixture/primary.gz" "$STATE_FILE"
write_report WARNING 'Confirmed primary failure fixture'
jq -e '.replacementCandidates==1 and (.body|contains("Primary-stream decode failure")) and (.body|contains("#0 video (h264; primary)"))' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
gzip -dc "$STATE_FILE" | jq '.files[].issue.streamEvidence[].primary=false' | gzip -c >"$fixture/aux.gz";mv "$fixture/aux.gz" "$STATE_FILE"
write_report WARNING 'Primary evidence absent fixture'
jq -e '.replacementCandidates==0 and (.body|contains("Suspected decode failure"))' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
# Progress and last-path changes never bypass grouped incident deduplication.
old_calls=$(wc -l <"$fixture/calls")
jq '.uniqueFilesAttempted=42 | .uniqueFilesOpened=40 | .uniqueFilesPartiallyDecoded=12' "$TMP_DIR/stats.json" >"$fixture/stats-new";mv "$fixture/stats-new" "$TMP_DIR/stats.json"
gzip -dc "$STATE_FILE" | jq '.lastActivity.attempt={path:"movies/Example.mkv",epoch:100,kind:"decode_range_passed",nextOffset:600,duration:7200}' | gzip -c >"$fixture/progress.gz";mv "$fixture/progress.gz" "$STATE_FILE"
write_report WARNING 'Same finding; more progress'
[[ $(wc -l <"$fixture/calls") == "$old_calls" ]]
jq -e '.progress.run.uniqueFilesAttempted==42 and (.body|contains("Last attempted file: movies/Example.mkv")) and .notification=="suppressed"' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
# Quiet transient rows cannot hide a primary failure beyond the display limit.
jq -n --argjson now "$(date +%s)" '{schema:1,files:((reduce range(0;12) as $i ({}; .["movies/Quiet\($i)/file.mkv"]={identity:["1","2","3","4","5"],issue:{id:("quiet"+($i|tostring)),kind:"unverified_timeout",confirmed:false,confirmedRuns:0,alertable:false,firstSeen:1,evidence:"timeout"}})) + {"movies/Critical/file.mkv":{identity:["1","2","3","4","5"],issue:{id:"priority",kind:"decode_error",identity:["1","2","3","4","5"],proofVersion:4,origin:"decode",confirmationMethod:"normal-isolated-streams-v1",confirmationKey:"fixture",confirmed:true,confirmedRuns:2,firstSeen:$now,streamEvidence:[{index:0,type:"video",codec:"h264",primary:true,kind:"decode_error",exit:1,complete:false}],evidence:"Invalid NAL"}}})}' | gzip -c >"$STATE_FILE"
write_report WARNING 'Priority ordering fixture'
jq -e '.activeFindings==13 and .actionableFindings==1 and .displayedFindingIds==["priority"] and (.body|contains("- movies/Critical/file.mkv")) and (.body|contains("Quiet transient findings=12"))' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
# Preserve the primary incident while exposing its separate audit limitation.
gzip -dc "$STATE_FILE" | jq '.files["movies/Critical/file.mkv"].auditIssue={id:"separate-audit",kind:"read_error",evidence:"EIO",confirmed:false,confirmedRuns:0}' | gzip -c >"$fixture/separate.gz";mv "$fixture/separate.gz" "$STATE_FILE"
write_report WARNING 'Separate media and storage evidence fixture'
jq -e '.activeFindings==14 and .replacementCandidates==1 and (.displayedFindingIds|index("priority"))!=null and (.displayedFindingIds|index("separate-audit"))!=null' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
# Omitted rows rotate only on later existing delivery opportunities.
jq -n '{schema:1,files:(reduce range(0;12) as $i ({}; .["movies/Action\($i)/file.mkv"]={identity:["1","2","3","4","5"],issue:{id:("action"+($i|tostring)),kind:"read_error",evidence:"EIO",confirmed:false,confirmedRuns:0,firstSeen:1}}))}' | gzip -c >"$STATE_FILE"
write_report WARNING 'More findings than notification slots'
jq -e '(.displayedFindingIds|length)==8 and (.body|contains("4 omitted"))' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
jq '.displayedFindingIds' "$STATUS_DIR/media_integrity_audit.json" >"$fixture/shown-first"
old_calls=$(wc -l <"$fixture/calls")
write_report WARNING 'Same findings second scheduled run'
[[ $(wc -l <"$fixture/calls") == "$old_calls" ]]
jq '.sentAt=0' "$STATE_DIR/notified.json" >"$fixture/receipt";mv "$fixture/receipt" "$STATE_DIR/notified.json"
write_report WARNING 'Weekly reminder opportunity'
jq -e --slurpfile first "$fixture/shown-first" '[.displayedFindingIds[]|select(. as $id|($first[0]|index($id))==null)]|length==4' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
printf 'Priority incidents remain visible; separate audit evidence and weekly-only omitted-row rotation passed\n'
