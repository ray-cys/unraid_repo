"""Embed the read-only native adapter so the User Script stays standalone."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
path = root / 'user_script/system_update_coordinator.sh'
text = path.read_text()
start = text.index("<<'NATIVEPHP'\n") + len("<<'NATIVEPHP'\n")
end = text.index('\nNATIVEPHP\n', start)
text = text[:start] + (root / 'tools/system_update_native.php').read_text().rstrip('\n') + text[end:]
path.write_text(text)
