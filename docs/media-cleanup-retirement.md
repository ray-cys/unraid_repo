# Media cleanup: retirement verification and reporting

Sonarr's native automatic-tag rules can add/remove unrelated tags during a
series update. In particular, a rule requiring monitored series may remove its
`hd` tag when cleanup correctly unmonitors a completely deleted series.
[Sonarr's native implementation](https://github.com/Sonarr/Sonarr/blob/develop/src/NzbDrone.Core/AutoTagging/AutoTaggingService.cs)
explicitly permits automatic removal when a rule stops matching.

Cleanup first requires an exact read-back. If a Sonarr full-object replacement
only differs in native automatic tags, it reads `/api/v3/autotagging` and the tag
catalogue. Only IDs owned by validated `removeTagsAutomatically=true` rules may
vary. Manual tags, monitoring, seasons and reserved lifecycle/exemption tags
remain strict. Missing/invalid rule evidence retains the checkpoint as unverified;
no write is blindly replayed. Radarr and explicit tag add/remove operations keep
their existing exact verification. Policy evidence is scoped to the application
and current cleanup invocation.

A retained accepted-action checkpoint is re-read on the next run. Successful
verification closes it and records the reason. Fresh retirement eligibility,
complete-deletion evidence, queue/recovery holds and cleanup completion are still
required before recording the hold. This does not shorten the 30-day retirement
period or delete media. Removal later affects the Arr entry with `deleteFiles=false`
and requires a verified import-list exclusion.

Specific application errors and aggregate counts stay in the daily report.
Generic wrapper/retirement errors are omitted only when the corresponding detailed
error is already queued. Without such evidence, fallback errors remain visible.
Failed outcomes stay failed in receipts and the current-run footer. Raw progress
log tails no longer overwhelm the generic failure message. Undelivered older
successful actions keep their original observation time; they are historical
actions, not new failures. Upcoming retirement notices are advance warnings,
not unsuccessful removal attempts.
