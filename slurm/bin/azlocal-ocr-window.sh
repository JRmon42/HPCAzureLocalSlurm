#!/usr/bin/env bash
# Night window for the OCR (GPU) partition.
#
# The GPUs belong to the researchers during the day. Slurm has no "partition schedule", so the
# closed hours are expressed as a DAILY recurring blocking reservation owned by root on the GPU
# nodes: nobody else can start a job there while it is active, and Slurm will not start a job
# whose time limit would overlap its next occurrence (so the partition MaxTime must be <= the
# open window). Jobs submitted during the day simply wait Pending and start when the window
# opens - the VMs are created at that moment (or just before, with "prewarm").
#
# Usage (run as root on the controller):
#   azlocal-ocr-window.sh apply         create/refresh the daily blocking reservation
#   azlocal-ocr-window.sh block <min>   test helper: block the GPU nodes for <min> minutes from now
#   azlocal-ocr-window.sh unblock       remove the test block
#   azlocal-ocr-window.sh prewarm       power up the GPU nodes (pre-provision the VMs)
#   azlocal-ocr-window.sh cron          print the cron entry that pre-warms before the window opens
#   azlocal-ocr-window.sh status
# Times are in the controller's local time zone (the one slurmctld uses).
set -euo pipefail
# shellcheck source=/dev/null
source "${AZLOCAL_CONF:-/etc/azlocal-slurm/azlocal.conf}"

OPEN_START="${OCR_OPEN_START:-20:00}"   # window opens (GPU jobs may start)
OPEN_END="${OCR_OPEN_END:-06:00}"       # window closes (researchers are back)
NODES="${OCR_NODES:?OCR_NODES not set in azlocal.conf}"
PREWARM_MIN="${OCR_PREWARM_MIN:-0}"
RES_DAILY=ocr_closed_daily
RES_ONCE=ocr_closed_today
RES_TEST=ocr_block_test

minutes() { local h m; IFS=: read -r h m <<<"$1"; echo $((10#$h * 60 + 10#$m)); }
stamp() { date -d "@$1" +%Y-%m-%dT%H:%M:%S; }
drop() { scontrol delete reservationname="$1" >/dev/null 2>&1 || true; }
create() {  # name start-epoch duration-min [flags]
  scontrol create reservation reservationname="$1" starttime="$(stamp "$2")" duration="$3" \
    users=root nodes="$NODES" flags="${4:-IGNORE_JOBS}" >/dev/null
}

apply() {
  local closed now today_start next_start last_start last_end
  closed=$(( ( $(minutes "$OPEN_START") - $(minutes "$OPEN_END") + 1440 ) % 1440 ))
  (( closed > 0 )) || { echo "open window covers 24h, nothing to block" >&2; drop "$RES_DAILY"; drop "$RES_ONCE"; return 0; }
  now=$(date +%s)
  today_start=$(date -d "today $OPEN_END" +%s)
  if (( today_start > now )); then
    next_start=$today_start; last_start=$(date -d "yesterday $OPEN_END" +%s)
  else
    next_start=$(date -d "tomorrow $OPEN_END" +%s); last_start=$today_start
  fi
  last_end=$(( last_start + closed * 60 ))
  drop "$RES_DAILY"; drop "$RES_ONCE"
  create "$RES_DAILY" "$next_start" "$closed" IGNORE_JOBS,DAILY
  echo "daily block: every day from $OPEN_END for ${closed} min (next: $(stamp "$next_start")) on $NODES"
  if (( now < last_end )); then   # we are inside a closed period right now: cover the rest of it
    create "$RES_ONCE" "$now" $(( (last_end - now + 59) / 60 ))
    echo "closed right now: one-shot block until $(stamp "$last_end")"
  fi
}

case "${1:-status}" in
  apply)   apply ;;
  block)   drop "$RES_TEST"; create "$RES_TEST" "$(date +%s)" "${2:?minutes required}"; echo "blocked $NODES for $2 min" ;;
  unblock) drop "$RES_TEST" ;;
  prewarm) scontrol update nodename="$NODES" state=power_up reason="ocr window pre-warm" ;;
  cron)
    t=$(( $(minutes "$OPEN_START") - PREWARM_MIN )); t=$(( (t + 1440) % 1440 ))
    echo "$((t % 60)) $((t / 60)) * * * root $0 prewarm >>/var/log/slurm/azlocal-ocr-window.log 2>&1" ;;
  status)  scontrol show reservation 2>&1 | grep -E 'ReservationName|StartTime|Flags|Users|Nodes=' || true ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
