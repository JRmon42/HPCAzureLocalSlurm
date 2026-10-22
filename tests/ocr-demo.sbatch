#!/bin/bash
#SBATCH --job-name=ocr-demo
#SBATCH --partition=ocr
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:20:00
#SBATCH --output=/shared/jobs/ocr-demo-%j.out
# Demo of the nightly OCR batch. Same Slurm shape as the production job: one GPU, input
# documents and results on shared storage. POC: the OCR engine is tesseract (CPU) and the GPU
# is simulated; production replaces the "ocr" function with the Qwen-VL inference call.
IN=${OCR_IN:-/shared/ocr/in}
OUT=${OCR_OUT:-/shared/ocr/out}
mkdir -p "$IN" "$OUT"

echo "node=$(hostname) job=$SLURM_JOB_ID gpus=${SLURM_JOB_GPUS:-${CUDA_VISIBLE_DEVICES:-none}} start=$(date -Is)"
nvidia-smi -L 2>/dev/null || echo "(no physical GPU on this node: simulated GRES, POC)"

# Generate sample documents when the input folder is empty
if ! ls "$IN"/*.png >/dev/null 2>&1; then
  i=0
  for text in "Facture 2024-0042  Total TTC 1 280,50 EUR" \
              "Compte rendu de reunion  Azure Local et Slurm" \
              "Invoice 7781  Amount due 3 450.00 USD"; do
    i=$((i + 1))
    convert -size 1000x160 xc:white -font DejaVu-Sans -pointsize 36 -fill black \
            -gravity center -annotate 0 "$text" "$IN/doc-$i.png"
  done
fi

ocr() { tesseract "$1" "${2%.txt}" -l fra+eng >/dev/null 2>&1; }

for f in "$IN"/*.png; do
  b=$(basename "$f" .png)
  ocr "$f" "$OUT/$b.txt" && echo "OCR $b: $(tr '\n' ' ' <"$OUT/$b.txt")"
done
echo "done=$(date -Is) documents=$(ls "$OUT"/*.txt | wc -l)"
