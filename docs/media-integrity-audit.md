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
resumable backlog/maintenance deferrals are silent. Verified replacements send a grouped completion notification.
Active media findings, unexpected worker/storage failures, checkpoint fallback and
incomplete/uncertain/overdue recovery produce one grouped attention email with
file names, IDs, actions, original/replacement paths and evidence. Progress alone never
changes an incident signature. The same unresolved evidence reminds at most once
per week; new/changed issues can notify sooner. No per-file emails are sent.
Delivery failure retains one pending outbox and retries while still relevant; a
stale report is cleared locally if the condition is now healthy. Email is bounded
to 24 KB and representative entries; exact findings remain in state. No success
email is sent simply because an old issue was resolved.

`/mnt/vault/cloud/logs/script/media_integrity_audit` owns:

- `state.json.gz`: current queue, identities, progress, findings and 12 run summaries.
- `state.previous.json.gz`: previous validated checkpoint, retained once per run.
- `recovery.json`: durable Arr intents, exact target IDs, original/replacement identities, bounded events and exact-target holds. Required backup material, unlike the optional rolling decode queue. Never delete it to clear an unresolved hold.
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

## Arr-native replacement (v2.0.0, disabled by default)

`AUTO_RECOVERY_ENABLED=false` remains installed on Hubble. Observe several weekly
runs before enabling it in the script. No CLI/environment argument overrides
this switch. The persistent `recovery.json` is installed as an empty
`{"schema":1,"workflow":"arr-native","actions":{}}` document; missing, invalid,
symlinked or legacy workflow state stops mutations. Never delete the journal to
clear an unresolved job. Deployment confirms no legacy recovery exists before
installing this contract; it performs no legacy media moves or migration.

The script retains the original at its existing library path and leaves Arr's
file record and monitoring unchanged. Arr owns normal download/import/recycling.
The only permitted mutation in the recovery API helper is **POST /release**.
File DELETE, monitoring PUT, profile changes, blocklisting, forced/manual import,
filesystem moves and custom bin handoff have been removed.

Process:

1. Require a repeatable decoder error on the same filesystem version in two
   distinct runs, evidence at most 48 hours old, and the same decoder runtime.
   Read/resource/permission/timeout failures do not authorize replacement.
2. Prove exact monitored Arr parent/file/episode ownership, native external ID,
   active season monitoring, no tags, current quality profile, quiet native
   health/queue/commands, free capacity and the unchanged physical original.
3. Query native interactive releases. Initial automation supports Sonarr v5 and
   Radarr v3 API resources and **Usenet** only. Sonarr v3 search resources are
   rejected rather than guessed. Unknown response fields or rejection formats,
   whole-season packs, partial/mismatched episode sets and ambiguous identities
   do not qualify. Exact multi-episode files can qualify when every mapped ID,
   season and episode matches the original file's complete target set.
4. Preserve profile-allowed quality ordering, revision, language metadata when
   present, minimum format score and non-decreasing score at equal quality.
   Preserve explicit Radarr edition. Reject previously grabbed candidates and
   the original scene release when known. Only allowlisted **existing-file**
   cutoff/preference/revision/score rejections may be bypassed. Unknown, minimum
   score, wrong identity, language, availability, blocklist or disabled-upgrade
   rejections remain vetoes. No profile or quality override is submitted.
5. Re-read current rules/identity/queue immediately before saving grab intent and
   sending one native release grab. Correlate exact GUID, source title, target
   IDs and new history IDs to one actual download ID. A lost response is never
   blindly repeated. Discovery retries at most daily; one attempted grab per
   pass, three per rolling week and one job per parent per 30 days bound work.
6. Track native queue completion/warnings and exact download history. A matching
   import event must identify the new file ID and path for each exact target;
   also re-read current parent external identity, import date and physical file
   version. Download completion/import alone is not integrity proof.
7. Give imported replacements bounded priority verification through the existing
   five-minute Arr monitor. These passes stat/decode only up to four exact
   replacement paths, without walking/pruning the full library queue. Reuse
   checkpoints and low-priority decoder limits, with at most 75 seconds worker
   time per pass. Normal weekly auditing remains Wednesday 09:30 SGT, two hours.
8. Mark `recovered` only after every exact current replacement passes all planned
   decode ranges. Arr recycles/removes the original using its normal policy;
   this script performs no second delete/move. Native import is not promised
   atomic, and native recycling retention does not wait for our verification.

The Arr monitor permits new grabs only in the first ten minutes of 00:00,
04:00, 08:00, 12:00, 16:00 and 20:00 Asia/Singapore, with new work starting before
minute seven. Follow-up and priority verification continue outside these windows.
`ARR_AUTOMATION_ENABLED`/profile controls can pause new grabs while observation
continues. Appdata/state-export/metadata locks and workload guards remain in use.

Sonarr series and individual Radarr movies with unresolved jobs are excluded
from delete-sync/retirement, generic missing searches, import retries and policy
rejection/replacement. This prevents the policy cleaner treating a needed
replacement as redundant simply because the damaged original is still present.
Unrelated series/movies continue. Native Arr RSS/import tasks do not obey script
locks: fresh pre-grab checks reduce races, not provide a global Arr transaction.

## Grouped replacement notifications and state

Healthy ordinary scans are quiet. Findings requiring replacement, newly tracked
downloads, blocked/uncertain actions, overdue verification and **verified
replacement completions** are grouped in a single notification per reporting
pass, with filenames, selected release, target/file/download IDs, actual action,
reason and recent transitions. Completion says a replacement was performed by
Arr and fully verified, without claiming our script moved the original.
Delivered event keys suppress repeat completion emails. Failed delivery remains
pending and is retried; unchanged incidents remind at most weekly. No emojis.

`recovery.json` keeps each original identity, finding, current profile snapshot,
selection decision, grab intent, baseline/native history/download IDs, native
queue/completion status, replacement file identities, decode outcome and at most
32 significant transition events. Poll timestamps do not append events. Completed
jobs expire after one year; unresolved jobs do not silently expire. Raw download
URLs, full API responses and API keys are not logged in events/notifications.
The existing ISS operational-state export includes the required recovery journal.

Native bin retention on Hubble is currently two days. Verification older than
24 hours produces attention so it can be investigated before that period ends.
Workload deferrals, long/slow files and errors may exceed retention; **there is no
guaranteed original rollback**. A 28-day missing-import deadline requires review.
The script never changes bin retention or Plex configuration. Leaving originals
in place removes the prolonged Plex-missing and media-mirror deletion gap, but
normal Arr import can still expose a short file transition.

Commands (no new User Scripts schedule required):

```bash
script=/boot/config/plugins/user.scripts/scripts/media_integrity_audit/script
/bin/bash "$script" --version
/bin/bash "$script" --recovery-status
/bin/bash "$script" --recover-only  # exits immediately while recovery is disabled
```

`--recovery-status` includes the exact job state, selected release, download,
replacement IDs and bounded event history. Unknown/blocked cases retain the
original, stay protected and report why automation stopped. They never trigger a
fallback deletion or forced import. Release metadata and SAB completion cannot
prove an uncorrupted source; post-import decoding supplies the integrity evidence.
