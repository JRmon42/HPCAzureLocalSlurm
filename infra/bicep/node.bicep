// One elastic Slurm compute node on Azure Local:
//   Azure Local NIC (static IP on a logical network)
//   + Arc machine (kind HCI)
//   + Azure Local VM instance (virtualMachineInstances/default) sized from the Slurm node definition.
// Deployed by the Slurm ResumeProgram (slurm/bin/azlocal-resume.sh) on the controller.

@description('Slurm node name; also the VM, computer and NIC name prefix')
param nodeName string

@description('Azure region of the Azure Local custom location (e.g. eastus)')
param location string

@description('Resource ID of the Azure Local custom location')
param customLocationId string

@description('Resource ID of the Azure Local logical network')
param logicalNetworkId string

@description('Resource ID of the Azure Local VM image (gallery image)')
param imageId string

@description('Static IP for the node on the logical network. Empty = allocate from the logical network IP pool')
param ipAddress string = ''

@description('vCPUs (Slurm CPUs=)')
param processors int = 2

@description('Memory in MB (Slurm RealMemory= plus OS overhead)')
param memoryMB int = 4096

@description('Admin user created by cloud-init; used by the controller to bootstrap slurmd over SSH')
param adminUsername string = 'slurmadmin'

@description('SSH public key of the Slurm controller')
param sshPublicKey string

@description('Optional Azure Local storage path ID for VM files. Empty = platform default')
param storagePathId string = ''

@description('Install the Arc guest agent (guest management). Not required for compute nodes and slows provisioning')
param enableGuestManagement bool = false

param tags object = {}

var ipConfigProperties = union({
  subnet: {
    id: logicalNetworkId
  }
}, empty(ipAddress) ? {} : {
  privateIPAddress: ipAddress
})

resource nic 'Microsoft.AzureStackHCI/networkInterfaces@2024-01-01' = {
  name: '${nodeName}-nic'
  location: location
  tags: tags
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    ipConfigurations: [
      {
        name: '${nodeName}-ipconfig'
        properties: ipConfigProperties
      }
    ]
  }
}

resource machine 'Microsoft.HybridCompute/machines@2025-01-13' = {
  name: nodeName
  location: location
  tags: tags
  kind: 'HCI'
  identity: {
    type: 'SystemAssigned'
  }
}

resource vm 'Microsoft.AzureStackHCI/virtualMachineInstances@2024-01-01' = {
  name: 'default'
  scope: machine
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    hardwareProfile: {
      vmSize: 'Custom'
      processors: processors
      memoryMB: memoryMB
    }
    osProfile: {
      adminUsername: adminUsername
      computerName: nodeName
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: enableGuestManagement
        provisionVMConfigAgent: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    securityProfile: {
      enableTPM: false
    }
    storageProfile: union({
      imageReference: {
        id: imageId
      }
    }, empty(storagePathId) ? {} : {
      vmConfigStoragePathId: storagePathId
    })
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

output vmId string = vm.id
output nicId string = nic.id
