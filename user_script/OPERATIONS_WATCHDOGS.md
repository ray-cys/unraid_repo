# Docker watchdog and reboot audit

These scripts are independent Unraid User Scripts. Keeping them in GitHub does
not install, enable, or schedule them. Review container names, URLs, paths, and
expected service states before deployment. Run scripts through `/bin/bash`.

## Docker service watchdog v2.0

Optional schedule: `*/5 * * * *`. Each rule is
`container|optional HTTP endpoint|always or on-demand|restart permission`.
Kometa and Recyclarr default to on-demand, so a normal stopped state is allowed.
Pi-hole is monitored by `dns_redundancy_watchdog.sh` instead.

Two consecutive bad scans confirm an availability failure. Two good scans clear
it. A changed issue set/severity produces one grouped notification; unchanged
conditions have no reminders. Notification delivery failures retain pending
transitions for retry. OOM and Docker restart-count changes are events, not
permanent availability failures. HTTP 2xx/3xx/401/403 establish reachability only.

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
