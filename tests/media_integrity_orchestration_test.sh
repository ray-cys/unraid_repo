#!/bin/bash
# Whole host entry point with an external mock Docker CLI and temporary paths.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/media_integrity_audit.sh"
fixture=$(mktemp -d /tmp/media-integrity-entry-test.XXXXXX)
VAULT_MOUNT="$fixture/vault"
STATE_DIR="$VAULT_MOUNT/cloud/logs/script/media_integrity_audit"
STATUS_DIR="$fixture/status";STATE_FILE="$STATE_DIR/state.json.gz";PREVIOUS_STATE_FILE="$STATE_DIR/state.previous.json.gz"
RECOVERY_FILE="$STATE_DIR/recovery.json"
LOG_FILE="$STATE_DIR/audit.log";LOCK_FILE="$fixture/audit.lock";STATE_EXPORT_LOCK="$fixture/export.lock"
NOTIFY_BIN="$fixture/notify";mkdir -p "$fixture/bin" "$STATE_DIR"
printf '{"schema":1,"workflow":"arr-native","actions":{}}' >"$RECOVERY_FILE"
printf '#!/bin/sh\nexit 0\n' >"$NOTIFY_BIN";chmod 755 "$NOTIFY_BIN"
printf '{"schema":1,"files":{},"runs":[]}' | gzip -c | base64 | tr -d '\n' >"$fixture/payload"
jq -nc --rawfile payload "$fixture/payload" '
 {type:"checkpoint-begin",length:($payload|length)},
 (range(0;($payload|length);32) as $i | {type:"checkpoint-chunk",data:$payload[$i:($i+32)]}),
 {type:"checkpoint-end",stats:{inventoryComplete:true,inventoryFiles:0,activeFindings:0,mode:"scan"}},
 {type:"complete",stats:{inventoryComplete:true,inventoryFiles:0,activeFindings:0,mode:"scan",reason:"fixture completed"}}
 ' >"$fixture/events"
export MEDIA_TEST_EVENTS="$fixture/events"
command cat >"$fixture/bin/docker" <<'MOCK'
#!/bin/bash
if [[ "$1" == exec && "$2" == -i ]]; then
 [[ "${MEDIA_TEST_MAINTENANCE:-0}" != 1 ]] || exit 137
 cat "$MEDIA_TEST_EVENTS"
else printf 'ffmpeg fixture\nffprobe fixture\n';fi
MOCK
chmod 755 "$fixture/bin/docker"
export PATH="$fixture/bin:$PATH"
mountpoint() { return 0; }
guard_calls=0
workload_guard() {
 guard_calls=$((guard_calls+1));GUARD_REASON=""
 if [[ "${MEDIA_TEST_MAINTENANCE:-0}" == 1 ]] && (( guard_calls>1 )); then GUARD_REASON='Planned appdata/Bazarr maintenance';return 1;fi
 return 0
}
# macOS fixtures have no /proc; Unraid uses the real source.
cat() { if [[ "${1:-}" == /proc/sys/kernel/random/uuid && ! -e "$1" ]]; then printf '11111111-2222-3333-4444-555555555555\n';else command cat "$@";fi; }
main
trap 'cleanup;rm -rf -- "$fixture"' EXIT
if [[ "${MEDIA_TEST_MAINTENANCE:-0}" == 1 ]]; then
 jq -e '.status=="DEFERRED" and .lastCompletedScanAt==0 and (.body|contains("maintenance"))' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
 printf 'Container interruption during planned maintenance is deferred, not a corruption/script-failure alert\n'
else
 jq -e '.status=="OK" and .lastCompletedScanAt>0 and .notification=="suppressed"' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
 [[ -f "$STATE_FILE" && ! -e "$STATE_DIR/pending-notification.json" ]]
 printf 'Whole host launch, streaming checkpoint, worker exit, final receipt and quiet healthy completion passed\n'
fi
