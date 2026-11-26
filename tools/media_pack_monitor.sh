# shellcheck shell=bash
# Native Sonarr pack workflow. No forced imports, library deletes or title identities.
pack_publish() {
    local candidate="$1" target="$PACK_STATE_FILE"
    pack_document_valid "$candidate" || return 1
    (( $(stat -c %s "$candidate")<=33554432 )) || return 1
    if [[ -f "$target" ]] && cmp -s "$candidate" "$target";then rm -f "$candidate";return 0;fi
    [[ ! -f "$target" ]] || { cp "$target" "$target.bak.tmp" && sync -f "$target.bak.tmp" && mv "$target.bak.tmp" "$target.bak"; } || return 1
    sync -f "$candidate" && mv "$candidate" "$target" && sync -f "$STATE_DIR"
}
pack_update() {
    local filter="$1";shift
    jq "$@" "$filter" "$PACK_STATE_FILE" >"$TMP_DIR/pack-state.next" && pack_publish "$TMP_DIR/pack-state.next"
}
pack_snapshot() {
    local id="$1" output="$2" root="$SONARR_API_ROOT" key="$SONARR_API_KEY" queue="$TMP_DIR/pack-queue.json" sab="$TMP_DIR/pack-sab.json" history="$TMP_DIR/pack-history.json"
    local series="$TMP_DIR/pack-series.json" profiles="$TMP_DIR/pack-profiles.json" formats="$TMP_DIR/pack-formats.json" profile="$TMP_DIR/pack-profile.json" preview="$TMP_DIR/pack-preview.json" source="$TMP_DIR/pack-source.json"
    local folder parent signature rows="$TMP_DIR/pack-targets.jsonl" target ep="$TMP_DIR/pack-episode.json" file="$TMP_DIR/pack-file.json" prior="$TMP_DIR/pack-target-history.json" pid
    [[ "$id" =~ ^[a-z0-9-]+$ ]] || return 1
    jq --arg id "$id" '[.history.slots[]?|select((.nzo_id|ascii_downcase)==$id and .status=="Completed")]|select(length==1)|.[0]' "$SAB_HISTORY" >"$sab" || return 1
    jq -e --argjson now "$START_TIME" 'type=="object" and (.completed|tonumber)>0 and $now-(.completed|tonumber)>=21600' "$sab" >/dev/null || return 1
    jq -e --arg id "$id" 'all(.queue.slots[]?;(.nzo_id|ascii_downcase)!=$id)' "$SAB_QUEUE" >/dev/null || return 1
    folder=$(jq -r .storage "$sab")
    [[ "$folder" == "$AUTOMATION_SONARR_COMPLETE_ROOT/"* && "$folder" != *'/../'* && "$folder" != */.. ]] || return 1
    fetch_arr_queue Sonarr "$root" "$key" "$queue" || return 1
    jq -e --arg id "$id" --arg folder "$folder" --argjson now "$START_TIME" 'all(.records[]|select((.downloadId // ""|ascii_downcase)==$id);.protocol=="usenet" and .status=="completed" and .outputPath==$folder and ((try (.added|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) catch $now)<=$now-21600))' "$queue" >/dev/null || return 1
    jq -e --arg id "$id" 'all(.records[]?;(.downloadId // ""|ascii_downcase)!=$id)' "$RADARR_QUEUE" >/dev/null || return 1
    fetch_arr_history_by_download_id Sonarr "$id" "$history" || return 1
    jq -e --arg id "$id" '.totalRecords==(.records|length) and all(.records[];(.downloadId // ""|ascii_downcase)==$id) and any(.records[];.eventType=="grabbed") and ([.records[]|select(.eventType=="grabbed")|{sourceTitle,quality}]|unique|length)==1' "$history" >/dev/null || return 1
    parent=$(jq -r '[.records[]|select(.eventType=="grabbed")|.seriesId]|unique|select(length==1)|.[0]' "$history")
    [[ "$parent" =~ ^[1-9][0-9]*$ ]] || return 1
    pack_repair_held "$parent" && return 1
    api_get "$root/series/$parent" "$key" "$series" && api_get "$root/qualityprofile" "$key" "$profiles" && api_get "$root/customformat" "$key" "$formats" || return 1
    jq -e --argjson id "$parent" '.id==$id and .monitored==true and .tvdbId>0 and (.tags|length)==0' "$series" >/dev/null || return 1
    pid=$(jq -r .qualityProfileId "$series");jq --argjson id "$pid" '.[]|select(.id==$id)' "$profiles" >"$profile"
    jq -e 'type=="object" and (.minFormatScore|type)=="number"' "$profile" >/dev/null || return 1
    signature=$(pack_profile_signature "$profiles" "$formats") || return 1
    jq -e --arg signature "$signature" --argjson now "$START_TIME" '.profiles.Sonarr.signature==$signature and .profiles.Sonarr.holdUntil<=$now and $now-.profiles.Sonarr.checkedAt<=5400' "$AUTOMATION_STATE_FILE" >/dev/null || return 1
    pack_source_inventory "$folder" "$AUTOMATION_SONARR_COMPLETE_ROOT" "$source" || return 1
    local query
    query=$(jq -nr --arg folder "$folder" --arg id "$id" '"folder="+($folder|@uri)+"&downloadId="+($id|@uri)+"&filterExistingFiles=false"')
    api_get "$root/manualimport?$query" "$key" "$preview" || return 1
    jq -e --arg id "$id" --arg folder "$folder" --argjson parent "$parent" --slurpfile source "$source" '
      type=="array" and length>0 and length<=200 and
      all(.[];. as $v|.series.id==$parent and (.downloadId|ascii_downcase)==$id and .size>0 and (.episodes|length)>0 and .path==($folder+"/"+.relativePath) and any($source[0].files[];.relative==$v.relativePath and .size==$v.size)) and
      ([.[].relativePath]|sort)==([$source[0].files[]|select(.video)|.relative]|sort)' "$preview" >/dev/null || return 1
    : >"$rows"
    local targets="$TMP_DIR/pack-target-ids"
    jq -r '[.records[]|select(.eventType=="grabbed")|.episodeId]|unique|select(length>0 and length<=40)|.[]' "$history" >"$targets" || return 1
    [[ -s "$targets" ]] || return 1
    while IFS= read -r target;do
      runtime_budget_allows_optional_phase pack-proof || return 75
      [[ "$target" =~ ^[1-9][0-9]*$ ]] || return 1
      api_get "$root/episode/$target" "$key" "$ep" || return 1
      jq -e --argjson id "$target" --argjson parent "$parent" --slurpfile series "$series" '. as $e|.id==$id and .seriesId==$parent and .monitored==true and .episodeNumber>0 and any($series[0].seasons[]?;.seasonNumber==$e.seasonNumber and .monitored==true)' "$ep" >/dev/null || return 1
      printf '{}' >"$file"
      if jq -e '.hasFile==true and .episodeFileId>0' "$ep" >/dev/null;then
        api_get "$root/episodefile/$(jq -r .episodeFileId "$ep")" "$key" "$file" || return 1
        jq -e --argjson parent "$parent" --slurpfile ep "$ep" '.id==$ep[0].episodeFileId and .seriesId==$parent and .size>0 and (.path|type)=="string"' "$file" >/dev/null || return 1
      elif jq -e '.hasFile==false and (.episodeFileId // 0)==0' "$ep" >/dev/null;then
        automation_target_history episode "$target" "$root" "$key" "$prior" || return 1
        jq -e 'all(.records[];.eventType!="episodeFileDeleted" and .eventType!="downloadFolderImported")' "$prior" >/dev/null || return 1
        if [[ -f "$STATE_DIR/import-receipts.json" ]];then
          automation_document_valid "$STATE_DIR/import-receipts.json" receipts || return 1
          jq -e --argjson id "$target" 'all(.receipts[]|select(.app=="Sonarr");all(.targets[];.targetId!=$id))' "$STATE_DIR/import-receipts.json" >/dev/null || return 1
        fi
        jq -e --argjson id "$target" 'all(.downloadLedger[]?|select(.app=="Sonarr" and ((.arrImportedAt // 0)>0 or (.manuallyDismissedAt // 0)>0));all(.targets[]?;(.episodeId // 0)!=$id))' "$STATE_FILE" >/dev/null || return 1
      else return 1;fi
      jq -nc --slurpfile e "$ep" --slurpfile f "$file" --slurpfile p "$profile" --slurpfile h "$history" '
        $e[0] as $e|$f[0] as $f|{key:($e.id|tostring),value:{id:$e.id,seriesId:$e.seriesId,seasonNumber:$e.seasonNumber,episodeNumber:$e.episodeNumber,monitored:$e.monitored,hasFile:$e.hasFile,fileId:($e.episodeFileId // 0),filePath:($f.path // ""),fileDateAdded:($f.dateAdded // ""),
          goodExisting:($e.hasFile==true and ($f.customFormatScore|type)=="number" and ($f.quality.quality.id|type)=="number" and $f.quality.quality.id>0 and $f.customFormatScore>=$p[0].minFormatScore and ([$p[0].items[]|select(.allowed==true)|.quality.id,.items[]?.quality.id]|index($f.quality.quality.id))!=null),
          importedByJob:any($h[0].records[];.eventType=="downloadFolderImported" and .episodeId==$e.id and ((.data.fileId // "0"|tonumber?)==$e.episodeFileId))}}' >>"$rows" || return 1
    done <"$targets"
    jq -n --arg id "$id" --arg signature "$signature" --arg folder "$folder" --argjson parent "$parent" --slurpfile s "$series" --slurpfile p "$profile" --slurpfile q "$queue" --slurpfile sab "$sab" --slurpfile h "$history" --slurpfile source "$source" --slurpfile preview "$preview" --slurpfile targets "$rows" '
      ($targets|from_entries) as $targets |
      {app:"Sonarr",downloadId:$id,seriesId:$parent,tvdbId:$s[0].tvdbId,title:$sab[0].name,folder:$folder,profileSignature:$signature,profile:$p[0],source:$source[0],targets:$targets,
       sab:($sab[0]|{nzo_id,name,storage,completed,category}),queueIds:[$q[0].records[]|select((.downloadId // ""|ascii_downcase)==$id)|.id]|sort,
       release:([$h[0].records[]|select(.eventType=="grabbed")|{sourceTitle,quality}]|first),files:[$preview[0][]|. as $v|
        ($v.rejections // []|map(.reason)) as $reasons|([$source[0].files[]|select(.relative==$v.relativePath)]|first) as $f|
        {relative:$v.relativePath,size:$f.size,identity:$f.identity,episodeIds:[$v.episodes[].id]|sort,
         disposition:(if ($v.quality.quality.id|type)!="number" or $v.quality.quality.id<=0 or (([$p[0].items[]|select(.allowed==true)|.quality.id,.items[]?.quality.id]|index($v.quality.quality.id))==null) then "unknown"
          elif all($v.episodes[];$targets[.id|tostring]!=null and .seriesId==$parent and .seasonNumber==$targets[.id|tostring].seasonNumber and .episodeNumber==$targets[.id|tostring].episodeNumber)|not then "unknown"
          elif ($reasons|length)>0 and all($reasons[];test("^Not (a |an )?(Custom Format|quality revision|upgrade for existing)";"i") and (test("BeforeRename|AfterRename";"i")|not)) and all($v.episodes[];$targets[.id|tostring].goodExisting) then "redundant"
          elif ($reasons|length)>0 and all($reasons[];test("^Custom Formats? .*(have score|score of|score) -?[0-9]+ .*below .*profile minimum -?[0-9]+$";"i")) and ($v.customFormatScore|type)=="number" and $v.customFormatScore<$p[0].minFormatScore and all($v.episodes[];$targets[.id|tostring].hasFile==false) then "rejected"
          elif ($reasons|length)==0 or all($reasons[];test("being used by another process|sharing violation|resource (temporarily unavailable|busy)|temporarily locked";"i")) then "required" else "unknown" end),reasons:$reasons}]} |
      .accounted=(all(.files[];.disposition=="redundant" or .disposition=="rejected") and
        (. as $plan|all(.targets[];. as $t|any($plan.files[];.episodeIds|index($t.id)) or ($t.goodExisting and $t.importedByJob)))) |
      .unknown=((. as $plan|any(.targets[];. as $t|((any($plan.files[];.episodeIds|index($t.id)))|not) and (($t.goodExisting and $t.importedByJob)|not))) or any(.files[];.disposition=="unknown") or ([.files[].episodeIds[]]|length)!=([.files[].episodeIds[]]|unique|length))' >"$output" || return 1
    pack_plan_valid "$output" || return 1
    jq -e --arg id "$id" --slurpfile plan "$output" 'all(.records[]|select((.downloadId // ""|ascii_downcase)==$id);.seriesId==$plan[0].seriesId and ((.episodeId // 0)==0 or $plan[0].targets[(.episodeId|tostring)]!=null))' "$queue" >/dev/null || return 1
}
pack_missing_guard() {
    local id="$1" target="$2" root="$SONARR_API_ROOT" key="$SONARR_API_KEY" job="$TMP_DIR/pack-search-job.json" object="$TMP_DIR/pack-search-episode.json" owner="$TMP_DIR/pack-search-series.json" history="$TMP_DIR/pack-search-history.json" queue="$TMP_DIR/pack-search-queue.json" profile="$TMP_DIR/pack-search-profiles.json" formats="$TMP_DIR/pack-search-formats.json" parent
    jq --arg id "$id" '.jobs[$id]' "$PACK_STATE_FILE" >"$job" || return 1
    jq -e --arg target "$target" '.status=="queue_verified" and .disposalPlan.targets[$target]!=null and any(.disposalPlan.files[];.disposition=="rejected" and (.episodeIds|index($target|tonumber))!=null)' "$job" >/dev/null || return 1
    parent=$(jq -r .disposalPlan.seriesId "$job")
    pack_repair_held "$parent" && return 1
    api_get "$root/episode/$target" "$key" "$object" && api_get "$root/series/$parent" "$key" "$owner" || return 1
    jq -e --arg target "$target" --slurpfile j "$job" '.id==($target|tonumber) and .seriesId==$j[0].disposalPlan.seriesId and .seasonNumber==$j[0].disposalPlan.targets[$target].seasonNumber and .episodeNumber==$j[0].disposalPlan.targets[$target].episodeNumber and .monitored==true and .hasFile==false and (.episodeFileId // 0)==0' "$object" >/dev/null || return 1
    jq -e --slurpfile j "$job" --slurpfile e "$object" '.id==$j[0].disposalPlan.seriesId and .tvdbId==$j[0].disposalPlan.tvdbId and .qualityProfileId==$j[0].disposalPlan.profile.id and .monitored==true and (.tags|length)==0 and any(.seasons[]?;.seasonNumber==$e[0].seasonNumber and .monitored==true)' "$owner" >/dev/null || return 1
    fetch_arr_queue Sonarr "$root" "$key" "$queue" || return 1
    jq -e --argjson parent "$parent" 'all(.records[];.seriesId!=$parent)' "$queue" >/dev/null || return 1
    fetch_sab_queue "$TMP_DIR/pack-search-sab.json" || return 1
    jq -e --arg category "${SAB_TV_CATEGORY,,}" --slurpfile q "$queue" '[$q[0].records[].downloadId|ascii_downcase] as $known|all(.queue.slots[]?|select((.cat // .category // ""|ascii_downcase)==$category);(.nzo_id|ascii_downcase) as $id|($known|index($id))!=null)' "$TMP_DIR/pack-search-sab.json" >/dev/null || return 1
    automation_target_history episode "$target" "$root" "$key" "$history" || return 1
    jq -e --arg id "$id" --argjson since "$((START_TIME-7*86400))" 'all(.records[];.eventType!="episodeFileDeleted" and .eventType!="downloadFolderImported" and (.eventType!="grabbed" or (.downloadId|ascii_downcase)==$id or ((try (.date|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) catch 9999999999)<$since)))' "$history" >/dev/null || return 1
    if [[ -f "$STATE_DIR/import-receipts.json" ]];then
      automation_document_valid "$STATE_DIR/import-receipts.json" receipts || return 1
      jq -e --argjson target "$target" 'all(.receipts[]|select(.app=="Sonarr");all(.targets[];.targetId!=$target))' "$STATE_DIR/import-receipts.json" >/dev/null || return 1
    fi
    jq -e --argjson target "$target" 'all(.downloadLedger[]?|select(.app=="Sonarr" and ((.arrImportedAt // 0)>0 or (.manuallyDismissedAt // 0)>0));all(.targets[]?;(.episodeId // 0)!=$target))' "$STATE_FILE" >/dev/null || return 1
    api_get "$root/qualityprofile" "$key" "$profile" && api_get "$root/customformat" "$key" "$formats" || return 1
    [[ $(pack_profile_signature "$profile" "$formats") == $(jq -r .disposalPlan.profileSignature "$job") ]]
}
pack_command_guard() {
    local candidate="$1" id kind fresh="$TMP_DIR/pack-final-plan.json" expected
    id=$(jq -r .packId "$candidate");kind=$(jq -r .kind "$candidate")
    if [[ "$kind" == missing-search ]];then pack_missing_guard "$id" "$(jq -r .targetId "$candidate")";return $?;fi
    jq -e --arg id "$id" --argjson now "$START_TIME" '.jobs[$id].observation|.runs>=2 and .at<=$now and $now-.at<=1200' "$PACK_STATE_FILE" >/dev/null || return 1
    pack_snapshot "$id" "$fresh" || return 1
    expected=$(jq -r --arg id "$id" '.jobs[$id].observation.fingerprint' "$PACK_STATE_FILE")
    [[ $(jq -Sc . "$fresh"|sha256sum|cut -d ' ' -f1) == "$expected" ]] || return 1
    jq -e '.unknown==false and any(.files[];.disposition=="required")' "$fresh" >/dev/null
}
pack_verify_queue_removal() {
    local id="$1" queue="$TMP_DIR/pack-verify-queue.json" history="$TMP_DIR/pack-verify-history.json" blocklist="$TMP_DIR/pack-blocklist.json" job="$TMP_DIR/pack-verify-job.json"
    jq --arg id "$id" '.jobs[$id]' "$PACK_STATE_FILE" >"$job" || return 1
    fetch_arr_queue Sonarr "$SONARR_API_ROOT" "$SONARR_API_KEY" "$queue" && fetch_arr_history_by_download_id Sonarr "$id" "$history" || return 1
    jq -e --arg id "$id" 'all(.records[];(.downloadId // ""|ascii_downcase)!=$id)' "$queue" >/dev/null || return 1
    jq -e --slurpfile j "$job" --arg id "$id" '$j[0].disposalPlan as $p|. as $h|.totalRecords==(.records|length) and all($p.targets[];. as $t|any($h.records[];(.downloadId|ascii_downcase)==$id and .seriesId==$p.seriesId and .episodeId==$t.id and (.eventType==(if $j[0].blocklist then "downloadFailed" else "downloadIgnored" end) or ($t.importedByJob and .eventType=="downloadFolderImported"))))' "$history" >/dev/null || return 1
    if jq -e '.blocklist==true' "$job" >/dev/null;then
      api_get "$SONARR_API_ROOT/blocklist?page=1&pageSize=100&sortKey=date&sortDirection=descending" "$SONARR_API_KEY" "$blocklist" || return 1
      jq -e --slurpfile j "$job" 'any(.records[]; .seriesId==$j[0].disposalPlan.seriesId and .sourceTitle==$j[0].disposalPlan.release.sourceTitle and .quality==$j[0].disposalPlan.release.quality and (.episodeIds|sort)==([$j[0].disposalPlan.targets[].id]|sort) and ((try (.date|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) catch 0)>=$j[0].queueIntentAt-5))' "$blocklist" >/dev/null || return 1
    fi
    cp "$queue" "$SONARR_QUEUE" || return 1
    pack_update '.jobs[$id].status="queue_verified"|.jobs[$id].queueVerifiedAt=$at|.jobs[$id].reason="Exact queue removal and native disposition verified; payload retained pending guarded file cleanup"' --arg id "$id" --argjson at "$START_TIME"
}
pack_dispatch() {
    local id="$1" plan="$2" fresh="$TMP_DIR/pack-dispatch-fresh.json" fingerprint first queue_id blocklist rc=0
    automation_window_open && automation_action_budget && monitor_mutation_gate Sonarr && automation_no_active_command "$SONARR_API_ROOT" "$SONARR_API_KEY" || return 0
    jq -e 'all(.actions[];.status!="intent")' "$AUTOMATION_STATE_FILE" >/dev/null || return 0
    jq -e '.accounted==true and .unknown==false and (.queueIds|length)>0' "$plan" >/dev/null || return 0
    jq -e --arg id "$id" --argjson now "$START_TIME" '.jobs[$id].observation|.runs>=2 and .at<=$now and $now-.at<=1200' "$PACK_STATE_FILE" >/dev/null || return 0
    pack_snapshot "$id" "$fresh" || return 0
    fingerprint=$(jq -Sc . "$fresh"|sha256sum|cut -d ' ' -f1)
    [[ "$fingerprint" == $(jq -r --arg id "$id" '.jobs[$id].observation.fingerprint' "$PACK_STATE_FILE") ]] || return 0
    first=$(jq -r '[.targets[].id]|min' "$fresh");queue_id=$(jq -r '.queueIds[0]' "$fresh");blocklist=$(jq 'any(.files[];.disposition=="rejected")' "$fresh")
    usr_ops_arr_reserve "pack-queue:$id" Sonarr "$first" || return 0
    pack_update '.jobs[$id].status="queue_intent"|.jobs[$id].queueIntentAt=$at|.jobs[$id].disposalPlan=$plan[0]|.jobs[$id].planFingerprint=$fingerprint|.jobs[$id].blocklist=$blocklist|.jobs[$id].reason="Native queue disposition dispatched; read-back required before disposal"' --arg id "$id" --argjson at "$START_TIME" --slurpfile plan "$fresh" --arg fingerprint "$fingerprint" --argjson blocklist "$blocklist" || return 1
    policy_mutate DELETE "$SONARR_API_ROOT/queue/$queue_id?removeFromClient=false&blocklist=$blocklist&skipRedownload=true&changeCategory=false" "$SONARR_API_KEY" '' "$TMP_DIR/pack-delete-response.json" || rc=$?
    if ((rc==75));then
      usr_ops_arr_release_undispatched "pack-queue:$id" || true
      pack_update '.jobs[$id].status="observing"|del(.jobs[$id].queueIntentAt,.jobs[$id].disposalPlan,.jobs[$id].planFingerprint)|.jobs[$id].reason="Local gate refused before dispatch; queue unchanged"' --arg id "$id";return $?
    fi
    pack_verify_queue_removal "$id" || pack_update '.jobs[$id].reason="Queue disposition outcome unverified; no DELETE replay, search or disposal allowed"' --arg id "$id"
}
pack_submit_import() {
    local id="$1" plan="$2" candidate="$TMP_DIR/pack-import-command.json" count last
    jq -e '.unknown==false and any(.files[];.disposition=="required")' "$plan" >/dev/null || return 0
    count=$(jq --arg id "$id" '[.actions[]|select(.kind=="import-retry" and (.downloadId|ascii_downcase)==$id)]|length' "$AUTOMATION_STATE_FILE")
    last=$(jq --arg id "$id" '[.actions[]|select(.kind=="import-retry" and (.downloadId|ascii_downcase)==$id)|.startedAt]|max // 0' "$AUTOMATION_STATE_FILE")
    if ((count>=AUTOMATION_IMPORT_RETRY_MAX_ATTEMPTS));then
      pack_update '.jobs[$id].status="blocked"|.jobs[$id].reason="Native Auto import retry limit reached; required files retained. Exact mapping is reassessed on later action windows; no fourth retry or speculative rejection"' --arg id "$id"
      return $?
    fi
    ((START_TIME-last>=14400)) || return 0
    jq --arg id "$id" '. as $p|([.files[]|select(.disposition=="required")|.episodeIds[]]|unique|.[0]|tostring) as $t|
      {key:("Sonarr:pack-import:"+$id),app:"Sonarr",kind:"import-retry",packId:$id,downloadId:$id,mediaKind:"episode",targetId:.targets[$t].id,parentId:.seriesId,title:.title,reason:["Fully mapped pack has files eligible for native Auto import"],identity:.targets[$t],parentExternalId:.tvdbId,command:{name:"DownloadedEpisodesScan",path:.folder,downloadClientId:$id,importMode:"Auto"}}' "$plan" >"$candidate" || return 1
    automation_submit_command "$candidate" "$SONARR_API_ROOT" "$SONARR_API_KEY"
}
pack_submit_searches() {
    local id="$1" row target candidate="$TMP_DIR/pack-search-candidate.json" job="$TMP_DIR/pack-search-plan.json" recent
    automation_window_open && automation_action_budget || return 0
    jq --arg id "$id" '.jobs[$id]' "$PACK_STATE_FILE" >"$job" || return 1
    while IFS= read -r target;do
      runtime_budget_allows_optional_phase pack-search || break
      automation_action_budget || break
      # One search per target, with the existing weekly bound across producers.
      recent=$(jq --argjson target "$target" --argjson cutoff "$((START_TIME-7*86400))" '[.actions[]|select(.app=="Sonarr" and .targetId==$target and .kind=="missing-search" and .startedAt>=$cutoff)]|length' "$AUTOMATION_STATE_FILE")
      ((recent==0)) || continue
      if [[ -f "$STATE_DIR/policy-actions.json" ]] && ! jq -e --argjson target "$target" --argjson cutoff "$((START_TIME-7*86400))" 'all(.actions[];.app!="Sonarr" or .targetId!=$target or .mode!="replace" or .startedAt<$cutoff)' "$STATE_DIR/policy-actions.json" >/dev/null;then continue;fi
      pack_missing_guard "$id" "$target" || continue
      jq --arg id "$id" --arg target "$target" '.disposalPlan as $p|{key:("Sonarr:pack-search:"+$id+":"+$target),app:"Sonarr",kind:"missing-search",packId:$id,mediaKind:"episode",targetId:($target|tonumber),parentId:$p.seriesId,title:$p.title,identity:($p.targets[$target]+{episodeFileId:$p.targets[$target].fileId}),parentExternalId:$p.tvdbId,command:{name:"EpisodeSearch",episodeIds:[($target|tonumber)]}}' "$job" >"$candidate" || return 1
      automation_submit_command "$candidate" "$SONARR_API_ROOT" "$SONARR_API_KEY" || return 1
    done < <(jq -r '[.disposalPlan.files[]|select(.disposition=="rejected")|.episodeIds[]]|unique|.[]' "$job")
}
pack_followup() {
    local id="$1" record target ep="$TMP_DIR/pack-followup-episode.json" file="$TMP_DIR/pack-followup-file.json" job="$TMP_DIR/pack-followup-job.json" fingerprint prior runs seen epoch parent
    jq --arg id "$id" '.jobs[$id]' "$PACK_STATE_FILE" >"$job" || return 1
    parent=$(jq -r .disposalPlan.seriesId "$job")
    local owner="$TMP_DIR/pack-followup-owner.json" profiles="$TMP_DIR/pack-followup-profiles.json" formats="$TMP_DIR/pack-followup-formats.json"
    api_get "$SONARR_API_ROOT/series/$parent" "$SONARR_API_KEY" "$owner" && api_get "$SONARR_API_ROOT/qualityprofile" "$SONARR_API_KEY" "$profiles" && api_get "$SONARR_API_ROOT/customformat" "$SONARR_API_KEY" "$formats" || return 0
    jq -e --slurpfile j "$job" '.id==$j[0].disposalPlan.seriesId and .tvdbId==$j[0].disposalPlan.tvdbId and .qualityProfileId==$j[0].disposalPlan.profile.id and .monitored==true and (.tags|length)==0' "$owner" >/dev/null || return 0
    [[ $(pack_profile_signature "$profiles" "$formats") == $(jq -r .disposalPlan.profileSignature "$job") ]] || return 0
    while IFS= read -r target;do
      runtime_budget_allows_optional_phase pack-followup || return 0
      prior=$(jq -r --arg t "$target" '.proofs[$t].fingerprint // ""' "$job");seen=$(jq -r --arg t "$target" '.proofs[$t].at // 0' "$job")
      ((START_TIME-seen>=240)) || continue
      api_get "$SONARR_API_ROOT/episode/$target" "$SONARR_API_KEY" "$ep" || continue
      jq -e --arg t "$target" --slurpfile j "$job" --slurpfile owner "$owner" '. as $e|any($owner[0].seasons[]?;.seasonNumber==$e.seasonNumber and .monitored==true) and .id==($t|tonumber) and .seriesId==$j[0].disposalPlan.seriesId and .seasonNumber==$j[0].disposalPlan.targets[$t].seasonNumber and .episodeNumber==$j[0].disposalPlan.targets[$t].episodeNumber and .monitored==true and .hasFile==true and .episodeFileId>0' "$ep" >/dev/null || { pack_update '.jobs[$id].proofs[$t]={runs:0,verified:false,at:$at}' --arg id "$id" --arg t "$target" --argjson at "$START_TIME";continue; }
      api_get "$SONARR_API_ROOT/episodefile/$(jq -r .episodeFileId "$ep")" "$SONARR_API_KEY" "$file" || continue
      epoch=$(date_to_epoch "$(jq -r '.dateAdded // ""' "$file")")
      ((epoch>=$(jq -r .queueIntentAt "$job"))) || continue
      jq -e --argjson parent "$parent" --slurpfile e "$ep" --slurpfile j "$job" '.id==$e[0].episodeFileId and .seriesId==$parent and .size>0 and (.path|length)>0 and (.customFormatScore|type)=="number" and (.quality.quality.id|type)=="number" and .quality.quality.id>0 and .customFormatScore>=$j[0].disposalPlan.profile.minFormatScore and (.quality.quality.id as $quality|[$j[0].disposalPlan.profile.items[]|select(.allowed==true)|.quality.id,.items[]?.quality.id]|index($quality))!=null' "$file" >/dev/null || continue
      fingerprint=$(jq -Sc '{id,seriesId,path,size,dateAdded,quality,customFormatScore}' "$file"|sha256sum|cut -d ' ' -f1)
      runs=$(jq -r --arg t "$target" '.proofs[$t].runs // 0' "$job");if [[ "$prior" == "$fingerprint" ]];then runs=$((runs+1));else runs=1;fi
      pack_update '.jobs[$id].proofs[$t]={fingerprint:$fp,runs:$runs,at:$at,fileId:$file,verified:($runs>=2)}' --arg id "$id" --arg t "$target" --arg fp "$fingerprint" --argjson runs "$runs" --argjson at "$START_TIME" --argjson file "$(jq .id "$file")" || return 1
    done < <(jq -r '[.disposalPlan.files[]|select(.disposition=="rejected")|.episodeIds[]]|unique|.[]' "$job")
}
pack_reconcile_receipts() {
    local file="${MEDIA_PACK_CLEANUP_RECEIPT:-/mnt/vault/cloud/logs/script/media_cleanup/sab/pack-cleanup.json}" empty="$TMP_DIR/pack-empty-receipts.json"
    printf '{"schema":1,"jobs":{}}' >"$empty"
    if [[ -e "$file" ]];then [[ ! -L "$file" ]] && jq -e '.schema==1 and (.jobs|type)=="object"' "$file" >/dev/null || return 1;else file="$empty";fi
    pack_update ' .jobs|=with_entries(.value as $j|if $receipt[0].jobs[.key] as $c|$c!=null and $c.createdAt==$j.createdAt and $c.planFingerprint==$j.planFingerprint then .value.cleanup=$receipt[0].jobs[.key] else . end |
      if any((.value.cleanup.files // {})[];.status=="manual_restore") then .value.status="manual_hold"|.value.reason="Operator restore intent recorded; automatic re-quarantine and further pack commands held"
      elif .value.status=="queue_verified" then .value as $v|([.value.disposalPlan.files[]|select(.disposition=="rejected")|.episodeIds[]]|unique) as $needed|
        if all($v.disposalPlan.files[];. as $f|$v.cleanup.files[$f.relative].status=="quarantined" and $v.cleanup.files[$f.relative].identity==$f.identity) and all($needed[];$v.proofs[tostring].verified==true and $v.proofs[tostring].at==$now) then .value.status="resolved"|.value.reason="Every source video has committed quarantine proof and all required replacements were verified on two scans" else . end else . end)' --slurpfile receipt "$file" --argjson now "$START_TIME"
}
pack_report() {
    local id job signature sent detail status event=progress commands="$TMP_DIR/pack-report-commands.json"
    while IFS= read -r job;do
      id=$(jq -r .key <<<"$job");jq --arg id "$id" '[.actions[]?|select(.packId==$id)]|group_by([.kind,.targetId])|map(sort_by(.startedAt)|last|{kind,targetId,status,commandId,nativeMessage})' "$AUTOMATION_STATE_FILE" >"$commands" || return 1;status=$(jq -r .value.status <<<"$job")
      signature=$(jq -Sc --slurpfile commands "$commands" '.value|{status,reason,proofs:((.proofs // {})|with_entries(.value|={fileId,verified})),cleanup:((.cleanup.files // {})|with_entries(.value|={status,reason,identity})),commands:$commands[0]}' <<<"$job"|sha256sum|cut -d ' ' -f1)
      sent=$(jq -r --arg id "$id" '.monitor.packNotifications[$id] // ""' "$STATE_FILE")
      detail=$(jq -r --slurpfile commands "$commands" '.value|. as $j|(.disposalPlan // .plan // {}) as $p|"Download ID: "+.downloadId+"\nPack workflow: "+.status+"; "+(.reason // "Evidence collection pending")+"\nSource videos: "+(($p.files // []|length)|tostring)+"; mapped episode IDs: "+(($p.targets // {}|length)|tostring)+".\n"+
        ([($p.files // [])[]|. as $f|"- "+($f.relative|.[0:500])+": "+$f.disposition+"; cleanup="+(.relative as $r|($j.cleanup.files[$r].status // "pending"))+(.relative as $r|if $j.cleanup.files[$r].status=="blocked" then "; "+($j.cleanup.files[$r].reason // "Proof unavailable"|.[0:240]) else "" end)+(.relative as $r|if ($j.cleanup.files[$r].quarantinePath // "")!="" then " -> "+($j.cleanup.files[$r].quarantinePath|.[0:500]) else "" end)]|.[:12]|join("\n"))+"\nNative commands: "+([$commands[0][]|.kind+" episode "+(.targetId|tostring)+": "+.status+" (command "+(.commandId // "unconfirmed"|tostring)+")"+(if (.nativeMessage // "")!="" then ": "+(.nativeMessage|.[0:200]) else "" end)]|join("; "))+"\nExact files, IDs, per-file cleanup receipts and native command intents remain in the pack journal. No library media was moved/deleted; no forced import or series search was requested."' <<<"$job")
      if [[ "$status" == queue_intent ]] && ((START_TIME-$(jq -r '.value.queueIntentAt // 0' <<<"$job")>1200));then
        record_normalized_issue "PACK:REVIEW:$id" Sonarr 'Pack queue disposition unverified' ARR_PACK_AUTOMATION WARNING queue-unverified 'Exact queue disposition could not be verified; no request replay or file disposal' 0 "$detail";continue
      fi
      if jq -e --slurpfile jobs "$PACK_STATE_FILE" --arg id "$id" '$jobs[0].jobs[$id] as $job|any(.[];. as $a|(.status=="failed" or .status=="intent") and $job.status!="resolved" and (($job.proofs[($a.targetId|tostring)].verified // false)|not) and (.kind!="import-retry" or ($job.status!="queue_verified" and $job.status!="manual_hold")))' "$commands" >/dev/null;then
        record_normalized_issue "PACK:REVIEW:$id" Sonarr 'Pack native command requires review' ARR_PACK_AUTOMATION WARNING command-unverified 'Native command failed or remains uncertain; no blind retry' 0 "$detail";continue
      fi
      if [[ "$status" == queue_verified ]] && jq -e --arg id "$id" 'any(.jobs[$id].cleanup.files[]?;.status=="blocked")' "$PACK_STATE_FILE" >/dev/null;then
        record_normalized_issue "PACK:REVIEW:$id" Sonarr 'Pack cleanup deferred' ARR_PACK_AUTOMATION WARNING cleanup-proof 'A per-file cleanup check could not be satisfied; affected source files retained' 0 "$detail";continue
      fi
      case "$status" in
        blocked|review|manual_hold) record_normalized_issue "PACK:REVIEW:$id" Sonarr 'Pack automation requires review' ARR_PACK_AUTOMATION WARNING "$status" "$(jq -r .value.reason <<<"$job")" 0 "$detail";;
        *) if [[ "$sent" != "$signature" ]];then event=progress;[[ "$status" != resolved ]] || event=completed
          queue_group_notification "PACK:ACTION:$id" "$signature" Sonarr "$(jq -r '.value.title // "Completed pack"' <<<"$job")" ARR_PACK_AUTOMATION INFO 0 "$detail" "$event";fi;;
      esac
    done < <(jq -c '.jobs|to_entries[]' "$PACK_STATE_FILE")
}
process_media_packs() {
    PACK_STATE_FILE="$STATE_DIR/pack-actions.json"
    [[ ! -L "$PACK_STATE_FILE" ]] || return 1
    [[ -f "$PACK_STATE_FILE" ]] || { printf '{"schema":1,"jobs":{}}' >"$TMP_DIR/pack-initial";pack_publish "$TMP_DIR/pack-initial"; } || return 1
    pack_document_valid "$PACK_STATE_FILE" || return 1
    pack_update '.jobs|=with_entries(select(.value.status!="resolved" or .value.createdAt>=$since))' --argjson since "$((START_TIME-90*86400))" || return 1
    [[ "$SONARR_QUEUE_OK" == true && "$RADARR_QUEUE_OK" == true && "$SAB_HISTORY_OK" == true && "$SAB_QUEUE_OK" == true ]] || { preserve_pack_issues;return 0; }
    local id plan="$TMP_DIR/pack-plan.json" fp previous at runs status n=0
    # Reconcile without replay before considering any new pack action.
    while read -r id;do runtime_budget_allows_optional_phase pack-queue-followup || break;pack_verify_queue_removal "$id" || true;done < <(jq -r '.jobs|to_entries[]|select(.value.status=="queue_intent")|.key' "$PACK_STATE_FILE")
    while read -r id;do runtime_budget_allows_optional_phase pack-file-followup || break;pack_followup "$id" || true;pack_update '.jobs[$id].lastFollowupAt=$at' --arg id "$id" --argjson at "$START_TIME" || return 1;done < <(jq -r '.jobs|to_entries|sort_by(.value.lastFollowupAt // 0)|map(select(.value.status=="queue_verified"))|.[:2][].key' "$PACK_STATE_FILE")
    pack_reconcile_receipts || return 1
    if [[ "$ARR_AUTOMATION_ENABLED" == true && "$POLICY_AUTOMATION_ENABLED" == true && "$AUTOMATION_CONTROLS_OK" == true ]] && automation_window_open && automation_api_ready;then
      while read -r id;do pack_submit_searches "$id" || true;done < <(jq -r '.jobs|to_entries[]|select(.value.status=="queue_verified")|.key' "$PACK_STATE_FILE")
      while read -r id;do
        ((n<2)) || break;runtime_budget_allows_optional_phase pack-discovery || break
        status=$(jq -r --arg id "$id" '.jobs[$id].status // "new"' "$PACK_STATE_FILE")
        [[ "$status" != queue_intent && "$status" != queue_verified && "$status" != resolved && "$status" != review && "$status" != manual_hold ]] || continue
        n=$((n+1))
        if ! pack_snapshot "$id" "$plan";then
          pack_update '.jobs[$id]=((.jobs[$id] // {app:"Sonarr",downloadId:$id,createdAt:$at})+{checkedAt:$at,status:"blocked",reason:"Complete source inventory, native mapping, current policy or exact identity could not be proven; payload preserved"})' --arg id "$id" --argjson at "$START_TIME" || return 1
          continue
        fi
        fp=$(jq -Sc . "$plan"|sha256sum|cut -d ' ' -f1);previous=$(jq -r --arg id "$id" '.jobs[$id].observation.fingerprint // ""' "$PACK_STATE_FILE");at=$(jq -r --arg id "$id" '.jobs[$id].observation.at // 0' "$PACK_STATE_FILE");runs=$(jq -r --arg id "$id" '.jobs[$id].observation.runs // 0' "$PACK_STATE_FILE")
        if [[ "$previous" == "$fp" ]] && ((START_TIME-at>=240 && START_TIME-at<=1200));then runs=$((runs+1));else runs=1;fi
        pack_update '.jobs[$id]=((.jobs[$id] // {app:"Sonarr",downloadId:$id,createdAt:$at})+{checkedAt:$at,title:$plan[0].title,status:(if $plan[0].unknown then "blocked" else "observing" end),reason:(if $plan[0].unknown then "Unaccounted, mixed or unsupported pack files remain protected" else "Complete pack mapping retained; waiting for stable proof or bounded native action" end),plan:$plan[0],observation:{fingerprint:$fp,at:$at,runs:$runs}})' --arg id "$id" --argjson at "$START_TIME" --arg fp "$fp" --argjson runs "$runs" --slurpfile plan "$plan" || return 1
        ((runs>=2)) || continue
        if jq -e '.accounted and (.unknown|not)' "$plan" >/dev/null;then pack_dispatch "$id" "$plan" || true
        elif jq -e '.unknown|not' "$plan" >/dev/null;then pack_submit_import "$id" "$plan" || true;fi
      done < <(jq -r --slurpfile jobs "$PACK_STATE_FILE" '[[.records[]|select(.protocol=="usenet" and .status=="completed" and (.downloadId // "")!="")]|group_by(.downloadId|ascii_downcase)|.[]|select(length>1 or any(.[];.title|test("complete|season[ ._-]*[0-9]|[Ss][0-9]{1,3}([ ._-]|$)|[Ss][0-9]{1,3}[Ee][0-9]{1,3}[Ee-][0-9]";"i")))|.[0].downloadId|ascii_downcase] | sort_by($jobs[0].jobs[.].checkedAt // 0)|.[]' "$SONARR_QUEUE")
    fi
    pack_report
}
preserve_pack_issues() {
    [[ -f "${STATE_FILE:-}" ]] || return 0
    local key
    while IFS= read -r key;do mark_seen "$key";done < <(jq -r '.issues|to_entries[]|select(.value.active==true and (.key|startswith("PACK:")))|.key' "$STATE_FILE")
}
