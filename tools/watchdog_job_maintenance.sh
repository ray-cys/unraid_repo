# shellcheck shell=bash
# Exact native Docker stop/start windows, retained in existing watchdog state.
# Only narrow Plex-connection failures qualify; no job is marked successful.
wd_plex_dependency_url() {
    local name="$1" info="$2" bound
    # A stopped Docker container clears runtime ports/IPs; retained static
    # bindings are inspection evidence, not a port scan or a config change.
    bound=$(jq '.[0] |= (if ((.NetworkSettings.Ports // {})|length)==0 then .NetworkSettings.Ports=(.HostConfig.PortBindings // {}) else . end |
      .NetworkSettings.Networks |= with_entries(if (.value.IPAddress // "")=="" then .value.IPAddress=(.value.IPAMConfig.IPv4Address // "") else . end))' <<<"$info") || return 1
    probe_url "$name" "$bound" 32400 /identity
}
wd_capture_downtime() {
    local name="$1" info="$2" lease="$3" profile="${PROFILE_BY_NAME[$1]:-$1}" stopped id created target key
    case "$profile" in plex-media|plex-media-server) ;; *) return 0;; esac
    [[ -n "$lease" && -f "$lease" && ! -L "$lease" ]] || return 0
    [[ $(stat -c %u "$lease") == "$EUID" ]] || return 0
    jq -e '.[0].State.Running==false' <<<"$info" >/dev/null || return 0
    stopped=$(date -d "$(jq -r '.[0].State.FinishedAt' <<<"$info")" +%s 2>/dev/null) || return 0
    created=$(stat -c %Y "$lease") || return 0
    ((stopped>0 && stopped<=NOW && stopped>=NOW-86400 && created<=stopped && created>=stopped-300)) || return 0
    id=$(jq -r '.[0].Id' <<<"$info")
    target=$(wd_plex_dependency_url "$name" "$info" 2>/dev/null) || target=''
    key=$(printf '%s' "$BOOT_ID|$name|$id|$stopped"|sha256sum|cut -d' ' -f1)
    mutate --arg key "$key" --arg name "$name" --arg id "$id" --arg boot "$BOOT_ID" --arg target "${target%/identity}" \
      --argjson stopped "$stopped" --argjson now "$NOW" --slurpfile lease "$lease" '
      .plannedDowntime //= {} | .plannedDowntime[$key] //= {id:$key,container:$name,containerId:$id,boot:$boot,startedAt:$stopped,endedAt:0,
        observedAt:$now,target:$target,source:"verified-maintenance-lease-and-native-docker",reason:$lease[0].reason,owner:$lease[0]}'
}
wd_close_downtime() {
    local name="$1" info="$2" started id profile="${PROFILE_BY_NAME[$1]:-$1}"
    case "$profile" in plex-media|plex-media-server) ;; *) return 0;; esac
    jq -e --arg name "$name" 'any((.plannedDowntime // {})[];.container==$name and .endedAt==0)' "$STATE_WORK" >/dev/null || return 0
    jq -e '.[0].State.Running==true' <<<"$info" >/dev/null || return 0
    started=$(date -d "$(jq -r '.[0].State.StartedAt' <<<"$info")" +%s 2>/dev/null) || return 0
    id=$(jq -r '.[0].Id' <<<"$info")
    mutate --arg name "$name" --arg id "$id" --arg boot "$BOOT_ID" --argjson started "$started" --argjson now "$NOW" '
      .plannedDowntime |= with_entries(if .value.container==$name and .value.containerId==$id and .value.boot==$boot and .value.endedAt==0
       and .value.startedAt<$started and $started<=$now then .value.endedAt=$started | .value.closedObservedAt=$now else . end)'
}
wd_prune_downtime() {
    mutate --argjson now "$NOW" '
      .plannedDowntime=((.plannedDowntime // {})|to_entries|map(select(.value.startedAt >= $now-14*86400))|sort_by(.value.startedAt)|.[-128:]|from_entries) |
      .jobIncidentHistory=((.jobIncidentHistory // [])|map(select(.archivedAt >= $now-14*86400))|.[-128:]) |
      .maintenanceOutcomes=((.maintenanceOutcomes // {})|to_entries|map(select(.value.finishedAt >= $now-14*86400))|sort_by(.value.finishedAt)|.[-128:]|from_entries)'
}
wd_plex_job_signature() {
    local profile="$1" file="$2"
    if [[ "$profile" == metafusion ]];then
        jq -e '.last_error=="Plex connector preflight failed"' "$file" >/dev/null
    elif [[ "$profile" == kometa ]];then
        jq -e '.backlog!=true and .incomplete!=true and (.reader.gap // false)!=true and ([.findings.fatal // {}, .findings.errors // {}] as $b |
          ([$b[].keys[]?]|length)>0 and all($b[]; ((.keys // [])|length)==((.examples // [])|length)) and
          all($b[].examples[]?; .=="Config Error: No libraries were found in config" or .=="Plex Error: Plex URL is probably invalid"))' "$file" >/dev/null
    else return 1;fi
}
wd_plex_job_evidence() {
    local name="$1" profile="$2" mode="$3" hint=''
    if [[ "$profile" == kometa ]];then
        hint=$(docker_cmd inspect "$name" | jq -r '.[0] | ((.Args // [])+(.Config.Cmd // [])) as $a |
          [range(0;($a|length)-1)|select($a[.]=="--config" or $a[.]=="-c")|$a[.+1]]|unique|
          if length==0 then "" elif length==1 then .[0] else "AMBIGUOUS" end') || return 1
        [[ "$hint" != AMBIGUOUS ]] || return 1
    fi
    # BEGIN EMBEDDED PLEX DEPENDENCY PROBE
    # END EMBEDDED PLEX DEPENDENCY PROBE
}
wd_match_job_maintenance() {
    local name="$1" profile="$2" started="$3" finished="$4" file="$5" candidates config checked target dep info endpoint identity body row active
    JOB_MAINTENANCE_DETAIL=''
    [[ "$profile" == kometa || "$profile" == metafusion ]] || return 1
    ((finished>0)) || return 1
    if ((started>finished));then
        started=$(jq -r --arg name "$name" '.jobs[$name].maintenanceOutcome.startedAt // .jobs[$name].runLog.completed.startedAt // 0' "$STATE_WORK") || return 1
    fi
    ((started>0 && started<=finished)) || return 1
    wd_plex_job_signature "$profile" "$file" || return 1
    candidates="$TMP_DIR/$name.maintenance-candidates.json"
    jq -c --arg boot "$BOOT_ID" --argjson started "$started" --argjson finished "$finished" '
      [(.plannedDowntime // {})[]|select((.endedAt>0 or .boot==$boot) and .startedAt<=$started and (.endedAt==0 or $finished<=.endedAt))]|sort_by(.startedAt)|reverse' "$STATE_WORK" >"$candidates" || return 1
    jq -e 'length>0' "$candidates" >/dev/null || return 1
    config="$TMP_DIR/$name.plex-config.json";checked="$TMP_DIR/$name.plex-auth.json"
    wd_plex_job_evidence "$name" "$profile" config >"$config" 2>/dev/null || return 1
    target=$(jq -er '.target|select(type=="string" and length>0)' "$config") || return 1
    while IFS= read -r row;do
        dep=$(jq -r .container <<<"$row")
        info=$(docker_cmd inspect "$dep" 2>/dev/null) && inspect_valid "$info" || continue
        if [[ $(jq -r '.[0].Id' <<<"$info") != "$(jq -r .containerId <<<"$row")" ]];then
            [[ $(jq -r .endedAt <<<"$row") != 0 && -n "$(jq -r '.machineIdentifier // ""' <<<"$row")" ]] || continue
        fi
        endpoint=$(wd_plex_dependency_url "$dep" "$info" 2>/dev/null) || continue
        identity=''
        if [[ $(jq -r .endedAt <<<"$row") == 0 ]];then
            # Open-window classification requires a currently stopped container
            # and the exact still-live verified maintenance lease owner.
            [[ "$target" == "${endpoint%/identity}" || "$target" == "$(jq -r .target <<<"$row")" ]] || continue
            jq -e '.[0].State.Running==false' <<<"$info" >/dev/null || continue
            maintenance_active "$dep";active=$?
            [[ "$active" == 0 && -n "${ACTIVE_MAINTENANCE_LEASE:-}" ]] || continue
        else
            wd_plex_job_evidence "$name" "$profile" check >"$checked" 2>/dev/null || continue
            jq -e '.schema==1 and .verified==true and (.machineIdentifier|type)=="string"' "$checked" >/dev/null || continue
            body="$TMP_DIR/$name.dependency-identity.xml"
            curl --silent --show-error --connect-timeout 4 --max-time 8 --max-filesize 65536 "$endpoint" >"$body" 2>/dev/null || continue
            identity=$(sed -n 's/.*machineIdentifier="\([A-Za-z0-9_-]*\)".*/\1/p' "$body")
            [[ -n "$identity" && "$identity" == "$(jq -r .machineIdentifier "$checked")" ]] || continue
            [[ -z "$(jq -r '.machineIdentifier // ""' <<<"$row")" || "$identity" == "$(jq -r .machineIdentifier <<<"$row")" ]] || continue
        fi
        mutate --arg name "$name" --arg key "$name:$finished" --argjson row "$row" --argjson started "$started" --argjson finished "$finished" --argjson now "$NOW" --arg identity "$identity" '
          (if $identity!="" then .plannedDowntime[$row.id].machineIdentifier=$identity else . end) |
          {status:"maintenance-blocked",dependency:$row.container,windowId:$row.id,startedAt:$started,finishedAt:$finished,
            stoppedAt:$row.startedAt,restartedAt:$row.endedAt,verifiedAt:$now,dependencyAccessVerified:($identity!=""),nativeResult:"failed",successNotClaimed:true} as $outcome |
          .jobs[$name].maintenanceOutcome=$outcome | .maintenanceOutcomes[$key]=$outcome |
          if $identity!="" and (.jobs[$name].runLog.maintenance.issues|type)=="object" then
            .jobs[$name].runLog.maintenance.issues |= with_entries(
              if (.value.message|IN("Config Error: No libraries were found in config","Plex Error: Plex URL is probably invalid"))
                and ((.value.affectedRuns // [])|index($started))!=null
              then .value.maintenanceProofs=(((.value.maintenanceProofs // [])+[$outcome])|unique_by(.startedAt)|sort_by(.startedAt)|.[-150:]) else . end)
          else . end |
          (.observations[$name+":job-failed"] // null) as $prior |
          if $prior!=null then .jobIncidentHistory=((.jobIncidentHistory // [])+[{key:($name+":job-failed"),observation:$prior,archivedAt:$now,reason:"Reclassified from exact Plex maintenance evidence; no successful run claimed"}])|del(.observations[$name+":job-failed"]) else . end' || return 1
        if [[ -n "$identity" ]];then
            JOB_MAINTENANCE_DETAIL="$dep was stopped $(TZ=Asia/Singapore date -d "@$(jq -r .startedAt <<<"$row")" '+%Y-%m-%d %H:%M:%S %Z') to $(TZ=Asia/Singapore date -d "@$(jq -r .endedAt <<<"$row")" '+%H:%M:%S %Z'); current authenticated Plex and configured-library checks passed"
        else JOB_MAINTENANCE_DETAIL="$dep is still stopped under its verified maintenance lease; backend recovery is not yet established";fi
        log INFO "$name: failed run $finished matched verified stopped interval for $dep; retained as maintenance-blocked, never successful; normal completion deadlines remain active"
        return 0
    done < <(jq -c '.[]' "$candidates")
    return 1
}
