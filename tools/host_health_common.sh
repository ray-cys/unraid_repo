# shellcheck shell=bash
# Shared read-only host/storage parsers. Embedded in standalone User Scripts.
HH_TIMEZONE="${HH_TIMEZONE:-Asia/Singapore}"
hh_mount_info() {
    local mount="$1" value fs options
    value=$(timeout --kill-after=1 4 findmnt -rn -M "$mount" -o FSTYPE,OPTIONS 9>&- 2>/dev/null) || value=''
    read -r fs options <<< "$value"
    if [[ -z "$fs" ]];then printf '{"mounted":false,"readOnly":false,"type":""}\n';return;fi
    jq -nc --arg fs "$fs" --arg options "$options" '{mounted:true,type:$fs,readOnly:($options|split(",")|index("ro")!=null)}'
}
hh_array_state() {
    awk -F= 'tolower($1)=="mdstate" {gsub(/[" \r]/,"",$2);print tolower($2);exit}' "${HH_VAR_INI:-/var/local/emhttp/var.ini}" 2>/dev/null
}
hh_expected_mounts() {
    printf '/boot\n'
    [[ "$(hh_array_state)" == started ]] || return 0
    awk -F= '
      function emit(){if(slot ~ /^[A-Za-z0-9_.-]+$/ && (type=="Data" || type=="Cache") && fs!="" && (device!="" || identity!="" || assigned!="" || status=="DISK_DSBL" || status=="DISK_MISSING"))print "/mnt/"slot}
      /^\[/{emit();slot=$0;gsub(/[\[\]"\r]/,"",slot);type=fs=device=status=identity=assigned="";next}
      {v=$2;gsub(/["\r]/,"",v)} $1=="type"{type=v} $1=="fsType"{fs=v} $1=="device"{device=v} $1=="status"{status=v} $1=="id"{identity=v} $1=="idSb"{assigned=v} END{emit()}
    ' "${HH_DISKS_INI:-/var/local/emhttp/disks.ini}" 2>/dev/null
    if grep -Eqi '^DOCKER_ENABLED="?(yes|true|1)"?$' "${HH_DOCKER_CFG:-/boot/config/docker.cfg}" 2>/dev/null;then printf '/var/lib/docker\n';fi
}
hh_btrfs_metrics() {
    local usage="$1" show="${2:-}" parsed missing=false
    grep -qiE 'Some devices missing|path[[:space:]]+missing' <<< "$show" && missing=true
    parsed=$(awk '
      function number(s){gsub(/[^0-9]/,"",s);return s+0}
      /^ *Device size:/{size=number($3);gotSize=1}
      /^ *Device unallocated:/{unallocated=number($3);gotUnallocated=1}
      /^ *Device missing:/{missing=number($3);gotMissing=1}
      /^ *Free \(estimated\):/{free=number($3);gotFree=1}
      /^ *Global reserve:/{reserve=number($5)}
      /^Metadata,/{split($2,a,":");split($3,b,":");meta+=number(a[2]);used+=number(b[2]);gotMeta=1}
      END{printf "{\"valid\":%s,\"deviceBytes\":%.0f,\"unallocatedBytes\":%.0f,\"missingBytes\":%.0f,\"estimatedFreeBytes\":%.0f,\"metadataBytes\":%.0f,\"metadataUsedBytes\":%.0f,\"reserveUsedBytes\":%.0f}",
        (gotSize&&gotUnallocated&&gotMissing&&gotFree&&gotMeta&&meta>0?"true":"false"),size,unallocated,missing,free,meta,used,reserve}
    ' <<< "$usage") || return 1
    jq -c --argjson absent "$missing" '.+{missingMembers:$absent,metadataPercent:(if .metadataBytes>0 then 100*.metadataUsedBytes/.metadataBytes else null end)} |
      .+{severity:(if (.missingBytes>0 or .missingMembers) then "critical"
         elif .valid!=true then "unknown"
         elif (.metadataPercent>=95 and .unallocatedBytes<([1073741824,2*.metadataBytes]|max)) then
           (if .metadataPercent>=99 and .reserveUsedBytes>0 then "critical" else "warning" end)
         else "ok" end)}' <<< "$parsed"
}
# A cron deadline is computed from the actual native schedule, using local time.
# Supports lists, ranges, steps, Sunday 0/7 and standard DOM/DOW OR semantics.
hh_cron_last_due() {
    local expression="$1" now="$2"
    php /dev/stdin "$expression" "$now" "$HH_TIMEZONE" <<'PHP'
<?php
function field($s,$min,$max,$dow=false){$out=[];foreach(explode(',',$s)as$p){$parts=explode('/',$p);if(count($parts)>2)return null;$step=$parts[1]??'1';if(!ctype_digit($step)||intval($step)<1)return null;$base=$parts[0];
if($base==='*'){ $a=$min;$b=$max; }elseif(preg_match('/^(\d+)-(\d+)$/',$base,$m)){ $a=intval($m[1]);$b=intval($m[2]); }elseif(ctype_digit($base)){ $a=intval($base);$b=count($parts)>1?$max:$a; }else return null;
if($a<$min||$b>$max||$a>$b)return null;for($i=$a;$i<=$b;$i+=intval($step))$out[$dow&&$i===7?0:$i]=true;}return $out;}
$e=preg_split('/\s+/',trim($argv[1]));$now=intval($argv[2]);try{$tz=new DateTimeZone($argv[3]);}catch(Throwable $x){echo '{"valid":false}';exit;}
if(count($e)!==5){echo '{"valid":false}';exit;}$bounds=[[0,59],[0,23],[1,31],[1,12],[0,7]];$f=[];foreach($e as$i=>$s){$v=field($s,$bounds[$i][0],$bounds[$i][1],$i===4);if($v===null){echo '{"valid":false}';exit;}$f[]=$v;}
$base=(new DateTimeImmutable('@'.$now))->setTimezone($tz)->setTime(0,0);$hours=array_keys($f[1]);$minutes=array_keys($f[0]);rsort($hours);rsort($minutes);
for($d=0;$d<=400;$d++){$day=$base->modify('-'.$d.' days');if(!isset($f[3][intval($day->format('n'))]))continue;
$dom=isset($f[2][intval($day->format('j'))]);$dow=isset($f[4][intval($day->format('w'))]);$domStar=str_starts_with($e[2],'*');$dowStar=str_starts_with($e[4],'*');
$match=$domStar&&$dowStar?($dom&&$dow):($domStar?$dow:($dowStar?$dom:($dom||$dow)));if(!$match)continue;
foreach($hours as$h)foreach($minutes as$m){$t=$day->setTime($h,$m)->getTimestamp();if($t<=$now){echo json_encode(['valid'=>true,'dueEpoch'=>$t,'dueLocal'=>$day->setTime($h,$m)->format('Y-m-d H:i:s T')]);exit;}}}
echo '{"valid":true,"dueEpoch":0}';
PHP
}
hh_fast_receipt_owns() {
    local id="$1" now="$2" file="${HH_FAST_RECEIPT:-/run/syslog-host-health.json}" boot
    [[ -f "$file" && ! -L "$file" && $(stat -c %u "$file" 2>/dev/null) == "$EUID" && $(stat -c %h "$file" 2>/dev/null) == 1 ]] || return 1
    boot=$(cat /proc/sys/kernel/random/boot_id)
    jq -e --arg id "$id" --arg boot "$boot" --argjson now "$now" '.schema==1 and .status=="COMPLETE" and .bootId==$boot and .observedAt<=$now+60 and .observedAt>=$now-900 and any(.observations[]; .id==$id and (.severity|IN("ok","warning","critical")))' "$file" >/dev/null 2>&1
}
