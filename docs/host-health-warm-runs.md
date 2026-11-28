# Daily host-health evidence and coverage

`host_health_monitor` retains the existing daily 06:30 schedule and delegates
fast-changing host conditions to `host_health_watchdog`. These changes do not
install another script/timer, change Docker configuration or loosen disk-wake,
maintenance or alert thresholds.

- Scrub freshness uses the time native results were observed. A scrub started
  after this monitor began can therefore be recognised as a valid same-run
  completion, while future timestamps remain unverified.
- A live, clean Docker scrub result closes an outstanding request only when its
  filesystem UUID and native start match the recorded request. Cached status,
  errors and results older than the request cannot close it. Reconciliation
  never starts another scrub. If a scrub is still running at the later status
  collection, the request stays pending for the next scheduled observation.
- Physical Btrfs members retain their existing stable disk identities. Docker
  loop counters use filesystem UUID and Btrfs device ID, so changing loop numbers
  does not lose the baseline. Duplicate mount views are counted once. A recreated
  filesystem gets a new baseline; unresolvable legacy loop-path baselines are
  not guessed or converted into invented error deltas.
- A due SMART test records the exact reason it could not start. Pending/retry
  protection, other tests, filesystem scrubs, Mover/parity, backups and unverified
  operation state do not move its original calendar deadline.
- Self-test log observations share the existing invocation-local SMART cache.
  A new native test invalidates that disk's cached output before post-start
  observations. Failed/timeout reads are not cached as successful data.

The log's `COVERAGE` line and existing completion receipt (`state/monitor_receipt.json`,
`coverage` field) distinguish inventory size, fresh/deferred/unverified SMART
samples, devices never sampled and the oldest successful sample. They also
record tests started, pending, overdue and deferred reasons, plus current-run
scrub evidence. `overdue` counts test kinds (short/long), not unique disks;
its threshold matches the existing actionable overdue grace. Never-sampled
counts are a subset of incomplete coverage, not extra devices.

The same compact summary accompanies notifications already warranted by the
existing lifecycle. An unchanged healthy result remains silent. A completed
collector with sleeping disks is not a claim that every disk was freshly checked.
No additional persistent report file is created.

Helper source: `tools/host_health_warm_run.sh`, embedded with
`python3 tools/sync_host_health_warm.py`. Native fixture tests cover same-run and
future timestamps, matching request reconciliation, stale/cached/error evidence,
loop renumbering/new UUIDs, duplicate mounts, cache invalidation and coverage.
