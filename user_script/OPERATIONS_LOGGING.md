# Operational logs and notifications

Active Hubble scripts embed the same functions from `tools/operations_contract.sh`.
They remain standalone when restored from Unraid flash. Run
`python3 tools/sync_operations_contract.py` after editing that source; the contract
fixture checks every embedded copy.

Operational lines use:

```text
2026-11-24 21:00:00 | INFO | media_cleanup | run=12345 | phase=arr/Sonarr | Completed verified cleanup; pending entries retained for the next run
```

`INFO` records ordinary work and safe deferrals, `WARNING` records attention,
`ERROR` records a failed operation, and `CRITICAL` retains an urgent service or
storage fault. A deferred action was not performed. Unverified evidence is not
success. Recovery requires the owning workflow's evidence checks. Native CLI
reports, JSON, checksums and third-party diagnostic excerpts keep their formats.
The log line limit is 4 KiB. Scripts retain their existing storage and rotation
budgets. Metadata audit additionally keeps a 2 MiB operational log, two rotations
and 30-day rotated-log retention. User Scripts' `clearLog=true` keeps its UI
console on the latest run; retained operational history stays in bounded logs.

Emails use `Status`, `Summary`, and `Actions and findings`. `ATTENTION` means a
warning/alert; `UPDATE` covers an informational action or recovery. Exact
completion, failure, deferral, recovery and required intervention are described in
the evidence below those common labels. The notifier does not infer successful
repairs, remove original details or advance a producer's delivery checkpoint.
Every delivery has a timeout with termination escalation. Healthy quiet periods,
daily/weekly grouping and existing acknowledgement/reminder policies are retained.

## Media coordination

- Health owns Arr/SAB collection and download/import workflow findings.
- Integrity owns repeatable corruption and replacement verification. Health links
  an exact matching download to `integrity:JOB_ID`; independent API/import faults
  remain visible. Integrity recovery remains disabled until explicitly enabled.
- Metadata owns the weekly MetaFusion/Kometa review and guarded personal-template
  reconciliation. Native Kometa does not share the writer lock: native log
  identity/activity is rechecked before publication and changes are deferred within
  three minutes of a four-hour boundary. This reduces overlap; it cannot make an
  arbitrary third-party/manual start atomic with a filesystem rename.
- Cleanup owns library-deletion follow-up, SAB payload cleanup and bin retention.

`action-budget.json` in the health state directory coordinates new health and
integrity automation: at most two workflows in one parent run and four in rolling
24 hours. A rejection plus its paired replacement search is one workflow; it is
not a promise about the number of downloads Arr may subsequently produce. The
first reservation seeds existing recent journals. A confirmed pre-HTTP local
refusal releases its slot; uncertain dispatched actions retain theirs and are
never replayed merely because delivery/read-back failed. Invalid ledgers block new
work and require attention. Read-only reconciliation can continue.

Metadata records each completed or deferred invocation and weekly-report outcome
separately. Pending weekly email bodies survive later producer snapshots. Metadata
and integrity release their export leases during delivery and reacquire them
before acknowledging. Health also commits and releases its parent lease before
calling the integrity executor, so a retained parent descriptor cannot block export. An export-lease failure stops further state writes.

Integrity receipts expose current-version coverage, unknown pending age and
consecutive completed scans without progress. An incomplete or deferred scan is
not a clean result. Backup health checks for stale metadata receipts, failed weekly
reporting and three completed integrity scans without measurable progress. These
checks do not add a schedule or enable integrity replacement.
