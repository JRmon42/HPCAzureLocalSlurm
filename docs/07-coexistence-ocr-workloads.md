# 7. Sharing Azure Local with OCR workloads (Qwen) — clarification and options

## What the requirement most likely means

| What was heard | Most likely meaning |
|---|---|
| "Qwen four OCDR jobs" | **"Qwen for OCR jobs"**: OCR (optical character recognition) and document extraction done with **Qwen vision-language models** (Qwen2.5-VL / Qwen3-VL, or the OCR-tuned *Qwen-VL-OCR*), served on GPUs (vLLM, Ollama, TGI…). "OCDR" is probably "OCR", or "OCR / document recognition". It is most likely not "Qwen 4", but confirm the model name. |
| "OCR jobs running in Azure Local" | The Azure Local instance already hosts (or will host) this OCR/inference workload. It is the **primary tenant**. |
| "Slurm jobs use the available resources without preempting the OCR jobs" | HPC jobs submitted from the **on-premises Slurm** may only use **left-over capacity** (CPU, RAM, GPU). They must never stop or slow down OCR. They are opportunistic ("scavenger") jobs. |

Sizing reference: Qwen3-VL-8B needs about 17 GB of VRAM in BF16 (24 GB recommended), and the 2B/4B models
need 5–12 GB. A single NVIDIA L4/L40S, or an Azure Local GPU partition, can host one OCR instance. OCR is
therefore mostly a **GPU + RAM** consumer, while classic HPC is mostly **CPU + RAM**.

### Questions to confirm with the customer

1. How does the OCR workload run? On **Arc VMs**, on **AKS on Azure Local** (Kubernetes pods), or outside Azure Local management?
2. Is the OCR load constant (always-on service) or bursty (batches)? Must OCR be able to **take capacity back** while a Slurm job runs? In that case Slurm jobs must be requeued or killed: Slurm is preempted, never OCR.
3. Do the Slurm jobs need **GPUs**, or only CPU?
4. Can the Slurm jobs restart, through checkpointing or `--requeue`?
5. Which Slurm version runs on premises, and can it reach the Azure Local logical network (SSH/6817/6818) and Azure Resource Manager over outbound HTTPS?

## What the platform does by itself

| Resource | Azure Local / Hyper-V behaviour | Consequence for "no preemption of OCR" |
|---|---|---|
| Memory | Static VM memory is **not overcommitted**. A VM that does not fit **fails to start**. Nothing running is evicted. | OCR is never evicted, but a Slurm VM creation can fail. The job is requeued by `ResumeFailProgram`. |
| GPU | DDA (whole GPU) or GPU-P (partition) is assigned **statically** to a VM. | A GPU used by OCR cannot be taken by Slurm. |
| CPU | vCPUs **can be oversubscribed**: VMs compete for physical cores. | **Risk: contention, not preemption.** Slurm VMs could slow OCR down. This must be controlled. |
| Storage / network | Shared (Storage Spaces Direct, NICs) | HPC I/O can affect OCR latency. Use QoS or separate volumes if needed. |

**Conclusion:** the platform never preempts OCR on its own. The design must (1) only create Slurm VMs when
real headroom exists, (2) prevent CPU contention, and (3) optionally let OCR reclaim capacity by
requeuing Slurm jobs.

## Options

### Option A — Capacity-aware elastic Slurm (extension of this POC) — *when OCR runs on Arc VMs*

The on-premises Slurm controller keeps the `ResumeProgram`/`SuspendProgram` of this repository, with three additions:

1. **Capacity guard in `azlocal-resume.sh`**: before creating a VM, compute the headroom:

   `headroom = cluster capacity − reserve for OCR − Σ(memory, vCPU, GPU of all VMs in Azure)`

   The VM list comes from `az stack-hci-vm list`. If the node does not fit, no VM is created: the
   node is set `DOWN` with reason "no capacity" and the job stays **pending** until capacity frees up
   (`ResumeFailProgram` + `--requeue`).
2. **No CPU contention**:
   * Size the Slurm pool so that the sum of all vCPUs stays ≤ the physical cores.
   * Or give Slurm VMs a low Hyper-V processor **relative weight / maximum**, or put them in a Hyper-V
     **CPU group** with a cap. These are host-level Hyper-V settings, applied by a small host-side
     script; they are not exposed through the Azure Local VM API.
3. **Reclaim for OCR (optional)**: when OCR needs to scale out, its automation calls
   `scontrol update nodename=<n> state=POWER_DOWN_FORCE` (or `scancel`/`requeue`). The Slurm VMs are
   deleted and the capacity is returned. Jobs submitted with `--requeue` are restarted later.

Slurm-side: a dedicated partition `azlocal` with a low priority QOS. A `MaxNodes` cap or `GrpTRES` limits
how much of Azure Local Slurm can ever take. GPU jobs: the node template can request a GPU partition
(`hardwareProfile.virtualMachineGPUs`, GPU-P, preview), so Slurm only takes GPU partitions that OCR is
not using.

**Pros:** reuses the validated POC; the customer's Slurm stays the single entry point; clean VM per job.
**Cons:** about 4–5 min VM start-up; capacity accounting is done by the scripts.

### Option B — Kubernetes as the arbiter (Slinky) — *when OCR runs on AKS on Azure Local*

If the OCR service runs as pods on **AKS enabled by Azure Arc** (typical for vLLM serving Qwen), let Kubernetes arbitrate:

* Deploy **Slurm workers as pods** with SchedMD/NVIDIA **Slinky** (`slurm-operator`), or let Slurm schedule
  pods with `slurm-bridge`.
* OCR pods get a **high `PriorityClass`**; Slurm worker pods get a **low, preemptible** one.
  Kubernetes then *evicts Slurm pods* (never OCR) when OCR needs room. Slurm sees the node go away and
  requeues the job.
* Start-up is seconds (pod), not minutes (VM). Autoscaling of Slurm workers is handled by the operator.
* On-premises users submit to this Slurm cluster through **multi-cluster** (`sbatch -M azlocal`, shared
  `slurmdbd`) or directly.

Limitations to check: on AKS Arc, GPUs are exposed with DDA (whole GPU), not GPU-P. Multi-node MPI in pods
needs host networking and tuning. It also needs Slurm ≥ 25.x for Slinky.

### Option C — Static split

Dedicate hosts or GPUs to OCR and the rest to Slurm (fixed partitions or always-on Slurm nodes). There is no
interference at all and nothing to build, but capacity is idle when one side is quiet.

## Recommendation

| If… | Then |
|---|---|
| OCR runs on Arc VMs, Slurm jobs are mainly CPU | **Option A**: this POC plus a capacity guard and CPU caps |
| OCR runs on AKS / containers and must reclaim capacity quickly | **Option B**: Slinky with Kubernetes priorities |
| Strict isolation matters more than utilization | **Option C** |

In all cases: Slurm jobs are submitted from the **existing on-premises Slurm** (partition `azlocal`). Its
controller runs the resume/suspend programs and authenticates to Azure either:

* with the managed identity of the **Arc-enabled server** that hosts `slurmctld`, or
* with a service principal and certificate (`AZ_AUTH=sp` in `azlocal.conf`).

No Slurm controller VM is needed on Azure Local.
