"""Run embedded preflight in an isolated Kometa-compatible runtime."""
import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import tempfile
import time
import yaml

PREFLIGHT_SOURCE=(Path(__file__).resolve().parents[1]/"user_script/media_metadata_audit.sh").read_text().split("<<'PY'\n",1)[1].split("\nPY\n",1)[0]

with tempfile.TemporaryDirectory(prefix='media-metadata-audit-fixture-') as folder:
    root=Path(folder)
    for name in ['logs','metadata','overlays','collections','.metafusion']: (root/name).mkdir()
    (root/'.metafusion/kometa-coordinator.json').write_text(json.dumps({'schema':1,'epoch':int(time.time()),'state':'scheduled'}))
    (root/'config.yml').write_text(yaml.safe_dump({'settings':{'default_collection_order':'release'},'libraries':{'Movies':{},'TV Shows':{}}}))
    (root/'logs/meta.log').write_text('[INFO] | Starting 20:00 Run |\n[INFO] | Finished 20:00 Run |\n')
    # Generated output is deliberately outside wrapper ownership.
    generated=b'metadata:\n  Manual: {summary: keep exactly}\n'
    (root/'metadata/movie_metadata.yml').write_bytes(generated)
    (root/'collections/movie_collection.yml').write_text(yaml.safe_dump({'dynamic_collections':{'TMDb':{'type':'tmdb_collection','sync':True,'exclude':[123]},'Custom':{'type':'tmdb_collection','template':'my_custom'}}}))
    (root/'overlays/media_info.yml').write_text('templates:\n  resolution_info:\n    conditionals:\n      resolution:\n        conditions: []\n    plex_search:\n      all:\n        resolution: <<resolution>>\n\n  next_template:\n    plex_all: true\n')
    os.environ['KOMETA_CONFIG_ROOT']=str(root)
    def run(epoch=1795518000):
        out=io.StringIO();scope={'__name__':'__main__','FIXTURE_EPOCH':epoch}
        program=PREFLIGHT_SOURCE.replace("datetime.datetime.now(ZoneInfo('Asia/Singapore'))", "datetime.datetime.fromtimestamp(FIXTURE_EPOCH, ZoneInfo('Asia/Singapore'))")
        with contextlib.redirect_stdout(out):
            try:exec(compile(program,'embedded-preflight','exec'),scope)
            except SystemExit:pass
            finally:
                if scope.get('output_lock') is not None:scope['output_lock'].close()
        return json.loads(out.getvalue())
    os.chmod(root/'overlays/media_info.yml',0o640)
    result=run();assert result['status']=='OK',result
    assert (root/'overlays/media_info.yml').stat().st_mode & 0o777 == 0o640
    assert (root/'metadata/movie_metadata.yml').read_bytes()==generated
    overlay=yaml.safe_load((root/'overlays/media_info.yml').read_text())
    rules=overlay['templates']['resolution_info']['conditionals']['resolution_filters']['conditions']
    assert len(rules)==12 and rules[0]['value']['episodes']['count']==1
    collections=yaml.safe_load((root/'collections/movie_collection.yml').read_text())
    assert collections['templates']['preflight_tmdb_collection_order']['collection_order']=='release'
    assert collections['dynamic_collections']['TMDb']['exclude']==[123]
    assert collections['dynamic_collections']['Custom']['template']=='my_custom'
    result=run();assert result['changed'] is False,result
    (root/'logs/meta.log').write_text('[INFO] | Starting 00:00 Run |\n')
    assert run()['status']=='DEFERRED'
    (root/'logs/meta.log').write_text('[INFO] | Starting 00:00 Run |\n[INFO] | Finished 00:00 Run |\n')
    (root/'.metafusion/kometa-coordinator.json').unlink()
    result=run();assert result['status']=='OK',result  # Stock Kometa needs no installed launcher.
    import datetime
    from zoneinfo import ZoneInfo
    near=int(datetime.datetime(2026,11,24,3,59,tzinfo=ZoneInfo('Asia/Singapore')).timestamp())
    assert run(near)['status']=='DEFERRED'
    with (root/'.metafusion/output.lock').open('a+') as holder:
        fcntl.flock(holder,fcntl.LOCK_EX|fcntl.LOCK_NB)
        assert run()['status']=='DEFERRED'
    assert (root/'metadata/movie_metadata.yml').read_bytes()==generated
    print('Preflight native handoff, manual YAML preservation, ownership, configuration-only edits and native idle/writer-lock guards passed')
