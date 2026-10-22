#!/usr/bin/env bash
# Site hook run on every GPU node VM at boot, before slurmd registers (see node-bootstrap.sh).
# POC: installs a CPU OCR engine so the demo job produces real OCR output without a GPU.
#
# PRODUCTION: replace with the real node preparation, typically
#   - install/verify the NVIDIA driver (or bake it in the golden image, see image/prepare-slurm-image.sh)
#   - mount the model store (Qwen-VL weights) read-only, e.g. an NFS/Azure Files/Blob mount
#   - start nothing heavy here: the Slurm job loads the model itself
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! command -v tesseract >/dev/null; then
  apt-get update -qq
  apt-get install -y -qq tesseract-ocr tesseract-ocr-fra imagemagick fonts-dejavu-core >/dev/null
fi
tesseract --version 2>&1 | head -1
