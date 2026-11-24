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
No backup or Docker restart is triggered. Optional Arr recovery is installed but disabled. Its short executor uses the existing backup/metadata gates and audit lock; the long decoder scan never holds the appdata gate.

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
as removed, not repaired. With `AUTO_RECOVERY_ENABLED=false`, no operation deletes, moves, renames, changes permissions on, quarantines or re-downloads media. No environment variable or CLI flag overrides that switch.

## Reports and maintenance

Every invocation updates the local report and receipt. Healthy checks, normal
resumable backlog/maintenance deferrals and successful recoveries are silent.
Active media findings, unexpected worker/storage failures, checkpoint fallback and
incomplete/uncertain/overdue recovery produce one grouped attention email with
file names, IDs, actions, preserved paths and evidence. Progress alone never
changes an incident signature. The same unresolved evidence reminds at most once
per week; new/changed issues can notify sooner. No per-file emails are sent.
Delivery failure retains one pending outbox and retries while still relevant; a
stale report is cleared locally if the condition is now healthy. Email is bounded
to 24 KB and representative entries; exact findings remain in state. No success
email is sent simply because an old issue was resolved.

`/mnt/vault/cloud/logs/script/media_integrity_audit` owns:

- `state.json.gz`: current queue, identities, progress, findings and 12 run summaries.
- `state.previous.json.gz`: previous validated checkpoint, retained once per run.
- `recovery.json`: durable Arr intents, exact target IDs, preserved-original ownership and deletion-sync holds. Required backup material, unlike the optional rolling decode queue. Never delete it to clear an unresolved hold.
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

## Disabled automatic recovery and later activation

The installed version keeps `AUTO_RECOVERY_ENABLED=false`. Leave it off for
several weekly cycles. Review whether errors repeat on the same unchanged file,
which codecs are involved, how quickly coverage progresses, and whether any tool,
resource or permission errors are being confused with media damage. There is no
need to increase scan scope or install another package during observation.

After a separate decision to enable it, change that one switch in the User Script
(and GitHub together). Credentials and API roots are configured in the existing
script; the Arr monitor also passes its discovered roots/keys to the bounded
executor without placing keys in its command arguments or recovery journal.
Current supported contracts are Sonarr v5 (or compatible v3) and Radarr v3. The live read-only API schemas, Bazarr UID and preservation/no-overwrite behavior were verified with temporary files outside library folders; no live recovery was enabled or existing media changed.
Application/API incompatibility stops recovery rather than selecting a speculative
endpoint or replaying a mutation.

An eligible file must have a repeatable `decode_error` on **two separate audit
runs**, unchanged five-part identity, current-version findings at most 48 hours
old, and the same decoder runtime. Permission/read/resource/timeout failures and
unsupported codecs do not qualify. Upgrading the decoder resets confirmation
counts. Movies and series require exact Arr path/file ownership and monitored
native IDs. A multi-episode Sonarr file must map all its monitored episode IDs;
Formula1/unmanaged/ambiguous/unmonitored media remains review-only.

The existing Arr monitor invokes `--recover-only` within the first ten minutes
of 00:00, 04:00, 08:00, 12:00, 16:00 and 20:00 Singapore time. This preserves the
weekly scan schedule and four-hour action windows. While the switch is off the
executor returns before any API, Docker, media or state mutation. Normal read-only
follow-up can also run during the next weekly scan when enabled.

For each recovery, the script:

1. Checks mounts, current backups/Mover/parity/Plex workload, native health,
   commands and queues. Unknown ownership or incomplete queue pagination blocks
   action. Takes the existing backup and metadata mutation locks briefly.
2. Records a durable plan and preserves the exact original using Linux
   `renameat2(RENAME_NOREPLACE)`, with a same-filesystem no-overwrite hard-link/unlink fallback for Unraid shfs, under
   `/mnt/user/media/integrity_quarantine/ACTION_ID/ORIGINAL_FILENAME`.
   Cross-filesystem/unsupported/failed preservation stops; interruption with both names preserves both for review; a completed move can be resumed using exact identity without moving again; there is no bulk-copy fallback,
   overwriting or automatic purge. A changed identity prevents further mutation.
3. Records deletion intent, removes only the exact obsolete Arr **file record**
   and requires a 404 read-back. The original is already preserved. Title, profile, blocklist and global monitoring settings remain unchanged.
   Both live Arr applications have native unmonitor-on-delete enabled. Only
   targets proven monitored before this recovery may have that prior state
   restored, within 120 seconds of this script's own deletion, after confirming
   the native setting and exact missing IDs. Sonarr's series must remain monitored.
   Monitoring PUT intent/read-back is journaled; an uncertain/user-later change
   stops for review and is never blindly overwritten.
4. Confirms the exact target is still monitored and missing, persists search
   intent, sends one `EpisodeSearch`/`MoviesSearch`, and reads back its exact
   command identity/target IDs. A lost response is never blindly retried.
5. Holds deletion-sync until new exact Arr file IDs, import dates and paths match
   a later **complete planned-range decode cycle**. Replacement paths receive
   priority within the audit's new-work lane. Search completion or a new filename
   alone does not count as recovered. The damaged original remains retained.

The executor has a three-minute budget, examines at most four candidates per pass, and reserves the final three minutes of each action window for in-flight work. New preservation also requires free media space for the current file size plus 10 GiB. Capacity is a conservative share-level estimate, not a guarantee about every disk/download client.

Limits: one new recovery per pass, three per rolling seven days, and one attempt
per exact parent/target set per 30 days. An unsuccessful command, uncertain
request, changed monitoring or a 28-day verification deadline requires review.
Unresolved holds never expire silently. Review actions can close automatically through read-only follow-up once the exact current/restored file passes a later complete audit; no mutation is retried to obtain that result. Sonarr holds only its affected series;
Radarr delete-sync and generic missing searches conservatively defer the affected
application while a hold exists. Existing Arr queue/import monitoring continues.
No automatic blocklisting is inferred from a local decoder error: the release
might be sound and the local file might have suffered storage damage.

```bash
script=/boot/config/plugins/user.scripts/scripts/media_integrity_audit/script
/bin/bash "$script" --recovery-status
/bin/bash "$script" --recover-only  # harmless disabled result while switch is false
```

Review/uncertain actions list the original/quarantine paths, Arr IDs and reason in
`--recovery-status`, the local report and attention notifications. For manual
recovery, inspect source and preserved copies first; never overwrite a returned
file. A restored original needs an Arr rescan/import and audit verification. Do
not remove the journal/hold to claim success. There is deliberately no automatic
rollback that might overwrite a newly imported replacement.

Further tuning should follow several real runs: choose the runtime/segment size
from observed coverage and timeout rates, review codec-specific false positives,
and only then consider retention for **verified** recovery originals. Current
preserved originals are pinned, so inspect their total space before enabling
recovery at scale.

Implementation references: [Sonarr file-delete controller](https://github.com/Sonarr/Sonarr/blob/develop/src/Sonarr.Api.V5/EpisodeFiles/EpisodeFileController.cs),
[Sonarr monitoring lifecycle](https://github.com/Sonarr/Sonarr/blob/develop/src/NzbDrone.Core/Tv/EpisodeService.cs),
[Radarr file-delete controller](https://github.com/Radarr/Radarr/blob/develop/src/Radarr.Api.V3/MovieFiles/MovieFileController.cs), and
[Radarr monitoring lifecycle](https://github.com/Radarr/Radarr/blob/develop/src/NzbDrone.Core/Movies/MovieService.cs).
