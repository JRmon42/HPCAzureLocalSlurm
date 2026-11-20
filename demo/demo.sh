#!/usr/bin/env bash
# Run the Slurm + Kueue + Qwen-VL OCR POC demo from bash (Git Bash in VS Code, WSL, Linux, macOS, Cloud Shell).
# Prerequisites: Azure CLI logged in to the POC subscription, extension connectedmachine.
# Usage: ./demo/demo.sh <command> [args]   (./demo/demo.sh help)
set -euo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'   # Git Bash: do not rewrite /shared/... arguments

RG=${RG:-rg-hpc-azlocal-slurm}
HOST_VM=${HOST_VM:-LocalBox-Client}
CTL=${CTL:-slurmctl}
K8S=${K8S:-k8s-01}
SBATCH=/shared/tests/ocr-qwen-kueue.sbatch
KA='kubectl --kubeconfig /shared/k8s/admin.kubeconfig'
KU='sudo -u hpcuser kubectl --kubeconfig /shared/k8s/hpcuser.kubeconfig -n ocr'

TIMEOUT=''
if command -v timeout >/dev/null 2>&1; then TIMEOUT='timeout 1000'; elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT='gtimeout 1000'; fi

die() { echo "ERROR: $*" >&2; exit 1; }
nocr() { tr -d '\r'; }
# az on Windows writes its output in the ANSI code page (cp1252): convert back to UTF-8 so accents display correctly
utf8() { if command -v iconv >/dev/null 2>&1 && ! iconv -f UTF-8 -t UTF-8 <<<"$1" >/dev/null 2>&1; then iconv -f CP1252 -t UTF-8 <<<"$1"; else printf '%s\n' "$1"; fi; }
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
need_job() { [[ ${1:-} =~ ^[0-9]+$ ]] || die "give the Slurm job id, e.g. $0 $CMD 12"; }

# Runs a bash script on the Slurm controller through Azure Arc Run Command and prints its output.
ctl() {
  local f name loc out err st
  read -r loc st < <(az connectedmachine show -g "$RG" -n "$CTL" --query "[location,status]" -o tsv --only-show-errors | nocr | tr '\n\t' '  '; echo) || true
  [[ -n $loc ]] || die "Arc machine $CTL not found in $RG"
  [[ $st == Connected ]] || die "$CTL is $st in Azure Arc: run '$0 status' (host deallocated? then '$0 start')"
  f=$(mktemp); printf '#!/bin/bash\n%s\n' "$*" >"$f"
  name="rc-$(date +%Y%m%d%H%M%S)-$RANDOM"
  for attempt in 1 2 3; do
    # A client-side guard: az can hang (e.g. after the PC wakes from sleep); the script itself is bounded by 900 s
    if $TIMEOUT az connectedmachine run-command create -g "$RG" --machine-name "$CTL" --location "$loc" --name "$name" \
        --script "@$(winpath "$f")" --timeout-in-seconds 900 --only-show-errors -o none; then break; fi
    # Do not run the script twice if it already ran
    [[ $(az connectedmachine run-command show -g "$RG" --machine-name "$CTL" --name "$name" \
        --query instanceView.executionState -o tsv --only-show-errors 2>/dev/null | nocr) == Succeeded ]] && break
    [[ $attempt == 3 ]] && { rm -f "$f"; die "run command failed (is $CTL Connected? ./demo/demo.sh status)"; }
    echo "run command attempt $attempt failed, retrying in 30s" >&2; sleep 30
  done
  rm -f "$f"
  out=$(az connectedmachine run-command show -g "$RG" --machine-name "$CTL" --name "$name" \
        --query instanceView.output -o tsv --only-show-errors | nocr)
  err=$(az connectedmachine run-command show -g "$RG" --machine-name "$CTL" --name "$name" \
        --query instanceView.error -o tsv --only-show-errors | nocr)
  az connectedmachine run-command delete -g "$RG" --machine-name "$CTL" --name "$name" --yes --no-wait \
     --only-show-errors -o none 2>/dev/null || true
  printf '%b\n' "$out" | { o=$(cat); utf8 "$o"; }
  [[ -n $err ]] && { printf 'stderr: %b\n' "$err" | { e=$(cat); utf8 "$e"; }; } >&2
  return 0
}

arc_status() {
  az connectedmachine list -g "$RG" --query "[].{machine:name,status:status}" -o table --only-show-errors
}

wait_arc() {
  local deadline=$((SECONDS + ${1:-2700})) s1 s2
  while :; do
    s1=$(az connectedmachine show -g "$RG" -n "$CTL" --query status -o tsv --only-show-errors | nocr)
    s2=$(az connectedmachine show -g "$RG" -n "$K8S" --query status -o tsv --only-show-errors | nocr)
    echo "$(date +%H:%M:%S)  $CTL=$s1  $K8S=$s2"
    [[ $s1 == Connected && $s2 == Connected ]] && return 0
    ((SECONDS > deadline)) && die "still not Connected after waiting; see the troubleshooting section"
    sleep 60
  done
}

# After a cold start k8s-01 boots with its clock ahead and corrects it: the service-account tokens issued at boot
# are then rejected (401) and Kueue never becomes ready. Restarting the system deployments issues fresh tokens.
wait_kueue() {
  echo "==> Waiting for Kubernetes and the Kueue controller (up to 10 min, self-heals after 2 min)"
  ctl "ready() { $KA -n kueue-system get deploy kueue-controller-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^[1-9]' && \
$KA -n kueue-system get endpointslices -l kubernetes.io/service-name=kueue-webhook-service -o jsonpath='{.items[*].endpoints[*].addresses[0]}' 2>/dev/null | grep -q .; }
for i in \$(seq 60); do
  ready && { echo 'Kueue ready'; exit 0; }
  if [ \$i = 12 ]; then echo 'Kueue not ready after 2 min: restarting kube-system and kueue-system deployments (fresh tokens)'
    $KA -n kube-system rollout restart deploy; $KA -n kueue-system rollout restart deploy; fi
  sleep 10
done
echo 'Kueue NOT ready: run ./demo/demo.sh health, then ./demo/demo.sh repair if needed'; exit 1"
}

start_nested() {
  local f stuck; f=$(mktemp --suffix=.ps1 2>/dev/null || mktemp)
  # A managed run-command left in "Creating" blocks the next ones on the VM
  stuck=$(az vm run-command list -g "$RG" --vm-name "$HOST_VM" --query "[?provisioningState=='Creating'].name" -o tsv --only-show-errors | nocr)
  for n in $stuck; do echo "Deleting stuck run-command $n"; az vm run-command delete -g "$RG" --vm-name "$HOST_VM" --name "$n" --yes --only-show-errors -o none || true; done
  cat >"$f" <<'PS'
Get-VM | Where-Object { $_.State -ne 'Running' } | Start-VM
Start-Sleep 5
Get-VM | Select-Object Name, State, Uptime | Format-Table -AutoSize | Out-String -Width 200
PS
  echo "==> Starting the nested Azure Local hosts inside $HOST_VM (about 1-3 min)"
  az vm run-command invoke -g "$RG" -n "$HOST_VM" --command-id RunPowerShellScript --scripts "@$(winpath "$f")" \
     --query "value[0].message" -o tsv --only-show-errors | nocr
  rm -f "$f"
}

usage() {
  cat <<EOF
Usage: $0 <command> [args]        (RG=$RG)

 Environment
  status                 host VM power state and Arc status of the machines
  start                  start $HOST_VM, start the nested hosts, wait until $CTL, $K8S and Kueue are ready
  wait                   only wait until $CTL and $K8S are Connected in Azure Arc and Kueue is ready
  health                 Slurm partitions, Kubernetes node, Kueue queues, simulated GPU count
  repair                 re-apply k3s, simulated GPUs, Kueue, queues and kubeconfigs (needs pwsh, about 10 min)
  stop                   deallocate $HOST_VM (stops the cost)

 Test
  submit [count]         submit the OCR job (as hpcuser) count times, default 1
  jobs                   Slurm queue + history and Kueue workloads / Kubernetes jobs / pods
  watch [seconds]        repeat 'jobs' every N seconds (default 60) until no OCR job is left; Ctrl+C to stop
  log <jobid>            Slurm output of the job (what the researcher sees)
  result <jobid>         OCR text files produced by the job
  describe <jobid>       Kueue workload details (why it is queued / admitted)
  cancel <jobid>         scancel the job (the Kubernetes Job is deleted)
  window-close           run the 06:00 CronJob now (ClusterQueue on Hold)
  window-open            run the 20:00 CronJob now (ClusterQueue open)
  window                 show the current stopPolicy (None = open, Hold = closed)

 Any command
  run '<bash command>'   run a command on the Slurm controller, e.g. $0 run 'sinfo'
EOF
}

CMD=${1:-help}; shift || true
case $CMD in
  status)
    echo "Host VM $HOST_VM: $(az vm get-instance-view -g "$RG" -n "$HOST_VM" \
      --query "instanceView.statuses[1].displayStatus" -o tsv --only-show-errors | nocr)"
    arc_status ;;
  start)
    echo "==> Starting $HOST_VM (about 2-3 min if deallocated)"
    az vm start -g "$RG" -n "$HOST_VM" --only-show-errors -o none
    start_nested
    echo "==> Waiting for $CTL and $K8S to be Connected in Azure Arc (15-30 min after a cold start)"
    wait_arc; wait_kueue ;;
  wait) wait_arc; wait_kueue ;;
  health)
    ctl "echo '=== Slurm'; sinfo
echo '=== Kubernetes node'; $KA get nodes
echo '=== Kueue controller'; $KA -n kueue-system get deploy kueue-controller-manager
echo '=== Kueue queues'; $KA get clusterqueue,localqueue -A
echo -n '=== Simulated GPUs on $K8S: '; $KA get node $K8S -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'; echo
echo -n '=== OCR window (stopPolicy): '; $KA get clusterqueue ocr-cq -o jsonpath='{.spec.stopPolicy}'; echo
echo -n '=== Shared folder: '; ls $SBATCH" ;;
  submit)
    n=${1:-1}; [[ $n =~ ^[0-9]+$ ]] || die "count must be a number"
    ctl "cd /tmp && for i in \$(seq $n); do sudo -u hpcuser sbatch $SBATCH; done" ;;
  jobs)
    ctl "echo '=== Slurm queue'; squeue -o '%.6i %.9P %.22j %.8u %.2t %.10M %R'
echo '=== Recently finished Slurm jobs (kept about 5 min by slurmctld; accounting is off in the POC)'
squeue -h -t CD,CA,F,TO,OOM,NF -o '%.6i %.9P %.22j %.8u %.10T %.10M %R'
echo '=== Kueue workloads / Kubernetes jobs / pods (namespace ocr)'; $KU get workloads,jobs,pods 2>&1" ;;
  watch)
    every=${1:-60}
    while :; do
      out=$("$0" jobs); clear 2>/dev/null || true
      echo "$(date +%H:%M:%S)  (refresh every ${every}s + 1-2 min Run Command latency, Ctrl+C to stop)"; echo "$out"
      grep -Eq ' (R|PD|CG) ' <<<"$(sed -n '/Slurm queue/,/Recently finished/p' <<<"$out")" || { echo "No job left in the Slurm queue."; break; }
      sleep "$every"
    done ;;
  log)      need_job "${1:-}"; ctl "tail -n 40 /shared/jobs/*-$1.out" ;;
  result)   need_job "${1:-}"; ctl "cd /shared/ocr/out/$1 && for f in *.txt; do echo \"===== \$f\"; cat \"\$f\"; echo; done" ;;
  describe) need_job "${1:-}"; ctl "w=\$($KA -n ocr get workloads -o name | grep -- '-slurm-$1-' | head -1)
[ -n \"\$w\" ] && $KA -n ocr describe \$w | sed -n '/^Status:/,\$p' || echo 'no workload for job $1 (finished or cancelled)'" ;;
  cancel)   need_job "${1:-}"; ctl "sudo -u hpcuser scancel $1; sleep 10; squeue; $KU get jobs" ;;
  window-close) ctl "$KA -n ocr delete job ocr-close-now --ignore-not-found >/dev/null; $KA -n ocr create job --from=cronjob/ocr-window-close ocr-close-now
sleep 25; echo -n 'stopPolicy: '; $KA get clusterqueue ocr-cq -o jsonpath='{.spec.stopPolicy}'; echo" ;;
  window-open)  ctl "$KA -n ocr delete job ocr-open-now --ignore-not-found >/dev/null; $KA -n ocr create job --from=cronjob/ocr-window-open ocr-open-now
sleep 25; echo -n 'stopPolicy: '; $KA get clusterqueue ocr-cq -o jsonpath='{.spec.stopPolicy}'; echo" ;;
  window)   ctl "echo -n 'stopPolicy: '; $KA get clusterqueue ocr-cq -o jsonpath='{.spec.stopPolicy}'; echo; $KA -n ocr get cronjobs" ;;
  run)      [[ $# -gt 0 ]] || die "give a command, e.g. $0 run 'sinfo'"; ctl "$*" ;;
  repair)
    command -v pwsh >/dev/null 2>&1 || die "PowerShell 7 (pwsh) is required for repair"
    pwsh -NoProfile -File "$(dirname "$0")/../infra/05-deploy-k8s.ps1" -ResourceGroup "$RG" -Stage Configure ;;
  stop)     az vm deallocate -g "$RG" -n "$HOST_VM" --no-wait --only-show-errors; echo "Deallocation of $HOST_VM requested." ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
