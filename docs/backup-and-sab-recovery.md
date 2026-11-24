# Backup and SAB recovery behavior

`vault_backup.sh` is installed as `vault_remote_backup` in Unraid User Scripts.
The stable status receipt remains `vault_backup.json`; all notifications use
**Vault to ISS Backup**. Version checks on both backup endpoints consume all
rsync output before deciding compatibility. This avoids a SIGPIPE false failure
under `pipefail`, including with newer rsync versions.

The ISS job publishes delivery only after its full manifest verification. Its
existing guarded shutdown follows successful delivery/retention and the scheduled
restore-drill decision. A failed preflight leaves ISS available for investigation;
it does not force a shutdown or claim a successful backup.

`appdata_backup.sh` now includes Plex's `Media` directory for both configured
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
