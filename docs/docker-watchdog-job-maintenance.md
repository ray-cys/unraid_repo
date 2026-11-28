# Docker watchdog job failures during Plex maintenance

The watchdog monitors container availability independently from scheduled-job
outcomes. A failed job never authorizes a container restart. Existing Docker
health/readiness thresholds, permissions and restart budgets still apply.

For MetaFusion's exact `Plex connector preflight failed` outcome, or Kometa's
complete two-reason Plex-connection/empty-library failure, the watchdog can
classify a run as **maintenance-blocked** when all evidence agrees:

1. Native Docker timestamps prove its whole failed run occurred while the
   matching Plex container was stopped under verified planned maintenance.
2. Per-container maintenance has a valid owner/boot/process identity. A broad
   backup-running interval, unrelated service outage or unknown journal is not
   enough. Open-window classification additionally requires the container still
   stopped and its maintenance lease still valid.
3. After restart, the producer's own configured endpoint and credentials pass
   authenticated Plex library checks. Its configured libraries must be present.
   Plex's machine identity must match the actual maintained dependency. This
   follows retained port/network bindings; it performs no port scan or media
   filesystem checks. TLS verification is retained; cross-origin credential
   redirects are rejected. Credentials stay inside the producer container.
4. Mixed errors, incomplete/truncated capture, invalid configuration, failed
   authentication, a changed Plex identity or a run outside the exact interval
   keep ordinary failure reporting. Unknown failures are not automatically muted.

No native result is rewritten as success and no job is forced or rescheduled.
The current maintenance-blocked outcome is a warning awaiting the next native
scheduled run. A later unrelated failure remains critical; normal missed-run
and overrun deadlines remain enabled. Maintenance-blocked outcomes stay visible
as warnings until a later native outcome is available.
Notification recovery text explicitly calls this reclassification rather than
claiming the job ran successfully.

The existing `state.json` retains bounded `plannedDowntime`,
`maintenanceOutcomes` and `jobIncidentHistory` data: 14 days, at most 128 entries
per collection. Closed verified intervals survive a host reboot; active intervals
require the current boot/owner. Container recreation requires the same authenticated
Plex machine identity. Kometa's compact native issue catalogue retains matching
proofs with its bounded affected-run history so a known historical maintenance
failure does not later become an invented YAML fault when the short window
history ages out. A new unproven occurrence makes that issue actionable again.

The weekly media metadata review explains maintenance-only Kometa findings once
as historical blocked work, preserves the raw native result, and does not request
YAML edits for those findings. Other unresolved metadata/artwork issues remain.
No new log scan or recurring timer is introduced for that report.

`bad` counters for run-scoped job findings count **monitor observations**, not
failed job executions. The current native completion identity scopes the count
and first-observed duration; earlier observations are retained in bounded history.
Notification details include the native completion time in Singapore time.

For the first deployment, `tools/import_backup_maintenance.py` imports only exact
historical intervals supported by a same-boot successful backup execution receipt,
its matching completion log and Docker's retained stop/start timestamps. It emits
candidate JSON for review and does not edit live state. Subsequent timing evidence
is collected by the watchdog from existing verified leases and native Docker
state, without changing any Docker image, startup setting or application config.

Standalone script helpers are generated with
`python3 tools/sync_watchdog_job_maintenance.py`. Fixtures cover correlation,
unknown/mixed failures, authenticated target identity, current-run counters,
reboot/recreation, active leases and weekly historical presentation.
