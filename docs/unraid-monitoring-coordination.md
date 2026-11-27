# Hubble monitoring coordination

The following User Scripts are deployed on Hubble and maintained in this repository.
Docker images, startup commands, application configuration, and cron schedules are
not modified by this update.

## Docker Service Watchdog 3.8

The qBittorrent VPN audit is read-only and separate from availability checks.
Docker health, maintenance leases, availability recovery budgets, and existing
per-container restart permissions remain effective. VPN findings cannot request
restart or reconfiguration. Two consecutive observations raise/clear incidents;
unchanged observations use the watchdog's existing grouped delivery policy.

The audit checks the selected online Tailscale exit node against the approved node
ID, the persisted qBittorrent interface binding, IPv4/IPv6 routes, the DNS answer
for Mullvad's canary, and small interface-bound HTTPS canaries. DNS/TLS/transport
failures mean *unverified*, not a proven leak. A successful canary is evidence for
that request, not proof about every torrent socket or a full DNS-leak test.

Read-only diagnostic:

```bash
/bin/bash /boot/config/plugins/user.scripts/scripts/docker_service_watchdog/script --diagnose-vpn
```

For Hubble's current Tailscale/Mullvad arrangement, select `tailscale0` in
qBittorrent Settings > Advanced > Network interface. Leave Optional IP address to
bind to at All addresses. Keep Web UI container port 8080 and host mapping 8686;
Web UI and torrent interface selection serve different purposes. Hotio's separate
built-in VPN is not required merely because Tailscale is the chosen VPN transport.
Recheck the expected exit-node ID if deliberately selecting another Mullvad node.

At inspection, `am.i.mullvad.net` resolved to `0.0.0.0` inside qBittorrent. Review
Pi-hole/upstream blocking or DNS overrides and allow that exact diagnostic hostname
if desired. The watchdog never bypasses that DNS policy. A one-off HTTPS
connectivity check on `tailscale0` succeeded; Mullvad attribution remains
unverified until its canary works. No application setting was changed.

## Arr Health / Activity Monitor 3.15.0

API monitoring keeps the five-minute schedule and existing four-hour remediation
windows. The hourly filesystem audit processes up to 20 history entries or about
15 seconds per slice, with five seconds per file enumeration. The budget is checked
between records, so one in-progress record can extend the slice. A persisted
lexical download-ID cursor resumes on the next scheduled run; after the end of the
pass, the hourly interval begins again. Entries added before the cursor are visited
on the next pass.

File enumeration uses one `find` traversal with file sizes and no per-file `stat`
process. Failed/incomplete traversals cannot establish recovery. Only an identity
checked in a successful current slice may resolve a filesystem issue. Unchecked
active findings remain visible in health counts.

Notifications group matching application/title/classification/severity/event for
presentation only. Every download keeps its original issue key, Ack ID, detail,
resolution evidence and per-record delivery bookkeeping. Existing pagination,
byte limits, reminder policies, and failed-send retries remain in force. Historical
review warnings are not automatically dismissed just because titles match.

## Syslog Notification Monitor 1.1

Adds OOM kills, hung tasks, lockups and network watchdog/reset patterns to existing
error matching. Explicit zero-valued error/failure counters alone do not alert.
Normalized event signatures suppress identical repeats for 24 hours. The transient
ledger retains at most 2,000 signatures for seven days and resets on reboot, as the
existing syslog cursor does. Alert details include original evidence and state
that no corrective host/container action was taken.

Notification failure preserves the cursor and previous delivery ledger. High
`/var/log` utilization also emits an explicit recovery notification after its
recovery threshold. Silence in syslog is not interpreted as recovery from OOM,
network or disk faults.

## Disk Health Monitor 2.19.0

The newer live implementation is authoritative and is now copied to GitHub
verbatim. This preserves its retirement of report-only trend state and its
restriction of temperature-rate warnings to fresh readings near the actual
warning threshold. Current disk-health fixtures replace tests of those retired
features. It is not reverted to the older repository implementation.

The watchdog's recovery permissions in this repository now match the already
active live policy. Arr API credentials remain private deployment values and are
not published in GitHub. Deployment compares the executable logic after restoring
only those existing API-key lines.

## Daily storage and fast host ownership (daily host monitor 3.4.0 / host watchdog 1.9.1)

The User Scripts schedule remains the sole scheduler: `host_health_monitor` runs
at **06:30 daily**, and `host_health_watchdog` at **five-minute intervals**. No new cron
entry, daemon, package or User Script is required.

Daily health retains SMART/NVMe wear, temperatures, tests, disk/pool capacity,
maintenance coordination and native scrub-completion freshness. Before state or
configuration migration it verifies the exact vault mount, persistent filesystem,
read-write mount options and a small write/delete probe. Failure leaves persistent
state untouched and records emergency evidence in `/run`. The frequent watchdog
owns that emergency condition; a daily direct alert is a fallback if that watchdog
is unavailable. Recovery still requires two good frequent observations.

The fast watchdog owns required mount availability/read-only state, available RAM,
root/boot/Docker capacity and applicable inode exhaustion, trusted CPU package
limits, SSD-pool Btrfs metadata headroom/missing members, and the physical LAN
behind the default bridge/bond. Array filesystems are checked through mount
metadata; their usage and SMART queries remain daily. Btrfs allocation polling is
limited to pools whose enumerated members are all non-rotational. RAM-log and
`/var/log` capacity retain their existing owners. It performs no automatic repair,
balance, network restart or application changes.

Warnings require three samples, critical resource conditions two, and a critical
mount/CPU condition one. Recovery needs two consecutive good samples; sampling
gaps and unknown/unsupported evidence cannot manufacture confirmation or recovery.
Notifications report raised/severity-change/recovery events and daily reminders
for confirmed unresolved conditions. Host events join an existing syslog email
where possible; otherwise one grouped host notification is sent. A failed delivery
leaves events pending. Healthy scans do not email. Up to 24 host events fit one
message; excess events remain pending for another scheduled invocation.

Fast state is consolidated in `/run/host-health-state.json`, with a same-boot
coverage receipt at `/run/host-health-receipt.json`. One durable
`host_health_watchdog/host-health.json` mirror is refreshed hourly or on pending-event
changes/delivery. Reboot invalidates network deltas and consecutive-sample counters;
retained incidents are not falsely declared recovered. Removed hardware is retired
after seven days without a misleading recovery claim. The central syslog receipt
separates successful execution from `activeHostConditions`.

Daily storage records one structured `state/filesystems/pool_health.json` beside
existing scrub evidence. Native pool cron expressions determine the actual last
due scrub, with a **72-hour grace**. A clean finished scrub must have started at or
after that due time (five-minute timestamp tolerance). Cached native status retains
its original start date; reading it does not create a fresh completion. Disabled
native schedules are excluded, and unreadable schedules remain unverified rather
than becoming disk faults. The monitor never starts or aborts native pool scrubs.

LAN checks use supported speeds or observed baselines, keyed by interface and MAC.
Current RX/TX errors are compared with packet deltas; counter resets, sampling gaps,
dropped packets alone and historical totals do not produce degradation alerts.
A replacement 1Gb adapter is not required to support the previous 2.5Gb hardware.
CPU limits come from trusted driver-exported package sensors; unsupported telemetry
is left unknown, without guessed limits or motherboard AUX/fan false alarms.

The standalone scripts embed modules from `tools/host_health_common.sh`,
`tools/host_health_probes.sh` and `tools/disk_host_health.sh`; regenerate with
`python3 tools/sync_host_health.py`. Isolated native fixtures cover state guards,
lifecycle/delivery, scheduling, allocation, CPU and network behaviour; the separate
integration fixture intercepts mail and uses temporary state on Hubble.


## Host watchdog naming and preserved state

The expanded host/syslog owner is `host_health_watchdog`, with the existing
five-minute User Scripts schedule and Unraid category. UI descriptions are
preserved during the rename. Its persistent incident ledger and host lifecycle
mirror live in `logs/script/host_health_watchdog/`; runtime cursor/incident delivery
state is `/tmp/host_health_watchdog_state`. The current-boot probe receipt and
baseline state are `/run/host-health-receipt.json` and `/run/host-health-state.json`.
Central completion and execution receipts use the same operational identity.

Daily disk fallback, hourly backup freshness, deployment hashes, recovery-state
exports, native schedule copies/cron and category metadata refer to that identity.
The existing incident IDs, notification cooldowns, XFS acknowledgements, cursor,
network counters and host condition evidence are moved intact. No second watchdog,
empty baseline or compatibility cron is left active. Completed backup snapshots,
checksum manifests and original historical log messages retain their recorded
provenance; the next normal recovery export includes the renamed ledger and host
lifecycle mirror. Existing archives are not rewritten.

## Daily monitor name and external observer

The daily SMART/filesystem owner is `host_health_monitor` (06:30 daily), distinct
from the five-minute `host_health_watchdog`. Its log/state directory, private
`host_health_monitor.conf`, runtime lock, execution identity, UI schedule/category,
backup audit and operational recovery export all use that name. Device identities,
maintenance coverage, lifecycle journals and historical findings are retained;
completed old backups/log messages retain their original provenance. Stable state
format identifiers are not renamed or reinterpreted as a schema migration.

The external Pi observer is maintained under `external_scripts/`, outside Hubble's
User Scripts list. Its restricted Hubble endpoint is read-only, does not take the
producer lock and cannot acknowledge or mutate incidents. Hubble also checks the
Pi observer's execution/mail state, using explicit private enrollment metadata.
See `external_scripts/README.md` for its schedule, retention, delivery semantics
and maintenance CLI.
