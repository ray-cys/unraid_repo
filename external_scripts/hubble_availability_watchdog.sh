#!/bin/bash
# Hubble Availability Watchdog v1.0.1 — runs on the independent Raspberry Pi.
# Purpose: report Hubble outages, stalled monitoring, web-interface failures and
# observed reboots without depending on Hubble to send email. No host restart,
# repair, wake, container action or configuration replay is performed.
# Schedule: managed /etc/cron.d/hubble_availability_watchdog, every two minutes.
# State: one private atomic JSON in /var/lib/hubble_availability_watchdog; retain
# incident/delivery evidence across Pi reboots. Logs: 256 KiB with two rotations.
# SSH: dedicated key restricted on Hubble to --external-status; pinned host key.
# Mail: Pi's existing root msmtp account; no SMTP password in this script/config.
# CLI: --status, --test-email, --maintenance MINUTES --reason TEXT,
#      --clear-maintenance, --version; --config PATH selects an explicit config.
# A maintenance lease is at most 240 minutes and expires automatically. It only
# suppresses new host/reboot notices; unresolved previously notified incidents
# and notification retries are retained. Restore a deliberate long shutdown by
# renewing the explicit lease; no outage is silently acknowledged forever.
set -euo pipefail
exec /usr/bin/python3 - "$@" <<'PY'
# BEGIN EXTERNAL WATCHDOG PYTHON
import argparse, copy, datetime, email.message, email.utils, fcntl, hashlib, json
import os, pathlib, re, stat, subprocess, sys, tempfile, time
VERSION = '1.0.1'
ACTIVE_CONFIG = None


def secure_file(path, optional=False):
    path = pathlib.Path(path)
    if not path.exists():
        if optional: return
        raise ValueError('Required private file is absent: '+str(path))
    s = path.lstat()
    if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or s.st_uid != os.geteuid() or s.st_mode & 0o077:
        raise ValueError('Private regular file ownership/permissions invalid: '+str(path))


def atomic_json(path, value):
    path = pathlib.Path(path); secure_file(path, True)
    fd, temporary = tempfile.mkstemp(prefix='.watchdog.', dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, ensure_ascii=True, separators=(',', ':')); stream.write('\n')
            stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_DIRECTORY)
        try: os.fsync(directory)
        finally: os.close(directory)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def load_config(path):
    secure_file(path)
    c = json.loads(pathlib.Path(path).read_text())
    required = ['target','sshIdentity','knownHosts','recipient','sender','stateDirectory','logDirectory','lockFile']
    if any(not isinstance(c.get(k), str) or not c[k] or '\n' in c[k] or '\r' in c[k] for k in required):
        raise ValueError('Required configuration fields are invalid')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+@[0-9.]+', c['target']): raise ValueError('A fixed SSH user and LAN IPv4 are required')
    for k in ['recipient','sender']:
        if not re.fullmatch(r'[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+', c[k]): raise ValueError('Invalid mail address')
    for k in ['sshIdentity','knownHosts','stateDirectory','logDirectory','lockFile']:
        p = pathlib.Path(c[k])
        if not p.is_absolute() or p.resolve(strict=False) != p: raise ValueError('Unsafe path: '+k)
    secure_file(c['sshIdentity']);secure_file(c['knownHosts'])
    for k in ['stateDirectory','logDirectory']:
        p=pathlib.Path(c[k]);p.mkdir(mode=0o700, parents=True, exist_ok=True)
        s=p.lstat()
        if not stat.S_ISDIR(s.st_mode) or s.st_uid!=os.geteuid() or s.st_mode&0o077: raise ValueError('Private directory required: '+k)
    c.setdefault('webUrl','http://'+c['target'].split('@')[1]+'/')
    if c['webUrl'] != 'http://'+c['target'].split('@')[1]+'/': raise ValueError('Web probe must use the target LAN address')
    c.setdefault('sshBinary','/usr/bin/ssh');c.setdefault('curlBinary','/usr/bin/curl');c.setdefault('mailBinary','/usr/bin/msmtp')
    c.setdefault('mailAccount','default');c.setdefault('expectedHostname','Hubble')
    return c


def run_command(args, timeout, data=None):
    # Temporary files bound captured RAM use even for a broken remote endpoint.
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        try:
            result=subprocess.run(args, input=data, stdout=out, stderr=err, timeout=timeout, close_fds=True)
            rc=result.returncode
        except subprocess.TimeoutExpired: rc=124
        out.seek(0);err.seek(0);stdout=out.read(65537);stderr=err.read(2048)
    if len(stdout)>65536: return 125, '', 'Response exceeded 64 KiB'
    return rc, stdout.decode('utf-8','replace'), stderr.decode('utf-8','replace').strip()


def collect(c, now):
    ssh=[c['sshBinary'],'-F','/dev/null','-n','-T','-o','ControlMaster=no','-o','ControlPath=none','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes',
         '-o','UpdateHostKeys=no','-o','ConnectTimeout=5','-o','ConnectionAttempts=1',
         '-o','ServerAliveInterval=3','-o','ServerAliveCountMax=1','-o','UserKnownHostsFile='+c['knownHosts'],
         '-i',c['sshIdentity'],c['target'],'external-status']
    rc, text, err=run_command(ssh,12)
    web_rc,web,_=run_command([c['curlBinary'],'--noproxy','*','--silent','--output','/dev/null',
         '--write-out','%{http_code}','--connect-timeout','3','--max-time','5',c['webUrl']],7)
    web_good=web_rc==0 and web.strip() in {'200','301','302','303','307','308','401','403'}
    data=None;access_error=''
    if rc==0:
        try:
            data=json.loads(text)
            if not (data.get('schema')==1 and data.get('name')==c['expectedHostname'] and
                    re.fullmatch(r'[0-9a-f-]{36}',data.get('bootId','')) and isinstance(data.get('epoch'),int) and
                    isinstance(data.get('uptimeSeconds'),int) and data['uptimeSeconds']>=0):
                raise ValueError('identity/schema mismatch')
        except (ValueError,TypeError,AttributeError): data=None;access_error='Restricted SSH probe returned invalid identity or JSON'
    else:
        access_error='Restricted SSH probe failed (exit='+str(rc)+'); '+err[:250]
    host_good=data is not None or web_good
    observations={
      'availability': {'result':'ok' if host_good else 'bad','severity':'CRITICAL',
        'detail':('Hubble responded to '+('the restricted SSH probe' if data else 'the web probe')) if host_good else
                 'Hubble could not be reached through either restricted SSH or its web interface. No restart was attempted.'},
      'probe_access': {'result':'ok' if data else ('bad' if web_good else 'unknown'),'severity':'WARNING','detail':
        'Restricted probe identity verified.' if data else access_error},
      'web_interface': {'result':('ok' if web_good else ('bad' if data else 'unknown')),'severity':'WARNING',
        'detail':'HTTP status='+web.strip()+'; transport exit='+str(web_rc)+'. A response proves interface reachability, not authenticated application functionality.'}}
    if data:
        receipt=data.get('fastWatchdog',{});age=data['epoch']-receipt.get('observedAt',0)
        fresh=(receipt.get('bootId')==data['bootId'] and receipt.get('status')=='COMPLETE' and -60<=age<=900)
        warming=data['uptimeSeconds']<900
        observations['monitor_heartbeat']={'result':'ok' if fresh else ('unknown' if warming else 'bad'),'severity':'CRITICAL',
          'detail':'Hubble fast-monitor receipt age='+str(age)+'s; boot matches='+str(receipt.get('bootId')==data['bootId'])+
                   '; startup grace='+str(warming)+'. Host condition findings remain owned by Hubble.'}
        skew=abs(now-data['epoch'])
        observations['clock_agreement']={'result':'ok' if skew<=300 else 'bad','severity':'WARNING',
          'detail':'Pi/Hubble clock difference='+str(skew)+'s; no clock was changed.'}
    else:
        for key in ['monitor_heartbeat','clock_agreement']:
            observations[key]={'result':'unknown','severity':'WARNING','detail':'Hubble probe unavailable; no recovery inferred.'}
    return observations,data


def initial_state():
    return {'schema':1,'conditions':{},'pending':{},'history':[],'delivery':{},'maintenance':{}}


def reconcile(state, observations, host, now, pi_boot, monotonic):
    s=copy.deepcopy(state)
    last=s.get('lastRun',{})
    consecutive=last.get('piBoot')==pi_boot and 0<monotonic-last.get('monotonic',0)<=600 and now>=last.get('epoch',0)-60
    lease=s.get('maintenance',{});suppressed=now<lease.get('until',0)<=now+14400
    for key,o in observations.items():
        condition=s['conditions'].setdefault(key,{'active':False,'bad':0,'good':0,'lastNotifiedAt':0})
        if not consecutive:condition.update(bad=0,good=0)
        condition.update(detail=o['detail'],observedAt=now,severity=o['severity'])
        if o['result']=='bad':
            condition['bad']+=1;condition['good']=0
            if condition['bad']>=3:
                if not condition['active']:
                    if suppressed:condition['suppressedAt']=now;continue
                    condition.update(active=True,startedAt=now)
                    s['pending'][key]={'kind':'RAISED','condition':key,'at':now,'startedAt':now,'detail':o['detail'],'severity':o['severity']}
                elif now-condition.get('lastNotifiedAt',0)>=86400 and key not in s['pending']:
                    s['pending'][key]={'kind':'REMINDER','condition':key,'at':now,'startedAt':condition['startedAt'],'detail':o['detail'],'severity':o['severity']}
        elif o['result']=='ok':
            condition['good']+=1;condition['bad']=0
            if condition['active'] and condition['good']>=2:
                condition['active']=False
                old=s['pending'].get(key,{})
                kind='RECOVERED BEFORE DELIVERY' if old.get('kind')=='RAISED' else 'RECOVERED'
                s['pending'][key]={'kind':kind,'condition':key,'at':now,'startedAt':condition['startedAt'],
                  'detail':o['detail']+'; confirmed by two good observations.','severity':'NORMAL'}
        else:condition.update(bad=0,good=0)
    if host:
        old=s.get('hostBootId')
        if old and old!=host['bootId'] and not suppressed:
            s['pending']['reboot']={'kind':'REBOOT OBSERVED','condition':'boot_identity','at':now,'startedAt':now,'severity':'WARNING',
               'detail':'Hubble boot identity changed; current uptime='+str(host['uptimeSeconds'])+'s. Exact downtime is unknown; no restart was requested by this watchdog.'}
        s['hostBootId']=host['bootId']
    s['lastRun']={'epoch':now,'monotonic':monotonic,'piBoot':pi_boot}
    s['observations']=observations;s['version']=VERSION
    return s


def delivery_message(c,state,now,test=False):
    msg=email.message.EmailMessage()
    msg['From']=c['sender'];msg['To']=c['recipient']
    kinds=[event.get('severity') for event in state['pending'].values()]
    level='TEST' if test else ('CRITICAL' if 'CRITICAL' in kinds else ('WARNING' if 'WARNING' in kinds else 'RECOVERED'))
    msg['Subject']='[Hubble] External Availability Watchdog - '+level
    msg['Date']=email.utils.formatdate(now,localtime=True)
    digest=hashlib.sha256(json.dumps(state['pending'],sort_keys=True).encode()).hexdigest()[:24]
    msg['Message-ID']=email.utils.make_msgid(idstring='test',domain='rpi4.local') if test else '<hubble-watchdog-'+digest+'@rpi4.local>'
    lines=['Status: '+('ATTENTION' if level in {'CRITICAL','WARNING'} else 'UPDATE'),'Severity: '+level,'Summary: '+('External watchdog setup test; no outage simulated.' if test else 'Hubble availability/monitoring condition changed.'),
           '', 'Actions and findings:', 'Observer: Raspberry Pi 4 (192.168.50.100); target: Hubble (192.168.50.4).',
           'Detection: three failed observations; recovery: two good observations; healthy runs are silent.']
    labels={'availability':'Hubble reachability','probe_access':'Restricted SSH probe','web_interface':'Unraid web interface','monitor_heartbeat':'Host watchdog freshness','clock_agreement':'Pi/Hubble clock agreement','boot_identity':'Hubble reboot'}
    if test:
        for key,o in state.get('observations',{}).items():lines+=['- '+labels.get(key,key)+': '+o['result'].upper()+'; '+o['detail']]
        lines+=['','Schedule: every two minutes (Asia/Singapore).', 'State: '+c['stateDirectory'],
                'Mail: sent directly by the Pi using its existing SMTP account; Hubble did not send this message.']
    else:
        for event in state['pending'].values():
            age=max(0,now-event.get('startedAt',now))//60
            lines+=['- ['+event['kind']+'] '+labels.get(event['condition'],event['condition'])+'; observed duration='+str(age)+' minute(s).','  '+event['detail']]
    lines+=['','No server, container, network or DNS restart was performed.']
    msg.set_content('\n'.join(lines));return msg.as_bytes()


def deliver(c,s,now,test=False):
    rc,_,error=run_command([c['mailBinary'],'--account='+c['mailAccount'],'--syslog=off','--logfile=','--',c['recipient']],35,delivery_message(c,s,now,test))
    if rc:raise RuntimeError('Independent SMTP submission failed (exit='+str(rc)+'): '+error[:400])
    if test:s['testMail']={'acceptedAt':now,'scope':'SMTP server accepted submission; inbox receipt is not asserted'};return
    for event in s['pending'].values():
        condition=s['conditions'].get(event['condition'])
        if condition:condition['lastNotifiedAt']=now
        s['history'].append(dict(event,submittedAt=now))
    s['history']=s['history'][-40:];s['pending']={};s['delivery']={'lastAcceptedAt':now,'failures':0,'nextAttemptAt':0}


def log(c,level,message):
    path=pathlib.Path(c['logDirectory'])/'watchdog.log'
    secure_file(path,True)
    for n in [1,2]:secure_file(str(path)+'.'+str(n),True)
    if path.exists() and path.stat().st_size>=262144:
        second=pathlib.Path(str(path)+'.2');first=pathlib.Path(str(path)+'.1')
        if second.exists():second.unlink()
        if first.exists():os.replace(first,second)
        os.replace(path,first)
    with path.open('a') as stream:
        os.chmod(path,0o600)
        stamp=datetime.datetime.now().astimezone().isoformat(timespec='seconds')
        stream.write(stamp+' | '+level+' | hubble_availability_watchdog | '+message.replace('\n',' | ')[:2048]+'\n')


def main(argv=None):
    global ACTIVE_CONFIG
    parser=argparse.ArgumentParser(description='Independent Hubble checks on the Raspberry Pi; no automatic server actions.')
    parser.add_argument('--config',default='/etc/hubble_availability_watchdog.json')
    group=parser.add_mutually_exclusive_group()
    group.add_argument('--status',action='store_true');group.add_argument('--test-email',action='store_true')
    group.add_argument('--maintenance',type=int,metavar='MINUTES');group.add_argument('--clear-maintenance',action='store_true')
    group.add_argument('--version',action='store_true');parser.add_argument('--reason',default='Planned maintenance')
    args=parser.parse_args(argv)
    if args.version:print('hubble_availability_watchdog.sh '+VERSION);return 0
    c=load_config(args.config);ACTIVE_CONFIG=c;secure_file(c['lockFile'],True)
    fd=os.open(c['lockFile'],os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    try:
        try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:return 0
        path=pathlib.Path(c['stateDirectory'])/'state.json';secure_file(path,True)
        state=json.loads(path.read_text()) if path.exists() else initial_state()
        if state.get('schema')!=1 or not all(isinstance(state.get(k),dict) for k in ['conditions','pending','delivery','maintenance']) or not isinstance(state.get('history'),list):
            raise ValueError('Invalid persistent state; original preserved for review')
        now=int(time.time())
        if args.status:print(json.dumps(state,indent=2));return 0
        if args.maintenance is not None:
            if not 1<=args.maintenance<=240:raise ValueError('Maintenance must be 1–240 minutes')
            state['maintenance']={'until':now+60*args.maintenance,'reason':args.reason[:200]}
            atomic_json(path,state);log(c,'INFO','Timed maintenance lease set for '+str(args.maintenance)+' minutes');return 0
        if args.clear_maintenance:
            state['maintenance']={};atomic_json(path,state);log(c,'INFO','Maintenance lease cleared');return 0
        observations,host=collect(c,now)
        if args.test_email:
            preview=copy.deepcopy(state);preview['observations']=observations
            deliver(c,preview,now,True);state['testMail']=preview['testMail'];atomic_json(path,state)
            log(c,'INFO','Setup test email accepted by the independent SMTP server')
            print('Test email accepted by the Pi SMTP server.');return 0
        pi_boot=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        updated=reconcile(state,observations,host,now,pi_boot,time.monotonic())
        changed=json.dumps(state.get('pending',{}),sort_keys=True)!=json.dumps(updated['pending'],sort_keys=True)
        if changed:log(c,'WARNING' if updated['pending'] else 'INFO','Condition transitions journaled; queued='+str(len(updated['pending'])))
        # Journal before mail, so a process interruption never loses the event.
        atomic_json(path,updated)
        if updated['pending'] and now>=updated['delivery'].get('nextAttemptAt',0):
            try:
                deliver(c,updated,now);log(c,'INFO','Grouped condition notification accepted by independent SMTP server')
            except RuntimeError as exc:
                failures=updated['delivery'].get('failures',0)+1
                updated['delivery'].update(failures=failures,nextAttemptAt=now+min(3600,900*2**min(failures-1,2)))
                log(c,'ERROR',str(exc));atomic_json(path,updated);return 1
            atomic_json(path,updated)
        return 0
    finally:os.close(fd)

if __name__=='__main__':
    try:sys.exit(main())
    except Exception as error:
        print('hubble_availability_watchdog: '+str(error),file=sys.stderr)
        try:log(ACTIVE_CONFIG or {'logDirectory':'/var/log/hubble_availability_watchdog'},'ERROR',str(error))
        except Exception:pass
        sys.exit(1)
# END EXTERNAL WATCHDOG PYTHON
PY
