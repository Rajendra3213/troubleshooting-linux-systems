#!/usr/bin/env bash
set -euo pipefail

INTERVAL="${1:-5}"

C_HDR=$'\033[1;36m'
C_GRP=$'\033[1;33m'
C_VAL=$'\033[0m'
C_WARN=$'\033[1;31m'
RESET=$'\033[0m'

while true; do
  DATA=$(vmstat -S M 1 2 | tail -1)
  read -r r b swpd free buff cache si so bi bo in cs us sy id wa st _rest <<< "$DATA"

  clear
  printf '%svmstat monitor%s  %s  (interval: %ss, Ctrl+C to quit)\n\n' "$C_HDR" "$RESET" "$(date '+%Y-%m-%d %H:%M:%S')" "$INTERVAL"

  printf '%sPROCS%s\n' "$C_GRP" "$RESET"
  printf '  runnable        : %s\n' "$r"
  printf '  blocked (IO)    : %s\n\n' "$b"

  printf '%sMEMORY (MB)%s\n' "$C_GRP" "$RESET"
  printf '  free            : %s\n' "$free"
  printf '  buffers         : %s\n' "$buff"
  printf '  cache           : %s\n' "$cache"
  printf '  swap used       : %s\n\n' "$swpd"

  printf '%sSWAP (MB/s)%s\n' "$C_GRP" "$RESET"
  if [ "$si" != "0" ] || [ "$so" != "0" ]; then
    printf '  %sswap in         : %s%s\n' "$C_WARN" "$si" "$RESET"
    printf '  %sswap out        : %s%s\n\n' "$C_WARN" "$so" "$RESET"
  else
    printf '  swap in         : %s\n' "$si"
    printf '  swap out        : %s\n\n' "$so"
  fi

  printf '%sIO (blocks/s)%s\n' "$C_GRP" "$RESET"
  printf '  read            : %s\n' "$bi"
  printf '  write           : %s\n\n' "$bo"

  printf '%sSYSTEM%s\n' "$C_GRP" "$RESET"
  printf '  interrupts/s    : %s\n' "$in"
  printf '  ctx switches/s  : %s\n\n' "$cs"

  printf '%sCPU (%%)%s\n' "$C_GRP" "$RESET"
  printf '  user            : %s\n' "$us"
  printf '  system          : %s\n' "$sy"
  printf '  idle            : %s\n' "$id"
  if [ "${wa:-0}" -ge 20 ] 2>/dev/null; then
    printf '  %siowait          : %s%s\n' "$C_WARN" "$wa" "$RESET"
  else
    printf '  iowait          : %s\n' "$wa"
  fi
  printf '  stolen          : %s\n' "${st:-0}"

  sleep "$INTERVAL"
done
