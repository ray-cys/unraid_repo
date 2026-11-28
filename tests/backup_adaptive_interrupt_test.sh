#!/usr/bin/env bash
# Native Linux process ownership/cleanup fixture; no SSH, disks or production state.
# shellcheck disable=SC2034
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/user_script/backup_media_remote.sh"
fixture=$(mktemp -d)
outsider=''
finish(){ [[ -z "$outsider" ]] || { kill "$outsider" 2>/dev/null || true;wait "$outsider" 2>/dev/null || true; };rm -rf "$fixture"; }
trap finish EXIT
ba_log(){ :; }
BA_ROOT=$fixture BA_ACTIVE=true BA_REMOTE_READY=false
sleep 30 & outsider=$!
# This worker has a real descendant. Cleanup must stop both, leave the outsider.
(
 trap 'exit 143' TERM
 sleep 30 & child=$!
 printf '%s\n' "$child" >"$fixture/child"
 wait "$child"
) &
worker=$!;BA_PIDS[0]=$worker;BA_STAMPS[0]=$(ba_stamp "$worker")
for ((i=0;i<30;i++));do [[ ! -s "$fixture/child" ]] || break;sleep 0.1;done
child=$(cat "$fixture/child");child_stamp=$(ba_stamp "$child")
ba_cleanup
! ba_alive "$worker" "${BA_STAMPS[0]:-gone}"
# Reparented zombies have stopped executing; /proc may persist until init reaps.
if [[ -r /proc/$child/stat ]];then [[ $(awk '{print $3}' "/proc/$child/stat") == Z ]];fi
kill -0 "$outsider"
[[ ${#BA_PIDS[@]} == 0 && $BA_ACTIVE == false ]]
# Reused/mismatched identity is never accepted for a signal or priority change.
if ba_alive "$outsider" 0;then exit 1;fi
printf 'Interrupted worker and descendant stopped; unrelated process and PID identity safeguards preserved\n'
