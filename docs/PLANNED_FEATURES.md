# zk Planned Features

> When a feature is completed, move it to `FEATURES.md` using the same `- **Name**: one-sentence description` format.

## Build System Fixes (Priority)
- **disk_image.zig Zig 0.16 Compat**: `tools/disk_image.zig:109` uses `posix.open()` which was removed in Zig 0.16 - migrate to new `std.fs` or `std.Io.Dir` APIs

## Network Stack
- *(mDNS/DNS-SD moved to FEATURES.md)*

## Storage
- **IDE/PIIX**: Legacy VM compatibility
- **GPT Write**: Partition modification (read-only only)

## Display
- **QXL 2D Accel**: Command rings for hardware-accelerated 2D operations (Phase 2)
- **QXL Cursor**: Hardware cursor support via QXL command interface

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
