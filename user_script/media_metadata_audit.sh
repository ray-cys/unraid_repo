#!/bin/bash
# shellcheck disable=SC2034
clearLog=true
arrayStarted=true
# MetaFusion/Kometa weekly findings audit and guarded configuration reconciliation v3.2. Schedule 55 3,7,11,15,19,23 * * *.
# Run after MetaFusion and before the four-hour Kometa boundaries. MetaFusion
# owns generated metadata; this wrapper only maintains personal overlay and
# collection templates, under the MetaFusion/wrapper write lock.
# Incomplete Plex identity inventories/active producers prohibit edits.
# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="media_metadata_audit"
# Embedded operations contract v1; generated into standalone User Scripts.
usr_ops_log_line() {
    local level="${1^^}" phase="$2" message="$3" line LC_ALL=C
    case "$level" in WARN) level=WARNING;; ERR|FATAL) level=ERROR;; NOTICE) level=INFO;; esac
    message=${message//$'\r'/};message=${message//$'\n'/ | }
    printf -v line '%s | %s | %s | run=%s | phase=%s | %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$OPS_SCRIPT_ID" "${OPS_RUN_ID:-$$}" "$phase" "$message"
    if ((${#line}>4096));then line="${line:0:4050} ... [truncated]";fi
    printf '%s\n' "$line"
}

# Accept the original command, including its timeout, so producer-specific
# delivery/cooldown/acknowledgement semantics stay with the owning script.
usr_ops_notify() {
    local -a args=("$@")
    local i importance=normal summary='' message='' index=-1 status=UPDATE
    for ((i=0;i<${#args[@]};i++));do
        case "${args[$i]}" in
          -i) importance="${args[$((i+1))]:-normal}";;
          -d) summary="${args[$((i+1))]:-}";;
          -m) index=$((i+1));message="${args[$index]:-}";;
        esac
    done
    case "$importance" in alert|warning) status=ATTENTION;;esac
    if [[ "$message" != 'Status: '* ]];then
        message="Status: $status"$'\n'"Summary: $summary"$'\n\n'"Actions and findings:"$'\n'"${message:-$summary}"
        if ((index>=0));then args[$index]="$message";else args+=(-m "$message");fi
    fi
    # Every notifier has a termination escalation, including legacy callers.
    if [[ "${args[0]##*/}" == timeout ]];then
        if [[ " ${args[*]} " != *' --kill-after'* ]];then args=("${args[0]}" --kill-after=5 "${args[@]:1}");fi
    else args=(timeout --signal=TERM --kill-after=5 30 "${args[@]}");fi
    "${args[@]}"
}

# Bounded local history for scripts previously dependent on the plugin console.
usr_ops_append_log() {
    local file="$1" line="$2" max="${3:-2097152}" i
    [[ -d "${file%/*}" && ! -L "$file" ]] || return 1
    for i in 1 2;do [[ ! -L "$file.$i" ]] || return 1;done
    find "${file%/*}" -maxdepth 1 -type f \( -name "${file##*/}.1" -o -name "${file##*/}.2" \) -mtime +29 -delete || return 1
    if [[ -f "$file" ]] && (( $(stat -c %s "$file")+${#line}+1>max ));then
        rm -f "$file.2";[[ ! -f "$file.1" ]] || mv "$file.1" "$file.2";mv "$file" "$file.1" || return 1
    fi
    printf '%s\n' "$line" >>"$file"
}
# END EMBEDDED OPERATIONS CONTRACT
set -uo pipefail
readonly SCRIPT_VERSION="3.2"
STATE_DIR="${STATE_DIR:-/mnt/vault/cloud/logs/script/media_metadata_audit}"
STATUS_DIR="${STATUS_DIR:-/mnt/vault/cloud/logs/script/user_scripts_status}"
NOTIFY_BIN="${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}"
# Weekly reporting is read-only and runs before all configuration-edit guards.
# No extra schedule: Sunday 11:55 Singapore time matches an existing invocation.
# The watchdog retains the compact 21-day catalogue; full native logs are not
# copied/reparsed here. Never infer a fix from a skipped collection or one clean run.
KOMETA_CONTAINER="${KOMETA_CONTAINER:-kometa}"
WATCHDOG_STATE_FILE="${WATCHDOG_STATE_FILE:-/mnt/vault/cloud/logs/script/docker_service_watchdog/state.json}"
WEEKLY_REPORT_TIMEZONE="${WEEKLY_REPORT_TIMEZONE:-Asia/Singapore}"
WEEKLY_REPORT_WEEKDAY="${WEEKLY_REPORT_WEEKDAY:-7}" # Monday=1, Sunday=7.
WEEKLY_REPORT_HOUR="${WEEKLY_REPORT_HOUR:-11}"
WEEKLY_REPORT_MINUTE="${WEEKLY_REPORT_MINUTE:-55}"
WEEKLY_REPORT_MAX_ITEMS=20
METAFUSION_FINDINGS_FILE="${METAFUSION_FINDINGS_FILE:-/mnt/cache/appdata/metafusion/reports/findings-latest.json}"
METAFUSION_FINDINGS_MAX_BYTES=$((32*1024*1024))

log() {
    local level="$1";shift;local line
    line=$(usr_ops_log_line "$level" "${METADATA_PHASE:-MAIN}" "$*")
    printf '%s\n' "$line"
    [[ ! -d "$STATE_DIR" ]] || usr_ops_append_log "$STATE_DIR/media-metadata-audit.log" "$line"
}

metadata_notify() {
    local released=false rc=0
    if [[ -n "${METADATA_EXPORT_FD:-}" ]];then exec {METADATA_EXPORT_FD}>&-;released=true;fi
    usr_ops_notify "$@" || rc=$?
    if [[ "$released" == true ]];then
        exec {METADATA_EXPORT_FD}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || { METADATA_EXPORT_LOST=true;return 75; }
        flock -s -w 20 "$METADATA_EXPORT_FD" || { exec {METADATA_EXPORT_FD}>&-;METADATA_EXPORT_LOST=true;return 75; }
    fi
    return "$rc"
}

metadata_finish() {
    local rc="$1" temp outcome="${METADATA_STATUS:-FAILED}" summary="${METADATA_SUMMARY:-Audit did not complete}"
    trap - EXIT
    [[ "$outcome" != RUNNING ]] || { outcome=FAILED;summary='Audit ended before recording its final outcome'; }
    ((rc==0)) || { [[ "$outcome" == DEFERRED ]] || outcome=FAILED; }
    if [[ "${METADATA_WEEKLY_STATUS:-}" == FAILED && "$outcome" == OK ]];then outcome=WARNING;summary+='; weekly report delivery or evidence collection failed and remains pending';fi
    log "$(case "$outcome" in FAILED) printf ERROR;;WARNING|ATTENTION) printf WARNING;;*) printf INFO;;esac)" "$outcome: $summary" || true
    [[ "${METADATA_EXPORT_LOST:-false}" != true ]] || return 0
    temp=$(mktemp "$STATUS_DIR/.media-metadata-receipt.XXXXXX") || return 0
    jq -n --arg status "$outcome" --arg summary "$summary" --arg weekly "${METADATA_WEEKLY_STATUS:-NOT_CHECKED}" \
      --arg phase "${METADATA_PHASE:-startup}" --arg run "${METADATA_RUN_ID:-$$}" --arg version "$SCRIPT_VERSION" \
      --argjson started "${METADATA_STARTED:-0}" --argjson epoch "$(date +%s)" \
      '{schema:1,name:"media_metadata_audit",status:$status,summary:$summary,epoch:$epoch,startedAt:$started,runId:$run,phase:$phase,scriptVersion:$version,weeklyReportStatus:$weekly}' >"$temp" && mv "$temp" "$STATUS_DIR/media_metadata_audit.json" || rm -f "$temp"
}

weekly_media_report() {
    local preview="${1:-false}" epoch input result saved mf watchdog report_state="$STATE_DIR/weekly-report-state.json" rc=0
    epoch=$(date +%s)
    mkdir -p "$STATE_DIR" || return 1
    [[ ! -L "$report_state" && ! -L "$STATE_DIR/weekly-report.txt" && ! -L "$WATCHDOG_STATE_FILE" ]] || return 1
    input=$(mktemp "$STATE_DIR/.weekly-input.XXXXXX") || return 1
    result=$(mktemp "$STATE_DIR/.weekly-result.XXXXXX") || { rm -f "$input"; return 1; }
    saved=$(mktemp "$STATE_DIR/.weekly-state.XXXXXX") || { rm -f "$input" "$result"; return 1; }
    chmod 600 "$input" "$result" "$saved"
    if [[ -f "$report_state" ]]; then
        jq -e '.schema==1 and (.nextDue|type=="number") and (.lastCheckedAt|type=="number")' "$report_state" >/dev/null && cp "$report_state" "$saved" || { rm -f "$input" "$result" "$saved"; return 1; }
    else printf '{}\n' >"$saved"; fi
    mf=$(mktemp "$STATE_DIR/.metafusion-input.XXXXXX") || return 1
    watchdog=$(mktemp "$STATE_DIR/.watchdog-input.XXXXXX") || { rm -f "$mf"; return 1; }
    chmod 600 "$mf" "$watchdog"
    if [[ -L "$METAFUSION_FINDINGS_FILE" ]]; then
        printf '{"status":"symlink rejected"}' >"$mf"
    elif [[ ! -f "$METAFUSION_FINDINGS_FILE" ]]; then
        printf '{"status":"missing; awaiting first producer export"}' >"$mf"
    elif (( $(stat -c %s "$METAFUSION_FINDINGS_FILE" 2>/dev/null || printf 999999999) > METAFUSION_FINDINGS_MAX_BYTES )); then
        printf '{"status":"exceeds 32 MiB consumer limit"}' >"$mf"
    elif ! jq -c '{status:"available",snapshot:.}' "$METAFUSION_FINDINGS_FILE" >"$mf" 2>/dev/null; then
        printf '{"status":"unreadable or malformed JSON"}' >"$mf"
    fi
    if ! jq -c 'select(type=="object")' "$WATCHDOG_STATE_FILE" >"$watchdog" 2>/dev/null || [[ ! -s "$watchdog" ]]; then
        printf '{}' >"$watchdog"
    fi
    if ! jq --slurpfile saved "$saved" --slurpfile mf "$mf" --arg name "$KOMETA_CONTAINER" \
        '{saved:$saved[0],metafusion:$mf[0],catalogue:(.jobs[$name].runLog.maintenance // null),
          gap:(.jobs[$name].runLog.gap // true),backlog:(.jobs[$name].runLog.backlog // true)}' "$watchdog" >"$input"; then
        rm -f "$input" "$result" "$saved" "$mf" "$watchdog"; return 1
    fi
    rm -f "$mf" "$watchdog"
    local program
    program="$(cat <<'PYWEEKLY'
import datetime, json, re, sys
from zoneinfo import ZoneInfo
from pathlib import Path
# Optional read-only attribution using current local config. Never print its
# credentials or assign an ambiguous/shared source to one library.
library_files = {}
file_libraries = {}
def normal_path(value):
    value = str(value).replace("\\", "/")
    while value.startswith("./"):
        value = value[2:]
    return value.removeprefix("/config/").removeprefix("config/")
try:
    import yaml
    config_path = Path("/config/config.yml")
    if config_path.is_file() and config_path.stat().st_size <= 4*1024*1024:
        config = yaml.safe_load(config_path.read_text())
        for library, settings in (config.get("libraries") or {}).items():
            library_files[library] = []
            for kind in ("collection_files", "overlay_files", "metadata_files", "playlist_files"):
                entries = settings.get(kind) or []
                if not isinstance(entries, list):
                    entries = [entries]
                for entry in entries:
                    path = entry.get("file") if isinstance(entry, dict) else None
                    if isinstance(path, str):
                        if path not in library_files[library]:
                            library_files[library].append(path)
                        file_libraries.setdefault(normal_path(path), set()).add(library)
except Exception:
    library_files, file_libraries = {}, {}
now, zone, weekday, hour, minute, maximum, preview = sys.argv[1:]
now, weekday, hour, minute, maximum = map(int, (now, weekday, hour, minute, maximum))
if not 1 <= weekday <= 7 or not 0 <= hour <= 23 or not 0 <= minute <= 59 or not 1 <= maximum <= 50:
    raise ValueError("Invalid weekly report schedule/size")
zone = ZoneInfo(zone)
data = json.load(sys.stdin)
saved, catalogue = data["saved"], data["catalogue"]
kometa_problem=None
if (not isinstance(catalogue,dict) or catalogue.get("schema")!=1
        or not isinstance(catalogue.get("issues"),dict) or not isinstance(catalogue.get("runs"),list)
        or not all(isinstance(row,dict) and isinstance(row.get("message"),str)
                   and isinstance(row.get("firstSeen"),(int,float)) and isinstance(row.get("lastSeen"),(int,float))
                   and isinstance(row.get("context",{}),dict) for row in catalogue.get("issues",{}).values())):
    catalogue={"issues":{},"runs":[],"trackingSince":now}
    kometa_problem="Kometa catalogue unavailable; watchdog immediate reporting remains enabled."
scan=catalogue.get("lastScanAt",0)
if not isinstance(scan,(int,float)) or not 0<scan<=now+300 or scan<now-3600:
    scan=0
    kometa_problem="Kometa catalogue stale/unavailable; retained findings are historical. Watchdog immediate reporting remains enabled."
current = datetime.datetime.fromtimestamp(now, zone)
def next_review():
    candidate = current.replace(hour=hour, minute=minute, second=0, microsecond=0)
    candidate += datetime.timedelta(days=(weekday-current.isoweekday()) % 7)
    if candidate.timestamp() <= now:
        candidate += datetime.timedelta(days=7)
    return int(candidate.timestamp())
def stamp(epoch):
    return datetime.datetime.fromtimestamp(epoch, zone).strftime("%d %b %Y %H:%M") if epoch else "not recorded"
def safe(text, limit=900):
    text = str(text)
    text = re.sub(r"""(?is)(["']?(?:api[_-]?key|token|password|secret|authorization)["']?\s*[:=]\s*)(["'])(.*?)\2""", r'\1"[REDACTED]"', text)
    text = re.sub(r"(?i)([\"']?(?:api[_-]?key|token|password|secret|authorization)[\"']?\s*[:=]\s*)[\"']?[^\s,;|]+", r"\1[REDACTED]", text)
    text = re.sub(r"(https?://[^\s?#|]+)[?#][^\s|]*", r"\1?[REDACTED]", text)
    text = re.sub(r"(?i)(https?://)[^/@\s]+@", r"\1[REDACTED]@", text)
    return " ".join(text.split())[:limit]
def advice(message, context):
    lower = message.lower()
    if re.search(r"yaml|duplicate key|scannererror|parsererror|mapping values|indent", lower):
        category = "YAML syntax/configuration"
        action = "Open the indicated YAML; check the named key, indentation and any reported line/column. Validate the file before the next normal run."
    elif re.search(r"file.*(?:not found|does not exist)|no such file|path.*not found", lower):
        category = "Missing file/path"
        action = "Check the configured container-visible path and volume mapping. Confirm the referenced YAML/artwork file exists; a host path is not necessarily visible inside Kometa."
    elif re.search(r"401|403|unauthori|forbidden|invalid.*(?:token|api.key)", lower):
        category = "Authentication/permissions"
        action = "Verify the affected service credentials and access permissions. Keep tokens out of screenshots and shared logs."
    elif re.search(r"429|rate.limit|timeout|timed out|connection|502|503|504", lower):
        category = "Service/network failure"
        action = "Check which provider failed and whether later runs recovered. Review connectivity, rate limits and provider availability before changing YAML."
    elif re.search(r"poster|background|artwork|image|overlay|upload", lower):
        category = "Artwork/overlay"
        action = "Check the named asset, supported format, size and container-visible path. For uploads, check the associated Plex/API error as well."
    elif re.search(r"no.*(?:items|results|matches)|empty|minimum", lower):
        category = "Empty/filtered result"
        action = "Check the builder, filters and minimum-item policy. An intentionally empty collection can be expected; do not remove a valid filter just to silence the warning."
        if "resolution" in lower and "no matches" in lower:
            action = "Check whether this library actually contains the requested resolution. An empty SD/480p/other resolution class can be expected; verify the intended overlay/filter and do not loosen a valid filter solely to silence the message."
    elif re.search(r"attribute|template|variable|builder|not supported|invalid", lower):
        category = "Configuration/schema"
        action = "Check the named attribute/template/variable against the installed Kometa version and confirm referenced templates and parameters exist."
    elif re.search(r"tmdb|tvdb|imdb|external.id|guid", lower):
        category = "Metadata/provider identity"
        action = "Check the named TMDb/TVDb/IMDb identity and Plex item match. Confirm provider availability and MetaFusion mapping/source data before changing generated metadata."
    elif "plex error" in lower:
        category = "Plex library/API"
        action = "Check the named library/item and Plex response. Confirm library access and supported search/filter behaviour; distinguish Plex data/API failures from YAML syntax problems."
    else:
        category = "Review required"
        action = "Inspect this message with the preceding library/file/collection headings in the native run log. Context not supplied by the log is left unknown."
    path = context.get("file", "")
    ownership = "Ownership not established from log context."
    if re.search(r"(?:^|/)metadata/(?:movie_metadata|tv_metadata|formula1_2026)\.ya?ml$", path):
        ownership = "Known MetaFusion output path; confirm current ownership and correct the generating source/configuration instead of applying an edit that may be overwritten."
    return category, action, ownership
cutoff = now - 7*86400
def iso_epoch(value):
    if not isinstance(value,str):
        raise ValueError("timestamp missing")
    parsed=datetime.datetime.fromisoformat(value.replace("Z","+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp has no timezone")
    result=int(parsed.timestamp())
    if result<=0 or result>now+300:
        raise ValueError("timestamp outside valid range")
    return result

def metafusion_review():
    wrapper=data.get("metafusion") or {"status":"missing"}
    snapshot=wrapper.get("snapshot")
    problem=None
    mf_blocks=[]
    email_groups={}
    summaries=[]
    opened=[]; fixed=[]
    try:
        if wrapper.get("status")!="available":
            raise ValueError(str(wrapper.get("status","missing")))
        if not isinstance(snapshot,dict) or type(snapshot.get("schema_version")) is not int or snapshot["schema_version"]!=1:
            raise ValueError("unsupported/invalid findings schema")
        generated=iso_epoch(snapshot.get("generated_at"))
        run=snapshot.get("run")
        if not isinstance(run,dict) or run.get("status") not in ("completed","incomplete") or not isinstance(run.get("run_id"),str):
            raise ValueError("invalid run envelope")
        finished=iso_epoch(run.get("finished_at"))
        if abs(generated-finished)>300:
            raise ValueError("export and run timestamps disagree")
        for field in ("open","recently_resolved","run_history"):
            if not isinstance(snapshot.get(field),list):
                raise ValueError("invalid "+field+" collection")
        if now-generated>8*3600:
            problem="Latest findings export is older than eight hours; retained findings below are historical, not current verification."
        if run["status"]!="completed":
            problem="Latest MetaFusion run is incomplete; coverage is unverified and retained findings must not be interpreted as a complete inventory."
        records=snapshot["open"]+snapshot["recently_resolved"]
        for row in records:
            if not isinstance(row,dict) or row.get("status") not in ("open","resolved") or not all(isinstance(row.get(k),str) and row[k] for k in ("finding_id","first_seen","last_checked_at","reason_code","operation")):
                raise ValueError("invalid item identity/lifecycle fields")
            iso_epoch(row["first_seen"]); iso_epoch(row["last_checked_at"])
            if not isinstance(row.get("evidence",{}),dict):
                raise ValueError("invalid finding evidence")
        if any(row["status"]!="open" for row in snapshot["open"]) or any(row["status"]!="resolved" for row in snapshot["recently_resolved"]):
            raise ValueError("finding collection/status mismatch")
        opened=snapshot["open"]
        fixed=[row for row in snapshot["recently_resolved"] if iso_epoch(row.get("resolved_at"))>=max(cutoff,saved.get("lastReportAt",0)+1)]
        # Dedupe the same occurrence; finding_id alone is insufficient on relapse.
        def unique(rows):
            return list({(r["finding_id"],r["first_seen"]):r for r in rows}.values())
        opened=unique(opened); fixed=unique(fixed)
        def priority(row):
            code=row["reason_code"]
            if row.get("evidence",{}).get("error_type") or code in ("ownership_collision","library_processing_failed","incomplete_coverage") or code.startswith("retry_"):
                return 0
            if code in ("no_candidate_returned","source_missing","locked_skipped"):
                return 2
            return 1
        opened.sort(key=lambda row:(priority(row),row.get("library") or "",row.get("title") or "",row["finding_id"]))
        fixed.sort(key=lambda row:row["resolved_at"],reverse=True)
        histories=[r for r in snapshot["run_history"] if isinstance(r,dict) and iso_epoch(r.get("finished_at"))>=cutoff]
        histories=list({r["run_id"]:r for r in histories if isinstance(r.get("run_id"),str)}.values())
        summaries=["MetaFusion native findings: "+str(len(opened))+" open; "+str(len(fixed))+" newly reported verified recoveries.",
                   "MetaFusion open reasons (native observations, not an error total): "+safe(json.dumps(snapshot.get("open_by_reason",{}),ensure_ascii=False),1500),
                   "MetaFusion export: "+stamp(generated)+"; latest run: "+run["status"]+"; mode: "+safe(run.get("mode","unknown"),30)+"; targeted: "+str(bool(run.get("targeted")))+".",
                   "MetaFusion recorded runs this week: "+str(len(histories))+"; completed: "+str(sum(r.get("status")=="completed" for r in histories))+". Counts describe recorded runs, not unique items.",
                   "MetaFusion producer build: "+safe(json.dumps(run.get("build",{}),ensure_ascii=False),600),
                   "Latest run libraries: "+safe(json.dumps(run.get("libraries",{}),ensure_ascii=False),1500),
                   "Latest run field actions: "+safe(json.dumps(run.get("fields_by_action",{}),ensure_ascii=False),800),
                   "Latest artwork-present evaluations by action: "+safe(json.dumps(run.get("artwork_present_by_action",{}),ensure_ascii=False),800),
                   "Latest cleanup counts: "+safe(json.dumps(run.get("cleanup",{}),ensure_ascii=False),800),
                   "Enabled operations: "+safe(json.dumps(run.get("enabled_operations",{}),ensure_ascii=False),1000)+"; full-scan libraries: "+safe(json.dumps(run.get("full_scan_libraries",[]),ensure_ascii=False),500),
                   "Native source-missing observations concern provider/generated fields; they are not a direct audit of every field currently stored in Plex.",
                   "Native history is limited to retained producer runs; missing historical exports are not reconstructed from logs."]
        if run.get("unreadable_audits"):
            problem=(problem+" " if problem else "")+"MetaFusion reported unreadable application audits; inspect native reports."
        action_map={
            "review_ownership":"Review the recorded owner/lock and exact destination. Confirm identity before changing ownership or generated artwork.",
            "verify_application":"Review the native application audit. Generated YAML or artwork on disk does not prove Plex applied it.",
            "inspect_retry_queue":"Review the native retry queue and failure class; correct the provider, identity or storage problem before retrying.",
            "check_storage_permissions":"Check the recorded destination, container-visible mount and write permissions.",
            "review_inventory":"Review the protected Plex inventory change; confirm intended removals before releasing an inventory hold.",
            "recheck_on_eligible_scan":"Review the provider/policy evidence and allow a subsequent eligible scan to recheck this exact item."
        }
        resolutions={
            "destination_present":"Artwork file is present; this does not establish Plex application.",
            "filesystem_verified":"Artwork passed native filesystem verification; Plex application is a separate check.",
            "item_removed":"MetaFusion verified that this exact item was removed from Plex.",
            "season_removed":"MetaFusion verified this season's completed cleanup/removal.",
            "applied":"Native application audit confirmed the output was applied.",
            "selected":"Native verification confirmed the artwork was selected.",
            "identity_verified":"Native identity verification now passes."
        }
        for row in opened+fixed:
            resolved_row=row["status"]=="resolved"
            checked=iso_epoch(row["last_checked_at"])
            lifecycle="RESOLVED" if resolved_row else ("NEW" if iso_epoch(row["first_seen"])>=max(cutoff,saved.get("lastReportAt",0)+1) else "PERSISTENT")
            code=row["reason_code"]
            block=["", "[MetaFusion] "+lifecycle+" | "+safe(row["operation"],120)+" | "+safe(code,100),
                   "Library: "+safe(row.get("library") or "not identified",180)+"; item: "+safe(row.get("title") or ("title not supplied; use exact Plex ID" if row.get("plex_rating_key") else "library/job scope"),220),
                   "Identity: server="+safe(row.get("server_id") or "unknown",120)+"; library UUID="+safe(row.get("library_uuid") or "unknown",120)+"; Plex="+safe(row.get("plex_rating_key") or "unknown",50)+"; TMDb="+safe(row.get("tmdb_id") or "unknown",50)+"; season="+safe(row.get("season_number"),20)+"; episode="+safe(row.get("episode_number"),20),
                   "Finding ID: "+safe(row["finding_id"],100)+"; component: "+safe(row.get("component") or "core",50)+"; mode: "+safe(row.get("mode") or "unknown",30),
                   "First observed: "+stamp(iso_epoch(row["first_seen"]))+"; last checked: "+stamp(checked)+"; observations: "+safe(row.get("observations",0),20),
                   "Evidence: "+safe(json.dumps(row.get("evidence",{}),ensure_ascii=False),1800)]
            if resolved_row:
                resolution=row.get("resolution","unknown")
                block += ["Verified resolved: "+stamp(iso_epoch(row["resolved_at"]))+"; evidence: "+safe(resolution,100),
                          resolutions.get(resolution,"Native processing verified this operation's recovery; generated output alone does not prove Plex application."),
                          "Recovery details: "+safe(json.dumps(row.get("recovery_evidence",{}),ensure_ascii=False),1000)]
            else:
                if row.get("last_run_id")!=run["run_id"]:
                    block.append("Not rechecked in latest run; remains open. Skipped/unchanged processing is not resolution evidence.")
                if code=="no_candidate_returned":
                    block.append("Provider returned no artwork candidate; this is not automatically a download or storage error.")
                elif code=="source_missing":
                    block.append("Provider field unavailable; inspect target_value_present before assuming existing metadata is missing.")
                elif code=="locked_skipped":
                    block.append("Field update held by the configured lock/policy; an intentional hold is not a failed download.")
                block.append("Recommended action: "+action_map.get(row.get("next_action"),"Review the exact native reason code and evidence. Unknown future reasons are retained for review."))
            mf_blocks.append(block)
            # Email groups are presentation only. The full report and producer
            # retain every identity/occurrence and its own recovery evidence.
            grouped_operation=re.sub(r"(?<=\.)[0-9]+(?=\.|$)","*",row["operation"])
            grouped_operation=re.sub(r"^season [0-9]+ poster$","season * poster",grouped_operation)
            key=(row.get("server_id"),row.get("library_uuid"),row.get("library"),grouped_operation,code,lifecycle,row.get("mode"),row.get("resolution"))
            if key not in email_groups:
                email_groups[key]={"count":0,"block":block.copy(),"operation":grouped_operation}
            email_groups[key]["count"]+=1
    except (ValueError,TypeError,KeyError,OverflowError) as error:
        problem="Native findings unavailable/unverified: "+safe(error,200)+". Await the next non-dry MetaFusion run or inspect its native exporter. No missing file is interpreted as a clean result."
        opened=[]; fixed=[]; mf_blocks=[]; email_groups={}
        summaries=["MetaFusion findings coverage: UNVERIFIED."]
    email_blocks=[]
    for group in email_groups.values():
        block=group["block"]
        if group["count"]>1:
            block.insert(2,"Related native findings: "+str(group["count"])+"; grouped operation: "+safe(group["operation"],150)+"; one detailed example shown. Every exact finding ID/evidence is retained in weekly-report.txt.")
        email_blocks.append(block)
    if problem:
        warning=["","[MetaFusion] COVERAGE UNVERIFIED",problem,
                 "Recommended action: check the producer run, findings export freshness/schema and native application-audit availability; no automatic fix was inferred."]
        mf_blocks.insert(0,warning); email_blocks.insert(0,warning)
    return mf_blocks,email_blocks,summaries,len(opened),len(fixed),bool(problem)

mf_blocks,mf_email_blocks,mf_summary,mf_active,mf_resolved,mf_partial=metafusion_review()

issues = [dict(value) for value in catalogue.get("issues", {}).values()
          if not value.get("resolvedAt") or value.get("resolvedAt", 0) >= max(cutoff, saved.get("lastReportAt",0)+1)]
issues.sort(key=lambda issue: (bool(issue.get("resolvedAt")), issue.get("severity") not in ("FATAL", "CRITICAL", "ERROR"), -issue.get("lastSeen", 0)))
resolved = sum(bool(issue.get("resolvedAt")) for issue in issues)
active = len(issues)-resolved
runs = [run for run in catalogue.get("runs", []) if run.get("finished", 0) >= cutoff]
partial = bool(data.get("gap") or data.get("backlog") or catalogue.get("dropped") or catalogue.get("trackingSince", now)>cutoff)
lines = ["Media metadata weekly maintenance review", "Period: "+stamp(cutoff)+" to "+stamp(now)+" ("+str(zone)+")",
         f"Kometa recorded normal runs: {len(runs)}; findings needing review: {active}; verified resolved: {resolved}.",
         "Tracking started: "+stamp(catalogue.get("trackingSince", 0))+"; last scan: "+stamp(scan)+"."]
if partial:
    lines.append("Coverage is partial: collection started within this period, a log gap/backlog exists, or a capture limit was reached. Missing findings do not establish a clean week.")
if catalogue.get("dropped"):
    lines.append("Capture-limit events recorded: "+str(catalogue["dropped"])+"; the catalogue is bounded to 256 issues/128 distinct findings per run.")
latest_run = max(runs, key=lambda run: run.get("finished", 0), default={})
latest_start = latest_run.get("started", 0)
lines += mf_summary
if kometa_problem:
    lines.append(kometa_problem)
header = lines.copy()
blocks = []
for number, issue in enumerate(issues, 1):
    block_start = len(lines)
    context = dict(issue.get("context", {}))
    libraries = file_libraries.get(normal_path(context.get("file", "")), set())
    if not context.get("library") and len(libraries)==1:
        context["library"] = next(iter(libraries))
    category, action, ownership = advice(issue["message"], context)
    fixed = issue.get("resolvedAt", 0)
    state = "RESOLVED: two completed runs processed the same scope without findings" if fixed else (
        "OBSERVED in latest recorded run" if latest_start in issue.get("affectedRuns", []) else "NOT RE-OBSERVED; resolution unverified")
    lines += ["", f"{number}. [Kometa] [{safe(issue.get('severity','WARNING'),20)}] {category} | {state}",
              "Library: "+safe(context.get("library") or "not identified",180),
              "YAML/source: "+safe(context.get("file") or "not identified in log context",300),
              "Scope: "+safe(context.get("kind") or "not identified",40)+"; item: "+safe(context.get("item") or "not identified",220),
              "Issue ID: "+safe(issue.get("id","unknown"),30), "Message: "+safe(issue["message"]),
              "Affected recorded runs this week: "+str(sum(epoch>=cutoff for epoch in issue.get("affectedRuns",[])))+
              "; occurrences in last affected run: "+str(issue.get("occurrencesInLatestRun",1)),
              "First observed: "+stamp(issue["firstSeen"])+"; last observed: "+stamp(issue["lastSeen"])+("; verified resolved: "+stamp(fixed) if fixed else ""),
              "Recommended action: "+action, "File ownership: "+ownership]
    if not context.get("file") and context.get("library") in library_files:
        lines.append("Configured local sources (candidates, not proven origin): "+safe("; ".join(library_files[context["library"]][:5]),700))
    blocks.append(lines[block_start:])
# Each producer gets space in the same bounded email; a large Kometa backlog
# cannot crowd all native MetaFusion findings out of the weekly notification.
all_blocks=[]
if kometa_problem:
    all_blocks.append(["","[Kometa] COVERAGE UNVERIFIED",kometa_problem])
for index in range(max(len(blocks),len(mf_blocks))):
    if index<len(mf_blocks): all_blocks.append(mf_blocks[index])
    if index<len(blocks): all_blocks.append(blocks[index])
footer=["", "Reporting performed no YAML edits, restarts or corrective actions. Native verified recoveries above describe MetaFusion's actions. Urgent availability/job failures remain with Docker Service Watchdog."]
email_candidates=[]
if kometa_problem:
    email_candidates.append(["","[Kometa] COVERAGE UNVERIFIED",kometa_problem])
for index in range(max(len(blocks),len(mf_email_blocks))):
    if index<len(mf_email_blocks): email_candidates.append(mf_email_blocks[index])
    if index<len(blocks): email_candidates.append(blocks[index])
email_lines=header.copy()
shown=0
for block in email_candidates[:maximum]:
    if len("\n".join(email_lines+block+footer).encode())>22000:
        break
    email_lines.extend(block); shown+=1
if shown<len(email_candidates):
    email_lines += ["",f"Email includes {shown} of {len(email_candidates)} review entries/groups. {len(email_candidates)-shown} additional entries/groups are retained with details in weekly-report.txt. Both producers share the item/byte budget."]
if not all_blocks:
    footer.insert(0,"No actionable findings recorded. This does not certify unprocessed items or disabled operations.")
full_body="\n".join(header+[line for block in all_blocks for line in block]+footer)
body="\n".join(email_lines+footer)
if len(body.encode())>24000:
    body=body.encode()[:23000].decode(errors="ignore")+"\n[Email size limit reached; full details retained.]"
schedule_key = f"{zone}/{weekday}/{hour}/{minute}"
next_due = saved.get("nextDue", next_review()) if saved.get("scheduleKey")==schedule_key else next_review()
due = now >= next_due
new_state = {**saved, "schema":1, "scheduleKey":schedule_key, "lastCheckedAt":now, "nextDue":next_review() if due else next_due,
             "lastEvidenceAt":scan, "kometaEvidenceOk":not bool(kometa_problem),
             "metafusionEvidenceOk":not mf_partial,"lastReportAt":saved.get("lastReportAt",0)}
if due:
    new_state["lastReportAt"] = now
print(json.dumps({"state":new_state,"due":due,"send":due and bool(all_blocks),"actionable":active+mf_active,"resolved":resolved+mf_resolved,
                  "metafusionOpen":mf_active,"metafusionResolved":mf_resolved,
                  "coverageWarnings":int(bool(kometa_problem))+int(mf_partial),"partial":partial or mf_partial or bool(kometa_problem),"body":body,"fullBody":full_body,"preview":preview=="true"}))
PYWEEKLY
)" || { rm -f "$input" "$result" "$saved"; return 1; }
    timeout --kill-after=3 25 docker exec -i "$KOMETA_CONTAINER" python3 -c "$program" "$epoch" "$WEEKLY_REPORT_TIMEZONE" "$WEEKLY_REPORT_WEEKDAY" "$WEEKLY_REPORT_HOUR" "$WEEKLY_REPORT_MINUTE" "$WEEKLY_REPORT_MAX_ITEMS" "$preview" <"$input" >"$result" || rc=$?
    if ((rc!=0)) || ! jq -e '.state.schema==1 and (.body|type=="string")' "$result" >/dev/null 2>&1; then
        rm -f "$input" "$result" "$saved"; usr_ops_log_line ERROR reporting 'Weekly evidence collection failed; delivery deadline retained for retry; watchdog availability reporting remains active' >&2; return 1
    fi
    if [[ "$preview" == true ]]; then jq -r .fullBody "$result"; rm -f "$input" "$result" "$saved"; return 0; fi
    local pending="$STATE_DIR/weekly-pending-notification.json"
    if [[ -e "$pending" ]];then
      [[ ! -L "$pending" ]] && jq -e '.state.schema==1 and .send==true and (.body|type)=="string"' "$pending" >/dev/null || { rm -f "$input" "$result" "$saved";return 1; }
      cp "$pending" "$result" || return 1
    fi
    jq -r .fullBody "$result" >"$input" && mv -f "$input" "$STATE_DIR/weekly-report.txt" || { rm -f "$input" "$result" "$saved"; return 1; }
    if [[ $(jq -r .send "$result") == true ]]; then
        cp "$result" "$pending.new" && sync -f "$pending.new" && mv "$pending.new" "$pending" || return 1
        local importance=warning
        if jq -e '.actionable==0 and .coverageWarnings==0' "$result" >/dev/null; then importance=normal; fi
        if [[ ! -x "$NOTIFY_BIN" ]] || ! metadata_notify timeout 30 "$NOTIFY_BIN" -i "$importance" -s 'Media Metadata Weekly Review' -d "Weekly findings: $(jq -r .actionable "$result"); verified resolved: $(jq -r .resolved "$result"); coverage warnings: $(jq -r .coverageWarnings "$result")" -m "$(jq -r .body "$result")"; then
            rm -f "$result" "$saved"; usr_ops_log_line ERROR notification 'Notification delivery failed; exact report retained for retry; delivery deadline unchanged' >&2; return 1
        fi
        usr_ops_log_line INFO notification 'Completed weekly notification delivery'
    fi
    jq .state "$result" >"$saved" && mv -f "$saved" "$report_state" || { rm -f "$result" "$saved"; return 1; }
    rm -f "$result" "$pending"
}

main() {
    if [[ ${1:-} == --version ]]; then printf 'media_metadata_audit.sh %s\n' "$SCRIPT_VERSION"; return; fi
    if [[ ${1:-} == --help ]]; then
        printf 'Usage: bash script [--version|--weekly-report|--report-preview]\nNormal schedule unchanged: collect/report weekly before edit guards, then existing reconciliation. --weekly-report checks the weekly deadline only; no YAML edits. --report-preview prints the current review without email, state updates or YAML edits. Native MetaFusion findings join the watchdog Kometa catalogue. Missing/stale exports are reported as unverified. Review defaults to Sunday 11:55 Asia/Singapore, first available invocation afterward.\n'; return
    fi
    case "${1:-}" in ''|--weekly-report|--report-preview) ;; *) return 2;; esac
    umask 077
    local platform_version
    if [[ -r "${UNRAID_VERSION_FILE:-/etc/unraid-version}" ]]; then
        platform_version=$(sed -n 's/^version="\([^"]*\)"/\1/p' "${UNRAID_VERSION_FILE:-/etc/unraid-version}")
    fi
    local rc=0 temp status summary changed previous='' signature native_report
    mountpoint -q /mnt/vault || return 1
    mkdir -p "$STATE_DIR" "$STATUS_DIR" || return 1
    exec 9>"$STATE_DIR/audit.lock"; flock -n 9 || return 0
    exec {METADATA_EXPORT_FD}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}"; flock -s -n "$METADATA_EXPORT_FD" || return 0
    if [[ ${1:-} == --report-preview ]]; then weekly_media_report true; return $?; fi
    METADATA_STARTED=$(date +%s);METADATA_RUN_ID="${METADATA_STARTED}_$$";METADATA_STATUS=RUNNING;METADATA_PHASE=weekly-report;METADATA_SUMMARY='Audit started';METADATA_WEEKLY_STATUS=RUNNING
    trap 'metadata_finish "$?"' EXIT
    # Planned container downtime is a maintenance deferral, not failed reporting.
    exec {gate}>"${ARR_BACKUP_GATE:-/run/arr-appdata-coordination.lock}";flock -s -n "$gate" || { METADATA_STATUS=DEFERRED;METADATA_WEEKLY_STATUS=DEFERRED;METADATA_SUMMARY='Scheduled application maintenance active; reporting and configuration changes deferred';return 0; }
    local weekly_rc=0
    weekly_media_report false || weekly_rc=$?
    METADATA_WEEKLY_STATUS=OK;((weekly_rc==0)) || METADATA_WEEKLY_STATUS=FAILED
    [[ "${METADATA_EXPORT_LOST:-false}" != true ]] || return 75
    METADATA_PHASE=reconciliation
    if [[ ${1:-} == --weekly-report ]]; then METADATA_PHASE=weekly-report;METADATA_STATUS=OK;METADATA_SUMMARY='Weekly findings reporting checked; no configuration reconciliation requested';return "$weekly_rc"; fi
    if [[ -n "${platform_version:-}" && "$platform_version" != 7.* ]]; then METADATA_STATUS=DEFERRED;METADATA_SUMMARY="Unvalidated Unraid $platform_version; configuration changes deferred";return 0;fi
    # Reporting failure never authorizes or blocks existing guarded edits.
    # Watchdog falls back to its immediate routine alerts if handoff is stale.
    # Never compete with an active or unobservable MetaFusion producer.
    if ! timeout 8 docker exec metafusion cat /tmp/metafusion-status.json | jq -e '.state=="idle"' >/dev/null; then METADATA_STATUS=DEFERRED;METADATA_SUMMARY='MetaFusion active or status unverified; configuration changes deferred';return 0;fi
    if ! timeout 8 docker exec metafusion cat /tmp/metafusion-status.json | jq -e '.capabilities.kometa_metadata_reconciliation==1 and .capabilities.kometa_output_lock==1' >/dev/null; then
        METADATA_STATUS=DEFERRED;METADATA_SUMMARY='Required native reconciliation capability unavailable; no configuration changes';return 0
    fi
    native_report=$(timeout 8 docker exec metafusion cat /tmp/metafusion-status.json | jq -c '{finished:.last_run_finished,status:.last_run_status,result:(.metrics.kometa_reconciliation // {})} | .result.actions=((.result.actions // [])[:10])') || return 1
    temp=$(mktemp "$STATE_DIR/.result.XXXXXX") || return 1
    timeout --signal=TERM --kill-after=5 180 docker exec -i -e "NATIVE_RECONCILIATION=$native_report" "$KOMETA_CONTAINER" timeout --signal=TERM --kill-after=5 165 python3 - >"$temp" <<'PY'
import json, os, re, stat, sys, time
from pathlib import Path
import yaml
import fcntl
from zoneinfo import ZoneInfo
import datetime
root=Path(os.environ.get('KOMETA_CONFIG_ROOT','/config')); state=root/'.preflight'; state.mkdir(mode=0o700,exist_ok=True)
class SafetyError(Exception): pass
changes=[]
try:
    log=root/'logs/meta.log'
    active=None
    log_before=log.stat()
    with log.open(errors='replace') as handle:
        for line in handle:
            body=line.split('|',1)[-1].strip().strip('=| ').strip()
            if re.fullmatch(r'Starting (?:\d{1,2}:\d{2} )?Run',body): active=True
            if re.fullmatch(r'Finished (?:\d{1,2}:\d{2} )?Run',body): active=False
    if active is not False:
        print(json.dumps({'status':'DEFERRED','summary':'Kometa run active or native completion evidence unavailable; files unchanged','changed':False})); sys.exit(0)
    cfg=yaml.safe_load((root/'config.yml').read_text())
    if not isinstance(cfg,dict) or not isinstance(cfg.get('libraries'),dict):raise SafetyError('Unsupported Kometa configuration')
    # This lock coordinates our own writers only. Stock Kometa does not
    # participate; its native log and the schedule provide observational guards.
    # Never require a custom consumer launcher or change its Docker startup.
    output_lock=(root/'.metafusion/output.lock').open('a+')
    try:fcntl.flock(output_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:
        print(json.dumps({'status':'DEFERRED','summary':'MetaFusion owns write lock; no edits','changed':False}));sys.exit(0)
    def publication_allowed():
        current=log.stat()
        if (current.st_ino,current.st_size,current.st_mtime_ns)!=(log_before.st_ino,log_before.st_size,log_before.st_mtime_ns):
            return False
        now=datetime.datetime.now(ZoneInfo('Asia/Singapore'))
        seconds=(now.hour%4)*3600+now.minute*60+now.second
        return 4*3600-seconds>180
    if not publication_allowed():
        print(json.dumps({'status':'DEFERRED','summary':'Kometa activity changed or next scheduled boundary is within three minutes; no configuration changes','changed':False}));sys.exit(0)
    staged=[]
    # Native per-item regex filters allow a legitimate empty resolution class.
    # Keep builder validation elsewhere and preserve all configured overlays.
    overlay=root/'overlays/media_info.yml'; old=overlay.read_bytes(); data=yaml.safe_load(old)
    template=(data.get('templates') or {}).get('resolution_info') or {}
    supported_resolutions={'SD':'SD','480P':'480p','576P':'576p','720P':'720p','1080P':'1080p','Ultra-HD':'4k'}
    for name,definition in (data.get('overlays') or {}).items():
        if isinstance(definition,dict) and 'resolution_info' in str(definition.get('template','')):
            key=(definition.get('variables') or {}).get('key')
            if key not in supported_resolutions:raise SafetyError('Unknown resolution overlay key; template preserved')
    if template.get('plex_search')=={'all':{'resolution':'<<resolution>>'}}:
        text=old.decode(); start=text.index('  resolution_info:\n')
        match=re.search(r'(?m)^  [^ ]|^\S',text[start+len('  resolution_info:\n'):])
        end=(start+len('  resolution_info:\n')+match.start()) if match else len(text)
        block=text[start:end]
        conditions=[]
        for key,res in supported_resolutions.items():
            rule={'resolution.regex':'(?i)^'+re.escape(res)+'$'}
            # Native Plex search matched ANY child episode. Preserve that
            # behaviour explicitly instead of the filter's default 50% rule.
            conditions.append({'key':key,'library_type':'show','builder_level.not':'episode','value':{'episodes':{'count':1,**rule}}})
            conditions.append({'key':key,'value':rule})
        import textwrap
        inject=textwrap.indent(yaml.safe_dump({'resolution_filters':{'conditions':conditions}},sort_keys=False),'      ')
        if block.count('    conditionals:\n')!=1:raise SafetyError('Unexpected resolution conditionals; template preserved')
        block=block.replace('    conditionals:\n','    conditionals:\n'+inject,1)
        pattern=r'(?m)^    plex_search:\s*\n      all:\s*\n        resolution: [\'\"]?<<resolution>>[\'\"]?\s*$'
        block,count=re.subn(pattern,'    plex_all: true\n    filters: <<resolution_filters>>',block)
        if count!=1:raise SafetyError('Unexpected resolution template text; original preserved')
        block=block.rstrip()+'\n\n'
        text=text[:start]+block+text[end:]
        parsed=yaml.safe_load(text)
        assert parsed['templates']['resolution_info']['filters']=='<<resolution_filters>>'
        staged.append((overlay,old,text.encode()));changes.append('Resolution overlays now use validated native filters; empty classes remain enabled and series/seasons retain any-episode matching')
    elif not (template.get('plex_all') is True and template.get('filters')=='<<resolution_filters>>' and
              'resolution_filters' in (template.get('conditionals') or {})):
        raise SafetyError('Unknown resolution template; no automatic rewrite')
    # Native dynamic TMDb defaults inherit collection_order with a warning for
    # every collection. Make the identical effective order explicit, without
    # changing membership, sync/exclusions or an existing custom template.
    collection=root/'collections/movie_collection.yml'
    if collection.exists():
        original=collection.read_bytes(); definitions=yaml.safe_load(original) or {}
        inherited=(cfg['libraries']['Movies'].get('settings') or {}).get('default_collection_order',
                    (cfg.get('settings') or {}).get('default_collection_order'))
        altered=False; template_name='preflight_tmdb_collection_order'
        templates=definitions.get('templates') or {}
        expected={'tmdb_collection_details':'<<value>>','minimum_items':2,'collection_order':inherited}
        for definition in (definitions.get('dynamic_collections') or {}).values():
            if not isinstance(definition,dict) or definition.get('type')!='tmdb_collection':continue
            if not inherited or definition.get('template') not in (None,template_name):continue
            if template_name in templates and templates[template_name]!=expected:
                raise SafetyError('Managed collection template differs; custom settings preserved')
            if definition.get('template') is None:
                definition['template']=template_name;templates[template_name]=expected;altered=True
        if altered:
            definitions['templates']=templates
            staged.append((collection,original,yaml.safe_dump(definitions,sort_keys=False,allow_unicode=True).encode()))
            changes.append('Made inherited TMDb collection order explicit: '+str(inherited)+'; membership/sync/exclusions preserved')
    # Prepare every file before any replacement; original bytes are retained.
    stamp=time.strftime('%Y%m%d_%H%M%S')+'_'+str(time.time_ns()); backup=state/'backups'/stamp
    for path,old,new in staged:
        current=path.read_bytes() if path.exists() else b''
        if current!=old:raise SafetyError('Concurrent configuration change; no overwrite')
        yaml.safe_load(new)
    if staged:
        backup.mkdir(parents=True,exist_ok=False)
        manifest=[]
        for index,(path,old,new) in enumerate(staged):
            saved=backup/(str(index)+'-'+path.name);saved.write_bytes(old)
            tmp=path.with_name('.'+path.name+'.preflight-new');tmp.write_bytes(new)
            mode=0o600;uid=os.getuid();gid=os.getgid()
            if path.exists():
                original_stat=path.stat();mode=stat.S_IMODE(original_stat.st_mode);uid=original_stat.st_uid;gid=original_stat.st_gid
            os.chmod(tmp,mode)
            if (tmp.stat().st_uid,tmp.stat().st_gid)!=(uid,gid):os.chown(tmp,uid,gid)
            manifest.append({'path':str(path),'backup':str(saved),'mode':mode,'uid':uid,'gid':gid})
        (backup/'restore.json').write_text(json.dumps(manifest,indent=2))
        def publish_file(temp,path):
            # Contents and directory entry must be durable before removing the
            # other copy of a definition, including a restored definition.
            with temp.open('rb') as handle:os.fsync(handle.fileno())
            os.replace(temp,path)
            directory=os.open(path.parent,os.O_RDONLY)
            try:os.fsync(directory)
            finally:os.close(directory)
        for path,old,new in staged:
            if not publication_allowed():raise SafetyError('Kometa activity changed; further publication stopped; original-file backups retained')
            if (path.read_bytes() if path.exists() else b'')!=old:raise SafetyError('Concurrent write detected; prepared originals retained')
            publish_file(path.with_name('.'+path.name+'.preflight-new'),path)
        # Keep five original-file sets; the deferred catalogue is never pruned.
        import shutil
        for old_dir in sorted((state/'backups').iterdir(),reverse=True)[5:]:
            if old_dir.is_dir() and re.fullmatch(r'\d{8}_\d{6}(?:_\d+)?',old_dir.name):shutil.rmtree(old_dir)
    summary=f'Native MetaFusion owns metadata reconciliation; wrapper changed {len(staged)} personal configuration file(s). MetaFusion/wrapper writer lock verified; Kometa retains its native scheduler. Plex, media and Arr settings unchanged.'
    reported=json.loads(os.environ.get('NATIVE_RECONCILIATION','{}'))
    reconciliation=reported.get('result') or {}
    native_changed=False
    if reported.get('status')=='success' and reconciliation.get('status')=='ok':
        deferred=reconciliation.get('deferred',0);restored=reconciliation.get('restored',0);imported=reconciliation.get('imported',0)
        summary+=f' Native run {reported.get("finished")}: deferred={deferred}, restored={restored}, legacy imported={imported}.'
        native_changed=bool(deferred or restored or imported)
        changes.extend(reconciliation.get('actions') or [])

    print(json.dumps({'status':'OK','summary':summary,'changed':bool(staged) or native_changed,'actions':changes[:20]}))
except Exception as error:
    # Exception text from HTTP clients can contain URLs/tokens: never echo it.
    print(json.dumps({'status':'FAILED','summary':'Preflight stopped: '+(str(error) if isinstance(error,SafetyError) else type(error).__name__)+'; existing files/backups retained.','changed':False}));sys.exit(1)
PY
    rc=$?
    if ! jq -e '.status|type=="string"' "$temp" >/dev/null 2>&1; then
        jq -n --argjson rc "$rc" '{status:"FAILED",summary:("Container preflight failed/unsupported (exit="+($rc|tostring)+"); configuration preserved"),changed:false}' >"$temp"
    fi
    status=$(jq -r .status "$temp"); summary=$(jq -r .summary "$temp"); changed=$(jq -r .changed "$temp")
    signature=$(jq -c '{status,summary,actions}' "$temp" | sha256sum | awk '{print $1}')
    [[ ! -f "$STATE_DIR/state.json" ]] || previous=$(jq -r '.signature // ""' "$STATE_DIR/state.json")
    METADATA_STATUS="$status";METADATA_SUMMARY="$summary"
    log INFO "$status: $summary"
    if [[ "$status" != DEFERRED && "$signature" != "$previous" && ( "$changed" == true || "$status" == FAILED ) ]]; then
        local importance=normal
        [[ "$status" != FAILED ]] || importance=warning
        metadata_notify timeout 30 "$NOTIFY_BIN" -i "$importance" -s 'Media Metadata Audit' -d "Configuration reconciliation: $status" -m "$summary"$'\n'"$(jq -r '.actions[]?' "$temp")" >/dev/null 2>&1 || { rm -f "$temp"; return 1; }
    fi
    jq --arg signature "$signature" --argjson epoch "$(date +%s)" '.+{signature:$signature,epoch:$epoch}' "$temp" >"$STATE_DIR/.state.new" && mv "$STATE_DIR/.state.new" "$STATE_DIR/state.json" || return 1
    jq --arg name media_metadata_audit --argjson epoch "$(date +%s)" '.+{name:$name,epoch:$epoch}' "$temp" >"$STATUS_DIR/.media-metadata-audit.new" && mv "$STATUS_DIR/.media-metadata-audit.new" "$STATUS_DIR/media_metadata_audit.json"
    rm -f "$temp"
    [[ "$status" != FAILED ]]
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
