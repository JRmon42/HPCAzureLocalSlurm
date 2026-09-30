#!/usr/bin/env bash
# Configures an Azure Local VM (built from the golden image) as the Slurm controller.
# Expects the bundle (bin/, etc/, azlocal.conf) extracted into $BUNDLE_DIR.
# Invoked by infra/03-deploy-controller.ps1 through Azure Arc Run Command, as root.
#
# Env: BUNDLE_DIR, CLUSTER_NAME, CONTROLLER_NAME, CONTROLLER_IP, NODE_RANGE, NODE_CPUS,
#      NODE_MEMORY, SUSPEND_TIME, NFS_CLIENTS (CIDR allowed to mount /shared)
set -euo pipefail
BUNDLE_DIR="${BUNDLE_DIR:-/tmp/azlocal-bundle}"
CLUSTER_NAME="${CLUSTER_NAME:-azlocal}"
CONTROLLER_NAME="${CONTROLLER_NAME:-$(hostname -s)}"
CONTROLLER_IP="${CONTROLLER_IP:?}"
NODE_RANGE="${NODE_RANGE:-hpc-[01-04]}"
NODE_CPUS="${NODE_CPUS:-2}"
NODE_MEMORY="${NODE_MEMORY:-3500}"
SUSPEND_TIME="${SUSPEND_TIME:-120}"
NFS_CLIENTS="${NFS_CLIENTS:?}"
INSTALL_DIR=/opt/azlocal-slurm
CONF_DIR=/etc/azlocal-slurm

echo "==> Installing azlocal-slurm programs"
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/etc" "$CONF_DIR/ssh" /var/log/slurm /var/spool/slurmctld
install -m 0755 "$BUNDLE_DIR"/bin/*.sh "$INSTALL_DIR/bin/"
install -m 0644 "$BUNDLE_DIR/etc/node.json" "$INSTALL_DIR/etc/node.json"
install -m 0640 -o root -g slurm "$BUNDLE_DIR/azlocal.conf" "$CONF_DIR/azlocal.conf"
chown slurm:slurm /var/log/slurm /var/spool/slurmctld
touch /var/log/slurm/azlocal-power.log && chown slurm:slurm /var/log/slurm/azlocal-power.log

echo "==> slurm.conf"
sed -e "s|__CLUSTER_NAME__|$CLUSTER_NAME|g" \
    -e "s|__CONTROLLER_NAME__|$CONTROLLER_NAME|g" \
    -e "s|__CONTROLLER_IP__|$CONTROLLER_IP|g" \
    -e "s|__NODE_RANGE__|$NODE_RANGE|g" \
    -e "s|__NODE_CPUS__|$NODE_CPUS|g" \
    -e "s|__NODE_MEMORY__|$NODE_MEMORY|g" \
    -e "s|__SUSPEND_TIME__|$SUSPEND_TIME|g" \
    "$BUNDLE_DIR/etc/slurm.conf.tpl" >/etc/slurm/slurm.conf
chmod 0644 /etc/slurm/slurm.conf

echo "==> Name resolution"
sed -i "/[[:space:]]$CONTROLLER_NAME\$/d" /etc/hosts
echo "$CONTROLLER_IP $CONTROLLER_NAME" >>/etc/hosts
# shellcheck source=/dev/null
source "$CONF_DIR/azlocal.conf"
if [[ -n "${NODE_IP_BASE:-}" ]]; then
  sed -i '/# azlocal-slurm begin/,/# azlocal-slurm end/d' /etc/hosts
  {
    echo "# azlocal-slurm begin"
    for n in $(scontrol show hostnames "$NODE_RANGE" 2>/dev/null || true); do
      num="$(sed -E 's/^.*[^0-9]([0-9]+)$/\1/' <<<"$n")"
      echo "${NODE_IP_PREFIX}$((NODE_IP_BASE + 10#$num)) $n"
    done
    echo "# azlocal-slurm end"
  } >>/etc/hosts
fi

echo "==> Munge"
if [[ ! -s /etc/munge/munge.key ]]; then
  dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key status=none
fi
chown munge:munge /etc/munge/munge.key && chmod 0400 /etc/munge/munge.key
# Copy readable by SlurmUser so the ResumeProgram can hand it to new nodes
install -o slurm -g slurm -m 0400 /etc/munge/munge.key "$CONF_DIR/munge.key"
systemctl enable --now munge

echo "==> SSH key used to bootstrap compute VMs"
if [[ ! -s "$CONF_DIR/ssh/id_ed25519" ]]; then
  ssh-keygen -q -t ed25519 -N '' -C "slurm@$CONTROLLER_NAME" -f "$CONF_DIR/ssh/id_ed25519"
fi
chown -R slurm:slurm "$CONF_DIR/ssh" && chmod 0700 "$CONF_DIR/ssh" && chmod 0600 "$CONF_DIR/ssh/id_ed25519"

echo "==> Azure identity for SlurmUser (Arc managed identity)"
# The Arc agent's token endpoint requires membership of the himds group
if getent group himds >/dev/null; then usermod -aG himds slurm; fi

echo "==> NFS export /shared"
mkdir -p /shared/home/hpcuser /shared/jobs
chown -R hpcuser:hpcuser /shared/home/hpcuser /shared/jobs
chmod 1777 /shared/jobs
grep -q '^/shared ' /etc/exports || echo "/shared $NFS_CLIENTS(rw,sync,no_subtree_check,no_root_squash)" >>/etc/exports
systemctl enable --now nfs-kernel-server
exportfs -ra

echo "==> Checking Azure login as SlurmUser"
sudo -u slurm -H bash -c "source $INSTALL_DIR/bin/azlocal-common.sh && az_login && az account show --query '{sub:id,user:user.name}' -o tsv"

echo "==> Starting slurmctld"
systemctl enable slurmctld
systemctl restart slurmctld
sleep 5
systemctl is-active slurmctld
sinfo
echo "CONTROLLER-SETUP-DONE"
