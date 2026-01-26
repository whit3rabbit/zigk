# zk Planned Features

> When a feature is completed, move it to `FEATURES.md` using the same `- **Name**: one-sentence description` format.

## Network Stack
- *(mDNS/DNS-SD moved to FEATURES.md)*

## Storage
- **IDE/PIIX**: Legacy VM compatibility
- **GPT Write**: Partition modification (read-only only)

## Display
- **QXL Driver**: SPICE acceleration
- **Cirrus VGA**: Legacy graphics for older VMs

## Shared Folders
- **HGFS**: VMware Host-Guest File System
- **VBoxSF**: VirtualBox Shared Folders

## Paravirtualized Devices
- **VMXNET3**: VMware 10GbE performance
- **PVSCSI**: VMware low-latency storage

## Guest Agents
- **QEMU GA**: Full VirtIO-Console integration, fs-freeze
- **open-vm-tools**: Full VMware Tools parity

## Graphics Acceleration
- **SVGA3D**: 3D command submission
- **VirtIO-GPU 3D**: Virgl rendering
- **VBoxSVGA**: VirtualBox 3D

## VirtualBox-Specific
- **VBoxGuest**: Guest additions core
- **VBoxVideo**: Paravirtualized display
- **Seamless Mode**: Window integration

## Hyper-V (Not Implemented)
- **VMBus**: Transport layer
- **StorVSC/NetVSC**: Paravirtualized storage/network
- **Synthetic Interrupt Controller**

## Libc Limitations
- **Directory Ops**: mkdir/rmdir return EROFS on InitRD (read-only filesystem)
