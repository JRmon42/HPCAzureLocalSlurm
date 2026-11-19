#!/usr/bin/env bash
# Slurm EpilogSlurmctld: runs on the controller when a job ends.
# With POWER_DOWN_AFTER_JOB=true the job's nodes are powered down as soon as they are
# idle, so each job gets freshly provisioned VMs that are decommissioned at job end
# (instead of waiting SuspendTime seconds of idleness).
source /etc/azlocal-slurm/azlocal.conf
[[ "${POWER_DOWN_AFTER_JOB:-false}" == "true" ]] || exit 0
[[ -n "${SLURM_JOB_NODELIST:-}" ]] || exit 0
# Only VM-backed nodes (Feature=azlocal) are decommissioned; static nodes such as the
# controller/Kubernetes gateway must never be powered down.
nodes=""
for n in $(scontrol show hostnames "$SLURM_JOB_NODELIST"); do
  scontrol show node "$n" 2>/dev/null | grep -q 'AvailableFeatures=.*azlocal' && nodes+="${nodes:+,}$n"
done
[[ -n "$nodes" ]] || exit 0
SLURM_JOB_NODELIST="$nodes"
scontrol update nodename="$SLURM_JOB_NODELIST" state=power_down_asap \
  reason="azlocal: job $SLURM_JOB_ID ended" >/dev/null 2>&1
printf '%s [epilog] job %s ended -> power_down_asap %s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SLURM_JOB_ID" "$SLURM_JOB_NODELIST" >>"${LOG_FILE:-/var/log/slurm/azlocal-power.log}"
exit 0
