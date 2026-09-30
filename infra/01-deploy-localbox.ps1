#requires -Version 7.0
<#
.SYNOPSIS
  Deploys an Azure Local instance for the POC with Jumpstart LocalBox
  (2-node Azure Local cluster nested in one Azure VM, Arc resource bridge,
  custom location 'jumpstart', logical network 'localbox-vm-lnet-vlan200').

.DESCRIPTION
  For a real customer, skip this script: use the existing Azure Local instance and pass its
  custom location / logical network names to the next scripts.
  LocalBox reference: https://jumpstart.azure.com/azure_jumpstart_localbox
  After the ARM deployment finishes, the LocalBox-Client VM logs on automatically and deploys
  the Azure Local cluster (validation + deployment take ~3-6 hours).
#>
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [securestring] $AdminPassword,
    [string] $Location = 'swedencentral',
    [string] $AzureLocalInstanceLocation = 'eastus',
    [string] $VmSize = 'Standard_E32s_v5',
    [string] $AdminUsername = 'arcdemo',
    [string] $LocalBoxRef = 'main',
    [string] $WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'azure_arc')
)
$ErrorActionPreference = 'Stop'
function Invoke-Az { $out = & az @args; if ($LASTEXITCODE) { throw "az $($args -join ' ') failed" }; $out }

if (-not (Test-Path "$WorkDir/azure_jumpstart_localbox")) {
    git clone --depth 1 --filter=blob:none --sparse --branch $LocalBoxRef https://github.com/microsoft/azure_arc.git $WorkDir
    git -C $WorkDir sparse-checkout set azure_jumpstart_localbox
}

$spnProviderId = Invoke-Az ad sp list --filter "appId eq '1412d89f-b8a8-4111-b4fd-e82905cbd85d'" --query '[0].id' -o tsv
$params = @{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = @{
        tenantId                   = @{ value = $TenantId }
        spnProviderId              = @{ value = $spnProviderId }
        windowsAdminUsername       = @{ value = $AdminUsername }
        windowsAdminPassword       = @{ value = (ConvertFrom-SecureString $AdminPassword -AsPlainText) }
        location                   = @{ value = $Location }
        azureLocalInstanceLocation = @{ value = $AzureLocalInstanceLocation }
        vmSize                     = @{ value = $VmSize }
        deployBastion              = @{ value = $false }
        vmAutologon                = @{ value = $true }
        autoDeployClusterResource  = @{ value = $true }
        autoUpgradeClusterResource = @{ value = $false }
        governResourceTags         = @{ value = $true }
        natDNS                     = @{ value = '8.8.8.8' }
    }
}
$paramFile = New-TemporaryFile
try {
    $params | ConvertTo-Json -Depth 5 | Set-Content $paramFile
    Write-Host "==> Deploying LocalBox into $ResourceGroup (host $VmSize in $Location, Azure Local region $AzureLocalInstanceLocation)"
    Invoke-Az deployment group create -g $ResourceGroup -n localbox `
        --template-file "$WorkDir/azure_jumpstart_localbox/bicep/main.bicep" --parameters "@$paramFile" -o none
} finally { Remove-Item $paramFile -Force }

Write-Host @'
==> ARM deployment done. The Azure Local cluster is now being deployed from LocalBox-Client.
    Follow progress with:
      az stack-hci cluster list -g <rg> -o table          (cluster resource + status)
      az customlocation list -g <rg> -o table              (ready when 'jumpstart' exists)
      az stack-hci-vm network lnet list -g <rg> -o table   (logical network for the VMs)
    Logs on the host: C:\LocalBox\Logs\*.log
'@
