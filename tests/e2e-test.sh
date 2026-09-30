#!/usr/bin/env bash
# End-to-end test of elastic Slurm compute on Azure Local. Run as root on the controller.
#   e2e-test.sh [job.sbatch ...]      (default: hello.sbatch mpi.sbatch)
# For every job: submit as hpcuser -> Slurm resumes (creates) the VMs -> job runs ->
# EpilogSlurmctld/SuspendTime -> Slurm suspends (deletes) the VMs. Measures each phase and
# checks the VMs really exist during the job and are gone afterwards.
set -uo pipefail
TESTS_DIR="$(dirname "$(readlink -f "$0")")"
JOBS=("$@"); [[ ${#JOBS[@]} -eq 0 ]] && JOBS=(hello.sbatch mpi.sbatch)
TIMEOUT=${E2E_TIMEOUT:-3600}
mkdir -p /shared/tests && cp "$TESTS_DIR"/*.sbatch "$TESTS_DIR"/*.c /shared/tests/ && chmod -R a+rX /shared/tests

az_vms() {  # names of Slurm-managed VMs currently present on Azure Local
  sudo -u slurm -H bash -c 'source /opt/azlocal-slurm/bin/azlocal-common.sh >/dev/null && az_login >/dev/null &&
    az stack-hci-vm list -g "$RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null' | grep -E '^hpc-' | sort | xargs
}
az_leftovers() {  # all compute-node resources: VM instances, Arc machines hpc-NN, NICs hpc-NN-nic
  sudo -u slurm -H bash -c 'source /opt/azlocal-slurm/bin/azlocal-common.sh >/dev/null && az_login >/dev/null &&
    { az resource list -g "$RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null;
      az stack-hci-vm list -g "$RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null; }' | grep -E '^hpc-' | sort -u | xargs
}
ts() { date -u +%H:%M:%S; }
fail=0

echo "=== E2E start $(date -u +%FT%TZ) on $(hostname) ==="
sinfo -N -o '%N %T'
echo "Azure Local compute resources before: [$(az_leftovers)]"

for job in "${JOBS[@]}"; do
  echo; echo "=== $job ==="
  t0=$SECONDS
  jid=$(sudo -u hpcuser -H sbatch --parsable "/shared/tests/$job") || { echo "sbatch failed"; fail=1; continue; }
  echo "$(ts) submitted job $jid"
  state=""; seen_vms=""
  while (( SECONDS - t0 < TIMEOUT )); do
    state=$(scontrol show job "$jid" -o 2>/dev/null | grep -oP '(?<=JobState=)\S+')
    # VMs are created while the job is CONFIGURING; sample until every job node has been seen (jobs can be short)
    if [[ "$state" =~ ^(CONFIGURING|RUNNING|COMPLETING)$ ]] && (( $(wc -w <<<"$seen_vms") < $(squeue -h -j "$jid" -o %D 2>/dev/null || echo 1) )); then
      now_vms=$(az_vms)
      if [[ -n "$now_vms" && "$now_vms" != "$seen_vms" ]]; then
        seen_vms=$(echo "$seen_vms $now_vms" | xargs -n1 | sort -u | xargs)
        echo "$(ts) $state: Azure Local VMs present: [$now_vms] (job nodes $(squeue -h -j "$jid" -o %N))"
      fi
    fi
    [[ "$state" =~ ^(COMPLETED|FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY)$ ]] && break
    sleep 5
  done
  t_end=$((SECONDS - t0))
  jobinfo=$(scontrol show job "$jid" -o)
  nodes=$(grep -oP '(?<= NodeList=)\S+' <<<"$jobinfo")
  # Slurm resets StartTime to the moment the powered-up nodes became usable
  sub=$(date -d "$(grep -oP '(?<=SubmitTime=)\S+' <<<"$jobinfo")" +%s)
  start=$(date -d "$(grep -oP '(?<=StartTime=)\S+' <<<"$jobinfo")" +%s)
  endt=$(date -d "$(grep -oP '(?<=EndTime=)\S+' <<<"$jobinfo")" +%s)
  t_run=$((start - sub)); t_exec=$((endt - start))
  echo "$(ts) job $jid $state after ${t_end}s (nodes $nodes): provisioning wait ${t_run}s, execution ${t_exec}s"
  out=$(ls /shared/jobs/*-"$jid".out 2>/dev/null | head -1)
  [[ -n "$out" ]] && { echo "--- job output ---"; cat "$out"; echo "------------------"; }
  [[ "$state" == COMPLETED ]] || fail=1
  [[ -n "$seen_vms" ]] || { echo "WARNING: no VM observed during the job"; fail=1; }

  echo "$(ts) waiting for decommissioning of $nodes"
  t1=$SECONDS
  while (( SECONDS - t1 < 1200 )); do
    [[ -z "$(az_leftovers)" ]] && break
    sleep 10
  done
  t_dec=$((SECONDS - t1))
  # node stays POWERING_DOWN (idle%) until SuspendTimeout expires, then POWERED_DOWN (idle~)
  pstate=$(sinfo -h -N -n "$nodes" -o '%T' | sort -u | xargs)
  left=$(az_leftovers)
  echo "$(ts) VM, Arc machine and NIC deleted ${t_dec}s after job end; resources left: [$left]; Slurm node state: $pstate"
  [[ -z "$left" ]] || fail=1
  [[ "$pstate" =~ ^(idle~|idle%|idle%\ idle~|idle~\ idle%)$ ]] || { echo "WARNING: unexpected node state $pstate"; fail=1; }
  echo "RESULT $job job=$jid state=$state provisioning_wait=${t_run}s execution=${t_exec}s vms_during_job=[$seen_vms] vm_deletion_after_end=${t_dec}s"
done
echo; echo "=== power log (last 60 lines) ==="
tail -n 60 /var/log/slurm/azlocal-power.log
echo; [[ $fail -eq 0 ]] && echo "E2E-PASS" || echo "E2E-FAIL"
exit $fail
