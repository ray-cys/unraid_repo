"""Embed historical review/reporting into the standalone media monitor."""
from pathlib import Path
r=Path(__file__).resolve().parents[1];p=r/'user_script/media_health_monitor.sh';s=p.read_text()
a='# BEGIN EMBEDDED MEDIA HEALTH REVIEW\n';b='# END EMBEDDED MEDIA HEALTH REVIEW\n'
block=a+(r/'tools/media_health_review.sh').read_text().rstrip()+'\n'+b
if a in s:
 start=s.index(a);end=s.index(b,start)+len(b);s=s[:start]+block+s[end:]
else:
 at=s.index('perform_download_ledger_reconciliation() {');s=s[:at]+block+'\n'+s[at:]
p.write_text(s)
