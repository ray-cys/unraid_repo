# Media Integrity Audit

`user_script/media_integrity_audit.sh` installs as `media_integrity_audit` on Hubble.
The existing Bazarr container supplies Python, FFprobe and FFmpeg; no host package,
container, mount, image, startup setting or application configuration is added.

## Schedule and scope

Run `30 9 * * 3`: Wednesdays at 09:30 Asia/Singapore, for up to two hours of work.
The first scheduled run is 25 November 2026. Scope is the existing
`/mnt/user/media/{movies,series,formula1}` bind at `/data`. Download/quarantine
folders, the secure library, symlinks, ISO/IMG, standalone audio and subtitles are
outside verification. All selected video and audio streams inside ordinary video
containers are checked.

The scan reads real array media and can spin up drives. It requests low CPU and
idle I/O priority and limits decoder threads; I/O-priority effectiveness depends
on the kernel/storage scheduler. It shares Bazarr's container resources but does
not change that container's resource settings. A decoder has a 2-GiB virtual
address-space limit; hitting it leaves coverage unverified, not corrupt.

## Evidence and rolling work

Inventory identifies files by device/inode/size/mtime/ctime. New/changed files
receive quick container/stream checks first, for at most a quarter of the budget
(30 minutes by default). The remaining work uses overlapping ten-minute media
ranges; all planned ranges must succeed before a file cycle is complete. Large
files resume from confirmed ranges on the next invocation. A ten-minute recent-
change hold and before/after identity checks avoid credit for changing files.

This is not a single uninterrupted full decode or a checksum baseline. Damaged
seek indexes, incorrect duration metadata, unsupported codecs, timeouts and empty
or short decoder output can leave coverage unverified. A decoded range does not
certify untested ranges. Previously successful unchanged files become due again
after 180 days to avoid trusting metadata forever. There is no claim that a large
library can be fully rechecked within 180 days under a two-hour weekly budget.

Among eligible deep work, new/changed files receive a 60% time share and periodic
work 40% when both exist. In-progress files are resumed before new cycles. A
per-file time slice prevents a single file occupying the entire invocation;
slow timed-out ranges shrink on retry. Estimates use measured decoding throughput
and known durations only; unknown files, codecs, retries and maintenance deferrals
can substantially extend the full-library cycle. Adjust the budget only after
observing real coverage; no real-library throughput benchmark is performed during
installation.

Read-only sources are passed as verified open file descriptors to child tools.
The worker runs as UID/GID 99:100, with no shell interpretation of filenames.
Output goes to the null sink; bounded diagnostics stay in RAM. The worker owns
only a transient token/PID file in container `/tmp`, removed at completion. The
supervisor verifies token, command line and process start time before asking its
own worker to terminate. FFmpeg children have independent process groups that are
terminated and reaped on timeout/cancellation. Kernel-blocked I/O can still delay
termination; no interrupted range is credited as passed.

## Cooperation with existing scripts

Before and during work, check actual array/parity fields, Mover, existing backup
locks, Bazarr maintenance leases and Plex transcoder processes. Do not set User
Scripts `noParity=true`: its stale position check can incorrectly block work.
The audit's parity guard requires positive activity and position, rather than the
historical action label. Paused parity with zero activity is not active parity I/O.

The audit never holds backup coordination for its entire scan. Checkpoint commits
briefly share the operational-state export lock. Appdata backup may stop Bazarr;
then the last confirmed checkpoint remains and the unfinished range is retried.
No backup, Docker restart or media replacement is triggered by this script.

Backup Health Audit checks the new schedule, overdue weekly completions and failed
notification delivery, without repeating individual media errors. The ISS vault
workflow includes the compressed queue in its existing operational-state export.

## Findings and recovery

A known decoder/container error is repeated on the same unchanged file when
budget permits. "Repeatable decoder error" is evidence requiring review, not
proof of physical disk damage or irreparability. Permission/tool/resource/time
limits remain unverified. The first failing range stops that file; this is not an
exhaustive enumeration of every bad location. Failed files back off to future
schedules instead of being repeatedly decoded in the same run.

Two clean unchanged-file rechecks can close a previous failing probe/range. A file
version change preserves its old finding until the replacement completes its
planned ranges. Confirmed absence from a complete inventory closes the finding
as removed, not repaired. No state-driven operation deletes, moves, renames,
changes permissions on, repairs, quarantines or re-downloads any media.

## Reports and maintenance

One grouped weekly scan summary contains actual actions/counts, file names,
positions, diagnostic excerpts, recoveries, partial coverage and deferred work.
A healthy scheduled run also reports progress; no per-file emails are sent.
Delivery failure retains a single outbox. Active findings and 30-day recoveries
feed the next summary. Unchanged reruns within 24 hours are suppressed after a
successful notification. Email is bounded to 24 KB and representative entries;
all exact findings remain in compressed state.

`/mnt/vault/cloud/logs/script/media_integrity_audit` owns:

- `state.json.gz`: current queue, identities, progress, findings and 12 run summaries.
- `state.previous.json.gz`: previous validated checkpoint, retained once per run.
- `latest-report.txt`: overwritten readable summary, bounded like the email.
- `pending-notification.json` and `notified.json`: delivery retry/deduplication.
- `media-integrity-audit.log`: 1 MiB with two backups; backups expire after 30 days.

A standard compact receipt lives in `user_scripts_status/media_integrity_audit.json`.
An installed/scheduled receipt is not a completed scan. Inventory-only runs and
guard/worker failures do not refresh the completed-scan timestamp. Invalid state
never silently resets the queue; a valid previous state may be used with an
explicit warning, otherwise scanning stops and original files are preserved.

```bash
script=/boot/config/plugins/user.scripts/scripts/media_integrity_audit/script
/bin/bash "$script" --help
/bin/bash "$script" --status
/bin/bash "$script" --inventory-only
```

`--status` reads saved evidence without media/Docker access. `--inventory-only`
can wake drives and update inventory but does not probe/decode or send a normal
summary. A no-argument invocation performs the real scheduled scan.

To inspect every active finding without scanning media:

```bash
gzip -dc /mnt/vault/cloud/logs/script/media_integrity_audit/state.json.gz |
  jq '.files | to_entries[] | select(.value.issue != null) | {path:.key, finding:.value.issue}'
```

Do not delete state to hide findings or claim previously unchecked media healthy.
