# Operational evidence and performance

`media_cleanup --status` separates the latest invocation from the full scheduled
run and the latest terminal execute result per module. Preview results cannot
certify a repair. The receipt set is fixed in size; it does not create a report
per run. `backup_health_audit` can recognise a later exact-application repair of
a failed cleanup module, while retaining the original failed execution and
explicitly saying that the next complete scheduled confirmation remains pending.
Legacy module receipts require matching execute-mode start-log evidence.

Sidecar cache validity follows its rule contract, recognition settings, semantic
recovery holds, exact media evidence and filesystem fingerprints. A release bump
or an unchanged recovery-journal rewrite does not force every folder to be
recaptured. Pending work, periodic rotation, changed files and destructive
last-moment identity/hash checks retain their existing protections. Per-app
metrics count cache-miss reasons for subsequent tuning.

Appdata compression profiling times the existing compressor within its streaming
pipeline. Logs and the largest-archive report include input/output throughput,
compressor CPU core-equivalents, level and configured workers. It creates no trial
archive, second source traversal or additional payload copy. Low CPU use alone
does not identify which storage device is limiting throughput. Compression level,
thread policy, exclusions and verification are unchanged until measurements
support a deliberate tuning decision.

The Docker watchdog recognises partial native item failures only with complete,
consistent integer accounting, actual successful items and actual failed items.
Preflight failures, absent/unknown accounting and Docker availability failures
retain their stronger classification. Native whole-run failure and last successful
run are not rewritten as success. When the metadata audit has fresh usable
MetaFusion evidence, partial content findings use its weekly delivery; availability
and fatal errors retain immediate watchdog ownership. Reclassification is reported
as reclassification, not as successful completion.

MetaFusion ownership guidance uses exact Plex/provider identities. Its native
output preview/forget interface can release a proven deleted predecessor's claim
without deleting artwork. A targeted retry does not replace the earlier full-run
outcome. No Docker image, startup setting or application configuration change is
part of these script enhancements.

`backup_media_remote --evidence-status` distinguishes pending first native receipt,
valid transferred-data verification and invalid/unsupported evidence without
contacting ISS. `media_integrity_audit --evidence-status` distinguishes report time,
normal-scan evidence, decoding progress and incomplete coverage without accessing
media. Normal scheduled operations supply these baselines; a healthy report is
not proof that pending media was fully decoded or an entire mirror rehashed.

## Adaptive remote backups

`backup_media_remote` and `backup_vault_remote` share one embedded controller;
standalone User Scripts require no additional installed script, daemon or cron.
The shared ISS lease still prevents the two producers using ISS concurrently.
Within one producer, different labels may overlap, with a ceiling of two workers.
Destination trees must be disjoint and labels unique. Capacity estimation completes
before copying. Each result is collected only after its worker exits, checked as
JSON and merged into the parent's statistics. Missing or failed worker evidence
cannot publish a verified generation. Vault workers keep separate profiling records
until collection; aggregate stage durations may overlap in wall time.

Admission starts at one. Native CPU counters, runnable/blocked tasks and available
memory are sampled on both hosts every 30 seconds. Two consecutive contention
samples lower the affected priority; any pressure stops additional parallel
admission. Five quiet minutes recover CPU and I/O independently and permit two
jobs. Quiet/busy CPU nice values are 0/5/10; I/O is best-effort priority 4/6/7.
A missing/invalid sample or failed priority control restricts new admission to one
and is counted in the summary. Existing work drains normally; it is never paused
or killed just to reduce concurrency. High disk utilisation alone is not pressure.
The algorithm cannot attribute every stall to another workload; the finite ceiling
and conservative fallback limit its effect. I/O scheduler behaviour determines the
actual impact of `ionice`; requested/read-back priority is not a hard I/O cap.

Priorities apply only to verified PID/start-time descendants and registered remote
rsync/SHA workers belonging to the current run. New processes inherit current
worker priorities. Temporary helper files live in RAM on ISS and are invoked with
Bash because `/run` may be mounted noexec. Interrupt cleanup stops/reaps owned work
before releasing the lease. Cleanup uncertainty prevents automatic shutdown.
Remote control and telemetry calls have bounded SSH and command timeouts.

ISS-only Reconstruct Write is enabled by default as an eligible optimisation.
Hubble is the reader and its mode is untouched. ISS's current inventory has no
parity disks, so the optimisation reports an explicit skip and changes no mode.
The check is dynamic: a future parity-protected array must be started, healthy,
without active/paused resync or mover, without the CA Turbo Write controller and
with usable kernel write-command evidence before a temporary override is allowed.
`var.ini` alone does not establish a runtime override. Only known native mode
values are accepted. No change is made to `/boot/config/disk.cfg`.

A RAM journal records the original mode and the exact kernel apply receipt. Normal,
failed and interrupted runs restore that mode before shutdown. A short-lived ISS
guard restores after a lost lease or a heartbeat older than 120 seconds; a new
exclusive backup lease reconciles stale helper evidence before starting. A later
administrator/controller write command takes precedence and is preserved. Missing
apply/read-back evidence is reported as unverified rather than claiming restoration.
The kernel command interface offers no atomic compare-and-set against an unrelated
administrator command; avoid manually changing mode during a managed backup.
Power loss clears the RAM override and the unchanged flash configuration supplies
boot settings. This does not add parity protection to a server that has none.

Native validation used two small simultaneous RAM-only transfers on Hubble 7.4.1
and ISS 7.2.9, including vault manifest creation, destination SHA read-back and result
aggregation. These fixtures establish functionality, not a full-backup duration or
2.5 Gb/s throughput guarantee. Scheduled real-run timings remain the tuning evidence.
