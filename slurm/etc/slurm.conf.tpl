# /etc/slurm/slurm.conf - Slurm on Azure Local with elastic (power-saving) compute VMs.
# Rendered by slurm/controller/controller-setup.sh. Compute nodes run configless and
# fetch this file from slurmctld.
ClusterName=__CLUSTER_NAME__
SlurmctldHost=__CONTROLLER_NAME__(__CONTROLLER_IP__)
SlurmUser=slurm
AuthType=auth/munge
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldDebug=info
SlurmdDebug=info
DebugFlags=Power

# ---- Scheduling ----
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_CPU
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none
MpiDefault=none
JobAcctGatherType=jobacct_gather/none
AccountingStorageType=accounting_storage/none
ReturnToService=2
SlurmdTimeout=300
InactiveLimit=0
KillWait=30
MinJobAge=300

# ---- Elastic compute on Azure Local (Slurm power saving) ----
#  enable_configless   : slurmd pulls slurm.conf from slurmctld (no config on the image)
#  cloud_reg_addrs     : a node's address is taken from its slurmd registration
#  idle_on_node_suspend: a node that failed is made available again once its VM is removed
SlurmctldParameters=enable_configless,cloud_reg_addrs,idle_on_node_suspend
CommunicationParameters=NoAddrCache
PrivateData=cloud
TreeWidth=65533
ResumeProgram=/opt/azlocal-slurm/bin/azlocal-resume.sh
SuspendProgram=/opt/azlocal-slurm/bin/azlocal-suspend.sh
ResumeFailProgram=/opt/azlocal-slurm/bin/azlocal-resume-fail.sh
EpilogSlurmctld=/opt/azlocal-slurm/bin/azlocal-epilog-slurmctld.sh
# Idle seconds before a VM is decommissioned (POWER_DOWN_AFTER_JOB makes it immediate)
SuspendTime=__SUSPEND_TIME__
# Max seconds for the SuspendProgram (VM delete) before the node can be resumed again
SuspendTimeout=360
# Max seconds from ResumeProgram start until slurmd registers (VM create + boot + bootstrap)
ResumeTimeout=1800
ResumeRate=0
SuspendRate=0

# ---- Nodes: VMs that exist on Azure Local only while they have work ----
# CPUs / RealMemory also size the VM (see azlocal-resume.sh).
NodeName=__NODE_RANGE__ CPUs=__NODE_CPUS__ RealMemory=__NODE_MEMORY__ State=CLOUD Feature=azlocal
PartitionName=hpc Nodes=__NODE_RANGE__ Default=YES MaxTime=INFINITE State=UP
