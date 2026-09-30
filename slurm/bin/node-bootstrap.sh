#!/usr/bin/env bash
# Runs as root on a freshly provisioned compute VM (pushed + invoked over SSH by
# azlocal-resume.sh). Joins the node to the Slurm cluster in configless mode.
#   node-bootstrap.sh <controller-ip> <munge-key-file> <hosts-fragment>
set -euo pipefail
CONTROLLER_IP="$1"; MUNGE_KEY="$2"; HOSTS_FRAGMENT="${3:-}"

# Hostname resolution for peers (MPI) and the controller
if [[ -n "$HOSTS_FRAGMENT" && -s "$HOSTS_FRAGMENT" ]]; then
  sed -i '/# azlocal-slurm begin/,/# azlocal-slurm end/d' /etc/hosts
  { echo "# azlocal-slurm begin"; cat "$HOSTS_FRAGMENT"; echo "# azlocal-slurm end"; } >>/etc/hosts
fi

# Shared munge secret
install -o munge -g munge -m 0400 "$MUNGE_KEY" /etc/munge/munge.key
rm -f "$MUNGE_KEY"
systemctl enable --now munge

# Shared file system (home directories + job data) exported by the controller
mkdir -p /shared
grep -q " /shared " /etc/fstab || echo "$CONTROLLER_IP:/shared /shared nfs defaults,_netdev,nofail 0 0" >>/etc/fstab
for _ in $(seq 1 12); do
  if mountpoint -q /shared || mount /shared 2>/dev/null; then break; fi
  sleep 5
done
mountpoint -q /shared

# slurmd in configless mode: slurm.conf is fetched from slurmctld
echo "SLURMD_OPTIONS=\"--conf-server $CONTROLLER_IP\"" >/etc/default/slurmd
mkdir -p /etc/systemd/system/slurmd.service.d
cat >/etc/systemd/system/slurmd.service.d/azlocal.conf <<'EOF'
[Unit]
# Configless: there is no local slurm.conf
ConditionPathExists=
After=network-online.target munge.service remote-fs.target
Wants=network-online.target
EOF
mkdir -p /var/spool/slurmd /var/log/slurm
chown slurm:slurm /var/spool/slurmd /var/log/slurm 2>/dev/null || true
systemctl daemon-reload
systemctl enable slurmd
systemctl restart slurmd
sleep 3
systemctl is-active slurmd
echo "BOOTSTRAP-OK $(hostname) $(date -u +%Y-%m-%dT%H:%M:%SZ)"
