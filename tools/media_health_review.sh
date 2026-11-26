# shellcheck shell=bash
# Historical review is read-only reconciliation/reporting. It grants no import,
# cleanup, search or library-file mutation authority.
review_collectors_healthy() {
    [[ "$SONARR_QUEUE_OK" == true && "$RADARR_QUEUE_OK" == true && "$SAB_QUEUE_OK" == true && "$SAB_HISTORY_OK" == true && "$SONARR_AUDIT_OK" == true && "$RADARR_AUDIT_OK" == true ]] || return 1
    [[ "${SONARR_HEALTH_OK:-false}" == true && "${RADARR_HEALTH_OK:-false}" == true && "${SAB_API_OK:-false}" == true ]] || return 1
    jq -es 'all(.[];type=="array" and all(.[];(.type // ""|ascii_downcase)!="error" and (.type // ""|ascii_downcase)!="warning"))' "$SONARR_HEALTH" "$RADARR_HEALTH" >/dev/null
}
review_attempt_absent() {
    local id="$1" record="$2" q
    for q in "$SONARR_QUEUE" "$RADARR_QUEUE";do
      jq -e --arg id "$id" --slurpfile r "$record" '
        all(.records[];(.downloadId // ""|ascii_downcase)!=$id and
          ((.title // ""|ascii_downcase)!=($r[0].release // $r[0].title // ""|ascii_downcase)))' "$q" >/dev/null || return 1
    done
    jq -e --arg id "$id" --slurpfile r "$record" 'all(.queue.slots[]?;(.nzo_id|ascii_downcase)!=$id and ((.filename // .name // ""|ascii_downcase)!=($r[0].release // $r[0].title // ""|ascii_downcase)))' "$SAB_QUEUE" >/dev/null || return 1
    jq -e --arg id "$id" 'all(.history.slots[]?;(.nzo_id|ascii_downcase)!=$id)' "$SAB_HISTORY" >/dev/null
}
review_current_targets_satisfied() {
    local id="$1" app="$2" record="$3" root key owner_kind kind target parent row file_id profile_id signature count=0
    local rows="$TMP_DIR/review-targets.jsonl" input="$TMP_DIR/review-target-record.json" object="$TMP_DIR/review-object.json" owner="$TMP_DIR/review-owner.json" file="$TMP_DIR/review-file.json" profiles="$TMP_DIR/review-profiles.json" formats="$TMP_DIR/review-formats.json" evidence="$TMP_DIR/review-target-evidence.jsonl" output="$TMP_DIR/review-target-result.jsonl" fingerprint
    REVIEW_TARGET_REASON='Current targets were not evaluated'
    [[ "${TARGET_SATISFACTION_RECONCILE_ENABLED:-true}" == true ]] || return 1
    jq -e --arg key "FLOW:DOWNLOAD:$id" '.issues[$key].active==true and .issues[$key].classification=="DOWNLOAD_FLOW_REVIEW_REQUIRED"' "$STATE_FILE" >/dev/null || return 1
    REVIEW_TARGET_REASON='Complete healthy Arr/SAB collector coverage is required'
    review_collectors_healthy || return 1
    printf '%s' "$record" >"$input"
    REVIEW_TARGET_REASON='Exact attempt or matching release still has an active/reference record'
    review_attempt_absent "$id" "$input" || return 1
    REVIEW_TARGET_REASON='Exact native target identities are missing, mixed or exceed the bounded target limit'
    jq -e --arg app "$app" '(.targets|type)=="object" and (.targets|length)>0 and (.targets|length)<=40 and all(.targets[];if $app=="Sonarr" then .type=="episode" else .type=="movie" end)' "$input" >/dev/null || return 1
    IFS=$'\t' read -r root key < <(arr_reconciliation_connection "$app")
    api_get "$root/qualityprofile" "$key" "$profiles" && api_get "$root/customformat" "$key" "$formats" || return 1
    REVIEW_TARGET_REASON='Current profile/custom-format signature is unverified, changed or inside its safety hold'
    signature=$(pack_profile_signature "$profiles" "$formats") || return 1
    [[ -f "${AUTOMATION_STATE_FILE:-$STATE_DIR/automation-actions.json}" ]] || return 1
    jq -e --arg app "$app" --arg signature "$signature" --argjson now "$START_TIME" '.profiles[$app].signature==$signature and .profiles[$app].holdUntil<=$now and $now-.profiles[$app].checkedAt<=5400' "${AUTOMATION_STATE_FILE:-$STATE_DIR/automation-actions.json}" >/dev/null || return 1
    jq -c '.targets[]' "$input" >"$rows";: >"$evidence"
    while IFS= read -r row;do
      runtime_budget_allows_optional_phase target-satisfaction || return 1
      kind=movie;owner_kind=movie;target=$(jq -r '.movieId // 0' <<<"$row");parent="$target"
      if [[ "$app" == Sonarr ]];then kind=episode;owner_kind=series;target=$(jq -r '.episodeId // 0' <<<"$row");parent=$(jq -r '.seriesId // 0' <<<"$row");fi
      [[ "$target" =~ ^[1-9][0-9]*$ && "$parent" =~ ^[1-9][0-9]*$ ]] || return 1
      REVIEW_TARGET_REASON="Integrity recovery may protect $app parent ID=$parent"
      media_recovery_app_held "$app" "$parent" && return 1
      REVIEW_TARGET_REASON="Current native target/parent API identity, file or monitoring proof is incomplete (target ID=$target)"
      api_get "$root/$kind/$target" "$key" "$object" && api_get "$root/$owner_kind/$parent" "$key" "$owner" || return 1
      jq -e --arg app "$app" --argjson target "$target" --argjson parent "$parent" --argjson stored "$row" '.id==$target and .hasFile==true and .monitored==true and
        (if $app=="Sonarr" then .seriesId==$parent and .episodeFileId>0 and .episodeNumber>0 and .seasonNumber>=0 and
         (($stored.seasonNumber==null) or .seasonNumber==$stored.seasonNumber) and (($stored.episodeNumber==null) or .episodeNumber==$stored.episodeNumber)
         else .movieFileId>0 end)' "$object" >/dev/null || return 1
      jq -e --arg app "$app" --argjson parent "$parent" --slurpfile e "$object" '.id==$parent and .monitored==true and (.tags|length)==0 and
        (if $app=="Sonarr" then .tvdbId>0 and any(.seasons[]?;.seasonNumber==$e[0].seasonNumber and .monitored==true) else .tmdbId>0 end)' "$owner" >/dev/null || return 1
      # Other attempts for the exact parent may still be upgrading these files.
      local queue="$RADARR_QUEUE";[[ "$app" != Sonarr ]] || queue="$SONARR_QUEUE"
      REVIEW_TARGET_REASON="Another queued attempt exists for native parent ID=$parent"
      jq -e --arg app "$app" --argjson parent "$parent" 'all(.records[];(if $app=="Sonarr" then .seriesId else .movieId end)!=$parent)' "$queue" >/dev/null || return 1
      file_id=$(jq -r '.episodeFileId // .movieFileId // 0' "$object");profile_id=$(jq -r .qualityProfileId "$owner")
      api_get "$root/${kind}file/$file_id" "$key" "$file" || return 1
      REVIEW_TARGET_REASON="Current file identity/profile goals did not qualify: file ID=$file_id; $(jq -r '"custom-format score="+(.customFormatScore|tostring)+"; native quality-cutoff unmet="+(.qualityCutoffNotMet|tostring)' "$file")"
      jq -e --arg app "$app" --argjson id "$file_id" --argjson parent "$parent" --argjson profile "$profile_id" --slurpfile p "$profiles" --slurpfile e "$object" '
        ($p[0]|map(select(.id==$profile))|select(length==1)|.[0]) as $p|
        .id==$id and (if $app=="Sonarr" then .seriesId==$parent and .seasonNumber==$e[0].seasonNumber else .movieId==$parent end) and
        .size>0 and (.path|type)=="string" and (.path|startswith("/")) and (.customFormatScore|type)=="number" and
        (.quality.quality.id|type)=="number" and .quality.quality.id>0 and .customFormatScore>=$p.minFormatScore and
        ($p.upgradeAllowed|type)=="boolean" and
        (if $p.upgradeAllowed then .qualityCutoffNotMet==false and ($p.cutoffFormatScore|type)=="number" and .customFormatScore>=$p.cutoffFormatScore else true end) and
        (.quality.quality.id as $q|[$p.items[]|select(.allowed==true)|.quality.id,.items[]?.quality.id]|index($q))!=null' "$file" >/dev/null || return 1
      jq -nc --arg app "$app" --argjson target "$target" --argjson parent "$parent" --arg signature "$signature" --slurpfile f "$file" --slurpfile e "$object" '{app:$app,targetId:$target,parentId:$parent,season:$e[0].seasonNumber,episode:$e[0].episodeNumber,profileSignature:$signature,file:($f[0]|{id,path,size,dateAdded,quality,customFormatScore,qualityCutoffNotMet})}' >>"$evidence" || return 1
      count=$((count+1))
    done <"$rows"
    ((count==$(jq '.targets|length' "$input"))) || return 1
    REVIEW_TARGET_REASON='All exact targets satisfy current native policy; two separate positive scans are required to close this workflow'
    fingerprint=$(jq -scS 'sort_by(.targetId)' "$evidence"|sha256sum|cut -d ' ' -f1)
    # Replace only this attempt's negative fallback result. No native receipt or
    # importedAt timestamp is invented; two separate positive scans still apply.
    jq -c --arg id "$id" 'select(.id!=$id)' "$DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE" >"$output" && mv "$output" "$DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE" || return 1
    write_download_reconciliation_result "$id" "$app" true true target-satisfied DOWNLOAD_FLOW_RECONCILED_TARGET_SATISFIED INFO "$fingerprint" \
      'Every exact target currently has an acceptable native Arr file record; original download outcome remains unknown' \
      "Verified $count exact target(s), current native file IDs, quality/custom-format policy and monitoring. API database evidence only; no physical library access. Closed the actionable requirement, not the original download as imported. No Arr/SAB/media changes."
}

review_archive_events() {
    local row id signature detail
    while IFS= read -r row;do
      id=$(jq -r .id <<<"$row");signature=$(jq -r '(.archivedAt|tostring)' <<<"$row")
      detail=$(jq -r '"Download ID: "+.id+"\nAction: archived historical attempt with UNKNOWN outcome; no import or cancellation was inferred.\nReason: "+.reason+"\nOriginal classification: "+.issue.classification+"\nOriginal warning: "+.issue.message+"\nOriginal Ack ID: "+(.issue.ackId // "not captured")+"\nArr/SAB/media changes: none. Evidence retained in state.json; weekly review includes the archival."' <<<"$row")
      queue_group_notification "REVIEW:ARCHIVE:$id" "$signature" "$(jq -r .app <<<"$row")" "$(jq -r .title <<<"$row")" DOWNLOAD_FLOW_ARCHIVED_UNKNOWN INFO 0 "$detail" archived
    done < <(jq -c '(.monitor.historicalReviewArchive // {})[]|select((.notifiedAt // 0)<.archivedAt and (.reopenedAt // 0)==0)' "$STATE_FILE")
}
process_historical_review_archive() {
    local next="$TMP_DIR/review-state.next" candidates="$TMP_DIR/review-archive-candidates.jsonl" record="$TMP_DIR/review-archive-record.json" row id age count at fp old runs checked
    jq --argjson now "$START_TIME" '.monitor.weeklyReview.enrolledAt //= $now |
      .monitor.historicalReviewArchive //= {} |
      .monitor.historicalReviewArchive|=with_entries(select(.value.archivedAt>=$now-180*86400 or (.value.notifiedAt // 0)==0)) |
      .monitor.reviewAbsence //= {} | .monitor.reviewAbsence|=with_entries(select(.value.at>=$now-5400))' "$STATE_FILE" >"$next" && save_state "$next" || return 1
    # Positive reappearance reopens the attempt even if another collector failed.
    local ids="$TMP_DIR/review-reappeared.jsonl" q;: >"$ids"
    for q in "$SONARR_QUEUE" "$RADARR_QUEUE";do [[ ! -s "$q" ]] || jq -c '.records[]?|{id:(.downloadId // ""|ascii_downcase)}|select(.id!="")' "$q" >>"$ids" || return 1;done
    [[ ! -s "$SAB_QUEUE" ]] || jq -c '.queue.slots[]?|{id:(.nzo_id|ascii_downcase)}' "$SAB_QUEUE" >>"$ids" || return 1
    jq --slurpfile ids "$ids" --argjson now "$START_TIME" 'reduce $ids[] as $r (.;if (.monitor.historicalReviewArchive[$r.id].archivedAt // 0)>0 and (.monitor.historicalReviewArchive[$r.id].reopenedAt // 0)==0 then
      (if .downloadLedger[$r.id]!=null then .downloadLedger[$r.id].historicalArchivedAt=0 else . end)|.monitor.historicalReviewArchive[$r.id].reopenedAt=$now|del(.monitor.reviewAbsence[$r.id]) else . end)' "$STATE_FILE" >"$next" && save_state "$next" || return 1
    if ! review_collectors_healthy;then
      jq 'del(.monitor.reviewAbsence)' "$STATE_FILE" >"$next" && save_state "$next" || return 1
      review_archive_events;return $?
    fi
    # Known targets with unmet/ambiguous requirements stay active. They are never
    # archived just because a timer elapsed; native target reconciliation owns them.
    jq -c --argjson now "$START_TIME" --argjson days "$HISTORICAL_REVIEW_ARCHIVE_DAYS" --argjson retry "$DOWNLOAD_LEDGER_RECONCILE_RETRY_MINUTES" '. as $s|.issues|to_entries[]|
      select(.value.active and .value.classification=="DOWNLOAD_FLOW_REVIEW_REQUIRED")|(.key|ltrimstr("FLOW:DOWNLOAD:")) as $id|$s.downloadLedger[$id]|
      select(.flowEnrolled==true and (.targets|type)=="object" and (.targets|length)==0 and .reconciliationLastScanOk==true and
        $now-(.reconciliationLastCheckedAt // 0)<=($retry+10)*60 and (.reconciliationCandidateRuns // 0)==0 and
        ([.arrImportedAt,.arrFailedAt,.arrIgnoredAt,.arrReconciledAt,.sabCompletedAt,.sabFailedAt,.manuallyDismissedAt,.historicalArchivedAt]|map(. // 0)|max)==0)|
      ([.arrGrabbedAt,.sabQueuedAt,.arrQueueLastSeen,.sabQueueLastSeen,.firstSeen]|map(. // 0)|max) as $last|
      select($last>0 and $now-$last>=$days*86400)|{id:$id,record:.,lastWorkAt:$last}' "$STATE_FILE" >"$candidates" || return 1
    count=0
    while IFS= read -r row;do
      ((count<20)) || break;runtime_budget_allows_optional_phase historical-archive || break;count=$((count+1))
      id=$(jq -r .id <<<"$row");[[ "$id" =~ ^[a-z0-9-]+$ ]] || continue
      jq .record <<<"$row" >"$record"
      if ! review_attempt_absent "$id" "$record";then
        jq --arg id "$id" 'del(.monitor.reviewAbsence[$id])' "$STATE_FILE" >"$next" && save_state "$next" || return 1;continue
      fi
      fp=$(jq -Sc '{id,lastWorkAt}' <<<"$row"|sha256sum|cut -d ' ' -f1)
      old=$(jq -r --arg id "$id" '.monitor.reviewAbsence[$id].fingerprint // ""' "$STATE_FILE")
      at=$(jq -r --arg id "$id" '.monitor.reviewAbsence[$id].at // 0' "$STATE_FILE")
      runs=$(jq -r --arg id "$id" '.monitor.reviewAbsence[$id].runs // 0' "$STATE_FILE")
      if [[ "$old" == "$fp" ]] && ((START_TIME-at>=240 && START_TIME-at<=5400));then runs=$((runs+1));elif [[ "$old" != "$fp" ]] || ((START_TIME-at>5400));then runs=1;else continue;fi
      jq --arg id "$id" --arg fp "$fp" --argjson now "$START_TIME" --argjson runs "$runs" '.monitor.reviewAbsence[$id]={fingerprint:$fp,at:$now,runs:$runs}' "$STATE_FILE" >"$next" && save_state "$next" || return 1
      ((runs>=2)) || continue
      checked=$(jq '.monitor.historicalReviewArchive|length' "$STATE_FILE");((checked<1000)) || { log 'WARNING: Historical archive capacity reached; remaining review issues retained';break; }
      jq --arg id "$id" --argjson now "$START_TIME" --argjson days "$HISTORICAL_REVIEW_ARCHIVE_DAYS" '
        .downloadLedger[$id] as $r|.issues["FLOW:DOWNLOAD:"+$id] as $issue|
        .monitor.historicalReviewArchive[$id]={id:$id,app:$r.app,title:($r.title // $r.release),archivedAt:$now,notifiedAt:0,outcome:"UNKNOWN",reason:("At least "+($days|tostring)+" days without observed work; repeated healthy queue/history checks found no active attempt. Exact target identity is unavailable. Administrative archival only."),ledger:$r,issue:$issue}|
        .downloadLedger[$id].historicalArchivedAt=$now|
        .issues["FLOW:DOWNLOAD:"+$id].active=false|.issues["FLOW:DOWNLOAD:"+$id].resolvedAt=$now|
        .issues["FLOW:DOWNLOAD:"+$id].resolutionKind="archived_unknown"|.issues["FLOW:DOWNLOAD:"+$id].resolutionReason="Historical attempt archived with unknown outcome; not confirmed imported or cancelled"|
        del(.monitor.reviewAbsence[$id])' "$STATE_FILE" >"$next" && save_state "$next" || return 1
    done <"$candidates"
    review_archive_events
}

review_weekly_due_period() {
    local now="$1" day midnight due
    day=$(TZ=Asia/Singapore date -d "@$now" +%u);midnight=$(TZ=Asia/Singapore date -d "$(TZ=Asia/Singapore date -d "@$now" +%F) 00:00:00" +%s)
    due=$((midnight-(day%7)*86400+19*3600));((due<=now)) || due=$((due-7*86400))
    printf '%s\t%s\n' "$(TZ=Asia/Singapore date -d "@$due" +%F)" "$due"
}
review_report_build() {
    local json="$1" text="$2" empty="$TMP_DIR/review-empty-automation.json" automation="${AUTOMATION_STATE_FILE:-$STATE_DIR/automation-actions.json}"
    printf '{"actions":{}}' >"$empty";[[ -r "$automation" && ! -L "$automation" ]] || automation="$empty"
    jq --argjson now "$START_TIME" --argjson archiveDays "$HISTORICAL_REVIEW_ARCHIVE_DAYS" --argjson keepReports "$WEEKLY_MEDIA_REVIEW_KEEP_REPORTS" --slurpfile automation "$automation" '
      def groupissues:sort_by([.app,.title,.classification])|group_by([.app,.title,.classification])|map({app:.[0].app,title:.[0].title,classification:.[0].classification,severity:(if any(.[];.severity=="ERROR") then "ERROR" elif any(.[];.severity=="WARNING") then "WARNING" else "INFO" end),attempts:.});
      . as $s|[.issues|to_entries[]|select(.value.active==true)|. as $entry|.value+
        {key:$entry.key,ageHours:((($now-(.value.firstSeen // $now))/3600)|floor),acknowledged:((.value.acknowledgedSignature // "")!="" and .value.acknowledgedSignature==.value.signature),
         lastAutomaticCheck:($s.downloadLedger[($entry.key|ltrimstr("FLOW:DOWNLOAD:"))].targetSatisfactionLastReason // $s.downloadLedger[($entry.key|ltrimstr("FLOW:DOWNLOAD:"))].reconciliationLastReason // "See native issue reason; no additional recovery action is inferred"),
         nextAction:(if .value.classification=="DOWNLOAD_FLOW_REVIEW_REQUIRED" then "Exact identities/current file policy are rechecked automatically; identity-free historical attempts may qualify for "+($archiveDays|tostring)+"-day archival. No speculative redownload." elif .value.classification=="ARR_DOWNLOAD_FAILED_HISTORY" then "Recorded manual/native failure event. No retry is inferred from this history event." else "Review the recorded reason. Existing guarded automation continues; no profile, permission or identity override." end)}] as $issues|
      {schema:1,generatedAt:$now,keepReports:$keepReports,activeErrors:([$issues[]|select(.severity=="ERROR")]|length),activeWarnings:([$issues[]|select(.severity=="WARNING")]|length),
       groups:([$issues[]|select(.severity=="ERROR" or .severity=="WARNING")]|groupissues),
       information:([$issues[]|select(.severity=="INFO")]|groupissues),
       archivedUnknown:([(.monitor.historicalReviewArchive // {})[]|select((.reopenedAt // 0)==0)]|length),
       archivedThisWeek:[(.monitor.historicalReviewArchive // {})[]|select(.archivedAt>=$now-7*86400 and (.reopenedAt // 0)==0)|{id,app,title,archivedAt,reason}],
       reconciledThisWeek:[.downloadLedger[]?|select((.arrReconciledAt // 0)>=$now-7*86400)|{id,app,title,kind:.reconciliationKind,evidence:.reconciliationEvidence}],
       automationThisWeek:[$automation[0].actions[]?|select(.startedAt>=$now-7*86400)|{app,kind,targetId,status,outcome,nativeMessage}],
       newInformationalEvents:([$issues[]|select(.severity=="INFO" and .firstSeen>=$now-7*86400)]|length)}' "$STATE_FILE" >"$json" || return 1
    TZ=Asia/Singapore jq -r '
      def groups($items):$items[]|"\n["+.severity+"] "+.app+" / "+.title+"\nClassification: "+.classification+"; recorded attempts: "+(.attempts|length|tostring)+
        "\n"+([.attempts[]|"- Ack ID: "+(.ackId // "unknown")+"; age="+(.ageHours|tostring)+"h; acknowledged="+(.acknowledged|tostring)+"; reminders sent="+(.reminderCount // 0|tostring)+"; last observed="+(.lastSeen|strflocaltime("%Y-%m-%d %H:%M:%S %Z"))+"\n  Issue: "+.key+"\n  Reason: "+.message+"\n  Last automatic check: "+.lastAutomaticCheck+"\n  Next action: "+.nextAction]|join("\n"));
      "MEDIA HEALTH WEEKLY REVIEW\nGenerated: "+(.generatedAt|strflocaltime("%Y-%m-%d %H:%M:%S %Z"))+
      "\nCurrent actionable backlog: errors="+(.activeErrors|tostring)+"; warnings="+(.activeWarnings|tostring)+
      "\nIncludes acknowledged issues and issues whose reminder allowance has expired.\nRepeated titles are grouped for presentation only; individual IDs remain independent.\n" ,
      "ACTIVE ERRORS / WARNINGS",groups(.groups),
      "\nINFORMATIONAL HISTORY (separate from the actionable backlog)",groups(.information),
      "\nAUTOMATIC RECONCILIATION THIS WEEK",(.reconciledThisWeek[]|"- "+.app+" / "+.title+"; download="+.id+"; outcome="+.kind+"; "+.evidence),
      "\nAUTOMATION COMMANDS THIS WEEK",(.automationThisWeek[]|"- "+.app+" / "+.kind+"; target="+(.targetId|tostring)+"; command="+.status+"; outcome="+(.outcome // "unverified")+"; "+(.nativeMessage // "")),
      "\nARCHIVED HISTORICAL ATTEMPTS: outcome UNKNOWN; no successful import/cancellation inferred",
      ("Retained archived unknown attempts: "+(.archivedUnknown|tostring)),
      (.archivedThisWeek[]|"- "+.app+" / "+.title+"; download="+.id+"; "+.reason),
      "\nReport actions: saved this review and queued its complete numbered parts for grouped notification. No Arr/SAB/media changes were performed by reporting.\nOnly the latest "+(.keepReports|tostring)+" weekly report files are retained. Historical evidence has its separate bounded state retention."' "$json" >"$text"
}
review_queue_weekly_parts() {
    local file="$1" period="$2" signature="$3" index=0 chunk total detail size="${GROUP_NOTIFICATION_ITEM_MAX_CHARS:-4000}"
    [[ "$size" =~ ^[1-9][0-9]*$ ]] || return 1
    ((size<=2000)) || size=2000
    local chunks="$TMP_DIR/weekly-review-parts.jsonl"
    jq -Rnc --argjson size "$size" --rawfile body "$file" '[range(0;($body|length);$size) as $i|$body[$i:$i+$size]]|to_entries[]|{index:.key,text:.value}' >"$chunks" || return 1
    total=$(wc -l <"$chunks"|tr -d ' ');REVIEW_WEEKLY_PARTS_QUEUED=0;REVIEW_WEEKLY_PARTS_MISSING=0
    while IFS= read -r chunk;do
      index=$(jq -r .index <<<"$chunk") || return 1
      [[ "$index" =~ ^[0-9]+$ ]] || return 1
      if jq -e --arg key "REVIEW:WEEKLY:$period:$index" --arg sig "$signature" '.monitor.weeklyReview.acceptedParts[$key]==$sig' "$STATE_FILE" >/dev/null;then continue;fi
      REVIEW_WEEKLY_PARTS_MISSING=$((REVIEW_WEEKLY_PARTS_MISSING+1))
      runtime_budget_allows_optional_phase weekly-review-delivery || break
      # A sentinel preserves trailing newlines at part boundaries through Bash
      # command substitution; all report characters reach the durable outbox.
      detail=$(jq -r '.text+"\u0001"' <<<"$chunk") || return 1;detail=${detail%$'\001'}
      queue_group_notification "REVIEW:WEEKLY:$period:$index" "$signature" Monitor "Weekly media health review $period ($((index+1))/$total)" MEDIA_HEALTH_WEEKLY_REVIEW INFO 0 "$detail" weekly || return 1
      REVIEW_WEEKLY_PARTS_QUEUED=$((REVIEW_WEEKLY_PARTS_QUEUED+1))
    done <"$chunks"
}
review_prune_weekly_reports() {
    local dir="$1" count=0 p reports=()
    mapfile -t reports < <(find "$dir" -maxdepth 1 -type f -name 'media-health-review-????-??-??.txt' -printf '%f\n'|sort -r)
    for p in "${reports[@]}";do count=$((count+1));((count<=WEEKLY_MEDIA_REVIEW_KEEP_REPORTS)) || rm -f -- "$dir/$p" || return 1;done
}
process_weekly_media_review() {
    [[ "${WEEKLY_MEDIA_REVIEW_ENABLED:-true}" == true ]] || return 0
    local period due enrolled prepared file signature current delivered next="$TMP_DIR/weekly-review-state.next" dir="$STATE_DIR/weekly-reports" json="$TMP_DIR/weekly-review.json" text="$TMP_DIR/weekly-review.txt" pending
    pending=$(jq '[.monitor.notification.outbox[]?|select(.issueKey|startswith("REVIEW:WEEKLY:"))]|length' "$STATE_FILE")
    ((pending==0)) || return 0
    current=$(jq -r '.monitor.weeklyReview.current.period // ""' "$STATE_FILE");delivered=$(jq -r '.monitor.weeklyReview.lastDeliveredPeriod // ""' "$STATE_FILE")
    if [[ -n "$current" && "$current" != "$delivered" ]];then
      file=$(jq -r .monitor.weeklyReview.current.path "$STATE_FILE");signature=$(jq -r .monitor.weeklyReview.current.sha256 "$STATE_FILE")
      [[ "$file" == "$dir/media-health-review-$current.txt" && -f "$file" && ! -L "$file" && ! -L "$dir" && $(sha256sum "$file"|cut -d ' ' -f1) == "$signature" ]] || return 1
      review_queue_weekly_parts "$file" "$current" "$signature" || return 1
      ((REVIEW_WEEKLY_PARTS_MISSING==0)) || return 0
      jq --arg period "$current" --argjson now "$START_TIME" '.monitor.weeklyReview.lastDeliveredPeriod=$period|.monitor.weeklyReview.current.deliveredAt=$now' "$STATE_FILE" >"$next" && save_state "$next" || return 1
    fi
    IFS=$'\t' read -r period due < <(review_weekly_due_period "$START_TIME")
    enrolled=$(jq -r '.monitor.weeklyReview.enrolledAt // 0' "$STATE_FILE");((enrolled>0 && due>=enrolled)) || return 0
    prepared=$(jq -r '.monitor.weeklyReview.lastPreparedPeriod // ""' "$STATE_FILE");[[ "$prepared" != "$period" ]] || return 0
    [[ ! -L "$dir" ]] || return 1
    if [[ -d "$dir" && ! -f "$dir/.owner" ]] && [[ -n $(find "$dir" -mindepth 1 -maxdepth 1 -print -quit) ]];then return 1;fi
    mkdir -p "$dir" || return 1
    [[ ! -L "$dir/.owner" ]] || return 1
    [[ -e "$dir/.owner" ]] || printf 'media-health-weekly-review-v1\n' >"$dir/.owner"
    [[ $(cat "$dir/.owner") == media-health-weekly-review-v1 ]] || return 1
    file="$dir/media-health-review-$period.txt";[[ ! -L "$file" ]] || return 1
    if [[ ! -f "$file" ]];then
      review_report_build "$json" "$text" || return 1
      if jq -e '.activeErrors==0 and .activeWarnings==0 and (.archivedThisWeek|length)==0 and (.reconciledThisWeek|length)==0 and (.automationThisWeek|length)==0 and .newInformationalEvents==0' "$json" >/dev/null;then
        jq --arg period "$period" '.monitor.weeklyReview.lastPreparedPeriod=$period|.monitor.weeklyReview.skippedEmpty=true' "$STATE_FILE" >"$next" && save_state "$next";return $?
      fi
      [[ ! -L "$dir/.weekly-report.tmp" ]] || return 1
      cp "$text" "$dir/.weekly-report.tmp" && sync -f "$dir/.weekly-report.tmp" && mv "$dir/.weekly-report.tmp" "$file" || return 1
    fi
    signature=$(sha256sum "$file"|cut -d ' ' -f1)
    # Persist the report identity BEFORE enqueueing parts. Interruption resumes
    # the same immutable snapshot and skips already accepted parts on every run.
    jq --arg period "$period" --arg file "$file" --arg hash "$signature" --argjson now "$START_TIME" '
      .monitor.weeklyReview.lastPreparedPeriod=$period|.monitor.weeklyReview.current={period:$period,path:$file,sha256:$hash,generatedAt:$now}|
      .monitor.weeklyReview.retainedPeriods=(([$period]+(.monitor.weeklyReview.retainedPeriods // []))|unique|sort|reverse|.[:2])|
      .monitor.weeklyReview.retainedPeriods as $keep|
      .monitor.weeklyReview.acceptedParts=((.monitor.weeklyReview.acceptedParts // {})|with_entries(select(.key as $k|any($keep[];. as $period|$k|startswith("REVIEW:WEEKLY:"+$period+":")))))|
      .monitor.weeklyReview.skippedEmpty=false' "$STATE_FILE" >"$next" && save_state "$next" || return 1
    review_prune_weekly_reports "$dir" || return 1
    review_queue_weekly_parts "$file" "$period" "$signature" || return 1
    log "Weekly media-health review queued; retained latest $WEEKLY_MEDIA_REVIEW_KEEP_REPORTS report files"
}
