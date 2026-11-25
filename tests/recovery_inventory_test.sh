#!/usr/bin/env bash
# Isolated read-only Docker/control-plane fixtures; never contacts a real daemon.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/recovery-inventory.XXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
TEST_ROOT=$(realpath "$TEST_ROOT")
export ROOT TEST_ROOT
bash <<'CAPTURE'
set -euo pipefail
source "$ROOT/user_script/backup_vault_remote.sh"
RECOVERY_BOOT_ROOT="$TEST_ROOT/boot"; LOG_FILE="$TEST_ROOT/capture.log"
BACKUP_JOBS=("photos|/mnt/vault/cloud/photos")
mkdir -p "$RECOVERY_BOOT_ROOT/config/plugins/user.scripts/scripts/example"
printf 'DOCKER_ENABLED="yes"\n' >"$RECOVERY_BOOT_ROOT/config/docker.cfg"
printf '#!/bin/bash\nprintf hello\n' >"$RECOVERY_BOOT_ROOT/config/plugins/user.scripts/scripts/example/script"
printf '{"job":{"script":"/boot/config/plugins/user.scripts/scripts/example/script","frequency":"daily"}}' >"$RECOVERY_BOOT_ROOT/config/plugins/user.scripts/schedule.json"
printf '0 7 * * 0 true\n' >"$RECOVERY_BOOT_ROOT/config/plugins/user.scripts/media_integrity_audit_sunday.cron"
recovery_docker() {
    case "$*" in
        'ps -aq --no-trunc') printf 'aaaaaaaaaaaa\n';;
        'inspect aaaaaaaaaaaa') printf '[{"Id":"aaaaaaaaaaaa","Name":"/fixture","Image":"sha256:abc","Mounts":[{"Type":"bind","Source":"/mnt/vault/cloud/photos2","Destination":"/photos","RW":true},{"Type":"volume","Source":"/var/lib/docker/volumes/test/_data","Destination":"/data","RW":true}]}]';;
        'image inspect sha256:abc') printf '[{"Id":"sha256:abc","RepoDigests":["example@sha256:abc"]}]';;
        'network ls -q'|'volume ls -q') :;;
        *) printf 'Unexpected Docker mutation or command: %s\n' "$*" >&2; return 1;;
    esac
}
vault_capture_recovery "$TEST_ROOT/recovery"
[[ -s "$TEST_ROOT/recovery/boot-config/config/plugins/user.scripts/media_integrity_audit_sunday.cron" ]]
jq -e '.runtimeStatus=="complete" and .containerCount==1 and .namedVolumeMounts==1' "$TEST_ROOT/recovery/inventory.json" >/dev/null
jq -e '.[0].matchingConfiguredSources==[] and (.[1].payloadStatus|startswith("named-volume"))' "$TEST_ROOT/recovery/coverage.json" >/dev/null
[[ "$RECOVERY_CAPTURE_WARNING" == true ]]
[[ $(stat -c %a "$TEST_ROOT/recovery") == 700 ]]
(cd "$TEST_ROOT/recovery" && sha256sum -c SHA256SUMS >/dev/null)
recovery_docker() { return 1; }
vault_capture_recovery "$TEST_ROOT/unavailable"
jq -e '.runtimeStatus=="unavailable"' "$TEST_ROOT/unavailable/inventory.json" >/dev/null
printf 'Capture, private permissions, exact path boundaries, named-volume gaps and unavailable Docker passed\n'
CAPTURE
bash <<'DRILL'
set -euo pipefail
source "$ROOT/user_script/backup_restore_drill.sh"
WORK_DIR="$TEST_ROOT/drill"; LOG_FILE="$TEST_ROOT/drill.log"; mkdir "$WORK_DIR"
GENERATION_ROOT=""; RECOVERY_BUNDLE_ROOT="$TEST_ROOT/recovery"
drill_recovery_bundle
[[ "$CONTROL_SCRIPTS_CHECKED" == 1 && "$DRILL_WARNINGS" -ge 1 ]]
printf 'tampered' >>"$RECOVERY_BUNDLE_ROOT/containers.json"
if drill_recovery_bundle; then printf 'Tampering was accepted\n' >&2; exit 1; fi
printf 'Recovery checksum tampering rejected; copied script and schedule checked\n'
# Invalid shell syntax is rejected without executing the fixture.
printf '#!/bin/bash\nif then\n' >"$RECOVERY_BUNDLE_ROOT/boot-config/config/plugins/user.scripts/scripts/example/script"
if drill_control_plane "$RECOVERY_BUNDLE_ROOT/boot-config/config"; then exit 1; fi
printf 'Broken restored shell syntax rejected\n'
DRILL
bash <<'AUDIT'
set -euo pipefail
source "$ROOT/user_script/backup_health_audit.sh"
RECOVERY_BUNDLE_ROOT="$TEST_ROOT/not-created"
audit_recovery_inventory
[[ ${#FINDINGS[@]} == 0 ]]
RECOVERY_BUNDLE_ROOT="$TEST_ROOT/unavailable"
audit_recovery_inventory
[[ ${#FINDINGS[@]} == 1 && "${FINDINGS[0]}" == *unavailable* ]]
printf 'Audit allows cutover and reports incomplete runtime capture\n'
AUDIT
bash <<'CONTROL'
set -euo pipefail
source "$ROOT/user_script/backup_restore_drill.sh"
WORK_DIR="$TEST_ROOT/control"; mkdir "$WORK_DIR"; LOG_FILE="$WORK_DIR/check.log"
config="$WORK_DIR/config"
mkdir -p "$config/plugins/dockerMan/templates-user" "$config/plugins/user.scripts/scripts/example"
printf 'enabled' >"$config/docker.cfg"
printf '#!/bin/bash\nprintf ok\n' >"$config/plugins/user.scripts/scripts/example/script"
printf '{"job":{"script":"/boot/config/plugins/user.scripts/scripts/example/script","frequency":"daily"}}' >"$config/plugins/user.scripts/schedule.json"
if command -v php >/dev/null; then
    printf '<Container><Name>fixture</Name><Repository>example/image</Repository></Container>' >"$config/plugins/dockerMan/templates-user/fixture.xml"
    drill_control_plane "$config"
    [[ "$CONTROL_TEMPLATES_CHECKED" == 1 && "$CONTROL_SCRIPTS_CHECKED" == 1 && "$DRILL_WARNINGS" == 0 ]]
    printf '<!DOCTYPE Container [<!ENTITY x SYSTEM "file:///etc/passwd">]><Container><Name>&x;</Name></Container>' >"$config/plugins/dockerMan/templates-user/fixture.xml"
    if drill_control_plane "$config"; then exit 1; fi
    rm "$config/plugins/dockerMan/templates-user/fixture.xml"
    printf 'Template XML checked; external-entity template rejected\n'
fi
printf '{"job":{"script":"/boot/config/plugins/user.scripts/scripts/missing/script","frequency":"daily"}}' >"$config/plugins/user.scripts/schedule.json"
if drill_control_plane "$config"; then exit 1; fi
printf 'Missing active scheduled script rejected\n'
CONTROL
