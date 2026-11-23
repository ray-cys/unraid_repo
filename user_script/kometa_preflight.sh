#!/bin/bash
# shellcheck disable=SC2034
arrayStarted=true
# Kometa configuration reconciliation v2.0. Schedule 55 3,7,11,15,19,23 * * *.
# Run after MetaFusion and before the four-hour Kometa boundaries. MetaFusion
# owns generated metadata; this wrapper only maintains personal overlay and
# collection templates, under the shared producer/consumer output lock.
# Incomplete Plex identity inventories/active producers prohibit edits.
set -uo pipefail
readonly SCRIPT_VERSION="2.0"
STATE_DIR="${STATE_DIR:-/mnt/vault/cloud/logs/script/kometa_preflight}"
STATUS_DIR="${STATUS_DIR:-/mnt/vault/cloud/logs/script/user_scripts_status}"
NOTIFY_BIN="${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}"
main() {
    if [[ ${1:-} == --version ]]; then printf 'kometa_preflight.sh %s\n' "$SCRIPT_VERSION"; return; fi
    local platform_version
    if [[ -r "${UNRAID_VERSION_FILE:-/etc/unraid-version}" ]]; then
        platform_version=$(sed -n 's/^version="\([^"]*\)"/\1/p' "${UNRAID_VERSION_FILE:-/etc/unraid-version}")
        [[ "$platform_version" == 7.* ]] || { printf 'Unvalidated Unraid %s; maintenance/config mutations deferred.\n' "$platform_version"; return 0; }
    fi
    local rc=0 temp status summary changed previous='' signature native_report
    mountpoint -q /mnt/vault || return 1
    mkdir -p "$STATE_DIR" "$STATUS_DIR" || return 1
    exec 9>"$STATE_DIR/preflight.lock"; flock -n 9 || return 0
    exec {gate}>"${ARR_BACKUP_GATE:-/run/arr-appdata-coordination.lock}"; flock -s -n "$gate" || { printf 'Appdata maintenance active; Kometa preflight deferred.\n'; return 0; }
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}"; flock -s -n "$export_fd" || return 0
    # Never compete with an active or unobservable MetaFusion producer.
    if ! timeout 8 docker exec metafusion cat /tmp/metafusion-status.json | jq -e '.state=="idle"' >/dev/null; then printf 'MetaFusion is active/unverified; configuration edits deferred.\n'; return 0; fi
    if ! timeout 8 docker exec metafusion cat /tmp/metafusion-status.json | jq -e '.capabilities.kometa_metadata_reconciliation==1 and .capabilities.kometa_output_lock==1' >/dev/null; then
        printf 'Native MetaFusion reconciliation capability unavailable; upgrade develop image before enabling preflight v2. No YAML files changed.\n'; return 0
    fi
    native_report=$(timeout 8 docker exec metafusion cat /tmp/metafusion-status.json | jq -c '{finished:.last_run_finished,status:.last_run_status,result:(.metrics.kometa_reconciliation // {})} | .result.actions=((.result.actions // [])[:10])') || return 1
    temp=$(mktemp "$STATE_DIR/.result.XXXXXX") || return 1
    timeout --signal=TERM --kill-after=5 180 docker exec -i -e "NATIVE_RECONCILIATION=$native_report" kometa timeout --signal=TERM --kill-after=5 165 python3 - >"$temp" <<'PY'
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
    # Producer and consumer participate in this same inode lock. Atomic file
    # writes alone do not prevent Kometa reading multiple generations in a run.
    native=json.loads((root/'.metafusion/kometa-coordinator.json').read_text())
    if native.get('schema')!=1 or not 0<=time.time()-native.get('epoch',0)<90:
        raise SafetyError('Coordinated Kometa launcher missing/stale; no configuration edits')
    output_lock=(root/'.metafusion/output.lock').open('a+')
    try:fcntl.flock(output_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:
        print(json.dumps({'status':'DEFERRED','summary':'MetaFusion/Kometa owns shared output lock; no edits','changed':False}));sys.exit(0)
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
    summary=f'Native MetaFusion owns metadata reconciliation; wrapper changed {len(staged)} personal configuration file(s). Shared producer/consumer lock verified. Plex, media and Arr settings unchanged.'
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
