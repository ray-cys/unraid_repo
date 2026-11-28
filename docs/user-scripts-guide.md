# Hubble User Scripts: purpose and coordination

This guide describes the current installed release set. Short Unraid UI descriptions
remain user-owned; the matching operational summaries also appear near the top of
each script. Configuration in the script and current native User Scripts schedules
control behaviour; this guide does not create timers or change policies.

For commands and their side effects, see [the CLI reference](user-scripts-cli.md).
For release numbers and public code hashes, see [the version inventory](../user_script/versions.json).
Live secret configuration can legitimately make installed hashes differ.

Backup producers create protection; audits inspect evidence; restore drills sample
restorability. Media monitoring, cleanup, integrity and metadata audits have distinct
ownership and share maintenance/recovery guards. The daily and frequent host monitors
share finding lifecycles. Docker recovery and native updates honour producer leases.

## Script index

- [backup_boot_disk](#backup-boot-disk)
- [backup_cache_appdata](#backup-cache-appdata)
- [backup_health_audit](#backup-health-audit)
- [backup_media_remote](#backup-media-remote)
- [backup_vault_remote](#backup-vault-remote)
- [backup_restore_drill](#backup-restore-drill)
- [dns_redundancy_watchdog](#dns-redundancy-watchdog)
- [docker_service_watchdog](#docker-service-watchdog)
- [host_health_monitor](#host-health-monitor)
- [host_health_watchdog](#host-health-watchdog)
- [media_cleanup](#media-cleanup)
- [media_health_monitor](#media-health-monitor)
- [media_integrity_audit](#media-integrity-audit)
- [media_metadata_audit](#media-metadata-audit)
- [media_plex_dbrepair](#media-plex-dbrepair)
- [media_torrent_management](#media-torrent-management)
- [ram_logs_watchdog](#ram-logs-watchdog)
- [system_update_coordinator](#system-update-coordinator)

## backup-boot-disk

Source: [backup_boot_disk.sh](../user_script/backup_boot_disk.sh).

**Purpose.** Create a restorable backup of the Unraid boot device and its configuration.

**Workflow.** Select a supported native backup method or direct ZIP fallback, validate the archive and checksum, then publish it before applying retention.

**Coordination.** backup_health_audit checks completion evidence; backup_vault_remote copies completed backups to ISS; backup_restore_drill checks selected restore contents.

**Limits.** This protects boot configuration, not Docker appdata or media. A validated archive is not proof that replacement hardware will boot.

**Reporting.** Report backup outcomes and failures with bounded diagnostics; retain failed notification delivery for retry.


## backup-cache-appdata

Source: [backup_cache_appdata.sh](../user_script/backup_cache_appdata.sh).

**Purpose.** Create verified Docker appdata archives, including configured directories without a container owner, and optionally mirror additional shares.

**Workflow.** Estimate space, identify container owners, stop the required running containers, archive and validate each directory, then restore its containers. Publish the completed generation before deleting the previous successful generation.

**Coordination.** A whole-run backup lease defers dependent monitoring and updates. Successful completion requests an ISS copy through backup_vault_remote; backup_health_audit and backup_restore_drill inspect its evidence.

**Limits.** Only configured sources are backed up; exclusions are intentional. Prior successful protection is retained if a replacement cannot be completed. Container recovery takes priority over continuing archives.

**Reporting.** Report archive results, non-container directories, space, container recovery and finalization; unsuccessful runs do not publish ISS completion requests.


## backup-health-audit

Source: [backup_health_audit.sh](../user_script/backup_health_audit.sh).

**Purpose.** Check whether configured backup protection and recovery evidence are current and internally consistent.

**Workflow.** Read execution receipts, manifests, backup/verification freshness, deployed-code evidence and the installed native schedule; distinguish execution from successful protection.

**Coordination.** Consumes the backup producers, restore drill, RAM-log checkpoints and deployment registry. Retries eligible failed producer notifications without repeating the backup itself.

**Limits.** Metadata checks do not rehash every archive, wake ISS, restore applications or prove bootability. Unknown or missing evidence remains explicit.

**Reporting.** Report changed findings, recovery and bounded reminders; unchanged healthy audits remain quiet.


## backup-media-remote

Source: [backup_media_remote.sh](../user_script/backup_media_remote.sh).

**Purpose.** Maintain a remote mirror of configured media shares on ISS for recovery after loss of Hubble.

**Workflow.** Check local/remote mounts, paths, space and rsync capabilities; wake ISS if needed, transfer under a shared remote-use lease, publish completion evidence and request shutdown when safe.

**Coordination.** Shares ISS coordination with backup_vault_remote; backup_health_audit reads its completion/verification receipt.

**Limits.** This is a mirror: source removals can propagate. Compatibility uses available features rather than requiring identical rsync versions. Shutdown acknowledgement and observed shutdown are separate results.

**Reporting.** Report transfer, verification and shutdown outcomes; retain failed delivery evidence for retry.


## backup-vault-remote

Source: [backup_vault_remote.sh](../user_script/backup_vault_remote.sh).

**Purpose.** Copy completed local backups and configured vault data into independently restorable generations on ISS.

**Workflow.** Consume a valid appdata completion request, wake and validate ISS, transfer and verify a staged generation, promote it atomically, acknowledge completion, then apply retention and eligible remote restore checks.

**Coordination.** backup_cache_appdata produces requests; boot backups and configured GitHub/photos data join the generation. Shares the ISS lease with backup_media_remote; backup_restore_drill and backup_health_audit consume evidence.

**Limits.** An idle scheduled check does not start a transfer or wake ISS. Invalid, stale or changed requests are withheld. Dry run is disabled for production; hashing and transfer profiling remain separate.

**Reporting.** Report generation, verification, retention, restore-check and shutdown results, including unresolved failures; idle checks stay quiet.


## backup-restore-drill

Source: [backup_restore_drill.sh](../user_script/backup_restore_drill.sh).

**Purpose.** Exercise selected backup extraction and content checks in isolated temporary staging without replacing live applications.

**Workflow.** Select eligible completed archives using coverage history, verify and extract within resource limits, inspect expected database/configuration contents, record coverage and remove temporary payloads.

**Coordination.** Uses appdata/boot recovery evidence locally or a completed ISS generation when called by backup_vault_remote; backup_health_audit tracks drill freshness.

**Limits.** A sample passing does not certify every archive, a running restored application or a bootable server. Live appdata and container state are not replaced.

**Reporting.** Report selected restore-check outcomes and failures with durable completion evidence.


## dns-redundancy-watchdog

Source: [dns_redundancy_watchdog.sh](../user_script/dns_redundancy_watchdog.sh).

**Purpose.** Monitor Unraid Pi-hole as the primary DNS resolver and the Raspberry Pi as the independent fallback.

**Workflow.** Probe configured DNS answers over UDP/TCP, separate resolver failures from transport/host-access issues, then apply only the configured bounded recovery policy.

**Coordination.** Docker DNS monitoring is delegated here by docker_service_watchdog. Resolver and host/network evidence distinguish an application outage from a broader Hubble problem.

**Limits.** A running container is not proof of working DNS. Unknown host-to-custom-IP access or probe configuration must not become a blind restart decision.

**Reporting.** Group resolver failures, recovery actions and restoration using consecutive observations and cooldowns.


## docker-service-watchdog

Source: [docker_service_watchdog.sh](../user_script/docker_service_watchdog.sh).

**Purpose.** Monitor installed Docker availability, health and application readiness, with bounded recovery for eligible service failures.

**Workflow.** Discover installed containers, apply their policy, combine Docker health with backend probes or scheduled-job evidence, and verify any permitted restart.

**Coordination.** Honours appdata backup and updater maintenance. DNS belongs to dns_redundancy_watchdog; content/job findings are shared with media_metadata_audit. Dynamic inventory retires removed applications.

**Limits.** Content errors and unverified job outcomes are not availability restart reasons. Global appdata maintenance suppresses dependent probes and notifications until its recovery grace ends.

**Reporting.** Report actionable availability/job conditions, actions and recovery; avoid routine healthy emails and duplicate delegated content reports.


## host-health-monitor

Source: [host_health_monitor.sh](../user_script/host_health_monitor.sh).

**Purpose.** Run daily storage health and maintenance checks using SMART/NVMe data, endurance, capacity and supported filesystem evidence.

**Workflow.** Identify current hardware dynamically, collect supported measurements, evaluate confirmed faults and configured thresholds, and schedule eligible disk tests/scrubs under maintenance guards.

**Coordination.** Shares host findings and notification ownership with host_health_watchdog. The daily job covers slower storage checks; the frequent watchdog covers fast-changing host conditions.

**Limits.** Unsupported endurance attributes remain unverified. Trends provide context, not predicted failure dates. Maintenance respects array/backup activity; no speculative disk replacement decision is made.

**Reporting.** Coordinate actionable warnings, critical faults and recovery with the frequent watchdog; deferred or unavailable probes are shown separately.


## host-health-watchdog

Source: [host_health_watchdog.sh](../user_script/host_health_watchdog.sh).

**Purpose.** Monitor fast-changing host conditions and syslog without repeating daily SMART maintenance or waking disks solely for temperature checks.

**Workflow.** Process bounded resumable syslog input and probe mounts, memory, capacity/inodes, native temperatures, LAN and monitoring freshness; persist confirmed findings and shared host status.

**Coordination.** Shares lifecycle evidence with host_health_monitor, checks external Raspberry Pi observer freshness and consumes central execution/checkpoint evidence.

**Limits.** Distinguish unavailable collectors from confirmed faults. Critical conditions notify promptly; ordinary warnings and recovery require the configured observations. No automatic remount, filesystem repair or forced reboot.

**Reporting.** Group actionable host findings and restoration with shared deduplication; expose all probe results in console/status output.


## media-cleanup

Source: [media_cleanup.sh](../user_script/media_cleanup.sh).

**Purpose.** Coordinate daily Arr deletion/unmonitoring, retirement, proven SAB residue cleanup and quarantine retention in one workflow.

**Workflow.** Run Arr, SAB and quarantine phases sequentially. Verify exact identities and native writes; quarantine eligible sidecars/payloads, remove empty folders with rmdir and retain incomplete action journals.

**Coordination.** Consumes media_health_monitor pack plans and media_integrity_audit recovery holds; shared leases/action budgets prevent conflicting media changes. Replaces three separately scheduled cleanup jobs.

**Limits.** Whole-item retirement uses the configured 30-day hold and native record removal with deleteFiles=false; partial season deletion does not retire a surviving series. Unknown ownership, active work and Mover defer unsafe cleanup.

**Reporting.** Deliver one daily grouped account of actions, blockers, failures and recovery; retained entries keep their original observation times.


## media-health-monitor

Source: [media_health_monitor.sh](../user_script/media_health_monitor.sh).

**Purpose.** Monitor Sonarr, Radarr and SABnzbd health, downloads and imports, and reconcile issues using exact current evidence.

**Workflow.** Poll native APIs, classify queue/history/flow conditions, track issue lifecycle, and run bounded policy recovery: eligible import retries/searches, proven redundant handling, replacement and exact-accounted pack plans.

**Coordination.** Coordinates with media_cleanup and media_integrity_audit using application leases, action budgets and recovery holds. Appdata maintenance defers dependent checks; expected four-hour SAB batching is not a stalled-download error.

**Limits.** No title-only import proof or blanket dismissal. Mutations use configured four-hour action windows; uncertain ownership or required pack media prevents rejection. Historical warnings remain distinct from active faults.

**Reporting.** Group new/changed/reminder/restored and automated-action results. Weekly backlog review retains two reports; acknowledgement/dismissal commands are documented separately.


## media-integrity-audit

Source: [media_integrity_audit.sh](../user_script/media_integrity_audit.sh).

**Purpose.** Check configured media for genuine corruption with bounded, resumable verification and optional Arr-native replacement.

**Workflow.** Use Bazarr-provided FFprobe/FFmpeg/Python for quick inventory and planned decode ranges; retain per-file/version coverage and confirming-run evidence. Classify unsupported/resource/protocol outcomes separately from corruption.

**Coordination.** Coordinates backup, Mover/array load, Bazarr availability and Plex transcodes; shares recovery follow-up and holds with media_health_monitor and media_cleanup.

**Limits.** Automatic recovery is disabled by default. If enabled, exact Arr identities and repeated evidence gate replacement; the original stays in place and Arr owns import/recycling. A successful import alone does not prove integrity.

**Reporting.** Group required replacement, actions, blockers and verified completion; report truthful coverage/progress and weekly unresolved findings while successful routine checks stay quiet.


## media-metadata-audit

Source: [media_metadata_audit.sh](../user_script/media_metadata_audit.sh).

**Purpose.** Review MetaFusion metadata/artwork findings and Kometa, Recyclarr and ImageMaid operational findings in one weekly report, with guarded template reconciliation.

**Workflow.** Read structured MetaFusion findings and watchdog job evidence, preserve actionable error details, and reconcile only the configured personal Kometa overlay/collection templates when producer and identity guards permit.

**Coordination.** MetaFusion owns generated metadata/artwork; its write lock protects coordination. docker_service_watchdog supplies job evidence and independently handles Docker availability.

**Limits.** Incomplete inventories, active producers or appdata maintenance defer edits. This script does not update Docker images or take over MetaFusion metadata generation.

**Reporting.** Group weekly actionable findings and reconciliation outcomes; retain bounded reports and avoid routine per-run success emails.


## media-plex-dbrepair

Source: [media_plex_dbrepair.sh](../user_script/media_plex_dbrepair.sh).

**Purpose.** Run verified DBRepair checks and configured maintenance for both Plex instances while preserving their original container state.

**Workflow.** Validate the DBRepair tool, acquire per-instance maintenance protection, journal the operation, perform checks/eligible repair, then verify database results and restore the original service state.

**Coordination.** Shares maintenance evidence with docker_service_watchdog, backup_cache_appdata and update coordination so intentional Plex downtime is not treated as an outage.

**Limits.** This is database maintenance, not a replacement for appdata backups or a Docker image update. Interrupted operations retain recovery evidence; a running container alone does not prove database health.

**Reporting.** Report database findings, changes, advisories requiring review and recovery failures in operational language; harmless check banners do not become warnings.


## media-torrent-management

Source: [media_torrent_management.sh](../user_script/media_torrent_management.sh).

**Purpose.** Prepare completed configured qBittorrent payloads and move them into their final Plex locations, with a separate bounded VueTorrent refresh.

**Workflow.** Check active torrent ownership, remove configured unwanted source files, normalize confidently identified JAV codes before rsync, then move completed payloads. Incoming same-name files replace destination names; uncertain codes retain their names.

**Coordination.** Works with the qBittorrent completion/category workflow and Plex agent naming. Mover guards protect movement; source preparation happens before files reach the array.

**Limits.** Incomplete downloads and unconfigured categories are not bulk-cleaned. No title scraping, duplicate-name suffixes or original-name archive is added. VueTorrent staging is validated separately.

**Reporting.** Console-only action, timing and backlog reporting; no email notifications.


## ram-logs-watchdog

Source: [ram_logs_watchdog.sh](../user_script/ram_logs_watchdog.sh).

**Purpose.** Keep dedicated RAM-log storage ready and preserve bounded recent logs on persistent storage for diagnosis.

**Workflow.** Check RAM-log readiness and capacity, checkpoint logs to vault, verify retained archives periodically, and use the clean-stop hook for a final archive. After power loss, preserve the last completed checkpoint.

**Coordination.** Boot preparation supports applications using RAM-log mounts; backup_health_audit and host_health_watchdog independently check checkpoint/execution freshness.

**Limits.** Keep only the configured latest two archives. Sudden power loss cannot capture logs written after the last checkpoint; old logs are never restored into live RAM logs.

**Reporting.** Report readiness, checkpoint/archive failures and recovery rather than every healthy checkpoint.


## system-update-coordinator

Source: [system_update_coordinator.sh](../user_script/system_update_coordinator.sh).

**Purpose.** Discover Unraid, Docker and plugin updates and install approved current Docker/plugin candidates within guarded maintenance windows.

**Workflow.** Reconcile dynamic inventory and native schedules, age candidates, check backups and active producers, archive recovery evidence, run one native installer, then verify digest/configuration/readiness before releasing holds.

**Coordination.** Coordinates backup producers, Docker watchdog, application leases and scheduled-job windows. Removed applications/plugins retire after complete inventories; new identities do not inherit broad approval.

**Limits.** Unraid OS updates are notification-only. Direct Plex playback and queued downloads do not inherently block updates; active transcodes, post-processing or protected maintenance can. Uncertain outcomes are reconciled, not blindly replayed; image rollback cannot reverse database migrations.

**Reporting.** Group installed, failed and genuinely pending/deferred updates; omit up-to-date items. Critical/uncertain installation outcomes bypass ordinary batching.

## Retained compatibility and archived references

Readers for existing state, backup manifests, generation ownership and supported
native interfaces remain when they have active callers. Removing them solely
because their format is older would risk losing recovery evidence. Superseded
standalone scripts remain in GitHub as reference material; they are outside the
18-script installed release inventory and must not be scheduled alongside their
replacement workflows.

Standalone files embed only shared helpers reachable by their callers. Full
shared module sources remain under tools/ for generation and fixture coverage.

## Operational details

See [operational evidence and performance](user-script-operational-evidence.md) for scoped repairs, cache validity, profiling and inspection semantics.
