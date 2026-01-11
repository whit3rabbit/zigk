# Zscapek
[![ISO Release Build](https://github.com/whit3rabbit/zigk/actions/workflows/build-iso.yml/badge.svg?event=release)](https://github.com/whit3rabbit/zigk/actions/workflows/build-iso.yml)

Zscapek is a 64-bit modular monolithic operating system kernel written in Zig. It targets both **x86_64** (AMD64) and **AArch64** (ARMv8-A) architectures, featuring a custom UEFI bootloader and a unified Hardware Abstraction Layer (HAL).

While the project uses a clean module structure to separate concerns, it operates as a monolithic kernel. Device drivers, the network stack, and file system logic run in kernel space (Ring 0 / EL1) to maximize performance and simplify hardware access.

## Architecture

Zscapek is designed with a modular monolithic architecture. Unlike a microkernel, essential system services and drivers are compiled directly into the kernel binary.

- **Privilege Level:** Drivers (Network, Storage, GPU) and the TCP/IP stack execute in Ring 0 (x86) or EL1 (ARM).
- **Memory Model:** The kernel utilizes a Higher Half Direct Map (HHDM) for physical memory access.
- **System Calls:** Userspace interacts with the kernel via a Linux-compatible syscall ABI (interrupt 0x80/syscall instruction) rather than IPC message passing.
- **Further reading:** Boot flow and memory layout are detailed in [docs/BOOT.md](docs/BOOT.md) and [docs/BOOT_ARCHITECTURE.md](docs/BOOT_ARCHITECTURE.md). The HAL boundary and directory map are in [docs/FILESYSTEM.md](docs/FILESYSTEM.md).

## Features

### Best Features

A quick overview of the capabilities detailed in [docs/FEATURES.md](docs/FEATURES.md):

#### 🏗️ Architecture & Core
- **Dual-Arch Support**: Single codebase for **x86_64** and **AArch64** with a unified, zero-cost HAL.
- **Security First**: KASLR, Stack Canaries, Hardware Entropy (RDRAND/FEAT_RNG), and strict User/Kernel isolation (SMAP/PAN).
- **Modern Memory**: Higher-Half Direct Map (HHDM), IOMMU protection (VT-d), and slab-like kernel heap allocator.

#### 🌐 Networking
- **Zero-Copy Stack**: In-kernel TCP/IP (RFC 793) designed for performance with zero-copy packet processing.
- **High Performance**: NAPI-style interrupt handling and ring-buffer IPC (128-byte cache line alignment).
- **Drivers**: Intel E1000e (PCIe), VirtIO-Net, and Loopback.

#### 🎮 Graphics & Userspace
- **Graphics**: VirtIO-GPU 2D acceleration, UEFI Framebuffer, and redundant "Double-Fault" display handling.
- **Doom Port**: Runs vanilla Doom with music and sound effects to demonstrate system stability and audio/video subsystems.
- **Linux Compatibility**: `io_uring` support, standard libc (musl-like), and ELF64 loader.

#### 🔌 Hardware Support
- **USB Stack**: Native xHCI (USB 3.0) and EHCI (USB 2.0) support.
- **Storage**: AHCI (SATA) driver with DMA Scatter/Gather and async I/O.
- **Audio**: Intel HDA and AC97 drivers for high-fidelity sound.

## Build and Run

See [docs/BUILD.md](docs/BUILD.md) for platform-specific notes and Docker-based builds.

### Requirements
- Zig 0.16.x
- QEMU (for emulation)
- xorriso (for ISO generation)

### Compilation

To build the kernel, userspace programs, and generate the bootable ISO:

```bash
# Build for x86_64 (default)
zig build -Darch=x86_64 -Doptimize=ReleaseSafe

# Build for AArch64
zig build -Darch=aarch64 -Doptimize=ReleaseSafe
```

**Dual-Architecture Support:** The build system produces architecture-named kernel binaries (`kernel-x86_64.elf`, `kernel-aarch64.elf`) that coexist in `zig-out/bin/`. You can build for both architectures without overwrites:

```bash
zig build -Darch=x86_64 && zig build -Darch=aarch64
ls zig-out/bin/kernel-*.elf  # Both exist
```

Architecture-specific build targets:

| Target | Description |
| :--- | :--- |
| `iso -Darch=x86_64` | Build bootable x86_64 UEFI ISO |
| `iso -Darch=aarch64` | Build bootable AArch64 UEFI ISO |
| `run -Darch=x86_64` | Build and run x86_64 kernel in QEMU |
| `run -Darch=aarch64` | Build and run AArch64 kernel in QEMU |

### Running with QEMU

The build system wraps QEMU for easy testing. The `run` steps automatically configure networking (user mode), KVM/HVF acceleration, and device flags.

| Command | Architecture | Description |
| :--- | :--- | :--- |
| `zig build run -Darch=x86_64` | x86_64 | Runs in QEMU (uses KVM on Linux, HVF on macOS if avail) |
| `zig build run -Darch=aarch64` | AArch64 | Runs in QEMU (uses HVF on Apple Silicon, TCG otherwise) |

#### Common Options

**Boot Target**:
Choose what to boot into with `-Ddefault-boot`:
```bash
zig build run -Darch=x86_64 -Ddefault-boot=shell  # Interactive shell
zig build run -Darch=x86_64 -Ddefault-boot=doom   # Doom (default)
```

**Networking**:
By default, port **8080** on localhost is forwarded to guest port **80**.
- Access the web server: `http://localhost:8080`

**Firmware Overrides**:
If the auto-detection fails or you want to test specific firmware:
```bash
zig build run -Darch=x86_64 -Dbios=/path/to/OVMF.fd
```

**Boot from Disk Image**:
To boot from the GPT-partitioned disk (`disk.img`) instead of the ISO:
```bash
zig build run -Darch=x86_64 -Drun-iso=false
```

**Headless Mode**:
To run without a display (useful for CI):
```bash
zig build run -Darch=x86_64 -Dheadless=true
```

## Roadmap

- **SMP:** Symmetric Multiprocessing support.
- **VFS:** Abstract Virtual File System to unify InitRD and AHCI storage.
- **Dynamic Linking:** Support for shared object (`.so`) loading.
- ~~**VirtIO Net:** Paravirtualized network driver implementation.~~ (Done)

## License

MIT License
