"""Build/check the version inventory; --version must work without external commands."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "user_script/versions.json"
MARKER = "# Release version: bump for every deployed code change; descriptions stay user-owned."


def inventory():
    result = {}
    for path in sorted((ROOT / "user_script").glob("*.sh")):
        header = "\n".join(path.read_text().splitlines()[:12])
        if MARKER not in header:
            continue  # Archived reference scripts are outside the live release set.
        match = re.search(r'^(?:readonly )?(SCRIPT_VERSION|MC_VERSION|VERSION)="(\d+\.\d+\.\d+)"$', header, re.M)
        if not match:
            raise ValueError(f"Missing top-level release number: {path.name}")
        result[path.stem] = {"version": match[2], "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="Regenerate the release inventory after bumping changed scripts")
    parser.add_argument("--bash", default="/bin/bash", help="Bash executable for safe CLI checks")
    args = parser.parse_args()
    found = inventory()
    if args.write:
        MANIFEST.write_text(json.dumps({"schema": 1, "scripts": found}, indent=2) + "\n")
    saved = json.loads(MANIFEST.read_text())["scripts"]
    if found != saved:
        raise ValueError("Release inventory differs from scripts; bump changed versions and regenerate with --write")
    # No external commands, host configuration or producer calls may precede --version.
    # An empty PATH catches accidental dependencies; private working/HOME dirs isolate tests.
    with tempfile.TemporaryDirectory() as temp:
        for name, item in found.items():
            path = ROOT / "user_script" / (name + ".sh")
            env = {"PATH": "", "HOME": temp, "TMPDIR": temp, "LC_ALL": "C"}
            run = subprocess.run([args.bash, str(path), "--version"], cwd=temp, env=env,
                                 text=True, capture_output=True, timeout=8, check=True)
            expected = f"{name}.sh {item['version']}\n"
            if run.stdout != expected or run.stderr:
                raise ValueError(f"Version CLI mismatch: {name}: {run.stdout!r} {run.stderr!r}")
            subprocess.run([args.bash, "-n", str(path)], check=True, capture_output=True)
            print(expected.rstrip())
        if list(Path(temp).iterdir()):
            raise ValueError("Version queries created files")
    print(f"Verified {len(found)} releases: inventory hashes, Bash syntax and side-effect-free version CLI")


if __name__ == "__main__":
    main()
