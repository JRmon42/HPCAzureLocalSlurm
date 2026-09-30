#!/usr/bin/env bash
# Builds the "golden" Slurm image used for BOTH the Slurm controller and the
# elastic compute nodes on Azure Local.
#
# Runs inside a temporary Ubuntu 24.04 Azure VM (Azure Marketplace image). At the
# end, the VM is generalized for Azure Local (cloud-init NoCloud datasource),
# following https://learn.microsoft.com/azure/azure-local/manage/virtual-machine-azure-marketplace-ubuntu
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

HPC_USER=hpcuser
HPC_UID=5000

# Wait for any boot-time apt/cloud-init activity to finish
cloud-init status --wait || true
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 5; done

apt-get update -y
apt-get install -y --no-install-recommends \
  munge libmunge2 \
  slurmctld slurmd slurm-client slurm-wlm-basic-plugins \
  openmpi-bin libopenmpi-dev build-essential \
  nfs-kernel-server nfs-common \
  jq curl ca-certificates gnupg lsb-release chrony netcat-openbsd psmisc

# Azure CLI (used only on the controller by the Slurm Resume/Suspend programs)
curl -sL https://aka.ms/InstallAzureCLIDeb | bash
mkdir -p /opt/azlocal-slurm/cliextensions
AZURE_EXTENSION_DIR=/opt/azlocal-slurm/cliextensions az extension add --name stack-hci-vm --yes --only-show-errors
AZURE_EXTENSION_DIR=/opt/azlocal-slurm/cliextensions az extension add --name customlocation --yes --only-show-errors
chmod -R a+rX /opt/azlocal-slurm

# Common HPC user with a fixed UID across controller and compute nodes.
# Its home directory lives on the controller NFS export (/shared).
mkdir -p /shared/home
if ! id "$HPC_USER" >/dev/null 2>&1; then
  groupadd -g "$HPC_UID" "$HPC_USER"
  useradd -M -u "$HPC_UID" -g "$HPC_UID" -s /bin/bash -d "/shared/home/$HPC_USER" "$HPC_USER"
fi

# Services are enabled at role-assignment time (controller setup / node bootstrap),
# never baked into the image. The image-wide munge key is removed so every cluster
# generates its own secret.
systemctl disable --now slurmctld slurmd munge nfs-kernel-server || true
rm -f /etc/munge/munge.key

cat >/etc/azlocal-slurm-image <<EOF
image=slurm-ubuntu2404
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
slurm=$(dpkg-query -W -f='${Version}' slurmd)
munge=$(dpkg-query -W -f='${Version}' munge)
kernel=$(uname -r)
EOF
cat /etc/azlocal-slurm-image

########## Generalize for Azure Local ##########
# 1. Azure Local injects provisioning data through a NoCloud seed, not the Azure wire server
echo 'datasource_list: [ NoCloud ]' >/etc/cloud/cloud.cfg.d/90_dpkg.cfg
# 2. The Azure guest agent has no wire server on Azure Local
systemctl disable walinuxagent || true
# 3. Remove machine-specific state
cloud-init clean --logs --seed || true
rm -rf /var/lib/cloud/
rm -f /etc/netplan/50-cloud-init.yaml
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
apt-get clean
rm -rf /tmp/* /var/tmp/*
find /var/log -type f -exec truncate -s 0 {} \;
rm -f /root/.bash_history /home/*/.bash_history
sync
echo "IMAGE-PREP-DONE"
