# Shared new-action budget. Native outcomes remain in the producer's journal.
usr_ops_arr_reserve() (
    [[ "${USR_OPS_SHARED_BUDGET_ACTIVE:-false}" == true ]] || return 0
    local action="$1" app="$2" target="$3" root="${MEDIA_ACTION_BUDGET_ROOT:-/mnt/vault/cloud/logs/script/media_health_monitor}" now run fd export_fd temp file
    [[ "$app" == Sonarr || "$app" == Radarr ]] || return 1
    [[ "$target" =~ ^[1-9][0-9]*$ && -d "$root" && ! -L "$root" ]] || return 1
    [[ "$root" != /mnt/vault/* ]] || mountpoint -q /mnt/vault || return 75
    file="$root/action-budget.json";[[ ! -L "$file" ]] || return 1
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || return 1
    flock -s -n "$export_fd" || return 75
    exec {fd}>"${MEDIA_ACTION_BUDGET_LOCK:-/run/media-automation-budget.lock}" || return 1
    flock -x -w 5 "$fd" || return 75
    now=$(date +%s);run="${MEDIA_AUTOMATION_RUN_ID:-$OPS_SCRIPT_ID:${START_TIME:-${START_EPOCH:-$$}}:$$}"
    temp=$(mktemp "$root/.action-budget.XXXXXX") || return 1
    trap 'rm -f -- "$temp"' EXIT
    if [[ -f "$file" ]];then
      jq -e '.schema==1 and (.actions|type)=="object" and all(.actions[];(.at|type)=="number" and (.run|type)=="string")' "$file" >/dev/null || return 1
      cp "$file" "$temp" || return 1
    else
      # Seed from existing issued/uncertain journals instead of resetting limits
      # when the shared contract is first installed. Known local non-dispatch is excluded.
      printf '{"schema":1,"actions":{}}\n' >"$temp"
      local source prefix seed
      for source in "$root/automation-actions.json" "$root/policy-actions.json" "${MEDIA_INTEGRITY_RECOVERY_FILE:-/mnt/vault/cloud/logs/script/media_integrity_audit/recovery.json}";do
        [[ -f "$source" && ! -L "$source" ]] || continue
        prefix="${source##*/}";seed="$temp.seed"
        jq --slurpfile old "$source" --arg prefix "$prefix" --argjson since "$((now-86400))" '
          reduce (($old[0].actions // {})|to_entries[]|select((.value.startedAt // .value.grabSentAt // 0)>=$since and .value.outcome!="not_dispatched" and
           (if $prefix=="recovery.json" then (.value.grabSentAt // 0)>0 else true end))) as $r
           (.;.actions[($prefix+":"+$r.key)]={at:($r.value.grabSentAt // $r.value.startedAt),run:"pre-contract",owner:$prefix,app:$r.value.app,target:($r.value.targetId // $r.value.parentId)})' "$temp" >"$seed" && mv "$seed" "$temp" || return 1
      done
    fi
    if jq -e --arg key "$action" '.actions[$key]!=null' "$temp" >/dev/null;then return 75;fi
    jq -e --argjson since "$((now-86400))" --arg run "$run" '[.actions[]|select(.at>=$since)] as $today | ($today|length)<4 and ([$today[]|select(.run==$run)]|length)<2' "$temp" >/dev/null || return 75
    jq --arg key "$action" --arg app "$app" --argjson target "$target" --arg run "$run" --arg owner "$OPS_SCRIPT_ID" --argjson now "$now" \
      '.actions |= with_entries(select(.value.at>=$now-30*86400)) | .actions[$key]={at:$now,run:$run,owner:$owner,app:$app,target:$target,outcome:"reserved; native journal owns dispatch/outcome"}' "$temp" >"$temp.next" && mv "$temp.next" "$temp" || return 1
    sync -f "$temp" && mv "$temp" "$file" && sync -f "$root"
)

usr_ops_arr_release_undispatched() (
    [[ "${USR_OPS_SHARED_BUDGET_ACTIVE:-false}" == true ]] || return 0
    local key="$1" root="${MEDIA_ACTION_BUDGET_ROOT:-/mnt/vault/cloud/logs/script/media_health_monitor}" fd export_fd temp run
    run="${MEDIA_AUTOMATION_RUN_ID:-$OPS_SCRIPT_ID:${START_TIME:-${START_EPOCH:-$$}}:$$}"
    [[ -f "$root/action-budget.json" && ! -L "$root/action-budget.json" ]] || return 1
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}";flock -s -n "$export_fd" || return 75
    exec {fd}>"${MEDIA_ACTION_BUDGET_LOCK:-/run/media-automation-budget.lock}";flock -x -w 5 "$fd" || return 75
    temp=$(mktemp "$root/.budget-release.XXXXXX") || return 1
    trap 'rm -f -- "$temp"' EXIT
    jq --arg key "$key" --arg run "$run" 'if .actions[$key].run==$run then del(.actions[$key]) else . end' "$root/action-budget.json" >"$temp" && sync -f "$temp" && mv "$temp" "$root/action-budget.json" && sync -f "$root"
)
