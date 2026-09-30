#requires -Version 7.0
<#
.SYNOPSIS
  Runs the end-to-end test (tests/e2e-test.sh) on the Slurm controller through Azure Arc Run Command
  and streams its log. Also usable to run any ad-hoc command on the controller (-Command).

.EXAMPLE
  ./infra/04-run-e2e.ps1 -ResourceGroup rg-hpc-azlocal-slurm
  ./infra/04-run-e2e.ps1 -ResourceGroup rg-hpc-azlocal-slurm -Command 'sinfo; tail /var/log/slurm/azlocal-power.log'
#>
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $ControllerName = 'slurmctl',
    [string] $Command,
    [string[]] $Jobs = @('hello.sbatch', 'mpi.sbatch'),
    [int] $TimeoutMinutes = 120
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$location = az connectedmachine show -g $ResourceGroup -n $ControllerName --query location -o tsv
if (-not $location) { throw "Controller $ControllerName not found" }

function Invoke-ControllerScript([string] $Script, [int] $TimeoutSec = 600) {
    $f = New-TemporaryFile
    [IO.File]::WriteAllText($f, "#!/bin/bash`n" + ($Script -replace "`r`n", "`n"))
    $name = "rc-$(Get-Date -Format yyyyMMddHHmmssfff)"
    az connectedmachine run-command create -g $ResourceGroup --machine-name $ControllerName --location $location `
        --name $name --script "@$f" --timeout-in-seconds $TimeoutSec -o none
    $r = az connectedmachine run-command show -g $ResourceGroup --machine-name $ControllerName --name $name `
        --query '{out:instanceView.output,err:instanceView.error,exit:instanceView.exitCode}' -o json | ConvertFrom-Json
    az connectedmachine run-command delete -g $ResourceGroup --machine-name $ControllerName --name $name --yes --no-wait -o none 2>$null
    Remove-Item $f
    if ($r.err) { Write-Verbose $r.err }
    $r.out
}

if ($Command) { Invoke-ControllerScript $Command; return }

Write-Host '==> Uploading tests and starting e2e-test.sh on the controller'
$work = Join-Path ([IO.Path]::GetTempPath()) "azlocal-tests-$(Get-Random)"
New-Item -ItemType Directory $work | Out-Null
Get-ChildItem "$repoRoot/tests" -File | ForEach-Object {
    [IO.File]::WriteAllText("$work/$($_.Name)", ((Get-Content $_.FullName -Raw) -replace "`r`n", "`n"))
}
tar -czf "$work.tgz" -C $work .
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("$work.tgz"))
Remove-Item $work, "$work.tgz" -Recurse -Force
$log = "/shared/jobs/e2e-$(Get-Date -Format yyyyMMdd-HHmmss).log"
Invoke-ControllerScript @"
set -e
rm -rf /opt/azlocal-slurm/tests && mkdir -p /opt/azlocal-slurm/tests
echo '$b64' | base64 -d | tar -xzf - -C /opt/azlocal-slurm/tests
chmod +x /opt/azlocal-slurm/tests/*.sh
systemctl reset-failed azlocal-e2e 2>/dev/null || true
systemd-run --unit azlocal-e2e --collect bash -c '/opt/azlocal-slurm/tests/e2e-test.sh $($Jobs -join ' ') >$log 2>&1'
echo started $log
"@ | Write-Host

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$last = ''
do {
    Start-Sleep 60
    $content = Invoke-ControllerScript "tail -n 12 $log"
    if ($content -ne $last) { Write-Host "----- $(Get-Date -Format HH:mm:ss)"; $content | Write-Host; $last = $content }
} until ($content -match 'E2E-(PASS|FAIL)' -or (Get-Date) -gt $deadline)
Write-Host '==> Summary'
Invoke-ControllerScript "grep -E '^(RESULT|=== E2E|E2E-)|RUNNING after|decommissioned in|VMs during job' $log" | Write-Host
Write-Host "Full log on the controller: $log"
if ($content -notmatch 'E2E-PASS') { throw 'E2E test did not pass' }
