This bullet checklist highlights the unique implementation details and features found in your Zig kernel codebase, organized by architecture and core design patterns.

### Core Architectural Features
*   **Provider Pattern Design**: The kernel uses a compile-time architecture selector in `root.zig` to provide a unified HAL (Hardware Abstraction Layer) while maintaining zero-cost abstraction.
*   **Cross-Architecture Syscall Parity**: The `SyscallFrame` uses x86 register naming conventions (rax, rdi, etc.) on AArch64 to allow shared, architecture-independent syscall dispatch logic.
*   **Comptime Safety Assertions**: Extensive use of Zig’s `comptime` to verify that memory layouts (like `SyscallFrame`) and interrupt handler array sizes exactly match low-level assembly expectations.

### AArch64 Implementation (ARMv8-A)
*   **Privileged Access Never (PAN)**: Enforcement of ARM’s PAN feature, requiring explicit `LDTR`/`STTR` assembly helpers for kernel-to-user memory access to prevent security exploits.
*   **Exception Vector Hardening**: Low-level exception vectors include universal bit-63 sign checks to prevent the kernel from accidentally returning to a kernel address while in a user context.
*   **GICv2/v3 Hybrid Support**: A dynamic interrupt controller driver that parses Device Tree information but falls back to safe QEMU virt machine defaults if necessary.
*   **FEAT_RNG Integration**: Utilization of the `RNDR` register for hardware-grade entropy, with a sophisticated timing-based fallback that uses `SplitMix64` for bit distribution.
*   **Flexible ASID Detection**: Runtime detection of 8-bit vs. 16-bit Address Space Identifiers (ASIDs) to optimize TLB management and prevent process-space collisions.
*   **VMware Fusion Support**: Full VMware hypervisor detection and hypercall interface using ARM64-specific `mrs xzr, mdccsr_el0` trap instruction, enabling SVGA graphics, VMMouse, and time synchronization on Apple Silicon Macs.
*   **Paravirtualized Time (pvtime)**: ARM KVM stolen time tracking via SMCCC hypercalls (HVC), providing accurate CPU time measurement under hypervisor by accounting for vCPU preemption. Integrated with timing subsystem for optional stolen-time-adjusted nanoseconds.

### x86_64 Implementation (AMD64)
*   **Intel SYSRET Mitigation**: A security-hardened syscall entry point that manually validates canonical RCX addresses to prevent the "SYSRET privilege escalation" vulnerability.
*   **Intel VT-d IOMMU**: Implementation of DMA remapping with support for DRHD (DMA Remapping Hardware Unit) discovery and hardware-level fault reporting.
*   **Dual-Mode APIC**: Support for both xAPIC (MMIO-based) and x2APIC (MSR-based) for high-performance interrupt handling on modern processors.
*   **Double Fault Handling**: Dedicated handler for double fault exceptions with diagnostic output. SYSCALL entry manages GS base via SWAPGS.
*   **SMP Trampoline**: A position-independent bootstrap mechanism that transitions Application Processors (APs) from 16-bit Real Mode to 64-bit Long Mode via patched immediate values.
*   **VMware Hypercall Interface**: A cross-architecture driver for hypervisor-specific guest-host communication, enabling integrated mouse and time synchronization in virtual environments. Uses I/O port 0x5658 on x86_64 and `mrs xzr, mdccsr_el0` trap on aarch64.

### Memory & MMIO
*   **HHDM Guarding**: The `physToVirt` translation layer includes mandatory overflow checks to ensure physical addresses never wrap around into user virtual space.
*   **Type-Safe MMIO Wrapper**: The `MmioDevice` utility uses enums and `comptime` to ensure register accesses are always within bounds and correctly aligned without runtime overhead.
*   **Aligned MMIO Mapping**: The `mapMmioExplicitAligned()` function supports hardware that requires specific virtual address alignment (e.g., PCI ECAM requires 1MB alignment for bitwise OR address calculations).
*   **Write-Through MMIO Pages**: `PageFlags.MMIO` includes both `cache_disable` and `write_through` flags for strict uncacheable semantics, preventing CPU prefetch buffers from serving stale data.
*   **Checked Timing Delays**: Calibration of the TSC (Time Stamp Counter) via the legacy PIT, providing high-precision blocking delays with protection against integer overflow.
*   **IST Support**: IDT gates support Interrupt Stack Table selection for critical exceptions. TSS structure includes IST entries.

### Entropy & Security
*   **Graded Entropy Quality**: A multi-tier entropy system that categorizes random sources (High/Medium/Low/Critical) and allows the kernel to refuse to boot if high-quality RNG is missing for KASLR.
*   **Atomic Interrupt Dispatch**: Lock-free registration of interrupt handlers using atomic acquire/release semantics to ensure SMP safety without the bottleneck of a Big Kernel Lock.

This checklist covers the features and unique implementation details of the **Common Boot Structures** and the **UEFI Bootloader** components.

### Bootloader Core & Handoff
*   **Unified BootInfo**: A standardized handoff structure sharing memory maps, framebuffer info, ACPI RSDP, and InitRD metadata across architectures.
*   **Dual-Arch Support**: A single codebase that manages x86_64 and AArch64 boot flows using Zig’s `builtin.cpu.arch` for compile-time logic branching.
*   **KASLR Offset Generation**: Calculation of random, page-aligned offsets for kernel stack, heap, and MMIO regions to enhance system security from the moment of boot.
*   **Symbol-Based Entry Discovery**: An ELF loader that prioritizes a specific `_uefi_start` symbol over the standard entry point to handle UEFI-specific initialization.

### Entropy & Security
*   **UEFI RNG Protocol Integration**: Acquisition of high-quality boot-time entropy using the `EFI_RNG_PROTOCOL` to seed KASLR and kernel random generators.
*   **TSC-Based Entropy Fallback**: A sophisticated "weak" entropy collector that mixes TSC timing variance and UEFI stack ASLR jitter when hardware RNG is missing.
*   **Buffer Sanitization**: Mandatory zero-initialization of entropy and file buffers to prevent information leakage from previous boot stages.
*   **ELF Validation Hardening**: Robust ELF header checks, including machine type verification and DoS prevention by capping program/section header counts.

### Memory & Paging
*   **4-Level Paging Handover**: Pre-construction of the translation hierarchy (PML4 for x86 / L0-L3 for ARM) to map the Identity region, HHDM, and Kernel segments.
*   **Checked Memory Iterators**: UEFI memory map processing using checked arithmetic (`std.math`) to prevent overflows from malformed firmware descriptors.
*   **HHDM Base Mapping**: Automated mapping of all physical RAM to a higher-half direct map (HHDM) base (defaulting to `0xFFFF800000000000`).
*   **Flexible Segment Loading**: Support for multiple `PT_LOAD` segments with individual permission handling (RW, RX, RO) and overlap detection.

### Graphics & UI
*   **GOP Framebuffer Standardization**: Automatic conversion of various UEFI Graphics Output Protocol formats (RGB, BGR, Bitmask) into a uniform kernel representation.
*   **Interactive Boot Menu**: A console-based UI with a 5-second auto-boot countdown, timer events, and submenus for selecting specialized test kernels.
*   **Dynamic Video Mode Setting**: Ability to query and set specific horizontal/vertical resolutions before handed-off to the kernel.

### System Discovery
*   **ACPI RSDP Discovery**: Automated scanning of the UEFI Configuration Table to locate the Root System Description Pointer for both ACPI 1.0 and 2.0.
*   **InitRD Discovery**: Automatic loading of `initrd.tar` from the EFI System Partition into kernel-accessible memory.
*   **Early Serial Debugging**: Architecture-specific serial output drivers (I/O port 0x3F8 for x86, PL011 MMIO for ARM) for loader-stage diagnostics.

This checklist covers the features found in your hardware drivers, PCI subsystem, and peripheral stack, focusing on the specialized implementations for x86_64 and AArch64.

### PCI & Hardware Discovery
*   **Dual PCI Access Mechanisms**: Support for both PCIe ECAM (memory-mapped) and legacy Port I/O (x86 0xCF8/0xCFC) with automatic fallback.
*   **ECAM 1MB-Aligned Mapping**: The ECAM driver uses `mapMmioExplicitAligned()` to guarantee the virtual base address is 1MB aligned, enabling correct bitwise OR address calculations per PCIe spec. Runtime assertions verify alignment to prevent address aliasing bugs.
*   **SMP-Safe Enumeration**: Strict enumeration invariants and global locking to prevent race conditions during BAR sizing and interrupt registration.
*   **Automated BAR Sizing**: Intelligent resource probing that handles 32-bit and 64-bit BARs, prefetchable memory, and I/O space.
*   **Capability Linked-List Parsing**: Robust parser for PCI capabilities (MSI, MSI-X, Power Management) with built-in cycle detection to prevent malicious device hangs.

### USB Stack (xHCI & EHCI)
*   **xHCI Transfer Ring Management**: Implementation of Command, Event, and Transfer rings using producer/consumer models and cycle-bit toggling.
*   **Multi-Interface Composite Devices**: Unified configuration parser that extracts all interfaces and endpoints, enabling simultaneous keyboard, mouse, and storage functionality.
*   **USB Hotplug & Disconnect**: Spec-compliant cleanup sequence that stops endpoints and cancels in-flight transfers before releasing device slots.
*   **HID Report Parser**: A bit-level precise descriptor parser that identifies keyboards, mice, and absolute-position tablets/touchscreens.
*   **USB Hub Support**: Generic hub class driver per USB 2.0 Chapter 11 with port feature control, status tracking, and single/multi-TT configurations.
*   **USB Mass Storage Class**: Bulk-Only Transport (BOT) protocol implementation with SCSI command interface, sector detection, and tag-based request tracking.

### Networking (E1000e)
*   **NAPI-Style Polling**: High-performance Intel 82574L driver using a worker thread to drain RX rings, reducing interrupt overhead under heavy load.
*   **Pre-allocated Packet Pool**: A bounded, zero-copy buffer pool that eliminates heap allocation latency and fragmentation during packet processing.
*   **IOMMU-Aware DMA**: Full integration with the system IOMMU for all descriptor rings and packet buffers to ensure hardware memory isolation.
*   **TX Watchdog**: Hardware stall detection that automatically resets the transmit subsystem if the head pointer stops advancing.

### Storage & AHCI
*   **Asynchronous Block I/O**: AHCI driver integrated with kernel `IoRequest` structures for non-blocking sector access.
*   **LBA48 & Scatter-Gather DMA**: Support for large disks and multi-page transfers using Physical Region Descriptor Tables (PRDT).
*   **SATA FIS Communication**: Low-level implementation of Frame Information Structures for H2D commands and D2H status reporting.

### Storage & NVMe
*   **NVMe 1.4+ Compliant Driver**: Full NVMe driver supporting Admin Queue and I/O Queue pairs with proper phase bit toggling for completion detection.
*   **Identify Controller/Namespace**: Complete parsing of 4KB Identify structures with compile-time size verification (`comptime` assertions ensure exact 4096-byte layouts).
*   **PRP-Based Data Transfer**: Physical Region Page (PRP) support for DMA transfers, with automatic PRP list allocation for multi-page operations.
*   **MSI-X Interrupt Integration**: Preference for MSI-X over legacy INTx interrupts, with vector allocation and handler registration through the HAL.
*   **Async I/O Reactor Integration**: NVMe read/write operations integrate with the kernel's `IoRequest` and `Future` patterns for non-blocking disk access.
*   **Namespace Discovery**: Automatic enumeration of active namespaces via Active Namespace List (CNS=02h), with per-namespace LBA size and capacity tracking.
*   **Queue Pair Management**: Separate Admin Queue (QID 0) and I/O Queues with configurable depth, command ID tracking, and SQ/CQ doorbell management.
*   **Controller Reset & Initialization**: Proper CC.EN disable/enable sequence with CSTS.RDY polling and timeout detection per NVMe spec.

### Audio (HDA & AC97)
*   **Intel HDA Controller**: Full High Definition Audio driver with CORB/RIRB ring buffer management, codec detection via STATESTS, and 256-entry command/response rings.
*   **AC97 Legacy Support**: Fallback audio driver for older hardware and QEMU virtual machines.
*   **PC Speaker Tones**: PIT channel 2 integration for diagnostic beeps and simple audio feedback via `beep(frequency_hz, duration_ms)`.

### Timekeeping & RTC
*   **MC146818A RTC Driver**: Full CMOS Real-Time Clock support with date/time read/write, BCD conversion, and 12/24-hour format handling.
*   **RTC Alarm Interrupts**: Programmable alarm with wildcard fields (0xFF = don't care) and IRQ8 handler.
*   **Periodic Interrupts**: 13 configurable frequencies from 2 Hz to 8192 Hz for high-resolution timing applications.
*   **Unix Timestamp Conversion**: Bidirectional conversion functions (`toUnixTimestamp`/`fromUnixTimestamp`) with leap year handling.
*   **Battery-Backed CMOS**: Access to 128 bytes of CMOS RAM for persistent settings.

### PS/2 Controller & Input
*   **8042 Controller Abstraction**: Type-safe status register handling via packed structs for ports 0x60 (data) and 0x64 (status/command).
*   **Controller Self-Test**: Commands 0xAA (controller) and 0xAB/0xA9 (port tests) with timeout detection.
*   **Dual Port Support**: Independent enable/disable for keyboard (port 1) and mouse (port 2) with IRQ routing.
*   **Mouse Command Forwarding**: Command 0xD4 for transparent PS/2 mouse communication.
*   **Dual Ring Buffers**: Separate buffers for ASCII characters and raw scancodes enabling both cooked and raw input modes.

### Input & Layouts
*   **Sub-pixel Cursor Management**: Cursor position tracker with fixed-point sensitivity scaling, fractional movement accumulation, and absolute coordinate normalization.
*   **Multilingual Keyboard Layouts**: Support for US QWERTY and Dvorak layouts with an extensible mapping architecture for shift/altgr/caps states.
*   **VMware VMMouse Support**: Direct integration with the VMware hypercall interface for high-precision absolute cursor positioning in VMs.

### Video & Graphics
*   **VirtIO-GPU 2D Acceleration**: Paravirtualized GPU driver supporting 2D scanout, resource-based memory tracking, and accelerated host blitting.
*   **VMware SVGA II Driver**: Cross-architecture driver for VMware/VirtualBox graphics with support for resolution switching, hardware FIFO command rings, 2D acceleration (RectFill/RectCopy), and hardware cursor. Supports both x86_64 (I/O port access) and aarch64 (MMIO access for VMware Fusion on Apple Silicon).
*   **ANSI Terminal Emulation**: Full state-machine parser for ANSI escape sequences (colors, bold, inverse) integrated into the kernel console.
*   **Dual-Mode Framebuffer**: Comptime-generic driver providing both direct-to-VRAM and back-buffered rendering paths to eliminate runtime branches.
*   **PSF Font Support**: Robust loaders for PSF1 and PSF2 bitmap fonts with checked arithmetic for glyph indexing.

### Serial & Async I/O
*   **Interrupt-Driven Serial**: Standard 16550 and PL011 drivers featuring asynchronous, non-blocking transmission via THRE interrupts.
*   **Panic-Safe I/O**: Specialized write paths that bypass spinlocks and async buffers to ensure crash diagnostics are visible during kernel failures.
*   **Unified Async Request Pool**: A system-wide, fixed-size pool of transfer structures for xHCI, AHCI, and Serial to prevent memory exhaustion.

### Virtual File System (VFS)
*   **Longest-Path Mount Resolution**: A central VFS that resolves absolute paths to the most specific mount point available in an 8-slot registry.
*   **Unmount Protection**: Reference counting for open file handles per mount point to prevent use-after-free and filesystem corruption during unmount.
*   **Layered Security Model**: Centralized permission enforcement at the syscall and VFS layers, allowing filesystems to focus on storage-level operations.
*   **TOCTOU Detection**: Metadata structures (`FileMeta`) designed to store device IDs and inode numbers to detect symlink swaps and race conditions.

### Simple File System (SFS)
*   **Sync-over-Async I/O Pattern**: Block-based filesystem designed around the AHCI async I/O model, using `Future` types to bridge async hardware calls with sync-like logic.
*   **Deferred Block Deletion**: Implementation where files are unlinked from the directory immediately, but underlying blocks are only freed after the last open handle is closed.
*   **Superblock Security Hardening**: Strict validation of disk metadata (e.g., bitmap sizes, file counts) to prevent memory exhaustion or out-of-bounds access from malicious disk images.
*   **Batched Bitmap Loading**: Performance optimization that loads all allocation bitmap blocks in a single contiguous async I/O operation.
*   **Write-Through Bitmap Cache**: In-memory caching of allocation state to minimize redundant disk reads while maintaining on-disk consistency via atomic updates.

### Partition Management
*   **Hybrid MBR/GPT Detection**: Automatic scanning of LBA 0 to detect legacy MBR tables or GPT "Protective MBR" headers to switch between parsing logic.
*   **Dynamic DevFS Registration**: Automated discovery and registration of partitions as unique devices (e.g., `/dev/sda1`) using a shared `partition_ops` interface.
*   **Partition Bound Enforcement**: Checked arithmetic on all partition-relative I/O to prevent malicious partition tables from accessing data on other segments of the disk.

### Initial RAM Disk (InitRD)
*   **USTAR TAR Integration**: Native support for the USTAR tar format, allowing the kernel to mount bootloader-provided modules as a read-only root filesystem.
*   **Auto-Variant Resolution**: A search mechanism that automatically checks common path variants (e.g., `name`, `name.elf`, `bin/name`) during a single archive scan.
*   **Security-Hardened Path Normalization**: Rejection of all path traversal attempts (`..`) and strict length-based matching to prevent injection attacks within the InitRD.
*   **Safe Octal Metadata Parsing**: Built-in protection against integer overflows when interpreting octal size, mode, and ownership fields from TAR headers.

This checklist covers the features found in the core kernel logic, memory management, process handling, and syscall infrastructure.

### ACPI & System Discovery
*   **DMAR/VT-d Parser**: Advanced parsing of DMA Remapping tables to discover IOMMU hardware units, including support for RMRR (Reserved Memory) and complex device scopes.
*   **MADT/APIC Topology**: Comprehensive Multiple APIC Description Table parser that identifies Local APICs, I/O APICs, and provides support for x2APIC and ISA interrupt overrides.
*   **MCFG/ECAM Setup**: Robust parsing of PCIe configuration space regions with built-in validation of bus ranges and alignment to prevent firmware-level address calculation errors.
*   **Dual-Version RSDP**: Support for both ACPI 1.0 (RSDT) and ACPI 2.0+ (XSDT) root structures with manual checksum and signature validation.

### Core Kernel & Security
*   **Multi-Backend Console**: Architecture-agnostic logging system supporting multiple simultaneous outputs (Serial UART, Graphical Console, and IPC-based remote logging).
*   **Hardened ELF Loader**: Security-focused loader featuring segment overlap detection, strict size limits (DoS prevention), and mandatory execution-segment validation.
*   **Stack Guard Canaries**: Compiler-integrated stack smashing protection using randomized canaries seeded from hardware RNG or a kernel CSPRNG.
*   **Release-Mode KASLR Masking**: Panic and debug handlers that automatically mask absolute kernel addresses in release builds to prevent KASLR bypass via information leaks.
*   **ChaCha20 CSPRNG**: High-performance cryptographic random number generator (RFC 8439) with entropy pooling and periodic hardware re-seeding.

### Memory Management
*   **Architecture-Aware Kernel Stacks**: Per-thread kernel stacks with architecture-specific sizing (32KB for x86_64, 64KB for AArch64) to compensate for AArch64's 2.25x larger SyscallFrame (288 bytes vs 128 bytes due to 31 GPRs).
*   **Security-Hardened Stack Allocator**: Kernel stack allocator (`kernel_stack.zig`) with comprehensive overflow protection: checked arithmetic on all address calculations, guard page unmap failure detection, stack_region_base kernel space validation, double-free detection with Debug-mode panic, and descriptor field validation on free.
*   **IOMMU Domain Manager**: Infrastructure for per-device DMA isolation using IOVA spaces. Domain allocation and IOVA management implemented; per-device driver integration in progress.
*   **Bitmap PMM with Refcounts**: Physical memory manager using a bit-array for speed and a 16-bit refcount array to support future Copy-on-Write and shared memory features.
*   **Multi-Region ASLR**: Per-process address layout randomization for the stack, heap, PIE base, mmap region, and TLS, providing defense against ROP attacks.
*   **Hierarchical Slab Allocator**: O(1) allocator for small objects (16B-2KB) using bitmapped slabs to eliminate fragmentation and improve cache locality.
*   **Secure Page Freeing**: Physical pages are zeroed via HHDM during deallocation. PTE clearing and TLB shootdown handled by VMM layer.
*   **Multicore TLB Shootdown**: Protocol-based cross-CPU TLB invalidation using IPIs and atomic counters to maintain cache consistency across all cores.
*   **Demand Paging**: Lazy allocation for anonymous memory with zero-fill on page fault, reducing memory pressure for sparse allocations.
*   **VMA Tracking**: Full Virtual Memory Area management with start/end/prot/flags tracking and support for MAP_SHARED, MAP_PRIVATE, MAP_FIXED, MAP_ANONYMOUS, and MAP_DEVICE.

### Process & Threading
*   **Capability-Based Security**: Fine-grained hardware access control (IRQs, I/O ports, MMIO, DMA) assigned to processes by name or manifest rather than broad "root" access.
*   **SMP-Aware Scheduler**: Per-CPU ready queues with work-stealing and LIFO-based cache locality optimization to reduce lock contention.
*   **Futex Subsystem**: Fast userspace locking keyed by physical address with timeout support and page pinning to prevent TOCTOU races during munmap.
*   **Zero-Copy Ring IPC**: SPSC (Single-Producer Single-Consumer) shared-memory ring buffers with built-in futex support for low-latency, high-bandwidth inter-process communication.
*   **Thread-Safe Wait Queues**: Interrupt-safe sleep/wake mechanisms featuring atomic "woken" flags to prevent the "lost wakeup" race condition on SMP systems.
*   **Process Groups & Sessions**: Full POSIX job control with `setpgid`, `getpgid`, `setsid`, `getsid` syscalls and process group leader enforcement.
*   **Resource Limits (rlimit)**: Implementation of 16 Linux RLIMIT types including CPU, FSIZE, DATA, STACK, NOFILE, AS, with configurable soft/hard limits.
*   **CPU Affinity**: Per-thread CPU affinity bitmask allowing processes to be pinned to specific cores for cache optimization.
*   **Clone Flags**: Full Linux clone() semantics with CLONE_THREAD, CLONE_VM, CLONE_SIGHAND, CLONE_PARENT_SETTID, CLONE_CHILD_CLEARTID, and CLONE_SETTLS.
*   **Credential Management**: Complete uid/gid/euid/egid/suid/sgid tracking with 16-element supplementary groups array and credential lock for TOCTOU prevention.
*   **Sorted Sleep List**: Efficient timeout management via wake_time-sorted sleep list with O(1) insertion at correct position.

### I/O & Syscall Infrastructure
*   **Async I/O Reactor**: Central coordinator for all non-blocking operations, featuring a fixed-size request pool to ensure Principle IX (Heap Hygiene) compliance.
*   **Hierarchical Timer Wheel**: A 3-level wheel structure (L0-L2) providing O(1) timer insertion and amortized O(1) expiration for thousands of concurrent timeouts.
*   **io_uring Implementation**: High-performance async interface using shared submission/completion rings (SQ/CQ) with mandatory kernel-side bounce buffers to prevent TOCTOU attacks.
*   **Type-Safe `UserPtr`**: A wrapper that forces developers to validate userspace pointers and handle page faults before any memory dereference occurs.
*   **vDSO Integration**: Mapping of a "Virtual Dynamic Shared Object" into every user process to provide high-speed, syscall-free access to system time and CPU information.
*   **Exclusive Framebuffer Ownership**: Atomic ownership tracking for the system display, allowing only a certified "Display Server" process to map and modify the raw video buffer.

### POSIX I/O Multiplexing
*   **epoll Implementation**: Full Linux epoll API with `epoll_create1`, `epoll_ctl`, `epoll_wait` supporting EPOLLIN, EPOLLOUT, EPOLLERR, EPOLLET (edge-triggered), and EPOLLONESHOT.
*   **select() Support**: Traditional 1024-FD select with read/write/exception sets and microsecond-precision timeouts.
*   **poll() Support**: Per-FD event polling with timeout support for portable I/O multiplexing.
*   **Pipes with Flags**: `pipe` and `pipe2` syscalls with O_CLOEXEC and O_NONBLOCK flag support.
*   **Scatter-Gather I/O**: `writev` and `pread64` syscalls for efficient multi-buffer and positioned I/O operations.
*   **clock_getres()**: Clock resolution query for CLOCK_REALTIME, CLOCK_MONOTONIC, and CLOCK_PROCESS_CPUTIME_ID.

This checklist highlights the unique features and automated capabilities of your Zig-based build system.

### Platform & Firmware Orchestration
*   **Intelligent OVMF Detection**: Automated discovery of UEFI firmware (OVMF/EDK2) paths across macOS (Homebrew/Intel/M1) and multiple Linux distributions (Ubuntu, Debian, Fedora).
*   **Dual-Arch UEFI Target**: Unified build logic for `bootaa64.efi` and `bootx64.efi` using Zig’s native UEFI target support and architecture-specific ABIs (MSVC for x86_64).
*   **Custom Firmware Handoff**: Support for user-provided UEFI code and variable store paths via `-Dbios` and `-Dvars` options for testing custom firmware environments.

### Kernel Hardening & Safety
*   **FPU-Safe Kernel Configuration**: Explicitly disables MMX, SSE, and AVX features for x86_64 kernel code while enabling `soft_float` to prevent implicit FPU register corruption.
*   **Interrupt-Safe Code Model**: Enforces the `kernel` code model and disables the `red_zone` to protect the stack from corruption during asynchronous interrupt handling.
*   **LLVM Backend Enforcement**: Forced use of the LLVM backend as a stability workaround for Zig 0.16 regressions, ensuring reliable higher-half kernel linking via linker scripts.

### Build Orchestration & Modules
*   **Module-Based Dependency Injection**: Extensive use of Zig `Module` system to handle complex dependency graphs and resolve circular dependencies between the HAL, Console, and Scheduler.
*   **Comptime Configuration Injection**: Dynamic generation of a `config` module that injects build-time parameters (heap size, max threads, baud rate) directly into the kernel source.
*   **Architecture-Specific Source Selection**: Compile-time branching for driver selection, automatically wiring the correct UART (PL011 vs. 16550) based on the target architecture.

### Deployment & Tooling
*   **Automated InitRD Packaging**: A built-in orchestration step that automatically gathers all compiled userland ELFs and packages them into a USTAR-formatted `initrd.tar`.
*   **Hybrid GPT/ISO Generation**: Integration with `xorriso` and `mtools` to create "isohybrid" images containing GPT-partitioned FAT32 partitions for maximum hardware compatibility.
*   **Host-Agnostic Disk Tooling**: Compiles and executes a native `disk_image` tool on the host to generate GPT-compliant disk images without external dependency on loopback mounting.

### Emulation & Testing
*   **Multi-Backend QEMU Runner**: Support for diverse display (SDL, GTK, Cocoa, Headless) and audio (CoreAudio, PA, File) backends directly through the `zig build run` command.
*   **Virtualized Hardware Simulation**: Automated QEMU configuration for complex topologies including XHCI controllers, USB hubs, paravirtualized VirtIO-GPUs, and legacy AC97 audio.
*   **Target-Specific Acceleration**: Intelligent selection of QEMU acceleration parameters, utilizing `hvf` for high-performance ARM-on-ARM virtualization on Apple Silicon.
*   **Cross-Arch Build Aliases**: Convenience steps (e.g., `iso-aarch64`, `run-x86_64`) that simplify cross-compilation and testing of the entire stack from a single host.

You can append these sections to your `features.md`. I have organized them into **Core Utility Structures**, updated **System Discovery**, and expanded the **Entropy & Security** sections to reflect the specific implementation details found in your new files.

### Core Utility Structures
*   **Zero-Allocation Intrusive List**: An `IntrusiveDoublyLinkedList` implementation that eliminates external node allocations by embedding pointers directly in structures, critical for high-performance scheduler runqueues.
*   **Double-Remove Protection**: List implementation uses a combination of debug assertions and `std.math.sub` checked arithmetic to trigger an explicit kernel panic on count underflow, preventing use-after-free bugs caused by double-removals.
*   **Comptime Ring Buffer Validation**: A generic circular buffer that enforces power-of-2 capacities at compile-time, allowing the use of bitwise `& MASK` instead of expensive modulo operations for wraparound.
*   **Anti-Leak Ring Semantics**: Security-hardened `pop()` and `clear()` operations that perform mandatory `@memset` zeroing on consumed or cleared slots to prevent sensitive data (like keyboard scancodes) from lingering in memory.

### System Discovery (AArch64 focus)
*   **Hardened DTB Parser**: A minimalist Device Tree Blob parser designed with a "security-first" approach, including a 64MB `MAX_DTB_SIZE` limit to prevent Denial-of-Service (DoS) attacks via malicious `totalsize` claims.
*   **Bounded DTB Scanning**: Implementation of strictly bounded node-name scanning (256-byte limit) and property-offset validation to prevent out-of-bounds reads when parsing malformed firmware blobs.
*   **Checked Address Calculation**: Utilization of Zig’s `std.math` checked arithmetic when calculating `address_cells` and `size_cells` to prevent integer overflows during GIC (Generic Interrupt Controller) base address discovery.

### Entropy & Security (Updated)
*   **Fail-Secure Entropy Policy**: A `require_hardware_entropy` build-time toggle that forces a kernel panic during boot if high-quality hardware RNG (RDRAND/RDSEED) is unavailable, ensuring the system never runs in a compromised state.
*   **Multi-Source Fallback Mixing**: A sophisticated fallback seeder that combines TSC (Time Stamp Counter) variance, stack-address jitter, and MurmurHash3 (MurmurHash3_fmix64) to generate the best possible seed on legacy hardware.
*   **Xoroshiro128+ PRNG**: Implementation of the `xoroshiro128+` algorithm for fast, non-cryptographic kernel randomization (stack canaries, ASLR), protected by a global spinlock for SMP safety.
*   **Tiered Security Monitoring**: A `SecurityLevel` API (Secure/Degraded/Critical) that allows the kernel to monitor entropy quality and log high-visibility warnings if the system is operating with predictable random values.
*   **Atomic PRNG State Guarding**: Use of atomic booleans with `Acquire/Release` memory ordering to track PRNG initialization, preventing TOCTOU (Time-of-Check to Time-of-Use) races during early multicore boot.
*   **Direct Hardware Entropy Bypass**: Dedicated paths (`fillFromHardwareEntropy`) that bypass the PRNG to provide raw, hardware-grade entropy directly to sensitive syscalls like `sys_getrandom`.

### Data Integrity & Safety
*   **Panic-on-Corruption**: Widespread use of `@panic` in release builds for low-level data structure corruption (e.g., list count underflow), choosing system halt over continued execution with compromised internal state.
*   **Memory-Safe Pointer Arithmetic**: Use of bounded slices (`ptr[start..end]`) instead of raw pointer arithmetic throughout the DTB and Ring Buffer implementations to leverage Zig's safety checks.
*   **Explicit Zeroing of Sensitive Slots**: Standardized pattern of zeroing memory immediately after use in I/O buffers to minimize the "blast radius" of potential kernel heap leaks.

This checklist highlights the unique architectural design, protocol compliance, and security-hardened features of your Zig network stack.

### Network Core & Memory Management
*   **Zero-Copy Packet Buffer**: The `PacketBuffer` utilizes layer-specific offsets (`eth_offset`, `ip_offset`, etc.) to process data across the stack without redundant memory copies.
*   **Shared Memory Budgeting**: A centralized `pool.zig` manages TX buffers and reassembly allocations under a single system-wide memory budget to prevent network-driven heap exhaustion.
*   **Safe Header Accessors**: Use of bounds-checked accessor functions (e.g., `getIpv4Header`) that return optional pointers, preventing out-of-bounds access on malformed frames even in `ReleaseFast` builds.
*   **Incremental Checksum Updates**: Implementation of RFC 1624 for efficient header updates (like TTL decrements) without recalculating the entire ones' complement sum.

### Layer 2 - Ethernet & ARP
*   **RFC 894 Padding Security**: Outgoing short frames are padded to the 60-byte minimum with explicit zero-initialization to prevent leaking stale kernel stack data.
*   **Anti-Spoofing ARP Cache**: The ARP subsystem includes conflict detection that identifies MAC address swaps for the same IP, utilizing exponential backoff and entry blocking to mitigate MITM attacks.
*   **O(1) MAC Lookup**: A dedicated ARP hash table allows constant-time resolution of IP-to-MAC mappings, supplemented by a doubly-linked LRU eviction strategy for cache aging.
*   **Static ARP Binding**: Support for administrative static entries that are protected from being overwritten by unsolicited ARP replies.

### Layer 3 - IPv4 & ICMP
*   **Hardened IP Reassembly**: A "hole-tracking" reassembly engine that enforces a 64-fragment limit and rejects overlapping fragments (RFC 5722) to defend against "Teardrop" and "Ping of Death" attacks.
*   **Security-Conscious Option Filtering**: Automatic rejection of dangerous IPv4 options like Loose/Strict Source Routing (LSRR/SSRR) and Record Route (RR) at the validation layer.
*   **Tick-Based PMTU Discovery**: Path MTU Discovery (RFC 1191) uses a monotonic tick-based rate limiter rather than an operation-counter, preventing attackers from flooding ICMP messages to bypass rate limits.
*   **ICMP Smurf Prevention**: Explicit checks to ensure the kernel never replies to ICMP Echo Requests sent to broadcast/multicast addresses or originating from a multicast source.
*   **RFC 5927 ICMP Validation**: ICMP errors (like Fragmentation Needed) are validated against active TCP/UDP flows using 4-tuple and sequence number checks before updating the PMTU cache.
*   **Raw ICMP Sockets**: Support for `SOCK_RAW` with `IPPROTO_ICMP` enabling userspace ping utilities. Echo replies are delivered to matching raw sockets with source IP address metadata.

### Layer 4 - TCP & UDP
*   **Cryptographically Secure ISNs**: Initial Sequence Numbers (ISNs) are generated using SipHash-2-4 seeded with hardware entropy (RFC 6528), with periodic key re-seeding to prevent sequence prediction attacks.
*   **O(1) SYN Flood Mitigation**: A dedicated "half-open" intrusive list allows the kernel to evict the oldest pending connection in constant time when the `MAX_HALF_OPEN` limit is reached.
*   **High-Performance Extensions**: Support for RFC 7323 (Window Scaling and Timestamps) and RFC 2018 (Selective Acknowledgments - SACK) to optimize throughput on high-latency links.
*   **Jacobson/Karels RTT Estimation**: Per-connection Smoothed Round-Trip Time (SRTT) and RTT Variation (RTTVAR) tracking with exponential backoff for retransmission timeouts.
*   **Mandatory UDP Checksums**: Enforcement of non-zero UDP checksums for security-sensitive ports (DNS, NTP, SNMP) to prevent cache poisoning and spoofing, while allowing zero-checksums for general traffic.

### Sockets & Async I/O
*   **RFC 6056 Port Randomization**: Ephemeral port allocation implements "Random Port Randomization" (Algorithm 3) to provide ~32 bits of total entropy when combined with DNS transaction IDs.
*   **Two-Phase Socket Deletion**: Lifetime management using `AtomicRefcount` and a "closing" flag to prevent use-after-free races during concurrent packet processing and socket teardown.
*   **Async I/O Reactor Integration**: A Phase 2 API that supports `acceptAsync`, `recvAsync`, and `sendAsync`. Async recv uses kernel bounce buffers - IRQ context copies data to kernel memory, then `finalizeBounceBuffer()` safely copies to userspace in syscall context via `UserPtr`, preventing SMAP violations and TOCTOU attacks.
*   **SO_REUSEADDR Support**: POSIX-compliant address reuse semantics allowing server restart without TIME_WAIT delays. Both sockets must set SO_REUSEADDR; TIME_WAIT connections always allow reuse; two LISTEN sockets on the same port are still prevented.
*   **Tick-Based Timeouts**: Socket operations use a hierarchical timer wheel with 1ms granularity for timeout management.

### DNS Client
*   **Zero-Allocation Resolver**: The hostname resolver uses stack-allocated buffers and a case-insensitive `dnsNameEql` helper to perform hostname resolution without heap pressure.
*   **Recursion & CNAME Following**: Robust CNAME chain resolution with a mandatory depth limit (8) and protection against malicious pointer loops in compressed DNS names.
*   **Deadline-Hardened Query Loop**: The resolver loop enforces a total wall-clock deadline and a max-packet-count limit to prevent DoS from spoofed UDP responses.
*   **RFC 5452 Security**: Randomized source port allocation for query ID entropy amplification.
*   **Multiple Record Types**: Support for A (IPv4), AAAA (IPv6), CNAME, NS, SOA, PTR, MX, and TXT record parsing.

### Network Interfaces
*   **Loopback Interface**: Virtual network interface for 127.x.x.x traffic with synchronous packet re-injection into IPv4 stack.
*   **Multicast Support**: Software-based multicast MAC address filtering with optional driver-specific hardware filter programming and accept-all-multicast mode.
*   **Interface Abstraction**: Unified `NetworkInterface` structure with driver-specific callbacks for send, receive, and configuration.

### Synchronization & Safety
*   **IRQ-Safe "Held" Token Pattern**: A custom `IrqLock` and `Spinlock` architecture that uses a `Held` token to ensure interrupts are always restored to their previous state and locks are never left dangling.
*   **Generation Counter Guarding**: Use of monotonic generation counters on TCBs and ARP entries to detect object reuse, preventing stale pointers from being used after a connection has been recycled.
*   **Comptime ABI Verification**: Extensive use of `extern struct` with `comptime` size assertions to ensure network headers exactly match wire specifications and are safe for unaligned access.

### Network Configuration Daemon (netcfgd)
*   **DHCPv4 Client (RFC 2131/2132/5227)**: Full DORA (Discover-Offer-Request-Acknowledge) state machine with exponential backoff (4s-64s) and jitter. Includes ARP probe/announce for conflict detection (RFC 5227), DHCPDECLINE on conflict, DHCPRELEASE on shutdown, T1/T2 renewal timers defaulting to 0.5/0.875 of lease time.
*   **DHCPv6 Client (RFC 8415)**: Complete stateful DHCPv6 implementation with SOLICIT/ADVERTISE/REQUEST/REPLY message handling, Rapid Commit optimization for 2-message exchange, IA_NA (Identity Association for Non-temporary Addresses), DUID-LL generation from MAC, T1/T2 renewal with default calculations, and multicast to ff02::1:2.
*   **SLAAC (RFC 4862)**: Stateless Address Autoconfiguration from Router Advertisements with Modified EUI-64 interface identifier generation, M/O/A flag detection, global address configuration, and timestamp-based RA deduplication.
*   **Security-Hardened Transaction IDs**: Both DHCPv4 (32-bit) and DHCPv6 (24-bit) use CSPRNG for transaction ID generation to prevent spoofing attacks. Server ID and MAC address validation on responses.
*   **Zero-Initialized Packets**: All outbound packets zero-initialized to prevent kernel memory leaks; partial reads from recvfrom leave zeros (treated as PAD) in unwritten bytes.
*   **Initial Delay (Thundering Herd Prevention)**: DHCPv4 implements RFC 2131 Section 4.4.1 random delay (1-10 seconds) on startup to prevent synchronized lease requests after power outage recovery.

This checklist highlights the unique implementation details, Linux ABI compatibility, and security-hardened features found in your Userland API (UAPI) and System Interface layers.

### ABI Stability & Verification
*   **Comptime ABI Assertions**: Extensive use of Zig’s `comptime` to verify that userland-visible structures (`Timespec`, `SockAddrIn`, `MsgHdr`) exactly match the Linux x86_64 ABI layout, preventing ABI drift at compile-time.
*   **Struct Padding Validation**: Explicit security audits of `Stat` and `Statfs` structures to ensure all reserved fields and internal padding are zero-initialized, preventing kernel-to-user information leaks.
*   **Type-Safe Errno Mapping**: A robust `SyscallError` set that uses Zig’s error union pattern to automatically map kernel errors to their standard negative Linux `errno` counterparts (e.g., `error.EBADF` → `-9`).
*   **Zero-Length Array Protection**: The `Dirent64` implementation includes documented safety rules for the `d_name` flexible array member, ensuring the struct header and name data are handled separately to prevent stack memory corruption.

### Zero-Copy IPC & Ring Buffers
*   **Cache-Line Separation**: The `RingHeader` for shared-memory IPC is designed with 128-byte alignment/padding between producer and consumer indices to prevent "false sharing" and optimize cache performance on multicore systems.
*   **SPSC-to-MPSC Semantics**: Implementation of Single-Producer Single-Consumer (SPSC) rings that can be decomposed and managed by the kernel to provide Multi-Producer (MPSC) semantics for high-performance service communication.
*   **Atomic Refcounted Sockets**: Lifetime management using `AtomicRefcount` combined with an atomic `closing` flag to prevent TOCTOU (Time-of-Check to Time-of-Use) races during concurrent socket teardown.
*   **Futex-Backed Ring Synchronization**: Ring buffer structures include built-in `futex_offset` metadata, allowing userspace producers and consumers to block efficiently using the kernel’s futex subsystem.

### System Extensions (Zscapek-Specific)
*   **Unified Input Event ABI**: A custom `InputEvent` format that provides a stable interface for relative movement, absolute positioning, and button states, including nanosecond-precision timestamps since boot.
*   **Hardware Access Syscalls**: Special "microkernel-style" extensions (1000+ series) that allow authorized userspace drivers to perform PCI enumeration, I/O port access (`INB`/`OUTB`), and DMA allocation.
*   **Named Service Registry**: A built-in service discovery mechanism (`SYS_REGISTER_SERVICE` / `SYS_LOOKUP_SERVICE`) allowing processes to register as named providers (e.g., "netstack") and resolve peer PIDs for IPC.
*   **Direct Framebuffer Mapping**: Dedicated syscalls for acquiring display metadata and mapping the raw video buffer directly into a process's address space for high-performance graphics servers.

### I/O & Event Management
*   **io_uring Compatibility**: Implementation of `IoUringSqe` and `IoUringCqe` structures matching the Linux 6.x+ ABI, supporting asynchronous submission and completion queues for high-throughput I/O.
*   **Poll-to-Epoll Conversion Safety**: Specialized helpers that convert 32-bit `epoll` events to 16-bit `poll` events, with mandatory checks to prevent silent truncation of high-bit flags (like `EPOLLET` or `EPOLLONESHOT`).
*   **Packed Epoll Events**: Use of byte-array backings and `align(1)` pointers within the `EpollEvent` struct to strictly match the 12-byte packed layout required by the Linux x86_64 ABI.
*   **OSS Sound Compatibility**: Definition of standard Open Sound System (OSS) constants (`SNDCTL_DSP_SPEED`, etc.) to support legacy applications like Doom via a `/dev/dsp` emulation layer.

### Process & Signal Management
*   **Standardized Context Tracking**: Full `UContext` and `MContext` structures that capture the complete machine state (registers, segments, signal masks), enabling userspace signal handling and cooperative multitasking.
*   **Signal Set Helper API**: A bitmask-based `SigSet` implementation (64-bit) with helper functions (`sigaddset`, `sigismember`) for efficient signal mask manipulation within the kernel and userland.
*   **Clone Logic Consistency**: Support for standard Linux `CLONE_*` flags, enabling shared virtual memory, file descriptor tables, and thread-group semantics during process creation.
*   **Overflow-Safe Time Conversion**: The `TimeVal` and `Timespec` structures include saturating arithmetic helpers to convert between seconds and milliseconds without risking integer overflow on large values.

This bullet checklist highlights the features of the **Userspace Environment**, **Libc Implementation**, and **Hardware Drivers**, focusing on the unique design patterns and security-focused implementations in your Zig-based userspace.

### Userspace Drivers & Capability Access
*   **Pure Userspace VirtIO Drivers**: Implementation of high-performance VirtIO-Net and VirtIO-Blk drivers entirely in userspace, utilizing capability-based syscalls for MMIO mapping (`SYS_MMAP_PHYS`) and DMA allocation (`SYS_ALLOC_DMA`).
*   **Zero-Copy Ring-Buffer IPC**: A high-level `Ring` library providing zero-copy packet and data transfers between drivers and the netstack, featuring cache-line separation (128-byte alignment) to prevent "false sharing" and optimize multicore performance.
*   **Parallel Driver Architecture**: The VirtIO-Net driver utilizes a multi-process model (via `fork`) to separate RX and TX handling into independent execution contexts, maximizing throughput on full-duplex links.
*   **MPSC Service Pattern**: A Multi-Producer Single-Consumer (MPSC) registry allowing multiple hardware drivers to attach their own rings to a single "Netstack" consumer for centralized packet processing.

### Security-Hardened Libc (Zig Implementation)
*   **Recursion-Safe Memory Ops**: Internal `safeCopy` and `safeFill` functions that avoid Zig's `@memcpy` and `@memset` builtins, preventing infinite recursion in freestanding mode where the compiler might otherwise lower those builtins to the very libc functions they implement.
*   **Overflow-Protected Allocator**: A standard `malloc` implementation featuring mandatory `checkedMultiply` and `checkedAdd` operations on all size calculations to prevent integer wrap-around exploits.
*   **Heap Corruption Detection**: Integrated "Magic Number" tracking (`0xDEADBEEF` / `0xFEEDFACE`) in allocation headers to identify heap corruption and double-free attempts in debug builds.
*   **Safer String Alternatives**: Native implementations of `strlcpy` and `strlcat` provided alongside standard (unsafe) C string functions to encourage truncation-aware string handling.
*   **Thread-Local PRNG State**: A `rand()` implementation using `threadlocal` storage to ensure independent, race-free PRNG state for every userspace thread without requiring global locks.

### Libc Standard Functions
*   **Character Classification (ctype.h)**: Full suite including `isspace`, `isdigit`, `isalpha`, `isalnum`, `isupper`, `islower`, `isprint`, `isxdigit`, `iscntrl`, `isgraph`, `ispunct`, `isblank`, `toupper`, `tolower`.
*   **String Search Functions**: `strchr`, `strrchr`, `strstr` (with bounds checking), `strpbrk`, `strspn`, `strcspn`, `memrchr`.
*   **String Tokenization**: `strtok`, `strtok_r`, `strsep` for string parsing.
*   **Case-Insensitive Comparison**: `strcasecmp`, `strncasecmp` for portable string matching.
*   **Error String Mapping**: `strerror`, `strerror_r` with mapped errno values.
*   **Math Utilities**: `abs`, `labs`, `llabs` (with INT_MIN overflow handling), `div`, `ldiv`, `lldiv` for quotient/remainder.
*   **Floating Point Conversion**: `atof`, `strtod`, `strtof` for string-to-float parsing.
*   **Sorting & Searching**: `qsort`, `bsearch`, `lfind` for array manipulation.
*   **setjmp/longjmp**: Full implementation saving RBX, RBP, R12-R15, RSP, RIP with architecture-specific assembly for x86_64 and AArch64.
*   **Signal Handling (stubs)**: `signal`, `raise` with SA_RESTART and SA_RESETHAND flags, SIG_DFL, SIG_IGN, SIG_ERR constants.

### Advanced Async I/O (io_uring)
*   **Linux-Compatible io_uring Wrapper**: A high-level `IoUring` Zig structure that provides a type-safe interface for submission and completion queues, matching the standard Linux x86_64 ABI.
*   **Kernel-Level Blocking**: Unlike spin-polling implementations, the `IoUring` library uses `io_uring_enter` with the `IORING_ENTER_GETEVENTS` flag to properly park userspace threads in the kernel until I/O completion.
*   **Atomic SQE Population**: A callback-based `getSqeAtomicFn` pattern ensures that submission queue entries are fully initialized and committed before being visible to the kernel reactor.

### Cross-Architecture Runtime (CRT0)
*   **Manual Varargs Abstraction**: A sophisticated `VaList` implementation that manually navigates the ARM 64-bit Procedure Call Standard (AAPCS64) and x86_64 System V ABI, bypassing LLVM's current `@cVaArg` limitations on AArch64.
*   **TLS & FS_BASE Initialization**: The `crt0` (assembly and Zig) handles early Thread-Local Storage initialization, automatically configuring the `FS` register via `ARCH_SET_FS` for architectural thread-local support.
*   **Null-Pointer Guarded Linker Script**: A custom linker script that starts the `USER_BASE` at 4MB, ensuring that the first 4MB of virtual memory remain unmapped to catch null-pointer dereferences as hardware faults.

### Userspace Applications
*   **HTTP Server (httpd)**: Async HTTP/1.1 server using io_uring with support for 32 concurrent clients, fallback poll mode, and proper connection lifecycle management.
*   **Interactive Shell**: Basic command-line shell with readline support (backspace handling), ANSI escape sequences, and built-in commands (help, exit, clear).
*   **Network Stack Daemon (netstack)**: Userspace packet routing service receiving packets via shared memory rings from driver processes with 1MB fixed-size heap allocator.
*   **Doom Port**: Complete port of the classic Doom engine with keyboard/mouse input, software rendering, and audio effects via OSS-compatible interface.
*   **Test Utilities**: Audio device testing (OSS), multi-format sound tests (S16 stereo, U8 mono), assembly tests, and libc correctness verification.

### Audio & Graphics Support
*   **Software Audio Mixer**: An AC97/OSS-compatible sound backend for Doom (`i_sound.zig`) that performs real-time linear interpolation, stereo separation, and frequency scaling in software.
*   **LRU Sound Cache**: A sound effect caching system using a doubly-linked Least Recently Used (LRU) eviction strategy and a dedicated 64MB memory budget to manage digital audio lumps.
*   **Dynamic Framebuffer Centering**: The `doomgeneric` platform layer automatically detects hardware resolution and applies centered blitting with on-the-fly BPP (Bits Per Pixel) conversion and VirtIO-GPU flushing.

### System Utilities
*   **Deadline-Aware IPC**: The `Ring.wait` implementation uses nanosecond-precision TSC deadlines to bound wait times, preventing process starvation during high-contention IPC scenarios.
*   **Standardized Error Mapping**: An internal `setErrno` utility that bridges Zig's error-set paradigm with the POSIX `errno` convention, ensuring consistent error reporting across the entire library stack.
*   **Checked Clock Wrappers**: Saturating arithmetic and overflow-checked multipliers in `gettime_ms` to ensure that malformed kernel timespecs cannot cause userspace crashes or logic loops.

### Current Limitations & Development Stubs

The following features are intentionally incomplete or stubbed for the MVP release:

#### Libc Surface (Doom Port Compatibility)
*   **Environment Variables**: `getenv`, `setenv`, `unsetenv`, `putenv` return `ENOSYS` - no environment block support.
*   **Filesystem Ops**: `mkdir`, `rmdir`, `chdir`, `getcwd` return `ENOSYS` - InitRD is read-only.
*   **Stdio Input**: `scanf`, `fscanf` return 0 - no input parsing implemented.
*   **Security Stubs**: `gets()` intentionally disabled (returns null with `ENOSYS`) per C11 removal.
*   **Process Control**: `system()` returns -1 - no userspace shell available.
*   **Dynamic Allocation**: `vasprintf` stubbed - requires allocator integration.

#### Networking
*   **DNS Buffer Size**: Hardcoded 512-byte UDP buffer (RFC 1035). EDNS0 large responses not supported.
*   **PMTU Cache Expiration**: LRU cache with tick-based rate limiting but no background expiration timer.
*   **Loopback Interface**: Synchronous processing only - protocol handlers must copy data before returning.

#### Drivers & Hardware
*   **Audio/Music**: Doom sound effects and music playback fully implemented with OPL3 FM synthesis.
*   **VirtIO-Blk IPC**: Message buffers support up to 32 sectors (16KB) per message with automatic chunking for larger requests up to 256 sectors (128KB).
*   **VirtIO-Net Features**: `VIRTIO_NET_F_MRG_RXBUF` and `EVENT_IDX` defined but not negotiated.

#### Signals & Context
*   **sigsetjmp**: Now properly saves/restores signal mask (implemented 2025-12-30).
*   **FPU/SSE/AVX State**: Full XSAVE support with dynamic sizing (implemented 2025-12-30). Thread FPU buffers are allocated based on CPU capabilities (512 bytes for FXSAVE, up to 2688+ bytes for AVX-512). Signal delivery and return properly save/restore dynamic-sized FPU state with 64-byte alignment.

---

## Roadmap: Missing Features & Security Improvements

This section documents known gaps, incomplete implementations, and security concerns identified during code audit. Items are prioritized by security impact.

### Priority 1: Security-Critical

#### Register Sanitization on Syscall Return
- **Status**: IMPLEMENTED (2025-12-30)
- **Description**: The SYSRET path in `src/arch/x86_64/lib/asm_helpers.S` now zeros caller-saved registers (RDX, RSI, RDI, R8, R9, R10) before returning to userspace. RAX is preserved (syscall return value), RCX/R11 are overwritten by SYSRET instruction, and RBX/RBP/R12-R15 are callee-saved and restored from the user's saved frame.
- **Files**: `src/arch/x86_64/lib/asm_helpers.S`

#### NMI Handler GS Base Gap
- **Status**: IMPLEMENTED (2025-12-30)
- **Description**: The `isr_stub_paranoid` entry in `asm_helpers.S` correctly handles NMI, MCE, Debug, and Double Fault by reading `MSR_GS_BASE` to determine if SWAPGS is needed. This prevents kernel crash if NMI fires during the SYSCALL/SYSRET gap. The paranoid code checks if GS_BASE is a kernel address (negative/high bit set) and only performs SWAPGS when needed.
- **Remaining**: NMI and MCE should use dedicated IST stacks (IST2/IST3) for additional safety against stack corruption.
- **Files**: `src/arch/x86_64/lib/asm_helpers.S`

### Priority 2: Correctness & Robustness

#### IST Stack Allocation for Critical Exceptions
- **Status**: COMPLETE (2026-01-15)
- **Description**: IST stacks are fully configured for all critical exceptions that can occur during the SYSCALL/SYSRET gap or when the kernel stack may be corrupted:
  - **IST1 (Double Fault)**: Per-CPU 4KB stacks in `double_fault_stacks`. IDT entry 8 uses `interruptWithIst(handler, 0, 1)`.
  - **IST2 (NMI)**: Per-CPU 4KB stacks in `nmi_stacks`. IDT entry 2 uses `interruptWithIst(handler, 0, 2)`. NMI can occur at any time including during SYSCALL/SYSRET gap.
  - **IST3 (MCE)**: Per-CPU 4KB stacks in `mce_stacks`. IDT entry 18 uses `interruptWithIst(handler, 0, 3)`. MCE indicates hardware failure requiring dedicated stack for diagnostics.
- **Security**: All IST stacks are zero-initialized to prevent information disclosure. The `isr_paranoid` assembly handler reads `MSR_GS_BASE` to determine if SWAPGS is needed, correctly handling the kernel-mode SYSCALL/SYSRET gap where GS base may be in user or kernel state.
- **Files**: `src/arch/x86_64/kernel/gdt.zig`, `src/arch/x86_64/kernel/idt.zig`, `src/arch/x86_64/lib/asm_helpers.S`

#### IOMMU Per-Device Integration
- **Status**: COMPLETE (2026-01-07)
- **Description**: IOMMU domain manager with bitmap-based IOVA allocator (64KB granularity). Drivers (xHCI, AHCI, E1000e) properly use `dma.allocBuffer(bdf, size, writable)` which integrates with IOMMU when enabled. The DMA subsystem transparently returns IOVA addresses for hardware and physical addresses for CPU access. DMAR parsing extracts RMRR regions.
- **Hardening (Implemented 2026-01-07)**:
  1. IOTLB invalidation after `mapRange()` calls - already correct in `allocateAndMap()`
  2. RMRR overlap validation - `allocateAndMap()` now rejects physical buffers overlapping firmware-reserved RMRR regions
  3. IOTLB invalidation error handling - `unmapIova()` now returns `UnmapError` on failure; callers leak physical memory rather than risk use-after-free via stale TLB entries
- **Files**: `src/kernel/mm/iommu/domain.zig`, `src/kernel/mm/dma.zig`, `src/arch/x86_64/mm/iommu/vtd.zig`

#### Secure Page Free Ordering
- **Status**: IMPLEMENTED (2026-01-07)
- **Description**: All user page free paths now enforce correct ordering: zero via HHDM -> memory barrier (`std.atomic.fence(.seq_cst)`) -> clear PTE -> TLB shootdown -> return to PMM. This prevents TLB race information leakage where a page could be reallocated before all CPUs process the TLB shootdown IPI. Fixed in `freeVmaPages()` (munmap, process exit) and `shrinkHeap()` (brk shrink).
- **Files**: `src/kernel/mm/user_vmm.zig`

### Priority 3: Feature Completeness

#### Signal Mask in sigsetjmp/siglongjmp
- **Status**: IMPLEMENTED (2025-12-30)
- **Description**: `sigsetjmp` now properly saves the signal mask when `savemask` is nonzero, using `rt_sigprocmask` syscall (14) to query the current mask. `siglongjmp` restores the mask using `SIG_SETMASK` before jumping. The `sigjmp_buf` is 80 bytes (10 x u64) to accommodate the flag and mask.
- **Files**: `src/user/lib/libc/setjmp.S`, `src/user/doom/include/setjmp.h`

#### FPU/SSE/AVX State in Signal Delivery
- **Status**: IMPLEMENTED (2025-12-30)
- **Description**: Full XSAVE support with dynamic FPU state sizing. The HAL detects CPU capabilities and enables XSAVE/XRSTOR for AVX support with automatic FXSAVE/FXRSTOR fallback. Thread creation dynamically allocates 64-byte aligned FPU buffers based on `fpu.getXsaveAreaSize()`. Signal delivery saves FPU state to user stack with dynamic sizing and proper alignment. Signal return restores FPU state using `copyToKernel` and `fpu.restoreState()`. Context switching uses `fpu.saveState()`/`fpu.restoreState()` wrappers that automatically select XSAVE or FXSAVE.
- **Files**: `src/kernel/proc/thread.zig`, `src/kernel/proc/signal.zig`, `src/kernel/sys/syscall/process/signals.zig`, `src/kernel/proc/sched/scheduler.zig`, `src/kernel/proc/sched/thread.zig`, `src/arch/x86_64/kernel/fpu.zig`

#### Music Playback
- **Status**: IMPLEMENTED (2026-01-07)
- **Description**: Full OPL3 FM synthesis for Doom music playback. Features include: MUS-to-MIDI conversion via `mus2mid`, MIDI sequencer with tick-based timing, OPL3 emulator with 18 2-operator voices, ADSR envelope generators, 8 waveform types, GENMIDI instrument bank loading from WAD, and integration with the audio mixer.
- **Files**: `src/user/doom/i_sound.zig`, `src/user/doom/opl3.zig`, `src/user/doom/midi.zig`, `src/user/doom/midi_parser.zig`, `src/user/doom/sequencer.zig`, `src/user/doom/genmidi.zig`

#### VirtIO-Blk Large Requests
- **Status**: IMPROVED (2026-01-16)
- **Description**: IPC message buffers now support up to 32 sectors (16KB) per message, an 8x improvement from the original 4 sectors (2KB). Requests up to 256 sectors (128KB) are automatically chunked by the driver using a multi-message protocol with `more_chunks` continuation flag.
- **Implementation**:
  - `MAX_SECTORS_PER_MESSAGE = 32` for inline data in IPC messages
  - `MAX_SECTORS_PER_REQUEST = 256` total sectors with automatic chunking
  - Static buffers for IPC messages to avoid stack overflow
  - `BlockResponse.more_chunks` field for chunked read continuation
  - Bounds checking includes full request range validation
- **Files**: `src/user/drivers/virtio_blk/main.zig`

### Audit Notes

This roadmap was generated from a comprehensive feature validation on 2024-12-30, with additional feature discovery on 2025-12-30. The validation compared all claims in this document against actual implementation.

**Discovered During Audit (added to documentation):**
- RTC driver with alarm/periodic interrupts
- Intel HDA audio controller driver
- PS/2 controller abstraction
- PC speaker tone generation
- USB Mass Storage Class (MSC)
- Process groups, sessions, rlimit
- epoll, select, poll implementations
- Demand paging and VMA tracking
- HTTP server, shell, netstack daemon
- Full libc ctype, string, and math functions

**Implemented 2025-12-30:**
- Register sanitization on SYSRET (zero caller-saved registers)
- IOVA bitmap allocator with proper free support
- sigsetjmp/siglongjmp signal mask save/restore
- XSAVE/XRSTOR support with dynamic FPU state sizing
- Dynamic thread FPU buffer allocation (64-byte aligned)
- Signal delivery/return with dynamic FPU frame sizes
- Paranoid ISR stubs for NMI/MCE/DF/DB with correct GS base handling (discovered - was already implemented)
- All critical exception IST stacks per-CPU (discovered - was already implemented):
  - IST1 for Double Fault (vector 8)
  - IST2 for NMI (vector 2)
  - IST3 for MCE (vector 18)

**Implemented 2026-01-02:**
- VMware SVGA II aarch64 support via MMIO register access (VMware Fusion on Apple Silicon)
- Architecture-independent register access abstraction (`src/drivers/video/svga/regs.zig`)
- Portable memory barriers (`mfence` on x86_64, `dmb sy` on aarch64)
- Portable CPU pause hints (`pause` on x86_64, `yield` on aarch64)
- VMware hypercall interface for aarch64 using `mrs xzr, mdccsr_el0` trap

**Implemented 2026-01-05:**
- **NVMe Driver**: Full NVMe 1.4+ driver (`src/drivers/storage/nvme/`)
  - Admin Queue and I/O Queue pairs with phase bit completion detection
  - Identify Controller/Namespace parsing with comptime 4096-byte size assertions
  - PRP-based DMA transfers with automatic PRP list allocation
  - MSI-X interrupt support with HAL vector allocation
  - Async I/O reactor integration via IoRequest/Future patterns
  - Namespace discovery and per-namespace LBA/capacity tracking
  - Controller reset sequence with CC.EN/CSTS.RDY handling
- PCI ECAM enumeration bug fix: Virtual address misalignment caused all PCI devices to return identical data
- Added `mapMmioExplicitAligned()` to VMM for hardware requiring specific virtual address alignment
- ECAM now uses 1MB-aligned virtual mapping to enable correct bitwise OR address calculations
- `PageFlags.MMIO` updated to include `write_through = true` on both x86_64 and aarch64 for strict MMIO semantics
- **kvmclock Paravirtualized Clock (x86_64)**: KVM paravirtualized timekeeping (`src/arch/x86_64/hypervisor/kvmclock.zig`)
  - MSR_KVM_WALL_CLOCK_NEW and MSR_KVM_SYSTEM_TIME_NEW support
  - Per-vCPU time info structures with seqlock synchronization
  - Automatic detection via CPUID leaf 0x40000001 feature bit
  - SMP support with per-AP MSR registration
  - Integration with timing.zig (initBest() prefers kvmclock over PIT calibration)
  - VDSO integration for userspace time access
- **pvtime Paravirtualized Time (aarch64)**: ARM KVM stolen time tracking (`src/arch/aarch64/hypervisor/pvtime.zig`)
  - SMCCC hypercalls (HV_PV_TIME_ST: 0xC6000021, HV_PV_TIME_FEATURES: 0xC6000020)
  - Per-vCPU stolen time structure (16 bytes) with seqlock synchronization
  - Automatic KVM detection via hypervisor probing
  - Integration with timing.zig (initBest() enables pvtime under KVM)
  - Stolen time tracking for accurate CPU accounting under VM preemption

**Implemented 2026-01-12/13:**
- **Kernel Stack Security Hardening** (`src/kernel/mm/kernel_stack.zig`):
  - Architecture-aware stack sizing: AArch64 gets 64KB (16 pages) vs x86_64's 32KB (8 pages) to compensate for larger SyscallFrame
  - Checked arithmetic on all address calculations using `std.math.add/mul` to prevent integer overflow
  - Guard page unmap failure now returns error instead of silently continuing (prevents guard bypass)
  - stack_region_base validation: must be in kernel space and not overflow address space
  - Descriptor validation in free(): verifies stack_base matches expected address for slot
  - Initialization race fix: moved `initialized` check inside spinlock
  - Bitmap bounds assertions with `std.debug.assert`
  - Changed `@intCast` to `@truncate` for bit index calculation
  - Comptime validation of constants for overflow safety
  - Added MEMORY.md documentation
- **ASLR Fail-Secure Entropy Enforcement** (`src/kernel/core/random.zig`, `src/kernel/mm/aslr.zig`):
  - Added `isEntropyWeak()` API to random module tracking whether CSPRNG was seeded with hardware entropy
  - ASLR now returns `WeakEntropy` error if only timing-based entropy available at init
  - Prevents spawning processes with predictable memory layouts under degraded security
- **DMA Allocator Robustness** (`src/kernel/mm/dma_allocator.zig`):
  - Added `initTracking()` for early initialization during kernel boot
  - `getTracking()` now returns optional, handling allocation failure gracefully
- **User VMM Underflow Protection** (`src/kernel/mm/user_vmm.zig`):
  - Added `subTotalMapped()` helper with saturating arithmetic to prevent underflow
- **Libc Security Hardening** (`src/user/lib/libc/`):
  - Zero-initialized buffers in printf/fprintf/snprintf to prevent stack data leaks on partial writes
  - Checked arithmetic on width/precision parsing with MAX_WIDTH/MAX_PRECISION caps (4095)
  - Saturating casts in sscanf to prevent undefined behavior from @intCast overflow
  - VaList.from() now panics on null instead of using undefined (x86_64, aarch64)
  - Added sprintf security warning comment (inherently unsafe, use snprintf)

**Implemented 2026-01-07:**
- **Secure Page Free Ordering**: Fixed TLB race information leakage (`src/kernel/mm/user_vmm.zig`)
  - All user page free paths (munmap, brk shrink, process exit) now enforce: zero via HHDM -> memory barrier -> clear PTE -> TLB shootdown -> return to PMM
  - Prevents page reallocation before all CPUs process TLB shootdown IPI
  - Added `hal.mmio.memoryBarrier()` between zeroing and PTE clear
- **Doom Music Playback (OPL3 FM Synthesis)**: Full music playback for Doom port
  - MUS-to-MIDI conversion via existing `mus2mid.c`
  - MIDI parser for SMF Type 0/1 files (`midi_parser.zig`)
  - Tick-based MIDI sequencer with per-channel state tracking (`sequencer.zig`)
  - Software OPL3/YMF262 FM synthesizer emulation (`opl3.zig`): 18 2-operator voices, 8 waveforms, ADSR envelopes, LRU voice allocation
  - GENMIDI instrument bank loading from WAD lumps (`genmidi.zig`)
  - Integration with audio mixer in `i_sound.zig` for simultaneous SFX + music
- **VirtIO-Sound Driver**: Full paravirtualized audio driver (`src/drivers/virtio/sound/`)
  - VirtIO Specification 1.2+ Section 5.14 compliant
  - OSS-compatible /dev/dsp interface for legacy applications (Doom)
  - PCM playback with multiple stream support
  - Control queue for stream configuration (PCM_INFO, PCM_SET_PARAMS, PCM_PREPARE, PCM_START, PCM_STOP)
  - TX queue for audio data transfer with double-buffering
  - Sample rate support: 8kHz-192kHz (device-dependent)
  - Format support: S8, U8, S16, U16, S24, S32, FLOAT
  - Integrated with audio subsystem init (priority: VirtIO-Sound > HDA > AC97)
- **IPv6 Socket Dual-Stack Completion**: Full IPv6 parity for socket syscalls
  - sys_getsockname/sys_getpeername: Return correct AF_INET6 addresses
  - sendtoRaw6/recvfromRaw6: Raw ICMPv6 socket support for ping6
  - PMTU cache: Path MTU discovery per RFC 8201
  - Error handling: NoBuffers/MsgSize socket errors properly mapped

**Discovered 2026-01-04 (documentation update - features were already implemented):**
- DHCPv4 client fully functional in netcfgd service (`src/user/services/netcfgd/dhcpv4.zig`)
  - Full RFC 2131/2132 state machine with T1/T2 renewal
  - RFC 5227 ARP probe/announce for conflict detection
  - CSPRNG transaction IDs, exponential backoff with jitter
- DHCPv6 client fully functional in netcfgd service (`src/user/services/netcfgd/dhcpv6.zig`)
  - Full RFC 8415 state machine: Waiting -> Solicit -> Request -> Bound -> Renew -> Rebind
  - DUID-LL generation from MAC address (RFC 8415 Section 11.4)
  - IA_NA (Identity Association for Non-temporary Addresses) with IA_ADDR parsing
  - Rapid Commit support for 2-message exchange optimization
  - T1/T2 timer handling with RFC-compliant default calculations
  - Option Request Option (ORO) for DNS server discovery
  - Server DUID storage for unicast RENEW
  - Multicast to ff02::1:2 (All_DHCP_Servers)
  - CSPRNG transaction IDs (24-bit)
- SLAAC functional in netcfgd (`src/user/services/netcfgd/slaac.zig`)
  - RFC 4862 Stateless Address Autoconfiguration
  - Modified EUI-64 interface identifier generation from MAC
  - M/O/A flag detection from Router Advertisements
  - Global address configuration with gateway setting
  - Timestamp-based RA deduplication

**Implemented 2026-01-16:**
- **UNIX Domain Sockets (Full Implementation)**: Complete path-based and anonymous sockets for local IPC
  - Location: `src/net/transport/socket/unix_socket.zig`, `src/kernel/sys/syscall/net/net.zig`
  - `socket(AF_UNIX, SOCK_STREAM, 0)` creates unbound sockets
  - `socketpair(AF_UNIX, SOCK_STREAM|SOCK_DGRAM, 0, sv)` for anonymous pairs
  - `bind()` to filesystem paths or abstract namespace (\0-prefixed)
  - `listen()` / `accept()` for server sockets (8-connection accept queue)
  - `connect()` for client connections with proper queuing
  - Bidirectional 4KB circular buffers per connection
  - Blocking and non-blocking I/O modes (SOCK_NONBLOCK flag support)
  - `poll()` support for I/O multiplexing on all socket states
  - Reference counting for proper cleanup when endpoints close
  - SMP-safe with spinlock protection and wakeup flags to prevent lost wakeups
  - Generation counters for stale reference detection
  - Path registry (256 slots) for socket name resolution
  - Limitations: SO_PEERCRED returns zeros, no cmsg/FD passing, 256 socket limit
- **VirtIO-Blk Large Request Support**: 8x improvement in per-message capacity (`src/user/drivers/virtio_blk/main.zig`)
  - Increased `MAX_SECTORS_PER_MESSAGE` from 4 to 32 sectors (2KB to 16KB)
  - Added `MAX_SECTORS_PER_REQUEST` of 256 sectors (128KB) with automatic chunking
  - Static IPC buffers to avoid stack overflow with larger messages
  - `BlockResponse.more_chunks` continuation flag for multi-message transfers
  - Full request range bounds validation
- **IST Stack Documentation Update**: Confirmed IST2 (NMI) and IST3 (MCE) were already implemented
  - All critical exception IST stacks (DF/NMI/MCE) documented as complete
  - Paranoid ISR handlers with MSR_GS_BASE check were already in place

**Methodology**: Codebase exploration using pattern matching across:
- `src/arch/x86_64/` and `src/arch/aarch64/` for architecture features
- `src/kernel/mm/` for memory management
- `src/kernel/proc/` for process/threading
- `src/kernel/sys/syscall/` for syscall implementations
- `src/net/` for networking stack
- `src/drivers/` for hardware drivers
- `src/user/` for userspace applications and libc

---

## Hypervisor Support Matrix

### Current Implementation Status

| Feature | VMware | VirtualBox | QEMU/KVM | Proxmox | Hyper-V |
|---------|--------|------------|----------|---------|---------|
| Hypervisor Detection | Yes | Yes | Yes | Yes | Yes |
| Time Sync | Yes | Yes | Yes (kvmclock/pvtime) | Yes (kvmclock/pvtime) | No |
| Graceful Shutdown | Yes | Partial | No | No | No |
| Graphics (2D) | SVGA II | SVGA II | VirtIO-GPU | VirtIO-GPU | No |
| Absolute Mouse | VMMouse | VMMouse | VirtIO-Input | VirtIO-Input | No |
| Network | E1000e | E1000e | VirtIO-Net | VirtIO-Net | No |
| Storage | AHCI | AHCI | AHCI/VirtIO-Blk/SCSI | AHCI/VirtIO-Blk/SCSI | No |
| Audio | HDA/AC97 | HDA/AC97 | VirtIO-Sound | VirtIO-Sound | No |
| Balloon Memory | No | No | VirtIO-Balloon | VirtIO-Balloon | No |
| Guest Agent | VMware Tools | VMware Tools | Partial | Partial | No |

### VMware/VirtualBox (Current)
**Implemented:**
- VMware SVGA II driver (x86_64 + aarch64)
- VMMouse absolute positioning
- VMware hypercall interface (RPCI/TCLO)
- Time synchronization via hypercall
- Graceful shutdown/reboot handling
- Guest info reporting (OS name, tools version)
- Capability registration (softPowerOp, syncTime, resolution_set)
- Heartbeat mechanism

**Missing:**
- PVSCSI paravirtualized SCSI controller
- VMXNET3 paravirtualized NIC (10GbE capable)
- Shared Folders (HGFS protocol)
- Clipboard/drag-and-drop (security-disabled by design)
- Screen resolution auto-resize (display driver integration pending)

### QEMU/KVM (Partial)
**Implemented:**
- VirtIO-RNG (kernel driver)
- VirtIO-GPU 2D (kernel driver)
- VirtIO-Net (userspace driver)
- VirtIO-Blk (userspace driver)
- VirtIO-Balloon (userspace driver)
- VirtIO-Console (userspace driver)
- QEMU Guest Agent (partial - detection only, VirtIO-Console integration pending)
- E1000e NIC (kernel driver)
- AHCI SATA (kernel driver)
- VirtIO-SCSI (kernel driver) **NEW** (2026-01-05)

**Missing - Critical for Proxmox/Production:**
- VirtIO-9P (shared folders via Plan 9 protocol)
- VirtIO-FS (virtiofs, modern shared folder replacement)
- ~~VirtIO-Input (keyboard/mouse/tablet, replaces PS/2)~~ **IMPLEMENTED** (2026-01-05)
- ~~VirtIO-Sound (modern audio)~~ **IMPLEMENTED** (2026-01-07)
- ~~kvmclock paravirtualized timing source~~ **IMPLEMENTED** (2026-01-05)
- SPICE display protocol (Proxmox default)
- SPICE agent (vdagent for clipboard, resolution)
- QXL display driver (SPICE acceleration)

### VirtualBox-Specific (Not Implemented)
- VBoxGuest driver (guest additions core)
- VBoxSF shared folders
- VBoxVideo paravirtualized display
- Seamless window mode
- 3D acceleration (VMSVGA/VBoxSVGA)

### Hyper-V (Not Implemented)
- VMBus transport layer
- StorVSC paravirtualized storage
- NetVSC paravirtualized network
- Hyper-V time sync integration
- Hyper-V shutdown integration
- Synthetic interrupt controller

---

## Missing Features Roadmap: Hypervisor & Network

### Tier 1: Essential for Production VMs

#### Network Stack Gaps
| Feature | Status | Impact |
|---------|--------|--------|
| IPv6 | **Implemented** | RX/TX, extension headers, fragmentation |
| ICMPv6/NDP | **Implemented** | Neighbor discovery, DAD, ping6 |
| SLAAC | **Implemented** | RFC 4862 with EUI-64 generation, M/O/A flags |
| DHCP Client | **Implemented** | Full RFC 2131 client with ARP conflict detection |
| DHCPv6 | **Implemented** | Full RFC 8415 client with Rapid Commit, T1/T2 renewal |
| Multicast Routing | Partial | mDNS/service discovery |
| Raw Sockets (IPv4 ICMP) | **Implemented** | ping utility support (2026-01-07) |
| Raw Sockets (IPv6 ICMPv6) | **Implemented** | ping6 utility support |
| Raw Sockets (traceroute) | **Implemented** | TTL control + TIME_EXCEEDED delivery (2026-01-07) |
| UNIX Domain Sockets | **Implemented** | Full bind/listen/accept/connect + socketpair (2026-01-18) |

#### Storage Gaps
| Feature | Status | Impact |
|---------|--------|--------|
| NVMe | **Implemented** | Full driver with Admin/IO queues, PRP DMA, MSI-X |
| VirtIO-SCSI | **Implemented** | Proxmox default storage, LUN enumeration, MSI-X, partition scanning |
| IDE/PIIX | Not Implemented | Legacy VM compatibility |
| GPT Partition Write | Read-Only | Cannot modify partitions |

#### Display Gaps
| Feature | Status | Impact |
|---------|--------|--------|
| QXL Driver | Not Implemented | SPICE acceleration |
| Bochs VGA | Not Implemented | SeaBIOS/legacy boot |
| Cirrus VGA | Not Implemented | Oldest VMs |
| Resolution Auto-Change | Partial | Host-requested resize pending |

### Tier 2: Enhanced Guest Experience

#### Shared Folders
| Feature | Hypervisor | Protocol |
|---------|------------|----------|
| VirtIO-9P | QEMU/KVM | Plan 9 filesystem |
| VirtIO-FS | QEMU/KVM | FUSE-based virtiofs |
| HGFS | VMware | Host-Guest File System |
| VBoxSF | VirtualBox | Shared Folder protocol |

#### Paravirtualized Devices
| Device | Hypervisor | Benefit |
|--------|------------|---------|
| VMXNET3 | VMware | 10GbE performance |
| PVSCSI | VMware | Low-latency storage |
| ~~kvmclock/pvtime~~ | QEMU/KVM | **IMPLEMENTED** - Stable TSC source (x86_64: kvmclock, aarch64: pvtime) |
| ~~VirtIO-Input~~ | QEMU/KVM | **IMPLEMENTED** - Modern HID replacement (keyboard/mouse/tablet) |
| ~~VirtIO-Sound~~ | QEMU/KVM | **IMPLEMENTED** - OSS-compatible /dev/dsp, PCM playback |

### Tier 3: Advanced Features

#### Agent Services
| Service | Status | Features Needed |
|---------|--------|-----------------|
| QEMU GA | Partial | VirtIO-Console integration, fs-freeze |
| SPICE Agent | Not Implemented | Clipboard, resolution, file transfer |
| open-vm-tools | Partial | Full feature parity with VMware Tools |

#### Graphics Acceleration
| Feature | Status | Requirement |
|---------|--------|-------------|
| SVGA3D | Defined Only | 3D command submission |
| VirtIO-GPU 3D | Not Implemented | Virgl 3D rendering |
| VBoxSVGA | Not Implemented | VirtualBox 3D |

---

## Implementation Priority

### Phase 1: Network Fundamentals (High Priority)
1. ~~**DHCP Client**~~ - **COMPLETE** (2026-01-04)
   - Location: `src/user/services/netcfgd/dhcpv4.zig`
   - Full RFC 2131/2132/5227 implementation with ARP conflict detection

2. ~~**DHCPv6 Client**~~ - **COMPLETE** (2026-01-04)
   - Location: `src/user/services/netcfgd/dhcpv6.zig`
   - Full RFC 8415 implementation with Rapid Commit and T1/T2 renewal

3. ~~**SLAAC**~~ - **COMPLETE** (2026-01-04)
   - Location: `src/user/services/netcfgd/slaac.zig`
   - RFC 4862 with EUI-64 generation, M/O/A flag handling

4. ~~**IPv6 Core**~~ - **COMPLETE** (2026-01-07)
   - Location: `src/net/ipv6/`, `src/net/transport/socket/`
   - Components: ICMPv6, NDP, SLAAC, DHCPv6, PMTU cache
   - Socket dual-stack: sys_getsockname/sys_getpeername IPv4/IPv6 aware
   - Raw sockets: sendtoRaw6/recvfromRaw6 for ping6 utility

### Phase 2: Storage Expansion (High Priority)
1. ~~**NVMe Driver**~~ - **COMPLETE** (2026-01-05)
   - Location: `src/drivers/storage/nvme/`
   - Full NVMe 1.4+ driver with Admin/IO queues, PRP DMA, MSI-X interrupts
   - Async I/O reactor integration, namespace discovery, queue pair management

2. ~~**VirtIO-SCSI**~~ - **COMPLETE** (2026-01-05)
   - Location: `src/drivers/virtio/scsi/`
   - Kernel driver with LUN enumeration, SCSI READ/WRITE, MSI-X interrupts
   - DevFS integration (`/dev/vdX`), MBR/GPT partition scanning

### Phase 3: Guest Integration (Medium Priority)
1. ~~**VirtIO-Input**~~ - **COMPLETE** (2026-01-05)
   - Location: `src/drivers/virtio/input/`
   - Kernel driver with keyboard, mouse, tablet support
   - Auto-detects device type from event capabilities
   - MSI-X interrupt support with polling fallback
   - Integration with unified input subsystem

2. ~~**kvmclock/pvtime**~~ - **COMPLETE** (2026-01-05)
   - x86_64: `src/arch/x86_64/hypervisor/kvmclock.zig` (MSR-based wall/system time)
   - aarch64: `src/arch/aarch64/hypervisor/pvtime.zig` (SMCCC-based stolen time)
   - Enables: Stable timing under VM migration (x86_64), accurate CPU accounting (aarch64)
   - Integrated with timing.zig (initBest()), SMP (per-vCPU pages), and VDSO

3. **SPICE Agent** - Proxmox integration
   - Location: `src/user/services/vdagent/`
   - Enables: Clipboard, resolution
   - Effort: Medium

### Phase 4: Shared Folders (Medium Priority)
1. **VirtIO-9P** - QEMU shared folders
   - Location: `src/fs/9p/` or `src/user/drivers/virtio_9p/`
   - Protocol: Plan 9 filesystem
   - Effort: Medium-High (new filesystem)

### Phase 5: Advanced Display (Lower Priority)
1. **QXL Driver** - SPICE acceleration
2. **SVGA3D** - VMware 3D
3. **VirtIO-GPU 3D** - Virgl rendering

---

## VirtIO Device Coverage

### Kernel Drivers (`src/drivers/virtio/`)
| Device ID | Name | Status | Notes |
|-----------|------|--------|-------|
| 0x1001 | Network | Userspace | `virtio_net` |
| 0x1002 | Block | Userspace | `virtio_blk` |
| 0x1003 | Console | Userspace | `virtio_console` |
| 0x1004 | Entropy (RNG) | Kernel | `rng.zig` |
| 0x1005 | Balloon | Userspace | `virtio_balloon` |
| 0x1009 | 9P Transport | Not Impl | Shared folders |
| 0x1010 | GPU | Kernel | `virtio_gpu.zig` |
| 0x1012 | Input | Kernel | `input/root.zig` **NEW** (2026-01-05) |
| 0x1019 | FS | Not Impl | virtiofs |
| 0x1021 | Sound | Kernel | `sound/root.zig` **NEW** (2026-01-07) |
| 0x1008 | SCSI | Kernel | `scsi/root.zig` **NEW** (2026-01-05) |

### Modern Device IDs (1040+)
Modern VirtIO devices use 0x1040 + device_type. The kernel should detect both legacy (0x1000+type) and modern (0x1040+type) device IDs.

---

## Network Stack Gaps Detail

### Implemented
- IPv4 with options filtering
- ARP with anti-spoofing
- ICMP with rate limiting
- TCP with RFC 7323, SACK (IPv4 and IPv6)
- UDP with checksum enforcement (IPv4 and IPv6)
- DNS resolver with anti-spoofing
- Socket API (SOCK_STREAM, SOCK_DGRAM, SOCK_RAW)
- Raw Sockets (ICMP/ICMPv6 for ping/ping6)
- Traceroute support (IP_TTL setsockopt, TIME_EXCEEDED delivery)
- Path MTU Discovery (IPv4)
- IPv6 (RFC 8200) - RX/TX paths, extension header parsing, fragment reassembly
- ICMPv6 (RFC 4443) - Echo, Dest Unreachable, Packet Too Big, Time Exceeded
- NDP (RFC 4861) - Neighbor cache, NS/NA, RS/RA, DAD, packet queuing

### Fully Implemented (Network)
| Protocol | RFC | Description |
|----------|-----|-------------|
| SLAAC | 4862 | RFC 4862 with EUI-64 generation, M/O/A flag handling |
| DHCPv6 | 8415 | Full client with SOLICIT/ADVERTISE/REQUEST/REPLY, Rapid Commit, T1/T2 |

### Implemented (Network)
| Protocol | RFC | Description |
|----------|-----|-------------|
| DHCPv4 | 2131/2132/5227 | Full client with DORA, T1/T2 renewal, ARP probe |

### Recently Added (2026-01-07)
| Protocol | RFC | Use Case |
|----------|-----|----------|
| Raw Sockets (ICMP) | - | IPv4 ping support via SOCK_RAW + IPPROTO_ICMP |
| Raw Sockets (ICMPv6) | - | IPv6 ping6 support via SOCK_RAW + IPPROTO_ICMPV6 |
| Raw Sockets (traceroute) | - | IPv4/IPv6 traceroute via TTL/hop limit control and TIME_EXCEEDED delivery |
| IPv6 Dual-Stack Syscalls | - | sys_getsockname/sys_getpeername return AF_INET6 addresses |

### Recently Added (2026-01-16)
| Protocol | RFC | Use Case |
|----------|-----|----------|
| UNIX Sockets | - | Full path-based IPC: socket/bind/listen/accept/connect + socketpair |

### Not Implemented
| Protocol | RFC | Use Case |
|----------|-----|----------|
| IGMP | 3376 | Multicast group membership |
| Netlink | - | Network configuration |

---

## Quick Reference: Hypervisor Detection

The kernel detects hypervisors via CPUID and MSRs:

| Hypervisor | Detection Method | Type ID |
|------------|------------------|---------|
| VMware | CPUID leaf 0x40000000 "VMwareVMware" | 1 |
| VirtualBox | CPUID leaf 0x40000000 "VBoxVBoxVBox" | 2 |
| KVM | CPUID leaf 0x40000000 "KVMKVMKVM" | 3 |
| Hyper-V | CPUID leaf 0x40000000 "Microsoft Hv" | 4 |
| Xen | CPUID leaf 0x40000000 "XenVMMXenVMM" | 5 |
| QEMU (TCG) | Fallback when no hypervisor leaf | 6 |

Syscall: `sys_get_hypervisor()` returns the type ID.