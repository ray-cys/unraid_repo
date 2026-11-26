# shellcheck shell=bash
# Pack producer receipts are immutable move evidence; the monitor owns plans.
pack_cleanup_record() {
    local id="$1" relative="$2" status="$3" reason="$4" identity="${5:-}" source="${6:-}" destination="${7:-}" file="$LOG_DIR/pack-cleanup.json" temp
    is_true "$DRY_RUN" && return 0
    [[ ! -L "$file" ]] || return 1
    [[ -f "$file" ]] || printf '{"schema":1,"jobs":{}}' >"$file"
    jq -e '.schema==1 and (.jobs|type)=="object"' "$file" >/dev/null || return 1
    if [[ -f "$file" ]] && jq -e --arg id "$id" --arg relative "$relative" --arg status "$status" --arg reason "$reason" --arg identity "$identity" --arg source "$source" --arg destination "$destination" '.jobs[$id].files[$relative] as $r|$r.status==$status and $r.reason==$reason and $r.identity==$identity and $r.sourcePath==$source and $r.quarantinePath==$destination' "$file" >/dev/null;then return 0;fi
    temp=$(mktemp "$LOG_DIR/.pack-cleanup.XXXXXX") || return 1
    jq --arg id "$id" --arg relative "$relative" --arg status "$status" --arg reason "$reason" --arg identity "$identity" --arg source "$source" --arg destination "$destination" --slurpfile job "$PACK_JOB_FILE" --argjson at "$(date +%s)" '
      $job[0] as $j|if .jobs[$id]!=null and (.jobs[$id].createdAt!=$j.createdAt or .jobs[$id].planFingerprint!=$j.planFingerprint) then error("pack receipt identity conflict") else
      .jobs[$id]=((.jobs[$id] // {createdAt:$j.createdAt,planFingerprint:$j.planFingerprint,files:{}})+{at:$at})|
      .jobs[$id].files[$relative]={status:$status,reason:$reason,identity:$identity,sourcePath:$source,quarantinePath:$destination,at:$at} end |
      .jobs|=with_entries(select(.value.at>=$at-180*86400))' "$file" >"$temp" && (( $(stat -c %s "$temp")<=33554432 )) && ops_publish_checkpoint "$temp" "$file"
}
# Rotate bounded consumers fairly, even when an early job is blocked indefinitely.
pack_cleanup_touch() {
    is_true "$DRY_RUN" && return 0
    local id="$1" file="$LOG_DIR/pack-cleanup.json" temp
    [[ ! -L "$file" ]] || return 1
    [[ -f "$file" ]] || printf '{"schema":1,"jobs":{}}' >"$file"
    temp=$(mktemp "$LOG_DIR/.pack-scan.XXXXXX") || return 1
    jq --arg id "$id" --argjson now "$(date +%s)" --slurpfile j "$PACK_JOB_FILE" '
      if .schema!=1 or (.jobs|type)!="object" or (.jobs[$id]!=null and (.jobs[$id].createdAt!=$j[0].createdAt or .jobs[$id].planFingerprint!=$j[0].planFingerprint)) then error("pack scan identity conflict") else
      .jobs[$id]=((.jobs[$id] // {createdAt:$j[0].createdAt,planFingerprint:$j[0].planFingerprint,files:{}})+{at:$now,lastScanAt:$now}) end' "$file" >"$temp" &&
      (( $(stat -c %s "$temp")<=33554432 )) && ops_publish_checkpoint "$temp" "$file"
}
pack_host_identity() {
    local path="$1" mtime ctime base
    [[ -f "$path" && ! -L "$path" && $(stat -c %h -- "$path") == 1 ]] || return 1
    base=$(stat -c '%d:%i:%s' -- "$path") && mtime=$(stat -c %y -- "$path") && ctime=$(stat -c %z -- "$path") || return 1
    printf '%s:%s:%s\n' "$base" "$(date -d "$mtime" +%s%N)" "$(date -d "$ctime" +%s%N)"
}
pack_file_move_guard() {
    [[ -f "$2" ]] || return 1
    local expected
    expected=$(jq -r '.sourceIdentity // ""' "$2") || return 1
    [[ -n "$expected" && $(pack_host_identity "$1") == "$expected" ]]
}
pack_cleanup_current_target() {
    local job="$1" entry="$2" proof="$3" ep="$TMP_DIR/pack-cleanup-episode.json" owner="$TMP_DIR/pack-cleanup-owner.json" file="$TMP_DIR/pack-cleanup-library.json" profiles="$TMP_DIR/pack-cleanup-profiles.json" formats="$TMP_DIR/pack-cleanup-formats.json" root="${SONARR_URL%/}/api/v3" target parent paths="$TMP_DIR/pack-cleanup-paths.jsonl" disposition
    parent=$(jq -r .disposalPlan.seriesId "$job");disposition=$(jq -r .disposition "$entry")
    arr_get "$root/series/$parent" "$SONARR_API_KEY" "$owner" && arr_get "$root/qualityprofile" "$SONARR_API_KEY" "$profiles" && arr_get "$root/customformat" "$SONARR_API_KEY" "$formats" || return 1
    jq -e --slurpfile j "$job" '.id==$j[0].disposalPlan.seriesId and .tvdbId==$j[0].disposalPlan.tvdbId and .qualityProfileId==$j[0].disposalPlan.profile.id and .monitored==true and (.tags|length)==0' "$owner" >/dev/null || return 1
    [[ $(pack_profile_signature "$profiles" "$formats") == $(jq -r .disposalPlan.profileSignature "$job") ]] || return 1
    # Active integrity repair holds protect the exact parent in every consumer.
    pack_repair_held "$parent" && return 1
    : >"$paths"
    while read -r target;do
      arr_get "$root/episode/$target" "$SONARR_API_KEY" "$ep" || return 1
      jq -e --arg t "$target" --slurpfile j "$job" --slurpfile owner "$owner" '. as $e|.id==($t|tonumber) and .seriesId==$j[0].disposalPlan.seriesId and .monitored==true and .seasonNumber==$j[0].disposalPlan.targets[$t].seasonNumber and .episodeNumber==$j[0].disposalPlan.targets[$t].episodeNumber and any($owner[0].seasons[]?;.seasonNumber==$e.seasonNumber and .monitored==true)' "$ep" >/dev/null || return 1
      if [[ "$disposition" == redundant ]];then
        jq -e --arg t "$target" --slurpfile j "$job" '.hasFile==true and .episodeFileId==$j[0].disposalPlan.targets[$t].fileId' "$ep" >/dev/null || return 1
      else
        [[ "$disposition" == rejected ]] || return 1
        jq -e '.hasFile==false and (.episodeFileId // 0)==0 or .hasFile==true and .episodeFileId>0' "$ep" >/dev/null || return 1
      fi
      if jq -e '.hasFile==true' "$ep" >/dev/null;then
        arr_get "$root/episodefile/$(jq -r .episodeFileId "$ep")" "$SONARR_API_KEY" "$file" || return 1
        jq -e --slurpfile e "$ep" --slurpfile j "$job" '.id==$e[0].episodeFileId and .seriesId==$j[0].disposalPlan.seriesId and .size>0 and (.path|type)=="string" and (.customFormatScore|type)=="number" and .customFormatScore>=$j[0].disposalPlan.profile.minFormatScore and (.quality.quality.id|type)=="number" and .quality.quality.id>0 and (.quality.quality.id as $q|[$j[0].disposalPlan.profile.items[]|select(.allowed==true)|.quality.id,.items[]?.quality.id]|index($q))!=null' "$file" >/dev/null || return 1
        local resolved
        resolved=$(resolve_imported_path Sonarr "$(jq -r .path "$file")") || return 1
        [[ -f "$resolved" && ! -L "$resolved" && $(stat_size "$resolved") -gt 0 ]] || return 1
        jq -nc --arg path "$resolved" '$path' >>"$paths" || return 1
      fi
    done < <(jq -r '.episodeIds[]' "$entry")
    jq -n --slurpfile j "$job" --slurpfile entry "$entry" --slurpfile paths "$paths" '{proofKind:"pack-file-disposition",packId:$j[0].downloadId,packCreatedAt:$j[0].createdAt,planFingerprint:$j[0].planFingerprint,packRelative:$entry[0].relative,sourceIdentity:$entry[0].identity,sourceEntry:$entry[0],targetIds:$entry[0].episodeIds,importedPaths:$paths,verifiedImportedPaths:($paths|length),remainingSourceMediaFiles:1}' >"$proof"
}
pack_cleanup_recover_receipts() {
    local id="$1" file="$LOG_DIR/source-removals.json" row relative status
    [[ -f "$file" ]] || return 0
    while IFS= read -r row;do
      relative=$(jq -r .packRelative <<<"$row");status=quarantined
      [[ $(jq -r .action <<<"$row") == quarantined ]] || status=manual_restore
      pack_cleanup_record "$id" "$relative" "$status" 'Recovered exact committed move/restore acknowledgement' "$(jq -r .sourceIdentity <<<"$row")" "$(jq -r .originalPath <<<"$row")" "$(jq -r '.destination // ""' <<<"$row")" || return 1
    done < <(jq -c --arg id "$id" --slurpfile j "$PACK_JOB_FILE" '.records[]?|select(.proofKind=="pack-file-disposition" and .packId==$id and .packCreatedAt==$j[0].createdAt and .planFingerprint==$j[0].planFingerprint and (.action=="quarantined" or .action=="restored" or .action=="restore_requested"))' "$file")
}
process_pack_cleanup() {
    local state="${MEDIA_PACK_STATE_FILE:-/mnt/vault/cloud/logs/script/media_health_monitor/pack-actions.json}" id item folder source entry="$TMP_DIR/pack-cleanup-entry.json" inventory="$TMP_DIR/pack-cleanup-inventory.json" proof="$TMP_DIR/pack-cleanup-proof.json" relative identity rc count=0 moved=0 path reason
    [[ ! -L "$state" ]] || { log ERROR 'Pack journal symlink refused; completed payloads preserved';return 1; }
    [[ -f "$state" ]] || { [[ ! -e "$state" ]] || return 1;return 0; }
    pack_document_valid "$state" || { log ERROR 'Pack journal invalid; pack payloads preserved';return 1; }
    local scan_receipts="$LOG_DIR/pack-cleanup.json" scan_empty="$TMP_DIR/pack-scan-empty.json"
    printf '{"schema":1,"jobs":{}}' >"$scan_empty"
    if [[ -e "$scan_receipts" || -L "$scan_receipts" ]];then
      [[ ! -L "$scan_receipts" ]] && jq -e '.schema==1 and (.jobs|type)=="object"' "$scan_receipts" >/dev/null || return 1
    else scan_receipts="$scan_empty";fi
    while read -r id;do
      moved=0
      ((count<2)) || break;count=$((count+1));mc_work_allowed sab || return 21
      PACK_JOB_FILE="$TMP_DIR/pack-cleanup-job.json";jq --arg id "$id" '.jobs[$id]' "$state" >"$PACK_JOB_FILE" || return 1
      jq '.disposalPlan' "$PACK_JOB_FILE" >"$TMP_DIR/pack-disposal-plan.json";pack_plan_valid "$TMP_DIR/pack-disposal-plan.json" || continue
      pack_cleanup_touch "$id" || return 1
      item=$(jq -c --arg id "$id" --slurpfile j "$PACK_JOB_FILE" '[.[]|select((.nzo_id|ascii_downcase)==$id and .status=="Completed" and ({nzo_id,name,storage,completed,category})==$j[0].disposalPlan.sab)]|select(length==1)|.[0]' "$SAB_HISTORY_FILE")
      [[ -n "$item" ]] || continue
      pack_cleanup_recover_receipts "$id" || return 1
      if [[ -f "$LOG_DIR/pack-cleanup.json" ]] && jq -e --arg id "$id" 'any(.jobs[$id].files[]?;.status=="manual_restore")' "$LOG_DIR/pack-cleanup.json" >/dev/null;then continue;fi
      folder=$(jq -r .disposalPlan.folder "$PACK_JOB_FILE");source=$(resolve_sab_path "$item" "$SAB_TV_DIR_REAL" || true)
      [[ -n "$source" && -d "$source" && ! -L "$source" ]] || continue
      # Never let generic completed/orphan cleanup interpret a pack as one movie.
      while IFS= read -r relative;do
        mc_work_allowed sab || return 21
        jq --arg relative "$relative" '.disposalPlan.files[]|select(.relative==$relative)' "$PACK_JOB_FILE" >"$entry" || return 1
        identity=$(jq -r .identity "$entry");path="$source/$relative"
        if [[ -f "$LOG_DIR/pack-cleanup.json" ]] && jq -e --arg id "$id" --arg relative "$relative" '.jobs[$id].files[$relative].status=="manual_restore"' "$LOG_DIR/pack-cleanup.json" >/dev/null;then break;fi
        if [[ -f "$LOG_DIR/pack-cleanup.json" ]] && jq -e --arg id "$id" --arg relative "$relative" --arg identity "$identity" '.jobs[$id].files[$relative].status=="quarantined" and .jobs[$id].files[$relative].identity==$identity' "$LOG_DIR/pack-cleanup.json" >/dev/null;then continue;fi
        reason=''
        if ! refresh_active_state || download_is_active_anywhere "$id" || orphan_has_live_reference "$source" Sonarr;then reason='Active/unverified download or source reference; pack file preserved'
        elif ! path_is_stable "$source" || ! path_is_stable "$path";then reason='Pack source is changing; file preserved'
        elif ! pack_source_inventory "$folder" "$SAB_CONTAINER_COMPLETE_ROOT" "$inventory";then reason='Complete source inventory unavailable or unsafe'
        else
          local receipts="$LOG_DIR/pack-cleanup.json" empty="$TMP_DIR/pack-cleanup-empty.json"
          printf '{"jobs":{}}' >"$empty";[[ -f "$receipts" ]] || receipts="$empty"
          if ! jq -e --arg id "$id" --slurpfile j "$PACK_JOB_FILE" --slurpfile done "$receipts" '
            (.files|sort_by(.relative))==([$j[0].disposalPlan.source.files[]|. as $f|select($done[0].jobs[$id].files[$f.relative].status!="quarantined")]|sort_by(.relative)) and
            ([.directories[].relative]|sort)==([$j[0].disposalPlan.source.directories[].relative]|sort)' "$inventory" >/dev/null;then reason='Source files changed or an unaccounted entry appeared; remaining pack preserved'
          elif ! pack_cleanup_current_target "$PACK_JOB_FILE" "$entry" "$proof";then reason='Current native identity/profile/library proof or repair hold prevents disposal'
          elif [[ $(pack_host_identity "$path" || true) != "$identity" ]];then reason='Source file identity changed since native pack proof';fi
        fi
        if [[ -n "$reason" ]];then log WARNING "Pack $id: preserved $relative; $reason";pack_cleanup_record "$id" "$relative" blocked "$reason" "$identity" "$path" || return 1;continue;fi
        ((MAX_QUARANTINES_PER_RUN==0 || QUARANTINED<MAX_QUARANTINES_PER_RUN)) || break
        # One wrapper per source file; exact job ID remains in the manifest.
        local component size
        component=$(printf %s "$relative"|sha256sum|cut -c1-16);size=$(jq -r .size "$entry");rc=0
        quarantine_payload Sonarr "$SAB_TV_CATEGORY" "$id" "$(jq -r .disposalPlan.title "$PACK_JOB_FILE")" "$(jq -r .disposalPlan.sab.completed "$PACK_JOB_FILE")" "$path" "$size" "$proof" "pack-$component" || rc=$?
        if ((rc==0));then
          pack_cleanup_record "$id" "$relative" quarantined 'Exact per-file quarantine committed; library media unchanged' "$identity" "$path" "$LAST_QUARANTINE_DESTINATION" || return 1
          QUARANTINED=$((QUARANTINED+1));BYTES_QUARANTINED=$((BYTES_QUARANTINED+size));moved=$((moved+1))
          QUARANTINE_DETAILS+=("Pack $id: quarantined $relative -> $LAST_QUARANTINE_DESTINATION ($(bytes_human "$size")); exact episode IDs $(jq -r '.episodeIds|map(tostring)|join(",")' "$entry").")
        else pack_cleanup_record "$id" "$relative" blocked 'Move deferred/failed; native intent and source remain protected' "$identity" "$path" || return 1;((rc!=20 && rc!=21)) || return "$rc";fi
      done < <(jq -r '.disposalPlan.files[]|select(.disposition=="redundant" or .disposition=="rejected")|.relative' "$PACK_JOB_FILE")
      # Empty directories only; retained metadata/unknown extras are never unlinked.
      if ((moved>0)) && ! is_true "$DRY_RUN" && refresh_active_state && ! download_is_active_anywhere "$id" && check_mover_guard 'before empty pack directory removal';then
        find "$source" -depth -type d -empty -exec rmdir -- {} \; 2>/dev/null || true
      fi
    done < <(jq -r --slurpfile scans "$scan_receipts" '.jobs|to_entries|sort_by($scans[0].jobs[.key].lastScanAt // 0)|.[]|select(.value.status=="queue_verified")|.key' "$state")
}
