# Guarded Arr policy automation

See [ARR_AUTOMATION.md](ARR_AUTOMATION.md) for the shared action windows,
combined budgets, profile-change holds and the four-script integration.

`arr_health_activity.sh` 3.13.0 monitors Sonarr, Radarr and SABnzbd and can
resolve narrowly proven import-policy rejections. No additional schedule is
needed: keep its five-minute schedule and the existing four-hour import batches.
The monitor makes no direct library filesystem checks for these decisions.

## Eligible decisions

| Native decision and evidence | Automated action |
| --- | --- |
| Explicit no-upgrade rejection, exact existing file, current allowed quality and minimum score satisfied | Ignore the redundant download in Arr. Preserve the existing library file. No blocklist and no new search. |
| Explicit below-profile-minimum score, matching current numerical score and minimum, genuinely missing monitored media | Blocklist the exact rejected release and submit one exact episode/movie search with the current profile. |
| Unknown custom-format warning, mixed reasons, permission/identity problem, unsupported schema | Preserve and report through ordinary monitoring. |

The monitor never lowers minimum scores, changes profiles, forces an import,
launches whole-series searches, deletes download payloads, or changes monitoring.
A release or search rejected during indexer evaluation before it was downloaded
has no completed queue item and is outside this workflow. The existing native profile/RSS/search rules continue
to handle those indexer decisions.

Required safeguards:

- A completed Usenet job, complete healthy queues for both apps and SAB history,
  no active SAB entry, exact grab-history/download/media IDs, and one queue row
  across both apps.
- Six hours since both queue addition and SAB completion, followed by two stable
  scans separated by at least four minutes. Changed evidence restarts this grace.
- Sonarr requires a single grabbed episode, exact series/season/episode, and
  explicit single-episode release notation. Packs, multi-episode and partially
  imported downloads are preserved. Movies require one exact grab record.
- The movie or series and relevant episode/season must remain monitored. Any
  movie/series tag protects the item; this intentionally includes retirement,
  deletion, keep and hold tags, as well as other tags. Review this limitation
  before expecting tagged content to be handled automatically.
- Current profile allows the quality; an existing redundant file must satisfy
  its current minimum custom-format score. Replacement applies only when no
  file exists according to Arr. All reasons must match the allowlist.
- Fresh complete queue and complete identity/profile/history/file evidence
  immediately before the action. Monitoring and profile are checked again
  before submitting a replacement search.

## Bounds and recovery

Defaults in the monitor configuration:

- `POLICY_AUTOMATION_ENABLED=true` (false disables new policy processing).
- `POLICY_GRACE_HOURS=6`.
- `POLICY_MAX_ACTIONS_PER_RUN=2` and `POLICY_MAX_ACTIONS_PER_DAY=4`, shared by apps.
- `POLICY_BURST_LIMIT=5`: more simultaneous policy symptoms suspends new actions,
  with a grouped configuration-review notification.
- At most one replacement per exact target in seven days, three in thirty days.

Arr removal uses `removeFromClient=false`, `changeCategory=false` and
`skipRedownload=true`. Native automatic redownload cannot duplicate the explicit
single search. Unknown mutation outcomes are never automatically retried.
An unresolved checkpoint blocks new actions across both apps. Subsequent scans
read native queue/history/blocklist/command evidence and resume only verified
next steps. A request that timed out without an identifiable command ID needs
operator review; blindly retrying could duplicate work.

The same monitor state directory contains `policy-actions.json` and one backup.
Intent is flushed before every mutation. Successful checkpoints retain exact
IDs, original warnings, profile and library evidence, SAB identity and command
ID. Completed audit records are retained for a year; unfinished intents never
expire. Recent observation records expire after a day.

Read-only inventory (does not send notifications or create state):

```bash
/bin/bash /boot/config/plugins/user.scripts/scripts/arr_health_activity/script --policy-actions
```

Columns: application, download ID, decision, checkpoint, target ID, replacement
state. `intent` / `search_uncertain` indicate an unverified request outcome;
do not erase the journal to make the script retry. Check the native Arr history,
blocklist and command first. A damaged journal fails closed and is preserved.

## Quarantine and notifications

`sabnzbd_cleanup.sh` 2.5.0 (installed as `arr_sabnzbd_cleanup`) accepts a separate
verified **policy disposition**, without pretending the rejected job imported.
It checks exact unchanged SAB identity, current media IDs/monitoring, no active
queue use, stable source path and at most one remaining video. For redundant
files it also verifies the original existing library file still exists and is
nonempty. The ordinary source-root, device, Mover, manifest, permissions and
per-run guards remain in force. The existing completed-age threshold is 336
hours (14 days), and the path-stability threshold is 24 hours; neither is shortened. Failed/uncertain actions authorize no quarantine.

Rejected payloads are not misreported as missing imports or unknown stranded
downloads. An exact SAB-bound policy receipt explains the retained data. If it
still exists after 384 hours (14-day eligibility plus 48 hours), the hourly
filesystem audit reports a delayed policy cleanup. Align
`POLICY_CLEANUP_EXPECTED_HOURS` if the cleanup age is changed.

Quarantine happens on the cleanup script's next scheduled eligible run, not
inside the monitor. Payload is retained in its existing 14-day quarantine and
can be restored with the existing `--restore WRAPPER` CLI. Nothing is removed
from the media library. Detailed cleanup notifications identify the move and
state that it used a policy disposition rather than import history.

Action summaries use the monitor's existing grouped notifications and delivered
signature tracking. They include the release/download ID, original reason,
queue/blocklist/search outcome and preserved payload status. A replacement
search means **pending**, never imported. Hourly API follow-up (at most four targets per run) confirms a fresh
exact-target file that satisfies the current profile before reporting an import.
After seven days without a proven compliant import, one lifecycle warning is
raised and existing bounded reminder rules apply. It does not start an
unbounded search loop. An API/database record is not proof of physical library
readability; quarantine independently checks the existing file when applicable.
