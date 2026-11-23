#!/bin/bash
# shellcheck disable=SC2034
arrayStarted=true
# Kometa configuration reconciliation and weekly maintenance review v2.2. Schedule 55 3,7,11,15,19,23 * * *.
# Run after MetaFusion and before the four-hour Kometa boundaries. MetaFusion
# owns generated metadata; this wrapper only maintains personal overlay and
# collection templates, under the MetaFusion/wrapper write lock.
# Incomplete Plex identity inventories/active producers prohibit edits.
set -uo pipefail
readonly SCRIPT_VERSION="2.2"
STATE_DIR="${STATE_DIR:-/mnt/vault/cloud/logs/script/kometa_preflight}"
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

weekly_kometa_report() {
    local preview="${1:-false}" epoch input result saved report_state="$STATE_DIR/weekly-report-state.json" rc=0
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
    if ! jq --slurpfile saved "$saved" --arg name "$KOMETA_CONTAINER" \
        '{saved:$saved[0],catalogue:(.jobs[$name].runLog.maintenance // null),
          gap:(.jobs[$name].runLog.gap // true),backlog:(.jobs[$name].runLog.backlog // true)}' "$WATCHDOG_STATE_FILE" >"$input"; then
        rm -f "$input" "$result" "$saved"; printf 'Weekly Kometa report: watchdog evidence unavailable; immediate watchdog routing retained.\n' >&2; return 1
    fi
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
if not isinstance(catalogue, dict) or catalogue.get("schema") != 1:
    raise ValueError("Weekly catalogue not collected yet; wait for watchdog ingestion")
scan = catalogue.get("lastScanAt", 0)
if not 0 < scan <= now + 300 or scan < now - 3600:
    raise ValueError("Weekly catalogue is stale; watchdog immediate reporting remains enabled")
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
issues = [dict(value) for value in catalogue.get("issues", {}).values()
          if not value.get("resolvedAt") or value.get("resolvedAt", 0) >= max(cutoff, saved.get("lastReportAt",0)+1)]
issues.sort(key=lambda issue: (bool(issue.get("resolvedAt")), issue.get("severity") not in ("FATAL", "CRITICAL", "ERROR"), -issue.get("lastSeen", 0)))
resolved = sum(bool(issue.get("resolvedAt")) for issue in issues)
active = len(issues)-resolved
runs = [run for run in catalogue.get("runs", []) if run.get("finished", 0) >= cutoff]
partial = bool(data.get("gap") or data.get("backlog") or catalogue.get("dropped") or catalogue.get("trackingSince", now)>cutoff)
lines = ["Kometa weekly maintenance review", "Period: "+stamp(cutoff)+" to "+stamp(now)+" ("+str(zone)+")",
         f"Recorded normal runs: {len(runs)}; findings needing review: {active}; verified resolved: {resolved}.",
         "Tracking started: "+stamp(catalogue.get("trackingSince", 0))+"; last scan: "+stamp(scan)+"."]
if partial:
    lines.append("Coverage is partial: collection started within this period, a log gap/backlog exists, or a capture limit was reached. Missing findings do not establish a clean week.")
if catalogue.get("dropped"):
    lines.append("Capture-limit events recorded: "+str(catalogue["dropped"])+"; the catalogue is bounded to 256 issues/128 distinct findings per run.")
latest_run = max(runs, key=lambda run: run.get("finished", 0), default={})
latest_start = latest_run.get("started", 0)
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
    lines += ["", f"{number}. [{safe(issue.get('severity','WARNING'),20)}] {category} | {state}",
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
email_lines = header.copy()
shown = 0
for block in blocks[:maximum]:
    if len("\n".join(email_lines+block).encode())>22000:
        break
    email_lines.extend(block)
    shown += 1
if shown<len(issues):
    email_lines += ["", f"{len(issues)-shown} additional findings have full messages and recommended actions in weekly-report.txt beside the preflight state. Email includes {shown} complete entries within its size budget."]
if not issues:
    lines += ["", "No actionable findings recorded in the observed period. This does not certify unprocessed libraries/files."]
lines += ["", "No YAML edits, restarts or corrective actions were performed by this reporting module. Fatal/availability/deadline alerts remain with Docker Service Watchdog."]
full_body = "\n".join(lines)
body = "\n".join(email_lines+lines[-2:])
# Keep the email bounded; retained catalogue remains available for later review.
if len(body.encode()) > 24000:
    body = body.encode()[:23000].decode(errors="ignore")+"\n[Report truncated at the email-size budget; remaining findings retained.]"
schedule_key = f"{zone}/{weekday}/{hour}/{minute}"
next_due = saved.get("nextDue", next_review()) if saved.get("scheduleKey")==schedule_key else next_review()
due = now >= next_due
new_state = {**saved, "schema":1, "scheduleKey":schedule_key, "lastCheckedAt":now, "nextDue":next_review() if due else next_due,
             "lastEvidenceAt":scan, "lastReportAt":saved.get("lastReportAt",0)}
if due:
    new_state["lastReportAt"] = now
print(json.dumps({"state":new_state,"due":due,"send":due and bool(issues),"actionable":active,"resolved":resolved,
                  "partial":partial,"body":body,"fullBody":full_body,"preview":preview=="true"}))
PYWEEKLY
)" || { rm -f "$input" "$result" "$saved"; return 1; }
    timeout --kill-after=3 25 docker exec -i "$KOMETA_CONTAINER" python3 -c "$program" "$epoch" "$WEEKLY_REPORT_TIMEZONE" "$WEEKLY_REPORT_WEEKDAY" "$WEEKLY_REPORT_HOUR" "$WEEKLY_REPORT_MINUTE" "$WEEKLY_REPORT_MAX_ITEMS" "$preview" <"$input" >"$result" || rc=$?
    if ((rc!=0)) || ! jq -e '.state.schema==1 and (.body|type=="string")' "$result" >/dev/null 2>&1; then
        rm -f "$input" "$result" "$saved"; printf 'Weekly Kometa report unavailable; delivery deadline unchanged and watchdog immediate reporting retained.\n' >&2; return 1
    fi
    if [[ "$preview" == true ]]; then jq -r .fullBody "$result"; rm -f "$input" "$result" "$saved"; return 0; fi
    jq -r .fullBody "$result" >"$input" && mv -f "$input" "$STATE_DIR/weekly-report.txt" || { rm -f "$input" "$result" "$saved"; return 1; }
    if [[ $(jq -r .send "$result") == true ]]; then
        if [[ ! -x "$NOTIFY_BIN" ]] || ! timeout 30 "$NOTIFY_BIN" -i warning -s 'Kometa Weekly Maintenance' -d "Weekly actionable findings: $(jq -r .actionable "$result"); verified resolved: $(jq -r .resolved "$result")" -m "$(jq -r .body "$result")"; then
            rm -f "$result" "$saved"; printf 'Weekly Kometa notification failed; deadline unchanged for retry.\n' >&2; return 1
        fi
        printf 'Weekly Kometa maintenance notification delivered.\n'
    fi
    jq .state "$result" >"$saved" && mv -f "$saved" "$report_state" || { rm -f "$result" "$saved"; return 1; }
    rm -f "$result"
}

main() {
    if [[ ${1:-} == --version ]]; then printf 'kometa_preflight.sh %s\n' "$SCRIPT_VERSION"; return; fi
    if [[ ${1:-} == --help ]]; then
        printf 'Usage: bash script [--version|--weekly-report|--report-preview]\nNormal schedule unchanged: collect/report weekly before edit guards, then existing reconciliation. --weekly-report checks the weekly deadline only; no YAML edits. --report-preview prints the current review without email, state updates or YAML edits. Review defaults to Sunday 11:55 Asia/Singapore, first available invocation afterward.\n'; return
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
    exec 9>"$STATE_DIR/preflight.lock"; flock -n 9 || return 0
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}"; flock -s -n "$export_fd" || return 0
    if [[ ${1:-} == --report-preview ]]; then weekly_kometa_report true; return $?; fi
    local weekly_rc=0
    weekly_kometa_report false || weekly_rc=$?
    if [[ ${1:-} == --weekly-report ]]; then return "$weekly_rc"; fi
    if [[ -n "${platform_version:-}" && "$platform_version" != 7.* ]]; then printf 'Unvalidated Unraid %s; configuration mutations deferred.\n' "$platform_version"; return 0; fi
    exec {gate}>"${ARR_BACKUP_GATE:-/run/arr-appdata-coordination.lock}"; flock -s -n "$gate" || { printf 'Appdata maintenance active; Kometa preflight deferred.\n'; return 0; }
    # Reporting failure never authorizes or blocks existing guarded edits.
    # Watchdog falls back to its immediate routine alerts if handoff is stale.
    # Never compete with an active or unobservable MetaFusion producer.
    if ! timeout 8 docker exec metafusion cat /tmp/metafusion-status.json | jq -e '.state=="idle"' >/dev/null; then printf 'MetaFusion is active/unverified; configuration edits deferred.\n'; return 0; fi
    if ! timeout 8 docker exec metafusion cat /tmp/metafusion-status.json | jq -e '.capabilities.kometa_metadata_reconciliation==1 and .capabilities.kometa_output_lock==1' >/dev/null; then
        printf 'Native MetaFusion reconciliation capability unavailable; upgrade develop image before enabling preflight v2. No YAML files changed.\n'; return 0
    fi
    native_report=$(timeout 8 docker exec metafusion cat /tmp/metafusion-status.json | jq -c '{finished:.last_run_finished,status:.last_run_status,result:(.metrics.kometa_reconciliation // {})} | .result.actions=((.result.actions // [])[:10])') || return 1
    temp=$(mktemp "$STATE_DIR/.result.XXXXXX") || return 1
    timeout --signal=TERM --kill-after=5 180 docker exec -i -e "NATIVE_RECONCILIATION=$native_report" "$KOMETA_CONTAINER" timeout --signal=TERM --kill-after=5 165 python3 - >"$temp" <<'PY'
import json, os, re, stat, sys, time
from pathlib import Path
import yaml
import fcntl
root=Path(os.environ.get('KOMETA_CONFIG_ROOT','/config')); state=root/'.preflight'; state.mkdir(mode=0o700,exist_ok=True)
class SafetyError(Exception): pass
changes=[]
try:
    log=root/'logs/meta.log'
    active=None
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
    printf '%s: %s\n' "$status" "$summary"
    if [[ "$status" != DEFERRED && "$signature" != "$previous" && ( "$changed" == true || "$status" == FAILED ) ]]; then
        local importance=normal
        [[ "$status" != FAILED ]] || importance=warning
        timeout 30 "$NOTIFY_BIN" -i "$importance" -s 'Kometa Preflight' -d "Configuration reconciliation: $status" -m "$summary"$'\n'"$(jq -r '.actions[]?' "$temp")" >/dev/null 2>&1 || { rm -f "$temp"; return 1; }
    fi
    jq --arg signature "$signature" --argjson epoch "$(date +%s)" '.+{signature:$signature,epoch:$epoch}' "$temp" >"$STATE_DIR/.state.new" && mv "$STATE_DIR/.state.new" "$STATE_DIR/state.json" || return 1
    jq --arg name kometa_preflight --argjson epoch "$(date +%s)" '.+{name:$name,epoch:$epoch}' "$temp" >"$STATUS_DIR/.kometa-preflight.new" && mv "$STATUS_DIR/.kometa-preflight.new" "$STATUS_DIR/kometa_preflight.json"
    rm -f "$temp"
    [[ "$status" != FAILED ]]
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
