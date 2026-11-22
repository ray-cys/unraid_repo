# Personal Arr and quarantine automation

The four standalone scripts cooperate through durable receipts in their existing
log/state directories. No shared runtime script, extra cron job, API-key file or
watchdog is required. Keep the current schedules. New notifications use the
existing grouped delivery, deduplication, size limits and emoji filtering.

## arr_health_activity.sh 3.13.1

The five-minute monitor now captures native import evidence, audits quality
configuration, retries allowlisted transient imports, and performs bounded
missing-media searches. Existing policy-rejection automation remains enabled.

### Action timing and budgets

New policy mutations, import retries and missing-media searches use the approved
Singapore-time windows: **00:00, 04:00, 08:00, 12:00, 16:00 and 20:00**, for the
first ten minutes of each hour. Configure `AUTOMATION_TIMEZONE`,
`AUTOMATION_BATCH_HOUR_OFFSET` and `AUTOMATION_BATCH_WINDOW_MINUTES` to change
this alignment. Monitoring, read-only recovery and receipt capture continue
outside those windows.

All three action types share the existing **two actions/run, four actions/rolling
24 hours** budget. An action can involve a verified rejection plus one search;
it does not mean two independent replacement searches. Unverified mutations
block new actions. Requests are journaled and flushed before submission, then
read back using exact command IDs and requested fields. A timeout never causes
a blind replay. Another native search/import command running in that app defers
our command without starving the other app.

`ARR_AUTOMATION_ENABLED=false` pauses new actions across these workflows while
monitoring and receipts continue. `POLICY_AUTOMATION_ENABLED` separately controls
the original rejection workflow. No automation changes monitoring, quality
profiles/custom formats, native schedules, or Docker state.

### Transient import retries

Only completed Usenet jobs with explicit **busy/locked-file** messages qualify.
Every reason must be allowlisted; mixed permission, capacity, identity, policy or
unknown warnings remain protected. An automatic retry:

- Waits at least six hours after completion and queue addition, then requires
  two stable observations separated by at least four minutes.
- Requires exact download/grab/episode/movie identity, monitored parents and
  seasons, no tags/retirement holds, complete healthy APIs, and no active SAB job.
- Rechecks current queues, target monitoring and complete target history directly
  before submission. Any retained file-deletion event vetoes the action so a
  delayed unmonitor cannot cause an intentional Plex deletion to be imported again.
- Restricts the scan to the native completed-download subdirectory configured by
  `AUTOMATION_SONARR_COMPLETE_ROOT` / `AUTOMATION_RADARR_COMPLETE_ROOT`.
- Sends `DownloadedEpisodesScan` or `DownloadedMoviesScan` with the exact
  `downloadClientId`, path, and **Auto** import mode. Arr still applies all of its
  import decisions; this is not a manual/forced import.
- Allows at most three attempts per download, separated by at least four hours.

A transient lock has no authoritative read-only "now unlocked" API. The bounded
Auto scan is an attempt, and is reported as such. Permanent errors are not
silently repaired or reclassified as success. Actual native import scans can
access download/media disks as part of importing. Routine health/profile/
receipt checks do not directly traverse physical library directories.

### Missing-media searches

A complete wanted/missing survey runs weekly, within an action window, inspecting
at most four rotating new candidates per app. Both scans in that window share
the same candidate set. Native searches are exact `EpisodeSearch` / `MoviesSearch`
commands; no series/season-wide or unlimited searches are issued.

**The first survey protects the pre-existing missing backlog.** Native history
may have been pruned, so the script cannot prove whether an old missing item was
intentionally deleted in Plex. It records baseline IDs and does not silently
redownload that backlog. This is intentional preservation, not a failed search.

Subsequent candidates must be monitored, missing, available/at least a day past
air date (or a day after movie addition), untagged, outside all active parent
queues, and stable on two scans. Complete exact-target history must contain no
file deletion or prior import, and no grab within seven days. Durable import
receipts and unresolved/ignored download ledgers also protect existing deletion
intent. Unknown manually queued SAB jobs in that category defer speculative
searches. Current monitoring/history/queues are rechecked just before dispatch.
Each exact target can be searched at most once per seven days, under the shared
global budgets. No available compliant release is a valid pending outcome.

### Profile changes, including Recyclarr

The script audits native quality/custom-format catalogs hourly and during action
windows. It checks that allowed qualities and the quality cutoff agree, referenced
format IDs exist, and the minimum score does not exceed the theoretical sum of
all positive scores. This upper-bound check does not claim every positive format
can match together or that a release is available.

Changes to native quality/custom-format definitions generate one grouped notice
and hold new actions for four hours. Impossible/inconsistent settings generate
specific lifecycle warnings and hold actions until corrected. The script never
lowers a score or overwrites Recyclarr/native configuration.

### Durable import receipts and action recovery

Native `downloadFolderImported` events are captured while history is available.
Two older completed SAB jobs per scan are also considered for backfill; pruned
history cannot be fabricated. Receipts retain exact download, native event,
movie/episode/parent and **file IDs**, original paths, TVDB/TMDB identity when
provided, import times and immutable SAB job identity. If incremental history
omits embedded resources, up to four exact native file/parent lookups per scan
fill the identity after proving the original path, or an original native event
that still exposes the same external ID. Enriched identity is retained when a
later compact history entry omits it. They remain for 365 days.
Conflicting evidence is preserved and is not used for quarantine.

Accepted/completed search/scan commands do **not** prove a successful import.
Read-only follow-up verifies a fresh exact current file, current profile, stable
identity and two positive scans. Retry recovery also requires an exact-download
import receipt. A negative hasFile observation resets the grace period. This
can resolve an uncertain command if its actual import result is independently
proven, without replaying it. A missing/unverifiable result remains pending.

Accepted and subsequently completed commands share one delivery signature;
command completion alone does not send an extra "success" email. A later proven
import, command failure or changed issue is a meaningful lifecycle update.
Notifications include the target/download ID, original warning, request/path,
command ID, native error where supplied, actual outcome and preserved data.

Read-only CLI:

```bash
/bin/bash /boot/config/plugins/user.scripts/scripts/arr_health_activity/script --automation-status
/bin/bash /boot/config/plugins/user.scripts/scripts/arr_health_activity/script --policy-actions
```

`--automation-status` summarizes baseline counts, profile holds, and the most
recent 50 actions. It creates no state and sends no notifications. `intent`
means acceptance is unknown: inspect native commands/history before making an
operator decision. Never erase a journal merely to make a request repeat.
`automation-actions.json` and `import-receipts.json`, each with one backup, live
beside the existing monitor state. Unfinished/failed commands remain auditable;
completed audit records/events retain up to a year. Unchanged documents are not
rewritten. Existing log rotation is unchanged.

## arr_sabnzbd_cleanup / sabnzbd_cleanup.sh 2.5.0

The cleanup script can use the monitor's `import-receipts.json` when native
history is pruned or its original imported path has changed. It checks exact SAB
job identity, exact current episode/movie/file IDs and native TVDB/TMDB identity,
then resolves and checks the current physical library file. A rename is accepted
for the same file ID and stable external identity. Older receipts without that
identity can authorize only their original exact path. A different file or
incomplete pack remains protected.

Source video enumeration now checks traversal success; an unreadable subtree
cannot look like zero media and bypass completeness checks. Partial packs still
need enough individually proven imported files to account for their remaining
videos. Native policy dispositions remain distinct from import proof.

Existing source/device/path/Mover/queue/permission safeguards and timing are
preserved: **336 hours completed age**, **24 hours path stability**, then
**14 days in quarantine**. Detailed reports identify current source/destination
and whether proof came from history, durable file IDs, or a policy disposition.

## arr_delete_sync_tag.sh 2.4.0

`AUTO_RECOGNIZE_KNOWN_AUXILIARY=true` adds narrowly scoped late-sidecar rules:

- Direct JPEG/PNG/WebP artwork in `.actors`, `actors`, `extrafanart` or
  `extrathumbs`, checked by binary signature; `.tbn` must contain JPEG data.
- `.DS_Store`, `Thumbs.db` and `desktop.ini` at the media-directory root, checked
  by named binary/INI signatures and the normal sidecar size bound.

These new types enter **late candidates**, even if the ordinary manifest is
captured first. They require two identical path/size/hash observations before
quarantine. Arbitrary images/directories, invalid signatures, symlinks, special
entries and remaining videos remain blockers. Empty directories still use
`rmdir`; media is never recursively deleted. Existing explicitly configured
extension rules, retirement holds, exclusions, permissions, API verification
and once-daily grouped delivery remain intact.

## quarantine_lifecycle.sh 1.5.0

Expired managed runs larger than the purge budget now drain incrementally rather
than remaining oversized forever. The default pass is bounded by **10 GiB,
250 regular files and 25 touched/completed runs**. Smaller fitting files/runs can
still progress. A single file larger than the byte cap or an unknown special
entry is preserved and reported, not split or force-deleted.

Each selected entry has a durable inventory receipt and an individual intent.
Its canonical path, inode/device, mode, size, mtime and ctime must still match
immediately before unlink. Every unlink is followed by absence verification and
parent-directory flushing. Interrupted absence is reconciled without repeating
deletion; a changed object is preserved for review. Referenced receipts stay
pinned. Partial passes remove only individually verified files and use `rmdir`
for newly empty directories. Complete small runs retain the existing verified
whole-run purge path.

The **45-day retention**, **24-hour idle** and Mover rules still apply. Changes
made by a partial pass can therefore require another idle period before the next
pass; the scheduled script resumes automatically. Notifications distinguish
complete runs from partially drained runs, include actual file counts/bytes and
filenames, and state what remains. Existing audit/restore/pending-operation CLI
and daily grouped notifications remain available.

## Deliberate review boundaries

Unknown files, old ambiguous missing backlogs, changed quarantine objects,
unverifiable API mutations without an independent outcome, conflicting receipts,
and incorrect user quality policies cannot safely be guessed away. They stay
protected with specific notifications. Routine temporary API/Mover/path-idle
conditions automatically defer and retry without requiring acknowledgement.
