# shellcheck shell=bash
# Warm-run evidence: observation time is distinct from the run's start timestamp.
hm_observed_epoch() { date +%s; }
hm_scrub_start_epoch() {
    local text epoch
    text=$(sed -nE 's/^[[:space:]]*Scrub started:[[:space:]]*//p; s/.*scrub started at[[:space:]]*//p' <<< "$1" | head -n1)
    epoch=0;[[ -z "$text" ]] || epoch=$(date -d "$text" +%s 2>/dev/null) || epoch=0
    [[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0
    printf '%s' "$epoch"
}
hm_scrub_clean() {
    local status="$1" start="$2" observed="$3"
    ((start>0 && start<=observed)) &&
      grep -qiE 'Status:[[:space:]]*finished|scrub finished' <<< "$status" &&
      grep -qi 'no errors found' <<< "$status" &&
      ! grep -qiE '(Corrected|Uncorrectable):[[:space:]]*[1-9]|(corrected|unrecoverable) errors:[[:space:]]*[1-9]' <<< "$status"
}
# Consume matching native proof only; this function never starts maintenance.
hm_reconcile_docker_scrub() {
    local mount="$1" status="$2" fresh="$3" observed start uuid old result requested
    [[ "$mount" == /var/lib/docker && "$fresh" == 1 && -s "$DOCKER_SCRUB_TRACKING_FILE" ]] || return 0
    observed=$(hm_observed_epoch);start=$(hm_scrub_start_epoch "$status")
    hm_scrub_clean "$status" "$start" "$observed" || return 0
    uuid=$(timeout --kill-after=1 5 findmnt -rn -M "$mount" -o UUID 2>/dev/null) || return 1
    old=$(jq -ce --arg uuid "$uuid" 'select(.schema==1 and .uuid==$uuid and (.pending|type)=="boolean")' "$DOCKER_SCRUB_TRACKING_FILE") || return 1
    [[ $(jq -r .pending <<< "$old") == true ]] || return 0
    requested=$(jq -er '.requestedEpoch|select(type=="number" and .>0 and .==floor)' <<< "$old") || return 1
    ((requested<=observed && start>=requested-5)) || return 0
    result=$(jq --argjson at "$observed" --argjson start "$start" '.pending=false|.requestedEpoch=0|.lastSuccessEpoch=$at|.lastSuccessfulStartEpoch=$start' <<< "$old") || return 1
    atomic_write_text "$DOCKER_SCRUB_TRACKING_FILE" "$result"$'\n' || return 1
    log BTRFS INFO 'Docker read-only scrub completion verified during this run; matching request closed without another scrub'
}
# Loop numbering is not persistent identity. Image recreation changes the UUID.
hm_btrfs_counter_key() {
    local mount="$1" dev="$2" show="$3" uuid devid
    if [[ "$dev" != /dev/loop* ]];then persistent_device_key "$dev";return;fi
    uuid=$(sed -nE 's/.*uuid:[[:space:]]*([A-Fa-f0-9-]{36}).*/\1/p' <<< "$show" | head -n1)
    devid=$(awk -v dev="$dev" '$1=="devid" && $NF==dev {print $2;exit}' <<< "$show")
    [[ "$uuid" =~ ^[A-Fa-f0-9-]{36}$ && "$devid" =~ ^[1-9][0-9]*$ ]] || return 1
    printf 'btrfs:%s:devid:%s' "${uuid,,}" "$devid"
}
declare -A SMART_TEST_DEFERRALS=()
SMART_TEST_STARTED_THIS_RUN=0
SMART_TEST_OVERDUE_COUNT=0
HOST_HEALTH_COVERAGE=null
HOST_HEALTH_COVERAGE_LINE=''
hm_test_deferred() {
    local kind="$1" reason="$2" disk="${3:-${SMART_TEST_CANDIDATE:-}}"
    [[ -z "$disk" ]] || SMART_TEST_DEFERRALS["$disk"]="$reason"
    log SMART INFO "${disk:+$disk: }New $kind self-test deferred: $reason; original calendar deadline retained"
}
hm_build_coverage_summary() {
    local disk id first last fresh=0 deferred=0 unknown=0 never=0 oldest=0 pending=0 key rows='' tests scrubs total observed
    observed=$(hm_observed_epoch);total=${#DISCOVERED_DISKS[@]}
    for disk in "${DISCOVERED_DISKS[@]}";do
        if [[ -n "${FRESH_SMART[$disk]:-}" ]];then fresh=$((fresh+1))
        elif [[ -n "${SMART_DEFERRED[$disk]:-}" ]];then deferred=$((deferred+1))
        else unknown=$((unknown+1));fi
        id=$(persistent_device_key "$disk")
        [[ "$(test_track_get "$id" pending)" != 1 ]] || pending=$((pending+1))
    done
    if [[ -s "$SMART_COVERAGE_FILE" ]];then
        while IFS=$'\t' read -r id first last;do
            [[ "$last" =~ ^[0-9]+$ ]] || continue
            if ((last==0));then never=$((never+1));elif ((oldest==0 || last<oldest));then oldest=$last;fi
        done < "$SMART_COVERAGE_FILE"
    fi
    for key in "${!SMART_TEST_DEFERRALS[@]}";do
        printf -v rows '%s%s\t%s\n' "$rows" "$key" "${SMART_TEST_DEFERRALS[$key]}"
    done
    tests=$(jq -Rn '[inputs|select(length>0)|split("\t")|{device:.[0],reason:.[1]}]' <<< "$rows") || return 1
    scrubs='[]'
    if [[ -s "$POOL_HEALTH_FILE" ]];then
        scrubs=$(jq -ce --argjson started "$RUN_EPOCH" '[.pools[]|select(.observedAt >= $started)|{mount,clean:.recordedClean,live:.liveStatus,start:.lastRecordedStart}]' "$POOL_HEALTH_FILE") || return 1
    fi
    HOST_HEALTH_COVERAGE=$(jq -nc --argjson at "$observed" --argjson total "$total" --argjson fresh "$fresh" --argjson deferred "$deferred" --argjson unknown "$unknown" --argjson never "$never" --argjson oldest "$oldest" --argjson started "$SMART_TEST_STARTED_THIS_RUN" --argjson pending "$pending" --argjson overdue "$SMART_TEST_OVERDUE_COUNT" --argjson deferrals "$tests" --argjson scrubs "$scrubs" '{observedAt:$at,inventory:$total,smart:{fresh:$fresh,deferred:$deferred,unverified:$unknown,neverSampled:$never,oldestFreshEpoch:$oldest},tests:{started:$started,pending:$pending,overdue:$overdue,deferrals:$deferrals},scrubs:$scrubs}') || return 1
    local age='none' clean count
    ((oldest==0)) || age="$(((observed-oldest)/86400))d"
    clean=$(jq '[.[]|select(.clean and .live)]|length' <<< "$scrubs");count=$(jq 'length' <<< "$scrubs")
    HOST_HEALTH_COVERAGE_LINE="Coverage: disks=$total; SMART fresh=$fresh, sleeping/deferred=$deferred, unverified=$unknown, never-sampled=$never, oldest sample=$age. Tests: started=$SMART_TEST_STARTED_THIS_RUN, pending=$pending, overdue=$SMART_TEST_OVERDUE_COUNT. Scrubs: clean live results=$clean/$count."
    log COVERAGE INFO "$HOST_HEALTH_COVERAGE_LINE"
}
