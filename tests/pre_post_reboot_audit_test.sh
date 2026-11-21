#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/reboot_audit_test.XXXXXX)"
trap 'rm -rf -- "${TEST_ROOT:?}"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC1091
source "$ROOT/user_script/pre_post_reboot_audit.sh"
STATE_ROOT="$TEST_ROOT/flash"; BASELINE_DIR="$STATE_ROOT/baseline"
CHECKPOINT_FILE="$STATE_ROOT/completed.json"; DEFERRED_FILE="$STATE_ROOT/deferred.json"
LOG_FILE="$STATE_ROOT/audit.log"; HISTORY_DIR="$TEST_ROOT/vault/history"
REPORT_FILE="$TEST_ROOT/vault/last-compare.txt"; STATUS_DIR="$TEST_ROOT/receipts"
TMP_DIR="$TEST_ROOT/runtime"; mkdir -p "$TMP_DIR" "$STATE_ROOT"
BOOT_CONFIG_ROOT="$TEST_ROOT/config"; UNRAID_VERSION_FILE="$TEST_ROOT/unraid-version"
mkdir -p "$BOOT_CONFIG_ROOT/shares" "$BOOT_CONFIG_ROOT/plugins/dockerMan/templates-user"
printf 'version="7.4.0"\n' >"$UNRAID_VERSION_FILE"
printf 'shareUseCache="yes"\n' >"$BOOT_CONFIG_ROOT/shares/media.cfg"
printf '<Container/>\n' >"$BOOT_CONFIG_ROOT/plugins/dockerMan/templates-user/plex.xml"
printf '<!ENTITY version "1.0">\n' >"$BOOT_CONFIG_ROOT/plugins/fixture.plg"
NOTIFY_BIN="$TEST_ROOT/notify"
printf '#!/bin/sh\nprintf "sent\\n" >>"%s/notifications"\n' "$TEST_ROOT" >"$NOTIFY_BIN"
chmod 755 "$NOTIFY_BIN"
stat() { if command -v gstat >/dev/null; then gstat "$@"; else command stat "$@"; fi; }
sort() { if command -v gsort >/dev/null; then gsort "$@"; else command sort "$@"; fi; }
date() { if command -v gdate >/dev/null; then gdate "$@"; else command date "$@"; fi; }
MOCK_READY=true; MOCK_CAPTURE_FAIL=false; MOCK_SERIAL=SERIAL-1; MOCK_DEVICE=sda
mountpoint() { [[ "$MOCK_READY" == true ]]; }
sleep() { :; }
WAIT_FOR_ARRAY_SECONDS=0; POST_ARRAY_SETTLE_SECONDS=0
CURRENT_BOOT_ID="boot-before"
bounded() {
    local command="$1"; shift
    case "$command" in
        lsblk)
            [[ "$MOCK_CAPTURE_FAIL" != true ]] || return 1
            jq -nc --arg serial "$MOCK_SERIAL" --arg name "$MOCK_DEVICE" \
                '{blockdevices:[{name:$name,type:"disk",serial:$serial,wwn:"",size:500000,model:"Fixture"}]}' ;;
        mdcmd) printf 'mdState=STARTED\ndiskId.1=SERIAL-1\ndiskSize.1=500000\ndiskName.1=%s\n' "$MOCK_DEVICE" ;;
        docker)
            case "$1" in
                info) : ;;
                ps) printf 'plex-media-server\n' ;;
                inspect) printf '[{"Name":"/plex-media-server","Config":{"Image":"plex:latest"},"Image":"sha256:fixture"}]\n' ;;
                image) printf '[{"Id":"sha256:fixture","RepoDigests":["plex@sha256:fixture"]}]\n' ;;
                *) return 1 ;;
            esac ;;
        ip)
            if [[ "$2" == address ]]; then printf '[{"ifname":"eth0","addr_info":[{"scope":"global","family":"inet","local":"192.168.50.4","prefixlen":24}]}]\n'
            else printf '[{"dst":"default","gateway":"192.168.50.1","dev":"eth0"}]\n'; fi ;;
        findmnt) printf '{"filesystems":[{"target":"/mnt/vault","source":"/dev/sdb1","fstype":"xfs","uuid":"stable-uuid"}]}\n' ;;
        virsh)
            case "$1" in list) printf 'fixture-vm-uuid\n';; dumpxml) printf '<domain><name>fixture</name><uuid>fixture-vm-uuid</uuid></domain>\n';; esac ;;
        *) "$command" "$@" ;;
    esac
}
reset_comparison() { CRITICAL_CHANGES=0; WARNING_CHANGES=0; INFO_CHANGES=0; RESULT_STATUS=FAILED; }

capture_baseline || fail 'valid baseline capture failed'
inventory_valid "$BASELINE_DIR" || fail 'baseline checksum validation failed'
grep -Fq 'fixture.plg|1.0|' "$BASELINE_DIR/plugins" || fail 'plugin version not captured'
grep -Fq 'SERIAL-1' "$BASELINE_DIR/block_devices" || fail 'disk identity not captured'
grep -Fq 'sha256:fixture' "$BASELINE_DIR/images" || fail 'image identity not captured'
before="$(sha256sum "$BASELINE_DIR/metadata.json")"
MOCK_CAPTURE_FAIL=true
if capture_baseline; then fail 'incomplete capture replaced baseline'; fi
[[ "$(sha256sum "$BASELINE_DIR/metadata.json")" == "$before" ]] || fail 'failed capture damaged baseline'
MOCK_CAPTURE_FAIL=false

# Linux enumeration changes must not be interpreted as missing physical disks.
CURRENT_BOOT_ID="boot-after"; MOCK_DEVICE=sdz
reset_comparison; compare_after_reboot || fail 'stable reboot audit failed'
[[ "$RESULT_STATUS" == OK && ! -e "$TEST_ROOT/notifications" ]] || fail 'clean reboot was noisy'
[[ -f "$CHECKPOINT_FILE" ]] || fail 'comparison checkpoint missing'
reset_comparison; compare_after_reboot || fail 'repeat comparison failed'
[[ "$RESULT_SUMMARY" == *'already completed'* ]] || fail 'same reboot not deduplicated'

# A genuinely changed serial triggers a critical finding with an actual report.
CURRENT_BOOT_ID="boot-missing"; MOCK_SERIAL=SERIAL-OTHER
reset_comparison
if compare_after_reboot; then fail 'missing disk failed to return error'; fi
[[ "$RESULT_STATUS" == CRITICAL ]] || fail 'missing disk severity incorrect'
grep -Fq 'missing baseline entries' "$REPORT_FILE" || fail 'specific disk difference missing'
[[ "$(wc -l <"$TEST_ROOT/notifications")" -eq 1 ]] || fail 'critical report missing'

# Incomplete startup is deferred without comparing empty inventories. Only one
# deferred email is sent; a later complete comparison reports recovery once.
CURRENT_BOOT_ID="boot-delayed"; MOCK_SERIAL=SERIAL-1; MOCK_READY=false
reset_comparison; compare_after_reboot || fail 'deferred audit failed'
[[ "$RESULT_STATUS" == WARNING && -f "$DEFERRED_FILE" ]] || fail 'readiness not deferred'
reset_comparison; compare_after_reboot || fail 'deferred retry failed'
[[ "$(wc -l <"$TEST_ROOT/notifications")" -eq 2 ]] || fail 'deferred notification repeated'
MOCK_READY=true
reset_comparison; compare_after_reboot || fail 'deferred audit did not recover'
[[ ! -e "$DEFERRED_FILE" && "$RESULT_STATUS" == OK ]] || fail 'deferred state not cleared'
[[ "$(wc -l <"$TEST_ROOT/notifications")" -eq 3 ]] || fail 'deferred recovery notification missing'

# Expected upgrades classify versions as information, while a missing plugin
# still warns. Baseline remains unchanged until an explicit capture.
CURRENT_BOOT_ID="boot-upgrade"; EXPECTED_UPGRADE=true
printf 'version="7.4.1"\n' >"$UNRAID_VERSION_FILE"
printf '<!ENTITY version "2.0">\n' >"$BOOT_CONFIG_ROOT/plugins/fixture.plg"
reset_comparison; compare_after_reboot || fail 'expected upgrade audit failed'
[[ "$RESULT_STATUS" == OK && "$INFO_CHANGES" -ge 2 ]] || fail 'expected upgrade changes not informational'
CURRENT_BOOT_ID="boot-plugin-missing"
rm "$BOOT_CONFIG_ROOT/plugins/fixture.plg"
reset_comparison; compare_after_reboot || fail 'missing plugin audit failed'
[[ "$RESULT_STATUS" == WARNING ]] || fail 'expected upgrade hid missing plugin'
[[ "$(sha256sum "$BASELINE_DIR/metadata.json")" == "$before" ]] || fail 'comparison advanced baseline'

CHECK_VMS=true
# Exercise real canonical XML hashing on the mocked inactive VM definition.
capture_inventory "$TMP_DIR/vm-inventory" || fail 'VM inventory capture failed'
grep -Fq 'fixture-vm-uuid|' "$TMP_DIR/vm-inventory/vm_config" || fail 'canonical VM configuration missing'
printf 'tampered\n' >>"$BASELINE_DIR/shares"
if inventory_valid "$BASELINE_DIR"; then fail 'corrupt baseline accepted'; fi
printf 'pre_post_reboot_audit fixture tests passed\n'
