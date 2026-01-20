# zscapek Feature Checklist

Zig-based microkernel for x86_64 and AArch64 with custom UEFI bootloader.

---

## Implemented Features

### Core Architecture
- **Provider Pattern**: Compile-time architecture selector in `root.zig` for unified HAL with zero-cost abstraction
- **Cross-Architecture Syscalls**: Shared syscall dispatch using x86 register naming on both architectures
- **Comptime Safety**: Memory layout verification for SyscallFrame and interrupt handlers at compile time

### AArch64 (ARMv8-A)
- **PAN Enforcement**: Explicit LDTR/STTR for kernel-to-user memory access
- **Exception Vector Hardening**: Bit-63 sign checks prevent return to kernel addresses in user context
- **GICv2/v3 Hybrid**: Dynamic interrupt controller with Device Tree parsing and QEMU fallback
- **FEAT_RNG**: RNDR register for hardware entropy with SplitMix64 timing fallback
- **Flexible ASID**: Runtime 8-bit vs 16-bit ASID detection for TLB optimization
- **VMware Fusion**: Full hypervisor detection via ARM64 `mrs xzr, mdccsr_el0` trap
- **pvtime**: KVM stolen time tracking via SMCCC hypercalls for accurate vCPU accounting

### x86_64 (AMD64)
- **SYSRET Mitigation**: Validates canonical RCX to prevent privilege escalation
- **VT-d IOMMU**: DMA remapping with DRHD discovery and fault reporting
- **Dual-Mode APIC**: xAPIC (MMIO) and x2APIC (MSR) support
- **Double Fault Handler**: Dedicated handler with diagnostic output, SWAPGS management
- **SMP Trampoline**: Position-independent AP bootstrap from Real Mode to Long Mode
- **kvmclock**: Paravirtualized timing with per-vCPU structures and seqlock sync

### Memory & MMIO
- **HHDM Guarding**: Overflow checks prevent physical address wraparound
- **Type-Safe MMIO**: MmioDevice wrapper with enum-based register access
- **Aligned MMIO Mapping**: 1MB alignment support for PCI ECAM
- **Write-Through MMIO**: Cache-disable + write-through for strict uncacheable semantics
- **IST Support**: Interrupt Stack Table for critical exceptions (DF, NMI, MCE)

### Security & Entropy
- **Graded Entropy**: Multi-tier sources (High/Medium/Low/Critical) with fail-secure boot
- **ChaCha20 CSPRNG**: RFC 8439 with entropy pooling and hardware re-seeding
- **Stack Guard Canaries**: Hardware RNG-seeded stack smashing protection
- **KASLR Masking**: Automatic address masking in release build panic handlers
- **Atomic Interrupt Dispatch**: Lock-free handler registration with acquire/release semantics

### Bootloader (UEFI)
- **Unified BootInfo**: Standardized handoff (memory map, framebuffer, ACPI, InitRD)
- **Dual-Arch Support**: Single codebase for x86_64 and AArch64 via comptime branching
- **KASLR Offsets**: Random page-aligned offsets for stack, heap, MMIO at boot
- **EFI_RNG_PROTOCOL**: Boot-time entropy acquisition for KASLR seeding
- **4-Level Paging**: Pre-built PML4/L0-L3 for Identity, HHDM, and Kernel segments
- **GOP Standardization**: Automatic RGB/BGR/Bitmask conversion to uniform format
- **Boot Menu**: 5-second countdown with submenu for test kernels

### PCI & Hardware Discovery
- **Dual Access**: PCIe ECAM and legacy Port I/O (0xCF8/0xCFC) with auto-fallback
- **ECAM Alignment**: 1MB-aligned mapping for correct bitwise OR address calculations
- **SMP-Safe Enumeration**: Global locking during BAR sizing and interrupt registration
- **Capability Parsing**: MSI/MSI-X/PM with cycle detection against malicious devices

### USB Stack (xHCI)
- **Transfer Rings**: Command, Event, Transfer rings with cycle-bit toggling
- **Composite Devices**: Multi-interface parsing for keyboard+mouse+storage
- **Hotplug**: Spec-compliant cleanup with endpoint stop and transfer cancellation
- **HID Parser**: Bit-level descriptor parsing for keyboards, mice, tablets
- **Hub Support**: USB 2.0 Chapter 11 compliant with TT configurations
- **Mass Storage**: Bulk-Only Transport with SCSI commands and tag tracking

### Networking (E1000e)
- **NAPI-Style Polling**: Worker thread drains RX rings under heavy load
- **Pre-allocated Pool**: Zero-copy bounded buffer pool eliminates heap latency
- **IOMMU-Aware DMA**: Full integration for descriptor rings and packet buffers
- **TX Watchdog**: Automatic reset on head pointer stall

### Storage (AHCI)
- **Async Block I/O**: IoRequest integration for non-blocking sector access
- **LBA48 & Scatter-Gather**: Large disk support with PRDT for multi-page transfers
- **SATA FIS**: Frame Information Structures for H2D/D2H communication

### Storage (NVMe)
- **NVMe 1.4+ Driver**: Admin/IO queues with phase bit completion detection
- **Identify Parsing**: 4KB structures with comptime 4096-byte size assertions
- **PRP DMA**: Physical Region Page transfers with automatic list allocation
- **MSI-X Integration**: HAL vector allocation and handler registration
- **Namespace Discovery**: Active namespace enumeration with LBA/capacity tracking

### Audio
- **Intel HDA**: CORB/RIRB rings, codec detection via STATESTS
- **AC97 Legacy**: Fallback for older hardware and QEMU
- **VirtIO-Sound**: OSS-compatible /dev/dsp with PCM playback
- **PC Speaker**: PIT channel 2 for diagnostic beeps

### Timekeeping
- **MC146818A RTC**: Date/time with BCD conversion and 12/24-hour handling
- **RTC Alarms**: Programmable with wildcard fields and IRQ8 handler
- **Periodic Interrupts**: 2 Hz to 8192 Hz configurable frequencies
- **Unix Timestamps**: Bidirectional conversion with leap year handling

### Input
- **PS/2 Controller**: 8042 abstraction with self-test and dual port support
- **Dual Ring Buffers**: Separate ASCII and scancode buffers for cooked/raw modes
- **Sub-pixel Cursor**: Fixed-point scaling with fractional accumulation
- **Keyboard Layouts**: US QWERTY and Dvorak with extensible mapping
- **VMware VMMouse**: Absolute positioning via hypercall interface
- **VirtIO-Input**: Modern HID replacement for QEMU/KVM

### Video & Graphics
- **VirtIO-GPU 2D**: Scanout, resource tracking, host blitting, runtime resolution changes
- **VMware SVGA II**: Cross-arch driver (x86_64 I/O, aarch64 MMIO) with 2D accel and hardware cursor
- **ANSI Terminal**: State machine parser for colors, bold, inverse
- **Dual-Mode Framebuffer**: Direct-to-VRAM and back-buffered paths
- **PSF Fonts**: PSF1/PSF2 loaders with checked glyph indexing

### Serial
- **Interrupt-Driven**: 16550 and PL011 with async THRE-based transmission
- **Panic-Safe I/O**: Bypass spinlocks/async for crash diagnostics

### VFS & Filesystems
- **Longest-Path Mount**: 8-slot registry with most-specific resolution
- **Unmount Protection**: Reference counting prevents use-after-free
- **SFS Filesystem**: Async I/O pattern with deferred block deletion
- **MBR/GPT Detection**: Automatic partition table parsing
- **InitRD (USTAR)**: Read-only TAR with path traversal rejection

### ACPI
- **DMAR/VT-d Parser**: IOMMU discovery with RMRR and device scopes
- **MADT/APIC Topology**: Local/IO APIC, x2APIC, ISA overrides
- **MCFG/ECAM Setup**: PCIe config space with bus range validation
- **Dual RSDP**: ACPI 1.0 (RSDT) and 2.0+ (XSDT) support

### Memory Management
- **Arch-Aware Stacks**: 32KB (x86_64) / 64KB (AArch64) per-thread kernel stacks
- **Bitmap PMM**: Bit-array with 16-bit refcounts for future CoW
- **Multi-Region ASLR**: Stack, heap, PIE, mmap, TLS randomization
- **Slab Allocator**: O(1) for 16B-2KB objects with bitmapped slabs
- **Secure Page Free**: Zero via HHDM, memory barrier, PTE clear, TLB shootdown
- **Multicore TLB Shootdown**: IPI-based with atomic counters
- **Demand Paging**: Lazy allocation with zero-fill on fault
- **VMA Tracking**: MAP_SHARED/PRIVATE/FIXED/ANONYMOUS/DEVICE support

### Process & Threading
- **Capability-Based Security**: Fine-grained IRQ/port/MMIO/DMA access control
- **SMP Scheduler**: Per-CPU queues with work-stealing and LIFO locality
- **Futex**: Physical address keyed with timeout and page pinning
- **Zero-Copy Ring IPC**: SPSC shared memory with futex signaling
- **Process Groups/Sessions**: Full POSIX job control (setpgid, setsid, etc.)
- **rlimit**: 16 Linux RLIMIT types with soft/hard limits
- **CPU Affinity**: Per-thread bitmask for core pinning
- **Clone Flags**: Full Linux semantics (CLONE_THREAD/VM/SIGHAND/etc.)
- **Credentials**: uid/gid/euid/egid/suid/sgid with 16-group supplementary array

### Syscall Infrastructure
- **Async I/O Reactor**: Fixed-size request pool for non-blocking operations
- **Timer Wheel**: 3-level O(1) insertion and amortized O(1) expiration
- **io_uring**: SQ/CQ rings with kernel bounce buffers against TOCTOU
- **UserPtr**: Forced validation before userspace memory dereference
- **vDSO**: Syscall-free time and CPU info access
- **Display Mode Syscall**: SYS_SET_DISPLAY_MODE (1070) with capability check

### POSIX I/O
- **epoll**: Full API with EPOLLIN/OUT/ERR/ET/ONESHOT
- **select/poll**: Traditional FD multiplexing with timeouts
- **Pipes**: O_CLOEXEC/O_NONBLOCK, async bounce buffers prevent UAF
- **Scatter-Gather**: writev, pread64 for multi-buffer I/O
- **clock_getres**: REALTIME, MONOTONIC, PROCESS_CPUTIME_ID

### Network Stack
- **Zero-Copy PacketBuffer**: Layer-specific offsets avoid copies
- **Memory Budgeting**: System-wide limit prevents network-driven exhaustion
- **RFC 894 Padding**: Zero-init prevents stack data leakage
- **ARP Cache**: Anti-spoofing with conflict detection and LRU eviction
- **IP Reassembly**: 64-fragment limit, overlapping fragment rejection (RFC 5722)
- **PMTU Discovery**: Tick-based rate limiting (RFC 1191)
- **ICMP Smurf Prevention**: No replies to broadcast/multicast
- **Raw ICMP Sockets**: SOCK_RAW for ping/traceroute utilities

### TCP/UDP
- **Secure ISNs**: SipHash-2-4 with hardware entropy (RFC 6528)
- **SYN Flood Mitigation**: O(1) half-open eviction
- **RFC 7323**: Window scaling, timestamps with anti-fingerprinting entropy mixing
- **SACK**: Selective acknowledgments (RFC 2018)
- **RTT Estimation**: Jacobson/Karels SRTT/RTTVAR with exponential backoff
- **UDP Checksums**: Mandatory for DNS/NTP/SNMP ports

### Sockets
- **Port Randomization**: RFC 6056 Algorithm 3 with ~32 bits entropy
- **Two-Phase Deletion**: AtomicRefcount + closing flag prevents UAF
- **SO_REUSEADDR**: POSIX-compliant address reuse for server restart
- **Async recv/send**: Bounce buffers prevent SMAP/TOCTOU issues

### IPv6
- **Full Stack**: RX/TX, extension headers, fragmentation
- **ICMPv6/NDP**: Neighbor discovery, DAD, ping6
- **SLAAC**: RFC 4862 with EUI-64 generation
- **DHCPv6**: RFC 8415 with Rapid Commit and T1/T2 renewal
- **PMTU Cache**: Per-destination path MTU (RFC 8201)

### DNS
- **Zero-Allocation Resolver**: Stack buffers with case-insensitive matching
- **CNAME Following**: 8-depth limit with pointer loop protection
- **Deadline Enforcement**: Wall-clock timeout and max-packet-count limit
- **RFC 5452**: Randomized source ports for query ID entropy

### UNIX Domain Sockets
- **socket/socketpair**: AF_UNIX SOCK_STREAM/DGRAM
- **bind/listen/accept/connect**: Path-based and abstract namespace (\0-prefix)
- **SO_PEERCRED**: Returns UCred (pid/uid/gid) of connected peer
- **shutdown**: Half-close with peer EOF notification
- **SCM_RIGHTS**: FD passing via sendmsg/recvmsg (max 8 FDs)
- **SCM_CREDENTIALS**: Credential passing (non-root can only send own creds)
- **SOCK_CLOEXEC**: Close-on-exec flag support

### Build System
- **OVMF Detection**: Auto-discovery across macOS and Linux distros
- **Dual-Arch UEFI**: Unified logic for bootaa64.efi and bootx64.efi
- **FPU-Safe Kernel**: Disables MMX/SSE/AVX, enables soft_float
- **Red Zone Disabled**: Protects stack during async interrupts
- **Module DI**: Resolves circular deps between HAL, Console, Scheduler
- **Comptime Config**: Injects heap size, max threads, baud rate at build
- **InitRD Packaging**: Auto-packages userland ELFs into USTAR tar
- **GPT/ISO Generation**: xorriso + mtools for isohybrid images
- **QEMU Runner**: Multi-backend display/audio with HVF acceleration

### Utility Structures
- **Intrusive List**: Zero-allocation with double-remove protection
- **Ring Buffer**: Comptime power-of-2 validation, anti-leak zeroing
- **DTB Parser**: 64MB limit, bounded scanning, checked arithmetic

### Userspace
- **VirtIO Drivers**: Userspace VirtIO-Net/Blk with capability syscalls
- **Ring IPC**: Zero-copy with 128-byte cache-line separation
- **SPICE Agent**: Display resolution sync via VDI protocol over VirtIO-Serial
- **Libc**: Recursion-safe memcpy/memset, overflow-protected malloc, strlcpy/strlcat
- **setjmp/longjmp**: Full implementation with signal mask save/restore
- **io_uring Wrapper**: Type-safe SQ/CQ with kernel blocking
- **CRT0**: Manual varargs for AAPCS64/SysV, TLS init, 4MB null-pointer guard

### Applications
- **HTTP Server**: Async HTTP/1.1 with io_uring, 32 concurrent clients
- **Shell**: Readline with backspace, ANSI escapes, built-in commands
- **Netstack Daemon**: Packet routing via shared memory rings
- **Doom Port**: Full game with keyboard/mouse, software rendering, OPL3 music
- **netcfgd**: DHCPv4/DHCPv6/SLAAC client with ARP conflict detection

### Hypervisor Support
| Feature | VMware | VirtualBox | QEMU/KVM | Proxmox |
|---------|--------|------------|----------|---------|
| Detection | Yes | Yes | Yes | Yes |
| Time Sync | Yes | Yes | kvmclock/pvtime | kvmclock/pvtime |
| Graphics | SVGA II | SVGA II | VirtIO-GPU | VirtIO-GPU |
| Mouse | VMMouse | VMMouse | VirtIO-Input | VirtIO-Input |
| Network | E1000e | E1000e | VirtIO-Net | VirtIO-Net |
| Storage | AHCI | AHCI | AHCI/VirtIO-Blk/SCSI | AHCI/VirtIO-Blk/SCSI |
| Audio | HDA/AC97 | HDA/AC97 | VirtIO-Sound | VirtIO-Sound |
| Guest Agent | VMware Tools | VMware Tools | Partial | SPICE Agent |

---

## Missing Features & Roadmap

### Network Stack
- **Multicast Routing**: mDNS/service discovery (partial)
- **EDNS0**: Large DNS responses (>512 bytes)

### Storage
- **IDE/PIIX**: Legacy VM compatibility
- **GPT Write**: Partition modification (read-only only)

### Display
- **QXL Driver**: SPICE acceleration
- **Bochs/Cirrus VGA**: Legacy boot support
- **Resolution Auto-Resize**: Host-requested resize pending

### Shared Folders
- **VirtIO-9P**: Plan 9 filesystem for QEMU/KVM
- **VirtIO-FS**: FUSE-based virtiofs
- **HGFS**: VMware Host-Guest File System
- **VBoxSF**: VirtualBox Shared Folders

### Paravirtualized Devices
- **VMXNET3**: VMware 10GbE performance
- **PVSCSI**: VMware low-latency storage

### Guest Agents
- **QEMU GA**: Full VirtIO-Console integration, fs-freeze
- **open-vm-tools**: Full VMware Tools parity

### Graphics Acceleration
- **SVGA3D**: 3D command submission
- **VirtIO-GPU 3D**: Virgl rendering
- **VBoxSVGA**: VirtualBox 3D

### VirtualBox-Specific
- **VBoxGuest**: Guest additions core
- **VBoxVideo**: Paravirtualized display
- **Seamless Mode**: Window integration

### Hyper-V (Not Implemented)
- **VMBus**: Transport layer
- **StorVSC/NetVSC**: Paravirtualized storage/network
- **Synthetic Interrupt Controller**

### Libc Stubs
- **Environment**: getenv/setenv/unsetenv (no env block)
- **Filesystem**: mkdir/rmdir/chdir/getcwd (InitRD read-only)
- **Input Parsing**: scanf/fscanf
- **Dynamic Alloc**: vasprintf

---

## Recent Implementation Log

### 2026-01-19
- SPICE Agent service with VDI protocol for Proxmox/QEMU display sync
- SYS_SET_DISPLAY_MODE syscall (1070) with DisplayServer capability
- VirtIO-GPU dynamic resolution changes via setDisplayMode()
- TCP timestamp anti-fingerprinting with periodic entropy mixing
- Pipe async I/O bounce buffers to prevent use-after-free

### 2026-01-18
- UNIX domain sockets: full implementation with SCM_RIGHTS/SCM_CREDENTIALS
- VirtIO-Blk: 8x improvement (32 sectors/message, 256 sectors/request)

### 2026-01-07
- VirtIO-Sound driver with OSS /dev/dsp interface
- Doom OPL3 FM synthesis music playback
- IPv6 socket dual-stack completion
- Secure page free ordering (zero -> barrier -> PTE clear -> TLB shootdown)

### 2026-01-05
- NVMe 1.4+ driver with Admin/IO queues and MSI-X
- VirtIO-SCSI kernel driver
- kvmclock (x86_64) and pvtime (aarch64) paravirtualized timing
- PCI ECAM 1MB-aligned mapping fix

### 2026-01-04
- DHCPv4/DHCPv6/SLAAC clients in netcfgd

### 2025-12-30
- Register sanitization on SYSRET
- sigsetjmp/siglongjmp signal mask support
- XSAVE/XRSTOR with dynamic FPU state sizing
