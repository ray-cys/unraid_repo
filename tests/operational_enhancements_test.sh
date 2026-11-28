#!/bin/bash
# Isolated safety and evidence contracts. No live APIs, payloads or notifications.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d /tmp/operational-enhancements.XXXXXX);trap 'rm -rf "$fixture"' EXIT
export repo fixture
bash <<'CLEANUP'
set -euo pipefail
source "$repo/user_script/media_cleanup.sh"
MC_ROOT="$fixture/cleanup";mkdir "$MC_ROOT";mc_publish(){ mv "$1" "$2"; }
MC_MODE=all
printf '{"mode":"all","dryRun":false,"epoch":200,"startedAt":100,"bootId":"test","runId":"full","modules":[{"module":"arr","status":"FAILED","exit":2}]}' > "$fixture/run"
mc_publish_scoped_receipts "$fixture/run"
MC_MODE=arr
printf '{"mode":"arr","dryRun":true,"epoch":400,"startedAt":300,"bootId":"test","runId":"preview","modules":[{"module":"arr","status":"COMPLETED","exit":0}]}' > "$fixture/run"
mc_publish_scoped_receipts "$fixture/run"
jq -e '.modules.arr.runId=="full" and .modules.arr.status=="FAILED"' "$MC_ROOT/latest-module-results.json" >/dev/null
jq '.dryRun=false|.runId="repair"' "$fixture/run" > "$fixture/next";mv "$fixture/next" "$fixture/run"
mc_publish_scoped_receipts "$fixture/run"
jq -e '.modules.arr.runId=="repair"' "$MC_ROOT/latest-module-results.json" >/dev/null
jq -e '.runId=="full"' "$MC_ROOT/latest-full-run.json" >/dev/null
MEDIA_INTEGRITY_RECOVERY_FILE="$fixture/recovery.json"
printf '{"schema":1,"workflow":"arr-native","actions":{}}' > "$MEDIA_INTEGRITY_RECOVERY_FILE"
MAX_SIDECAR_SIZE_MB=32;EXTRA_SIDECAR_EXTENSIONS='';AUTO_RECOGNIZE_KNOWN_AUXILIARY=true;CAPTURE_LATE_KODI_SIDECARS=true;QUARANTINE_KODI_SIDECARS=true
first=$(mc_sidecar_policy_fingerprint)
MC_VERSION=999.999.999
jq '.observedAt=123456' "$MEDIA_INTEGRITY_RECOVERY_FILE" > "$fixture/next";mv "$fixture/next" "$MEDIA_INTEGRITY_RECOVERY_FILE"
[[ "$first" == "$(mc_sidecar_policy_fingerprint)" ]]
jq '.actions.a={app:"Sonarr",parentId:4,status:"downloading"}' "$MEDIA_INTEGRITY_RECOVERY_FILE" > "$fixture/next";mv "$fixture/next" "$MEDIA_INTEGRITY_RECOVERY_FILE"
[[ "$first" != "$(mc_sidecar_policy_fingerprint)" ]]
printf invalid > "$MEDIA_INTEGRITY_RECOVERY_FILE"
if mc_sidecar_policy_fingerprint >/dev/null 2>&1;then exit 1;fi
printf 'PASS: preview cannot certify repairs, scoped run cannot replace full history; semantic cache ignores release/timestamp churn and rejects invalid recovery state\n'
CLEANUP
bash <<'AUDIT'
set -euo pipefail
source "$repo/user_script/backup_health_audit.sh"
STATUS_DIR="$fixture/status";AUDIT_CLEANUP_ROOT="$fixture/audit-cleanup";mkdir "$STATUS_DIR" "$AUDIT_CLEANUP_ROOT";ACTIONS=();audit_log(){ :; }
record="$fixture/execution"
printf '{"boot":"test","startedAt":100,"finishedAt":201,"executionStatus":"FAILED"}' > "$record"
printf '{"schema":1,"bootId":"test","startedAt":100,"epoch":200,"runId":"full","modules":[{"module":"arr","status":"FAILED","metrics":{"applications":[{"application":"SONARR","inventoryComplete":false,"errors":1},{"application":"RADARR","inventoryComplete":true,"errors":0}]}}]}' > "$STATUS_DIR/media_cleanup.json"
printf '{"schema":1,"mode":"arr","dryRun":false,"bootId":"test","epoch":400,"runId":"repair","modules":[{"module":"arr","status":"COMPLETED","exit":0,"metrics":{"applications":[{"application":"SONARR","inventoryComplete":true,"errors":0}]}}]}' > "$AUDIT_CLEANUP_ROOT/latest-run.json"
audit_cleanup_repaired
jq '.dryRun=true' "$AUDIT_CLEANUP_ROOT/latest-run.json" > "$fixture/next";mv "$fixture/next" "$AUDIT_CLEANUP_ROOT/latest-run.json"
if audit_cleanup_repaired;then exit 1;fi
jq '.dryRun=false|.modules[0].metrics.applications[0].application="RADARR"' "$AUDIT_CLEANUP_ROOT/latest-run.json" > "$fixture/next";mv "$fixture/next" "$AUDIT_CLEANUP_ROOT/latest-run.json"
if audit_cleanup_repaired;then exit 1;fi
jq 'del(.dryRun)|.modules[0].metrics.applications[0].application="SONARR"' "$AUDIT_CLEANUP_ROOT/latest-run.json" > "$fixture/next";mv "$fixture/next" "$AUDIT_CLEANUP_ROOT/latest-run.json"
if audit_cleanup_repaired;then exit 1;fi
printf 'date | INFO | media_cleanup | run=repair | phase=MAIN | Started mode=arr preview=false\n' > "$AUDIT_CLEANUP_ROOT/media-cleanup.log"
audit_cleanup_repaired
jq -e '.executionStatus=="FAILED"' "$record" >/dev/null
printf 'PASS: exact failed application repair proof, wrong-app/preview veto, bounded legacy log proof; original execution remains failed\n'
AUDIT
bash <<'WATCHDOG'
set -euo pipefail
source "$repo/user_script/docker_service_watchdog.sh"
printf '{"state":"idle","last_run_status":"failed","library_results":{"Movies":{"status":"failed","items_processed":10,"items_succeeded":9,"items_failed":1}}}' > "$fixture/native"
wd_native_partial_counts "$fixture/native" | jq -e '.succeeded==9 and .failed==1' >/dev/null
jq '.library_results.Movies.items_processed=11' "$fixture/native" > "$fixture/invalid"
if wd_native_partial_counts "$fixture/invalid" >/dev/null;then exit 1;fi
jq '.library_results.Movies={status:"failed",items_processed:0,items_succeeded:0,items_failed:0}' "$fixture/native" > "$fixture/invalid"
if wd_native_partial_counts "$fixture/invalid" >/dev/null;then exit 1;fi
jq -e '.last_run_status=="failed"' "$fixture/native" >/dev/null
printf 'PASS: exact native partial accounting; unknown counts/preflight failure stay critical; native failed outcome retained\n'
WATCHDOG
bash <<'PROFILE'
set -euo pipefail
source "$repo/user_script/backup_cache_appdata.sh"
TEMP_DIR="$fixture/profile-temp";WORK_DIR="$fixture/profile-out";WORK_ROOT="$WORK_DIR";mkdir -p "$TEMP_DIR" "$WORK_DIR" "$fixture/input/one"
head -c 1048576 /dev/urandom > "$fixture/input/one/payload"
PRIORITY_PREFIX=();EFFECTIVE_PIGZ_THREADS=2;PIGZ_LEVEL=3;RETRIES=1
log(){ printf '%s\n' "$*" >> "$fixture/profile.log"; }
check_remaining_capacity(){ return 0; };available_bytes_for_path(){ printf '1000000000000'; }
verify_archive(){ gzip -t "$1" && tar -tzf "$1" >/dev/null; }
record_archive_manifest_row(){ [[ $(sha256sum "$2"|cut -d ' ' -f1) == "$3" ]]; }
compress_directory one "$fixture/input/one"
[[ "$LAST_COMPRESSION_PROFILE" != unavailable ]]
grep -q '^PROFILE INFO' "$fixture/profile.log"
mkdir "$fixture/extracted";tar -xzf "$WORK_DIR/one.tar.gz" -C "$fixture/extracted"
cmp "$fixture/input/one/payload" "$fixture/extracted/one/payload"
printf 'PASS: measured streaming compressor preserves archive bytes/checksum and extraction; no second source/archive pass\n'
PROFILE
