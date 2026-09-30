# 4. Operations & troubleshooting

## Day-to-day

| Task | Command (on the controller) |
|---|---|
| Node / power states | `sinfo -N -l` — `idle~` powered down (no VM), `alloc#`/`idle#` powering up, `idle%` powering down, `down~` failed |
| Why a node is down | `scontrol show node hpc-01` (`Reason=`) |
| Provisioning log | `tail -f /var/log/slurm/azlocal-power.log` (one line per step, with durations) |
| Slurm power events | `grep -i power /var/log/slurm/slurmctld.log` (`DebugFlags=Power`) |
| VMs currently on Azure Local | `az resource list -g <rg> --resource-type Microsoft.HybridCompute/machines --tag ManagedBy=azlocal-slurm --query "[].name"` |
| Force decommission | `scontrol update nodename=hpc-01 state=power_down_force` |
| Pre-provision nodes before a campaign | `scontrol update nodename=hpc-[01-04] state=power_up` |
| Keep nodes up (disable suspend) | `SuspendExcNodes=hpc-[01-02]` in slurm.conf, `scontrol reconfigure` |
| Change VM size | edit `NodeName=… CPUs= RealMemory=` in `/etc/slurm/slurm.conf` then `scontrol reconfigure` (applies to next creation) |
| Switch lifecycle | `LIFECYCLE=persistent` in `/etc/azlocal-slurm/azlocal.conf` (no restart needed) |
| Per-job vs idle-timeout decommission | `POWER_DOWN_AFTER_JOB=true|false` in `azlocal.conf`; `SuspendTime=` in slurm.conf |

Test the programs by hand (as `slurm`):

```bash
sudo -u slurm /opt/azlocal-slurm/bin/azlocal-resume.sh hpc-01    # creates + bootstraps the VM
sudo -u slurm /opt/azlocal-slurm/bin/azlocal-suspend.sh hpc-01   # deletes it
```

(Slurm will not know about hand-made changes; prefer `scontrol update … state=power_up/power_down`.)

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `az login failed` in power log | `slurm` not in `himds` group, or Arc agent disconnected | `usermod -aG himds slurm` + `systemctl restart slurmctld`; `azcmagent show` |
| `AuthorizationFailed` on deployment | Role missing / not yet propagated | `az role assignment list --assignee <controller MI>`; wait 5 min after assignment |
| `VM deployment failed` | Image not `Succeeded`, IP already used, not enough memory on cluster | `az deployment group show -g <rg> -n slurm-hpc-01-<ts>`; check `az stack-hci-vm image show`; free capacity |
| `SSH to <ip> timed out` | VM did not boot or no network (VLAN, gateway), cloud-init NoCloud not configured in image | Azure Local VM console (`Get-VM` / `vmconnect` on a host); check lnet VLAN; rebuild image |
| Node `down~` after `ResumeTimeout` | Bootstrap failed (munge/NFS/slurmd) | `ssh -i /etc/azlocal-slurm/ssh/id_ed25519 slurmadmin@<ip> journalctl -u slurmd`; VM is removed by ResumeFailProgram — resume node with `scontrol update nodename=… state=resume` |
| `Invalid credential` in slurmd log | Munge key mismatch or clock skew | Re-run bootstrap; check chrony/Hyper-V time sync |
| Job stays `PD (Resources)` / `ReqNodeNotAvail` | Nodes `down` or drained | `sinfo -R`, then `scontrol update nodename=… state=resume` |
| VMs left behind | SuspendProgram killed / ARM error | `infra/99-teardown.ps1 -Scope Compute` or `azlocal-suspend.sh <nodes>` |
| MPI hangs between nodes | Wrong interface / name resolution | `/etc/hosts` block `azlocal-slurm` on nodes; `--mca btl_tcp_if_include <subnet>` |

## Timeouts to tune

| Parameter | POC value | Guidance |
|---|---|---|
| `ResumeTimeout` | 1800 s | ≥ 2 × measured VM create + boot + bootstrap |
| `SuspendTimeout` | 360 s | ≥ measured delete time (164–194 s in the POC); the node stays `idle%` (powering down) for this whole period and cannot be resumed before |
| `SuspendTime` | 120 s | Short = frees capacity quickly; long = reuse VMs across a job burst |
| `BOOTSTRAP_TIMEOUT` (azlocal.conf) | 1500 s | < `ResumeTimeout` |
