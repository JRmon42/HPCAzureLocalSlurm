# 5. POC results

The POC was built and validated end to end on **30 September 2026** in tenant `8181de63-…`, subscription
`7771d4f4-8927-4d73-bd3d-6e6e2ed5d2aa`, resource group **`rg-hpc-azlocal-slurm`**.

**Result: E2E-PASS.** Slurm jobs submitted to an empty partition caused Azure Local VMs to be created,
bootstrapped and registered. The jobs ran (including a 4-rank multi-node MPI job), and the VMs, their Arc
machines and their NICs were deleted automatically after the jobs finished. No resource and no disk was
left behind.

## Deployed environment

| Component | Resource | Details |
|---|---|---|
| Azure Local host (POC only) | `LocalBox-Client` (Azure VM, swedencentral) | `Standard_E32s_v5`, Jumpstart LocalBox, nested Hyper-V |
| Azure Local instance | `localboxcluster` (registered in `eastus`) | 2 nodes `AzLHOST1/2`, version 10.0.26100, status Connected |
| Arc VM management | `localboxcluster-arcbridge`, custom location `jumpstart` | Storage paths `UserStorage1/2` |
| Logical network | `localbox-vm-lnet-vlan200` | VLAN 200, `192.168.200.0/24`, static, gateway `.1`, DNS `192.168.1.254` |
| Golden image | `slurm-ubuntu2404` | Ubuntu 24.04 + Slurm 23.11 + munge + OpenMPI + NFS client, 30 GB VHD (4.36 GB download) |
| Slurm controller | `slurmctl` (Arc VM, `192.168.200.10`) | 4 vCPU / 8 GB, Arc agent + system-assigned MI, role *Azure Stack HCI VM Contributor* on the RG |
| Compute pool | `hpc-[01-04]` (`State=CLOUD`) | 2 vCPU / 4 GB each, `192.168.200.101-104`; **exist only while needed** |

## Build timeline

| Step | Duration (measured) |
|---|---|
| LocalBox ARM deployment (network, host VM, bootstrap) | 12 min |
| Azure Local cluster: host configuration → validation → deployment | ≈ 4 h 50 min from start (validation 52 min, deployment 2 h 25 min) |
| Logical network creation | ≈ 1 min |
| Golden image build on an Azure VM (Build stage) | ≈ 20 min |
| Image publish: disk → staging blob copy (32 GB) | ≈ 12 min |
| Image publish: download into Azure Local (`slurm-ubuntu2404`) | 48 min (14:13 → 15:01 UTC) |
| Controller VM deployment (ARM, guest management) | 4 min 51 s |
| Controller configuration (Arc Run Command) | ≈ 3 min |

## End-to-end test evidence

The test ran three times, with six jobs in total. Each job created and deleted 2 VMs, for 12 VM
lifecycles overall. Run 1 validated the mechanism; its harness reported FAIL only because of test-script
bugs, which were fixed. Runs 2 and 3 reported **E2E-PASS**. The final run log is
`/shared/jobs/e2e-20260930-211932.log` on the controller, and every power action is in
`/var/log/slurm/azlocal-power.log`.

### Final run (run 3) – `infra/04-run-e2e.ps1`

```text
=== E2E start 2026-09-30T19:19:44Z on slurmctl ===
hpc-01 idle~  hpc-02 idle~  hpc-03 idle~  hpc-04 idle~
Azure Local compute resources before: []

=== hello.sbatch ===
19:19:53 submitted job 5
19:20:26 CONFIGURING: Azure Local VMs present: [hpc-01] (job nodes hpc-[01-02])
19:20:47 CONFIGURING: Azure Local VMs present: [hpc-01 hpc-02] (job nodes hpc-[01-02])
19:23:59 job 5 COMPLETED after 246s (nodes hpc-[01-02]): provisioning wait 246s, execution 0s
--- job output ---
Job 5 started 2026-09-30T19:23:59Z on hpc-[01-02]
task 0 on hpc-01 (192.168.200.101) cpus=2 mem=3915MB
task 2 on hpc-02 (192.168.200.102) cpus=2 mem=3915MB
task 1 on hpc-01 (192.168.200.101) cpus=2 mem=3915MB
task 3 on hpc-02 (192.168.200.102) cpus=2 mem=3915MB
Job 5 finished 2026-09-30T19:23:59Z
------------------
19:26:50 VM, Arc machine and NIC deleted 164s after job end; resources left: []; Slurm node state: idle%

=== mpi.sbatch ===
19:26:50 submitted job 6
19:27:37 CONFIGURING: Azure Local VMs present: [hpc-04] (job nodes hpc-[03-04])
19:27:49 CONFIGURING: Azure Local VMs present: [hpc-03 hpc-04] (job nodes hpc-[03-04])
19:31:06 job 6 COMPLETED after 256s (nodes hpc-[03-04]): provisioning wait 249s, execution 2s
--- job output ---
Job 6 on hpc-[03-04]
rank 1 on hpc-03: received token 42
rank 2 on hpc-04: received token 42
rank 3 on hpc-04: received token 42
rank 0 on hpc-03: token 42 went around 4 ranks - MPI OK
------------------
19:34:14 VM, Arc machine and NIC deleted 180s after job end; resources left: []; Slurm node state: idle%

E2E-PASS
```

The MPI job was scheduled on `hpc-[03-04]` because `hpc-[01-02]` were still `POWERING_DOWN` (`idle%`,
`SuspendTimeout`). Slurm automatically picks other powered-down nodes of the pool.

### Power log (controller, run 3)

```text
19:19:54Z resume request: hpc-[01-02] (lifecycle=ephemeral)
19:23:04Z hpc-01: VM ready in 187s, ip=192.168.200.101
19:23:19Z hpc-01: bootstrap done, total 202s (slurmd will register)
19:23:34Z hpc-02: VM ready in 217s, ip=192.168.200.102
19:23:48Z hpc-02: bootstrap done, total 231s (slurmd will register)
19:23:59Z [epilog] job 5 ended -> power_down_asap hpc-[01-02]
19:24:00Z suspend request: hpc-[01-02] (lifecycle=ephemeral)
19:26:46Z hpc-01: VM decommissioned in 163s
19:26:46Z hpc-02: VM decommissioned in 163s
19:26:51Z resume request: hpc-[03-04]
19:30:31Z hpc-03: VM ready in 217s / hpc-04: VM ready in 217s
19:30:44Z hpc-03, hpc-04: bootstrap done, total 230s
19:31:01Z [epilog] job 6 ended -> power_down_asap hpc-[03-04]
19:33:48Z hpc-03: VM decommissioned in 163s / hpc-04: VM decommissioned in 163s
```

## Measured latencies (6 jobs, 12 VM lifecycles)

| Phase | Min | Max | Typical | What happens |
|---|---|---|---|---|
| Submit → `ResumeProgram` invoked | < 1 s | 1 s | < 1 s | Slurm powers up `State=CLOUD` nodes immediately (`ResumeRate=0`) |
| ARM deployment + VM create + boot + SSH reachable ("VM ready") | 187 s | 278 s | ≈ 3.7 min | NIC + Arc machine + VM instance; the 30 GB image VHD is **copied** to create the OS disk |
| SSH bootstrap (munge key, `/etc/hosts`, NFS, configless `slurmd`) | 11 s | 15 s | 12 s | `node-bootstrap.sh` pushed from the controller |
| **Submit → job start** (both nodes of the job) | **246 s** | **301 s** | **≈ 4.6 min** | Slurm waits for the slowest node of the job |
| Job end → `SuspendProgram` invoked | < 1 s | 1 s | < 1 s | `EpilogSlurmctld` → `scontrol update state=POWER_DOWN_ASAP` |
| **Decommission** (VM + Arc machine + NIC deleted) | **163 s** | **194 s** | **≈ 2.8 min** | `az stack-hci-vm delete`, `connectedmachine delete`, NIC delete; nodes in parallel |
| Node reusable (`idle%` → `idle~`) | 360 s | 360 s | 360 s | `SuspendTimeout` — Slurm keeps the node powering down for the full timeout |

Each run started and ended with **zero compute resources**: no `hpc-*` VM, Arc machine or NIC in
Azure. The Azure Local hosts were also checked after the runs through PowerShell Direct on `AzLHOST1`.
Only the image (`slurm-ubuntu2404.vhd`) and the controller OS disk remain on the cluster shared volumes,
so the VM delete also removes the OS disk.

## Issues found during the POC and their resolution

| # | Issue | Root cause | Resolution (in the repo) |
|---|---|---|---|
| 1 | CycleCloud cannot be used | CycleCloud only orchestrates Azure public-cloud VMs/VMSS | Slurm power-saving programs calling the Azure Local ARM API ([01](01-solution-overview.md)) |
| 2 | Storage account / Key Vault modified by policy during cluster deployment | MCAPS governance Modify policies disable key access and public access | RG-scoped Waiver exemption (`00-prereqs.ps1`) |
| 3 | Azure Local region `westeurope` denied | Tenant policy `sys.blockwesteurope` | Azure Local instance registered in `eastus` (the host VM stays in `swedencentral`) |
| 4 | No VM logical network after LocalBox | LocalBox does not create one when deploying automatically | New script `01b-create-logical-network.ps1` |
| 5 | Image import failed with `500 OperationTimedOut` | Azure Local cannot download from a managed-disk SAS (`md-*.blob.storage.azure.net`) | Publish copies the disk to a page blob in a temporary storage account first (`02-build-golden-image.ps1`) |
| 6 | `az disk grant-access --query accessSas` returned nothing | Property is `accessSAS` (JMESPath is case-sensitive) | Fixed query |
| 7 | `az stack-hci-vm … -n` rejected | The extension only accepts `--name` | All scripts/docs use `--name` |
| 8 | JMESPath filters / vSwitch name `ConvergedSwitch(compute_management)` broken on Windows | `az.cmd` goes through `cmd.exe`, which mangles parentheses | Filter in PowerShell; quote the argument on Windows |
| 9 | Controller setup failed at name resolution | `scontrol show hostnames` needs a `slurm.conf` | `slurm.conf` is written before `/etc/hosts` generation |
| 10 | Nodes stayed `idle%` for 10 min after a delete of ≈3 min | `SuspendTimeout=600` is always waited in full | `SuspendTimeout=360` (≈ 2 × measured delete time) |
| 11 | E2E harness reported FAIL although jobs worked | Short jobs finished between two polls; decommission loop waited for `idle~` | Harness samples VMs during `CONFIGURING`, checks every `hpc-*` ARM resource, accepts `idle%` |

## Optimization opportunities found

* **VM creation time is dominated by the OS disk copy.** The image is a 30 GB *fixed* VHD (exported
  from Azure), and every new VM copies it. Converting the golden image to a small **dynamic VHDX**
  (`Convert-VHD -VHDType Dynamic`, or building the image on Azure Local) should cut the ~3.5 min create
  time noticeably.
* **Guest management off on compute nodes** is already applied: no Arc agent install on each boot.
* For latency-sensitive queues, `LIFECYCLE=persistent` stops and starts VMs instead of deleting and
  creating them (disks are kept). A longer `SuspendTime` keeps VMs warm across bursts of jobs.

## Cost and teardown

The dominant POC cost is the LocalBox host VM (`Standard_E32s_v5` plus premium data disks). Azure Local
itself adds no Azure compute charge for the nested POC; see the Azure Local pricing page for production.
When the POC is not in use:

```powershell
az vm deallocate -g rg-hpc-azlocal-slurm -n LocalBox-Client      # stop (nested cluster stops with it)
az vm start      -g rg-hpc-azlocal-slurm -n LocalBox-Client      # resume later (allow ~15 min for Arc to reconnect)
./infra/99-teardown.ps1 -ResourceGroup rg-hpc-azlocal-slurm -Scope All   # delete everything
```
