#!/bin/bash
#SBATCH --job-name=ocr-qwen-kueue
#SBATCH --partition=k8s
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=04:00:00
#SBATCH --output=/shared/jobs/%x-%j.out
#
# OCR with Qwen-VL: the Slurm job is a thin proxy. The real work runs as a Kubernetes Job that
# Kueue admits only when GPU quota is available and the OCR window is open.
set -euo pipefail
export HOME=${HOME:-/shared/home/hpcuser}
OUT=/ocr/out/$SLURM_JOB_ID
echo "Slurm job $SLURM_JOB_ID on $(hostname) - submitting to Kueue"
/opt/azlocal-slurm/bin/azlocal-kueue-run.sh --queue ocr-queue --cpu 3 --mem 9Gi --gpu 1 --timeout 14400 \
  --env OUT_DIR="$OUT" --env GPU_LAYERS="${GPU_LAYERS:-0}" -- bash /ocr/bin/qwen-ocr.sh
echo "Results in /shared/ocr${OUT#/ocr}"
ls -l "/shared/ocr${OUT#/ocr}"
