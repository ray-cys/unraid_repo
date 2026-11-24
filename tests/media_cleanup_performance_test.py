#!/usr/bin/env python3
"""Read-only inventory/state parity and fault tests; no production paths or APIs."""
import json, shutil, subprocess, tempfile, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASH=shutil.which('bash')
source=(ROOT/'user_script/media_cleanup.sh').read_text()
common=source[:source.index('\n# MODULE: ARR')]
a=source.index('mc_arr() (\n')+len('mc_arr() (\n')
b=source.index('\nmain "$@"\n',a)
with tempfile.TemporaryDirectory(prefix='media-cleanup-speed.') as tmp:
    t=Path(tmp);merged=t/'merged.sh'
    merged.write_text(common+'\n'+source[a:b])
    media=t/'root'/'TV';media.mkdir(parents=True)
    for i in range(130): (media/f'{i}.nfo').write_text('metadata'+str(i))
    for name in ['poster.jpg','line\nbreak.nfo','quote"tab\t.nfo','日本語.nfo']:
        (media/name).write_text(name)
    (media/'media.mkv').write_text('not a sidecar')
    (media/'too-big.nfo').write_bytes(b'x'*(2*1024*1024))
    capture=r'''
source "$1"
VERIFY_RUNTIME_DIR="$2";MAX_SIDECAR_SIZE_MB=1
log(){ :; }
capture_kodi_sidecars sonarr "$2/root/TV" "$2/root" '["media.mkv"]'
'''
    old=subprocess.check_output([BASH,'-eu','-c',capture,'test',str(ROOT/'user_script/arr_delete_sync_tag.sh'),tmp])
    new=subprocess.check_output([BASH,'-eu','-c',capture,'test',str(merged),tmp])
    assert json.loads(old)==json.loads(new), 'Sidecar inventory semantics changed'
    # Separate shell wrappers count child tools without affecting their output.
    checks=r'''
source "$1"
VERIFY_RUNTIME_DIR="$2";MAX_SIDECAR_SIZE_MB=1;log(){ :; }
COUNT_LOG="$2/count"
stat(){ printf 'stat\n' >>"$COUNT_LOG";command stat "$@"; }
sha256sum(){ printf 'hash\n' >>"$COUNT_LOG";command sha256sum "$@"; }
capture_kodi_sidecars sonarr "$2/root/TV" "$2/root" '["media.mkv"]' >"$2/inventory"
# 134 eligible small files plus one oversized: 3 bounded groups, 3 tools each.
[[ $(wc -l <"$COUNT_LOG") -le 9 ]]
# Simulate a same-size rewrite during hashing. Its ctime/mtime must reject it.
sha256sum(){ command sha256sum "$@";printf 'changed!' >"$VERIFY_RUNTIME_DIR/root/TV/0.nfo"; }
if capture_kodi_sidecars sonarr "$2/root/TV" "$2/root" '["media.mkv"]' >"$2/changed";then exit 1;fi
# A traversal failure must not become a successful partial manifest.
find(){ return 1; }
if capture_kodi_sidecars sonarr "$2/root/TV" "$2/root" '["media.mkv"]' >"$2/failed";then exit 1;fi
'''
    subprocess.run([BASH,'-eu','-c',checks,'test',str(merged),tmp],check=True)
    # Large unrelated state, repeated IDs and mixed present/missing/unknown
    # episodes verify update-map merging is equivalent to the original reducer.
    seed={'episodes':{str(i):{'seriesId':2,'everHadFile':True,'missingRuns':2,'custom':'preserved'} for i in range(1,15001)},
          'sidecarManifests':{},'sidecarCleanupActions':{'2':{'keep':True}},'seriesRetirements':{'2':{'keep':True}},'unknown':{'keep':True}}
    episodes=[{'id':i,'seriesId':1,'title':'Episode','hasFile':i%3==0,'episodeFileId':i+1000} for i in range(1,501)]
    episodes += [{'id':1,'hasFile':False},{'id':20000,'hasFile':False}]
    (t/'episodes.json').write_text(json.dumps(episodes));(t/'sidecars.json').write_text(new.decode())
    snapshot=r'''
source "$1"
WORK_STATE="$2/$3.json";VERIFY_RUNTIME_DIR="$2";STATE_DIR="$2";SERIES_ROOT="$2/root";RUN_AT=fixed
sonarr_apply_snapshot 1 Fixture "$2/episodes.json" "$2/root/TV" "$2/sidecars.json"
'''
    for label,script in [('old',ROOT/'user_script/arr_delete_sync_tag.sh'),('new',merged)]:
        (t/f'{label}.json').write_text(json.dumps(seed))
        started=time.monotonic()
        subprocess.run([BASH,'-eu','-c',snapshot,'test',str(script),tmp,label],check=True)
        print(f'{label} Sonarr snapshot fixture: {time.monotonic()-started:.3f}s',flush=True)
    assert json.loads((t/'old.json').read_text())==json.loads((t/'new.json').read_text()), 'Sonarr snapshot state changed'
    print('Sidecar parity, bounded tool batches, changing-file/traversal rejection and large Sonarr state parity passed')
