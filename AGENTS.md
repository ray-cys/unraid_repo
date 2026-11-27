# Unraid User Script releases

For every deployed script code change, increment its top-level release number
and regenerate `user_script/versions.json` with `python3 tools/script_versions.py
--write`. Run `python3 tools/script_versions.py` before committing. Preserve
individual existing versions; do not reset all scripts to one common version.
The live deployment registry must record release version, code hash and commit.
Keep the consolidated `docs/user-scripts-cli.md` reference current whenever
a public command, option or CLI side effect changes.

Current live User Scripts description files are authoritative user wording.
Preserve them byte for byte for routine releases. Do not add versions, schedules,
release notes or CLI examples to descriptions. Keep detailed documentation in
script headers or repository docs. Do not change Docker images, startup settings
or application configuration as part of script maintenance.
