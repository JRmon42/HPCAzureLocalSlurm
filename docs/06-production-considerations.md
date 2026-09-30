# 6. From POC to production

| Area | POC | Production recommendation |
|---|---|---|
| **Azure Local** | LocalBox: 2 nested nodes in one Azure VM | Validated Azure Local hardware; size the cluster for peak HPC VMs + other workloads; consider a dedicated cluster for HPC |
| **Performance** | Nested virtualization, 2 vCPU VMs | Physical Azure Local nodes; large VMs (e.g. 1 VM per NUMA node or per host); disable dynamic memory (template sets static memory); pin HPC VMs with anti-affinity if desired |
| **Interconnect** | TCP over VLAN | RDMA-capable NICs (RoCEv2/iWARP) for storage; for MPI, SR-IOV/DDA is limited on Azure Local VMs — benchmark TCP vs. needs; very latency-sensitive MPI may justify bare metal or Azure HPC (CycleCloud bursting) |
| **GPU** | – | Azure Local GPU partitioning (GPU-P) / DDA; add GPU properties to `node.bicep` and `Gres=` in slurm.conf |
| **Provisioning latency** | Measured in [05-poc-results.md](05-poc-results.md) | Keep image small; use `LIFECYCLE=persistent` for latency-sensitive queues; pre-power nodes before campaigns (`state=power_up`); set `SuspendTime` to cover job bursts |
| **Controller HA** | Single VM | Two controllers (`SlurmctldHost` ×2) with `StateSaveLocation` on shared storage; Azure Local VM HA (failover cluster) already restarts the VM on host failure |
| **Accounting** | none | `slurmdbd` + MariaDB (on the controller or a separate VM) for fair-share and reporting |
| **Shared storage** | NFS from the controller | Dedicated file server / Scale-Out File Server / NAS; separate `/home` and `/scratch` |
| **Identity (users)** | Local `hpcuser` (UID 5000) | AD/LDAP via SSSD in the image (Azure Local is AD-joined — reuse the domain) |
| **Identity (automation)** | Arc managed identity | Keep; scope RBAC to a dedicated resource group; optionally custom role limited to the used actions |
| **Image lifecycle** | Built once | Pipeline (Packer/Azure Image Builder → Azure Local image), monthly patch, versioned image names; update `IMAGE_ID` in `azlocal.conf` |
| **Security** | Munge + SSH key | Restrict SSH on nodes to the controller (NSG on the logical network / host firewall); rotate munge key; Defender for Servers on the controller |
| **Governance** | RG policy exemption for witness/Key Vault | Agree exemptions with the governance team; use private endpoints where supported |
| **Monitoring** | Logs on controller | Azure Monitor Agent on the controller (Arc) → Log Analytics; alert on `down~` nodes and failed deployments; Azure Local Insights |
| **Scale** | 4 nodes | Slurm handles thousands of CLOUD nodes; the scripts run one ARM deployment per node in parallel — for large bursts, stay within [ARM throttling limits](https://learn.microsoft.com/azure/azure-resource-manager/management/request-limits-and-throttling) and Azure Local capacity (e.g. cap `ResumeRate`) |
| **Multiple node shapes** | 1 shape | Several `NodeName` lines / partitions (e.g. `small`, `large`, `gpu`); VM size follows the node definition automatically |
| **Hybrid burst** | – | Add Azure CycleCloud (or a second partition with a cloud ResumeProgram) to burst to Azure HPC SKUs when Azure Local is full |

## Known limitations

* VM creation copies the image VHDX; the first VMs on a new cluster may be slower (image cache).
* The Azure Local VM API version used has no user-data; bootstrap therefore needs SSH from the controller to the node.
* `az stack-hci-vm` CLI does not support arbitrary vCPU/RAM on `create`; the ARM template does.
* In `persistent` mode a VM keeps its IP and disks; changing the Slurm node size requires deleting the VM once.
