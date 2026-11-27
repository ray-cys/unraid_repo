#!/bin/bash
# shellcheck disable=SC2034,SC2120
# Isolated fixtures: no live API, Docker action or notification.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d /tmp/unraid-monitor-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
(
 source "$repo/user_script/docker_service_watchdog.sh"
 findings="$tmp/vpn-findings"; : >"$findings"
 log() { :; }
 vpn_finding() { printf '%s\n' "$1" >>"$findings"; }
 mock_binding=tailscale0; mock_exit=true; mock_canary=true; mock_fail=false; mock_dns=45.83.223.233
 collect_vpn_evidence() {
  case "$2" in
   status) printf '{"BackendState":"Running","ExitNodeStatus":{"ID":"n4voE47CNTRL","Online":%s}}' "$mock_exit" ;;
   prefs) printf '{"WantRunning":true,"ExitNodeID":"n4voE47CNTRL"}' ;;
   binding) printf '%s\n' "$mock_binding" ;;
   dns) printf '%s\n' "$mock_dns" ;;
   route4|route6) printf '[{"dev":"tailscale0"}]' ;;
   canary*) [[ "$mock_fail" != true ]] || return 1; printf '{"mullvad_exit_ip":%s}' "$mock_canary" ;;
  esac
 }
 check_vpn_egress qbittorrent; [[ ! -s "$findings" ]]
 mock_binding=eth0; check_vpn_egress qbittorrent; grep -q vpn-binding "$findings"
 : >"$findings"; mock_exit=false; check_vpn_egress qbittorrent; grep -q vpn-exit "$findings"
 : >"$findings"; mock_exit=true; mock_binding=tailscale0; mock_canary=false
 check_vpn_egress qbittorrent; grep -q vpn-egress4 "$findings"; grep -q vpn-egress6 "$findings"
 : >"$findings"; mock_fail=true; check_vpn_egress qbittorrent; grep -q vpn-egress4 "$findings"
 : >"$findings"; mock_dns=0.0.0.0; check_vpn_egress qbittorrent; grep -q vpn-canary-dns "$findings"
)
(
 source "$repo/user_script/host_health_watchdog.sh"
 STATE_DIR="$tmp/syslog"; mkdir -p "$STATE_DIR"
 # Every derived path must stay inside this fixture, including the incident
 # ledger now that real Unraid can have a mounted vault during native tests.
 SYSLOG_INCIDENT_ROOT="$tmp/syslog-incidents";SYSLOG_VAULT_MOUNT="$tmp/nonexistent-mount"
 CURSOR_FILE="$STATE_DIR/cursor";USAGE_ALERT_FILE="$STATE_DIR/usage_alerted"
 XFS_INCIDENT_FILE="$STATE_DIR/xfs_faults.tsv";LOCK_FILE="$tmp/host-watchdog.lock"
 HH_RAM_ROOT="$tmp/host-runtime";HH_MIRROR="$tmp/host-mirror.json"
 cat >"$tmp/syslog.input" <<'LINES'
Nov 23 10:00:01 Hubble kernel: Out of memory: Killed process 1234 (kometa)
Nov 23 10:00:02 Hubble kernel: Out of memory: Killed process 9876 (kometa)
Nov 23 10:00:03 Hubble monitor: errors=0 failures=0
Nov 23 10:00:04 Hubble kernel: NETDEV WATCHDOG: eth0 transmit queue timed out
Nov 23 10:00:05 Hubble kernel: INFO: task python:123 blocked for more than 120 seconds.
Nov 23 10:00:06 Hubble kernel: oom-kill: failures=0
LINES
 filter_matching_errors "$tmp/syslog.input" "$tmp/syslog.matches"
 [[ $(wc -l <"$tmp/syslog.matches") == 4 ]]
 mv "$INCIDENT_NEXT" "$STATE_DIR/incidents.tsv"
 filter_matching_errors "$tmp/syslog.input" "$tmp/syslog.matches"
 [[ ! -s "$tmp/syslog.matches" ]]
 rm "$STATE_DIR/incidents.tsv"
 build_new_syslog_chunk() { cp "$tmp/syslog.input" "$1"; }
 notify_unraid() { return 1; }
 write_cursor() { touch "$tmp/cursor-should-not-exist"; }
 MAX_NOTIFY_LINES=20; log() { :; }
 if check_syslog_errors; then exit 1; fi
 [[ ! -e "$tmp/cursor-should-not-exist" && ! -e "$STATE_DIR/incidents.tsv" ]]
)
(
 # shellcheck disable=SC1090
 source <(awk '/^# LOCK$/{exit} {print}' "$repo/user_script/media_health_monitor.sh")
 trap - EXIT INT TERM HUP
 TMP_DIR="$tmp"; mkdir -p "$tmp/payload"
 printf 'media' >"$tmp/payload/episode.mkv"
 printf 'sub' >"$tmp/payload/episode.srt"
 ln -s "$tmp/payload/episode.mkv" "$tmp/payload/linked.mkv"
 stats=$(analyze_sab_path "$tmp/payload")
 jq -e '.totalFiles==2 and .totalBytes==8 and .mediaFiles==1 and .metadataFiles==1' <<<"$stats" >/dev/null
 timeout() { return 124; }
 if analyze_sab_path "$tmp/payload"; then exit 1; fi
 # A completed 25-record audit spans two runs. Only inspected identities may
 # resolve; matching titles are never sufficient evidence.
 STATE_FILE="$tmp/arr-state.json"; printf '{"monitor":{},"issues":{}}' >"$STATE_FILE"
 SAB_ENABLED=true; SAB_SCAN_OK=true; SAB_FILESYSTEM_SCAN_OK=true
 SAB_HISTORY_OK=true; SONARR_QUEUE_OK=true; RADARR_QUEUE_OK=true; SONARR_SCAN_OK=true
 START_TIME=1000000; SAB_TV_CATEGORY=tv; SAB_MOVIE_CATEGORY=movies
 SAB_HISTORY="$tmp/sab-history.json"; printf '{"history":{"slots":[{}]}}' >"$SAB_HISTORY"
 jq -n '[range(1;26) | {nzo_id:("job"+(.|tostring)),name:"Same title",category:"tv",status:"Completed",auditEpoch:1}]' >"$tmp/sab-normalized-history.json"
 prepare_sab_history_index() { :; }
 runtime_budget_allows_optional_phase() { return 0; }
 sab_category_owner() { printf Sonarr; }
 sab_category_root() { printf /tmp; }
 arr_tracks_download() { return 0; }
 save_state() { cp "$1" "$STATE_FILE"; }
 log() { :; }
 SAB_FILESYSTEM_BATCH_ITEMS=20; SAB_FILESYSTEM_BATCH_SECONDS=60
 process_sab_orphans
 [[ $(wc -l <"$tmp/sab-filesystem-checked-keys") == 40 ]]
 [[ -n $(jq -r '.monitor.sabFilesystemCursor' "$STATE_FILE") ]]
 ! source_can_resolve SABnzbd SAB:job9
 process_sab_orphans
 [[ $(wc -l <"$tmp/sab-filesystem-checked-keys") == 10 ]]
 [[ -z $(jq -r '.monitor.sabFilesystemCursor' "$STATE_FILE") ]]
 source_can_resolve SABnzbd SAB:job9
 # Presentation grouping preserves every Ack ID and per-record delivery mark.
 jq -nc '{issueKey:"first",signature:"a",source:"Sonarr",title:"Same title",classification:"DOWNLOAD_FLOW_REVIEW_REQUIRED",severity:"WARNING",event:"new",age:1,ackId:"ack-first",detail:"Download ID: first"}, {issueKey:"second",signature:"b",source:"Sonarr",title:"Same title",classification:"DOWNLOAD_FLOW_REVIEW_REQUIRED",severity:"WARNING",event:"new",age:2,ackId:"ack-second",detail:"Download ID: second"}' >"$tmp/page.jsonl"
 notify() { printf '%s' "$3" >"$tmp/email.txt"; }
 mark_notified() { printf '%s\n' "$1" >>"$tmp/delivered"; }
 runtime() { printf 0s; }
 send_notification_page "$tmp/page.jsonl" 1 1 2
 grep -q 'Related records: 2' "$tmp/email.txt"
 grep -q ack-first "$tmp/email.txt"; grep -q ack-second "$tmp/email.txt"
 [[ $(wc -l <"$tmp/delivered") == 2 ]]
)
printf 'VPN binding/exit/canary, syslog dedup/retry, bounded file traversal checks passed\n'
