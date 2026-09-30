#!/bin/bash
#SBATCH --job-name=hello-azlocal
#SBATCH --partition=hpc
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=2
#SBATCH --output=/shared/jobs/%x-%j.out
# Minimal multi-node job: each task reports where it runs. The nodes do not exist
# when the job is submitted; Slurm provisions them on Azure Local first.
echo "Job $SLURM_JOB_ID started $(date -u +%FT%TZ) on $SLURM_JOB_NODELIST"
srun bash -c 'echo "task $SLURM_PROCID on $(hostname) ($(hostname -I | cut -d" " -f1)) cpus=$(nproc) mem=$(free -m | awk "/Mem:/{print \$2}")MB"'
echo "Job $SLURM_JOB_ID finished $(date -u +%FT%TZ)"
