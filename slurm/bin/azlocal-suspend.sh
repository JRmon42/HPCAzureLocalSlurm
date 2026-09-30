#!/usr/bin/env bash
# Slurm SuspendProgram: decommission Azure Local VMs of idle nodes.
#   ephemeral : delete VM instance, Arc machine and NIC (OS disk goes with the VM)
#   persistent: stop (power off) the VM, keep it for a faster next resume
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/azlocal-common.sh"

HOSTLIST="$1"
log "suspend request: $HOSTLIST (lifecycle=$LIFECYCLE)"
az_login || { log "az login failed"; exit 1; }

suspend_one() {
  local node="$1" t0=$SECONDS
  if [[ "$LIFECYCLE" == "persistent" ]]; then
    az stack-hci-vm stop --name "$node" --resource-group "$RESOURCE_GROUP" --output none \
      && log "$node: VM stopped in $((SECONDS - t0))s" || log "$node: stop failed"
    return
  fi
  if vm_exists "$node"; then
    az stack-hci-vm delete --name "$node" --resource-group "$RESOURCE_GROUP" --yes --output none \
      || log "$node: VM delete returned an error"
  fi
  # Arc machine resource (normally removed with the VM; ignore if already gone)
  az resource delete --ids "$(machine_id "$node")" --output none 2>/dev/null || true
  az stack-hci-vm network nic delete --name "$node-nic" --resource-group "$RESOURCE_GROUP" --yes --output none 2>/dev/null || true
  log "$node: VM decommissioned in $((SECONDS - t0))s"
}

pids=()
for node in $(expand_hosts "$HOSTLIST"); do
  scontrol update nodename="$node" nodeaddr="$node" nodehostname="$node" 2>/dev/null || true
  suspend_one "$node" &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
log "suspend request done: $HOSTLIST"
exit 0
