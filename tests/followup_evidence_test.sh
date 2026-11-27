#!/bin/bash
# Isolated evidence fixtures; no live API, notifications, cron or media mutations.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d);trap 'rm -rf "$tmp"' EXIT
source "$repo/tools/user_scripts_catalog.sh"
mkdir -p "$tmp/scripts/job"
printf 'OPS_SCRIPT_ID="host_health_watchdog"\n' >"$tmp/scripts/job/script"
printf '{"job":{"script":"/boot/config/plugins/user.scripts/scripts/job/script","frequency":"custom","custom":"*/15 * * * SUN"}}' >"$tmp/schedule"
usr_scripts_catalog "$tmp/schedule" "$tmp/scripts" >"$tmp/catalog"
printf '0,15,30,45 * * * 7 /usr/local/emhttp/plugins/user.scripts/startCustom.php /boot/config/plugins/user.scripts/scripts/job/script > /dev/null 2>&1\n' >"$tmp/cron"
usr_scripts_verify_cron "$tmp/catalog" "$tmp/cron" >"$tmp/result"
jq -e .valid "$tmp/result" >/dev/null
cp "$tmp/cron" "$tmp/single";cat "$tmp/single" >>"$tmp/cron"
if usr_scripts_verify_cron "$tmp/catalog" "$tmp/cron" >"$tmp/result";then exit 1;fi
jq -e '.issues|any(contains("duplicate"))' "$tmp/result" >/dev/null
sed 's/0,15,30,45/1,16,31,46/' "$tmp/single" >"$tmp/cron"
if usr_scripts_verify_cron "$tmp/catalog" "$tmp/cron" >"$tmp/result";then exit 1;fi
jq -e '.issues|any(contains("timing differs"))' "$tmp/result" >/dev/null
printf '*/15 * * * 0 /usr/local/emhttp/plugins/user.scripts/startCustom.php $(touch %s/sentinel) > /dev/null 2>&1\n' "$tmp" >"$tmp/cron"
if usr_scripts_verify_cron "$tmp/catalog" "$tmp/cron" >"$tmp/result";then exit 1;fi
[[ ! -e "$tmp/sentinel" ]]
printf 'Cron semantics, duplicate/drift and non-evaluation passed\n'
(
 source "$repo/user_script/backup_media_remote.sh"
 STATUS_DIR="$tmp/evidence";MEDIA_EVIDENCE_MOUNT="$tmp";mountpoint(){ return 0; }
 BACKUP_JOBS=('media|/source|/destination||');RESULT_CODE[media]=0;RESULT_REASON[media]=Success
 media_completion_evidence OK transfer
 jq -e '.schema==2 and .copy=="OK" and .jobs[0].exitCode==0' "$STATUS_DIR/backup_media_remote.last-success.json" >/dev/null
 cp "$STATUS_DIR/backup_media_remote.last-success.json" "$tmp/success"
 RESULT_CODE[media]=23;BACKUP_LAST_ERROR='Fixture partial transfer'
 media_completion_evidence UNVERIFIED transfer
 cmp "$tmp/success" "$STATUS_DIR/backup_media_remote.last-success.json"
 jq -e '.copy=="UNVERIFIED" and .jobs[0].exitCode==23 and .lastError=="Fixture partial transfer"' "$STATUS_DIR/backup_media_remote.last-attempt.json" >/dev/null
 if media_completion_evidence OK transfer;then exit 1;fi
 cmp "$tmp/success" "$STATUS_DIR/backup_media_remote.last-success.json"
)
printf 'Durable success preserved across failed attempts; partial transfers cannot claim verified completion\n'
(
 source "$repo/user_script/docker_service_watchdog.sh"
 readiness_probe(){ PROBE_RESULT=reachable;PROBE_MESSAGE=UI; }
 application_backend_probe(){ printf '%s\n' "$mock"; }
 mock='{"schema":1,"ready":true,"classification":"ready","detail":"Backend validated"}'
 endpoint_healthy http://fixture bazarr;[[ "$PROBE_RESULT" == ready ]]
 mock='{"schema":1,"ready":false,"classification":"authentication","detail":"Unauthorized"}'
 endpoint_healthy http://fixture bazarr;[[ "$PROBE_RESULT" == authentication ]]
 mock='{"schema":1,"ready":false,"classification":"backend_failure","detail":"HTTP 500"}'
 if endpoint_healthy http://fixture bazarr;then exit 1;fi
 [[ "$PROBE_RESULT" == unexpected ]]
 mock='invalid';endpoint_healthy http://fixture bazarr;[[ "$PROBE_RESULT" == unconfigured ]]
)
printf 'Backend readiness, authentication/configuration distinction and failed-backend classification passed\n'
(
 source "$repo/user_script/backup_health_audit.sh"
 STATE_DIR="$tmp/audit";STATUS_DIR="$tmp/status";mkdir -p "$STATE_DIR" "$STATUS_DIR"
 RAMLOG_ARCHIVE_ROOT="$tmp/archives";mkdir -p "$RAMLOG_ARCHIVE_ROOT/ramlogs_fixture"
 printf ramlog_archive >"$RAMLOG_ARCHIVE_ROOT/ramlogs_fixture/.owner"
 printf compressed-fixture >"$RAMLOG_ARCHIVE_ROOT/ramlogs_fixture/payload.tar.gz"
 boot=$(cat /proc/sys/kernel/random/boot_id);NOW=$(date +%s)
 jq -n --arg boot "$boot" '{schema:1,bootId:$boot}' >"$RAMLOG_ARCHIVE_ROOT/ramlogs_fixture/manifest.json"
 hash=$(sha256sum "$RAMLOG_ARCHIVE_ROOT/ramlogs_fixture/manifest.json"|cut -d ' ' -f1)
 bytes=$(stat -c %s "$RAMLOG_ARCHIVE_ROOT/ramlogs_fixture/payload.tar.gz")
 jq -n --arg boot "$boot" --arg path "$RAMLOG_ARCHIVE_ROOT/ramlogs_fixture" --arg hash "$hash" --argjson bytes "$bytes" --argjson now "$NOW" '{checkpoint:{bootId:$boot,path:$path,manifestSha256:$hash,payloadBytes:$bytes,checkedAt:$now}}' >"$STATUS_DIR/ram_logs_watchdog.json"
 jq -n --arg boot "$boot" --argjson now "$NOW" '{schema:1,bootId:$boot,lastSuccessfulScanAt:$now}' >"$STATUS_DIR/host_health_watchdog.json"
 AUDIT_CATALOG_FILE="$tmp/audit-catalog";printf '{"valid":true,"jobs":{}}' >"$AUDIT_CATALOG_FILE"
 USR_OPS_DELIVERY_ROOT="$tmp/outbox";USR_OPS_DELIVERY_RAM_ROOT="$tmp/ram-outbox";MEDIA_HEALTH_STATE_DIR="$tmp/media"
 audit_script_active(){ return 0; }
 usr_scripts_due_window(){ jq -nc --argjson cutoff "$((NOW-900))" '{cutoff:$cutoff}'; }
 finding(){ FINDINGS+=("$*"); }
 FINDINGS=();audit_script_executions;[[ ${#FINDINGS[@]} == 0 ]]
 # An unchanged archive remains fresh after a successful metadata read-back.
 jq '.checkpoint.checkedAt-=7200' "$STATUS_DIR/ram_logs_watchdog.json" >"$tmp/next";mv "$tmp/next" "$STATUS_DIR/ram_logs_watchdog.json"
 FINDINGS=();audit_script_executions;[[ ${FINDINGS[*]} == *'checkpoint is stale'* ]]
 jq --argjson now "$NOW" '.checkpoint.checkedAt=$now' "$STATUS_DIR/ram_logs_watchdog.json" >"$tmp/next";mv "$tmp/next" "$STATUS_DIR/ram_logs_watchdog.json"
 printf changed >>"$RAMLOG_ARCHIVE_ROOT/ramlogs_fixture/payload.tar.gz"
 FINDINGS=();audit_script_executions;[[ ${FINDINGS[*]} == *'read-back does not match'* ]]
 jq '.lastSuccessfulScanAt-=7200' "$STATUS_DIR/host_health_watchdog.json" >"$tmp/next";mv "$tmp/next" "$STATUS_DIR/host_health_watchdog.json"
 FINDINGS=();audit_script_executions;[[ ${FINDINGS[*]} == *'no recent successful scan'* ]]
 audit_script_active(){ return 1; }
 FINDINGS=();audit_script_executions;[[ ${#FINDINGS[@]} == 0 ]]
)
printf 'Independent stale/changed-checkpoint and successful-scan freshness; retired monitors excluded\n'
(
 eval "$(sed -n '/^notification_record_text() {/,/^}/p' "$repo/user_script/media_health_monitor.sh")"
 GROUP_NOTIFICATION_ITEM_MAX_CHARS=4096
 rendered=$(notification_record_text '{"source":"SABnzbd","title":"Recorded failure","classification":"SAB_ERROR","severity":"ERROR","age":48,"ackId":"fixture","detail":"Original native event"}')
 [[ "$rendered" == *'recorded application event'* && "$rendered" == *'Tracked issue age: 48h'* && "$rendered" == *'Ack ID: fixture'* && "$rendered" == *'Original native event'* ]]
 rendered=$(notification_record_text '{"classification":"DOWNLOAD_FLOW_REVIEW_REQUIRED","severity":"WARNING"}')
 [[ "$rendered" == *'historical outcome remains unverified'* ]]
 rendered=$(notification_record_text '{"classification":"ARR_API_UNREACHABLE","severity":"ERROR"}')
 [[ "$rendered" != *'recorded application event'* ]]
)
printf 'Historical notification labels preserve original evidence and distinguish current failures\n'
