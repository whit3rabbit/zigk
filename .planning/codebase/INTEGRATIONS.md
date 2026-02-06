# External Integrations

**Analysis Date:** 2026-02-06

## Emulation & QEMU Integration

**QEMU Emulation:**
- Platform: Both x86_64 and aarch64 architectures
- Acceleration: KVM (Linux), HVF (macOS), TCG (fallback)
- Launch: Configured via `build.zig` run steps with auto-detection

**QEMU Device Configuration:**
- Machine types: `pc` (x86_64), `virt` (aarch64)
- CPU: host (with KVM), cortex-a57 (aarch64with HVF)
- Memory: Configurable (default: 512 MiB)
- Display: Auto (Cocoa on macOS, SDL/GTK on Linux), headless option via `-Ddisplay=none`
- Networking: User-mode (port 8080 -> guest 80)
- Audio backends: coreaudio (macOS), PulseAudio (Linux), file (testing)

**UEFI Firmware Integration:**
- Auto-detection paths (macOS):
  - `/opt/homebrew/share/qemu/edk2-x86_64-code.fd` + `edk2-x86_64-vars.fd`
  - `/opt/homebrew/share/qemu/edk2-aarch64-code.fd` + `edk2-arm-vars.fd`
  - Fallback: `/usr/local/share/qemu/`
- Auto-detection paths (Linux):
  - `/usr/share/OVMF/OVMF_CODE.fd` + `OVMF_VARS.fd`
  - `/usr/share/AAVMF/AAVMF_CODE.fd` + `AAVMF_VARS.fd`
  - `/usr/share/edk2/`
  - `/usr/share/qemu-efi-aarch64/`
- Override: `-Dbios=/path/to/firmware.fd -Dvars=/path/to/vars.fd`
- Reason: UEFI boot protocol enables secure boot, ACPI table parsing, GPT partitions

## Hardware Interfaces & Protocols

### PCI/PCIe

**Purpose:** Discover and initialize hardware devices
- Implementation: `src/drivers/pci/root.zig`
- ECAM (Enhanced Configuration Address Mapping) support
- MSI-X interrupts (preferred) and legacy INTx
- BAR access (MMIO and I/O port ranges)

**Device Classes Supported:**
- Network (Class 0x02): Intel E1000e, VirtIO-Net
- Storage (Class 0x01): AHCI, NVMe, VirtIO-SCSI
- Video (Class 0x03): VirtIO-GPU, VGA variants
- Serial (Class 0x07): UART (x86), PL011 (ARM)
- USB (Class 0x0C): xHCI, EHCI
- Audio (Class 0x04): Intel HDA, AC97
- Input (Class 0x09): Keyboard, mouse via USB

### VirtIO (Paravirtual Devices)

**Protocol Version:** VirtIO 1.0+ over PCIe
- Common implementation: `src/drivers/virtio/common.zig`
- Ring buffer for command queues
- Interrupt/notification via MSI-X (x86_64) or platform IRQ (aarch64)

**Supported Devices:**
1. **VirtIO-Net** - Network interface
   - Protocol: Ethernet frames via VirtIO queue
   - RX/TX queues with scatter-gather
   - Integration: `src/net/drivers/virtio_net.zig`

2. **VirtIO-SCSI** - Block storage via SCSI protocol
   - Command/Response queue model
   - Location: `src/drivers/virtio/scsi/`

3. **VirtIO-GPU** - 2D graphics acceleration
   - Resolution change notifications
   - Scanout (framebuffer) operations
   - Location: `src/drivers/virtio/` (no separate module)

4. **VirtIO-Input** - Keyboard, mouse, tablet
   - Event codes (REL_X/Y for mouse, KEY_* for keyboard)
   - Location: `src/drivers/virtio/input/`

5. **VirtIO-Sound** - Audio playback/capture
   - PCM streams with buffer allocation
   - Location: `src/drivers/virtio/sound/`

6. **VirtIO-9P** - File sharing (9P protocol)
   - Stateful file operations (WALK, OPEN, READ, WRITE)
   - Location: `src/drivers/virtio/9p/`
   - QEMU attach: `zig build run -Dvirtfs=/tmp/share`

7. **VirtIO-FS** - File sharing (FUSE-based)
   - FUSE protocol tunneling for better compatibility
   - Location: `src/drivers/virtio/fs/`

### Storage Protocols

**AHCI (SATA):**
- Driver: `src/drivers/storage/ahci/`
- Command Table structure (CT) and Received FIS buffer
- DMA Scatter-Gather support
- Async I/O integration via kernel Reactor

**NVMe (PCIe SSD):**
- Driver: `src/drivers/storage/nvme/`
- Submission/Completion Queue pairs
- I/O command opcodes (Read, Write, Flush)
- Interrupt handling (MSI-X preferred)

**IDE (Legacy, x86_64 only):**
- Driver: `src/drivers/storage/ide/`
- Legacy ISA I/O ports
- Programmed I/O (no DMA, for testing only)

### Network Protocols

**Layers 2-3:**
- Ethernet (IEEE 802.3) - `src/net/ethernet/`
- IPv4 (RFC 791) - `src/net/ipv4/`
- IPv6 (RFC 2460, basic) - `src/net/ipv6/`
- ARP (RFC 826) - within Ethernet layer

**Layers 4+:**
- TCP (RFC 793) - `src/net/transport/tcp/`
  - ISN generation: RFC 6528 (SipHash-2-4 + hardware entropy)
  - SACK, window scaling, Nagle algorithm
- UDP (RFC 768) - `src/net/transport/icmp.zig`
- ICMP (RFC 792) - `src/net/transport/icmp.zig`
- DNS (UDP port 53) - `src/net/dns/`
- mDNS (multicast DNS) - `src/net/mdns/`

**Ring-buffer IPC (Custom):**
- Zero-copy packet passing between kernel and userspace
- Location: `src/uapi/ipc/ring.zig`
- 128-byte cache-line aligned for performance

### USB Protocol

**Controllers:**
- xHCI (USB 3.0, Intel/VIA) - `src/drivers/usb/xhci/`
  - Transfer Request Blocks (TRBs) on aligned rings
  - Event queue for interrupt handling
  - Multi-queue support per device

- EHCI (USB 2.0, legacy) - `src/drivers/usb/ehci/`
  - qH (queue head) and qTD (queue token descriptor) structures
  - Frame list scheduling

**Device Classes:**
- HID (Human Interface Device) - Keyboard, mouse, tablet
- Mass Storage Class (MSC) - USB drives, external storage
- Audio Class - USB audio devices

### Graphics Protocols

**Framebuffer Output:**
- UEFI Graphics Output Protocol (GOP) - from bootloader
- VESA VBE fallback
- VirtIO-GPU (paravirtual)
- VGA modes (BGA, SVGA, Cirrus, QXL for QEMU)

**Font Rendering:**
- PSF (PC Screen Font) format - `src/drivers/video/font/`
- Unicode support for terminal

### Input Protocols

**PS/2 (x86_64 only):**
- Keyboard and mouse via ISA ports
- Driver: `src/drivers/input/ps2/`
- Keyboard layouts (QWERTY, etc.) - `src/drivers/input/layouts/`

**USB HID:**
- Keyboard and mouse via USB
- Report Descriptor parsing
- Boot Protocol mode

## Security Protocols & Features

**Entropy Sources:**
- RDRAND instruction (x86_64) - `src/arch/x86_64/kernel/entropy.zig`
- RDSEED instruction (x86_64)
- FEAT_RNG system register (aarch64) - `src/arch/aarch64/kernel/entropy.zig`
- ChaCha20 stream cipher seeded from hardware entropy - `src/kernel/core/random.zig`

**Memory Protection:**
- SMAP (Supervisor Mode Access Prevention, x86_64) - enforced via HAL
- PAN (Privileged Access Never, aarch64) - enforced via HAL
- SMEP (Supervisor Mode Execution Prevention, x86_64)
- MMU: Page-level access control (user/kernel separation)
- Stack canaries - `src/kernel/core/stack_guard.zig`
- KASLR (Address Space Layout Randomization) - `src/kernel/mm/aslr.zig`

**IOMMU Protection:**
- Intel VT-d (x86_64 only) - `src/kernel/mm/iommu.zig`
- DMA isolation for PCI devices
- Device isolation for untrusted hardware

## System Interfaces (User-Facing)

**Syscall ABI (Linux-compatible):**
- x86_64: INT 0x80 and SYSCALL instruction (both supported)
- aarch64: SVC #0 (Supervisor Call)
- Syscall numbers: Linux x86_64 and aarch64 ABIs
  - Custom compat range: SYS_* 500+ for zk-specific extensions
  - Location: `src/uapi/syscalls/`

**io_uring (Linux Async I/O):**
- Submission Queue (SQ) and Completion Queue (CQ) with shared memory
- User-kernel shared memory ring buffers
- Syscalls: `sys_io_uring_setup`, `sys_io_uring_enter`, `sys_io_uring_register`
- Location: `src/uapi/io/io_ring.zig`

**Ring-buffer IPC (Custom):**
- Shared memory rings for producer-consumer patterns
- Syscalls: `sys_ring_create`, `sys_ring_attach`, `sys_ring_notify`, `sys_ring_wait`
- Location: `src/uapi/ipc/ring.zig`
- Use case: High-throughput driver communication (VirtIO, netstack)

**ELF64 Binary Format:**
- Executable executable and linking format for userspace programs
- Dynamic sections for relocations
- Loader: `src/user/lib/loader.zig`
- Interpreter: `/lib64/ld-musl-x86_64.so.1` (stub path, musl-compatible)

## Hypervisor Guest Integrations

**VirtualBox Guest Additions:**
- VMMDev port communication - `src/drivers/vbox/vmmdev/`
- Shared folders (SMB) - `src/drivers/vbox/sf/`

**VMware Tools:**
- VMCI (Virtual Machine Communication Interface)
- Shared folders support - `src/drivers/vmware/`

## CI/CD & Testing Infrastructure

**GitHub Actions:**
- Workflow file: `.github/workflows/ci.yml`
- Builds: x86_64 and aarch64 architectures
- Test runner: `scripts/run_tests.sh` with 90s timeout
- Test output: TAP (Test Anything Protocol) format

**Docker (Optional):**
- Container image: `Dockerfile` multi-stage build
- Zig compiler version pinning
- ISO generation with xorriso
- Compose orchestration: `docker-compose.yml`

## Bootloader Contract

**UEFI Protocol:**
- Application: `src/boot/uefi/main.zig`
- Target: UEFI firmware for x86_64 (MSVC ABI) and aarch64 (None ABI)
- Handoff structure: `src/boot/common/boot_info.zig` (BootInfo struct passed to kernel)

**BootInfo Contents:**
- Kernel entry point
- Kernel load address
- Memory map (EFI_MEMORY_DESCRIPTOR array)
- InitRD (USTAR tar) base address and size
- RSDP (ACPI Root System Description Pointer) for ACPI table discovery
- Screen/Framebuffer information (for VGA drivers)
- Kernel command-line arguments

**InitRD Mounting:**
- USTAR tar format (no compression)
- Mounted as read-only root filesystem (`/`)
- Used for bootstrap programs (shell, test runner, doom)

---

*Integration audit: 2026-02-06*
