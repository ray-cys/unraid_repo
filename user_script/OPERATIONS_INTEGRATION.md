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
| `backup_health_audit` | `20 * * * *` | Local-only freshness, pending ISS delivery, drill and runtime/schedule audit. No ISS wake, media hashing or repair actions. Changed incidents/recovery and at most daily reminders. |
| `imagemaid_restore_archive` | `50 6 * * 3,7` | Prepare before actual Wed/Sun 07:00 native ImageMaid runs. Archive an idle previous restore tree, briefly stop/restart the scheduler under maintenance and verify same-directory identity after atomic rename. |
| `kometa_preflight` | `55 3,7,11,15,19,23 * * *` | After idle MetaFusion, before Kometa's four-hour boundaries, reconcile exact Plex GUIDs and supported resolution filters. Active/unsupported producers defer without edits. |

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

Kometa preflight moves absent exact-ID definitions from the two MetaFusion metadata
files into `/config/.preflight/*.deferred.yml`. A complete Plex GUID inventory is
required; matching-title identity ambiguity stays active for review. Definitions
return when their exact target ID returns. Fresh generated definitions take
precedence over stale deferred aliases. Original files have five retained backup
sets, and the deferred catalogue is never expired. A durable catalogue superset is published before active definitions are removed; restored definitions are published durably before catalogue compaction. The mutating Python process has its own inside-container timeout. Plex items/files, Arr download
policy and identifiers are unchanged.

Resolution overlays use supported native regex filters instead of requiring Plex
to advertise an otherwise valid empty resolution class. Movies/episodes filter
directly; shows/seasons explicitly require one matching child episode, preserving
the old search semantics instead of changing to the default 50% filter threshold.
No overlays are disabled and general validation is not switched off. Existing
warnings remain until the next normal application run proves a clean result.

Preflight v1.1 also gives the native TMDb dynamic-collection template an explicit
copy of the effective `default_collection_order`. This avoids a warning for each
generated collection while preserving its inherited order, native two-item
minimum, membership, exclusions and sync policy. Existing custom templates are
left alone; an edited managed template stops reconciliation for review.

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
