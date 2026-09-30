# 3. Deployment guide

All scripts are PowerShell 7 (Windows, Linux or macOS) calling Azure CLI ≥ 2.60. Bash scripts under
`slurm/` and `image/` run on Linux VMs and are delivered by the PowerShell scripts.

```text
00-prereqs.ps1 ─► 01-deploy-localbox.ps1 ─► (Azure Local ready) ─► 02-build-golden-image.ps1 ─► 03-deploy-controller.ps1 ─► 04-run-e2e.ps1
   RPs, RG,          POC only: nested            ~3-6 h                 Build (Azure VM)            controller VM + MI RBAC        submit jobs,
   exemption         Azure Local                                        + Publish to Azure Local    + Slurm config (Run Command)   verify create/delete
```

## Prerequisites

* Azure subscription with **Owner** (role assignments are created) — POC: `7771d4f4-…`, tenant `8181de63-…`
* Azure CLI with extensions `stack-hci-vm`, `customlocation`, `connectedmachine` (auto-installed on first use:
  `az config set extension.use_dynamic_install=yes_without_prompt`)
* For the POC Azure Local: quota for one `Standard_E32s_v5` (32 vCPU ESv5) in the host region
* For a customer deployment: an existing **Azure Local instance** with Arc VM management (resource bridge +
  custom location) and a **logical network** reachable from the users

```powershell
az login --tenant 8181de63-3f9c-40ed-9967-94512f7a75fe
az account set --subscription 7771d4f4-8927-4d73-bd3d-6e6e2ed5d2aa
$rg = 'rg-hpc-azlocal-slurm'
```

## Step 0 – Subscription prerequisites

```powershell
./infra/00-prereqs.ps1 -SubscriptionId 7771d4f4-8927-4d73-bd3d-6e6e2ed5d2aa -ResourceGroup $rg `
  -PolicyAssignmentId '/providers/Microsoft.Management/managementGroups/<mg>/providers/Microsoft.Authorization/policyAssignments/<MCAPSGovDeployPolicies>'
```

Registers the resource providers, creates the resource group and — only in governed tenants — a **Waiver
exemption scoped to the resource group** for the Modify policies that disable storage account keys /
public access and Key Vault public access. Azure Local cluster deployment needs a cloud-witness storage
account accessed with its key and a reachable Key Vault.

## Step 1 – Azure Local (POC only: LocalBox)

```powershell
./infra/01-deploy-localbox.ps1 -ResourceGroup $rg -TenantId 8181de63-3f9c-40ed-9967-94512f7a75fe `
  -AdminPassword (Read-Host -AsSecureString) -Location swedencentral -AzureLocalInstanceLocation eastus
```

* The ARM part takes ~15 min; then the `LocalBox-Client` VM logs on automatically and builds the 2-node
  cluster, registers it in Azure, deploys the Arc resource bridge, the custom location `jumpstart` and
  the logical network `localbox-vm-lnet-vlan200` (3–6 hours). Logs: `C:\LocalBox\Logs` on the host VM.
* `AzureLocalInstanceLocation` must be a region supported by Azure Local (e.g. `eastus`, `westeurope`,
  `australiaeast`…). In the POC tenant West Europe is blocked by policy, hence `eastus`.
* Ready when: `az customlocation show -g $rg -n jumpstart` and
  `az stack-hci-vm network lnet show -g $rg -n localbox-vm-lnet-vlan200` both return `Succeeded`.

**Customer environment:** skip this step and pass your own `-CustomLocationName` / `-LogicalNetworkName`
to the next scripts. Reserve a static IP for the controller and a range for the compute nodes on the
logical network (or use an IP pool and leave `-NodeIpBase` empty).

## Step 2 – Golden image

```powershell
./infra/02-build-golden-image.ps1 -ResourceGroup $rg -Stage Build     # any time (Azure VM)
./infra/02-build-golden-image.ps1 -ResourceGroup $rg -Stage Publish   # once Azure Local is ready
./infra/02-build-golden-image.ps1 -ResourceGroup $rg -Stage Cleanup
```

Build creates a temporary Ubuntu 24.04 Azure VM (no inbound access), runs
[`image/prepare-slurm-image.sh`](../image/prepare-slurm-image.sh) through Run Command, generalizes it for
Azure Local (cloud-init `NoCloud` datasource, per the
[Azure Local Ubuntu image guidance](https://learn.microsoft.com/azure/azure-local/manage/virtual-machine-azure-marketplace-ubuntu))
and deallocates it. Publish creates a read SAS on the OS disk and imports it with
`az stack-hci-vm image create --image-path <SAS>`.

## Step 3 – Slurm controller

```powershell
./infra/03-deploy-controller.ps1 -ResourceGroup $rg `
  -ControllerIp 192.168.200.10 -NodeRange 'hpc-[01-04]' -NodeCpus 2 -NodeRealMemoryMB 3500 `
  -NodeIpPrefix '192.168.200.' -NodeIpBase 100 -SuspendTime 120 -Lifecycle ephemeral
```

1. Deploys the controller VM with [`infra/bicep/node.bicep`](../infra/bicep/node.bicep) (guest management
   enabled) and waits for its Arc agent.
2. Grants its managed identity **Azure Stack HCI VM Contributor** on the resource group.
3. Builds a bundle (`slurm/bin`, `node.json`, `slurm.conf.tpl`, rendered `azlocal.conf`) and runs
   [`slurm/controller/controller-setup.sh`](../slurm/controller/controller-setup.sh) with **Arc Run Command**:
   munge key, SSH bootstrap key, NFS `/shared`, `slurm.conf`, check of `az login --identity` as `slurm`,
   `slurmctld` start.

Change node shapes by editing `-NodeCpus/-NodeRealMemoryMB` (or `NodeName=` lines in
`/etc/slurm/slurm.conf`, then `scontrol reconfigure`): VMs are sized from the Slurm definition.

## Step 4 – End-to-end test

```powershell
./infra/04-run-e2e.ps1 -ResourceGroup $rg
```

Uploads [`tests/`](../tests) to the controller, and runs [`tests/e2e-test.sh`](../tests/e2e-test.sh) which, for
`hello.sbatch` (2 nodes × 2 tasks) and `mpi.sbatch` (OpenMPI ring over 4 ranks):
submits the job as `hpcuser` → checks that the VMs appear in Azure while it runs → waits for completion →
checks that the VMs are deleted and nodes return to `idle~`. Prints timings and `E2E-PASS`.

Ad-hoc commands on the controller (no inbound connectivity needed):

```powershell
./infra/04-run-e2e.ps1 -ResourceGroup $rg -Command 'sinfo; squeue; tail -n 30 /var/log/slurm/azlocal-power.log'
```

## Users

Users connect to the controller (login node) with SSH on the logical network and use Slurm normally:

```bash
sbatch -N 2 --ntasks-per-node=2 job.sh     # nodes are created, job runs, nodes are deleted
sinfo                                      # idle~ = powered down (no VM), alloc# / mix# = powering up
```

## Teardown

```powershell
./infra/99-teardown.ps1 -ResourceGroup $rg -Scope Compute   # remove any leftover compute VM
./infra/99-teardown.ps1 -ResourceGroup $rg -Scope Slurm     # + controller and image
./infra/99-teardown.ps1 -ResourceGroup $rg -Scope All       # whole resource group (POC)
```

The POC LocalBox host (`Standard_E32s_v5`) is the main cost; stop it with
`az vm deallocate -g $rg -n LocalBox-Client` when not in use (the nested cluster restarts with it).
