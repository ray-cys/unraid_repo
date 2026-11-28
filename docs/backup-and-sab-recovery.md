# Backup and SAB recovery behavior

`backup_vault_remote.sh` is installed as `backup_vault_remote` in Unraid User Scripts.
The stable status receipt remains `backup_vault_remote.json`; all notifications use
**Vault to ISS Backup**. Version checks on both backup endpoints consume all
rsync output before deciding compatibility. This avoids a SIGPIPE false failure
under `pipefail`, including with newer rsync versions.

The ISS job publishes delivery only after its full manifest verification. Its
existing guarded shutdown follows successful delivery/retention and the scheduled
restore-drill decision. A failed preflight leaves ISS available for investigation;
it does not force a shutdown or claim a successful backup.

`backup_cache_appdata.sh` now includes Plex's `Media` directory for both configured
instances. Generated previews/analysis can be rebuilt, but keeping them improves
restoration completeness. Cache, logs and the other documented temporary paths
remain excluded. Media can be large and compress poorly. The default retains one
verified generation; the previous backup is pruned only after a verified
replacement exists. Existing backups made before this change do not retroactively
contain Media.

## Unreadable SAB saved state

A `Loading .../__ADMIN__/SABnzbd_nzo_data failed` warning does not establish that
the download is redundant or disposable. Scheduled cleanup protects incomplete
folders. Review the exact job in SAB and Arr before any recovery decision.

The existing cleanup script provides a native recovery command:

```bash
cleanup_script=/boot/config/plugins/user.scripts/scripts/arr_sabnzbd_cleanup/script
/bin/bash "$cleanup_script" --dry-run --recover-orphan 'EXACT_FOLDER_NAME'
/bin/bash "$cleanup_script" --execute --recover-orphan 'EXACT_FOLDER_NAME'
```

Use a basename from SAB's orphan inventory, not a path. Without `--execute`, this
operation previews even when scheduled cleanup normally executes. The command
asks SAB to reconstruct that one job using retained NZB/data; it never deletes
an incomplete directory. It submits once, then verifies native registration.
An uncertain response requires inspection before retrying. Check the recovered
job's category, completion and subsequent Arr import; registration alone is not
import success. Existing import batching is preserved.

The Arr health monitor reconciles this specific old warning only when fresh SAB
status, queue and history APIs prove the exact orphan is gone and a healthy queue
record or Completed history record was created after the warning. It records the
original warning/acknowledgement ID and queues a grouped recovery notification.
Missing APIs, older records, failed jobs and an orphan still present keep the
warning active. Other download/import problems continue to be monitored.

## ISS rsync compatibility

`backup_media_remote.sh` and `backup_vault_remote.sh` (Unraid entry `backup_vault_remote`)
accept the native rsync on the older ISS Unraid installation based on its actual
features. Version banners are diagnostic only; no exact-match or minimum-number
gate and no host package/OS upgrade is imposed. Each end copies and checksums a
tiny fixture using the required flags in a private `/tmp` directory, then removes
only its own fixture. Configured backup destinations are untouched by this test.
Missing commands/options or failed fixture verification still stop the backup
before real transfer; logs identify Hubble versus ISS and the actual error.
Normal SSH transport negotiates a shared rsync protocol. This feature check is
not a guarantee against unrelated network/storage failures during real transfer.

## Appdata startup readiness and archive validity

`backup_cache_appdata` distinguishes Docker start/running-state failure from
unverified backend startup. A running container whose application is still warming
up keeps an explicit readiness warning; archiving other applications continues.
Outstanding readiness is checked again before finalization, without issuing a
second start/restart to an already running container. Native probe classifications
and reasons appear in the log and grouped outcome. A later successful check is
reported as recovered. Unresolved backend readiness produces a warning while
verified archives remain eligible for promotion and ISS handoff. Docker Service
Watchdog continues independent application monitoring/recovery.

A stopped or uninspectable container still fails recovery and prevents normal
finalization. Compression, manifest, capacity and retention guards are unchanged.
Interrupted runs explicitly report sources not attempted, alongside actual archive
failures, so successful partial work cannot be mistaken for a complete backup.
