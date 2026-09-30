#!/usr/bin/env bash
# Shared helpers for the Slurm <-> Azure Local power-saving programs.
# Sourced by azlocal-resume.sh, azlocal-suspend.sh, azlocal-resume-fail.sh and
# azlocal-epilog-slurmctld.sh. Runs as SlurmUser (slurm) on the controller.

AZLOCAL_CONF="${AZLOCAL_CONF:-/etc/azlocal-slurm/azlocal.conf}"
# shellcheck source=/dev/null
source "$AZLOCAL_CONF"

INSTALL_DIR="${INSTALL_DIR:-/opt/azlocal-slurm}"
LOG_FILE="${LOG_FILE:-/var/log/slurm/azlocal-power.log}"
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export AZURE_EXTENSION_DIR="${AZURE_EXTENSION_DIR:-$INSTALL_DIR/cliextensions}"
export AZURE_CORE_ONLY_SHOW_ERRORS=true
export AZURE_CORE_COLLECT_TELEMETRY=false
export AZURE_CORE_NO_COLOR=true
# Azure Arc (himds) managed identity endpoint of the Arc-enabled controller VM
export IDENTITY_ENDPOINT="${IDENTITY_ENDPOINT:-http://localhost:40342/metadata/identity/oauth2/token}"
export IMDS_ENDPOINT="${IMDS_ENDPOINT:-http://localhost:40342}"

log() {
  printf '%s [%s:%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$0")" "$$" "$*" >>"$LOG_FILE"
}

# Every invocation gets a private Azure CLI config dir: Slurm may run several
# Resume/Suspend programs concurrently and az CLI's token cache is not multi-process safe.
az_login() {
  AZURE_CONFIG_DIR="$(mktemp -d /tmp/azlocal-az.XXXXXX)"
  export AZURE_CONFIG_DIR
  trap 'rm -rf "$AZURE_CONFIG_DIR"' EXIT
  case "${AZ_AUTH:-msi}" in
    msi) az login --identity --output none ;;
    sp)  az login --service-principal -u "$SP_APP_ID" --tenant "$SP_TENANT_ID" \
           --certificate "$SP_CERT_FILE" --output none ;;
    *)   log "unknown AZ_AUTH=$AZ_AUTH"; return 1 ;;
  esac
  az account set --subscription "$SUBSCRIPTION_ID"
}

# Expand a Slurm hostlist expression (hpc-[01-03]) into one name per line
expand_hosts() { scontrol show hostnames "$1"; }

machine_id() { echo "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.HybridCompute/machines/$1"; }
vmi_id()     { echo "$(machine_id "$1")/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default"; }
nic_id()     { echo "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.AzureStackHCI/networkInterfaces/$1-nic"; }

VMI_API="2024-01-01"
NIC_API="2024-01-01"

# Deterministic static IP from the trailing number of the node name (hpc-07 -> base+7)
node_ip() {
  local n
  [[ -z "${NODE_IP_BASE:-}" ]] && return 0
  n="$(sed -E 's/^.*[^0-9]([0-9]+)$/\1/' <<<"$1")"
  echo "${NODE_IP_PREFIX}$((NODE_IP_BASE + 10#$n))"
}

# Actual IP of an existing NIC (used when IPs come from the logical network pool)
nic_ip() {
  az rest --method get --url "https://management.azure.com$(nic_id "$1")?api-version=$NIC_API" \
    --query 'properties.ipConfigurations[0].properties.privateIPAddress' -o tsv 2>/dev/null
}

vm_exists() {
  az rest --method get --url "https://management.azure.com$(vmi_id "$1")?api-version=$VMI_API" \
    --query 'id' -o tsv >/dev/null 2>&1
}

# Read CPUs / RealMemory from the Slurm node definition so the VM matches what Slurm schedules
node_size() {
  local line cpus mem
  line="$(scontrol show node "$1" -o)"
  cpus="$(grep -oP '(?<=CPUTot=)\d+' <<<"$line")"
  mem="$(grep -oP '(?<=RealMemory=)\d+' <<<"$line")"
  mem=$(( ( (mem + ${MEMORY_OVERHEAD_MB:-512} + 1023) / 1024 ) * 1024 ))
  echo "${cpus:-2} ${mem}"
}

set_node_down() {
  local node="$1" reason="$2"
  scontrol update nodename="$node" state=down reason="$reason" >/dev/null 2>&1 || true
}

ssh_node() {
  local ip="$1"; shift
  ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o LogLevel=ERROR "$ADMIN_USER@$ip" "$@"
}

scp_node() {
  local ip="$1" dst="$2"; shift 2
  scp -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o LogLevel=ERROR "$@" "$ADMIN_USER@$ip:$dst"
}
