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
ts() { date -u +%H:%M:%S; }
fail=0

echo "=== E2E start $(date -u +%FT%TZ) on $(hostname) ==="
sinfo -N -o '%N %T'
echo "Azure Local compute VMs before: [$(az_vms)]"

for job in "${JOBS[@]}"; do
  echo; echo "=== $job ==="
  t0=$SECONDS
  jid=$(sudo -u hpcuser -H sbatch --parsable "/shared/tests/$job") || { echo "sbatch failed"; fail=1; continue; }
  echo "$(ts) submitted job $jid"
  state=""; t_run=""; seen_vms=""
  while (( SECONDS - t0 < TIMEOUT )); do
    state=$(scontrol show job "$jid" -o 2>/dev/null | grep -oP '(?<=JobState=)\S+')
    if [[ "$state" == RUNNING && -z "$t_run" ]]; then
      t_run=$((SECONDS - t0))
      echo "$(ts) RUNNING after ${t_run}s on $(squeue -h -j "$jid" -o %N)"
      seen_vms=$(az_vms); echo "$(ts) Azure Local VMs during job: [$seen_vms]"
    fi
    [[ "$state" =~ ^(COMPLETED|FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY)$ ]] && break
    sleep 10
  done
  t_end=$((SECONDS - t0))
  nodes=$(scontrol show job "$jid" -o | grep -oP '(?<= NodeList=)\S+')
  echo "$(ts) job $jid $state after ${t_end}s (nodes $nodes)"
  out=$(ls /shared/jobs/*-"$jid".out 2>/dev/null | head -1)
  [[ -n "$out" ]] && { echo "--- job output ---"; cat "$out"; echo "------------------"; }
  [[ "$state" == COMPLETED ]] || fail=1
  [[ -n "$seen_vms" ]] || { echo "WARNING: no VM observed while the job was running"; fail=1; }

  echo "$(ts) waiting for decommissioning of $nodes"
  t1=$SECONDS
  while (( SECONDS - t1 < 1200 )); do
    remaining=$(az_vms)
    pstate=$(sinfo -h -N -n "$nodes" -o '%T' | sort -u | xargs)
    [[ -z "$remaining" && "$pstate" =~ ^(idle~|idle\~)$ ]] && break
    sleep 15
  done
  echo "$(ts) decommissioned in $((SECONDS - t1))s after job end; VMs left: [$(az_vms)]; node state: $(sinfo -h -N -n "$nodes" -o '%T' | sort -u | xargs)"
  [[ -z "$(az_vms)" ]] || fail=1
  echo "RESULT $job job=$jid state=$state time_to_running=${t_run:-NA}s job_total=${t_end}s decommission=$((SECONDS - t1))s"
done

echo; echo "=== power log (last 60 lines) ==="
tail -n 60 /var/log/slurm/azlocal-power.log
echo; [[ $fail -eq 0 ]] && echo "E2E-PASS" || echo "E2E-FAIL"
exit $fail
