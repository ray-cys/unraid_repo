#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/backup-capabilities.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
export root fixture
for script in vault_backup remote_backup; do
SCRIPT_UNDER_TEST=$script bash <<'FIXTURE'
set -euo pipefail
source "$root/user_script/$SCRIPT_UNDER_TEST.sh"
LOG_FILE="$fixture/$SCRIPT_UNDER_TEST.log"
# Large version output reliably triggers SIGPIPE when an early-exiting reader
# closes its pipe. awk must consume the full stream before deciding support.
TEST_RSYNC_VERSION=3.5.2
rsync() { printf 'rsync version %s protocol version 33\n' "$TEST_RSYNC_VERSION"; printf '%100000s\n' ''; }
flock() { :; }
mountpoint() { :; }
export TEST_RSYNC_VERSION
export -f rsync flock mountpoint
backup_ssh() {
  if [[ "$*" == *boot_id* ]]; then printf 'fixture-remote-boot\n'; else bash -s; fi
}
backup_capabilities >"$fixture/capabilities.out"
grep -q 'version 3.5.2' "$LOG_FILE"
TEST_RSYNC_VERSION=3.0.0
if backup_capabilities >/dev/null; then echo 'Unsupported rsync accepted' >&2; exit 1; fi
TEST_RSYNC_VERSION=3.5.2
backup_ssh() { return 255; }
if backup_capabilities >/dev/null; then echo 'Unavailable ISS accepted' >&2; exit 1; fi
printf '%s capability checks passed\n' "$SCRIPT_UNDER_TEST"
FIXTURE
done
