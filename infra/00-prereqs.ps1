#requires -Version 7.0
<#
.SYNOPSIS
  Subscription prerequisites for the Azure Local + Slurm POC: resource providers,
  resource group and (optionally) a scoped policy exemption.

.DESCRIPTION
  Azure Local needs a cloud witness storage account reachable with its account key and a
  Key Vault reachable from the cluster. In governed tenants (e.g. MCAPS) Modify policies
  force publicNetworkAccess=Disabled / allowSharedKeyAccess=false, which breaks the cluster
  deployment. -PolicyAssignmentId creates a Waiver exemption on the POC resource group only,
  limited to those policy definition references.
#>
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string] $ResourceGroup = 'rg-hpc-azlocal-slurm',
    [string] $Location = 'swedencentral',
    [string] $PolicyAssignmentId,
    [string[]] $PolicyDefinitionReferenceIds = @(
        'StorageAccountDisableLocalAuth', 'StorageAccountPublicNetworkModify', 'KeyVaultPublicNetworkModify')
)
$ErrorActionPreference = 'Stop'
function Invoke-Az { $out = & az @args; if ($LASTEXITCODE) { throw "az $($args -join ' ') failed" }; $out }

Invoke-Az account set --subscription $SubscriptionId
az config set extension.use_dynamic_install=yes_without_prompt extension.dynamic_install_allow_preview=true 2>$null

$providers = 'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity',
    'Microsoft.AzureStackHCI', 'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration',
    'Microsoft.ExtendedLocation', 'Microsoft.ResourceConnector', 'Microsoft.HybridContainerService',
    'Microsoft.Attestation', 'Microsoft.AzureArcData', 'Microsoft.OperationalInsights',
    'Microsoft.OperationsManagement', 'Microsoft.EdgeMarketplace', 'Microsoft.Insights'
foreach ($p in $providers) { Write-Host "==> register $p"; Invoke-Az provider register -n $p -o none }
do {
    Start-Sleep 10
    $pending = $providers | Where-Object { (az provider show -n $_ --query registrationState -o tsv) -ne 'Registered' }
    if ($pending) { Write-Host "    waiting: $($pending -join ', ')" }
} while ($pending)

Write-Host "==> Resource group $ResourceGroup ($Location)"
Invoke-Az group create -n $ResourceGroup -l $Location --tags Project=HPCAzureLocalSlurm -o none

if ($PolicyAssignmentId) {
    $rgId = Invoke-Az group show -n $ResourceGroup --query id -o tsv
    Write-Host '==> Policy exemption (Waiver) for Azure Local witness storage / Key Vault'
    Invoke-Az policy exemption create --name azlocal-network-waiver --scope $rgId `
        --policy-assignment $PolicyAssignmentId --exemption-category Waiver `
        --policy-definition-reference-ids @PolicyDefinitionReferenceIds `
        --display-name 'Azure Local POC: witness storage key + Key Vault public endpoint' -o none
}

Write-Host '==> Microsoft.AzureStackHCI resource provider service principal (LocalBox parameter spnProviderId)'
az ad sp list --filter "appId eq '1412d89f-b8a8-4111-b4fd-e82905cbd85d'" --query '[0].id' -o tsv
