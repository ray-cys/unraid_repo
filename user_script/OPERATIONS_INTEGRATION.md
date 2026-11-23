# Hubble User Scripts integration

This is a personal Unraid 7.4 deployment. Each script is standalone; no sourced
library or installation into the base OS is required. Runtime capabilities and
current API evidence are checked, not assumed from a future roadmap.

## Maintenance and crash recovery

`appdata_backup` remains the exclusive owner of `/tmp/appdata_backup.lock`.
DBRepair takes that lock shared before database maintenance, so backup and
DBRepair cannot run on the same live databases concurrently. A conflicting
maintenance run defers rather than stopping/restarting the other producer.

Arr monitoring, Arr delete sync, SAB cleanup, torrent processing and application
preparation hold `/run/arr-appdata-coordination.lock` shared through their work.
Appdata takes it exclusively before stopping containers. Arr consumers honour
the existing bounded startup grace. DNS watches the RPi fallback during primary
maintenance, preserves earlier primary failure counts and does not restart a
Pi-hole whose live maintenance lease/backup gate says it is intentionally down.

Docker watchdog v3.6 can recover a proven unexpected exit of an opted-in always-on
container. It requires the same container ID to have been observed running,
recent native `die` event evidence, no matching `stop`/`kill` event, valid state,
no maintenance, confirmation scans, shared-outage/flapping gates, cooldown and
budget. Missing event history, a new unknown container or intentional stop is
preserved. Recovery uses `docker start` for that exit, then the existing readiness
verification. It never restarts a job solely because processing failed.
Existing per-service permission `0` remains a prohibition. The default global
`AUTO_RESTART=false` in GitHub remains deliberate; live Hubble retains its
existing opt-ins. Docker restart policies are not changed to bypass these limits.

## Operational-state backup

The installed `vault_remote_backup` entry uses GitHub's `vault_backup.sh`.
Schedule `10 * * * *`: each hourly invocation checks the appdata completion
request; it is not a resident daemon or an hourly full copy. No request or an
already delivered identity exits before SSH/WOL, new backup logs or notifications.
A new verified producer generation triggers all configured backup labels.
Pending delivery retries on later checks, so variable producer runtimes and
temporary ISS/transport failures do not require a second fixed backup time.
Photos/GitHub/flash changes alone do not trigger delivery in this mode.
Delivery is acknowledged before retention, drill and shutdown; warnings from
those later phases do not automatically repeat an already verified generation.
`bash script --help` and `--version` are local-only diagnostics; `--force` can
wake ISS and repeat the current valid request while retaining freshness checks.

Vault v1.7 adds `operations_state` to each ISS generation. Before waking ISS, it
takes `/run/user-script-state-export.lock` exclusively and exports current state
from cooperating writers. These writers hold that lock shared. Export waits up
to ten minutes, then fails safely with the ISS request still pending.

The local managed source is `/mnt/vault/backup/operations_state`, with an ownership
marker. Unknown pre-existing directories are never replaced. Atomic promotion
keeps the previous export until its replacement is prepared. The 128 MiB budget
covers current Arr snapshots, pending-operation/action journals, acknowledgements,
import receipts, notification state, cleanup indexes, Docker/DNS history and
private disk-health configuration. Logs, dated state backups, app caches and
volatile leases/heartbeats are excluded. Export failure preserves the previous
snapshot. A remote SHA manifest verifies this label like other source labels.
Dry runs also prepare this small local snapshot; the remote remains read-only.

Restore files only with the owner script stopped. Pending mutations must be
reconciled with current downstream application/file IDs; restoring a journal
never means a mutation may be replayed unconditionally. Keep snapshots private.

## RAM logs and boot readiness

`ramlog_monitor.sh` v2.0 runs every ten minutes, using lifecycle state in `/run`:
70% warning, 90% critical, recovery at/below 65%, at most daily reminders for an
unchanged problem, and delivery retry. It reports large applications without
deleting/truncating active logs. Native application rotation remains authoritative.
Current mapped application logs already demonstrate rotation; no generic log
truncation job is introduced.

`bash .../ramlog_monitor/script --prepare` is the pre-emhttp/Docker boot hook.
It creates a missing empty 2 GiB tmpfs only before Docker is running, validates
existing tmpfs and creates declared application log directories. It refuses
nonempty unmounted directories, wrong filesystems and symlinked paths. It never
remounts an active filesystem or recursively changes application files. The go
hook is patched on the server, preserving unrelated content and secrets.

## Console-only torrent workflow

Torrent processing keeps console output only, with no grouped email or persistent
run log. Small state checkpoints live under
`/mnt/vault/cloud/logs/script/torrent_download_complete/state`. Required mounts,
Mover and maintenance are checked before changes. Exact qBittorrent content paths
must account for the category's files, and matching jobs must be complete and
already stopped (`stoppedUP`/legacy `pausedUP`). Active seeding, checking,
incomplete or unregistered files are retained with console explanations. The
script does not stop torrents, change seeding policy or remove torrent records.
An unfinished transfer checkpoint prevents blind replay; existing collision and
rsync transfer protections remain. VueTorrent refresh is limited to weekly and
its failure is reported independently of completed data processing.

## New narrowly scoped jobs

| User Script | Schedule (Singapore time) | Responsibility |
| --- | --- | --- |
| `backup_health_audit` | `20 * * * *` | Local freshness, pending ISS delivery, restore drills, runtime compatibility, and disk-monitor completion. Changed incidents/recovery and at most daily reminders. |

Hubble's `health_monitoring` runs at 06:30 daily and writes
`/mnt/vault/cloud/logs/script/health_monitoring/state/monitor_receipt.json`.
The hourly audit alerts if the monitor has no completed run in 30 hours or if
the latest notification failed. The receipt separates an attempted run from a
completed check, so an early exit or stalled run cannot refresh the completion
timestamp. The audit uses the existing schedule and only watches while Hubble
is online and its vault is mounted.

Disk Health Monitor v2.18.0 keeps the regression fixtures in
`tests/health_monitoring_test.sh`. Run that file with Bash from a checkout on
Unraid or a Linux environment with the monitor's fixture dependencies. Only
`user_script/health_monitoring.sh` is required for the installed User Script.
Use `bash script --diagnostics` on the installed copy to inspect configuration,
dependencies, and soak status without running SMART tests.

Disk Health Monitor v2.20.0 reads the legacy SMART, NVMe and command-timeout
baselines when `state/smart_baselines.json` is absent. A successful SMART
collection writes the combined file atomically. An invalid JSON file stops
the run so a corrupted baseline cannot silently reset counters. Keep the
pre-upgrade state backup when retiring the three original files. To downgrade
after retirement, use that state backup and the matching script version.
The soak report counts runs from the installed version only.
| `imagemaid_restore_archive` | Disabled with native clear-before-move | Optional archival alternative, retained in GitHub. Enable only when dated restore-image retention is wanted; do not combine it with native clear-before-move. |
| `media_metadata_audit` | `55 3,7,11,15,19,23 * * *` | Combine native MetaFusion findings and Kometa catalogue into one Sunday 11:55 review; retain guarded template reconciliation before four-hour boundaries. Missing coverage is explicit; active/unsupported producers defer edits. |

Keep `backup_restore_drill` unscheduled in User Scripts: the successful ISS backup
handoff invokes it on ISS when its seven-day interval is due. Its time follows
backup completion rather than a fixed weekly clock time. Repository files under
`user_script/descriptions/` supply the separate `description` file displayed by
the User Scripts plugin; comments inside a script do not populate that field.

ImageMaid images remain under the same Plex appdata filesystem in
`ImageMaid Restore Archives/restore_TIMESTAMP_PID`. No archive images are purged;
this preserves undo data while allowing the next move run a fresh active root.
Native start/finish/runtime evidence and an unchanged log after stopping protect
active jobs. No container image/env/schedule is recreated. Archive growth remains
visible to existing capacity monitoring and appdata backups.

Kometa preflight v2 delegates generated metadata reconciliation to MetaFusion.
Develop images advertise capability version 1 and the artwork byte ceiling in
native status. MetaFusion imports the legacy deferred catalogues without removing
them, tracks owned definitions, protects incomplete inventories/manual entries,
and publishes through its validated writer. Reconciliation runs during successful
untargeted incremental jobs as well as full jobs. Native counts/actions appear in
runtime metrics; preflight groups successful deferral/restoration results once.

MetaFusion and preflight share `<Kometa root>/.metafusion/output.lock` as a
writer lock. Kometa retains its original image, entrypoint and native scheduler;
no custom consumer launcher is deployed. Preflight v2.1 observes native run logs
and checks the writer lock before editing recognised personal overlay/collection
templates. It never rewrites generated metadata files or the native deferred
catalogue. Original personal-file backups retain five sets.

Stock Kometa does not acquire this lock. Scheduling and native activity checks
reduce overlap but do not guarantee producer/consumer mutual exclusion. Changing
a third-party container's startup is outside this installation's ownership
boundary. Keep all automation changes confined to owned MetaFusion and personal
User Scripts unless the user explicitly authorizes another application's change.

Application warnings need their underlying evidence checked before remediation:

* Empty overlay results can be normal: no current media matches that codec,
  edition or rating. They do not establish a container or download failure.
* A runtime overlay needs a parsed Plex duration. If targeted Plex analysis
  reports an invalid media header, the media needs recovery/replacement; neither
  changing overlay text nor restarting Docker repairs its contents.
* Kometa's metadata-backup language table may not represent a valid Plex language
  preference (for example, `zh`). Preserve the preference and report the backup
  limitation rather than changing playback behavior or excluding the field just
  to hide an error.
* Oversized artwork can be replaced by a smaller JPEG with the same dimensions
  and an updated exact `file_background` reference. Retain the original artwork
  and configuration backup; this is separate from media-file repair.

## Compatibility scope and intentional exclusions

The hourly backup health audit checks commands/GNU interfaces, rsync capability,
Docker availability, notification helper, expected mounts and active User Scripts
cron registration. Unraid outside the validated 7.x family is reported as
unvalidated, not silently certified compatible. For an unvalidated major version, Arr mutation/cleanup and application maintenance defer, and Docker/DNS recovery is prohibited while monitoring continues. App-specific validators also block unsafe actions when API/log schemas are unknown. Backup producers retain their own mount, identity and capability checks so protection is not silently disabled solely by a version label.
Announced Unraid 8 hooks/permissions cannot be implemented before their supported
interfaces exist; validate before enabling destructive automation on that release.

`docker_watchdog_liveness.sh` and `pre_post_reboot_audit.sh` remain inactive.
The existing disk-health schedule and parity policy are unchanged. `daily_digest.sh` and
`mover_audit.sh` are not installed by this deployment.

References: [qBittorrent API](https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-%28qBittorrent-5.0%29),
[Kometa native filters](https://kometa.wiki/en/nightly/files/filters/).


## Media Integrity Audit v1.0.0

`media_integrity_audit` runs `30 9 * * 3` (Wednesday 09:30 SGT), with a two-hour
read-only budget through Bazarr. Movies, series and Formula 1 video containers
receive quick probes and resumable overlapping decode ranges; pending coverage
is never called healthy. No new installation, Docker setting or media mutation.
One grouped run summary reports findings, exact paths, progress and recoveries.
Backup/runtime audit watches the weekly receipt and delivery failure; vault state
export optionally includes the compressed queue under its existing short lock.
Individual media warnings are not duplicated in hourly backup notifications.
See [Media Integrity Audit](../docs/media-integrity-audit.md) for scope, limitations,
retention, scheduling and operator CLI.
