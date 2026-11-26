# One-time secure-library duplicate cleanup

`tools/secure_duplicate_cleanup.sh` is a manually invoked maintenance tool, not a scheduled User Script. It consumes an explicit fresh manifest of keeper/extra paths prepared from filesystem and Plex records. The permanent `media_torrent_management` schedule and source-transfer workflow are unaffected.

The scope is `/mnt/user/secure/ポルノ` and performer folders below `/mnt/user/secure/プライベート`. `/mnt/user/secure/プライベート/ポルノコレクション` is a hard exclusion, checked before reading a candidate's metadata or contents. Photos, working torrent downloads, multipart media, directory links and other shares are outside the operation. A manifest cannot designate a keeper as another deletion. No original media, quarantine copies or `.dup` files are created.

Each extra requires the same nonzero size and SHA-256 as its keeper. Native `sha256sum` reads unverified files sequentially. Previous full-content proofs are reused only if device, inode, size, modification time and change time all match. Beginning/middle/end samples alone do not authorize deletion. A small atomic receipt checkpoints proof and intent before any unlink; it does not copy media. Different contents, changed paths, mismatched Plex references and uncertain APIs retain the files.

Immediately before exact-file deletion the tool takes the existing torrent, appdata and export leases, rechecks Mover, current Plex file references/watch-history priority, qBittorrent ownership, Plex playback and the full verified stat tuple. Only the designated extra is unlinked. Empty release directories may be removed with `rmdir`; library/performer roots and nonempty folders remain. It requests a normal scan once per affected Plex library after the batch, with no metadata refresh, forced trash emptying, Docker edits, notification email or additional cron.

```bash
# Inspect a prepared manifest only:
bash tools/secure_duplicate_cleanup.sh --manifest /tmp/cleanup-manifest.json

# Explicit execution after reviewing the selected paths:
bash tools/secure_duplicate_cleanup.sh \
  --manifest /tmp/cleanup-manifest.json \
  --evidence /tmp/full-results.jsonl \
  --execute
```

Default receipt: `/mnt/vault/cloud/logs/script/media_torrent_management/duplicate-cleanup-last.json`. The single receipt records retained and removed paths, hashes, estimated logical bytes removed, keeper verification and scan-request acceptance. Physical free-space changes can differ when other links, snapshots or open file handles retain blocks. An interrupted receipt records uncertain intent; rebuild/review the remaining-path manifest before another execution. Do not manually replay an unlink from an old plan. Raw manifests, Plex snapshots and personal catalogues are not committed to GitHub.

In the initial allowed-library inventory, four Plex items contained multiple versions. Three combined different release codes with different file sizes and were retained for review; Plex's multiple-version label alone is not evidence of identical files. Alternate H.264/HEVC encodes also remain outside exact-copy deletion.
