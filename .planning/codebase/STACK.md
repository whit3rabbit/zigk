# Technology Stack

**Analysis Date:** 2026-02-06

## Languages

**Primary:**
- Zig 0.16.x (Nightly) - Entire kernel and bootloader implementation
  - Location: `src/`, `build.zig`
  - Minimum version: `0.16.0-dev.1484` (specified in `build.zig.zon`)

**Secondary:**
- Assembly (x86_64 and AArch64)
  - x86_64: `src/arch/x86_64/lib/asm_helpers.S`, `src/arch/x86_64/lib/memcpy.S`, `src/arch/x86_64/boot/smp_trampoline.S`
  - AArch64: `src/arch/aarch64/lib/asm_helpers.S`, `src/arch/aarch64/boot/entry.S`
  - User-space CRT0: `src/user/crt0.S`, `src/user/lib/libc/setjmp.S`

## Runtime

**Environment:**
- Freestanding (bare-metal)
  - Kernel target: `os_tag = .freestanding`, `abi = .none`
  - User target: `os_tag = .freestanding`, `abi = .none`
  - UEFI bootloader target: `os_tag = .uefi`, `abi = .msvc` (x86_64) / `.none` (aarch64)

**Architectures:**
- Primary: x86_64 (AMD64) with freestanding ABI
- Secondary: AArch64 (ARMv8-A) with freestanding ABI
- Build system produces dual-arch binaries (`kernel-x86_64.elf`, `kernel-aarch64.elf`)

**CPU Feature Flags:**
- x86_64 kernel: **Disables** SSE, SSE2, AVX, AVX2, MMX; **Enables** soft-float
  - Reason: Prevent floating-point register clobbering in kernel context (ISR safety)
- AArch64: Standard FPU allowed in user space

**Package Manager:**
- Zig Build System (`zig build`)
  - No external package dependencies (`build.zig.zon` declares empty `.dependencies`)
  - All dependencies are built in-tree

## Frameworks & Subsystems

**Core Kernel:**
- Hardware Abstraction Layer (HAL) - `src/arch/` (architecture-agnostic interface)
- Physical Memory Manager (PMM) - `src/kernel/mm/pmm.zig`
- Virtual Memory Manager (VMM) - `src/kernel/mm/vmm.zig`
- Slab Allocator - `src/kernel/mm/slab.zig`
- Heap Allocator - `src/kernel/mm/heap.zig`
- Scheduler (thread scheduling) - `src/kernel/proc/sched/root.zig`
- ACPI Parser - `src/kernel/acpi/root.zig`

**File System:**
- VFS (Virtual File System) - `src/fs/root.zig`
- InitRD (USTAR tar format) - read-only root mount
- SFS (Simple File System) - persistent storage on `/mnt`
- Partition parsing - `src/fs/partitions/`

**Networking:**
- TCP/IP Stack - `src/net/`
  - Ethernet layer - `src/net/ethernet/`
  - IPv4 - `src/net/ipv4/`
  - IPv6 - `src/net/ipv6/` (basic support)
  - TCP (RFC 793) - `src/net/transport/tcp/` with RFC 6528 ISN generation
  - UDP - `src/net/transport/icmp.zig`
  - ICMP - `src/net/transport/icmp.zig` (RFC 792)
  - DNS - `src/net/dns/`
  - mDNS - `src/net/mdns/`
  - Ring-buffer IPC protocol - `src/uapi/ipc/ring.zig`

**Drivers:**
- PCI/PCIe (ECAM enumeration) - `src/drivers/pci/`
- VirtIO (paravirtual devices) - `src/drivers/virtio/`
  - VirtIO-Net (network)
  - VirtIO-GPU (graphics)
  - VirtIO-SCSI (storage)
  - VirtIO-Input (keyboard/mouse)
  - VirtIO-Sound (audio)
  - VirtIO-9P (file sharing)
  - VirtIO-FS (FUSE-based file sharing)
- Storage:
  - AHCI (SATA) - `src/drivers/storage/ahci/`
  - NVMe - `src/drivers/storage/nvme/`
  - IDE (legacy) - `src/drivers/storage/ide/` (x86_64 only)
- Network:
  - Intel E1000e (PCIe) - `src/drivers/net/e1000e/`
  - Loopback - `src/net/drivers/loopback.zig`
- Video:
  - VirtIO-GPU 2D - `src/drivers/virtio/`
  - UEFI Framebuffer - fallback from bootloader
  - VGA (BGA, SVGA, Cirrus, QXL) - `src/drivers/video/`
- Input:
  - PS/2 - `src/drivers/input/ps2/` (x86_64 only)
  - USB (xHCI/EHCI) - `src/drivers/usb/`
- Serial:
  - 16550 UART (x86_64) - `src/drivers/serial/uart_16550.zig`
  - PL011 UART (aarch64) - `src/drivers/serial/pl011.zig`
- Audio:
  - Intel HDA - native driver in kernel
  - AC97 - native driver in kernel
- Hypervisor Guest Additions:
  - VirtualBox VMMDev - `src/drivers/vbox/`
  - VMware Tools - `src/drivers/vmware/`
- IOMMU:
  - Intel VT-d - `src/kernel/mm/iommu.zig`

**Cryptography & Security:**
- ChaCha20 stream cipher (RFC 8439) - `src/kernel/core/random.zig`
- SipHash-2-4 - `src/net/transport/tcp/state.zig` (hash DoS protection, TCP ISN generation)
- RDRAND/RDSEED entropy - `src/arch/*/kernel/entropy.zig`
- Stack canaries - `src/kernel/core/stack_guard.zig`
- KASLR (Address Space Layout Randomization) - `src/kernel/mm/aslr.zig`

**User Space:**
- Custom libc - `src/user/lib/libc/`
- ELF64 loader - `src/user/lib/loader.zig`
- System call interface - `src/uapi/syscalls/`
- Test runner - `src/user/test_runner/`
- Shell - `src/user/shell/`
- Doom port - `src/user/doom/`
- HTTP daemon - `src/user/httpd/`
- Network stack (userspace) - `src/user/netstack/`

## Configuration

**Build Options (build.zig):**

| Option | Default | Purpose |
|--------|---------|---------|
| `-Darch` | `x86_64` | Target architecture (x86_64 or aarch64) |
| `-Doptimize` | `ReleaseSafe` | Optimization level |
| `-Dversion` | `0.1.0` | Kernel version string |
| `-Dname` | `ZK` | Kernel name |
| `-Dstack-size` | 16 KiB | Thread stack size |
| `-Dheap-size` | 2 MiB | Kernel heap size |
| `-Dmax-threads` | 64 | Maximum thread count |
| `-Dtimer-hz` | 100 | Timer frequency (Hz) |
| `-Dserial-baud` | 115200 | Serial port baud rate |
| `-Ddebug` | true | Enable debug output |
| `-Ddebug-memory` | false | Enable memory allocation logging |
| `-Ddebug-scheduler` | false | Enable scheduler logging |
| `-Ddebug-network` | false | Enable network logging |
| `-Dboot-logo` | true | Show animated boot logo |
| `-Dbios` | auto-detect | UEFI firmware path override |
| `-Dvars` | auto-detect | UEFI variables path override |
| `-Drun-iso` | false | Boot from ISO (vs disk image) |
| `-Ddisplay` | default | QEMU display backend (sdl, gtk, cocoa, none) |
| `-Dqemu-args` | none | Extra QEMU arguments |
| `-Dvirtfs` | none | VirtIO-9P host directory to share |
| `-Dusb-hub` | false | Attach USB hub to XEMU |
| `-Dnvme` | false | Add NVMe test device |
| `-Daudio` | platform-specific | QEMU audio backend (none, coreaudio, pa, file) |
| `-Dallow-weak-entropy` | false | Allow weak entropy (testing only) |

**Build Targets:**

| Target | Description |
|--------|-------------|
| `zig build` | Build kernel + bootloader + user space (default x86_64) |
| `zig build iso -Darch=x86_64` | Create bootable UEFI ISO |
| `zig build iso -Darch=aarch64` | Create bootable UEFI ISO (ARM) |
| `zig build run -Darch=x86_64` | Build and run in QEMU |
| `zig build run -Darch=aarch64` | Build and run in QEMU (ARM) |
| `zig build test` | Run Zig unit tests |
| `zig build test-kernel` | Run integration tests in kernel test runner |

## Platform Requirements

**Development:**
- Zig 0.16.x (Nightly)
- QEMU (system emulator with KVM/HVF/TCG acceleration)
- xorriso (ISO generation)
- macOS: Homebrew QEMU (no GTK/SDL, uses Cocoa display)
- macOS: EDK2 UEFI firmware (auto-detected at `/opt/homebrew/share/qemu/` or `/usr/local/share/qemu/`)
- Linux: OVMF or EDK2 firmware in standard paths

**Build Artifacts:**
- `zig-out/bin/kernel-x86_64.elf` (x86_64 kernel, freestanding)
- `zig-out/bin/kernel-aarch64.elf` (aarch64 kernel, freestanding)
- `zig-out/bin/bootx64.efi` (x86_64 UEFI bootloader)
- `zig-out/bin/bootaa64.efi` (aarch64 UEFI bootloader)
- `zig-cache/` (Zig build cache, auto-managed)
- `zig-out/` (Final artifacts)

**Production (Emulation):**
- QEMU 7.0+ with architecture support (x86_64-system, aarch64-system)
- VirtIO drivers (network, storage, graphics)
- BIOS/UEFI firmware (OVMF for x86_64, AAVMF/EDK2 for aarch64)
- Hardware: x86_64 or AArch64 CPU
- Memory: 512 MiB minimum (1 GiB recommended)

## External Tools & Utilities

**Build & Compilation:**
- Zig compiler (0.16.x) - Entire compilation pipeline
- LLVM/Clang (bundled with Zig)

**Testing & CI:**
- QEMU - Kernel execution and testing
- `scripts/run_tests.sh` - Test orchestration with 90s timeout
- TAP (Test Anything Protocol) - Test output format

**ISO & Disk Creation:**
- xorriso - UEFI ISO generation
- mtools - FAT filesystem manipulation
- grub-common / grub-pc-bin (Docker builds)

**Containerization:**
- Docker (optional) - `Dockerfile` for multi-architecture builds
- Docker Compose (optional) - `docker-compose.yml` for build orchestration

---

*Stack analysis: 2026-02-06*
