#!/bin/bash
#SBATCH --job-name=mpi-azlocal
#SBATCH --partition=hpc
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=2
#SBATCH --output=/shared/jobs/%x-%j.out
# OpenMPI ring test across elastically provisioned Azure Local VMs.
set -e
cd /shared/jobs
mpicc -O2 -o "mpi_ring.$SLURM_JOB_ID" /shared/tests/mpi_ring.c
echo "Job $SLURM_JOB_ID on $SLURM_JOB_NODELIST"
# One mpirun rank per Slurm task; OpenMPI discovers the allocation from Slurm
mpirun --mca btl tcp,self --mca btl_tcp_if_include "${MPI_SUBNET:-192.168.200.0/24}" \
       --mca oob_tcp_if_include "${MPI_SUBNET:-192.168.200.0/24}" "./mpi_ring.$SLURM_JOB_ID"
rm -f "mpi_ring.$SLURM_JOB_ID"
