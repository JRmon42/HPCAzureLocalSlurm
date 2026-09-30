#!/usr/bin/env bash
# Slurm EpilogSlurmctld: runs on the controller when a job ends.
# With POWER_DOWN_AFTER_JOB=true the job's nodes are powered down as soon as they are
# idle, so each job gets freshly provisioned VMs that are decommissioned at job end
# (instead of waiting SuspendTime seconds of idleness).
source /etc/azlocal-slurm/azlocal.conf
[[ "${POWER_DOWN_AFTER_JOB:-false}" == "true" ]] || exit 0
[[ -n "${SLURM_JOB_NODELIST:-}" ]] || exit 0
scontrol update nodename="$SLURM_JOB_NODELIST" state=power_down_asap \
  reason="azlocal: job $SLURM_JOB_ID ended" >/dev/null 2>&1
printf '%s [epilog] job %s ended -> power_down_asap %s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SLURM_JOB_ID" "$SLURM_JOB_NODELIST" >>"${LOG_FILE:-/var/log/slurm/azlocal-power.log}"
exit 0
