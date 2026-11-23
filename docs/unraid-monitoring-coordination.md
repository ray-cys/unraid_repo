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
