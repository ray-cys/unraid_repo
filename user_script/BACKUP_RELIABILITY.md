# Hubble to ISS backup operations

`remote_backup.sh` v2.3 mirrors Media/Secure to the existing ISS shares.
`vault_backup.sh` v1.5 creates independently verified full generations under
`/mnt/user/backup/vault_versions`. Each remains a standalone Unraid User Script;
no helper library or service needs installing. Deploy **both** updated scripts
so they honor the same ISS lock. Repository changes do not install them on Unraid.

## Configuration and normal operation

Review the existing source/destination paths, SSH identity/port and schedules.
The vault script retains its existing `DRY_RUN=true` default; set it to `false`
for live backups after checking its dry-run output. The mirror default remains
live. A dry run never constitutes a restore-ready backup.

Both scripts require Bash, rsync >=3.1 and GNU filesystem tools on both Unraid
hosts. The scripts check capabilities, use the same SSH settings for probes and
rsync, disable SSH compression, reuse a per-run SSH connection, and apply a
300-second rsync inactivity timeout. SHA-256 verification has no short overall
wall-clock timeout: reading a large generation legitimately takes time.

Existing per-script local locks remain. A live SSH worker holds
`/run/hubble-iss-backup.lock` on ISS throughout the run, with an ownership token
checked before transfer/shutdown. Another run waits up to 1,800 seconds. SSH
keepalives detect lost transports. Disconnect releases the lock; no permanent
PID-file lease can survive reboot. A recently accepted shutdown reserves ISS for
up to fifteen minutes, preventing another backup starting during clean shutdown.
A failed reservation expires; `/run` reservations also disappear on reboot.
Live queued backups defer shutdown normally so the next backup can take over
without another wake cycle. Dead or expired waiter hints are removed, preventing
stale/reused PIDs from permanently blocking shutdown.

Shutdown continues to allow ordinary parity checks. Active mover and critical
array operations remain protected, and an unverifiable activity probe leaves ISS
on. A shutdown request is reported as a request, not proof that power is off.
The shared lock coordinates these scripts, not arbitrary applications on ISS.

## Mirror safeguards and logging

The source must be a nonempty directory on a mounted expected Unraid filesystem;
root paths, symlinked roots, and unexpected filesystems are rejected. Existing
remote destinations must be canonical directories beneath `/mnt/user`.
`.hubble-backup-identity` records the configured source/destination pairing on
the first live run. A changed pairing requires deliberate review of that marker;
it is excluded/protected from mirror transfers and deletion.

`MAX_DELETIONS=10000` bounds deletions per job/attempt and also applies during
the preflight dry run. **This is not an atomic deletion transaction:** if a race
causes the live run to hit the limit, earlier deletions may already have happened.
Do not raise the limit merely to silence an unexpected failure. A mirror still
propagates intentional source deletions and is not historical media versioning.

Successful transfers now log summaries instead of timestamping every changed
file. `LOG_ITEMIZED_CHANGES=false` avoids per-file overhead. Main logs are bounded
at 1 MiB and raw logs at 2 MiB, as well as existing count retention; retained old
logs are bounded too. Transfer attempts report elapsed time and the mirror logs
its measured average network bytes per second. Phase durations identify the
actual bottleneck; tiny transfers do not measure link capacity meaningfully.

## Vault resumption, consistency and capacity

A compatible attempt reuses `.hubble-resume.partial`. Configuration/source-root
changes preserve the old attempt in a separately named incompatible partial.
Unknown staging is never silently deleted. The current partial is not promoted
until every configured job passes destination SHA-256 verification.

Appdata selects the newest completed `backup_YYYYMMDD_HHMMSS` directory and
validates its producer manifest checksum. Shared locks on the standard appdata
and flash producer lock files prevent their running/pruning while this backup
uses them. If those scripts use custom lock paths, update this list accordingly.
User Scripts, GitHub and photos use their configured roots. Temporary `.partial`,
`.rsync-partial`, `.tmp` and `.sock` entries are excluded consistently. Stale
excluded artifacts in owned staging are removed before promotion.

The manifest inventory also supplies file count and byte totals, avoiding the
previous separate count/size traversals. Source metadata inventories before/after
hashing and copying detect concurrent changes. A changed source gets a fresh
manifest and a bounded retry; a continuously changing source fails safely.
Git/photos writers are not paused: this is not a transactional cross-application
snapshot. Regular-file destination checksums remain mandatory. A mismatch causes
one of the bounded retries to compare contents with rsync `--checksum`, repairing
staged corruption even when size/mtime quick checks would miss it. Hard links
are only preserved *within* each copy with `-H`; generations do not share hard
links and no Btrfs snapshots are used.

Preflight estimates additional staged writes with rsync, adds a 10 GiB reserve,
and refuses insufficient capacity. Completed generations are never removed to
make an unverified replacement fit. Free-space estimates cannot guarantee Unraid
share allocation across individual disks or prevent another writer consuming
space later; actual errors fail the run. A fully independent generation requires
space for its bytes in addition to retained generations.

Only after promotion does retention keep the newest three completed generations
and expire script-owned abandoned partials older than fourteen days. The current
resumable partial and unmarked legacy partials are retained. Remaining partial
paths/sizes are reported for review. Generations without a completion marker do
not count as verified retention candidates.

## Outcomes and recovery

Both scripts write bounded operational logs and atomic receipts in
`/mnt/vault/cloud/logs/script/user_scripts_status`. Receipts distinguish copy,
verification, retention and notification outcomes. A completed backup followed
by retention/shutdown problems reports a warning rather than claiming the data
copy failed. Early failure and handled interruption produce a consolidated error
notification; unavailable delivery is reflected in the receipt. SIGKILL, host
power loss and a failed notification subsystem cannot themselves send email.

Media on ISS remains ordinary files under its mirror shares. To recover after
Hubble failure, first inspect the backup log/receipt and choose the intended ISS
copy. Restore into an empty/replacement destination; do not run a blind reverse
mirror with `--delete` against an existing library.

For vault recovery, choose a `hubble-...` directory containing `completed.txt`,
not a hidden partial. Verify its `manifests/LABEL.sha256` from inside `LABEL/`.
`manifests/restore-sources.tsv` records each source path and generation directory;
new appdata labels contain the selected completed archive set directly. Flash
archives and User Scripts are separate labels. Follow the relevant application's
restore procedure and keep restored services stopped while replacing appdata.
Older generations keep their original layout and do not acquire this new map.

## Subsequent tuning for the home 2.5 GbE link

2.5 gigabits/s is 312.5 decimal MB/s before protocol overhead, not 2.5 GB/s.
Measure memory-to-memory TCP throughput with iperf3 first, then compare one large
real file and the scripts' phase timings. Storage, parity work, CPU encryption,
metadata enumeration and verification can each dominate independently of LAN.

For large media/archives, compare rsync's normal delta algorithm with
`--whole-file` on disposable test destinations. Whole-file mode can reduce
receiver reads/CPU, but sends all bytes of every changed file. Do not apply it
blindly to frequently changing large files. Compression is already disabled.

If ISS parity writes are the bottleneck, benchmark Unraid reconstruct write
(Turbo Write) during an idle backup window. It trades additional spinning/read
activity across array disks for write throughput. Do not silently alter the
server's persistent write policy. Avoid SSD landing shares unless a measured
benefit justifies capacity requirements, a second write, and delayed final disk
placement before powerdown. Keep jumbo frames and parallel transfers out of the
defaults until the entire network/storage path is measured.

References: [rsync options](https://download.samba.org/pub/rsync/rsync.1),
[OpenSSH transport settings](https://man.openbsd.org/ssh_config),
[Unraid array behavior](https://docs.unraid.net/unraid-os/using-unraid-to/manage-storage/array/overview/).

## Completion-driven vault copies (appdata v3.7 / vault v1.6)

On Hubble, keep the appdata schedule and replace the weekly
`vault_remote_backup` schedule with `10 * * * *`. The hourly job checks local
metadata first; without a new request it exits without WOL, SSH, rsync, a new
backup log, or notification. `remote_backup` keeps its existing Sunday mirror
schedule and shared ISS lease.

A fully successful appdata run (including staged-generation recovery and
container restarts) atomically publishes
`/mnt/vault/cloud/logs/script/user_scripts_status/iss-backup-request.json`.
The vault consumer checks the request age (maximum 72 hours), source identity
and manifest digest, and acquires producer locks **before** waking ISS. This
queues work rather than starting a child that inherits the producer's lock.
Failed transfers leave the request pending for the next hourly attempt.
New requests supersede older requests with the latest successful generation.

The copied appdata archives are verified against the original producer hashes
on ISS using the normal transfer manifest. No fresh hash of corrupted source
bytes can replace that baseline. Only after remote verification and promotion
is `iss-backup-delivered.json` atomically saved with the source identity and
remote generation path. Dry runs never acknowledge requests. A completed
request is not copied again. `bash script --force` explicitly repeats the
current request; freshness and safety checks still apply. To retain manual,
schedule-independent operation, set `COMPLETION_DRIVEN=false` in the vault
configuration. Repository `DRY_RUN=true` remains intentional; live Hubble uses
`false`.

Deploy the standalone `backup_restore_drill.sh` as a User Scripts entry named
`backup_restore_drill`. It does not need an independent cron schedule. After a
successful live vault copy, vault v1.6 uploads/checksums this reviewed script
and runs a bounded drill **on ISS**, at most once per seven days. ISS must
provide GNU tar/coreutils, setsid, timeout, unzip, flock, jq and preferably
sqlite3. It uses the completed generation itself, while the existing ISS lease
protects it from competing retention/shutdown. Restored files never replace
production appdata or `/boot`.

The drill rotates two appdata archives weekly, checks original producer hashes,
extracts each to a separate directory, checks SQLite databases where supported,
and deletes the temporary payload before the next archive. It also verifies and
extracts the flash ZIP. It retains two small result directories and five logs
under `/mnt/user/backup/vault_versions/restore_drill` on ISS. Default extraction
budget is 64 GiB per archive with a 5 GiB free-space reserve; live space and size
checks stop extraction if the budget is exceeded. Oversize applications are
explicitly outside this bounded selection, not certified as restored. Missing
SQLite support, application-specific SQL extensions, scan limits, and absent
recommended legacy flash files produce a warning rather than a false claim of
full verification. Extraction/database failures retain the verified remote
backup and are included in the vault notification. The delivery acknowledgement
is preserved, so a drill failure does not trigger repeated full generation
copies. A failed drill is attempted again after the next successful new copy.
A successful bounded drill is not proof of application startup or USB boot.

Manual local drill:

```bash
/bin/bash /boot/config/plugins/user.scripts/scripts/backup_restore_drill/script
```

Manual ISS drill (run **on ISS**, with a real completed generation name):

```bash
VAULT_MOUNT=/mnt/user \
DRILL_ROOT=/mnt/user/backup/vault_versions/restore_drill \
LOG_DIR=/mnt/user/backup/vault_versions/restore_drill/logs \
STATUS_DIR=/mnt/user/backup/vault_versions/restore_drill/status \
/bin/bash /mnt/user/backup/vault_versions/.hubble-restore-drill.sh \
  --generation-root /mnt/user/backup/vault_versions/hubble-YYYYMMDD_HHMMSS
```

For a deliberate wider drill, `MAX_APPDATA_ARCHIVES=0` selects all archives that
fit `MAX_EXTRACT_BYTES`. Adjust the budget only after checking the actual target
filesystem. Producer locks protect source selection and local retention. GNU tar
path checks, fresh per-archive roots and refusal to overwrite entries prevent
archive traversal/link collisions; this is not an execution sandbox for arbitrary
untrusted backups.

## Arr monitoring during appdata maintenance

`arr_health_activity.sh` v3.13.2 and appdata v3.7 coordinate through
`/run/arr-appdata-coordination.lock`. A normal Arr scan holds it shared through
its observation, automation and notification phases. Appdata waits up to fifteen
minutes for an existing scan before it can stop containers, then holds it
exclusively until restart attempts finish. New scans defer while backup owns it,
and for a bounded two-minute startup grace after release. No API polling,
automation, reminders or issue resolution occurs during a deferred invocation;
existing issue state is preserved. CLI state administration remains available.

Deferred invocations write a small `/run` timestamp. The next normal scan uses
recent proof that the scheduler continued running to avoid a false missed-run
alert; an unrelated old gap or previous failed scan is not erased. After startup
grace, containers/APIs still unavailable are real failures and alert normally.
The existing Docker watchdog per-container maintenance leases remain in use.
Deploy **both** scripts to close the mid-scan stop race. This intentionally
pauses the whole Arr/SAB scan during appdata maintenance instead of declaring
unobserved applications healthy. It does not erase existing alerts from before
the upgrade.
