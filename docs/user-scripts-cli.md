# Hubble User Scripts: CLI reference

This is the single CLI reference for all 18 deployed User Scripts. Commands below
match the script parsers, not options offered by the underlying Docker apps.
Current release numbers and code hashes are in [versions.json](../user_script/versions.json).
Update this reference whenever a public command changes.
For each script's purpose, workflow and coordination with other jobs, see
[the operational guide](user-scripts-guide.md).

## Invoke an installed script

Use the Unraid terminal as root. Always run through Bash: the flash filesystem
may not permit direct execution. For example:

```bash
/bin/bash /boot/config/plugins/user.scripts/scripts/media_metadata_audit/script --version
```

For the shorter examples in this document, first define this terminal helper:

```bash
us() {
    local name="$1"
    shift
    /bin/bash "/boot/config/plugins/user.scripts/scripts/$name/script" "$@"
}
```

`us NAME` runs that script's normal operational workflow; it can perform configured
backups, maintenance, updates, cleanup or notifications. `us NAME --version` is the
only universally supported inspection command guaranteed to return before state,
logging, locks, Docker or network access. Do not assume `--help`, `--dry-run` or
`--execute` is accepted by every script. Some older workflow wrappers ignore
unrecognized arguments, so use only the commands documented for that script.
Inspection commands can take locks or initialize monitor state; this does not
mean they modify applications or media. Dry-run semantics are listed individually.
Commands here do not alter User Scripts cron schedules. Replace uppercase
arguments with real values and quote notes, paths and titles containing spaces.

## 1. backup_boot_disk

- `us backup_boot_disk`: create and validate the configured boot-device backup,
  retain generations and send configured outcome notifications.
- `us backup_boot_disk --version`: release only.

No help, preview or restore CLI is implemented. Configuration is in the script;
passing `--help` is not a safe way to inspect this backup wrapper.

## 2. backup_cache_appdata

- `us backup_cache_appdata`: run configured appdata backup, container coordination,
  archive verification, retention and optional share copies.
- `us backup_cache_appdata --version`: release only.

Appdata runs automatically coordinate blanket Docker watchdog deferral through a
verified runtime lease, followed by two minutes of recovery grace. No schedule
change or manual maintenance command is needed. Per-directory results append
`[no container]` only when a complete inventory of installed container bind mounts
(including stopped containers) proves no owner; `[owner unknown]` means inventory
could not be verified. Neither label changes backup eligibility.

No help, preview or restore CLI is implemented. Storage-mode overrides are
configuration inputs, not CLI options. A supported one-run example is:

```bash
BACKUP_STORAGE_MODE=staging /bin/bash /boot/config/plugins/user.scripts/scripts/backup_cache_appdata/script
```

This starts a real backup and still requires valid configured staging mounts and
sufficient capacity. It is not an inspection command.

## 3. backup_health_audit

- `us backup_health_audit`: audit backup evidence, freshness and runtime capability;
  no backup, remote wake, media scan or repair. Eligible queued notifications may send.
- `us backup_health_audit --help` / `--version`: usage / release.

## 4. backup_media_remote

- `us backup_media_remote`: run the configured media copy to ISS, verification,
  retention and guarded shutdown workflow.
- `us backup_media_remote --evidence-status`: validate saved success/failed-attempt
  receipts and show whether the first native receipt is still pending; no transfer, SSH or wake.
- `us backup_media_remote --version`: release only. No `--help` mode.

## 5. backup_restore_drill

- `us backup_restore_drill`: select backup coverage and perform bounded temporary
  restore/payload checks; remove extracted drill payload afterward and retain evidence.
- `us backup_restore_drill --generation-root /mnt/user/backup/vault_versions/hubble-STAMP`:
  test that specific generation on the host holding it; this performs a real drill.
- `us backup_restore_drill --help` / `--version`: usage / release.

A drill verifies recoverability; it does not restore live application data.

## 6. backup_vault_remote

- `us backup_vault_remote`: check the completion request; copy/verify a new generation
  on ISS when eligible. No pending request means no remote wake or transfer.
- `us backup_vault_remote --force`: repeat the current request despite its delivery
  acknowledgement. Source/freshness/integrity checks remain; this can wake ISS and
  transfer all configured backup jobs.
- `us backup_vault_remote --help` (`-h`) / `--version`: usage / release.

Production configuration uses `DRY_RUN=false`: eligible requests perform real
transfers and verification. Existing completion/request guards still apply; no
forced replay is needed after enabling production.

## 7. dns_redundancy_watchdog

- `us dns_redundancy_watchdog`: test primary/fallback DNS and apply only the
  configured bounded recovery policy, with lifecycle notifications.
- `us dns_redundancy_watchdog --version`: release only.

No help, diagnose or dry-run CLI is implemented; do not pass invented options.

## 8. docker_service_watchdog

| Command after `us docker_service_watchdog` | Purpose |
| --- | --- |
| No arguments | Availability/readiness and scheduled-job monitoring; configured bounded recovery and lifecycle reporting. |
| `--help` (`-h`) / `--version` | Usage / release. |
| `--diagnose CONTAINER [URL]` | Read-only readiness diagnosis, optionally using a supplied URL; no monitoring state, email or container action. |
| `--diagnose-vpn` | Read-only binding, exit-node, DNS and egress evidence. |
| `--readiness CONTAINER` | Machine-readable native readiness assessment for health consumers. |
| `--update-readiness CONTAINER` | Machine-readable readiness assessment for update verification. |
| `--update-schedule CONTAINER` | Native scheduling inputs for the updater; does not change application schedules. |
| `--maintenance CONTAINER MINUTES "REASON"` | Create a bounded manual maintenance lease; suppress availability/restarts and freeze findings until expiry. Maximum 24 hours. |
| `--record-job PROFILE EXIT_CODE [START_EPOCH]` | Record an actual producer outcome. Use the real exit code and start time; never use this to fabricate success. |

[Job maintenance classification and observation counters](docker-watchdog-job-maintenance.md)
explain how backup-related Plex failures differ from genuine job faults.

Example inspection: `us docker_service_watchdog --diagnose qbittorrent`.
To end a manual lease early, remove only the reviewed container's
`/run/docker-service-maintenance/CONTAINER.manual.json`; this is a separate file
operation, not a watchdog CLI mode.

## 9. host_health_monitor

Both host scripts share a [coordinated health view and notification context](host-health-coordination.md).

Daily coverage and warm-run evidence: [details](host-health-warm-runs.md).

| Command after `us host_health_monitor` | Purpose |
| --- | --- |
| No arguments | Daily disk/system health and configured bounded SMART/scrub maintenance. |
| `--help` (`-h`) / `--version` | Usage / release. |
| `--health-status` | Read shared health, partial disk coverage, readable times and separate maintenance assessment; no scan, state change or email. |
| `--check-config` | Validate configuration only. |
| `--diagnostics` | Read-only environment diagnostics. |
| `--state-status` | Inspect schema compatibility. |
| `--state-backups` | List available migration/rollback state backups. |
| `--rollback-state BACKUP_ID` | Restore one explicit state backup after creating a safety backup; no monitoring. |
| `--self-test` | Run repository fixtures from a complete checkout; not a live disk test. |
| `--test-notification` | Send one fixed test notification; no monitoring. |
| `--notification-dry-run` | Run normal monitoring/maintenance while skipping external notification delivery and notification-journal changes. |

Configuration, diagnostics and state-inspection modes do not run SMART commands,
start disk tests/scrubs or wake disks. **Notification dry-run is not a maintenance
or state dry-run**; normal monitoring work still runs.

## 10. host_health_watchdog

- `us host_health_watchdog --health-status`: read the same coordinated host/disk status; no probes, state changes or notification.

- `us host_health_watchdog`: collect fast host probes, print observations and summary,
  process syslog/log-capacity checks and deliver eligible lifecycle events.
- `us host_health_watchdog --help` (`-h`) / `--version`: usage / release.
- `us host_health_watchdog --external-status`: bounded native/RAM identity and
  freshness JSON for the Pi observer; no scan, state update or notification.
- `us host_health_watchdog --open-xfs`: list retained XFS incident markers.
- `us host_health_watchdog --ack-xfs SOURCE`: remove one reviewed source marker
  from that ledger. Use the exact source shown by `--open-xfs`; this is not repair.

Console results cover required mounts, capacity/inodes, memory, trusted CPU
sensors, eligible SSD Btrfs pools, physical LAN and the enrolled external observer.
Unverified/unsupported evidence stays explicit. Probe printing does not send
healthy-run mail or bypass warning/recovery confirmation rules.

## 11. media_cleanup

Normal `us media_cleanup` runs Arr, SAB and metadata quarantine retention
sequentially with one daily grouped notification. Preview records observations,
logs and checkpoints; it is not a zero-write mode.

| Command after `us media_cleanup` | Purpose |
| --- | --- |
| `--help` (`-h`) / `--version` | Wrapper usage / release. |
| `--status` | Saved latest full run, latest invocation and per-module results; no API calls, media scan, cleanup or notification. |
| `all [--dry-run\|--execute]` | All modules with explicit execution mode. |
| `--dry-run` / `--execute` | Equivalent global mode for all modules. |
| `--flush-notifications` | Retry eligible queued grouped delivery; no cleanup. |
| `arr [all\|sonarr\|radarr] [--dry-run\|--execute]` | Run the selected Arr deletion/tag/retirement workflow. |
| `arr --list-pending` | Inspect uncertain/pending Arr action checkpoints. |
| `arr --resolve-pending ID "NOTE"` | Record a verified operator decision; does not replay/reverse an action. |
| `sab [--dry-run\|--execute] [--purge\|--no-purge]` | Run SAB cleanup and optionally delayed quarantine purge. |
| `sab --inspect` | Inspect quarantined payloads, source paths and age. |
| `sab --pending-operations` | List unfinished purge/restore operations. |
| `sab --resolve-operation ID "NOTE"` | Record reviewed outcome; no payload change. |
| `sab --execute --restore WRAPPER` | Restore one manifest-backed payload to its original path; no overwrite. |
| `sab --execute --recover-orphan NAME` | Submit one exact native SAB orphan retry, retaining its data; never delete an incomplete folder. |
| `quarantine [--dry-run\|--execute] audit` | Inventory/retention audit; no payload purge. |
| `quarantine [--dry-run\|--execute] purge` | Bounded scheduled retention; dry-run routes to audit. |
| `quarantine --execute restore RUN_ID movies\|series RELATIVE_PATH` | Restore one original path without overwriting. |
| `quarantine --pending-operations` | List unfinished quarantine actions. |
| `quarantine --resolve-operation ID "NOTE"` | Record reviewed outcome; no payload movement/deletion. |
| `arr --help`, `sab --help`, `quarantine --help` | Module details. Each module also accepts `--version` for its component release. |

Example preview: `us media_cleanup arr sonarr --dry-run`.
Module releases are distinct from the wrapper's public release.

## 12. media_health_monitor

Normal scheduled scans defer all checks, notifications and automated actions
during a verified appdata backup and its two-minute recovery grace. Existing
issues remain intact; explicit review CLI commands remain available.

Normal `us media_health_monitor` polls Arr/SAB, reconciles evidence and runs
configured guarded automation in its permitted action windows.

| Command after `us media_health_monitor` | Purpose |
| --- | --- |
| `--help` (`--lifecycle-help`) / `--version` | Lifecycle usage / release. |
| `--list-active` | Active issues and exact 12-character ACK IDs. |
| `--automation-status` | Saved action/hold/search and pack workflow summaries. |
| `--policy-actions` | Saved guarded policy-action and cleanup checkpoints. |
| `--ack ACK_ID ["NOTE"]` | Suppress reminders for the current unchanged signature; does not resolve the issue or improve health. |
| `--unack ACK_ID` | Remove an acknowledgement. |
| `--dismiss-download ACK_ID ["REASON"]` | Close one intentionally abandoned supported download-flow issue in monitor state only. |
| `--batch-dismiss-downloads [FILTERS] [EXECUTION]` | Preview by default; execution requires a reviewed exact selection and count. |

Batch filters: `--source Sonarr|Radarr`, `--classification CLASSIFICATION`,
`--title-contains "LITERAL"`, `--older-than-hours N`, `--before DATE_OR_DATETIME`,
`--ack-file PATH`. Supported dismissal classifications are
`DOWNLOAD_FLOW_NOT_REACHED_SAB`, `DOWNLOAD_FLOW_SAB_VANISHED` and
`DOWNLOAD_FLOW_IMPORT_MISSING`. ACK files contain one complete 12-character ID
per line. Execution uses `--execute --confirm-count N --reason "NOTE"`; it needs
an exact classification or ACK file and an additional narrowing filter (the exact
ACK-file selection is itself a narrowing filter). A changed count is rejected.

```bash
# Preview the exact reviewed selection first; copy its printed count.
us media_health_monitor --batch-dismiss-downloads --ack-file /boot/config/arr-dismiss-ack-ids.txt
# Then, and only after review, use that exact count in place of N.
us media_health_monitor --batch-dismiss-downloads --ack-file /boot/config/arr-dismiss-ack-ids.txt --execute --confirm-count N --reason "Reviewed intentional removals"
```

Preview saves a TSV and ACK-only file and prints their paths. Monitor-state
execution keeps a backup/audit manifest. Acknowledgement/dismissal never removes
Arr entries, SAB jobs or media files. Uncertain real outcomes should remain open
for evidence-based reconciliation.

## 13. media_integrity_audit

- `us media_integrity_audit --evidence-status`: concise saved normal-scan, decode-progress and pending-coverage evidence; no media or Docker access.
- `us media_integrity_audit`: bounded media inventory/decoding scan and configured
  recovery follow-up; the recovery enable switch remains authoritative.
- `--help` (`-h`) / `--version`: usage / release.
- `--status`: saved scan receipt only; no Docker/media I/O.
- `--inventory-only`: stat library paths and save inventory; no decoding or normal email.
- `--recovery-status`: saved recovery journal only.
- `--recovery-tick`: bounded API follow-up; no decoding or scan-freshness advancement.
- `--recover-only`: bounded Arr recovery workflow, normally called in the Arr action window.

Prefix each option with `us media_integrity_audit`. No CLI bypasses
`AUTO_RECOVERY_ENABLED=false`. Originals remain in place until native Arr
replacement/recycling; recovery modes can contact Arr and submit guarded work
when enabled.

## 14. media_metadata_audit

Normal and `--weekly-report` invocations defer collection, email and reconciliation
during the same appdata lease/grace. Pending weekly delivery is retained for the
next eligible invocation. `--report-preview` remains read-only and available.

- `us media_metadata_audit`: check the weekly review deadline and then perform
  existing guarded metadata/configuration reconciliation when eligible.
- `--help` / `--version`: usage / release.
- `--report-preview`: print current MetaFusion/Kometa/Recyclarr/ImageMaid review;
  no email, report-state updates or YAML edits.
- `--weekly-report`: check the existing weekly deadline only; no configuration
  reconciliation. It does not force a report before the deadline. Eligible due
  delivery updates report state and can send one grouped email.

Prefix each option with `us media_metadata_audit`. Preview still uses the script's
normal coordination locks. Only two completed weekly text reports are retained.

## 15. media_plex_dbrepair

- `us media_plex_dbrepair`: run configured DBRepair maintenance for the Plex
  instances, preserve original container state and publish grouped outcomes.
- `us media_plex_dbrepair --version`: wrapper release only.

No help/diagnose/dry-run CLI is implemented. DBRepair's own internal version
option is not this wrapper's interface; do not pass arbitrary DBRepair arguments.

## 16. media_torrent_management

- `us media_torrent_management`: configured pre-transfer cleanup/renaming,
  completed-payload rsync and VueTorrent update checks; console-only reporting.
- `us media_torrent_management --help` (`-h`) / `--version`: usage / release.

No CLI dry-run, forced ownership bypass or alternate category selector is implemented.

## 17. ram_logs_watchdog

- `us ram_logs_watchdog`: checkpoint changed RAM logs, validate hook coverage and
  monitor RAM-log health under existing limits.
- `--help` / `--version`: usage / release.
- `--prepare`: prepare/mount the configured RAM-log filesystem and install the
  shutdown event adapter; changes host runtime setup.
- `--install-hook`: install the owned RAM-resident shutdown event adapter only.
- `--archive [manual|checkpoint|shutdown]`: create/update the bounded vault archive
  for that reason; never restore old logs into RAM.

Prefix each option with `us ram_logs_watchdog`. Retention stays at two boot
snapshots. A sudden power loss can lose changes after the last completed checkpoint.

## 18. system_update_coordinator

Normal `us system_update_coordinator` checks policy, reconciles outcomes and can
install approved updates inside configured windows. Commands change coordinator
policy only unless installation/reconciliation is explicitly described.

| Command after `us system_update_coordinator` | Purpose |
| --- | --- |
| `--help` (`-h`) / `--version` | Usage / release; no registry check or installation. |
| `--status` | Saved policy, items, jobs and pending-notification count. |
| `--candidates` | Saved available/held candidates and next-attempt evidence. |
| `--report-preview` | Saved holds and scheduling report; no installation/email. |
| `--check-only [--refresh]` | Refresh due/all bounded candidate evidence; no new installation. Existing jobs are still reconciled. |
| `--reconcile-only` | Verify existing outcomes and deliver eligible notifications; no new installer, registry refresh or recovery pruning. |
| `--pause` / `--resume` | Disable/enable new installations; checks/reconciliation continue. |
| `--allow docker NAME` / `--allow plugin NAME.plg` | Approve the exact installed image/channel or plugin source. |
| `--deny docker\|plugin NAME` | Disable one approval while retaining reporting. |
| `--allow-installed` | Approve currently installed eligible identities; Unraid OS remains manual. |
| `--window HH:MM HH:MM` | Set the primary same-day Singapore maintenance window. |
| `--add-window HH:MM HH:MM` | Add a non-overlapping window, maximum four. |
| `--remove-window HH:MM HH:MM` | Remove a window; retain at least one. |
| `--report-time HH:MM` | Set the Singapore grouped daily report time. |
| `--hold docker\|plugin NAME HOURS` | Set one installed identity's observation hold, 1–168 hours. |
| `--limits DOCKER PLUGINS HOLD_HOURS` | Daily caps: Docker 1–12, plugins 0–4, hold 1–168 hours; one installer per invocation remains. |
| `--archive-limit GIB` | Previous-image archive bound, 1–8 GiB. |
| `--resolve JOB_ID "NOTE"` | Close a reviewed uncertain/failed job without claiming success or replaying an installer/recovery. |

Removed identities retire after two complete inventories; do not delete journals
to force rediscovery. Unknown outcomes remain protected until verified or explicitly
reviewed. None of these commands changes Docker startup/template/application
configuration, switches image channels or installs/reboots Unraid OS.
