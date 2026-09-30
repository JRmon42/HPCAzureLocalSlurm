# 1. Solution overview

## Customer requirement

Run HPC workloads on **Azure Local** (on-premises, formerly Azure Stack HCI) with **Slurm** as the
workload manager, **without keeping compute VMs running permanently**:

* when a job is submitted, the compute VMs it needs are **provisioned automatically**;
* when the job ends, those VMs are **decommissioned automatically**, returning CPU, memory and
  storage to the Azure Local cluster for other workloads.

## Can Azure CycleCloud do it?

**No.** Azure CycleCloud is the Microsoft product that does exactly this pattern (autoscaling Slurm
nodes on demand), but only against **Azure public-cloud** compute (VMs / VM Scale Sets through the
`Microsoft.Compute` provider). It has no provider for Azure Local or Arc-enabled VMs:

| Question | Answer |
|---|---|
| Can CycleCloud be installed on an Azure Local VM? | Technically yes (it is a Linux application), but it can only create nodes in Azure regions. |
| Can CycleCloud create/delete VMs on Azure Local? | **No** — no `Microsoft.AzureStackHCI` / custom-location support. |
| Is there a CycleCloud "hybrid" feature? | Only **bursting**: an on-premises scheduler can add nodes *in Azure* (see option D). |

References: [CycleCloud overview](https://learn.microsoft.com/azure/cyclecloud/overview),
[CycleCloud Slurm project](https://github.com/Azure/cyclecloud-slurm) (node arrays map to Azure VM Scale Sets).

## Options considered

| # | Option | How elastic nodes are created | Pros | Cons | Verdict |
|---|---|---|---|---|---|
| **A** | **Slurm power saving + Azure Local VM API** (this repo) | Slurm `ResumeProgram` / `SuspendProgram` call ARM → Arc resource bridge → Azure Local VM | Native Slurm feature (same mechanism CycleCloud uses internally); VMs visible/governed in Azure (RBAC, tags, Activity Log, Policy); no custom agent on the hosts; works with any Slurm version ≥ 22.05 | ~5–10 min VM provisioning latency (image copy + boot); the scripts are yours to maintain | ✅ **Chosen** |
| B | Slurm on Kubernetes (AKS enabled by Azure Arc + [Slinky slurm-operator](https://github.com/SlinkyProject/slurm-operator)) | Kubernetes autoscaling of `slurmd` pods; AKS Arc node-pool autoscaler adds VMs | Container-native; fast pod start once nodes exist | Two orchestrators (K8s + Slurm); MPI/RDMA in pods is harder; AKS Arc autoscaler granularity is node pools; Slinky is young | Good for containerised AI, not first choice for classic MPI HPC |
| C | Slurm power saving + direct Hyper-V / Failover Cluster (WinRM, PowerShell) | `New-VM` on the hosts from the controller | Fastest (can use differencing disks); no Azure dependency | Bypasses Azure Local management plane (VMs invisible to Azure/Arc, unsupported for Arc VMs), needs Windows admin creds on the controller | ❌ Not recommended |
| D | CycleCloud hybrid **bursting** to Azure | On-prem Slurm + CycleCloud creates nodes in an Azure region | Unlimited cloud capacity, HPC SKUs with InfiniBand | Nodes are **not** on Azure Local; data egress & latency | Complementary: can be added on top of A |
| E | Persistent VMs, started/stopped | VMs created once, `az stack-hci-vm start/stop` | Faster resume (~1–2 min), no image copy | Disks stay allocated | Supported by this solution (`LIFECYCLE=persistent`) |

## Chosen design (option A)

Slurm has a built-in **power saving / elastic cloud** framework
([power_save](https://slurm.schedmd.com/power_save.html), [elastic_computing](https://slurm.schedmd.com/elastic_computing.html)):

* nodes are declared `State=CLOUD`; when powered down they have **no VM at all**;
* when the scheduler needs them for a job it runs `ResumeProgram <hostlist>`;
* when they have been idle for `SuspendTime` seconds it runs `SuspendProgram <hostlist>`.

This repository implements those programs for Azure Local:

1. `azlocal-resume.sh` logs in with the controller's **Arc managed identity** and deploys an ARM
   template (`node.json`) that creates a NIC on an Azure Local **logical network**, an Arc machine and an
   Azure Local **VM instance** sized from the Slurm node definition (`CPUs`, `RealMemory`), from a
   **golden image** that already contains Slurm/munge/OpenMPI.
2. Once the VM answers on SSH, the controller pushes the munge key and starts `slurmd` in
   **configless** mode (`--conf-server`); the node registers and the job starts.
3. When the job ends, `EpilogSlurmctld` puts the job's nodes in `POWER_DOWN_ASAP` (strict per-job
   decommissioning; optional — otherwise `SuspendTime` applies) and `azlocal-suspend.sh` deletes the
   VM instance, Arc machine and NIC.
4. `azlocal-resume-fail.sh` cleans up VMs that did not join within `ResumeTimeout`.

Everything goes through the **Azure Local management plane** (ARM + Arc resource bridge), so the VMs are
first-class Azure Local VMs: RBAC, tags, Azure Policy, Activity Log and the Azure portal all see them.

See [02-architecture.md](02-architecture.md) for the detailed design.
