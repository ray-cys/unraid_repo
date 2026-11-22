# Docker watchdog and reboot audit

These scripts are independent Unraid User Scripts. Keeping them in GitHub does
not install, enable, or schedule them. Review container names, URLs, paths, and
expected service states before deployment. Run scripts through `/bin/bash`.

## Docker service watchdog v3.2

Optional schedule: `*/5 * * * *`. Each rule is
`container|optional HTTP endpoint|always or on-demand|restart permission`.
All listed applications now default to continuously running, including the
internally scheduled Imagemaid, Kometa, Metafusion, and Recyclarr containers.
The list includes both Plex instances, Sonarr, Radarr, SABnzbd, qBittorrent,
Bazarr, Tautulli, Seerr, Prowlarr, PhotoPrism and Lumunarr. Pi-hole is monitored by
`dns_redundancy_watchdog.sh` instead. Adjust exact names to the deployed stack.
`lometa` and `tautilli` are supported aliases if the primary name is absent.
Use on-demand only for a container intended to exit; nonzero exits still alert.

Inventory discovery reports installed containers without a policy. It does not
automatically restart unclassified applications. Declare an explicit rule, add
to `DISABLED_SERVICES`, or delegate through `EXTERNAL_SERVICES`. The Docker label
`com.ray-cys.watchdog.owner=external` or `disabled` also delegates an otherwise
unclassified container.

Two consecutive bad scans confirm an availability failure. Two good scans clear
it. A changed issue set/severity produces one grouped notification; unchanged
conditions have no reminders. Notification delivery failures retain pending
transitions for retry. OOM and Docker restart-count changes are events, not
permanent availability failures. Readiness validates application responses;
401/403 and API redirects are authentication/configuration warnings, never proof of
readiness or permission to restart. HTTP 400/404/429, TLS configuration errors,
and oversized responses inhibit recovery rather than trigger it.

Recovery is disabled by default. To enable it, set `AUTO_RESTART=true` AND set
the individual rule's permission to `1`. Recovery requires three consecutive
failure scans, valid monitoring state, no active maintenance, and fresh Docker
inspection. By default it never starts a stopped container. Each attempt is
persisted before execution, consumes a budget even on failure/timeout, and is
limited to two attempts per 24 hours with a six-hour cooldown. Docker health and
the configured HTTP endpoint are verified after restart. Application-specific
functionality is outside these basic availability probes.

Unraid boot grace defaults to five minutes, and container startup grace to two
minutes. Docker/curl operations have timeouts. Invalid state disables recovery
for that scan; a valid backup can restore monitoring history. The original state
is retained as `state.json.invalid`. A legacy v1 state is treated the same way;
v1 notification fingerprints are not imported.

### Readiness and shared failures

`PROBE_RULES` defines the expected container port, read-only path and response
validator. Explicit URLs in `SERVICE_SPECS` take precedence. Otherwise endpoints
come from published ports, host networking, or an unambiguous custom-network IP.
qBittorrent's `WEBUI_PORT` and a single shared/VPN companion's port mappings are
supported. Unresolved/ambiguous mappings and custom base paths need explicit
URLs; these conditions warn and block recovery rather than guessing.

Plex validates `/identity`, the Arr ping probes validate JSON status, qBittorrent
validates its application-version response, and Seerr validates its status version.
The SABnzbd, Bazarr, Tautulli and PhotoPrism defaults recognize their web UI only:
that proves identity/reachability, not backend operation. Native Docker health
can provide additional evidence. Configure a stronger supported API probe where
desired. No probe requests library listings or touches physical media paths.

Web UI recognition has a separate 1 MiB response cap (API responses remain capped
at 64 KiB). UI probes follow up to three same-origin redirects, allowing normal
login/base-path redirects without claiming backend readiness. Cross-origin
redirects are rejected before sending another request, protecting configured
headers/cookies. API redirects remain unverified. LAN probes bypass HTTP proxy
environment variables. Lumunarr initially uses container/Docker health only.

To diagnose an unresolved endpoint without notifications, state changes, or
container actions:

```bash
/bin/bash /boot/config/plugins/user.scripts/scripts/docker_service_watchdog/script --diagnose qbittorrent
# Optionally test the exact working Web UI/API URL:
/bin/bash /path/to/docker_service_watchdog.sh --diagnose qbittorrent http://HOST:PORT/api/v2/app/version
```

Output includes network mode, published ports, resolved probe target, and the
probe classification. Credentials and query parameters are omitted from target
diagnostics. A timeout can still be a genuine firewall/network/service issue;
route discovery does not change Docker networking or VPN configuration.

For auto-discovered qBittorrent endpoints only, transport failure can try up to
three routes: the published host address, loopback when Docker published on a
wildcard address, and the inspected container/network-namespace IPv4 address.
Every route is derived from that container's Docker metadata; no ports are
scanned. An explicit URL disables fallback. HTTP/authentication errors do not
trigger route switching. A successful fallback must still validate the expected
qBittorrent version response; its target is included in the probe evidence.

Optional files under `PROBE_AUTH_DIR`: `CONTAINER.headers` contains HTTP headers;
`CONTAINER.cookies` is a Netscape cookie jar. Protect credentials with owner-only
permissions. qBittorrent API authentication is required unless your current
application configuration explicitly permits these API requests. The watchdog
does not change authentication, log in repeatedly, or print credential contents.

All observations complete before any recovery action. Three transport failures
in one scan inhibit all candidate restarts; after confirmation they form one
shared-dependency incident. This indicates correlation, not a proven network
root cause. Child service details remain in the notification. Restoration must
pass the ordinary recovery confirmation before restart inhibition clears.

Four availability transitions within one hour mark a service unstable. Repeated
up/down emails are replaced by one unstable incident, recovery is inhibited,
and 30 minutes of stable availability is required before normal reporting
resumes. Unrelated failures, job errors and recovery-budget alerts remain visible.

### Internally scheduled jobs

Container uptime is independent of successful scheduled processing. Defaults:

| Profile | Expected schedule | Audit policy |
| --- | --- | --- |
| Imagemaid | Weekly | Completion within 192 hours (weekly plus 24-hour grace) |
| Kometa | Every four hours | Completion within six hours |
| Metafusion | Every four hours before Kometa | Completion within six hours |
| Recyclarr | Wednesday/Sunday 06:00 Singapore time | Completion within 120 hours; two successes per rolling 192 hours |

The watchdog does not enforce job ordering or trigger jobs. It monitors
completion evidence. Runtime limits default to 24 hours and require a reliable
job-start timestamp; it never treats container start time as an internally
scheduled job start. Initial missing-completion checks allow a complete initial
window instead of accusing jobs of missing historical runs it never observed.

Host log-tail calls bypass shell overrides and use attached byte/line count
options. This avoids a separated numeric byte limit being interpreted as a
filename. Metafusion failures now include bounded, credential-redacted error
detail and completion/success timestamps. Actual job failures and missing
producer integration are not suppressed. They resolve after authoritative
successful processing and the configured recovery confirmation scans.

Metafusion uses its native `/tmp/metafusion-status.json` via bounded Docker exec.
Change the source if `STATUS_FILE` is customized. It distinguishes last run
failure, last success, completion and active processing. Invalid evidence freezes
existing job findings; it cannot falsely clear an earlier failed run.

Kometa and Imagemaid use bounded, timestamped Docker log tails by default. Only
whole-run completion banners count; collection, playlist and test-run banners
are excluded. The monitor caches evidence between scans. A completion banner
does **not** prove success: with `REQUIRE_VERIFIED_JOB_SUCCESS=true`, the result
is a stable `job-unverified` warning until authoritative evidence is provided.
No repeated email is sent merely because another identical banner appears.
If an image does not send these records to Docker logs, configure another source.
Plain container log-file tails need a parseable timestamp on the marker line.

Recyclarr now reads its resident cron scheduler's Docker logs automatically.
The default command `/cron.sh` and job position `0` match this installation's
scheduler output. It matches whole-job start/terminal records by command,
position and iteration, carries start/error context between polls, and counts
`job succeeded` as success only with a known run start and no observed ERR/FTL
or error/fatal records in that run. A scheduler failure or an error inside a
zero-exit wrapper still fails the job check. Per-library `Completed at` lines
never establish whole-job success. A terminal record without its start/error
context is completed-unverified until a complete run is observed. Unsupported
logging formats can still use an explicit producer receipt.

Producer receipts remain available for Recyclarr or definitive Kometa/Imagemaid
outcomes. From a real host-side post-run hook, invoke the script with the
canonical job profile, actual exit code, and optional Unix start timestamp:

```bash
/bin/bash /path/to/docker_service_watchdog.sh --record-job recyclarr 0 1795270000
```

Do not run that command from a container-start hook or on a timer as proof of
success. The producer must call it only after the actual job finishes, with a
reliable result. No post-run hooks or container schedules are modified by this
repository update. A producer may instead atomically write JSON to a configured
host receipt path:

```json
{"startedAt":1795270000,"finishedAt":1795270060,"successfulAt":1795270060,"exitCode":0}
```

For failure, use its nonzero exit code and `successfulAt:0`. All fields are integer
Unix timestamps except the exit code. `--record-job` serializes updates and retains
`successfulRuns` history, so multiple producer receipts between scans are not
lost. These host receipts override the default native/log source. Jobs are never
automatically restarted simply because processing failed, ran late or overran.

Reference implementations: [Metafusion runtime status](https://github.com/ray-cys/metafusion/blob/main/helper/runtime.py),
[Kometa run completion](https://github.com/Kometa-Team/Kometa/blob/master/kometa.py),
[ImageMaid run summary](https://github.com/Kometa-Team/ImageMaid/blob/master/imagemaid.py),
[Plex API](https://developer.plex.tv/pms/),
[qBittorrent WebAPI](https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-%28qBittorrent-5.0%29).

### Independent execution monitoring

Deploy `docker_watchdog_liveness.sh` as a **second** User Script and optionally
schedule it every five minutes. It must run independently of the main watchdog;
neither file installs or enables a schedule. Keeping both in GitHub does nothing
to the running server.

The main watchdog records start, finish, last successful scan, exit status,
consecutive execution failures and skipped-lock runs under
`/run/docker-service-watchdog/heartbeat.json`. A completed scan that finds an
unhealthy container still counts as a completed monitor execution. Missing vault,
notification failure or a monitoring/state error does not count as success.

The independent script detects missing/invalid or previous-boot heartbeat,
successful completion more than 15 minutes old, a running/stuck execution over
10 minutes, and three consecutive execution failures. Boot grace is five minutes.
It reports the dominant condition, suppresses unchanged notifications and sends
one recovery notification. Failed delivery remains pending. It performs no
container recovery and does not depend on vault: its bounded 64 KiB log and state
live in `/run/docker-watchdog-liveness` and reset at reboot. If the User Scripts
scheduler itself stops executing both scripts, an external monitor is still
needed; no local script can detect its own permanent non-execution.

Liveness v1.1 uses one bounded heartbeat snapshot per scan, validates numeric
configuration and notification-state schema, and identifies missing dependencies
in its execution output. Notifications include condition-specific evidence,
measured age/runtime or failure count, thresholds, and an operational action.
Temporary files are tracked and cleaned on normal/signal exit; delivery and
checkpoint failures leave transitions retryable. Corrupt state is retained as
`state.json.invalid` (bounded to the configured read limit) before the checker
rebuilds its checkpoint after successful delivery. State format remains v1, so
existing valid notification checkpoints are retained without a reset.

### Maintenance

Deploy the accompanying appdata backup v3.6 and Plex DBRepair v3.3 scripts to get
automatic per-container leases during their maintenance. Leases live under
`/run/docker-service-maintenance`, are independent per producer, and record boot,
PID, process start identity, and expiration. Shared per-container locks serialize
lease creation against watchdog recovery. A process that has exited cannot keep
suppression alive through PID reuse. An active maintenance owner overrunning its
lease becomes a warning and continues to block recovery for safety.

Manual example for a Docker update or planned shutdown:

```bash
/bin/bash /boot/config/plugins/user.scripts/scripts/docker_service_watchdog/script \
  --maintenance plex-media-server 60 "Planned Plex update"
```

Manual leases expire within 24 hours. Remove
`/run/docker-service-maintenance/plex-media-server.manual.json` to end that lease
early. An expired manual lease no longer suppresses checks, and reports a warning
until removed. Availability observations are frozen during maintenance; prior
issues are not falsely marked recovered. Restart/log-size/OOM monitoring resumes
after maintenance and startup grace. Logs rotate during writes at 1 MiB, with
one retained generation. Oversized logs inherited from older releases retain
only their most recent configured number of bytes. Monitor state and receipts
retain their existing paths.

## Pre/post reboot audit v2.0

Run `capture` while the array and expected services are still running, before
shutdown teardown. Run `compare` after the next boot. The script installs no
shutdown or startup hooks. Do not use a periodic capture that could overwrite the
intended pre-reboot state.

```bash
/bin/bash /path/to/pre_post_reboot_audit.sh capture
/bin/bash /path/to/pre_post_reboot_audit.sh compare
# For an intentional OS/plugin/image upgrade:
/bin/bash /path/to/pre_post_reboot_audit.sh compare --expected-upgrade
```

`auto` captures only when no baseline exists. It preserves an existing current-
boot baseline and compares one from a previous boot. Comparison never advances
the baseline: explicitly capture again after reviewing/accepting changes.

Captures require complete enabled collectors and protected inventory checksums.
Failed capture preserves the existing baseline. v1 baselines must be recaptured;
they do not provide v2's collector coverage and integrity evidence. An interrupted
baseline swap can leave `.previous-baseline`/`.new-baseline` for review; do not
remove a previous baseline without verifying the active one first.

Disk comparison uses serial/WWN identity, size, model, and assignment IDs rather
than Linux device enumeration. Configuration checks use file hashes. The audit
also records plugin versions (common PLG version fields, with a manifest hash
fallback), OS/kernel versions, Docker image IDs/digests, service inventories,
normalized global addresses/routes, and UUID-based mount evidence where available.
Missing disks and assignment changes are critical; configuration changes and
missing prior services warn; added resources are informational. Expected upgrades
make version/image changes informational without hiding missing plugins/services.

VM checks default off. Enable `CHECK_VMS=true` only if libvirt is expected before
and after reboot; `virsh` and `xmllint` are then required. VM identity uses UUIDs,
and inactive XML is canonicalized before hashing. Canonicalization removes XML
formatting differences, but changes libvirt makes to persistent configuration can
still legitimately warn. Kometa/Recyclarr are excluded from running-state drift.

Comparison waits for array, vault, Docker, and optionally VM readiness. An
incomplete startup/collection produces one deferred notification per baseline and
boot, retains the baseline, and allows a later comparison retry. It does not
install a retry schedule. Once complete, comparison is checkpointed and duplicate
reports are suppressed. `--force` explicitly repeats a completed comparison.
Successful unchanged comparisons are silent unless `SEND_SUCCESS_NOTIFICATION`
is enabled; an earlier deferred audit still receives a completion notification.

The small baseline, lifecycle checkpoints and a 64 KiB rotating log remain on
flash. Full reports and at most five historical inventory directories go to vault.
Both scripts write status receipts for the optional weekly operations audit.
Neither script repairs configuration, changes disk assignments, or updates Docker
images. These scripts should be verified on the target host before enabling
automatic recovery or relying on reboot audit coverage.
