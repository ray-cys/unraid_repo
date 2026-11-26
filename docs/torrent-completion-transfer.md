# Completed torrent transfer policy (v3.7)

`media_torrent_management.sh` is installed as Unraid User Script
`media_torrent_management`. It retains its existing two-hour schedule,
console-only output, filename cleanup, unwanted-file rules, incoming-file replacement,
Mover/maintenance guards, and recovery checkpoint. No Docker configuration or
qBittorrent seeding/removal setting is changed.

Both phase 1 and phase 2 use the same per-payload processor. A payload is one
immediate child of its configured completed category: a torrent directory or a
standalone file. A healthy, structurally valid qBittorrent API response is required
before each payload can be modified. A valid empty torrent list is allowed.

A payload with no overlapping registered torrent is eligible immediately during
that scheduled run. There is no age threshold, second observation, waiting state,
or separate phase-2 delay. Registered payloads remain eligible only when complete,
with zero bytes left, and stopped/paused in upload state. Downloading, seeding,
queued, checking, moving, errored and other states remain untouched. Unknown path
mappings, partial `.!qB` files, and symlinks also defer processing. One retained
payload does not block eligible siblings or other configured categories. An API
failure retains the remaining payloads for the next normal run.

For an unregistered payload, the completed-folder location is the completion
contract. The script cannot reconstruct completion proof after qBittorrent removes
its torrent record. Manually placing an unfinished file there without a partial
marker would also make it eligible. This is the chosen immediate-transfer policy;
there is no claim of independent completion verification for orphan files.
Live qBittorrent already has its temporary path enabled at
`/data/torrent/incomplete`; its completed save path is under
`/data/torrent/complete`. This native separation is the appropriate handoff for
the immediate policy and was not changed.

Unwanted files are removed first and names are normalized second, only inside an
eligible payload and before transfer. Standalone files use the normalized name
as their rsync destination. Incoming same-name regular files replace existing
files with `--ignore-times`, including equal-size/equal-mtime content; there is
no media hashing, duplicate suffix generation or original-file copy. Rsync uses
its normal temporary-file replacement, not `--inplace`. Source rename collisions
follow the same incoming-file-wins policy; source directories merge using moves.
Links and directory/file type conflicts defer processing rather than being
followed or deleted. Interrupted transfers still stop at their checkpoint for review;
no ambiguous automatic mutation replay was added. VueTorrent retains its existing
weekly refresh logic; validation does not invoke it.

Run `bash /boot/config/plugins/user.scripts/scripts/media_torrent_management/script --help`
for usage, or `--version` for the installed version. A normal manual invocation is
a real transfer run, not a preview.

# Mullvad canary DNS review

Read-only inspection found both primary Pi-hole (`192.168.50.101`) and fallback
DNS (`192.168.50.100`) answering `0.0.0.0` for `am.i.mullvad.net`. The primary
Pi-hole list query identified HaGeZi's `doh-vpn-proxy-bypass.txt` subscription and
its `||mullvad.net^` rule. qBittorrent resolves through Tailscale's
`100.100.100.100`; its generated `/etc/resolv.conf` should not be edited manually.

1. Open the primary Pi-hole administration page and filter Query Log to
   `am.i.mullvad.net`. Confirm the blocked status and client/group involved.
2. In Domains, add `am.i.mullvad.net` as an exact allow entry; ensure the entry is
   enabled for the groups assigned to that requesting client. Do not allow the
   entire `mullvad.net` domain or disable the whole bypass list just for this check.
3. Apply the same exact allow entry through the RPi fallback's administration UI
   if it is another Pi-hole. Both DNS servers currently block it.
4. From Unraid, check both resolvers with `dig +short @192.168.50.101 am.i.mullvad.net A`
   and `dig +short @192.168.50.100 am.i.mullvad.net A`. If still blocked, review
   group assignment, local DNS overrides, and upstream filtering. Do not pin a
   public address permanently; the endpoint's address can change.
5. Allow cached blocked replies to expire, then run
   `docker exec qbittorrent getent ahostsv4 am.i.mullvad.net`. The first address
   should be a usable public address, not `0.0.0.0` or a loopback address. If direct
   resolver checks work but this still fails, review Tailscale Admin DNS/global
   nameservers and upstream blocking; do not change Docker startup or hand-edit
   the Tailscale-managed resolver file.
6. Run `bash /boot/config/plugins/user.scripts/scripts/docker_service_watchdog/script --diagnose-vpn`.
   After selecting the recommended qBittorrent `tailscale0` interface, expect an
   approved exit node and IPv4 Mullvad confirmation. IPv6 can legitimately report
   no usable route. This diagnostic does not send notifications or clear state.
7. The normal five-minute watchdog clears each incident after two successful
   scans. Do not delete monitoring state to suppress unresolved warnings.

These steps are instructions for the owner; this change does not edit DNS policy.
Pi-hole references: https://docs.pi-hole.net/guides/misc/allowlist-denylist/
and https://docs.pi-hole.net/main/pihole-command/.

# Jav18 filename normalization (v3.6)

Hubble's secure Plex libraries currently select `com.plexapp.agents.jav18`. The installed agent searches using Plex's release name, so completed payloads now normalize a clear leading catalogue ID into `PREFIX-NUMBER`, retaining numeric studio prefixes and leading zeroes. Examples: `pppd528.mp4` becomes `PPPD-528.mp4`; `259luxu_1922.mp4` becomes `259LUXU-1922.mp4`; an advertising domain followed by `@` is discarded when the remaining name identifies a release. Existing literal cleanup remains the fallback. Files retain their video extension. Explicit part/CD numbers become Plex's ` - cdN` suffix. Scene excerpts, multiple conflicting codes, attached variant letters, unsupported ID families and title-only names are not guessed. Non-video assets receive only the existing literal cleanup, not release-ID extraction.

Only the configured completed-download categories are processed on scheduled runs; source completion/API guards, rsync movement, unwanted-file removal, ownership, Mover coordination and console-only output remain. No metadata website, additional dependency, rename journal, original-file copy or additional schedule is introduced. Existing transfer checkpoints remain. Incoming same-name files replace their targets; no new `.dupN` names are generated. Legacy duplicate suffixes on incoming payloads are stripped to restore the original filename; existing destination libraries are not rescanned to delete older duplicates. The script does not perform recurring library-wide renames.

VueTorrent retains its weekly cadence and configured GitHub branch. A bounded `git ls-remote` compares the upstream revision with the installed checkout before downloading. Matching revisions with valid HTML and referenced local JavaScript/CSS skip replacement. Both `index.html` and `public/index.html` layouts are supported. GitHub failure retains the installed WebUI; changed revisions retain the existing staged clone/activation/recovery workflow. Docker images, settings, Plex agent code and library configuration are not modified.

# Mover checks and console summary

Mover is checked at startup, before each eligible payload and immediately before each rsync invocation. A new Mover run defers remaining work; a payload already cleaned/renamed but not transferred records `category_deferred` and is eligible again at the next scheduled run. This state never overrides an uncertain or interrupted rsync checkpoint. An already-running rsync is not killed, and these checks do not lock Mover out or guarantee that `/mnt/user` files are still on NVMe.

The final console summary lists completed-payload file/byte totals, file/directory renames, unwanted-file removals, source/destination same-name replacements, observed retained payloads and VueTorrent outcome. Partial failed transfers are excluded from completed totals. Startup/completion messages use the actual script version. No email, new report files, additional cron, Docker configuration change or library-wide rename is introduced. The active qBittorrent `/app/qBittorrent/webui/VueTorrent` path was verified to resolve to the same `/config/webui/VueTorrent` checkout; its existing setting remains correct.
