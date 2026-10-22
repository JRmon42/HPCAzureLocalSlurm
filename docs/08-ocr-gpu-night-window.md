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

A reservation *for* the OCR account does **not** keep others out of the GPUs, and does not stop the OCR
account from running by day. The correct mechanism is the opposite: block the **closed** hours.

* Partition `ocr` with the GPU nodes (`NodeName=gpu-[01-08] State=CLOUD Gres=gpu:rtx6000:1 ...`).
* **Window**: a daily recurring **blocking reservation owned by `root`** on `gpu-[01-08]` covering the
  closed hours (06:00 → 20:00). While it is active nobody else can start a job on these nodes; Slurm also
  refuses to start a job whose time limit would run into its next occurrence. Jobs submitted by day simply
  wait `Pending` and start when the window opens. Implemented by
  [`slurm/bin/azlocal-ocr-window.sh`](../slurm/bin/azlocal-ocr-window.sh) (`apply`).
* **Jobs must fit the window**: partition `MaxTime` = window length (10 h for 20:00–06:00).
* The researchers' own jobs keep their own partition/nodes; only the GPU nodes are windowed.
* **Pre-warm** (optional, `OCR_PREWARM_MIN`): the VMs take ~4–5 min to start (see [05](05-poc-results.md))
  plus the model load time. A cron before opening runs `scontrol update NodeName=gpu-[01-08] State=POWER_UP`.
  Note that `SuspendTime` still applies to nodes that stay idle, so set it above the pre-warm lead time.
* If OCR is currently submitted with `sbatch --begin=20:00` or by cron, that continues to work.

### 2. GPU details

* Creating a VM with a GPU: `az stack-hci-vm create … --gpus GpuDDA` (documented), or
  `az stack-hci-vm gpu attach --gpus GpuDDA` on an existing, stopped VM
  ([Manage GPUs via DDA](https://learn.microsoft.com/azure/azure-local/manage/gpu-manage-via-device)).
  The Azure Local scheduler places the VM on a host with a free GPU. In ARM the VM instance exposes
  `hardwareProfile.virtualMachineGPUs[] {assignmentType: GpuDDA, gpuName, partitionSizeMB}`
  (API `2024-05-01-preview` and later). `node.bicep` now has a `gpus` parameter for it.
* Still to do for production (see section 4): image with the NVIDIA driver, `AutoDetect=nvml`,
  Qwen-VL stack and model weights. **Model weights stay on the shared
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

## POC status: implemented, simulated, not implemented

Tested on the POC (RG `rg-hpc-azlocal-slurm`, LocalBox, **no physical GPU**).

| Item | Status | Detail |
|---|---|---|
| `ocr` partition, nodes `gpu-[01-08]` (`State=CLOUD`, `Gres=gpu:rtx6000:1`), `--gres=gpu:1` scheduling | **Implemented and tested** | `slurm/etc/slurm.gpu.conf.tpl`, rendered by `controller-setup.sh` |
| Elastic lifecycle for GPU nodes (VM created at job start, deleted at job end, static IP 192.168.200.11x) | **Implemented and tested** | Same Resume/Suspend programs; `GPU_IP_BASE` in `azlocal.conf` |
| Night window (daily blocking reservation, jobs wait Pending, VMs created only when it opens) | **Implemented and tested** | `slurm/bin/azlocal-ocr-window.sh`; see test below |
| Node hooks run before slurmd registers (`/shared/hooks.d/<class>/*.sh`, class = `all` or the node prefix, e.g. `gpu`) | **Implemented and tested** | POC hook installs tesseract on GPU nodes only; production hook = driver check + model mount |
| OCR demo job (documents in `/shared/ocr/in` → text in `/shared/ocr/out`) | **Implemented and tested** with tesseract | `tests/ocr-demo.sbatch`; real OCR output, same Slurm shape as Qwen-VL |
| Pre-warm before the window | Implemented (`OCR_PREWARM_MIN` + cron), **not exercised** | |
| `gpus` parameter (DDA) in `node.bicep` / resume script (`GPU_DDA_ENABLE`) | **Implemented, deployed empty only** | Template compiled with API `2024-05-01-preview`, regression-tested with no GPU. Attaching a GPU could not be tested |
| NVIDIA driver + CUDA in the image (`INSTALL_NVIDIA=1`) | **Written, not built** | No GPU to validate the driver against |
| GPU in Slurm | **Simulated** | `gres.conf`: `File=/dev/null`. Scheduling and accounting are identical to a real GPU; no CUDA device exists |
| Qwen-VL inference | **Not implemented** | Needs a real GPU; the demo uses tesseract on CPU |
| Controller on-prem (Arc server identity) | **Not implemented** | The POC controller is itself an Azure Local VM |

Test run (Slurm clock UTC; window opened by a 7-minute test block):

| Step | Result |
|---|---|
| `ocr_closed_daily` created by `apply` | `Flags=IGNORE_JOBS,DAILY`, next start 06:00 for 14 h; a one-shot covers the rest of the current closed period |
| Job submitted while blocked | `PENDING (ReqNodeNotAvail, May be reserved for other job)`; **no VM created** |
| Window opens 12:47:46 | ResumeProgram starts at once (gpu-01, 192.168.200.111) |
| VM ready / bootstrap incl. hook | 343 s / 461 s after the window opened |
| OCR job | 3 documents OCR'd on `gpu-01`; ends 12:55:56 |
| Decommissioning | epilog → `power_down_asap` → suspend program deletes the VM |

## Production: how to complete what is missing

1. **GPU model**: confirm the card. Arc VM DDA lists T4, A2, A16, L4, L40, L40S and RTX PRO 6000; an older
   Quadro RTX 6000 or an RTX 6000 Ada is not listed. Enable IOMMU/SR-IOV, dismount the GPUs from the
   hosts following [Manage GPUs via DDA](https://learn.microsoft.com/azure/azure-local/manage/gpu-manage-via-device),
   and read the exact `gpuName` with `az stack-hci-vm gpu list`.
2. **Enable DDA in the scripts**: in `azlocal.conf` set `GPU_DDA_ENABLE="true"` and `GPU_DDA_NAME="<gpuName>"`;
   Resume then passes `gpus=[{"assignmentType":"GpuDDA",...}]` (one per `Gres` GPU). First test with 1 node.
3. **GPU image**: `INSTALL_NVIDIA=1 image/prepare-slurm-image.sh`, publish as `slurm-ubuntu2404-gpu`, set
   `IMAGE_ID` for the GPU nodes (or use one image for everything). Check `nvidia-smi` in the VM.
4. **Real GRES**: rebuild with `-GpuGresMode nvml` (`AutoDetect=nvml`; Slurm must be built with NVML),
   or list `File=/dev/nvidia0` in `gres.conf`. Remove the simulation (`File=/dev/null`).
5. **Qwen-VL**: replace the `ocr` function in the job with the inference call (vLLM or transformers). Keep
   weights on shared storage and mount them in the hook `slurm/hooks/gpu/10-ocr-tools.sh`; add the Python environment to the image
   or a container (Apptainer/Enroot, `nvidia-container-toolkit`).
6. **On-prem controller**: the existing Slurm controller must reach ARM (HTTPS out) and the VM network
   (SSH 22, 6817/6818, NFS). Give it an identity (Arc-enable the server and keep `AZ_AUTH=msi`, or
   `AZ_AUTH=sp` with a certificate) with *Azure Stack HCI VM Contributor* on the resource group, install the
   bundle with `controller-setup.sh`, and replace NFS `/shared` by the customer's storage.
7. **Window**: `OCR_OPEN_START/END`, partition `MaxTime` ≤ window; `azlocal-ocr-window.sh apply` once (the
   reservation recurs daily and survives restarts; re-run after any `scontrol reconfigure` that drops it).
   Set `OCR_PREWARM_MIN` (≥ 10) and `SuspendTime` above it if the first job must not wait.
8. **Day-time GPU use**: if researchers use these GPUs by day, they must run in VMs created by Azure Local
   outside Slurm; DDA GPUs are exclusive, so a VM needs a free GPU at creation time. Slurm does not see them.


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
