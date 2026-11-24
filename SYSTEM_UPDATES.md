# Hubble system update coordinator

`system_update_coordinator.sh` is an active automatic updater for approved Docker
apps and plugins, and a read-only update checker for Unraid OS. It appears under
**Unraid** in User Scripts. It uses the installed native DockerMan/plugin update
helpers, preserves existing image channels and templates, and never installs an
OS release or reboots the server. Existing CA automatic installation schedules
are disabled during deployment so there is only one automatic installer.

## Default policy and schedule

The first policy seeds the currently installed identities of Prowlarr, Bazarr,
Tautulli, Seerr and Lumunarr for Docker updates, and Community Applications, Fix
Common Problems and Dynamix System Information for plugin updates. All other
installed items remain report-only. This includes Plex, DNS/VPN apps, Arr develop,
SAB unstable, Kometa nightly, ImageMaid develop and MetaFusion develop channels.
Names do not grant future installations permission: approval is bound to the exact
installed repository/channel or plugin source URL.

Run every half hour (`15,45 * * * *`). Automatic installation is enabled from
rollout; its normal safeguards still apply. New installations start only between
13:15 and 15:30 Singapore time. A candidate must remain unchanged for 24 hours
from the coordinator's first observation, not its registry publication time.
There is one installation per invocation, at most two in a rolling 24 hours, with
at most one plugin installation. Registry checks are staggered (four per run,
six-hour per-item cache and bounded failure backoff). A newly discovered item may
therefore take several runs to receive its first registry check.

## Installation and reconciliation

1. Require complete live inventory, identity-bound approval, unchanged eligible
   candidate, available storage, known native interface and recent backup evidence.
2. Defer during Mover, active array operations, related backup/media work or an
   existing native installer. Hold the shared application maintenance gate; the
   Arr/metadata monitors defer rather than reporting planned downtime as failure.
3. Require a running Docker app with strong readiness before updating it. A
   stopped app is never started to install an update. Native Docker health or a
   validated application API establishes readiness; a login/UI page does not.
4. Archive the previous image and selected configuration/template, or installed
   plugin definition, before dispatch. Images above 2 GiB uncompressed or exceeding
   the bounded archive/time/space budget defer safely. Require 10 GiB vault reserve.
5. Persist an installation intent before calling the native helper once. Read back
   actual version/digest, template/settings and readiness. A 20-minute startup
   readiness grace avoids treating normal warm-up as a failed update; digest or
   configuration mismatches still require attention immediately. Exit zero alone is
   insufficient. A second scheduled observation confirms completion.
6. Interrupted or uncertain work is reconciled without replaying the installer.
   Further updates stop while verification is pending. A durable update journal
   also prevents watchdog restarts of the affected Docker app, even after a crash
   or reboot expires its short maintenance lease. Verified completion releases it.

Appdata evidence must be no more than 80 hours old and its producer manifest must
still match. Plugin updates require similarly recent successful boot-backup
metadata and an existing archive. This checks producer evidence rather than
rehashing all backup payloads before every update. Full restore verification is
owned by the restore drill.

Native DockerMan pulls mutable tags. A registry tag can move between the final
check and that pull; the coordinator detects an unexpected installed digest and
holds further work rather than reporting success. Updating can migrate app
state/databases: retaining an image does not guarantee a safe rollback. Recovery
is intentionally manual for incompatible database changes. The two most recent
finished recovery sets are retained alongside unresolved evidence; no broad image
pruning or application-data deletion is performed. Native plugin verification
establishes its version/source/manifest and finished installer task, not every
plugin feature's behavior. Manual GUI updates are external writers: avoid starting
one during this coordinator's active installation; process checks cannot make
independent native interfaces transactional.

## Retirement and policy changes without script edits

Removing a container/plugin is detected from two complete inventories. Its active
update entry and approval retire automatically. Stopped containers remain installed
and monitored according to their existing watchdog policy. Docker daemon failure
or partial inventory cannot retire services. Reinstalling a retired item, changing
its repository/source, or adding a new item requires a fresh approval; no wildcard
permission is inherited. The watchdog keeps known profiles in code but activates
only installed services, retires their old alerts without claiming recovery, and
reactivates known profiles when reinstalled. Unknown apps receive discovery
coverage without automatically granting restart permission.

Use `/bin/bash` to run the installed script; executable permission is unnecessary:

```bash
updater=/boot/config/plugins/user.scripts/scripts/system_update_coordinator/script
/bin/bash "$updater" --status
/bin/bash "$updater" --check-only
/bin/bash "$updater" --allow docker prowlarr
/bin/bash "$updater" --deny docker prowlarr
/bin/bash "$updater" --allow plugin community.applications.plg
/bin/bash "$updater" --pause
/bin/bash "$updater" --resume
/bin/bash "$updater" --window 13:15 15:30
/bin/bash "$updater" --limits 2 1 24
```

`--limits TOTAL PLUGINS HOLD_H` accepts 1–5 total updates/day, 0–2 plugins/day
(no more than total), and a 1–168 hour candidate hold. One update/run remains fixed.
`--check-only` never installs, but still reconciles pending work and sends queued
reports. Pausing stops new installation, not checks or reconciliation. OS,
CA updater and User Scripts plugins cannot be approved by this coordinator.

After independently reviewing/recovering an uncertain installation:

```bash
/bin/bash "$updater" --resolve JOB_ID 'Reviewed actual app state and recovery evidence'
```

This closes the hold without claiming successful recovery or running any restore.
It does not retry the same failed candidate. A new candidate can be considered
through normal checks. Do not dismiss an uncertain job while its native installer
or application recovery is still running.

## Operational reporting and persistence

Logs use the same operations contract as the other User Scripts: timestamp,
severity, script, run, phase and action/evidence. The local log is capped at 2 MiB
plus two rotations; rotations expire after 30 days. Healthy checks do not email.
Actual installs, verification/reconciliation and attention findings are grouped per
run with action details and recovery location. Availability review is weekly.
Failed notification delivery retains its exact queued events for retry.

State/policy/logs live in
`/mnt/vault/cloud/logs/script/system_update_coordinator`; recovery sets live in
`/mnt/vault/backup/system_updates`. State and policy join the vault operations-state
export and boot-configuration recovery inventory. The hourly backup audit checks
scheduled-run freshness; merely calling `--status` cannot fake its heartbeat.
Existing User Scripts descriptions, unrelated schedules and categories remain
unchanged during deployment.

The adapter validates the installed Unraid 7 native interfaces. Unknown major OS
versions or changed helper contracts stop new installations. This is a controlled
compatibility boundary, not a guarantee that future Unraid or application versions
will never require maintenance. `tools/system_update_native.php` is the reviewed
read-only adapter; `python3 tools/sync_update_adapter.py` embeds its exact contents
into the standalone script. No Python installation is needed on Hubble.
