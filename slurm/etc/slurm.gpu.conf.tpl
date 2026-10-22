
# ---- GPU nodes for the nightly OCR (Qwen-VL) workload ----
# Appended to slurm.conf by controller-setup.sh when GPU_NODE_RANGE is set.
# One GPU per VM (Discrete Device Assignment allows a single physical GPU per VM).
GresTypes=gpu
NodeName=__GPU_NODE_RANGE__ CPUs=__GPU_NODE_CPUS__ RealMemory=__GPU_NODE_MEMORY__ Gres=gpu:__GPU_TYPE__:1 State=CLOUD Feature=azlocal,gpu
# MaxTime must not exceed the open window: Slurm will not start a job that would run into the
# daily blocking reservation (see slurm/bin/azlocal-ocr-window.sh).
PartitionName=ocr Nodes=__GPU_NODE_RANGE__ Default=NO MaxTime=__OCR_MAX_TIME__ DefaultTime=01:00:00 State=UP
