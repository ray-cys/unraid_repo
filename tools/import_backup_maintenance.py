"""One-time import of completed-backup downtime, cross-checked against Docker timestamps."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
from zoneinfo import ZoneInfo


def epoch(value):
    value = re.sub(r'(\.\d{6})\d+', r'\1', value)
    return int(datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp())


def windows(receipt, containers, log, boot, now):
    if not (receipt.get('schema') == 1 and receipt.get('name') == 'backup_cache_appdata'
            and receipt.get('executionStatus') == 'COMPLETED' and receipt.get('lastExitCode') == 0
            and receipt.get('boot') == boot):
        raise ValueError('No verified same-boot successful backup receipt')
    start, end = receipt['startedAt'], receipt['finishedAt']
    if not 0 < start <= end <= now or now - end > 14 * 86400:
        raise ValueError('Backup receipt timing is invalid/stale')
    lines = []
    for line in log.splitlines():
        match = re.match(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \| INFO \| backup_cache_appdata \| .*? \| (.*)$', line)
        if match:
            at = int(datetime.strptime(match[1], '%Y-%m-%d %H:%M:%S').replace(tzinfo=ZoneInfo('Asia/Singapore')).timestamp())
            lines.append((at, match[2]))
    if not any(abs(at - start) <= 2 and 'Scheduled appdata backup started' in line for at, line in lines):
        raise ValueError('Log does not match this backup start')
    if not any(start <= at <= end and 'Appdata backup verified and finalized:' in line for at, line in lines):
        raise ValueError('No successful generation promotion in matching log')
    output = {}
    digest = hashlib.sha256(log.encode()).hexdigest()
    for container in containers:
        name = container['Name'].lstrip('/')
        if name not in ('plex-media-server', 'plex-media') or not container['State']['Running']:
            continue
        stopped = epoch(container['State']['FinishedAt'])
        restarted = epoch(container['State']['StartedAt'])
        if not start <= stopped < restarted <= end:
            continue
        stop = any(abs(at - stopped) <= 2 and line.endswith('Stopped owning container: ' + name) for at, line in lines)
        ready = any(restarted <= at <= min(end, restarted + 180) and ('Container started: ' + name + '; readiness result=0;') in line for at, line in lines)
        if not stop or not ready:
            continue
        key = hashlib.sha256(f"{boot}|{name}|{container['Id']}|{stopped}".encode()).hexdigest()
        output[key] = dict(id=key, container=name, containerId=container['Id'], boot=boot,
                           startedAt=stopped, endedAt=restarted, observedAt=now, target='',
                           source='completed-backup-receipt-log-and-native-docker', reason='appdata backup',
                           evidence=dict(backupStartedAt=start, backupFinishedAt=end, logSha256=digest))
    return output


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('receipt', 'docker', 'log', 'boot', 'output'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--now', type=int, default=int(datetime.now(timezone.utc).timestamp()))
    args = p.parse_args()
    output = windows(json.loads(Path(args.receipt).read_text()), json.loads(Path(args.docker).read_text()), Path(args.log).read_text(), args.boot, args.now)
    if not output:
        raise ValueError('No exact maintenance window could be proven')
    Path(args.output).write_text(json.dumps(output, indent=2) + '\n')
    print(f'Verified {len(output)} exact Plex maintenance interval(s); no state changed')


if __name__ == '__main__':
    main()
