# Read only the watchdog's compact producer catalogues. Missing/stale evidence
# stays unverified, and confirmed removals are retired rather than called fixed.
def scheduled_job_reviews(data, now, cutoff, saved, safe, stamp):
    blocks=[];summaries=[];active=resolved=warnings=0;handoff={}
    producers=data.get('jobProducers',[])
    if not isinstance(producers,list):
        producers=[{'name':'scheduled jobs','profile':'unknown','catalogue':None}]
    for producer in producers:
        name=producer.get('name','unknown');profile=producer.get('profile',name)
        if producer.get('retired'):
            continue
        label='ImageMaid' if profile=='imagemaid' else 'Recyclarr'
        cat=producer.get('catalogue');problem=None
        try:
            if not isinstance(cat,dict) or cat.get('schema')!=1 or not isinstance(cat.get('issues'),dict) or not isinstance(cat.get('runs'),dict):
                raise ValueError('producer catalogue unavailable or unsupported')
            scan=cat.get('lastScanAt',0);coverage=cat.get('coverage',{})
            if not isinstance(scan,(int,float)) or not now-3600<=scan<=now+300:
                raise ValueError('watchdog collection is stale; retained outcomes are historical')
            if producer.get('error'):
                raise ValueError('watchdog could not update this producer catalogue; retained state was preserved')
            paused=coverage.get('paused') is True
            if not coverage.get('valid') and not paused:
                problem='Native run/evidence coverage is incomplete or unavailable; no clean result is inferred.'
            if cat.get('droppedAt',0)>=cutoff:
                problem='Capture limit reached within this period; some history/reasons are unavailable.'
            runs=[r for r in cat['runs'].values() if isinstance(r,dict) and isinstance(r.get('finished'),(int,float)) and cutoff<=r['finished']<=now+300]
            latest=max(runs,key=lambda r:r['finished'],default={})
            summaries.append(f'{label} ({safe(name,80)}): {len(runs)} recorded run(s) this week; latest outcome={safe(latest.get("result",producer.get("result","not recorded")),40)}; finished={stamp(latest.get("finished",producer.get("finished",0)))}.')
            if isinstance(producer.get('started'),(int,float)) and producer['started']>producer.get('finished',0):
                summaries.append(label+': current native run is active since '+stamp(producer['started'])+'; the prior completion is not its outcome.')
            if paused:
                summaries.append(label+': planned maintenance deferred collection; previous findings remain retained.')
            if cat.get('trackingSince',now)>cutoff:
                summaries.append(label+': history collection began within this review period; earlier runs/reasons were not reconstructed.')
            # Only current valid coverage can delegate routine warning/error mail.
            handoff[name]=bool(not problem and (coverage.get('valid') or paused))
            for issue in cat['issues'].values():
                if not isinstance(issue,dict) or not isinstance(issue.get('message'),str) or not all(isinstance(issue.get(k),(int,float)) for k in ('firstSeen','lastSeen')):
                    raise ValueError('invalid retained finding identity/timestamps')
                fixed=issue.get('resolvedAt',0)
                if fixed and fixed<max(cutoff,saved.get('lastReportAt',0)+1):continue
                recoveries=[at for at in issue.get('recoveries',[]) if isinstance(at,(int,float)) and at>=max(cutoff,saved.get('lastReportAt',0)+1)]
                resolved+=len(recoveries) or int(bool(fixed))
                if not fixed:active+=1
                message=issue['message'];lower=message.lower()
                if profile=='recyclarr':
                    if re.search(r'401|403|unauthori|forbidden|api.?key',lower):action='Check the affected Sonarr/Radarr URL, API key and permissions in Recyclarr configuration; credentials are redacted.'
                    elif re.search(r'format|quality|profile|trash|yaml|config|invalid|unsupported',lower):action='Review the named Recyclarr YAML, instance, custom-format or quality-profile mapping against the installed Recyclarr release. Correct its source configuration before the next scheduled sync.'
                    else:action='Inspect the named instance and native scheduler result; check Arr availability/connectivity and the complete Recyclarr sync log. Per-instance Completed messages alone do not prove whole-job success.'
                elif re.search(r'restore|clear.before.move|move mode',lower):action='Review native ImageMaid move/clear-before-move settings and the restore destination. Confirm retained files are intentional before changing cleanup settings.'
                elif re.search(r'permission|denied|read.only|path|directory|no such file',lower):action='Check the recorded ImageMaid/Plex container-visible paths, mount access and permissions; do not recursively change unrelated media ownership.'
                else:action='Review the ImageMaid native run and Plex connectivity; correct the exact reported processing condition before its next scheduled run.'
                blocks.append(['',f'[{label}] '+('RESOLVED' if fixed else 'REVIEW REQUIRED')+' | '+safe(issue.get('severity','WARNING'),20),
                    'Container: '+safe(name,80)+'; finding ID: '+safe(issue.get('id','unknown'),80),
                    'Message: '+safe(message,900),'Source: '+safe(issue.get('source','native scheduler/run log'),250),
                    'Verified recoveries in this review: '+(', '.join(stamp(at) for at in recoveries) or 'none recorded')+(' (condition recurred afterward)' if recoveries and not fixed else ''),
                    'First observed: '+stamp(issue['firstSeen'])+'; last observed: '+stamp(issue['lastSeen'])+'; affected recorded runs/conditions: '+str(issue.get('occurrences',len(issue.get('affectedRuns',[])))),
                    ('Verified resolved: '+stamp(fixed)+'; '+safe(issue.get('resolution','Native recovery evidence recorded.'),500)) if fixed else 'Recommended action: '+action])
            if latest.get('counts'):
                summaries.append(label+' latest native summary/counts: '+safe(json.dumps(latest['counts'],ensure_ascii=False),1200)+'. No counts are inferred from a completion banner.')
            elif profile=='imagemaid':
                summaries.append('ImageMaid: move/delete/skip counts were not explicitly captured; this is not a claim of zero cleanup.')
        except (ValueError,TypeError,KeyError) as exc:
            problem=safe(str(exc),250);handoff[name]=False
        if problem:
            warnings+=1;handoff[name]=False
            blocks.append(['',f'[{label}] COVERAGE UNVERIFIED','Container: '+safe(name,80)+'; '+problem,
                           'Recommended action: inspect Docker watchdog job-evidence/collection status. Missing, skipped or truncated evidence does not resolve previous findings.'])
    return blocks,summaries,active,resolved,warnings,handoff
