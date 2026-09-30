#requires -Version 7.0
<#
.SYNOPSIS
  Builds the Slurm golden image and publishes it as an Azure Local VM image.

.DESCRIPTION
  1. Creates a temporary Ubuntu 24.04 Azure VM (no inbound access, egress only).
  2. Runs image/prepare-slurm-image.sh through Run Command (Slurm, munge, NFS, OpenMPI,
     Azure CLI + stack-hci-vm extension) and generalizes it for Azure Local (NoCloud).
  3. Deallocates the VM, generates a read SAS on the OS disk and creates the
     Azure Local gallery image from it (az stack-hci-vm image create --image-path <SAS>).
  4. Deletes the temporary Azure resources once the Azure Local image is Succeeded.

  Pattern documented in:
  https://learn.microsoft.com/azure/azure-local/manage/virtual-machine-azure-marketplace-ubuntu
#>
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $BuilderLocation = 'swedencentral',
    [string] $BuilderVmSize = 'Standard_D4as_v5',
    [string] $CustomLocationName = 'jumpstart',
    [string] $ImageName = 'slurm-ubuntu2404',
    [ValidateSet('All', 'Build', 'Publish', 'Cleanup')] [string] $Stage = 'All'
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$vm = 'vm-slurm-imagebuilder'

function Invoke-Az { $out = & az @args; if ($LASTEXITCODE) { throw "az $($args -join ' ') failed" }; $out }

if ($Stage -in 'All', 'Build') {
    Write-Host '==> Creating image builder network (egress only, no inbound rules)'
    Invoke-Az network nsg create -g $ResourceGroup -n nsg-imagebuilder -l $BuilderLocation -o none
    Invoke-Az network vnet create -g $ResourceGroup -n vnet-imagebuilder -l $BuilderLocation `
        --address-prefixes 10.50.0.0/24 --subnet-name builder --subnet-prefixes 10.50.0.0/26 `
        --network-security-group nsg-imagebuilder -o none
    Invoke-Az network public-ip create -g $ResourceGroup -n pip-imagebuilder -l $BuilderLocation --sku Standard -o none

    Write-Host '==> Creating Ubuntu 24.04 builder VM'
    Invoke-Az vm create -g $ResourceGroup -n $vm -l $BuilderLocation --size $BuilderVmSize `
        --image Canonical:ubuntu-24_04-lts:server:latest --security-type Standard `
        --vnet-name vnet-imagebuilder --subnet builder --public-ip-address pip-imagebuilder --nsg '""' `
        --admin-username imagebuilder --generate-ssh-keys --os-disk-size-gb 30 -o none

    Write-Host '==> Running image preparation (Run Command)'
    $script = Join-Path $repoRoot 'image/prepare-slurm-image.sh'
    $res = Invoke-Az vm run-command invoke -g $ResourceGroup -n $vm --command-id RunShellScript `
        --scripts "@$script" --query 'value[0].message' -o tsv
    $res | Select-Object -Last 25 | Write-Host
    if (-not ($res -match 'IMAGE-PREP-DONE')) { throw 'Image preparation did not complete' }

    Write-Host '==> Deallocating builder VM'
    Invoke-Az vm deallocate -g $ResourceGroup -n $vm -o none
}

if ($Stage -in 'All', 'Publish') {
    $diskId = Invoke-Az vm show -g $ResourceGroup -n $vm --query storageProfile.osDisk.managedDisk.id -o tsv
    Write-Host "==> Granting 10h read SAS on $diskId"
    $sas = Invoke-Az disk grant-access --ids $diskId --access-level Read --duration-in-seconds 36000 --query accessSas -o tsv

    $cl = Invoke-Az customlocation show -g $ResourceGroup -n $CustomLocationName --query id -o tsv
    $clLocation = Invoke-Az customlocation show -g $ResourceGroup -n $CustomLocationName --query location -o tsv
    Write-Host "==> Creating Azure Local image '$ImageName' (downloads the VHD into the cluster; can take 30-60 min)"
    Invoke-Az stack-hci-vm image create -g $ResourceGroup --custom-location $cl --location $clLocation `
        --name $ImageName --os-type Linux --image-path "`"$sas`"" -o none
    Invoke-Az stack-hci-vm image show -g $ResourceGroup -n $ImageName `
        --query '{name:name,state:properties.provisioningState,status:properties.status}' -o json | Write-Host
}

if ($Stage -in 'All', 'Cleanup') {
    Write-Host '==> Removing temporary builder resources'
    $diskId = az vm show -g $ResourceGroup -n $vm --query storageProfile.osDisk.managedDisk.id -o tsv 2>$null
    if ($diskId) { az disk revoke-access --ids $diskId -o none }
    az vm delete -g $ResourceGroup -n $vm --yes --force-deletion none -o none 2>$null
    if ($diskId) { az disk delete --ids $diskId --yes -o none }
    az network nic list -g $ResourceGroup --query "[?starts_with(name,'$vm')].id" -o tsv | ForEach-Object { az network nic delete --ids $_ -o none }
    az network public-ip delete -g $ResourceGroup -n pip-imagebuilder -o none
    az network vnet delete -g $ResourceGroup -n vnet-imagebuilder -o none
    az network nsg delete -g $ResourceGroup -n nsg-imagebuilder -o none
}
