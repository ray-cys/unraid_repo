# Coordinated host health

The existing two User Scripts retain their schedules and responsibilities:

| Owner | Responsibility |
| --- | --- |
| `host_health_watchdog` (five minutes) | CPU/native disk temperatures, memory, LAN, required mounts, boot/root/Docker capacity, all-SSD Btrfs pressure, syslog events and monitoring freshness. |
| `host_health_monitor` (daily 06:30) | SMART, self-tests, endurance, scrub verification, array/disk capacity and evidence-based storage trends. |

No extra installed script, service, cron job or Docker configuration change is
required. Both consume the embedded `tools/host_health_coordination.sh` contract.
Use `bash SCRIPT --health-status` with either installed script to read the same
current coordinated status without probes, state changes or notification.

## Shared evidence, independent ownership

The daily monitor extends its existing `state/monitor_receipt.json` with
`healthEvidence` (schema 1): boot identity, observation time, actionable findings,
coverage and the configured disk-temperature thresholds. Starting a run, or an
incomplete run, preserves the last complete health snapshot. Existing incidents
awaiting genuine recovery confirmation stay in that snapshot.

The watchdog extends `/run/host-health-receipt.json` and its existing persistent
status receipt with `health`: fast findings, daily evidence/freshness, coverage
and storage-event context. Successful execution and health status are separate;
a completed collector can report CRITICAL, ATTENTION, CONFIRMING or UNVERIFIED.
Deferred/sleeping and unsupported readings remain explicit coverage fields.
The combined view refreshes on the next watchdog pass after a daily run.

Daily freshness follows the current native User Scripts schedule, with two hours
of completion grace. Removed/disabled schedules stop expected-run warnings;
unrecognised timing is unverified, never guessed healthy. An incomplete execution
remains visible alongside its last complete snapshot. A stale or invalid fast
receipt triggers a daily monitoring finding and preserves independent disk,
mount/filesystem and syslog fallback checks. Last-good evidence from another boot
is not current recovery evidence.

## Overheating, mounts and storage faults

CPU thresholds use supported package sensors and driver limits; losing a formerly
available sensor is a monitoring concern. Disk temperature reads use current
Unraid `disks.ini` and sysfs device type, not periodic SMART commands. Metadata
older than 15 minutes is unverified. Sleeping disks are not woken and their absent
temperature cannot resolve a previous incident. Native stable device IDs isolate
replacement hardware. Valid daily temperature configuration is reused; fallback
limits match the daily monitor's defaults. Critical temperatures and required
mount faults use immediate confirmation; ordinary warnings require sustained
samples, and recovery requires two healthy samples.

`/mnt/user` is required when native user shares are enabled and the array is
started, in addition to assigned device/pool mounts, boot and enabled Docker.
Stopped arrays are not reported as missing share storage. No automatic remount,
filesystem repair, balance, service restart or hardware setting change is added.

A delivered, recent watchdog temperature incident owns its notification. The
daily monitor retains SMART evidence and does not duplicate an absolute-temperature
alert already handled at equal/higher severity. Failed/pending delivery, stale
watchdog evidence, a stronger daily observation or mixed SMART/storage errors keep
the daily fallback active. If that fallback first reports the temperature incident,
it retains recovery ownership; the watchdog shows it through daily context and
does not manufacture a separate recovery. This ownership rule applies only to
absolute temperature, not accumulated thermal-warning time or other SMART faults.

Syslog errors retain their existing durable incident history and delivery policy.
The joint view includes recent critical events as historical evidence, not proof
that a fault still exists. Open XFS review markers remain separate attention
items until reviewed with the existing `--ack-xfs SOURCE` command; acknowledgement
does not repair a filesystem. Missing/error samples do not clear active incidents.

## Essential notifications and trends

Each producer retains its delivery/retry/recovery journal. Its notification includes
its actionable events, evidence/actions and peer context, without turning peer
findings into new notification events. Quiet healthy runs remain silent. Fast
pending events are critical-first, and only the exact delivered batch is consumed;
remaining events stay pending. Optional daily peer context is bounded and explicitly
counts additional existing findings rather than silently acknowledging them.

Keep measured wear/host-write history, error-counter deltas, capacity growth and
near-limit temperature evidence: they support real maintenance decisions. Routine
trend diagnostics remain in logs/history. They do not generate daily recommendation
emails, failure-date predictions, weighted risk scores or automatic replacement.
Action recommendations accompany actual findings, not every routine run.
