# zk Planned Features

> When a feature is completed, move it to `FEATURES.md` using the same `- **Name**: one-sentence description` format.

## Network Stack
- **Multicast Routing**: mDNS/service discovery (partial)
- **EDNS0**: Large DNS responses (>512 bytes)

## Storage
- **IDE/PIIX**: Legacy VM compatibility
- **GPT Write**: Partition modification (read-only only)

## Display
- **QXL Driver**: SPICE acceleration
- **Bochs/Cirrus VGA**: Legacy boot support
- **Resolution Auto-Resize**: Host-requested resize pending

## Shared Folders
- **VirtIO-9P**: Plan 9 filesystem for QEMU/KVM
- **VirtIO-FS**: FUSE-based virtiofs
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
- **Directory Ops**: mkdir/rmdir return EROFS on InitRD (read-only); chdir only works for "/" (flat InitRD)
- **Environment**: Static storage (4096 bytes, 128 vars max)
- **vasprintf**: Limited to 4096 bytes output (no va_copy)
