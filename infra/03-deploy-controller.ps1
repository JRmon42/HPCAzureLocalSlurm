#requires -Version 7.0
<#
.SYNOPSIS
  Deploys the Slurm controller as an Azure Local VM and configures elastic compute.

.DESCRIPTION
  1. Creates the controller VM on Azure Local from the golden image, with a static IP and
     guest management (Arc agent) enabled, using the same template as the compute nodes.
  2. Grants the controller's Arc managed identity "Azure Stack HCI VM Contributor" on the
     resource group, so the Slurm Resume/Suspend programs can create/delete VMs without secrets.
  3. Renders azlocal.conf, packs slurm/ into a bundle and runs controller-setup.sh on the
     controller through Azure Arc Run Command (no inbound connectivity needed).
#>
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $CustomLocationName = 'jumpstart',
    [string] $LogicalNetworkName = 'localbox-vm-lnet-vlan200',
    [string] $ImageName = 'slurm-ubuntu2404',
    [string] $ControllerName = 'slurmctl',
    [string] $ControllerIp = '192.168.200.10',
    [int]    $ControllerCpus = 4,
    [int]    $ControllerMemoryMB = 8192,
    [string] $ClusterName = 'azlocal',
    [string] $NodeRange = 'hpc-[01-04]',
    [int]    $NodeCpus = 2,
    [int]    $NodeRealMemoryMB = 3500,
    [string] $NodeIpPrefix = '192.168.200.',
    [int]    $NodeIpBase = 100,
    [string] $NfsClients = '192.168.200.0/24',
    [int]    $SuspendTime = 120,
    [ValidateSet('ephemeral', 'persistent')] [string] $Lifecycle = 'ephemeral',
    [string] $SshPublicKeyFile = (Join-Path $HOME '.ssh/id_rsa.pub'),
    [ValidateSet('All', 'Vm', 'Rbac', 'Configure')] [string] $Stage = 'All'
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
function Invoke-Az { $out = & az @args; if ($LASTEXITCODE) { throw "az $($args -join ' ') failed" }; $out }

$sub = Invoke-Az account show --query id -o tsv
$cl = Invoke-Az customlocation show -g $ResourceGroup -n $CustomLocationName --query '{id:id,location:location}' -o json | ConvertFrom-Json
$lnetId = Invoke-Az stack-hci-vm network lnet show -g $ResourceGroup --name $LogicalNetworkName --query id -o tsv
$imageId = Invoke-Az stack-hci-vm image show -g $ResourceGroup --name $ImageName --query id -o tsv
$machineId = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/$ControllerName"

if ($Stage -in 'All', 'Vm') {
    Write-Host "==> Deploying controller VM $ControllerName ($ControllerIp) on Azure Local"
    $paramFile = Join-Path ([IO.Path]::GetTempPath()) "controller-params-$(Get-Random).json"
    @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{
            nodeName              = @{ value = $ControllerName }
            location              = @{ value = $cl.location }
            customLocationId      = @{ value = $cl.id }
            logicalNetworkId      = @{ value = $lnetId }
            imageId               = @{ value = $imageId }
            ipAddress             = @{ value = $ControllerIp }
            processors            = @{ value = $ControllerCpus }
            memoryMB              = @{ value = $ControllerMemoryMB }
            adminUsername         = @{ value = 'slurmadmin' }
            sshPublicKey          = @{ value = (Get-Content $SshPublicKeyFile -Raw).Trim() }
            enableGuestManagement = @{ value = $true }
            tags                  = @{ value = @{ SlurmCluster = $ClusterName; SlurmRole = 'controller' } }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content $paramFile
    Invoke-Az deployment group create -g $ResourceGroup -n "slurm-controller-$ControllerName" `
        --template-file (Join-Path $repoRoot 'infra/bicep/node.bicep') --parameters "@$paramFile" -o none
    Remove-Item $paramFile
    Write-Host '==> Waiting for the Arc agent (guest management) to connect'
    $deadline = (Get-Date).AddMinutes(30)
    do {
        Start-Sleep 20
        $status = az connectedmachine show -g $ResourceGroup -n $ControllerName --query status -o tsv 2>$null
        Write-Host "    agent status: $status"
    } until ($status -eq 'Connected' -or (Get-Date) -gt $deadline)
    if ($status -ne 'Connected') { throw 'Arc agent on the controller did not connect' }
}

if ($Stage -in 'All', 'Rbac') {
    $principalId = Invoke-Az rest --method get --url "https://management.azure.com$($machineId)?api-version=2025-01-13" --query identity.principalId -o tsv
    Write-Host "==> Granting 'Azure Stack HCI VM Contributor' to controller identity $principalId"
    $rgId = Invoke-Az group show -n $ResourceGroup --query id -o tsv
    $existing = az role assignment list --assignee $principalId --scope $rgId --role 'Azure Stack HCI VM Contributor' --query '[0].id' -o tsv
    if (-not $existing) {
        Invoke-Az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
            --role 'Azure Stack HCI VM Contributor' --scope $rgId -o none
    }
}

if ($Stage -in 'All', 'Configure') {
    Write-Host '==> Building controller bundle'
    $work = Join-Path ([IO.Path]::GetTempPath()) "azlocal-bundle-$(Get-Random)"
    New-Item -ItemType Directory -Path "$work/bundle/bin", "$work/bundle/etc" | Out-Null
    Copy-Item "$repoRoot/slurm/bin/*.sh" "$work/bundle/bin/"
    Copy-Item "$repoRoot/slurm/etc/slurm.conf.tpl", "$repoRoot/slurm/etc/node.json" "$work/bundle/etc/"
    Copy-Item "$repoRoot/slurm/controller/controller-setup.sh" "$work/bundle/"
    $conf = (Get-Content "$repoRoot/slurm/etc/azlocal.conf.tpl" -Raw) `
        -replace '__SUBSCRIPTION_ID__', $sub -replace '__RESOURCE_GROUP__', $ResourceGroup `
        -replace '__LOCATION__', $cl.location -replace '__CUSTOM_LOCATION_ID__', $cl.id `
        -replace '__LOGICAL_NETWORK_ID__', $lnetId -replace '__IMAGE_ID__', $imageId `
        -replace '__CONTROLLER_IP__', $ControllerIp -replace '__NODE_IP_PREFIX__', $NodeIpPrefix `
        -replace '__NODE_IP_BASE__', $NodeIpBase -replace 'LIFECYCLE="ephemeral"', "LIFECYCLE=`"$Lifecycle`""
    # Bash files must keep LF line endings
    Get-ChildItem $work -Recurse -File | ForEach-Object {
        $t = (Get-Content $_.FullName -Raw) -replace "`r`n", "`n"; [IO.File]::WriteAllText($_.FullName, $t)
    }
    [IO.File]::WriteAllText("$work/bundle/azlocal.conf", ($conf -replace "`r`n", "`n"))
    tar -czf "$work/bundle.tgz" -C "$work/bundle" .
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("$work/bundle.tgz"))

    $runScript = @"
#!/bin/bash
set -euo pipefail
rm -rf /tmp/azlocal-bundle && mkdir -p /tmp/azlocal-bundle
echo '$b64' | base64 -d | tar -xzf - -C /tmp/azlocal-bundle
export BUNDLE_DIR=/tmp/azlocal-bundle CLUSTER_NAME='$ClusterName' CONTROLLER_NAME='$ControllerName' \
  CONTROLLER_IP='$ControllerIp' NODE_RANGE='$NodeRange' NODE_CPUS='$NodeCpus' NODE_MEMORY='$NodeRealMemoryMB' \
  SUSPEND_TIME='$SuspendTime' NFS_CLIENTS='$NfsClients'
bash /tmp/azlocal-bundle/controller-setup.sh 2>&1
"@ -replace "`r`n", "`n"
    $scriptFile = "$work/run.sh"
    [IO.File]::WriteAllText($scriptFile, $runScript)

    Write-Host '==> Configuring controller through Azure Arc Run Command'
    $rcName = "controller-setup-$(Get-Date -Format yyyyMMddHHmmss)"
    Invoke-Az connectedmachine run-command create -g $ResourceGroup --machine-name $ControllerName `
        --location $cl.location --name $rcName --script "@$scriptFile" --timeout-in-seconds 1800 -o none
    $out = Invoke-Az connectedmachine run-command show -g $ResourceGroup --machine-name $ControllerName `
        --name $rcName --query '{state:instanceView.executionState,exit:instanceView.exitCode,out:instanceView.output,err:instanceView.error}' -o json | ConvertFrom-Json
    $out.out | Write-Host
    if ($out.err) { Write-Warning $out.err }
    Remove-Item $work -Recurse -Force
    if ($out.out -notmatch 'CONTROLLER-SETUP-DONE') { throw "Controller setup failed (state=$($out.state), exit=$($out.exit))" }
}
