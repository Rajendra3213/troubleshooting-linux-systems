#!/usr/bin/env bash
set -euo pipefail

INTERVAL="${1:-5}"
CORES="${2:-$(nproc)}"

RUNQ_WARN_F="${RUNQ_WARN_F:-1.0}"
RUNQ_CRIT_F="${RUNQ_CRIT_F:-2.0}"
LOAD_WARN_F="${LOAD_WARN_F:-0.7}"
LOAD_CRIT_F="${LOAD_CRIT_F:-1.0}"
CPU_WARN="${CPU_WARN:-80}"
CPU_CRIT="${CPU_CRIT:-90}"
IOWAIT_WARN="${IOWAIT_WARN:-10}"
IOWAIT_CRIT="${IOWAIT_CRIT:-20}"
STEAL_WARN="${STEAL_WARN:-5}"
MEM_WARN="${MEM_WARN:-15}"
MEM_CRIT="${MEM_CRIT:-5}"
CS_WARN_PER_CORE="${CS_WARN_PER_CORE:-20000}"
DISK_WARN="${DISK_WARN:-80}"
DISK_CRIT="${DISK_CRIT:-90}"
INODE_WARN="${INODE_WARN:-85}"

C_HDR=$'\033[1;36m'
C_GRP=$'\033[1;33m'
C_OK=$'\033[0;32m'
C_WARN=$'\033[1;33m'
C_CRIT=$'\033[1;31m'
C_DIM=$'\033[2m'
RESET=$'\033[0m'

gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>b+0)}'; }
fdiv() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", (b+0==0?0:a/b)}'; }

ISSUES=()
add_issue() { ISSUES+=("$1|$2|$3"); }

row() {
  local label="$1" value="$2" state="${3:-ok}" c
  case "$state" in
    crit) c="$C_CRIT" ;;
    warn) c="$C_WARN" ;;
    *)    c="" ;;
  esac
  if [ -n "$c" ]; then
    printf '  %-18s: %s%s%s\n' "$label" "$c" "$value" "$RESET"
  else
    printf '  %-18s: %s\n' "$label" "$value"
  fi
}

state_for() {
  local v="$1" w="$2" c="$3"
  if gt "$v" "$c"; then echo crit
  elif gt "$v" "$w"; then echo warn
  else echo ok; fi
}

while true; do
  DATA=$(vmstat -S M 1 2 | tail -1)
  read -r r b swpd free buff cache si so bi bo intr cs us sy id wa st _rest <<< "$DATA"
  read -r la1 la5 la15 _ < /proc/loadavg

  MEM_TOTAL=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
  MEM_AVAIL=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo)
  MEM_AVAIL_PCT=$(awk -v a="$MEM_AVAIL" -v t="$MEM_TOTAL" 'BEGIN{printf "%.1f", (t==0?0:a*100/t)}')

  CPU_BUSY=$(( 100 - id ))
  RUNQ_RATIO=$(fdiv "$r" "$CORES")
  LOAD_RATIO=$(fdiv "$la1" "$CORES")
  CS_LIMIT=$(( CS_WARN_PER_CORE * CORES ))

  ISSUES=()

  S_RUNQ=$(state_for "$RUNQ_RATIO" "$RUNQ_WARN_F" "$RUNQ_CRIT_F")
  S_LOAD=$(state_for "$LOAD_RATIO" "$LOAD_WARN_F" "$LOAD_CRIT_F")
  S_CPU=$(state_for "$CPU_BUSY" "$CPU_WARN" "$CPU_CRIT")
  S_WA=$(state_for "$wa" "$IOWAIT_WARN" "$IOWAIT_CRIT")
  S_ST=$(state_for "${st:-0}" "$STEAL_WARN" "$(( STEAL_WARN * 2 ))")
  S_CS=$(state_for "$cs" "$CS_LIMIT" "$(( CS_LIMIT * 2 ))")
  S_BLK=ok; [ "$b" -gt 0 ] && S_BLK=warn
  [ "$b" -gt "$CORES" ] && S_BLK=crit
  S_SWAP=ok
  if [ "$si" -gt 0 ] || [ "$so" -gt 0 ]; then S_SWAP=crit; fi

  S_MEM=ok
  if ! gt "$MEM_AVAIL_PCT" "$MEM_CRIT"; then S_MEM=crit
  elif ! gt "$MEM_AVAIL_PCT" "$MEM_WARN"; then S_MEM=warn; fi

  [ "$S_RUNQ" != ok ] && add_issue "$S_RUNQ" "CPU run queue: ${r} runnable vs ${CORES} cores (${RUNQ_RATIO}x)" "pidstat -u 1 5 | sort -k8 -nr | head; top -H -b -n1 | head -20"
  [ "$S_LOAD" != ok ] && add_issue "$S_LOAD" "Load average ${la1} on ${CORES} cores (${LOAD_RATIO}x)" "uptime; ps -eo pid,ppid,stat,pcpu,comm --sort=-pcpu | head"
  [ "$S_CPU" != ok ] && add_issue "$S_CPU" "CPU busy ${CPU_BUSY}% (us=${us} sy=${sy})" "pidstat -u 1 5; perf top"
  [ "$S_WA" != ok ] && add_issue "$S_WA" "iowait ${wa}% - disk bound" "iostat -xz 1 5; pidstat -d 1 5; iotop -bon3"
  [ "$S_BLK" != ok ] && add_issue "$S_BLK" "${b} processes blocked on IO" "ps -eo pid,stat,wchan:24,comm | awk '\$2 ~ /D/'"
  [ "$S_SWAP" != ok ] && add_issue crit "Active swapping (si=${si}MB/s so=${so}MB/s)" "smem -rs swap | head; ps -eo pid,rss,comm --sort=-rss | head; cat /proc/pressure/memory"
  [ "$S_MEM" != ok ] && add_issue "$S_MEM" "Only ${MEM_AVAIL}MB (${MEM_AVAIL_PCT}%) available of ${MEM_TOTAL}MB" "free -m; ps -eo pid,rss,comm --sort=-rss | head; slabtop -o | head"
  [ "$S_CS" != ok ] && add_issue "$S_CS" "Context switches ${cs}/s exceeds ${CS_LIMIT} for ${CORES} cores" "pidstat -w 1 5; vmstat 1"
  [ "$S_ST" != ok ] && add_issue "$S_ST" "CPU steal ${st}% - hypervisor contention" "mpstat -P ALL 1 5"

  DISK_ROWS=""
  while read -r fs size used avail pct mnt; do
    p="${pct%\%}"
    s=$(state_for "$p" "$DISK_WARN" "$DISK_CRIT")
    DISK_ROWS+="${mnt}|${used}/${size} (${pct}) free ${avail}|${s}"$'\n'
    [ "$s" != ok ] && add_issue "$s" "Disk ${mnt} at ${pct} (${avail} free)" "du -xhd1 ${mnt} 2>/dev/null | sort -rh | head; lsof +L1 | head"
  done < <(df -hP -x tmpfs -x devtmpfs -x squashfs -x iso9660 2>/dev/null | tail -n +2)

  while read -r fs inodes iused ifree ipct mnt; do
    p="${ipct%\%}"
    [ "$p" = "-" ] && continue
    if gt "$p" "$INODE_WARN"; then
      add_issue warn "Inodes ${mnt} at ${ipct}" "find ${mnt} -xdev -type f -printf '%h\\n' | sort | uniq -c | sort -rn | head"
    fi
  done < <(df -iP -x tmpfs -x devtmpfs -x squashfs -x iso9660 2>/dev/null | tail -n +2)

  clear
  printf '%svmstat monitor%s  %s  (cores: %s, interval: %ss, Ctrl+C to quit)\n\n' \
    "$C_HDR" "$RESET" "$(date '+%Y-%m-%d %H:%M:%S')" "$CORES" "$INTERVAL"

  if [ "${#ISSUES[@]}" -eq 0 ]; then
    printf '%sVERDICT%s  %sHEALTHY%s - no threshold exceeded\n\n' "$C_GRP" "$RESET" "$C_OK" "$RESET"
  else
    printf '%sVERDICT%s\n' "$C_GRP" "$RESET"
    for i in "${ISSUES[@]}"; do
      IFS='|' read -r st_ msg hint <<< "$i"
      if [ "$st_" = crit ]; then printf '  %s[CRIT]%s %s\n' "$C_CRIT" "$RESET" "$msg"
      else printf '  %s[WARN]%s %s\n' "$C_WARN" "$RESET" "$msg"; fi
      printf '         %s-> %s%s\n' "$C_DIM" "$hint" "$RESET"
    done
    printf '\n'
  fi

  printf '%sPROCS%s\n' "$C_GRP" "$RESET"
  row "runnable" "$r  (${RUNQ_RATIO}x cores)" "$S_RUNQ"
  row "blocked (IO)" "$b" "$S_BLK"
  row "load 1/5/15" "$la1 / $la5 / $la15  (${LOAD_RATIO}x)" "$S_LOAD"
  printf '\n'

  printf '%sMEMORY (MB)%s\n' "$C_GRP" "$RESET"
  row "total" "$MEM_TOTAL"
  row "available" "$MEM_AVAIL  (${MEM_AVAIL_PCT}%)" "$S_MEM"
  row "free" "$free"
  row "buffers" "$buff"
  row "cache" "$cache"
  row "swap used" "$swpd"
  printf '\n'

  printf '%sSWAP (MB/s)%s\n' "$C_GRP" "$RESET"
  row "swap in" "$si" "$S_SWAP"
  row "swap out" "$so" "$S_SWAP"
  printf '\n'

  printf '%sIO (blocks/s)%s\n' "$C_GRP" "$RESET"
  row "read" "$bi"
  row "write" "$bo"
  printf '\n'

  printf '%sDISK%s\n' "$C_GRP" "$RESET"
  while IFS='|' read -r m v s; do
    [ -z "${m:-}" ] && continue
    row "$m" "$v" "$s"
  done <<< "$DISK_ROWS"
  printf '\n'

  printf '%sSYSTEM%s\n' "$C_GRP" "$RESET"
  row "interrupts/s" "$intr"
  row "ctx switches/s" "$cs  (limit ${CS_LIMIT})" "$S_CS"
  printf '\n'

  printf '%sCPU (%%)%s\n' "$C_GRP" "$RESET"
  row "busy" "$CPU_BUSY" "$S_CPU"
  row "user" "$us"
  row "system" "$sy"
  row "idle" "$id"
  row "iowait" "$wa" "$S_WA"
  row "stolen" "${st:-0}" "$S_ST"

  sleep "$INTERVAL"
done
