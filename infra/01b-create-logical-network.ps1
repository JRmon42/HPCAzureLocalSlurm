#requires -Version 7.0
<#
.SYNOPSIS
  Creates the Azure Local logical network used by the Slurm controller and compute VMs.

.DESCRIPTION
  LocalBox (autoDeployClusterResource=true) deploys the cluster, Arc resource bridge and custom
  location but does NOT create a VM logical network: run this once the custom location is
  'Succeeded'. The defaults match the LocalBox nested network (VLAN 200, NAT gateway on the host,
  DNS = LocalBox domain controller). For a customer, use the VLAN / subnet / vSwitch of the site
  (Get-VMSwitch on a cluster node gives the vSwitch name).

.EXAMPLE
  ./infra/01b-create-logical-network.ps1 -ResourceGroup rg-hpc-azlocal-slurm
#>
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $CustomLocationName = 'jumpstart',
    [string] $Name = 'localbox-vm-lnet-vlan200',
    [string] $AddressPrefix = '192.168.200.0/24',
    [string] $Gateway = '192.168.200.1',
    [string[]] $DnsServers = @('192.168.1.254'),
    [int] $Vlan = 200,
    [string] $VmSwitchName = 'ConvergedSwitch(compute_management)'
)
$ErrorActionPreference = 'Stop'
function Invoke-Az { $out = & az @args; if ($LASTEXITCODE) { throw "az $($args -join ' ') failed" }; $out }

$cl = Invoke-Az customlocation show -g $ResourceGroup -n $CustomLocationName -o json | ConvertFrom-Json
if ($cl.provisioningState -ne 'Succeeded') { throw "Custom location $CustomLocationName is $($cl.provisioningState)" }

$existing = az stack-hci-vm network lnet show -g $ResourceGroup --name $Name --query properties.provisioningState -o tsv 2>$null
if ($existing -eq 'Succeeded') { Write-Host "==> Logical network $Name already exists"; return }

# az.cmd (cmd.exe) breaks on unquoted parentheses in the vSwitch name
$switchArg = if ($IsWindows) { "`"$VmSwitchName`"" } else { $VmSwitchName }
# Static allocation without an IP pool: the controller and compute NICs carry explicit IPs
Write-Host "==> Creating logical network $Name ($AddressPrefix, VLAN $Vlan) on $CustomLocationName"
Invoke-Az stack-hci-vm network lnet create -g $ResourceGroup --name $Name `
    --custom-location $cl.id --location $cl.location `
    --ip-allocation-method Static --address-prefixes $AddressPrefix --gateway $Gateway `
    --dns-servers @DnsServers --vlan $Vlan --vm-switch-name $switchArg -o none
Invoke-Az stack-hci-vm network lnet show -g $ResourceGroup --name $Name --query properties.provisioningState -o tsv
