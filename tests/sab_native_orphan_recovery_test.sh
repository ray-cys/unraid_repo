#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/user_script/sabnzbd_cleanup.sh"
fixture=$(mktemp -d /tmp/sab-native-recovery.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
TMP_DIR=$fixture SAB_API_KEY=fixture DRY_RUN=true RECOVERED=0
calls="$fixture/calls"; : >"$calls"
log() { :; }; check_mover_guard() { return 0; }; notify_summary() { return 0; }
date() { printf "1000\n"; }
phase=before; orphan_stays=false
sab_get() {
 printf '%s\n' "$*" >>"$calls"
 case "$1:$3" in
  status:name=add_orphan) phase=after; printf '{"status":true}' >"$2";;
  status:*) if [[ "$phase" == before || "$orphan_stays" == true ]]; then printf '{"status":{"folders":["exact-job"]}}' >"$2"; else printf '{"status":{"folders":[]}}' >"$2"; fi;;
  queue:*) printf '{"queue":{"slots":[{"filename":"exact-job","nzo_id":"new-id","time_added":1000}]}}' >"$2";;
  history:*) printf '{"history":{"slots":[]}}' >"$2";;
 esac
}
recover_sab_orphan exact-job
! grep -q add_orphan "$calls"
if recover_sab_orphan ../unsafe; then exit 1; fi
if recover_sab_orphan unknown-job; then exit 1; fi
DRY_RUN=false
recover_sab_orphan exact-job
[[ "$RECOVERED" == 1 ]]
phase=before; orphan_stays=true
if recover_sab_orphan exact-job; then exit 1; fi
[[ $(grep -c add_orphan "$calls") == 2 ]]
printf 'Native orphan retry preview, exact identity, traversal refusal and read-back checks passed\n'
