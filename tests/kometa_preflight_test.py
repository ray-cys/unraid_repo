"""Run inside Kometa's existing Python runtime; all APIs/config are fixtures.
Caller provides PREFLIGHT_SOURCE (the embedded Python source), no real tokens.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import yaml

with tempfile.TemporaryDirectory(prefix='kometa-preflight-fixture-') as folder:
    root=Path(folder)
    for name in ['logs','metadata','overlays','collections']: (root/name).mkdir()
    (root/'config.yml').write_text(yaml.safe_dump({'settings':{'default_collection_order':'release'},'plex':{'url':'fixture','token':'fixture'},'libraries':{'Movies':{},'TV Shows':{}}}))
    (root/'collections/movie_collection.yml').write_text(yaml.safe_dump({'dynamic_collections':{'TMDb':{'type':'tmdb_collection','sync':True,'exclude':[123]},'Custom':{'type':'tmdb_collection','template':'my_custom'}}}))
    (root/'logs/meta.log').write_text('[INFO] | Starting 20:00 Run |\n[INFO] | Finished 20:00 Run |\n')
    present={'match':{'mapping_id':1},'title':'Present'}
    absent={'match':{'mapping_id':999},'title':'Absent'}
    (root/'metadata/movie_metadata.yml').write_text(yaml.safe_dump({'metadata':{'Present (2026)':present,'Absent (2026)':absent}}))
    (root/'metadata/tv_metadata.yml').write_text(yaml.safe_dump({'metadata':{'Show':{'match':{'mapping_id':2}}}}))
    (root/'overlays/media_info.yml').write_text('templates:\n  resolution_info:\n    conditionals:\n      resolution:\n        conditions: []\n    plex_search:\n      all:\n        resolution: <<resolution>>\n\n  next_template:\n    plex_all: true\n')
    module=types.ModuleType('plexapi.server')
    movie_ids=['tmdb://1'];show_ids=['tvdb://2']
    class Server:
        def __init__(self,*a,**kw):self.library=self
        def section(self,name):self.name=name;return self
        def all(self,**kw):
            ids=movie_ids if self.name=='Movies' else show_ids
            return [types.SimpleNamespace(title='Present' if self.name=='Movies' else 'Show',guids=[types.SimpleNamespace(id=v) for v in ids])]
    module.PlexServer=Server
    sys.modules['plexapi']=types.ModuleType('plexapi');sys.modules['plexapi.server']=module
    os.environ['KOMETA_CONFIG_ROOT']=str(root)
    def run():
        out=io.StringIO()
        with contextlib.redirect_stdout(out):
            try:exec(compile(PREFLIGHT_SOURCE,'embedded-preflight','exec'),{'__name__':'__main__'})
            except SystemExit:pass
        return json.loads(out.getvalue())
    os.chmod(root/'overlays/media_info.yml',0o640)
    result=run();assert result['status']=='OK',result
    assert (root/'overlays/media_info.yml').stat().st_mode & 0o777 == 0o640
    active=yaml.safe_load((root/'metadata/movie_metadata.yml').read_text())['metadata']
    assert 'Present (2026)' in active and 'Absent (2026)' not in active
    pending=yaml.safe_load((root/'.preflight/movie_metadata.yml.deferred.yml').read_text())
    assert pending['Absent (2026)']==absent
    overlay=yaml.safe_load((root/'overlays/media_info.yml').read_text())
    assert overlay['templates']['resolution_info']['plex_all'] is True
    assert overlay['templates']['resolution_info']['filters']=='<<resolution_filters>>'
    rules=overlay['templates']['resolution_info']['conditionals']['resolution_filters']['conditions']
    assert len(rules)==12 and rules[0]['value']['episodes']['count']==1
    collections=yaml.safe_load((root/'collections/movie_collection.yml').read_text())
    assert collections['templates']['preflight_tmdb_collection_order']=={'tmdb_collection_details':'<<value>>','minimum_items':2,'collection_order':'release'}
    assert collections['dynamic_collections']['TMDb']['exclude']==[123]
    assert collections['dynamic_collections']['TMDb']['sync'] is True
    assert collections['dynamic_collections']['Custom']['template']=='my_custom'
    result=run();assert result['changed'] is False,result
    movie_ids.append('tmdb://999')
    result=run();assert result['status']=='OK',result
    active=yaml.safe_load((root/'metadata/movie_metadata.yml').read_text())['metadata']
    assert 'Absent (2026)' in active
    before=(root/'metadata/movie_metadata.yml').read_bytes()
    (root/'logs/meta.log').write_text('[INFO] | Starting 00:00 Run |\n')
    result=run();assert result['status']=='DEFERRED' and (root/'metadata/movie_metadata.yml').read_bytes()==before
    (root/'logs/meta.log').write_text('[INFO] | Starting 00:00 Run |\n[INFO] | Finished 00:00 Run |\n')
    movie_ids.clear()
    result=run();assert result['status']=='FAILED' and (root/'metadata/movie_metadata.yml').read_bytes()==before
    movie_ids.append('tmdb://1')
    original_replace=os.replace
    def interrupted_replace(source,destination):
        if Path(destination)==root/'metadata/movie_metadata.yml':raise OSError('fixture interrupted publication')
        return original_replace(source,destination)
    os.replace=interrupted_replace
    result=run();os.replace=original_replace
    assert result['status']=='FAILED',result
    retained=yaml.safe_load((root/'.preflight/movie_metadata.yml.deferred.yml').read_text())
    assert retained['Absent (2026)']==absent
    result=run();assert result['status']=='OK',result
    assert 'Absent (2026)' not in yaml.safe_load((root/'metadata/movie_metadata.yml').read_text())['metadata']
    print('Kometa deferral/restoration, ownership, empty filters, active/unknown guards and interrupted-publication recovery fixtures passed')
