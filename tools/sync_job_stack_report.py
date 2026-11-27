from pathlib import Path
root=Path(__file__).resolve().parents[1]
p=root/'user_script/media_metadata_audit.sh';s=p.read_text();a='# BEGIN SCHEDULED JOB WEEKLY REPORT';b='# END SCHEDULED JOB WEEKLY REPORT'
block=a+'\n'+(root/'tools/job_stack_report.py').read_text()+b+'\n'
if a in s:s=s[:s.index(a)]+block+s[s.index(b)+len(b)+1:]
else:s=s.replace('\nmf_blocks,mf_email_blocks,mf_summary', '\n'+block+'\nmf_blocks,mf_email_blocks,mf_summary',1)
p.write_text(s)
