# Zscapek
[![ISO Release Build](https://github.com/whit3rabbit/zigk/actions/workflows/build-iso.yml/badge.svg?event=release)](https://github.com/whit3rabbit/zigk/actions/workflows/build-iso.yml)

Zscapek is a 64-bit modular monolithic operating system kernel written in Zig. It targets the x86_64 architecture and utilizes the Limine bootloader.

While the project uses a clean module structure to separate concerns, it operates as a monolithic kernel. Device drivers, the network stack, and file system logic run in kernel space (Ring 0) to maximize performance and simplify hardware access.

## Architecture

Zscapek is designed with a modular monolithic architecture. Unlike a microkernel, essential system services and drivers are compiled directly into the kernel binary.

- **Privilege Level:** Drivers (Network, Storage, GPU) and the TCP/IP stack execute in Ring 0.
- **Memory Model:** The kernel utilizes a Higher Half Direct Map (HHDM) for physical memory access.
- **System Calls:** Userspace interacts with the kernel via a Linux-compatible syscall ABI (interrupt 0x80/syscall instruction) rather than IPC message passing.
- **Further reading:** Boot flow and memory layout are detailed in [docs/BOOT.md](docs/BOOT.md) and [docs/BOOT_ARCHITECTURE.md](docs/BOOT_ARCHITECTURE.md). The HAL boundary and directory map are in [docs/FILESYSTEM.md](docs/FILESYSTEM.md).

## Features

### Core Kernel
- **Memory Management:**
  - Physical Memory Manager (PMM) using bitmap allocation.
  - Virtual Memory Manager (VMM) supporting 4-level paging.
  - Slab-like kernel heap allocator with immediate coalescing.
  - Userspace Virtual Memory Area (VMA) tracking for `mmap` and `brk`.
  - Compiler-inserted stack guard protection seeded via hardware entropy.
- **Scheduling:**
  - Preemptive Round-Robin scheduler.
  - Support for kernel and user threads.
  - Process model supporting `fork`, `execve`, and `waitpid`.

### Networking
Zscapek includes a native, in-kernel TCP/IP stack.
- **Protocols:** Ethernet, ARP, IPv4, ICMP, UDP, and TCP.
- **TCP Support:** Implements RFC 793 state machine, sliding windows, retransmission timers, and congestion control.
- **Socket API:** BSD-style interface supporting `socket`, `bind`, `connect`, `accept`, `listen`, `send`, and `recv`.
- **Drivers:** Intel E1000e (PCIe Gigabit Ethernet) and VirtIO-Net (paravirtualized) with NAPI-style interrupt handling.
- **Zero-Copy IPC:** Ring buffer based inter-process communication between VirtIO-Net driver and netstack using decomposed SPSC pattern for MPSC semantics. 128-byte cache line alignment prevents false sharing.

### Hardware Support
- **Bus:** PCI enumeration with BAR mapping and MSI/MSI-X interrupt support.
- **Video:**
  - VirtIO-GPU driver for paravirtualized 2D acceleration.
  - UEFI Framebuffer fallback.
  - Double-buffered console with ANSI escape code support.
- **Storage:** AHCI (SATA) driver implementing DMA Scatter/Gather.
- **Input:** PS/2 Keyboard and Mouse drivers.
- **Interrupts:** APIC and I/O APIC support.
- **Entropy:** RDRAND (Intel/AMD) support with RDTSC fallback.

### Userspace
- **ELF64 Loader:** Parses and loads static binaries.
- **InitRD:** TAR-based initial ramdisk for loading user programs.
- **System Services:**
  - **Shell:** Interactive shell with basic command processing.
  - **HTTPD:** Multi-threaded web server demonstrating the kernel TCP stack.
- **CRT0:** Custom C Runtime startup code.

## Build and Run

See [docs/BUILD.md](docs/BUILD.md) for platform-specific notes and Docker-based builds.

### Requirements
- Zig 0.16.x
- QEMU (for emulation)
- xorriso (for ISO generation)

### Compilation
To build the kernel, userspace programs, and generate the bootable ISO:

```bash
zig build -Doptimize=ReleaseSafe
```

### Running in QEMU
To run the system with networking and VirtIO-GPU enabled:

```bash
zig build run
```

This configuration forwards local port 8080 to the guest port 80. Once the system boots and the `httpd` process starts, the web server is accessible at `http://localhost:8080`.

### Running with Custom UEFI Bootloader (Experimental)
To run the skeletal UEFI bootloader (Phase 2):

```bash
zig build run-uefi -Dbios=/path/to/OVMF.fd
```

Note: You must provide a valid UEFI firmware image (e.g. `OVMF.fd`). A known working copy can be found in the repository root as `OVMF_CODE.fd`.

## Roadmap

- **SMP:** Symmetric Multiprocessing support.
- **VFS:** Abstract Virtual File System to unify InitRD and AHCI storage.
- **Dynamic Linking:** Support for shared object (`.so`) loading.
- ~~**VirtIO Net:** Paravirtualized network driver implementation.~~ (Done)

## License

MIT License
