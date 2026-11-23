# Private recovery inventory and restore checks

`vault_backup.sh` v1.9 captures `operations_state/recovery` on a new valid appdata
completion request, before ISS wakes. Hourly no-op checks still perform no capture
or transfer. The existing state-export lock and atomic promotion protect the old
snapshot if copying fails. State and recovery files share the 128 MiB export
budget. No additional scheduled script is needed.

The bundle includes read-only Docker inspect data, image IDs/available RepoDigests,
network and volume definitions, selected boot control files, file hashes/original
ownership and modes, producer manifest, configured-source evidence and RESTORE.md.
The SHA manifest travels with the existing ISS generation. Its copy is verified by
the regular generation transfer; the restore drill separately checks its contents.
Docker settings are evidence only: no pull, create, exec, restart or update command
is used. Inspect data and templates can contain passwords. The bundle parent is
700 and files are 600. Keep copies private and out of GitHub.

`coverage.json` deliberately does not infer data protection from a mount existing.
It lists mount paths and matching configured ISS source roots using path boundaries.
The appdata manifest lists archived application names; exclusions still apply.
External appdata mounts, user-share aliases and the separate media mirror require
review against their actual policy. Named-volume *definitions* contain no volume
payload. Unknown coverage is reported as unverified, not silently certified.

`backup_restore_drill.sh` v1.3 retains the existing two-archive/64 GiB defaults. In
addition to archive/SQLite checks it checks template XML using PHP/SimpleXML with
network/entity loading prohibited, shell syntax using `bash -n`, schedule JSON,
known active script references and all recovery SHA entries. No restored script is
executed. Non-shell scripts and missing older-bundle components produce warnings.
A local drill shares the state-export lock so replacement cannot race its checks.
The remote drill reads an immutable completed generation. Neither is a full boot
or application startup test. Its existing notification reports checked counts and
recovery scope; no second notification channel is introduced.

`backup_health_audit.sh` v1.2 reads inventory metadata locally after the first
recovery-enabled export, reporting incomplete runtime capture or named-volume
payload gaps through its existing deduplicated findings. It never wakes ISS or
rehashes bulk media. Missing bundles from older generations do not cause a new
cutover alarm.

Recovery order is embedded in each bundle's RESTORE.md: verify disk assignments,
keep automation disabled, choose compatible completed data/state, restore paths and
networks, review exact image identities, start services individually, reconcile
pending script actions, then deliberately re-enable schedules. Inventory cannot
ensure an old image remains downloadable; image layers are not saved here.

CLI and schedules remain unchanged. Use `bash script --help` on the installed
restore drill for manual usage. Keep it unscheduled when the vault consumer runs
the bounded weekly drill on ISS. These changes do not modify appdata production,
flash backup retention or any third-party container configuration.
