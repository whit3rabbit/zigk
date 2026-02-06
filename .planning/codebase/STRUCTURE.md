# Codebase Structure

**Analysis Date:** 2026-02-06

## Directory Layout

```
zigk/
├── build.zig                    # Zig build system configuration (dual-arch: x86_64, aarch64)
├── src/
│   ├── arch/                    # Hardware Abstraction Layer (architecture-specific)
│   │   ├── root.zig             # HAL dispatcher (selects x86_64 or aarch64)
│   │   ├── x86_64/              # x86_64 architecture implementation
│   │   │   ├── kernel/          # x86_64-specific kernel subsystems
│   │   │   │   ├── interrupts/  # IDT, exception handlers, IRQ routing
│   │   │   │   ├── apic/        # LAPIC, IOAPIC, MSI-X vector management
│   │   │   │   ├── cpu.zig      # CPUID, MSR operations, privilege modes
│   │   │   │   ├── gdt.zig      # Global Descriptor Table setup
│   │   │   │   ├── idt.zig      # Interrupt Descriptor Table setup
│   │   │   │   ├── pic.zig      # Programmable Interrupt Controller
│   │   │   │   ├── pit.zig      # Programmable Interval Timer
│   │   │   │   ├── rtc.zig      # Real-Time Clock
│   │   │   │   ├── syscall.zig  # SYSCALL/SYSRET MSR configuration
│   │   │   │   └── smp.zig      # Symmetric Multi-Processing (AP startup)
│   │   │   ├── mm/              # Memory management
│   │   │   │   ├── paging.zig   # Page table setup, TLB invalidation
│   │   │   │   ├── mmio.zig     # Memory-mapped I/O access
│   │   │   │   ├── mmio_device.zig  # Typed MMIO register interface
│   │   │   │   └── iommu/       # Intel VT-d IOMMU support
│   │   │   ├── lib/             # x86_64-specific utility functions
│   │   │   │   └── io.zig       # Port I/O (inb, outb, etc.)
│   │   │   ├── serial/          # 16550 UART driver
│   │   │   ├── boot/            # Real-mode bootloader stub
│   │   │   ├── hypervisor/      # Hypervisor detection (KVM, VMware, Hyper-V)
│   │   │   └── asm_helpers.S    # Assembly: SYSCALL entry, page table setup, copy_from_user
│   │   └── aarch64/             # aarch64 architecture implementation
│   │       ├── kernel/          # aarch64-specific kernel subsystems
│   │       │   ├── interrupts/  # Exception table, vector handlers
│   │       │   ├── cpu.zig      # CPU control, privilege modes
│   │       │   ├── gic.zig      # Generic Interrupt Controller (GIC)
│   │       │   ├── syscall.zig  # SVC handler configuration
│   │       │   └── smp.zig      # AP startup via PSCI
│   │       ├── mm/              # Memory management (TTBR0/TTBR1, TLB)
│   │       ├── lib/             # aarch64-specific utilities
│   │       ├── boot/            # Boot stubs (not fully implemented)
│   │       ├── hypervisor/      # Hypervisor detection (similar to x86_64)
│   │       └── asm_helpers.S    # Assembly: SVC entry, page table, copy_from_user
│   │
│   ├── kernel/                  # Microkernel core (architecture-independent)
│   │   ├── core/                # Core initialization and services
│   │   │   ├── main.zig         # Kernel entry point (_start)
│   │   │   ├── init_hw.zig      # Hardware subsystem initialization (PCI, drivers, network)
│   │   │   ├── init_mem.zig     # Memory subsystem initialization (PMM, VMM, heap)
│   │   │   ├── init_fs.zig      # Filesystem initialization (mount InitRD, SFS, DevFS)
│   │   │   ├── init_proc.zig    # First process loading and execution
│   │   │   ├── panic.zig        # Panic handler and stack unwinding
│   │   │   ├── elf/             # ELF binary loader
│   │   │   └── debug/           # Debug utilities (stack trace, register dump)
│   │   │
│   │   ├── mm/                  # Memory management subsystems
│   │   │   ├── pmm.zig          # Physical Page Allocator (buddy algorithm)
│   │   │   ├── vmm.zig          # Virtual Memory Manager (kernel space paging)
│   │   │   ├── user_vmm.zig     # User space Virtual Memory Manager (VMAs, fault handling, ASLR)
│   │   │   ├── heap.zig         # Kernel heap allocator (slab, bump)
│   │   │   ├── slab.zig         # Slab allocator for fixed-size objects
│   │   │   ├── dma.zig          # DMA buffer management
│   │   │   ├── dma_allocator.zig # DMA memory pool allocator
│   │   │   ├── aslr.zig         # Address Space Layout Randomization
│   │   │   ├── tlb.zig          # TLB shootdown for SMP
│   │   │   ├── kernel_stack.zig # Per-thread kernel stack allocation
│   │   │   ├── layout.zig       # Kernel memory layout with KASLR offsets
│   │   │   └── iommu/           # IOMMU page table management
│   │   │
│   │   ├── proc/                # Process and scheduling subsystems
│   │   │   ├── sched/           # Scheduler (round-robin per-CPU)
│   │   │   │   ├── scheduler.zig # Main scheduler loop, context switching
│   │   │   │   ├── thread.zig   # Thread data structure and lifecycle
│   │   │   │   ├── cpu.zig      # Per-CPU scheduler data
│   │   │   │   ├── queue.zig    # Wait queue (blocking/wakeup)
│   │   │   │   └── root.zig     # Public API re-exports
│   │   │   ├── process/         # Process data structure
│   │   │   │   ├── root.zig     # Public process API
│   │   │   │   └── signal.zig   # Signal delivery and handling
│   │   │   ├── ipc/             # Inter-process communication
│   │   │   │   ├── futex.zig    # Futex syscalls and wait queues
│   │   │   │   ├── msgqueue.zig # Message queue syscalls
│   │   │   │   └── ring.zig     # Shared ring buffer (driver IPC)
│   │   │   ├── capabilities/    # Capability-based access control
│   │   │   │   └── root.zig     # Capability checks (MMIO, PCI, trace)
│   │   │   └── root.zig         # Process management public API
│   │   │
│   │   ├── fs/                  # Virtual Filesystem and file operations
│   │   │   ├── fd.zig           # File descriptor table and operations
│   │   │   ├── devfs.zig        # Device filesystem (/dev)
│   │   │   ├── pipe.zig         # Pipe and FIFO implementation
│   │   │   ├── flock.zig        # File locking (advisory)
│   │   │   └── root.zig         # FS public API
│   │   │
│   │   ├── sys/                 # Syscall implementation
│   │   │   └── syscall/         # Syscall handlers (organized by subsystem)
│   │   │       ├── core/        # Core syscalls (dispatch table, exit, uname)
│   │   │       ├── process/     # Process syscalls (fork, exec, wait, exit)
│   │   │       ├── fs/          # File syscalls (open, read, write, stat, etc.)
│   │   │       ├── memory/      # Memory syscalls (mmap, munmap, brk, mprotect)
│   │   │       ├── io/          # I/O syscalls (ioctl, select, poll)
│   │   │       ├── net/         # Network syscalls (socket, connect, send/recv)
│   │   │       ├── io_uring/    # Async I/O ring interface
│   │   │       ├── misc/        # Miscellaneous syscalls (getrandom, sysinfo, times)
│   │   │       ├── hw/          # Hardware access syscalls (port_io, mmio, pci)
│   │   │       ├── tests/       # Syscall unit tests and mocks
│   │   │       └── table.zig    # Dispatch table (comptime-generated)
│   │   │
│   │   ├── io/                  # Kernel async I/O
│   │   │   └── [async request handling]
│   │   │
│   │   ├── acpi/                # ACPI table parsing
│   │   │   └── root.zig         # RSDP, DMAR, power management
│   │   │
│   │   └── core/[remaining files]
│   │       ├── root.zig         # Kernel core module exports
│   │       └── sync.zig         # Synchronization primitives (RwLock, Spinlock)
│   │
│   ├── drivers/                 # Hardware drivers (modular, loadable at init)
│   │   ├── pci/                 # PCI bus enumeration and ECAM access
│   │   │   └── root.zig         # PCI device discovery, configuration
│   │   ├── storage/             # Block device drivers
│   │   │   ├── ahci/            # SATA (Serial ATA) AHCI controller
│   │   │   ├── nvme/            # NVMe SSD controller
│   │   │   └── ide/             # Legacy IDE controller (optional)
│   │   ├── net/                 # Network device drivers
│   │   │   └── e1000e/          # Intel E1000e Ethernet NIC
│   │   ├── usb/                 # USB host controllers and class drivers
│   │   │   ├── xhci/            # xHCI (USB 3.x) controller
│   │   │   ├── ehci/            # EHCI (USB 2.x) controller
│   │   │   └── class/hid/       # HID (human interface device) class
│   │   ├── video/               # Graphics drivers
│   │   │   ├── bga/             # Bochs Graphics Adapter (simple linear FB)
│   │   │   ├── cirrus/          # Cirrus Logic CL-GD5446
│   │   │   ├── qxl/             # SPICE QXL paravirtualized GPU
│   │   │   ├── svga/            # VMware SVGA
│   │   │   └── font/            # Font rendering for text console
│   │   ├── input/               # Input device drivers
│   │   │   └── ps2/             # PS/2 keyboard and mouse
│   │   ├── audio/               # Audio device drivers
│   │   │   ├── ac97/            # AC97 audio codec
│   │   │   └── hda/             # High Definition Audio
│   │   ├── serial/              # Serial port drivers (16550 UART)
│   │   ├── virtio/              # Virtio device family drivers
│   │   │   ├── 9p/              # 9P filesystem (VirtFS)
│   │   │   ├── fs/              # VirtIO filesystem (FUSE over shared memory)
│   │   │   ├── scsi/            # VirtIO SCSI storage
│   │   │   ├── input/           # VirtIO input devices
│   │   │   ├── sound/           # VirtIO sound device
│   │   │   └── root.zig         # Common virtio infrastructure
│   │   ├── vmware/              # VMware-specific drivers
│   │   │   ├── hgfs/            # HGFS (Hosted Guest Filesystem)
│   │   │   └── root.zig         # VMMouse, SVGA cursor integration
│   │   ├── vbox/                # VirtualBox-specific drivers
│   │   │   ├── sf/              # SharedFolders (VBoxSF)
│   │   │   ├── vmmdev/          # VMMDev device (Guest Additions)
│   │   │   └── root.zig         # VBox integration
│   │   ├── virt_pci/            # VFIO (Virtual Function I/O) for userspace drivers
│   │   └── [driver support libraries]
│   │
│   ├── net/                     # Network stack (TCP/IP protocol implementation)
│   │   ├── core/                # Packet queuing, statistics
│   │   ├── ethernet/            # Data link layer (Ethernet, ARP)
│   │   ├── ipv4/                # IPv4, ICMP
│   │   │   ├── ipv4/            # IP packet handling
│   │   │   └── arp/             # ARP protocol
│   │   ├── ipv6/                # IPv6, ICMPv6, NDP
│   │   │   ├── ipv6/            # IPv6 packet handling
│   │   │   ├── icmpv6/          # ICMPv6 (neighbor discovery)
│   │   │   └── ndp/             # NDP protocol
│   │   ├── transport/           # Transport layer
│   │   │   ├── socket/          # BSD socket API implementation
│   │   │   └── tcp/             # TCP protocol (stateful connection management)
│   │   │       ├── rx/          # TCP receive processing
│   │   │       ├── tx/          # TCP send processing
│   │   │       └── state.zig    # TCB (TCP Control Block), ISN generation
│   │   ├── dns/                 # Domain Name System
│   │   ├── mdns/                # Multicast DNS
│   │   ├── drivers/             # Network driver integration
│   │   └── root.zig             # Network stack public API
│   │
│   ├── fs/                      # Filesystem implementations
│   │   ├── initrd.zig           # USTAR tarball parser (read-only)
│   │   ├── sfs.zig              # Simple Filesystem (writable, 64 file limit)
│   │   ├── vfs/                 # Virtual Filesystem abstraction
│   │   └── partitions/          # Partition table parsing (MBR, GPT)
│   │
│   ├── lib/                     # Kernel utility libraries
│   │   ├── panic.zig            # Panic and error handling utilities
│   │   ├── prng.zig             # Pseudo-random number generator (xoroshiro128+)
│   │   ├── console.zig          # Kernel console I/O (multiplexed backends)
│   │   ├── keyboard.zig         # Keyboard input buffer
│   │   ├── mouse.zig            # Mouse input buffer
│   │   ├── input.zig            # Generic input event handling
│   │   ├── keyboard/            # Keyboard layout support
│   │   ├── framebuffer.zig      # Framebuffer management
│   │   └── [other shared utilities]
│   │
│   ├── uapi/                    # User-API definitions (ABI consistency between kernel and userland)
│   │   ├── root.zig             # Main UAPI entry point (re-exports all constants)
│   │   ├── syscalls/            # Syscall number definitions
│   │   │   ├── root.zig         # Dispatcher selecting x86_64 or aarch64 ABI
│   │   │   ├── linux.zig        # x86_64 Linux ABI syscall numbers
│   │   │   ├── linux_aarch64.zig # aarch64 Linux ABI syscall numbers (with zk compat range 500+)
│   │   │   └── zk.zig           # zk-specific extension syscalls
│   │   ├── base/                # Base definitions
│   │   │   ├── errno.zig        # Error codes (Linux compatible)
│   │   │   ├── abi.zig          # ABI constants (stack alignment, etc.)
│   │   │   └── mman.zig         # Memory management constants (mmap flags)
│   │   ├── fs/                  # Filesystem definitions
│   │   │   ├── stat.zig         # File stat structure
│   │   │   └── dirent.zig       # Directory entry structure
│   │   ├── io/                  # I/O definitions
│   │   │   ├── poll.zig         # poll/select event flags
│   │   │   ├── epoll.zig        # epoll event structures
│   │   │   └── io_ring.zig      # io_uring request/completion structures
│   │   ├── ipc/                 # IPC definitions
│   │   │   ├── futex.zig        # Futex operations and flags
│   │   │   ├── ipc_msg.zig      # Message queue structures
│   │   │   ├── net_ipc.zig      # Network IPC (sockets)
│   │   │   └── ring.zig         # Ring buffer shared structures
│   │   ├── process/             # Process definitions
│   │   │   ├── signal.zig       # Signal numbers and handlers
│   │   │   ├── sched.zig        # Scheduling constants
│   │   │   └── time.zig         # Time-related structures
│   │   ├── dev/                 # Device definitions
│   │   │   ├── input.zig        # Input event codes
│   │   │   ├── sound.zig        # Audio definitions
│   │   │   └── tty.zig          # TTY/terminal definitions
│   │   └── virt_pci/            # VFIO device structures
│   │
│   └── user/                    # Userspace (C library, applications)
│       ├── crt0.S               # x86_64 startup code (_start, libc initialization)
│       ├── crt0.zig             # aarch64 startup code
│       ├── linker.ld            # Linker script (ELF layout)
│       ├── lib/                 # Userspace libraries
│       │   ├── libc/            # POSIX C library implementation
│       │   │   ├── stdio/       # Standard I/O (printf, FILE streams)
│       │   │   ├── stdlib/      # Standard library (malloc, free, env)
│       │   │   ├── string/      # String functions (strlen, strcpy, etc.)
│       │   │   ├── unistd/      # POSIX API (read, write, close, fork)
│       │   │   ├── memory/      # Memory functions (memcpy, memset, mmap)
│       │   │   ├── va_list/     # Variable argument handling
│       │   │   └── [other standard headers]
│       │   ├── syscall/         # Syscall wrappers (raw syscall invocation)
│       │   │   └── [typed syscall wrappers per category]
│       │   └── [utility libraries]
│       ├── shell/               # Shell interpreter (command parsing, execution)
│       ├── doom/                # Doom game port (graphics/input test)
│       ├── httpd/               # HTTP server
│       ├── test_runner/         # Test harness (runs 186 tests)
│       │   └── tests/           # Test suite (filesystem, syscalls, process, stress)
│       ├── test_binary/         # Simple test executable
│       ├── services/            # Service daemons
│       │   ├── netcfgd/         # Network configuration daemon
│       │   ├── qemu_ga/         # QEMU Guest Agent
│       │   ├── spice_agent/     # SPICE agent (graphics protocol)
│       │   └── vmware_tools/    # VMware Guest Tools
│       ├── drivers/             # Userspace device drivers (ring-based IPC)
│       │   ├── virtio_blk/      # VirtIO block device driver
│       │   ├── virtio_net/      # VirtIO network driver
│       │   ├── virtio_console/  # VirtIO console
│       │   └── virtio_balloon/  # VirtIO memory balloon
│       ├── netstack/            # Network stack services
│       ├── root.zig             # Userspace module exports
│       └── tests/               # Additional test utilities
│
├── .github/
│   └── workflows/
│       └── ci.yml               # GitHub Actions CI configuration (runs tests on PR/push)
│
├── scripts/
│   ├── run_tests.sh             # Test runner script (handles multi-arch testing)
│   └── [other build/dev scripts]
│
├── docs/
│   ├── SYSCALL.md               # Syscall ABI and implementation status
│   ├── MISSING_SYSCALLS.md      # Stub implementations and gaps
│   └── [architecture docs, testing notes]
│
└── .planning/
    └── codebase/                # This analysis (ARCHITECTURE.md, STRUCTURE.md, etc.)
```

## Directory Purposes

**`src/arch/`:**
- Purpose: Hardware Abstraction Layer providing architecture-independent interface
- Contains: CPU operations, interrupts, paging, I/O, timing (separate implementations for x86_64 and aarch64)
- Key files: `x86_64/asm_helpers.S` (syscall entry, copy_from_user), `aarch64/kernel/interrupts/root.zig` (exception table)

**`src/kernel/`:**
- Purpose: Microkernel core - process scheduling, memory management, filesystem, IPC
- Contains: Scheduler (per-CPU round-robin), memory management (PMM/VMM/UserVmm), VFS, file descriptors, syscall dispatch, process management
- Key files: `core/main.zig` (kernel entry), `proc/sched/scheduler.zig` (preemptive scheduler), `mm/user_vmm.zig` (user address space), `sys/syscall/core/table.zig` (dispatch table)

**`src/drivers/`:**
- Purpose: Modular hardware device drivers (storage, network, USB, video, audio, input)
- Contains: PCI, AHCI/NVMe/IDE, E1000e, xHCI/EHCI, BGA/Cirrus/QXL/SVGA, PS/2, AC97/HDA, VirtIO, VirtualBox/VMware integration
- Key files: Each driver has `root.zig` entry point, initialized by `init_hw.zig`

**`src/net/`:**
- Purpose: TCP/IP protocol stack
- Contains: Ethernet, IPv4/IPv6, ICMP/ICMPv6, TCP/UDP, DNS, sockets
- Key files: `socket/root.zig` (BSD socket interface), `tcp/state.zig` (TCP control blocks)

**`src/fs/`:**
- Purpose: Filesystem implementations (InitRD, SFS, VFS)
- Contains: USTAR tarball parser, simple flat filesystem, VFS abstraction layer
- Mount points: `/` (InitRD, read-only), `/mnt` (SFS, writable), `/dev` (DevFS, virtual)

**`src/lib/`:**
- Purpose: Shared kernel utility libraries
- Contains: Console I/O, keyboard/mouse input, framebuffer, panic handling, random number generation

**`src/uapi/`:**
- Purpose: User-API definitions for kernel/userland ABI consistency
- Contains: Syscall numbers (Linux ABI + zk extensions), error codes, structures (stat, dirent, futex, poll, etc.)
- Single source of truth: Kernel and userspace share same constants, prevents ABI mismatches

**`src/user/`:**
- Purpose: Userspace (C library, applications, test runner)
- Contains:
  - `lib/libc/`: POSIX C library (stdio, stdlib, string, unistd, etc.)
  - `lib/syscall/`: Syscall wrappers for typed invocation
  - `shell/`, `doom/`, `test_runner/`: User-facing applications
  - `services/`: Network config, guest agents, tools
  - `drivers/`: Ring-based userspace device drivers (VirtIO)

## Key File Locations

**Entry Points:**
- `src/kernel/core/main.zig`: Kernel entry (_start), called by bootloader with BootInfo
- `src/boot/uefi/main.zig`: UEFI bootloader, loads kernel ELF from disk
- `src/user/crt0.S` (x86_64) or `crt0.zig` (aarch64): Userspace startup (_start -> libc init -> main)

**Configuration:**
- `build.zig`: Zig build configuration (target arch, optimization, driver selection)
- `src/arch/x86_64/asm_helpers.S`: x86_64 assembly (syscall entry, copy_from_user, GDT setup)
- `src/arch/aarch64/asm_helpers.S`: aarch64 assembly (SVC entry, exception table)

**Core Logic:**
- `src/kernel/core/init_hw.zig`: Hardware subsystem initialization orchestration
- `src/kernel/proc/sched/scheduler.zig`: Round-robin per-CPU scheduler with preemption
- `src/kernel/mm/user_vmm.zig`: User address space management (VMAs, page fault handling)
- `src/kernel/sys/syscall/core/table.zig`: Comptime dispatch table for all syscalls

**Testing:**
- `src/user/test_runner/tests/`: 186 integration tests (filesystem, syscalls, process, stress)
- `scripts/run_tests.sh`: Test runner with multi-arch support and 90s timeout
- `.github/workflows/ci.yml`: GitHub Actions CI (runs on PR/push)

## Naming Conventions

**Files:**
- `root.zig`: Module root/public API (convention: re-exports submodules for clean import)
- `*.zig`: Zig source files
- `*.S`: Assembly files (preprocessed, can use constants)
- `*.ld`: Linker scripts
- `asm_helpers.S`: Architecture-specific assembly helpers (syscall entry, low-level ops)

**Functions:**
- `sys_<name>`: Syscall handler (e.g., `sys_read`, `sys_fork`, `sys_socket`)
- `init*`: Initialization functions (e.g., `initHypervisor`, `initIommu`)
- `handle*`: Event handler functions (e.g., `handlePageFault`, `handleSignal`)
- `get*`, `set*`: Property accessors/setters
- `create*`, `destroy*`: Resource lifecycle management
- `*Wrapper`: Callback wrapper functions (for passing function pointers)

**Variables:**
- `g_<name>`: Global variable (e.g., `g_controller` for global driver instance)
- `current_*`: Scheduler-related (e.g., `current_thread`, `current_process`)
- `MAX_*`: Upper bound constants
- `*_lock`: Synchronization primitives (RwLock, Spinlock, Mutex)

**Types:**
- `*Allocator`: Allocator interface
- `*Driver`: Device driver struct
- `*Controller`: Hardware controller struct
- `Thread`, `Process`: Core scheduling types
- `Vnode`, `Inode`: VFS abstraction types
- `SyscallError`: Union of error types (errno values)

## Where to Add New Code

**New Feature (e.g., signal delivery, new syscall):**
- Primary code: Place in appropriate subsystem directory
  - Signal delivery: `src/kernel/proc/process/signal.zig`
  - New syscall `sys_example`: `src/kernel/sys/syscall/<category>/example.zig` (or create category if needed)
- Tests: `src/user/test_runner/tests/syscall/` (for syscall tests) or `src/kernel/sys/syscall/tests/` (for unit tests)
- UAPI: If syscall needs constants, add to `src/uapi/syscalls/linux.zig` (x86_64) or `linux_aarch64.zig`

**New Component/Module:**
- Implementation: Choose appropriate subsystem directory (e.g., `src/drivers/<subsystem>/` for drivers)
- Public API: Create `root.zig` in module directory with re-exports
- Export from parent: Add import and re-export in parent's `root.zig`
- Example: Adding AHCI driver -> `src/drivers/storage/ahci/root.zig` -> imported/exported by `src/drivers/storage/root.zig`

**Utilities:**
- Shared kernel helpers: `src/lib/` (console, keyboard, panic, prng)
- Shared userspace helpers: `src/user/lib/` (libc, syscall wrappers)
- Architecture-specific helpers: `src/arch/<arch>/lib/` (I/O, utilities)

**Architecture-Specific Code:**
- Do NOT place in kernel core
- Use compile-time selection: `if (builtin.cpu.arch == .x86_64) ... else ...`
- Or use separate files in `src/arch/x86_64/` and `src/arch/aarch64/`
- Re-export via `src/arch/root.zig` for unified interface

## Special Directories

**`.zig-cache/`:**
- Purpose: Zig compiler incremental build cache
- Generated: Automatically by `zig build`
- Committed: No (in .gitignore)
- Action if corrupted: `rm -rf .zig-cache && zig build`

**`zig-out/`:**
- Purpose: Build output directory
- Generated: Automatically by `zig build`
- Contains: `kernel-x86_64.elf`, `kernel-aarch64.elf`, `bootx64.efi`, `bootaa64.efi`, ISO images
- Committed: No (in .gitignore)

**`test_output_*.log`:**
- Purpose: Full QEMU console output for test runs (not truncated)
- Generated: By `scripts/run_tests.sh`
- Contains: All kernel output, test results, debug logs
- Committed: No (generated at test time)

**`.planning/codebase/`:**
- Purpose: Analysis documents for code navigation and planning
- Contents: ARCHITECTURE.md, STRUCTURE.md, CONVENTIONS.md, TESTING.md, CONCERNS.md
- Committed: Yes (part of codebase documentation)

