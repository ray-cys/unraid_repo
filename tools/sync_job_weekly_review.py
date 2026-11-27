"""Embed the pure native-PHP job review reducer; no runtime helper dependency."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
p=root/'user_script/docker_service_watchdog.sh';s=p.read_text()
block='''# BEGIN WEEKLY JOB REVIEW REDUCER
update_weekly_job_reviews() {
    local spec name profile paused observations input output
    for spec in "${EFFECTIVE_SPECS[@]}";do
        name=${spec%%|*};profile="${PROFILE_BY_NAME[$name]:-$name}"
        case "$profile" in recyclarr|imagemaid) ;; *) continue;;esac
        paused=false;[[ -z "${FROZEN[$name]:-}" ]] || paused=true
        observations=$(jq -c --arg prefix "$name:job-" '.observations|with_entries(select((.key|startswith($prefix)) and .value.active))' "$STATE_WORK") || return 1
        input="$TMP_DIR/$name.weekly-input.json";output="$TMP_DIR/$name.weekly-review.json"
        jq -n --slurpfile state "$STATE_WORK" --arg name "$name" --arg profile "$profile" --argjson now "$NOW" --argjson paused "$paused" --argjson observations "$observations" \\
          '{job:($state[0].jobs[$name]//{}),profile:$profile,now:$now,paused:$paused,observations:$observations}' > "$input" || return 1
        if ! timeout --kill-after=2 12 php /dev/fd/3 3<<'JOB_REVIEW_PHP' < "$input" > "$output" 2>/dev/null
'''+(root/'tools/job_weekly_review.php').read_text()+'''\nJOB_REVIEW_PHP
        then
            observe "$name:weekly-review-evidence" WARNING 'Weekly job catalogue could not be updated; previous findings retained; availability monitoring continues' 1 || return 1
            mutate --arg name "$name" --argjson now "$NOW" '.jobs[$name].weeklyReviewError=$now' || return 1
            continue
        fi
        mutate --arg name "$name" --argjson now "$NOW" --slurpfile review "$output" '.jobs //= {} | .jobs[$name] //= {firstSeen:$now,started:0,finished:0,success:0,result:"unknown",scanned:0,logState:{},runLog:{},history:[]} | .jobs[$name].weeklyReview=($review[0]+{containerName:$name}) | .jobs[$name].weeklyReviewError=0' || return 1
    done
}
# END WEEKLY JOB REVIEW REDUCER
'''
a='# BEGIN WEEKLY JOB REVIEW REDUCER';b='# END WEEKLY JOB REVIEW REDUCER'
if a in s:s=s[:s.index(a)]+block+s[s.index(b)+len(b)+1:]
else:s=s.replace('\nnotify_changes() {','\n'+block+'\nnotify_changes() {',1)
p.write_text(s)
