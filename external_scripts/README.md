# Independent Hubble availability monitoring

`hubble_availability_watchdog.sh` runs on the Raspberry Pi, outside Hubble's
User Scripts inventory. It uses existing Bash/Python, OpenSSH, curl, cron and
msmtp; it installs no packages or containers and has no restart/power authority.

Deployment locations:

| Item | Pi location |
| --- | --- |
| Script | `/usr/local/sbin/hubble_availability_watchdog.sh` |
| Private configuration | `/etc/hubble_availability_watchdog.json` |
| Persistent state/history/outbox | `/var/lib/hubble_availability_watchdog/state.json` |
| Dedicated private key and pinned host key | `/var/lib/hubble_availability_watchdog/ssh/` |
| Rotated operational log | `/var/log/hubble_availability_watchdog/watchdog.log` |
| Native cron | `/etc/cron.d/hubble_availability_watchdog` |

Cron runs every two minutes in Asia/Singapore. Three consecutive failed samples
raise an incident; two good samples resolve it. Unknown results, sampling gaps or
Pi reboot do not manufacture confirmation/recovery. Hubble's fast-monitor receipt
must belong to the current Hubble boot and be within 15 minutes, with a 15-minute
boot grace. The web probe checks response availability, including the expected
login redirect; it does not claim authenticated application correctness.

Hubble exposes only `host_health_watchdog --external-status` through a dedicated
SSH key restricted by source IP, forced command, and OpenSSH `restrict`. The Pi
pins Hubble's Ed25519 host key. A bad/replaced host key is never auto-accepted.
SSH failures with a working web interface are probe-access findings, rather than
claims that the whole server is down. Boot identity changes are reported as
observed reboots; exact downtime cannot always be determined.

Mail goes directly through the Pi's existing root msmtp account to the private
configured recipient. It does not call Hubble's notification helper or use Hubble
DNS. Configuration and keys are root-private and are not checked into GitHub.
Healthy runs are silent. Condition transitions are grouped; unresolved incidents
have daily reminders. Failed SMTP submissions retain events and retry after 15,
30, then 60 minutes. A recovery before initial delivery is described as such.
Successful submission records SMTP acceptance, not an assertion about inbox receipt.
State is atomic/fsynced; history retains 40 delivered events. The log retains the
current 256 KiB file plus two rotations and never sends logs to syslog.

Useful commands, run on the Pi:

```bash
sudo /usr/local/sbin/hubble_availability_watchdog.sh --status
sudo /usr/local/sbin/hubble_availability_watchdog.sh --test-email
sudo /usr/local/sbin/hubble_availability_watchdog.sh --maintenance 30 --reason 'Planned Hubble maintenance'
sudo /usr/local/sbin/hubble_availability_watchdog.sh --clear-maintenance
```

Maintenance expires after the requested 1–240 minutes and suppresses new notices;
it does not erase incidents already raised. Use it before deliberate prolonged
host downtime. An ordinary array stop is not a host outage while SSH/web remain
reachable. This watchdog never automatically restarts either host, Docker or DNS.

Hubble's five-minute host watchdog checks the Pi's atomic observer state using
existing management SSH access. It reports a stale observer (over ten minutes),
unverified access or outstanding independent-mail failures after sustained
confirmation. Removing/disabling the explicit external-observer enrollment
retires that check without editing executable code. No additional Hubble cron
entry is needed; the live User Scripts inventory remains 18.

On Pi replacement, restore its private config, dedicated SSH material and root
msmtp configuration through a protected backup channel. Restore state only with
matching configuration; no captured PID/lock is restored. Keep the original
source-IP/key restriction or re-enrol the new observer deliberately.
