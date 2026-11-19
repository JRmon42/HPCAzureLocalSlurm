#!/usr/bin/env bash
# Runs INSIDE the Kubernetes pod created by kueue-run (see tests/ocr-qwen-kueue.sbatch):
# OCR of every image in $IN_DIR with a Qwen-VL model served by llama.cpp (llama-mtmd-cli).
# Image: ghcr.io/ggml-org/llama.cpp:full (CPU, POC) or :full-cuda (GPU, production, GPU_LAYERS=99).
set -uo pipefail
IN_DIR="${IN_DIR:-/ocr/in}"
OUT_DIR="${OUT_DIR:-/ocr/out/manual}"
MODEL_REPO="${MODEL_REPO:-ggml-org/Qwen2.5-VL-3B-Instruct-GGUF}"
GPU_LAYERS="${GPU_LAYERS:-0}"
THREADS="${THREADS:-$(nproc)}"
PROMPT="${PROMPT:-Extract all the text of this document exactly as written. Output only the text.}"
export LLAMA_CACHE="${LLAMA_CACHE:-/models}"

echo "==> pod $(hostname) on node ${NODE_NAME:-?}"
echo "==> GPU devices visible: ${NVIDIA_VISIBLE_DEVICES:-none (simulated GPU resource, CPU inference)}"
command -v nvidia-smi >/dev/null && nvidia-smi -L

BIN="$(command -v llama-mtmd-cli || find /app -name llama-mtmd-cli -type f 2>/dev/null | head -1)"
[[ -x "$BIN" ]] || { echo "llama-mtmd-cli not found in the image"; exit 2; }
mkdir -p "$OUT_DIR"

n=0
for img in "$IN_DIR"/*.png "$IN_DIR"/*.jpg "$IN_DIR"/*.jpeg; do
  [[ -f "$img" ]] || continue
  base="$(basename "$img")"
  t0=$SECONDS
  echo "==> OCR $base"
  "$BIN" -hf "$MODEL_REPO" --image "$img" -p "$PROMPT" -n 400 --temp 0 -t "$THREADS" \
    -ngl "$GPU_LAYERS" >"$OUT_DIR/$base.txt" 2>"$OUT_DIR/$base.log" \
    || { echo "FAILED $base"; tail -5 "$OUT_DIR/$base.log"; exit 1; }
  echo "    done in $((SECONDS - t0))s -> $OUT_DIR/$base.txt"
  sed 's/^/    | /' "$OUT_DIR/$base.txt" | head -12
  n=$((n + 1))
done
(( n > 0 )) || { echo "no image found in $IN_DIR"; exit 1; }
echo "QWEN-OCR-DONE documents=$n"
