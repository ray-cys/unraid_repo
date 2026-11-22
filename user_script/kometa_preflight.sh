#!/bin/bash
# shellcheck disable=SC2034
arrayStarted=true
# Kometa configuration reconciliation v1.0. Schedule 55 3,7,11,15,19,23 * * *.
# Run after MetaFusion and before the four-hour Kometa boundaries. Never changes
# Plex/Arr media, identity, monitoring or download policy. Missing exact-ID
# metadata is retained in a deferred catalogue and restored when Plex has it.
# Incomplete Plex identity inventories/active producers prohibit edits.
set -uo pipefail
readonly SCRIPT_VERSION="1.0"
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
    local rc=0 temp status summary changed previous='' signature
    mountpoint -q /mnt/vault || return 1
    mkdir -p "$STATE_DIR" "$STATUS_DIR" || return 1
    exec 9>"$STATE_DIR/preflight.lock"; flock -n 9 || return 0
    exec {gate}>"${ARR_BACKUP_GATE:-/run/arr-appdata-coordination.lock}"; flock -s -n "$gate" || { printf 'Appdata maintenance active; Kometa preflight deferred.\n'; return 0; }
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}"; flock -s -n "$export_fd" || return 0
    # Never compete with an active or unobservable MetaFusion producer.
    if ! timeout 8 docker exec metafusion cat /tmp/metafusion-status.json | jq -e '.state=="idle"' >/dev/null; then printf 'MetaFusion is active/unverified; configuration edits deferred.\n'; return 0; fi
    temp=$(mktemp "$STATE_DIR/.result.XXXXXX") || return 1
    timeout --signal=TERM --kill-after=5 180 docker exec -i kometa timeout --signal=TERM --kill-after=5 165 python3 - >"$temp" <<'PY'
import json, os, re, stat, sys, time
from pathlib import Path
import yaml
from plexapi.server import PlexServer
root=Path(os.environ.get('KOMETA_CONFIG_ROOT','/config')); state=root/'.preflight'; state.mkdir(mode=0o700,exist_ok=True)
class SafetyError(Exception): pass
changes=[]; deferred_count=restored_count=0
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
    staged=[]
    for library, file_name, provider in [('Movies','movie_metadata.yml','tmdb'),('TV Shows','tv_metadata.yml','tvdb')]:
        local=cfg['libraries'].get(library)
        if not isinstance(local,dict):raise SafetyError('Configured library identity unavailable: '+library)
        creds=dict(cfg.get('plex') or {});creds.update(local.get('plex') or {})
        server=PlexServer(creds['url'],creds['token'],timeout=30)
        section=server.library.section(library)
        items=section.all(includeGuids=True)
        if not items:raise SafetyError('Empty Plex library inventory; metadata preserved')
        ids=set(); titles=set(); complete=True
        for item in items:
            titles.add(re.sub(r'\W+','',item.title).casefold())
            found=[]
            for guid in getattr(item,'guids',[]) or []:
                m=re.fullmatch(provider+r'://(\d+)',guid.id)
                if m:found.append(m.group(1))
            if not found:complete=False
            ids.update(found)
        # An incomplete external-ID inventory cannot prove absence. A matching
        # title is also an identity ambiguity, never permission to discard it.
        if not complete:raise SafetyError('Incomplete '+provider+' Plex GUID inventory; no metadata reconciliation')
        path=root/'metadata'/file_name; old=path.read_bytes(); data=yaml.safe_load(old) or {}
        entries=data.get('metadata')
        if not isinstance(entries,dict):raise SafetyError('Unsupported metadata file schema')
        catalogue=state/(file_name+'.deferred.yml')
        old_catalogue=catalogue.read_bytes() if catalogue.exists() else b''
        pending=yaml.safe_load(old_catalogue) or {}
        if not isinstance(pending,dict):raise SafetyError('Invalid deferred catalogue preserved')
        combined=dict(pending);combined.update(entries); active_entries={};next_pending={}
        def identity_of(name,value):
            if not isinstance(value,dict):return None
            return str((value.get('match') or {}).get('mapping_id',value.get('mapping_id',name)))
        fresh_ids={identity_of(k,v) for k,v in entries.items()}
        latest_by_id={identity_of(k,v):k for k,v in combined.items()}
        for name,value in combined.items():
            if not isinstance(value,dict):active_entries[name]=value;continue
            identity=(value.get('match') or {}).get('mapping_id',value.get('mapping_id',name))
            if name not in entries and (str(identity) in fresh_ids or latest_by_id.get(str(identity))!=name):
                next_pending[name]=value;continue
            if not str(identity).isdigit():active_entries[name]=value;continue
            if str(identity) in ids:
                active_entries[name]=value
                if name in pending and name not in entries:restored_count+=1;changes.append('Restored metadata: '+str(name))
            elif re.sub(r'\W+','',str(name).split(' (')[0]).casefold() in titles:
                active_entries[name]=value
            else:
                next_pending[name]=value
                if name in entries:deferred_count+=1;changes.append('Deferred absent '+provider+' '+str(identity)+': '+str(name))
        if active_entries!=entries or next_pending!=pending:
            data['metadata']=active_entries
            staged.extend([(path,old,yaml.safe_dump(data,sort_keys=False,allow_unicode=True).encode()),
                           (catalogue,old_catalogue,yaml.safe_dump(next_pending,sort_keys=False,allow_unicode=True).encode())])
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
        unions={}
        for path,old,new in staged:
            if path.parent==state:
                merged=dict(yaml.safe_load(old) or {});merged.update(yaml.safe_load(new) or {})
                union=yaml.safe_dump(merged,sort_keys=False,allow_unicode=True).encode()
                tmp=path.with_name('.'+path.name+'.preflight-union');tmp.write_bytes(union);os.chmod(tmp,0o600)
                if (path.read_bytes() if path.exists() else b'')!=old:raise SafetyError('Concurrent catalogue change; originals retained')
                publish_file(tmp,path);unions[path]=union
        for path,old,new in staged:
            if path.parent==state:continue
            if (path.read_bytes() if path.exists() else b'')!=old:raise SafetyError('Concurrent write detected; prepared originals retained')
            publish_file(path.with_name('.'+path.name+'.preflight-new'),path)
        for path,old,new in staged:
            if path.parent!=state:continue
            if path.read_bytes()!=unions[path]:raise SafetyError('Concurrent catalogue change; superset retained')
            publish_file(path.with_name('.'+path.name+'.preflight-new'),path)
        # Keep five original-file sets; the deferred catalogue is never pruned.
        import shutil
        for old_dir in sorted((state/'backups').iterdir(),reverse=True)[5:]:
            if old_dir.is_dir() and re.fullmatch(r'\d{8}_\d{6}(?:_\d+)?',old_dir.name):shutil.rmtree(old_dir)
    summary=f'Metadata deferred={deferred_count}, restored={restored_count}; changed files={len(staged)}. Deferred definitions preserved for future exact-ID restoration. Plex, media and Arr settings unchanged.'
    print(json.dumps({'status':'OK','summary':summary,'changed':bool(staged),'actions':changes[:20]}))
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
