#requires -Version 7.0
<#
.SYNOPSIS
  Tears the POC down.
  -Scope Compute : delete Slurm compute VMs left on Azure Local (keeps controller + cluster)
  -Scope Slurm   : also delete the controller VM and the image
  -Scope All     : delete the whole resource group (LocalBox host, Azure Local, everything)
#>
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [ValidateSet('Compute', 'Slurm', 'All')] [string] $Scope = 'Compute',
    [string] $ControllerName = 'slurmctl',
    [string] $ImageName = 'slurm-ubuntu2404'
)
$ErrorActionPreference = 'Continue'

if ($Scope -eq 'All') {
    Write-Host "==> Deleting resource group $ResourceGroup"
    az group delete -n $ResourceGroup --yes --no-wait
    return
}

$names = az resource list -g $ResourceGroup --resource-type Microsoft.HybridCompute/machines `
    --query '[].{n:name,m:tags.ManagedBy}' -o json | ConvertFrom-Json |
    Where-Object { $_.m -eq 'azlocal-slurm' } | ForEach-Object n
if ($Scope -eq 'Slurm') { $names = @($names) + $ControllerName }
foreach ($n in $names | Where-Object { $_ }) {
    Write-Host "==> Deleting VM $n"
    az stack-hci-vm delete -g $ResourceGroup --name $n --yes -o none
    az stack-hci-vm network nic delete -g $ResourceGroup --name "$n-nic" --yes -o none 2>$null
}
if ($Scope -eq 'Slurm') {
    az stack-hci-vm image delete -g $ResourceGroup --name $ImageName --yes -o none
}
