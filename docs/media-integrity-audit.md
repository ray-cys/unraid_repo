# Media Integrity Audit

`user_script/media_integrity_audit.sh` installs as `media_integrity_audit` on Hubble.
The existing Bazarr container supplies Python, FFprobe and FFmpeg; no host package,
container, mount, image, startup setting or application configuration is added.

## Schedule and scope

Run Wednesdays and Sundays at 07:00 Asia/Singapore, for up to two hours per invocation. Set the single User Scripts custom schedule to `0 7 * * 0,3`.
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
library can be fully rechecked within 180 days under two scheduled two-hour runs per week.

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

Backup Health Audit checks the new schedule, overdue scheduled completions and failed
notification delivery, without repeating individual media errors. The ISS vault
workflow includes the compressed queue in its existing operational-state export.

## Findings and recovery

A nonzero decoder failure is repeated on the same unchanged file and planned
range with wider seek context when budget permits. Probe-only failures remain
unverified container findings; they never authorize replacement. "Repeatable decoder error" is evidence requiring review, not
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

## Arr-native replacement (v2.1.1, disabled by default)

`AUTO_RECOVERY_ENABLED=false` remains installed on Hubble. Observe several scheduled
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
   time per pass. Normal auditing runs Wednesday/Sunday 07:00 Singapore time, up to two hours each.
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

Native bin retention on Hubble is currently two days. Verification alerts up to
twelve hours before the observed retention deadline, then escalates if it elapses.
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

## Recovery reliability enhancements (v2.1.1)

- External recovery: match stable external IDs, exact targets and physical files.
  A current external replacement receives priority verification and closes only
  after full planned-range proof; the notification does not attribute it to our
  grab. Native monitoring switched off cancels only while the exact original
  remains present. An unchanged original that passes a full later cycle can
  resolve without falsely claiming a replacement. These terminal states release
  only their own series/movie guards; unrelated automation continues normally.
- Capacity: recheck the selected release size against the real configured
  incomplete/complete directories and library filesystem. Allow packed/unpacked
  download space, an import copy, ten percent estimate overhead and 10 GiB reserve.
  Combine paths on a common device, avoiding duplicate reserve accounting.
  This checks visible filesystem free space, not a guarantee of Unraid placement,
  share minimum-free settings, or unexpected archive expansion.
- Native retention: read the existing Arr bin policy without changing it. Use the
  native import timestamp for the verification deadline and alert before expiry
  (up to twelve hours early; at most half the native retention). Escalate once
  when retention has elapsed. A zero-day policy means native timed cleanup is
  disabled; unknown/no deadline falls back to a 24-hour attention threshold.
- Fair verification: select up to four exact paths by oldest actual decoder
  attempt, then retention deadline. When stale corruption evidence needs refresh,
  reserve one slot for its original failing range; at most one original per pass,
  at least 24 hours between attempts and only when evidence is older than 48 hours.
  No full-library walk or lowering the two-confirmation/freshness safeguards.
- API reads: at most two attempts for transient GET failures, with request and
  executor deadlines. POST is never retried. History reads use at most ten pages
  of 200 records, reject unstable totals/duplicate IDs and require exact download
  IDs. Per-job diagnostics include operation, HTTP result and transport exit,
  without keys or full API responses.
- State: skip structurally unchanged writes, coalesce routine progress/poll
  heartbeats to fifteen minutes, validate before publication and retain one
  validated `recovery.previous.json`. Required intents and outcomes are still
  synced immediately. Never automatically restore an older journal to permit
  mutations: an older copy may predate a submitted request. The existing ISS state
  export carries both journals when present, giving them priority over bulk scan
  progress. Missing/corrupt current state remains a protective stop.
- Alternatives: initial grab plus at most one alternative per job, after at least
  four hours, inside an approved action window and the shared action/week budgets.
  Require exact native download/target failure history, an eligible archive/repair
  failure, no prior successful import, and the unchanged monitored original under
  the original profile. Storage, permission, manual, ignored and unknown failures
  require review. Failed GUID/title is excluded, no automatic blocklist/profile
  change, and lost responses are not replayed. Retry-wait/failure/completion
  updates remain grouped and delivery-tracked.

A cleared original-file warning is not itself a complete recovery: priority
verification finishes a fresh full decode cycle before releasing the job as
resolved, without claiming that a replacement was downloaded.

## Decoder evidence policy (v2.3.0)

A successful FFprobe run with valid stream/duration metadata does not become a
corruption finding merely because stderr contains “truncated” or “corrupt”. The
narrowly recognized H.264 SEI type-5 user-data and reference-startup diagnostics
are retained as nonfatal advisories. Unknown diagnostics remain unverified and
visible; they are not silently ignored. This does not guarantee invisible
playback artifacts are absent.

Deep checks use `-xerror -max_error_rate 0`, positive video-frame progress and
planned output duration. A failed seek is retried with up to 30 seconds of
preceding context. A successful context retry must pass the same frame/duration
checks before receiving range credit. A repeated nonzero decoder failure must
have matching normalized diagnostics, file identity, planned range and toolchain.
Two separate audit invocations must confirm that same evidence before any Arr
replacement is eligible; repeating a tool in one invocation counts only once.
Tool/resource/access failures and metadata-only findings never qualify.

Legacy corruption findings without this decoder proof lose replacement
eligibility and are re-evaluated. Valid metadata with a recognized nonfatal
probe diagnostic withdraws the old classification, preserves its evidence in
resolution history, and sends one grouped correction. The original media stays
unchanged and full-range verification remains pending. Routine advisory logs and
healthy progress do not generate repeated email.

Worker messages are newline-framed and bounded. The host retains partial input
across read timeouts; malformed, oversized or incomplete messages fail the scan
without creating a media-corruption finding. The last committed checkpoint is
retained, and complete-library coverage is never inferred from a short check.

## Independent stream confirmation (v2.4.0)

Strict decoding is a screening check, not sufficient replacement evidence. After
matching strict failures with wider seek context, the worker checks individual
video/audio streams with normal FFmpeg error handling (without `-xerror` or the
zero frame-error threshold). It uses up to 120 seconds of preceding context,
starting from the beginning for early ranges. Confirmation is capped at 90 wall
seconds within the remaining audit budget and eight streams. Insufficient time,
unknown failures or excessive stream counts leave the finding unverified.

The default video and audio tracks are primary; if a type has no default flag,
the first track of that type is primary. Other tracks are still checked. This is
a conservative automation policy, not a prediction of which track a Plex user
will select. Failures confined to additional tracks require review and never
trigger automatic whole-file replacement. Stream index, type, codec, primary
selection, exit result, progress and bounded diagnostics are stored in the issue.

The resulting categories are:

- **Advisory:** narrowly recognised nonfatal diagnostics or successful seek-context
  recovery. Retain evidence; routine healthy checks remain quiet.
- **Audit/unverified:** killed/crashed processes, unsupported tools, permissions,
  resource/time limits, storage reads, timestamp/filter/encoder/output problems,
  incomplete progress or ambiguous container/stream evidence. No replacement.
- **Recoverable media defect:** strict decoding fails repeatedly but every normal
  stream check completes. Keep range coverage pending and request review; decoder
  error concealment is not proof of undamaged playback. No replacement.
- **Additional-track defect:** failures are confined to non-primary tracks and
  other checks complete. Report the affected tracks for review. No replacement.
- **Replacement candidate:** an isolated primary-stream decoder failure persists
  under normal handling, with matching unchanged-file/range/toolchain/stream
  evidence across two separate audit invocations. Existing exact Arr mapping,
  monitoring, profile, capacity, action-window and import/recycling safeguards
  still apply. Recovery remains disabled by default.

Negative/signal process exits and common wrapper kill/crash statuses are excluded
before diagnostic-text matching. Generic “invalid data”/“corrupt” wording alone
cannot create replacement proof. Previous proof versions cannot authorise new
recovery actions; existing native downloads/imports remain protected and followed.

Transient timeout/resource/process failures get at most one additional attempt
per file per invocation, with smaller ranges where applicable and sufficient
remaining time. First transient findings stay visible in the local report but do
not email. Recurrence in a separate invocation or age of at least one day makes
an unresolved finding alertable. Storage read failures and other actionable
findings continue to notify without authorising replacement. Existing coverage
stall and missed-run monitoring remain independent.

Grouped reports distinguish replacement-candidate counts from audit/review
findings and include per-stream results. Existing deduplication and weekly
unchanged-incident reminders remain in effect; healthy progress is quiet.

## Coverage and last-checked reporting (v2.5.0)

Every local report, and any notification already warranted by findings or recovery
updates, includes these details calculated from saved state:

- Per-run **unique** files attempted, opened, metadata-probed successfully, given
  passed decode ranges, left partially decoded, and fully verified. Repeated
  probes/range retries do not count as additional media files. Existing tool/range
  operation counts remain separate.
- Overall and per-library coverage: fully verified current versions, partial
  decode coverage, metadata-only coverage, attempted but unverified, and untouched.
  These five coverage buckets are disjoint. Deferred, blocked and periodic-due
  counts overlap those buckets. Work remaining counts each file once, including
  a previously verified version due for its periodic recheck.
- Per-library inventory status: complete, partial, unavailable, not started, or
  limited to a targeted recovery scope. Finishing inventory means discovering
  paths; it does not mean those files were fully decoded.
- The last attempted file and outcome, last successful check and its type, and
  last passed decode, with timestamps and saved resume positions. Metadata success
  is explicitly different from full-file verification. These are historical
  activity records, not an alphabetical continuation promise.
- Counts of media-containing parent folders with complete, in-progress and
  untouched coverage, plus overlapping pending/blocked/deferred totals. Up to three
  recent, pending and blocked folder examples are included. Empty directories,
  excluded files and ancestor-only folders are not counted.

The structured status receipt exposes these details under `progress`, with the
same bounded folder examples used in `latest-report.txt` and email. No directory
walk, media read or extra API call is performed to render this coverage summary.
Progress updates do not alter notification incident signatures or cause healthy
emails. The existing schedule and notification reminders remain unchanged.

Counters and explicit last-success tracking begin with v2.5.0. Older runs show
“not recorded” where the evidence did not exist, rather than inventing historical
counts or declaring an arbitrary file the last success. Existing saved file
coverage and offsets remain usable immediately and are not reset.

## Coverage correctness, recovery and capacity (v2.6.0)

- Every decode interval, including short files and final tails, must report
  positive progress reaching its planned duration. Timing tolerance scales with
  range length and is capped at 0.5 seconds; there is no ten-second exemption.
  Stream confirmation uses known per-stream start/duration information where
  available, so a legitimately shorter additional track is not required to
  extend across the whole container timeline. Ambiguous short output stays
  unverified and never independently authorises replacement.
- Incidents retain the original failed interval. Two clean passes must cover that
  entire interval; reducing chunks after a timeout cannot resolve a larger failed
  range with only its first smaller piece. Audit limitations are stored separately
  in `auditIssue` when a media finding already exists. Successful probes resolve
  probe-stage limitations without clearing decoder incidents. Native recovery
  completion additionally requires current duration-proof policy 2.
- Old decoded prefixes/full-cycle proofs without the new duration policy are
  queued for verification again. The old values remain in `priorCoverage` for
  explanation; cached metadata, inventory and native recovery journals are kept.
  In Hubble’s pre-update state this affects four partial prefixes, not all 9,993
  cached metadata records. Replacement evidence now uses proof version 4.
- Notifications show replacement candidates first, then storage errors, then
  other actionable findings. Quiet first-occurrence transient findings do not
  consume the display slots. Omitted counts are explicit; previously omitted
  findings rotate within their priority group on later delivery opportunities.
  Rotation/progress does not bypass deduplication or cause another email on the
  second weekly run. New findings, native recovery events and delivery retries
  retain their existing behaviour; unchanged-issue reminders remain seven days.
- Checkpoints are bounded and semantically validated before publication, including
  schema, normalised relative paths, identity shape, finite progress and failed
  intervals. New data is flushed, and the current valid file is renamed into the
  previous-checkpoint slot without making another full copy. An invalid current
  file cannot poison the last valid rollback. Failed publication restores the
  previous current file; invalid reporting state is never displayed as healthy
  empty inventory.
- Three consecutive successful ranges gradually grow a reduced chunk back toward
  the configured ten-minute cap. Resource failures reset the clean streak. CPU,
  memory, thread and overall runtime limits do not increase.
- Decoder signatures remove memory addresses, presentation timestamps, duplicate
  lines and repeated-message summaries. Stream numbers, diagnostic numbers,
  offsets and codec details remain significant. File/range/toolchain checks are
  unchanged, so log formatting alone no longer prevents matching confirmations.
- Capacity uses up to six real, non-targeted scan samples with
  at least an hour of configured worker budget. Gracefully limited runs still
  count at their actual net progress, so workload holds do not inflate the
  estimated weekly capacity. At least three samples are needed
  before warning about persistent stalls or a known-duration backlog exceeding
  the 180-day target. Estimates use net saved coverage progress per observed run,
  not optimistic synthetic decoder speed. Unknown durations remain explicit, and
  the estimate is a lower bound for known work, not a full-library completion
  date. Capacity warnings join existing grouped notifications with stable keys.

The live schedule is Wednesday and Sunday 07:00–09:00 Singapore
time. Sunday leaves one hour before the existing 10:00 media backup. Workload
guards remain active, so unexpected backups, parity/Mover activity or Plex
transcoding can still defer scanning. No backup or Docker schedule is changed.
Backup Health Audit retains the five-day completion/progress grace; meaningful
partial progress does not falsely claim a completed scan, and media findings or
capacity warnings are not duplicated in its notifications.

### Single User Scripts schedule (v2.6.2)

Use `0 7 * * 0,3` in the existing `media_integrity_audit` User Scripts entry.
Both runs are managed entirely by User Scripts, with no supplemental cron file
or duplicate script. Disabling the entry disables all scheduled runs. The normal
User Scripts schedule files and script are already included in the recovery
export. Weekly unchanged-issue reminders and the two-hour run limit are unchanged.
