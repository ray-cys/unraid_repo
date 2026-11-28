#!/bin/bash
# Ephemeral ISS helper, installed only while the shared backup lease is held.
# No flash configuration, scheduler, package or application changes.
set -u
export LC_ALL=C
root=${BASH_SOURCE[0]%/*}
token=${root##*/}
owner=/run/hubble-iss-backup.lock.owner
same_pid() {
    local line rest expected=$2
    [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ && -r /proc/$1/stat ]] || return 1
    IFS= read -r line <"/proc/$1/stat" || return 1
    rest=${line##*) };set -- $rest
    # The final supplied value follows the 20th field (kernel field 22).
    [[ ${20} == "$expected" ]]
}
start_time() { local line; IFS= read -r line <"/proc/$1/stat" || return 1; line=${line##*) };set -- $line;printf '%s\n' "${20}"; }
lease_ok() { [[ -f "$owner" && $(cat "$owner") == "$token" ]]; }
sample() {
    # One snapshot; deltas and sustained-pressure decisions belong to Hubble.
    awk '/^cpu /{for(i=2;i<=9;i++)t+=$i; print t, $5, $6}' /proc/stat
    awk '/procs_running/{r=$2}/procs_blocked/{b=$2}END{print r,b}' /proc/stat
    awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{if(t>0&&a!="")print int(100*a/t);else print -1}' /proc/meminfo
    getconf _NPROCESSORS_ONLN
}
tree() {
    local pid=$1 stamp=$2 child child_stamp
    same_pid "$pid" "$stamp" || return 0
    printf '%s %s\n' "$pid" "$stamp"
    while read -r child;do
        child_stamp=$(start_time "$child" 2>/dev/null) || continue
        tree "$child" "$child_stamp"
    done < <(ps -o pid= --ppid "$pid" 2>/dev/null)
}
apply() {
    local file pid stamp cpu io child child_stamp failed=0
    read -r cpu io <"$root/priority" || return 1
    [[ "$cpu" =~ ^(0|5|10)$ && "$io" =~ ^[467]$ ]] || return 1
    for file in "$root"/pid.*;do
        [[ -f "$file" ]] || continue
        read -r pid stamp <"$file" || continue
        if same_pid "$pid" "$stamp";then
            while read -r child child_stamp;do
                same_pid "$child" "$child_stamp" || continue
                renice -n "$cpu" -p "$child" >/dev/null 2>&1 || { same_pid "$child" "$child_stamp" && failed=1; }
                ionice -c 2 -n "$io" -p "$child" >/dev/null 2>&1 || { same_pid "$child" "$child_stamp" && failed=1; }
                if same_pid "$child" "$child_stamp";then
                    [[ $(ps -o ni= -p "$child" 2>/dev/null | tr -d ' ') == "$cpu" ]] || { same_pid "$child" "$child_stamp" && failed=1; }
                    [[ $(ionice -p "$child" 2>/dev/null) == "best-effort: prio $io" ]] || { same_pid "$child" "$child_stamp" && failed=1; }
                fi
            done < <(tree "$pid" "$stamp")
        else rm -f -- "$file";fi
    done
    return "$failed"
}
# Kernel command evidence is authoritative for runtime overrides; var.ini alone
# can still show Auto after an mdcmd override. Unknown evidence disables tuning.
write_record() {
    dmesg --notime 2>/dev/null | awk '/mdcmd \([0-9]+\): set md_write_method( |$)/{v=$0}END{if(v!="")print v;else exit 1}'
}
write_safe() {
    local parity
    local capability
    for capability in dmesg setsid nohup flock stat pgrep;do command -v "$capability" >/dev/null || return 1;done
    [[ -x /usr/local/sbin/mdcmd && -r /proc/mdstat && -r /var/local/emhttp/disks.ini ]] || return 1
    grep -q '^mdState=STARTED$' /proc/mdstat || return 1
    grep -q '^mdResync=0$' /proc/mdstat && grep -q '^mdResyncPos=0$' /proc/mdstat || return 1
    # Slots 0 and 29 are parity. No parity means no parity-write bottleneck.
    parity=$(awk -F= '/^diskSize\.(0|29)=/{s+=$2}END{print s+0}' /proc/mdstat)
    ((parity>0)) || return 2
    awk -F= '/^diskSize\./{split($1,a,".");size[a[2]]=$2}/^diskState\./{split($1,a,".");state[a[2]]=$2}END{for(i in size)if(size[i]>0&&state[i]!=7)exit 1}' /proc/mdstat || return 1
    [[ ! -e /var/run/mover.pid && ! -d /usr/local/emhttp/plugins/ca.turbo ]] || return 1
    ! pgrep -f '^/bin/bash /usr/local/sbin/mover|^/usr/local/sbin/mover' >/dev/null
}
write_set() { /usr/local/sbin/mdcmd set md_write_method "$1"; }
write_restore() {
    local current applied original
    [[ -f "$root/write.original" ]] || return 0
    exec 8>"$root/write.lock";flock -x 8 || return 1
    original=$(cat "$root/write.original")
    if ! applied=$(cat "$root/write.applied" 2>/dev/null);then
        current=$(write_record) || return 1
        if [[ -f "$root/write.before" && "$current" == "$(cat "$root/write.before")" ]];then
            printf 'Reconstruct Write override was not applied; original mode unchanged\n' >"$root/write.status"
            rm -f "$root/write.original";return 0
        fi
        printf 'restoration unverified: apply receipt unavailable\n' >"$root/write.status";return 1
    fi
    current=$(write_record) || { printf 'restoration unverified: kernel evidence unavailable\n' >"$root/write.status";return 1; }
    if [[ "$current" != "$applied" ]];then
        printf 'administrator/other writer changed runtime mode; later setting preserved\n' >"$root/write.status"
        rm -f "$root/write.original";return 0
    fi
    write_set "$original" || return 1
    current=$(write_record) || return 1
    [[ "$current" == *": set md_write_method $original" ]] || return 1
    printf 'Reconstruct Write restored to previous runtime mode=%s; flash configuration unchanged\n' "$original" >"$root/write.status"
    rm -f "$root/write.original"
}
write_begin() {
    local safe=0 before original after
    write_safe || safe=$?
    if ((safe==2));then printf 'Reconstruct Write skipped: ISS has no parity disks; no write-mode benefit\n' >"$root/write.status";return 0;fi
    if ((safe!=0));then printf 'Reconstruct Write skipped: array/maintenance/competing controller safety guard\n' >"$root/write.status";return 0;fi
    before=$(write_record) || { printf 'Reconstruct Write skipped: current kernel mode unverified\n' >"$root/write.status";return 0; }
    original=${before##*md_write_method};original=${original# }
    [[ -n "$original" ]] || original=auto
    case "$original" in auto|0|1) ;; *) return 1;; esac
    if [[ "$original" == 1 ]];then printf 'Reconstruct Write already enabled; existing mode retained\n' >"$root/write.status";return 0;fi
    touch "$root/heartbeat"
    printf '%s\n' "$before" >"$root/write.before"
    printf '%s\n' "$original" >"$root/write.original"
    # This guardian outlives a lost SSH/client process, but has no cron/startup hook.
    nohup setsid bash "$root/helper" guard </dev/null >"$root/guard.log" 2>&1 &
    local guardian=$! guardian_start attempt
    guardian_start=$(start_time "$guardian") || { rm -f "$root/write.original";return 1; }
    printf '%s %s\n' "$guardian" "$guardian_start" >"$root/guard.pid"
    for ((attempt=0;attempt<50;attempt++));do [[ ! -f "$root/guard.ready" ]] || break;sleep 0.1;done
    if [[ ! -f "$root/guard.ready" ]] || ! same_pid "$guardian" "$guardian_start";then rm -f "$root/write.original";return 1;fi
    write_set 1 || return 1
    after=$(write_record) || return 1
    [[ "$after" != "$before" && "$after" == *': set md_write_method 1' ]] || return 1
    printf '%s\n' "$after" >"$root/write.applied"
    printf 'Reconstruct Write temporarily enabled on ISS; previous mode=%s; heartbeat guardian active\n' "$original" >"$root/write.status"
}
cleanup_run() {
      local failed=0 file pid stamp i
      for file in "$root"/pid.*;do
          [[ -f "$file" ]] || continue;read -r pid stamp <"$file" || continue
          if same_pid "$pid" "$stamp";then
              kill -TERM "$pid" 2>/dev/null || true
              for ((i=0;i<10;i++));do same_pid "$pid" "$stamp" || break;sleep 1;done
              same_pid "$pid" "$stamp" && failed=1
          fi
      done
      ((failed==0)) || return 75
      write_restore || return 75
      if [[ -f "$root/guard.pid" ]];then read -r pid stamp <"$root/guard.pid";same_pid "$pid" "$stamp" && kill -TERM "$pid" 2>/dev/null || true;fi
      rm -rf -- "$root"
}
case ${1:-} in
 guard) # No inherited transport, lock or producer descriptors may keep a lease alive.
        for fd in /proc/$$/fd/*;do n=${fd##*/};[[ "$n" =~ ^[0-9]+$ ]] || continue;((n<3||n==255)) || eval "exec $n>&-";done
        touch "$root/guard.ready"
        while [[ -d "$root" && -f "$root/write.original" ]];do
            age=$(( $(date +%s)-$(stat -c %Y "$root/heartbeat" 2>/dev/null || echo 0) ))
            if ! lease_ok || ((age>120)) || ! write_safe;then write_restore;exit $?;fi
            sleep 10
        done;;
 reconcile) # A new exclusive lease may finish an orphaned prior override.
        lease_ok && exit 75
        cleanup_run;;
 write-begin) lease_ok || exit 75;write_begin;rc=$?;cat "$root/write.status" 2>/dev/null;exit "$rc";;
 write-end) lease_ok || exit 75;write_restore || exit 1;cat "$root/write.status";;
 sample) lease_ok || exit 75;touch "$root/heartbeat"; sample;;
 tune) lease_ok || exit 75;[[ ${2:-} =~ ^(0|5|10)$ && ${3:-} =~ ^[467]$ ]] || exit 64
       printf '%s %s\n' "$2" "$3" >"$root/priority.new";mv -f "$root/priority.new" "$root/priority";apply;;
 run) shift;lease_ok || exit 75
      case ${1:-} in rsync|sha256sum) ;; *) exit 64;; esac
      stamp=$(start_time "$$") || exit 1
      printf '%s %s\n' "$$" "$stamp" >"$root/pid.$$"
      read -r cpu io <"$root/priority" || exit 1
      # exec retains PID/start identity; children inherit these initial priorities.
      exec nice -n "$cpu" ionice -c 2 -n "$io" "$@";;
 cleanup) lease_ok || exit 75;cleanup_run;;
 *) exit 64;;
esac
