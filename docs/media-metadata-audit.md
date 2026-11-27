# Media metadata weekly maintenance review

The Docker watchdog remains the single native-log reader. Its native parser extends
its existing incremental cursor with a redacted catalogue of configuration and
processing findings. Media metadata audit owns combined weekly presentation and delivery.
No Docker image, entrypoint, scheduler or application configuration is changed by
the reporting module. Existing guarded personal-template edits remain separate.

The default review deadline is Sunday 11:55 Asia/Singapore. Existing preflight
cron already includes that time; if delayed, delivery occurs on the next available
invocation. Initialization schedules the next future review and sends no immediate
backfill email. No recorded findings/fixes means no weekly all-clear email.

The report identifies observed library/source/scope, message, issue ID, affected
run count, first/last occurrence, diagnostic category and recommended action. A
uniquely referenced source can be associated with its library using the current
local config. Shared/missing attribution remains unknown; candidate files are not
presented as proven origins. Known MetaFusion output paths carry a reminder to
confirm ownership and fix generating inputs rather than overwrite generated YAML.

Read-only reporting runs before configuration-edit idle/maintenance guards and
does not obtain a writer lock or edit YAML. The report module's regular check is
recorded in weekly-report-state.json. Failed notification leaves its deadline
unchanged. Watchdog suppresses only routine Kometa job-errors/job-warnings emails
while that heartbeat/deadline is healthy. Added scheduled-job producers use their own validated handoff as described below. It retains those observations and all
urgent fatal, service-availability, overdue-job and recovery safeguards. If the
handoff is absent/stale, immediate routine reporting resumes automatically.

Collection/overlay/playlist/library fixes require two completed normal runs with
positive same-scope completion evidence and no findings for that scope. A file
loading scope also requires error-free normal run evidence. A skipped collection,
a partial log or one clean run never proves resolution. An unseen unresolved
finding is labelled resolution-unverified; its original diagnostic is retained.

The reader retains up to 256 issues, 128 distinct maintenance findings per run,
150 affected-run timestamps per issue and 150 recent normal-run records (21-day
run window). Unresolved issues remain until verified or bounded catalogue eviction;
resolved issues expire after 21 days. Capture limits/log gaps are disclosed.
Runtime severity counters keep their existing independent 32-reason caps. Large
JSON is passed through files/stdin, avoiding operating-system argument limits.

The email has up to 20 prioritized entries and a 24 KB budget. The latest full
review uses weekly-report.txt, with weekly-report.previous.txt retaining its predecessor;
there is no accumulating collection of full-log copies. Full reviews retain all
catalogued messages and recommended actions, including entries omitted from email.
Paths, signed URL queries and credential-shaped fields are redacted before storage
and again before rendering. All report/state files remain private.

Manual review on Unraid:

```bash
preflight=/boot/config/plugins/user.scripts/scripts/media_metadata_audit/script
/bin/bash "$preflight" --report-preview
/bin/bash "$preflight" --weekly-report
```

Preview sends no email, updates no report state and performs no YAML edits.
`--weekly-report` respects the deadline; it does not force an extra email. Normal
invocation also performs the existing reconciliation afterward. Bootstrap starts
from the available previous/current logs; seven-day coverage becomes available
only as new runs are observed, not by inventing missing history.

## Combined native MetaFusion review (media_metadata_audit v3.0)

The installed User Script is now `media_metadata_audit`. Its source filename,
state root, status receipt, watchdog handoff, backup-state export and scheduler
reference use the same name. The old state directory is moved once during
installation, preserving `nextDue` and delivery history; no duplicate job remains.
Docker images, startup, environment, native schedulers and app configuration are
not changed by the rename. Existing personal-template reconciliation remains
behind its existing guards; reporting runs independently before those guards.

The second source is MetaFusion `schema_version:1`
`/config/reports/findings-latest.json` on its existing host bind mount. It contains
`run`, 30-day `run_history`, persistent `open` findings and `recently_resolved`
findings. No native log parser or duplicate report collector is introduced.
The native export is read-only and may not exist until the first non-dry run
following the producer upgrade. Missing, invalid, future-dated, over-32-MiB,
stale (eight-hour) or incomplete coverage is explicitly reported. Kometa evidence
can fail independently: MetaFusion findings still render, while the watchdog
retains immediate routine Kometa reporting.

MetaFusion detail includes exact server/library/Plex/TMDb/season/episode identity,
component/mode, operation, reason code, provider and destination/ownership evidence,
observation counts, first/last checks, suggested actions and native resolution
proof. Stable IDs plus first-seen times distinguish recurrences. Open findings
are never aged out by the consumer or resolved because a later run skipped them.
Provider-no-candidate, field-unavailable, policy-held and processing-failure cases
remain distinct. A local artwork file is not reported as proof of Plex application.
Only producer-verified recoveries since the previous report/week are included.
Run action and cleanup counts are explicitly producer summaries, not unique-item
counts or actions performed by this audit.

Native findings with the same library/operation/reason/lifecycle are grouped for email, with an exact example, total count and the complete per-identity detail in the full report. Episode/season indices are generalized for presentation only. Provider-missing fields are not called runtime errors or a direct Plex-field audit.

One combined weekly notification interleaves MetaFusion and Kometa entries so one
source cannot monopolize all 20 positions. It retains the 24-KB bound, explicit
omission counts, one overwritten full report, redaction and failed-delivery retry.
Missing coverage is reportable even if there are no findings. When both sources
are fresh and have no findings/recoveries, no all-clear email is sent.

## Recyclarr and ImageMaid weekly review (v3.4)

The existing Sunday 11:55 Singapore-time deadline now covers MetaFusion, Kometa,
Recyclarr and ImageMaid in one **Media Stack Weekly Review**. Script schedules,
container images, entrypoints, native schedules and application settings stay as
configured. Reporting never runs Recyclarr sync or ImageMaid cleanup.

Docker Service Watchdog remains the only job-log reader. Recyclarr outcomes match
native `/cron.sh` scheduler command/position/iteration, with errors/warnings from
that run; per-Arr `Completed at` lines cannot establish whole-job success.
ImageMaid uses full start/terminal/footer evidence and native severity records,
including explicit completed-operation counters when present. No counter is
invented when the producer does not record one. ImageMaid's weekly completion
allowance is 192 hours (weekly schedule plus one-day grace), not five days.

Compact producer catalogues live in the existing watchdog `state.json` beneath
`.jobs[actualContainerName].weeklyReview`. Recent run receipts and resolved causes
retain 14 days, capped at 128 runs and 256 causes per producer; unresolved causes
remain until verified or the disclosed bound is reached. Recurrence retains
recent recovery timestamps. Repeated/overlapping scans do not multiply events,
and late historical errors cannot reopen a later proven clean outcome. A complete
clean native job can resolve processing causes; deadline/evidence conditions
require their own current valid watchdog recovery. Unknown, incomplete or capped
capture cannot silently establish a clean history. Cached outcomes from before
collection began are explicitly retained history, without invented reasons.

The weekly email groups sources fairly within the existing 20-entry/24 KB budget.
It includes native reasons, source paths when recorded, first/last observations,
recorded recurrence/recovery and specific suggested checks. Healthy unchanged
weeks are silent. Confirmed removed applications are retired from the report;
missing/stale evidence for an installed producer is reported as unverified.
The native report consumer receives actual discovered profile/container identities,
so known application removal does not require executable edits.

Only routine `job-errors`/`job-warnings` emails are delegated for a producer with
current successful report/collector evidence. Lost/stale handoff restores ordinary
watchdog reporting. Availability, fatal failures, missed deadlines and restart
permissions remain independent. Optional catalogue failure preserves old evidence
and reports the collection problem without stopping container availability checks.

Only `weekly-report.txt` and `weekly-report.previous.txt` are retained. They rotate
on a new weekly report, never on ordinary four-hour checks or repeated delivery of
the same pending report. Undelivered report JSON is retry state, not another
historical report; its exact reasons/recoveries are retained until delivery succeeds.
`--report-preview` remains read-only; `--weekly-report` honours the existing due
time and performs no configuration reconciliation.

The standalone reducer is generated from `tools/job_weekly_review.php` with
`tools/sync_job_weekly_review.py`; presentation comes from
`tools/job_stack_report.py` with `tools/sync_job_stack_report.py`. No runtime helper
installation or host Python package is required. PHP is native to Unraid and the
existing Kometa/ImageMaid Python runtimes remain read-only reporting workers.
