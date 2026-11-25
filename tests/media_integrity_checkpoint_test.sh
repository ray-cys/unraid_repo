#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/media_integrity_audit.sh"
fixture=$(mktemp -d);trap 'rm -rf "$fixture"' EXIT
STATE_DIR="$fixture/state";TMP_DIR="$fixture/tmp";mkdir -p "$STATE_DIR" "$TMP_DIR"
STATE_FILE="$STATE_DIR/state.json.gz";PREVIOUS_STATE_FILE="$STATE_DIR/state.previous.json.gz";STATE_EXPORT_LOCK="$fixture/export.lock"
printf '{}' >"$fixture/stats"
payload() { printf '%s' "$1" | gzip -c | base64 >"$fixture/payload"; }
printf '{"schema":1,"files":{},"marker":"original"}' | gzip -c >"$STATE_FILE"
for invalid in 'not json' '{"schema":9,"files":{}}' '{"schema":1,"files":{"../escape":{"identity":[1,2,3,4,5]}}}' '{"schema":1,"files":{"movies/a.mkv":{"identity":[1,2,3,4,5],"offset":30,"duration":10}}}';do
 payload "$invalid"
 if commit_checkpoint "$fixture/payload" "$fixture/stats";then echo 'Invalid checkpoint accepted' >&2;exit 1;fi
 gzip -dc "$STATE_FILE" | jq -e '.marker=="original"' >/dev/null
 [[ ! -e "$PREVIOUS_STATE_FILE" ]]
done
payload '{"schema":1,"files":{},"marker":"second"}'
commit_checkpoint "$fixture/payload" "$fixture/stats"
gzip -dc "$PREVIOUS_STATE_FILE" | jq -e '.marker=="original"' >/dev/null
payload '{"schema":1,"files":{},"marker":"third"}'
commit_checkpoint "$fixture/payload" "$fixture/stats"
gzip -dc "$PREVIOUS_STATE_FILE" | jq -e '.marker=="second"' >/dev/null
# Invalid current data cannot replace the last valid rollback checkpoint.
printf invalid | gzip -c >"$STATE_FILE"
payload '{"schema":1,"files":{},"marker":"recovered"}'
commit_checkpoint "$fixture/payload" "$fixture/stats"
gzip -dc "$PREVIOUS_STATE_FILE" | jq -e '.marker=="second"' >/dev/null
# A failed publication restores the last current checkpoint, with no partials.
mv() { if [[ "${1:-}" == -f && "${2:-}" == "$STATE_DIR"/.state.* && "${3:-}" == "$STATE_FILE" ]];then return 1;fi;command mv "$@"; }
payload '{"schema":1,"files":{},"marker":"never-published"}'
if commit_checkpoint "$fixture/payload" "$fixture/stats";then exit 1;fi
gzip -dc "$STATE_FILE" | jq -e '.marker=="recovered"' >/dev/null
[[ $(find "$STATE_DIR" -name '.state.*' | wc -l) == 0 ]]
printf 'Bounded semantic validation, newest valid rollback, corrupt-current protection and failed-publication recovery passed\n'
