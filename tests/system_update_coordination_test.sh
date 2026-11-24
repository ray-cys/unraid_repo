#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/update-coordination.XXXXXX);trap 'rm -rf -- "$fixture"' EXIT
export repo fixture
bash <<'CA'
set -euo pipefail
source "$repo/user_script/system_update_coordinator.sh"
CA_SETTINGS_ROOT="$fixture/ca";USER_SCRIPTS_ROOT="$fixture/scripts";mkdir -p "$CA_SETTINGS_ROOT" "$USER_SCRIPTS_ROOT/scripts/system_update_coordinator"
printf '#!/bin/bash\n' >"$USER_SCRIPTS_ROOT/scripts/system_update_coordinator/script"
printf '{"/boot/config/plugins/user.scripts/scripts/system_update_coordinator/script":{"frequency":"custom"}}' >"$USER_SCRIPTS_ROOT/schedule.json"
printf '{"cron":{"dockerCronFrequency":"Custom"},"global":{"dockerUpdateAll":"yes","keep":"retained"}}' >"$CA_SETTINGS_ROOT/DockerUpdateSettings.json"
printf '{"cron":{"pluginCronFrequency":"Weekly"},"Global":"true","keep":"retained"}' >"$CA_SETTINGS_ROOT/AutoUpdateSettings.json"
printf '0 7 * * * old-docker-updater\n' >"$CA_SETTINGS_ROOT/docker_update.cron"
printf '0 8 * * * old-plugin-updater\n' >"$CA_SETTINGS_ROOT/plugin_update.cron"
USER_SCRIPTS_LAUNCHER="$fixture/launcher.php";printf '<?php\n' >"$USER_SCRIPTS_LAUNCHER"
calls=0;update_cron(){ calls=$((calls+1)); }
bounded(){
  if [[ "$1 $2" == '8 php' ]];then [[ -r "$4" ]];return $?;fi
  [[ "$1 $2" == '8 crontab' ]] || return 1
  if [[ "${missing:-false}" == false ]];then printf '*/15 * * * * /usr/local/emhttp/plugins/user.scripts/startCustom.php /boot/config/plugins/user.scripts/scripts/system_update_coordinator/script\n'
  else printf '# missing coordinator\n';fi
}
enforce_single_installer
jq -e '.cron.dockerCronFrequency=="disabled" and .global.dockerUpdateAll=="no" and .global.keep=="retained"' "$CA_SETTINGS_ROOT/DockerUpdateSettings.json" >/dev/null
jq -e '.cron.pluginCronFrequency=="disabled" and .Global=="false" and .keep=="retained"' "$CA_SETTINGS_ROOT/AutoUpdateSettings.json" >/dev/null
[[ "$calls" == 1 ]]
enforce_single_installer;[[ "$calls" == 1 ]]
missing=true
if enforce_single_installer;then exit 1;fi
printf 'Plugin self-update preserves coordinator scheduling, prevents overlapping installers and avoids unchanged settings writes\n'
CA
bash <<'DNS'
set -euo pipefail
source "$repo/user_script/dns_redundancy_watchdog.sh"
MAINTENANCE_DIR="$fixture/maintenance";mkdir "$MAINTENANCE_DIR"
UPDATE_COORDINATOR_STATE_FILE="$fixture/journal.json";PRIMARY_IN_MAINTENANCE=false
printf '{"schema":1,"jobs":{"plugin":{"kind":"plugin","name":"tailscale.plg","status":"INTENT"}}}' >"$UPDATE_COORDINATOR_STATE_FILE"
maintenance_active primary
if maintenance_active fallback;then exit 1;fi
printf '{"schema":1,"jobs":{"plugin":{"kind":"plugin","name":"tailscale.plg","status":"VERIFYING"}}}' >"$UPDATE_COORDINATOR_STATE_FILE"
if maintenance_active primary;then exit 1;fi
printf '{"schema":1,"jobs":{"dns":{"kind":"docker","name":"pihole","status":"VERIFYING"}}}' >"$UPDATE_COORDINATOR_STATE_FILE"
maintenance_active primary
printf 'Planned plugin/Pi-hole maintenance protects primary DNS; fallback monitoring remains independent\n'
DNS
