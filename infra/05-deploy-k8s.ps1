#requires -Version 7.0
<#
.SYNOPSIS
  Deploys the POC Kubernetes cluster (k3s + Kueue + simulated GPUs) as an Azure Local VM.
  It stands in for the customer's Arc-enabled AKS cluster on Azure Local (see docs/09).

.DESCRIPTION
  1. Creates the VM from the golden image (same template as the Slurm nodes, Arc guest management on).
  2. Runs k8s/bin/k8s-setup.sh through Azure Arc Run Command: k3s, Kueue, OCR queue, night-window
     CronJobs, and the kubeconfigs written to /shared/k8s for the Slurm gateway.
  Prerequisite: the Slurm controller is deployed with -K8sGateway (03-deploy-controller.ps1).
#>
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $CustomLocationName = 'jumpstart',
    [string] $LogicalNetworkName = 'localbox-vm-lnet-vlan200',
    [string] $ImageName = 'slurm-ubuntu2404',
    [string] $K8sName = 'k8s-01',
    [string] $K8sIp = '192.168.200.20',
    [string] $ControllerIp = '192.168.200.10',
    [int]    $Cpus = 8,
    [int]    $MemoryMB = 20480,
    [int]    $SimulatedGpus = 8,
    [string] $GpuModel = 'rtx6000',
    [string] $SshPublicKeyFile = (Join-Path $HOME '.ssh/id_rsa.pub'),
    [ValidateSet('All', 'Vm', 'Configure')] [string] $Stage = 'All'
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
function Invoke-Az { $out = & az @args; if ($LASTEXITCODE) { throw "az $($args -join ' ') failed" }; $out }

$cl = Invoke-Az customlocation show -g $ResourceGroup -n $CustomLocationName --query '{id:id,location:location}' -o json | ConvertFrom-Json

if ($Stage -in 'All', 'Vm') {
    $lnetId = Invoke-Az stack-hci-vm network lnet show -g $ResourceGroup --name $LogicalNetworkName --query id -o tsv
    $imageId = Invoke-Az stack-hci-vm image show -g $ResourceGroup --name $ImageName --query id -o tsv
    Write-Host "==> Deploying VM $K8sName ($K8sIp, $Cpus vCPU, $MemoryMB MB)"
    $paramFile = Join-Path ([IO.Path]::GetTempPath()) "k8s-params-$(Get-Random).json"
    @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{
            nodeName              = @{ value = $K8sName }
            location              = @{ value = $cl.location }
            customLocationId      = @{ value = $cl.id }
            logicalNetworkId      = @{ value = $lnetId }
            imageId               = @{ value = $imageId }
            ipAddress             = @{ value = $K8sIp }
            processors            = @{ value = $Cpus }
            memoryMB              = @{ value = $MemoryMB }
            adminUsername         = @{ value = 'slurmadmin' }
            sshPublicKey          = @{ value = (Get-Content $SshPublicKeyFile -Raw).Trim() }
            enableGuestManagement = @{ value = $true }
            tags                  = @{ value = @{ SlurmRole = 'kubernetes'; Purpose = 'aks-stand-in' } }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content $paramFile
    Invoke-Az deployment group create -g $ResourceGroup -n "k8s-$K8sName" `
        --template-file (Join-Path $repoRoot 'infra/bicep/node.bicep') --parameters "@$paramFile" -o none
    Remove-Item $paramFile
    Write-Host '==> Waiting for the Arc agent'
    $deadline = (Get-Date).AddMinutes(30)
    do {
        Start-Sleep 20
        $status = az connectedmachine show -g $ResourceGroup -n $K8sName --query status -o tsv 2>$null
        Write-Host "    agent status: $status"
    } until ($status -eq 'Connected' -or (Get-Date) -gt $deadline)
    if ($status -ne 'Connected') { throw 'Arc agent on the Kubernetes VM did not connect' }
}

if ($Stage -in 'All', 'Configure') {
    Write-Host '==> Building the Kubernetes bundle'
    $work = Join-Path ([IO.Path]::GetTempPath()) "k8s-bundle-$(Get-Random)"
    New-Item -ItemType Directory "$work/bundle" | Out-Null
    Copy-Item "$repoRoot/k8s/bin/k8s-setup.sh", "$repoRoot/k8s/kueue-ocr.yaml", "$repoRoot/k8s/ocr-window.yaml", "$repoRoot/k8s/qwen-ocr.sh" "$work/bundle/"
    Get-ChildItem "$work/bundle" -File | ForEach-Object {
        [IO.File]::WriteAllText($_.FullName, ((Get-Content $_.FullName -Raw) -replace "`r`n", "`n"))
    }
    tar -czf "$work/bundle.tgz" -C "$work/bundle" .
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("$work/bundle.tgz"))
    $runScript = @"
#!/bin/bash
set -euo pipefail
rm -rf /tmp/k8s-bundle && mkdir -p /tmp/k8s-bundle
echo '$b64' | base64 -d | tar -xzf - -C /tmp/k8s-bundle
export BUNDLE_DIR=/tmp/k8s-bundle CONTROLLER_IP='$ControllerIp' K8S_IP='$K8sIp' SIM_GPUS='$SimulatedGpus' GPU_MODEL='$GpuModel'
bash /tmp/k8s-bundle/k8s-setup.sh 2>&1
"@ -replace "`r`n", "`n"
    [IO.File]::WriteAllText("$work/run.sh", $runScript)

    Write-Host '==> Configuring k3s + Kueue through Azure Arc Run Command (several minutes)'
    $rcName = "k8s-setup-$(Get-Date -Format yyyyMMddHHmmss)"
    Invoke-Az connectedmachine run-command create -g $ResourceGroup --machine-name $K8sName `
        --location $cl.location --name $rcName --script "@$work/run.sh" --timeout-in-seconds 3000 -o none
    $out = Invoke-Az connectedmachine run-command show -g $ResourceGroup --machine-name $K8sName `
        --name $rcName --query '{state:instanceView.executionState,exit:instanceView.exitCode,out:instanceView.output,err:instanceView.error}' -o json | ConvertFrom-Json
    $out.out | Write-Host
    if ($out.err) { Write-Warning $out.err }
    Remove-Item $work -Recurse -Force
    if ($out.out -notmatch 'K8S-SETUP-DONE') { throw "Kubernetes setup failed (state=$($out.state), exit=$($out.exit))" }
}
