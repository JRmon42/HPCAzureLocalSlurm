# /etc/azlocal-slurm/azlocal.conf - sourced by the Slurm power-saving programs.
# Rendered by infra/03-deploy-controller.ps1; placeholders are __UPPERCASE__.

# ---- Azure Local target (ARM resource IDs) ----
SUBSCRIPTION_ID="__SUBSCRIPTION_ID__"
RESOURCE_GROUP="__RESOURCE_GROUP__"
LOCATION="__LOCATION__"                     # region of the custom location, e.g. eastus
CUSTOM_LOCATION_ID="__CUSTOM_LOCATION_ID__"
LOGICAL_NETWORK_ID="__LOGICAL_NETWORK_ID__"
IMAGE_ID="__IMAGE_ID__"
STORAGE_PATH_ID=""                          # empty = Azure Local chooses the storage path

# ---- Networking ----
CONTROLLER_IP="__CONTROLLER_IP__"
# Deterministic static IPs: <prefix><base + trailing node number>, e.g. hpc-03 -> 192.168.200.103.
# Leave NODE_IP_BASE empty to let Azure Local allocate from the logical network IP pool.
NODE_IP_PREFIX="__NODE_IP_PREFIX__"
NODE_IP_BASE="__NODE_IP_BASE__"

# ---- Lifecycle ----
# ephemeral : ResumeProgram creates the VM, SuspendProgram deletes it (no footprint when idle)
# persistent: VMs are created once, then started/stopped (faster resume, disks kept)
LIFECYCLE="ephemeral"
# true: EpilogSlurmctld marks the job's nodes POWER_DOWN_ASAP => VM decommissioned right after the job
POWER_DOWN_AFTER_JOB="true"
MEMORY_OVERHEAD_MB=512                       # VM memory = Slurm RealMemory + overhead (rounded up to 1 GiB)

# ---- Authentication to Azure Resource Manager ----
# msi: system-assigned managed identity of the Arc-enabled controller VM (no secret on disk)
# sp : service principal with certificate (SP_APP_ID, SP_TENANT_ID, SP_CERT_FILE)
AZ_AUTH="msi"
SP_APP_ID=""
SP_TENANT_ID=""
SP_CERT_FILE=""

# ---- Node bootstrap ----
ADMIN_USER="slurmadmin"
SSH_KEY="/etc/azlocal-slurm/ssh/id_ed25519"
MUNGE_KEY_COPY="/etc/azlocal-slurm/munge.key"
BOOTSTRAP_TIMEOUT=1500                       # seconds to wait for SSH + slurmd after VM creation

# ---- Paths ----
INSTALL_DIR="/opt/azlocal-slurm"
LOG_FILE="/var/log/slurm/azlocal-power.log"
