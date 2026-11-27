# User Script release versions

Each of the 18 live scripts declares its release version immediately below the
interpreter line. `--version` returns before logging, locking, state access,
Docker calls or network activity. Run the installed User Script through Bash:

```bash
/bin/bash /boot/config/plugins/user.scripts/scripts/media_metadata_audit/script --version
```

The current release inventory is [versions.json](../user_script/versions.json).
It pairs each script's release number with its SHA-256 code hash. The live
`user_scripts_status/deployments.json` records the deployed release, code hash
and Git commit; execution receipts reflect the release when their producer next
runs. Existing historical receipts are retained as historical evidence.

For every code change, bump the script's release number: patch for fixes or
presentation changes, minor for new behavior and major for incompatible changes.
Keep release declarations outside embedded shared-code blocks so generators do
not overwrite them. `media_cleanup` has one public wrapper release; embedded
component releases describe those components separately.

Before deployment, regenerate and check the inventory:

```bash
python3 tools/script_versions.py --write
python3 tools/script_versions.py
```

The check compares all release hashes, parses Bash syntax and runs each version
query with an empty command search path. Existing User Scripts descriptions,
schedules, application configuration and operational state are independent of
release metadata and must be preserved.
