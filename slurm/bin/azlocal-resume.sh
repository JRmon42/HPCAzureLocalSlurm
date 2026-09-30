#!/usr/bin/env bash
# Slurm ResumeProgram: provision (or start) Azure Local VMs for the given nodes,
# then bootstrap slurmd on them. Called by slurmctld as SlurmUser with a hostlist
# expression, e.g.  azlocal-resume.sh hpc-[01-02]
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/azlocal-common.sh"

HOSTLIST="$1"
log "resume request: $HOSTLIST (lifecycle=$LIFECYCLE)"
az_login || { log "az login failed"; for n in $(expand_hosts "$HOSTLIST"); do set_node_down "$n" "azlocal: az login failed"; done; exit 1; }

# /etc/hosts fragment with every statically addressed node (needed by MPI launchers
# that resolve peer hostnames on the compute nodes)
HOSTS_FILE="$(mktemp /tmp/azlocal-hosts.XXXXXX)"
if [[ -n "${NODE_IP_BASE:-}" ]]; then
  for n in $(sinfo -h -N -o '%N' | sort -u); do
    ip="$(node_ip "$n")"; [[ -n "$ip" ]] && echo "$ip $n"
  done >"$HOSTS_FILE"
fi
echo "$CONTROLLER_IP $(scontrol show config | awk -F'[ =(]+' '/^SlurmctldHost\[0\]/{print $2}')" >>"$HOSTS_FILE"

create_vm() {
  local node="$1" cpus mem ip
  read -r cpus mem <<<"$(node_size "$node")"
  ip="$(node_ip "$node")"
  log "$node: creating VM cpus=$cpus memoryMB=$mem ip=${ip:-pool}"
  az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --name "slurm-$node-$(date +%s)" \
    --template-file "$INSTALL_DIR/etc/node.json" \
    --parameters nodeName="$node" location="$LOCATION" \
                 customLocationId="$CUSTOM_LOCATION_ID" logicalNetworkId="$LOGICAL_NETWORK_ID" \
                 imageId="$IMAGE_ID" ipAddress="${ip}" processors="$cpus" memoryMB="$mem" \
                 adminUsername="$ADMIN_USER" sshPublicKey="$(cat "$SSH_KEY.pub")" \
                 storagePathId="${STORAGE_PATH_ID:-}" \
                 tags="{\"SlurmCluster\":\"$(scontrol show config | awk '/^ClusterName/{print $3}')\",\"SlurmNode\":\"$node\",\"ManagedBy\":\"azlocal-slurm\"}" \
    --output none
}

start_vm() {
  log "$1: starting existing VM"
  az stack-hci-vm start --name "$1" --resource-group "$RESOURCE_GROUP" --output none
}

bootstrap_node() {
  local node="$1" ip="$2" deadline=$((SECONDS + BOOTSTRAP_TIMEOUT))
  until ssh_node "$ip" true 2>/dev/null; do
    (( SECONDS > deadline )) && { log "$node: SSH to $ip timed out"; return 1; }
    sleep 10
  done
  log "$node: SSH reachable at $ip, pushing bootstrap"
  scp_node "$ip" /tmp/ "$INSTALL_DIR/bin/node-bootstrap.sh" "$MUNGE_KEY_COPY" "$HOSTS_FILE" || return 1
  ssh_node "$ip" "sudo bash /tmp/node-bootstrap.sh '$CONTROLLER_IP' /tmp/$(basename "$MUNGE_KEY_COPY") /tmp/$(basename "$HOSTS_FILE")" \
    >>"$LOG_FILE" 2>&1
}

resume_one() {
  local node="$1" t0=$SECONDS ip
  if [[ "$LIFECYCLE" == "persistent" ]] && vm_exists "$node"; then
    start_vm "$node" || { log "$node: start failed"; set_node_down "$node" "azlocal: start failed"; return 1; }
  else
    create_vm "$node" || { log "$node: VM deployment failed"; set_node_down "$node" "azlocal: create failed"; return 1; }
  fi
  ip="$(node_ip "$node")"; [[ -z "$ip" ]] && ip="$(nic_ip "$node")"
  log "$node: VM ready in $((SECONDS - t0))s, ip=$ip"
  scontrol update nodename="$node" nodeaddr="$ip" nodehostname="$node"
  if bootstrap_node "$node" "$ip"; then
    log "$node: bootstrap done, total $((SECONDS - t0))s (slurmd will register)"
  else
    log "$node: bootstrap failed"; set_node_down "$node" "azlocal: bootstrap failed"; return 1
  fi
}

pids=()
for node in $(expand_hosts "$HOSTLIST"); do
  resume_one "$node" &
  pids+=($!)
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
rm -f "$HOSTS_FILE"
log "resume request done: $HOSTLIST rc=$rc"
exit $rc
