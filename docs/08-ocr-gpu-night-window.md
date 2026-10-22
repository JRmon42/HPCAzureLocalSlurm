# 8. OCR with Qwen-VL on GPU nodes: night window on Azure Local (customer answers)

Update after the customer's answers. This **supersedes the arbitration options of
[doc 07](07-coexistence-ocr-workloads.md)**: no arbitration is needed, only scheduling.

## What the customer said

| Topic | Answer | Consequence |
|---|---|---|
| Workload | **OCR with Qwen-VL** (vision-language model), already orchestrated by **Slurm** | The Slurm submission flow stays as it is |
| Today / tomorrow | Today: VMs **on-prem**. Tomorrow: **VMs in Azure Local** | Same Slurm; only the node backend changes (the subject of this repo) |
| Timing | OCR runs **at night**, outside the researchers' working hours; "to be planned according to the time" | A **time-window** problem, not a preemption problem |
| GPUs | Required. VMs get **DDA**; **8 RTX 6000** in the cluster | One GPU per VM → up to 8 GPU nodes; see "GPU details" |
| Arbitration | **None**: "it's a question of schedule" | No Slinky/Kubernetes priorities, no capacity reclaim logic |
| AKS | Possible later (an Arc + GPU-enabled cluster will exist) | Keep as option, not needed now |

So the "never preempt OCR" requirement from the first conversation turns into: **OCR and the researchers
do not run at the same time; the cluster belongs to OCR at night and to the researchers during the day.**

## Target design

```text
On-prem Slurm controller (existing)  ── ResumeProgram / SuspendProgram (this repo) ──►  Azure Local (ARM, Arc resource bridge)
        │                                                                                    │
        │  partition "ocr": nodes gpu-[01-08]  State=CLOUD  Gres=gpu:rtx6000:1               │  VM gpu-NN = image + NVIDIA driver
        │  recurring window 20:00–06:00 (reservation)                                        │  + 1 GPU in DDA, created at job start,
        └─ night: jobs run, VMs created   ─ day: no OCR VMs exist, GPUs free ◄───────────────┘  deleted at job end
```

Why the elastic model fits better than always-on GPU VMs: a DDA GPU is **bound to a VM while it
exists**. VMs created for the night window and **deleted afterwards give the 8 GPUs back** to researchers
or to any other VM during the day, without manual action.

### 1. Night window in Slurm

* Partition `ocr` with the GPU nodes (`NodeName=gpu-[01-08] State=CLOUD Gres=gpu:rtx6000:1 ...`,
  `gres.conf` `Name=gpu Type=rtx6000 File=/dev/nvidia0`).
* **Window**: a daily recurring reservation for the OCR account, for example
  `scontrol create reservation ReservationName=ocr_night Accounts=ocr Nodes=gpu-[01-08] StartTime=20:00:00 Duration=10:00:00 Flags=DAILY`
  (or a QOS). Researchers' jobs keep their own partition and are not affected.
* **Jobs must fit the window**: `MaxTime` on the partition (for example 9 h). Slurm does not start a job whose
  time limit would overlap the end of the window if a day reservation exists for the same nodes.
* **Pre-warm** (optional): the VMs take about 4–5 min to start (see [05](05-poc-results.md)) plus the model
  load time. A cron at 19:45 runs `scontrol update NodeName=gpu-[01-08] State=POWER_UP` so the first job
  does not wait. `SuspendTime` powers the VMs down after the last job.
* If OCR is currently submitted with `sbatch --begin=20:00` or by cron, that continues to work.

### 2. GPU details

* Creating a VM with a GPU: `az stack-hci-vm create … --gpus GpuDDA` (documented), or
  `az stack-hci-vm gpu attach --gpus GpuDDA` on an existing, stopped VM
  ([Manage GPUs via DDA](https://learn.microsoft.com/azure/azure-local/manage/gpu-manage-via-device)).
  The Azure Local scheduler places the VM on a host with a free GPU.
* **To add to this repo** (not yet implemented or tested: the POC runs on LocalBox, which has no GPU): a
  `gpus` parameter in `node.bicep` / `azlocal-resume.sh` for the GPU partition of the node pool, and the
  image `image/prepare-slurm-image.sh` with the **NVIDIA driver + CUDA**, `nvidia-container-toolkit` if
  containers are used, and `vllm` or the customer's inference stack. **Model weights stay on the shared
  storage** (NFS or equivalent), not in the image, so the image stays small and the VM starts quickly.
* **Supported models**: *NVIDIA RTX PRO 6000* is on the supported list for DDA with Arc VMs and AKS. The
  older *Quadro RTX 6000* and *RTX 6000 Ada* are **not listed**. **Confirm the exact model** and check it in the
  [Azure Local catalog](https://azurestackhcisolutions.azure.microsoft.com/) (homogeneous GPUs across all
  hosts are required).
* Constraints: one GPU per DDA VM; **DDA VMs cannot be live-migrated** and are not restarted on another host
  without a free GPU; with 8 GPUs spread over several hosts the maximum is 8 GPU VMs at once, and a VM needs
  a host that still has a free GPU.
* Sizing (Qwen3-VL): 2B–4B needs about 6–12 GB of VRAM, 8B about 17–24 GB. A 48–96 GB RTX 6000-class
  card fits the 8B model, even larger ones for some variants. One GPU per Slurm node means 8 parallel OCR workers.

### 3. Connectivity

The existing on-prem Slurm controller calls Azure over outbound HTTPS (ARM) and reaches the VM network of
Azure Local over SSH and the Slurm ports (slurmctld 6817, slurmd 6818, plus the ephemeral `srun` range). It needs an identity in Azure: an **Arc-enabled
server** (managed identity) or a **service principal with a certificate** (`AZ_AUTH=sp`) with the role
*Azure Stack HCI VM Contributor* on the resource group. No controller VM is needed on Azure Local.

## Migration path from today

1. **Today**: on-prem VMs, Slurm schedules OCR at night. No change.
2. **Pilot**: add the partition `ocr-azlocal` with 1–2 GPU nodes in Azure Local (this repo +
   GPU parameters) and run the same OCR job there; compare throughput and start-up time.
3. **Switch**: move all 8 GPUs, enable the night reservation, remove the always-on VMs.
4. **Optional later**: AKS on Azure Local with GPU DDA if the customer wants containers. The Slurm elastic model
   and AKS can co-exist (different GPUs) but then GPU DDA is split between them.

## Remaining questions for the customer

1. **Exact GPU model** (RTX PRO 6000 Blackwell or RTX 6000 Ada?), and how many per host and how many hosts?
2. Do the **researchers use these GPUs during the day** (Slurm or direct VMs)? If yes, which hours, so we can
   dimension the reservation and the GPU split.
3. **Current Slurm**: version, where `slurmctld` runs, is it an Arc-enabled server, and how are nodes
   defined today (persistent VMs?). Is `slurmdbd` used?
4. How are Qwen-VL models served: **offline batch per job** or a **vLLM server per node**? Which framework
   and model size? Where are the documents and the model weights stored (NFS, object storage), and how big
   is the nightly volume?
5. Network between on-prem and Azure Local, and where the documents come from (data gravity).
6. Expected **start-up tolerance**: 4–5 min VM creation plus model loading is fine if the window is several
   hours; if not, keep the VMs for the whole night (`SuspendTime` ≥ window).
