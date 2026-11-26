# Hubble system update coordinator

`system_update_coordinator.sh` is an active automatic updater for approved Docker
apps and plugins, and a read-only update checker for Unraid OS. It appears under
**Unraid** in User Scripts. It uses the installed native DockerMan/plugin update
helpers, preserves existing image channels and templates, and never installs an
OS release or reboots the server. Existing CA automatic installation schedules
are disabled during deployment so there is only one automatic installer.

## Default policy and schedule

The current rollout approves **all 17 installed Docker apps** (including both
Plex instances, Pi-hole, the VPN-backed qBittorrent app, PhotoPrism, Arr apps and
scheduled media jobs), and **all 11 installed plugins** (including Tailscale,
GPU tools, Unraid Connect, CA updater and both User Scripts plugins). Unraid OS
remains manual. Approval is bound to the exact installed repository/channel or
plugin source URL; an approval does not switch a develop/nightly channel to stable.
A fresh policy seeds current installations, but later new/reinstalled or changed
identities remain report-only until approved. Removing an item still retires it
automatically without changing the script.

Run every 15 minutes (`*/15 * * * *`). Start installations only between **13:15
and 15:30 Singapore time**, between the 12:00 and 16:00 media batch boundaries.
Stable Docker candidates and plugins must remain unchanged for **24 hours**
from first observation. Docker tags explicitly named `nightly`, `develop` or
`unstable` default to **12 hours**, allowing a daily rebuild to mature before the
next maintenance window. More frequent rebuilds still defer. Per-item holds are
configurable, survive reapproval of the same identity, and appear in the report.
A changed repository gets a fresh approval/hold policy.
Install one item per invocation, with independent rolling 24-hour ceilings of
**six Docker updates and two plugin updates** (eight combined). Dispatched
attempts consume their own application-type budget; one exhausted budget does
not prevent the other type from updating. The maintenance window and all safety
gates still apply, so the ceiling is not a requirement to install eight items. Registry checks remain cached for six hours per item with
four due checks per run and bounded failure backoff. Inventory is published in
bulk to reduce repeated state-file writes.

Normal installation/verification receipts are grouped into **one 15:45 daily
summary**. Failures and attention reports bypass the cutoff. Routine events recorded after
the daily summary wait for the next summary; failed pages of an already sealed
report remain eligible for prompt retries, including across midnight. The report lists
verified updates with previous/new version or digest, pending outcomes, available
updates that were deferred, and unverified checks that require attention.
Successfully checked, up-to-date apps/plugins are omitted. If there are no update
actions, available updates, unknown checks or queued events, the routine report
is suppressed entirely. Unknown/failed checks are never hidden as up to date. Pending normal receipts before the cutoff
are expected, not notification failures in the backup audit.

## Installation and reconciliation

1. Require complete live inventory, identity-bound approval, unchanged eligible
   candidate, available storage, known native interface and recent backup evidence.
2. Defer during Mover, active array operations, related backup/media work or an
   existing native installer. Hold the shared application maintenance gate; the
   Arr/metadata monitors defer rather than reporting planned downtime as failure.
3. Require a running Docker app with strong readiness before updating it. A
   stopped app is never started to install an update. Native Docker health or a
   validated application API establishes readiness; a login/UI page does not.
   Scheduled-job containers additionally validate their scheduler process and
   bounded native completion evidence; readiness does not erase job findings.
4. Check application activity again before dispatch: defer active Plex playback,
   Kometa/ImageMaid/Recyclarr jobs, MetaFusion processing, and SAB download or
   post-processing. Paused/queued SAB work remains eligible. Verify independent
   fallback DNS over UDP/TCP before updating primary Pi-hole. qBittorrent readiness
   includes the approved exit node, interface binding, routing and bound Mullvad
   canary; a working Web UI alone is insufficient. These checks do not modify apps.
5. Archive the previous image and selected configuration/template, or installed
   plugin definition, before dispatch. Images above the configured size limit
   (4 GiB uncompressed by default), or exceeding the bounded archive/time/space
   budget, defer safely. Require 10 GiB vault reserve.
6. Persist an installation intent before calling the native helper once. Read back
   actual version/digest, template/settings and readiness. A 20-minute startup
   readiness grace avoids treating normal warm-up as a failed update; digest or
   configuration mismatches still require attention immediately. Exit zero alone is
   insufficient. A second scheduled observation confirms completion.
7. Interrupted or uncertain work is reconciled without replaying the installer.
   Further updates stop while verification is pending. Watchdog/DNS coordination
   also protects planned host-plugin maintenance; the fallback resolver remains
   independently monitored. A durable update journal also prevents watchdog restarts of the affected Docker app, even after a crash
   or reboot expires its short maintenance lease. Verified completion releases it.
   User Scripts/plugin upgrades must preserve the coordinator cron entry and a
   readable PHP launcher that passes the native syntax check. CA updater
   installations stay disabled even when the CA updater plugin itself is
   upgraded; its regenerated settings/cron are reconciled. Tailscale host status
   is checked before/after its plugin update, and GPU-plugin updates defer active
   Plex sessions. Other plugin features are not automatically certified.

Appdata evidence must be no more than 80 hours old and its producer manifest must
still match. Plugin updates require similarly recent successful boot-backup
metadata and an existing archive. This checks producer evidence rather than
rehashing all backup payloads before every update. Full restore verification is
owned by the restore drill.

Container-specific installed-image evidence prevents a shared Plex tag pull from
making the second, older Plex container look current. If native cleanup strips
image digests, cached evidence is usable only for the exact same image ID,
container ID and repository. Recreated containers cannot inherit it.

Native DockerMan pulls mutable tags. A registry tag can move between the final
check and that pull; the coordinator detects an unexpected installed digest and
holds further work rather than reporting success. Updating can migrate app
state/databases: retaining an image does not guarantee a safe rollback. Recovery
is intentionally manual for incompatible database changes. The two most recent
finished recovery sets are retained **globally across all apps/plugins**, alongside
unresolved evidence; no broad image
pruning or application-data deletion is performed. Native plugin verification
establishes its version/source/manifest and finished installer task, not every
plugin feature's behavior. Manual GUI updates are external writers: avoid starting
one during this coordinator's active installation; process checks cannot make
independent native interfaces transactional.

## What is saved and pruned

Immediately before dispatch, `/mnt/vault/backup/system_updates/JOB_ID/` contains:

| Update type | Recovery evidence |
|---|---|
| Docker | Previous `docker image save` output compressed as `image.tar.gz`, its SHA-256, `template.xml`, selected runtime/configuration JSON, and existing appdata-backup evidence |
| Plugin | Previous `installed.plg`, the proposed `candidate.plg`, and existing boot-backup evidence |

The Docker archive is checked before installation. Plugin recovery is a retained
manifest/installer definition and backup reference; it is **not an independent
archive of every old plugin binary or dependency**. No fresh full appdata/boot
backup is created for every update. Existing producer backups are required.

After verified completion, owned recovery sets beyond the two newest finished
sets are pruned on subsequent coordinator processing. This is two sets in total,
not per app or per type. Pending/uncertain sets stay protected; unrecognized or
unowned paths are preserved. A preparation failure before installer dispatch can
clean its own known partial archive because the installed app was never changed.

Unraid's native Docker updater attempts to remove the superseded local image
when its image ID changes. The separate vault archive survives that local image
cleanup until its recovery-set retention expires. The coordinator never runs
`docker image prune`/`docker system prune`, uninstalls current plugins, or broadly
cleans plugin package caches. Native plugin installation replaces its active
plugin definition; cached-package cleanup remains specific to Unraid/the plugin.

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
/bin/bash "$updater" --limits 6 2 24
/bin/bash "$updater" --hold docker kometa 12
/bin/bash "$updater" --archive-limit 4
/bin/bash "$updater" --report-time 15:45
/bin/bash "$updater" --report-preview
/bin/bash "$updater" --allow-installed
```

`--limits DOCKER PLUGINS HOLD_H` sets **independent** ceilings: 1–12 Docker
updates, 0–4 plugin updates per rolling 24 hours, and a 1–168 hour default hold.
For example, `--limits 6 2 24` allows six Docker updates plus two plugins; its
combined ceiling is derived as eight. Older saved policies without `dailyDocker`
retain their previous combined ceiling until the CLI explicitly changes it. One update/run remains fixed.
`--check-only` never installs, but still reconciles pending work and sends queued
reports. Pausing stops new installation, not checks or reconciliation. Only the OS is excluded. `--allow-installed` explicitly approves
current identities;
it is not a wildcard for future installations. `--report-preview` prints the saved
report without registry checks, installation or notification. `--archive-limit`
accepts 1–8 GiB and retains the 10 GiB vault reserve. `--hold docker|plugin NAME
HOURS` overrides one installed identity (1–168 hours); `--limits` changes the
default hold without replacing explicit per-item holds. `--report-time` uses Singapore
time and should remain after the maintenance window.

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
plus two rotations; rotations expire after 30 days. Routine checks do not email
between daily summaries. Actual actions and current/deferred statuses are included
in the daily report, with urgent attention sent immediately. Large reports use
bounded UTF-8 pages without dropping records; accepted pages are acknowledged
individually and any remainder is retained. Delivery failure cannot silently clear
queued actions. A retry can produce a duplicate if external delivery succeeded but
its local acknowledgement could not be saved; no exactly-once claim is made.

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


Update-outcome verification treats Docker's bind-mount list as an unordered
multiset of exact mappings. Reordering does not change configuration; changed
paths, read/write options, duplicate counts, template checksums, environment,
network, memory and all other saved settings remain strictly checked. Original
snapshots are retained. Each job records the failed verification gate and a
specific operational reason instead of one generic outcome warning.

An earlier `ATTENTION` clears only after the approved installed digest, recreated
container, retained settings and readiness pass the existing two observations.
Recovery is reported explicitly; no reinstall or database rollback is performed.
Startup/attention events delivered after verification are labelled historical,
with the current verified time. Urgent delivery includes only attention/recovery
items; unrelated routine retirement/startup records retain normal daily delivery.

For a deliberate outcome-only recheck, run:

```bash
/bin/bash /boot/config/plugins/user.scripts/scripts/system_update_coordinator/script --reconcile-only
```

This inspects existing jobs and delivers eligible events; it never starts an
installer, refreshes update candidates or prunes recovery evidence. Allow the next
scheduled reconciliation to supply the second observation. Do not delete an
uncertain job or retry its installer to silence a verification warning.

The final operational line lists all available candidates and every unfinished
verification, rather than only the last app examined. Changed per-app holds also
appear in the local log; unchanged holds are not logged repeatedly. `media_pipeline`
is an internal dependency group for Arr, download and subtitle services, not a
Docker network or an indication that a media scan is running. A verified finished
installer with an unresolved app outcome holds its group; an unfinished installer
or uncertain plugin outcome holds all installations. Discovery continues through
these holds.

After verified installation, only the matching cached candidate is marked current
and prioritized for another native registry check. A newer candidate observed
during startup verification remains queued. Normal registry checks are bounded
and staggered with a six-hour per-item interval; a newer Docker-tab result can
therefore precede the next normal coordinator check. `--check-only --refresh`
requests a bounded full refresh without installation or resetting the observation
age of unchanged candidate digests.
