# Kometa weekly maintenance review

The Docker watchdog remains the single native-log reader. Its v3.7 parser extends
its existing incremental cursor with a redacted catalogue of configuration and
processing findings. Kometa preflight v2.2 owns weekly presentation and delivery.
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
while that heartbeat/deadline is healthy. It retains those observations and all
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
review overwrites weekly-report.txt in the existing preflight state directory;
there is no accumulating collection of full-log copies. Full reviews retain all
catalogued messages and recommended actions, including entries omitted from email.
Paths, signed URL queries and credential-shaped fields are redacted before storage
and again before rendering. All report/state files remain private.

Manual review on Unraid:

```bash
preflight=/boot/config/plugins/user.scripts/scripts/kometa_preflight/script
/bin/bash "$preflight" --report-preview
/bin/bash "$preflight" --weekly-report
```

Preview sends no email, updates no report state and performs no YAML edits.
`--weekly-report` respects the deadline; it does not force an extra email. Normal
invocation also performs the existing reconciliation afterward. Bootstrap starts
from the available previous/current logs; seven-day coverage becomes available
only as new runs are observed, not by inventing missing history.
