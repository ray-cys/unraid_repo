# Media Cleanup performance proposal

This is a review proposal; it changes no production cleanup behaviour, schedule or safeguards.

The observed run took about 573 seconds: Arr 513 seconds, SAB 52 seconds and quarantine 2 seconds. Arr is the first target. Current code already stages working snapshots in RAM, merges Sonarr episode maps per series, batches sidecars, avoids rewriting correct permissions and records module/API/hash timing. Repeating those changes would add little value.

Recommended rewrite, in small measurable stages:

1. Extend `mc_arr_metrics` / `mc_timed_call` to separate discovery, history pagination, entity reconciliation, state publication and filesystem checks. Compare representative runs by entity count and pending work; elapsed time alone varies with new downloads.
2. Materialize per-run library, file and history indexes once. Replace repeated whole-array `jq` searches with keyed lookups by exact application/entity/file/download ID. Refresh the affected entity after every mutation. Cache absence only after a complete successful API response; partial pages, timeouts and transport circuits invalidate that evidence.
3. Build a pending-work index so unchanged settled entities avoid expensive history and sidecar discovery. Keep a bounded rotating full discovery pass, and invalidate entries on media-file IDs, monitoring state, folder identity, recovery holds or policy changes. Plex deletion discovery must remain covered; a cache cannot prove that media is present.
4. Accumulate read-only observation changes per entity and publish one atomic checkpoint per entity or bounded batch. Persist every destructive intent before acting and its read-back immediately afterward. Never delay action-journal writes to gain speed.
5. Allow at most two concurrent independent read-only API fetches, with existing timeouts, paging limits and a shared request budget. Keep unmonitoring, retirement, filesystem actions and journal publication sequential. Cancel incomplete fetches at the cooperative runtime limit without interpreting them as empty results.

Retain exact ownership proof, fresh identity/hash checks, Mover guards, mount validation, recovery holds, retirement clocks, two-observation protections where currently required, native recycling and one grouped daily notification. Do not parallelize the three modules or share mutable snapshots across scripts.

Accept each stage only when representative fixtures produce identical action plans and safe interruption/retry results, with lower measured API calls, full-state copies or elapsed time. No specific speed gain is promised before profiling. Keep the current implementation available for rollback. No new cron entry or Docker configuration is needed.
