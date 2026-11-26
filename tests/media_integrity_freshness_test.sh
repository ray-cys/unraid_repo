#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/backup_health_audit.sh"
fixture=$(mktemp -d /tmp/media-integrity-freshness.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
STATUS_DIR="$fixture";NOW=1000000
jq -n --argjson first "$((NOW+86400))" '{schema:1,lastCompletedScanAt:0,firstScheduledAt:$first,notification:"not_attempted"}' >"$fixture/media_integrity_audit.json"
FINDINGS=();audit_media_integrity_monitor;[[ ${#FINDINGS[@]} == 0 ]]
jq '.firstScheduledAt=1' "$fixture/media_integrity_audit.json" >"$fixture/next";mv "$fixture/next" "$fixture/media_integrity_audit.json"
FINDINGS=();audit_media_integrity_monitor;[[ ${#FINDINGS[@]} == 1 ]]
jq --argjson now "$NOW" '.lastCompletedScanAt=$now|.notification="sent"|.activeFindings=42' "$fixture/media_integrity_audit.json" >"$fixture/next";mv "$fixture/next" "$fixture/media_integrity_audit.json"
FINDINGS=();audit_media_integrity_monitor;[[ ${#FINDINGS[@]} == 0 ]]
jq '.notification="failed"' "$fixture/media_integrity_audit.json" >"$fixture/next";mv "$fixture/next" "$fixture/media_integrity_audit.json"
FINDINGS=();audit_media_integrity_monitor;[[ ${#FINDINGS[@]} == 1 ]]
printf 'Initial-schedule grace, missed completion, no duplicate media findings and delivery-failure monitoring passed\n'
jq --argjson now "$NOW" '.notification="sent"|.schedule={maxGapSeconds:432000}|.lastCompletedScanAt=($now-6*86400)' "$fixture/media_integrity_audit.json" >"$fixture/next";mv "$fixture/next" "$fixture/media_integrity_audit.json"
FINDINGS=();audit_media_integrity_monitor;[[ ${#FINDINGS[@]} == 1 ]]
printf 'Twice-weekly schedule receipt applies a five-day completion grace\n'
jq --argjson now "$NOW" '.lastProgressScanAt=($now-2*86400)' "$fixture/media_integrity_audit.json" >"$fixture/next";mv "$fixture/next" "$fixture/media_integrity_audit.json"
FINDINGS=();audit_media_integrity_monitor;[[ ${#FINDINGS[@]} == 0 ]]
printf 'Guarded partial runs count only via saved successful progress, without fake completions\n'

# Recovery/validation polls cannot borrow legacy completion timestamps after schema 2.
jq --argjson now "$NOW" '.evidenceSchema=2|.lastRealScanAt=($now-6*86400)|.lastDecodeProgressAt=0|.lastCompletedScanAt=$now|.lastProgressScanAt=$now' "$fixture/media_integrity_audit.json" >"$fixture/next";mv "$fixture/next" "$fixture/media_integrity_audit.json"
FINDINGS=();audit_media_integrity_monitor;[[ ${#FINDINGS[@]} == 1 ]]
jq --argjson now "$NOW" '.lastDecodeProgressAt=($now-86400)' "$fixture/media_integrity_audit.json" >"$fixture/next";mv "$fixture/next" "$fixture/media_integrity_audit.json"
FINDINGS=();audit_media_integrity_monitor;[[ ${#FINDINGS[@]} == 0 ]]
printf 'Schema-2 API/validation timestamps cannot conceal stale real scan evidence\n'
