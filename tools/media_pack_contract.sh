# shellcheck shell=bash
# Shared pack contract v1; no source is disposable from a filename/title hint.
pack_document_valid() {
    jq -e '
      def pos:type=="number" and .>0 and .==floor;
      def relative:type=="string" and length>0 and (startswith("/")|not) and (test("(^|/)\\.\\.?(/|$)|//|[\\\\\u0000\n\r\t]")|not);
      .schema==1 and (.jobs|type)=="object" and (.jobs|length)<=128 and all(.jobs|to_entries[];
       .key as $id|.value|.app=="Sonarr" and .downloadId==$id and ($id|test("^[a-z0-9-]+$")) and (.createdAt|pos) and
       (.status as $s|["observing","blocked","queue_intent","queue_verified","resolved","review","manual_hold"]|index($s))!=null
      )' "$1" >/dev/null 2>&1
}
# Validate the immutable disposal plan independently of mutable lifecycle fields.
pack_plan_valid() {
    jq -e '
      def pos:type=="number" and .>0 and .==floor;
      def relative:type=="string" and length>0 and (startswith("/")|not) and (test("(^|/)\\.\\.?(/|$)|//|[\\\\\u0000\n\r\t]")|not);
      . as $plan|.app=="Sonarr" and (.downloadId|test("^[a-z0-9-]+$")) and (.seriesId|pos) and (.tvdbId|pos) and
      (.profileSignature|test("^[a-f0-9]{64}$")) and (.folder|startswith("/")) and (.source.fingerprint|test("^[a-f0-9]{64}$")) and
      (.source.complete==true) and (.source.files|type)=="array" and (.source.files|length)<=800 and (.source.directories|type)=="array" and (.source.directories|length)<=512 and .source.folder==.folder and (.files|type)=="array" and (.files|length)>0 and (.files|length)<=200 and
      (.targets|type)=="object" and (.targets|length)>0 and (.targets|length)<=40 and
      all(.targets|to_entries[];.key as $key|.value|(.id|pos) and (.id|tostring)==$key and (.seasonNumber|type)=="number" and .seasonNumber>=0 and (.episodeNumber|pos)) and
      all(.files[];(.relative|relative) and (.identity|test("^[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+$")) and (.size|pos) and (.episodeIds|length)>0 and
        all(.episodeIds[];pos and ($plan.targets[tostring]!=null)) and (.disposition as $s|["redundant","rejected","required","unknown"]|index($s))!=null) and
      ([.files[].relative]|unique|length)==(.files|length) and
      ([.source.files[].relative]|unique|length)==(.source.files|length) and
      ([.files[].relative]|sort)==([.source.files[]|select(.video)|.relative]|sort) and
      all(.files[];. as $f|any($plan.source.files[];.relative==$f.relative and .identity==$f.identity and .size==$f.size and .video==true)) and
      (.queueIds|type)=="array" and (.queueIds|length)>0 and all(.queueIds[];pos) and
      (.accounted|type)=="boolean" and (.unknown|type)=="boolean" and
      all(.source.files[];(.relative|relative) and (.identity|type)=="string" and (.size|type)=="number" and .size>=0 and (.video|type)=="boolean")' "$1" >/dev/null 2>&1
}
pack_source_inventory() {
    local folder="$1" root="$2" output="$3" input="${TMP_DIR:?}/pack-inventory-input.json"
    jq -n --arg folder "$folder" --arg root "$root" '{folder:$folder,root:$root}' >"$input" || return 1
    timeout --kill-after=2 20 docker exec -i --user 99:100 "${SAB_CONTAINER:-sabnzbd}" python3 -I -c "$(pack_inventory_program)" <"$input" >"$output" 2>"$TMP_DIR/pack-inventory.err" || return 1
    jq -e --arg folder "$folder" '.schema==1 and .complete==true and .folder==$folder and (.files|type)=="array" and (.files|length)<=800' "$output" >/dev/null
}
pack_profile_signature() {
    jq -nSc --slurpfile p "$1" --slurpfile f "$2" '{profiles:[$p[0]|sort_by(.id)[]|{id,cutoff,upgradeAllowed,minFormatScore,cutoffFormatScore,minUpgradeFormatScore,items,formatItems}],formats:[$f[0]|sort_by(.id)[]|{id,specifications,includeCustomFormatWhenRenaming}]}' |sha256sum|cut -d ' ' -f1
}
pack_repair_held() {
    local parent="$1" file="${MEDIA_INTEGRITY_RECOVERY_FILE:-/mnt/vault/cloud/logs/script/media_integrity_audit/recovery.json}"
    [[ -f "$file" && ! -L "$file" ]] || return 0
    jq -e '.schema==1 and .workflow=="arr-native" and (.actions|type)=="object" and all(.actions[];(.app=="Sonarr" or .app=="Radarr") and (.parentId|type)=="number" and .parentId>0 and (.status as $s|["required","selected","grab_intent","downloading","imported","verifying","recovered","blocked","review","cancelled","resolved","retry_wait"]|index($s))!=null)' "$file" >/dev/null || return 0
    local rc=0
    jq -e --argjson parent "$parent" 'any(.actions[];.app=="Sonarr" and .parentId==$parent and (.status as $s|["recovered","resolved","cancelled"]|index($s))==null)' "$file" >/dev/null || rc=$?
    ((rc!=1))
}
