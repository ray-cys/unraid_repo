"""Native response adapters and strict release-selection vetoes; no network."""
import copy,io,json,contextlib,sys
from pathlib import Path
s=(Path(__file__).resolve().parents[1]/'user_script/media_integrity_audit.sh').read_text()
s=s.split('recovery_select_release() {',1)[1].split('\n}\n',1)[0].split("python3 -c '\n",1)[1].rsplit("\n'",1)[0].replace("'\\''", "'")
q={'quality':{'id':1},'revision':{'version':1,'real':0,'isRepack':False}}
j={'app':'Radarr','parentId':10,'targets':[10],'profile':{'minFormatScore':10,'items':[{'allowed':True,'quality':{'id':1}},{'allowed':True,'quality':{'id':2}}]},'originalMedia':{'quality':q,'customFormatScore':100,'languages':[{'id':1}],'sceneName':'Old.Release'}}
r={'guid':'new','indexerId':1,'title':'New.Release','protocol':'usenet','size':100,'quality':q,'customFormatScore':100,'approved':False,'temporarilyRejected':False,'rejections':['Existing file meets cutoff: WEB []'],'downloadAllowed':True,'movieRequested':True,'mappedMovieId':10,'languages':[{'id':1}],'history':None}
def select(job,release):
 old=sys.stdin;sys.stdin=io.StringIO(json.dumps({'job':job,'releases':[release]}));out=io.StringIO()
 try:
  with contextlib.redirect_stdout(out):exec(compile(s,'selector','exec'),{})
 finally:sys.stdin=old
 return json.loads(out.getvalue())
assert select(j,r)['payload']=={'guid':'new','indexerId':1,'movieId':10}
for field,value in [('protocol','torrent'),('customFormatScore',99),('mappedMovieId',11),('movieRequested',False),('languages',[{'id':2}]),('title','Old.Release'),('rejections',['Unknown future rejection']),('downloadAllowed',False),('history',{'grabbed':'2026-01-01'})]:
 bad=copy.deepcopy(r);bad[field]=value;assert select(j,bad) is None,(field,value)
bad=copy.deepcopy(r);bad['quality']['revision']['version']=0;assert select(j,bad) is None
# Sonarr v5 nesting and exact multi-episode mapping, never title matching.
j=copy.deepcopy(j);j.update(app='Sonarr',parentId=20,targets=[201,202],targetDetails=[{'id':201,'seasonNumber':1,'episodeNumber':1},{'id':202,'seasonNumber':1,'episodeNumber':2}])
r={'release':{'guid':'new','indexerId':1,'title':'New.Release','protocol':'usenet','size':100},'parsedInfo':{'quality':q,'fullSeason':False},'decision':{'approved':False,'temporarilyRejected':False,'rejections':[{'reason':'diskCutoffMet'}]},'mappedSeriesId':20,'mappedEpisodeInfo':j['targetDetails'],'customFormatScore':100,'downloadAllowed':True,'languages':[{'id':1}]}
assert select(j,r)['payload']['searchInfo']=={'episodeId':201}
for mutate in [lambda x:x['mappedEpisodeInfo'].pop(),lambda x:x['parsedInfo'].update(fullSeason=True),lambda x:x['decision']['rejections'].append({'reason':'minimumCustomFormatScore'}),lambda x:x['mappedEpisodeInfo'][0].update(seasonNumber=2)]:
 bad=copy.deepcopy(r);mutate(bad);assert select(j,bad) is None
print('Native Radarr/Sonarr selection: exact mappings, equal quality/score, nullable history and all identity/profile/rejection/pack/language/revision vetoes passed')
