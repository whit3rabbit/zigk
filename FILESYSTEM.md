# ZigK Filesystem Structure

Based on the [latest complete file listing](./FILESYSTEM.md) as of 2025-12-08.
This structure mirrors the **Linux Kernel** organization to ensure familiarity for OS developers, while leveraging **Zig's** module system to enforce the strict HAL layering required by the Constitution.

## Current Implementation Status

```text
zigk/
├── build.zig                  # Master build logic (Zig 0.13.0+)
├── build.zig.zon              # Dependencies
├── BOOT.md                    # Boot process documentation
├── BUILD.md                   # Build instructions
├── FILESYSTEM.md              # This file
├── README.md                  # Project overview
├── Dockerfile                 # Docker build environment
├── docker-compose.yml         # Container orchestration
├── specs/                     # Design documents (Requirements, Contracts)
│   ├── 003-microkernel.../    # Active: Microkernel, Userland, Networking
│   ├── 007-linux-compat.../   # Active: Linux compatibility layer
│   ├── 009-spec-consistency/  # Active: Spec unification
│   ├── archived/              # Superseded specs
│   └── shared/                # Shared policies (zig-version, gotchas)
├── tests/
│   ├── unit/                  # Unit tests
│   │   ├── main.zig           # Test runner
│   │   └── heap_fuzz.zig      # Allocator fuzzing
│   └── integration/           # Integration tests
├── docs/                      # General documentation
└── src/
    ├── lib/                   # Kernel-agnostic libraries
    │   ├── limine.zig         # Limine boot protocol definitions
    │   ├── multiboot2.zig     # Multiboot2 header definitions
    │   ├── prng.zig           # Xoroshiro128+ PRNG
    │   └── ring_buffer.zig    # Generic comptime ring buffer
    │
    ├── uapi/                  # UserSpace API (Shared Headers)
    │   ├── root.zig           # UAPI module root
    │   ├── syscalls.zig       # Syscall numbers (Linux ABI)
    │   └── errno.zig          # Linux-compatible error codes
    │
    ├── user/                  # Userland Runtime (Ring 3)
    │   ├── root.zig           # Module root
    │   ├── crt0.zig           # Entry point (_start)
    │   ├── linker.ld          # Userland linker script
    │   ├── lib/
    │   │   └── syscall.zig    # Syscall wrappers
    │   └── shell/
    │       └── main.zig       # User shell application
    │
    ├── drivers/               # Device Drivers
    │   ├── keyboard.zig       # PS/2 keyboard driver
    │   ├── pci/               # PCI Subsystem
    │   │   ├── root.zig       # Module root
    │   │   ├── enumeration.zig# Bus scanning
    │   │   ├── ecam.zig       # PCIe ECAM access
    │   │   └── device.zig     # Device abstractions
    │   └── net/               # Network Drivers
    │       └── e1000e.zig     # Intel E1000e NIC driver
    │
    ├── net/                   # Network Stack (Protocol Layers)
    │   ├── root.zig           # Stack entry point
    │   ├── core/              # Core packet handling
    │   │   ├── root.zig
    │   │   ├── interface.zig  # Network interface management
    │   │   ├── packet.zig     # Packet buffer management
    │   │   └── checksum.zig   # IP/TCP/UDP checksums
    │   ├── ethernet/          # Ethernet Layer 2
    │   │   ├── root.zig
    │   │   └── ethernet.zig   # Frame parsing/building
    │   ├── ipv4/              # IPv4 Layer 3
    │   │   ├── root.zig
    │   │   ├── ipv4.zig       # Packet processing
    │   │   └── arp.zig        # ARP resolution
    │   └── transport/         # L4 Protocols
    │       ├── root.zig
    │       ├── udp.zig        # UDP implementation
    │       ├── icmp.zig       # ICMP (Ping)
    │       ├── tcp.zig        # TCP public wrapper
    │       ├── tcp/           # TCP internals
    │       │   ├── root.zig
    │       │   ├── api.zig
    │       │   ├── rx.zig
    │       │   ├── tx.zig
    │       │   ├── state.zig
    │       │   ├── timers.zig
    │       │   ├── options.zig
    │       │   ├── types.zig
    │       │   ├── constants.zig
    │       │   ├── checksum.zig
    │       │   └── errors.zig
    │       ├── socket.zig     # Socket public wrapper
    │       └── socket/        # Socket internals
    │           ├── root.zig
    │           ├── types.zig
    │           ├── state.zig
    │           ├── scheduler.zig
    │           ├── lifecycle.zig
    │           ├── udp_api.zig
    │           ├── tcp_api.zig
    │           ├── options.zig
    │           ├── poll.zig
    │           └── control.zig
    │
    ├── arch/                  # HAL - ONLY place for inline assembly
    │   ├── root.zig           # Architecture-agnostic HAL interface
    │   ├── x86_64/            # x86_64 Implementation
    │   │   ├── root.zig       # Exports
    │   │   ├── boot/          # Boot code
    │   │   │   ├── boot32.S   # Multiboot2 entry
    │   │   │   ├── linker.ld  # Kernel linker script
    │   │   │   └── grub.cfg   # GRUB configuration
    │   │   ├── asm_helpers.S  # Assembly routines
    │   │   ├── cpu.zig        # CPU features/control
    │   │   ├── serial.zig     # Serial port (UART)
    │   │   ├── debug.zig      # Debug facilities
    │   │   ├── entropy.zig    # RDRAND/RDTSC
    │   │   ├── fpu.zig        # FPU/SSE state
    │   │   ├── gdt.zig        # GDT setup
    │   │   ├── idt.zig        # IDT setup
    │   │   ├── interrupts.zig # ISRs
    │   │   ├── io.zig         # Port I/O
    │   │   ├── mmio.zig       # Memory Mapped I/O
    │   │   ├── paging.zig     # Page tables
    │   │   ├── pic.zig        # 8259 PIC
    │   │   └── syscall.zig    # SYSENTER/SYSEXIT setup
    │   └── aarch64/           # ARM64 Stub
    │       ├── boot/
    │       └── mm/
    │
    └── kernel/                # Core Kernel Subsystems
        ├── main.zig           # Kernel entry point
        ├── heap.zig           # Kernel heap allocator
        ├── pmm.zig            # Physical Memory Manager
        ├── vmm.zig            # Virtual Memory Manager
        ├── user_vmm.zig       # User address space management
        ├── thread.zig         # Threading support
        ├── process.zig        # Process management
        ├── sched.zig          # Scheduler
        ├── sync.zig           # Synchronization (Spinlocks)
        ├── fd.zig             # File Descriptors
        ├── devfs.zig          # Device Filesystem
        ├── elf.zig            # ELF Loader
        ├── framebuffer.zig    # Graphics (Limine/Multiboot)
        ├── stack_guard.zig    # Stack protections
        ├── debug/
        │   └── console.zig    # Kernel console
        └── syscall/           # Syscall Implementations
            ├── handlers.zig   # Main dispatch logic
            ├── table.zig      # Syscall table
            ├── net.zig        # Network syscalls
            └── random.zig     # Entropy syscalls
```

## Module Reference (Detailed)

### `src/net/` (Network Stack)
A device-independent TCP/IP stack implementing Layer 2 (Ethernet), Layer 3 (IPv4/ARP), and Layer 4 (UDP/TCP/ICMP).

| Submodule | Description |
|-----------|-------------|
| `core` | Defines `PacketBuffer`, `Interface`, and check-summing utilities. Manages the lifecycle of network packets. |
| `ethernet` | Handles Ethernet II frames. Dispatches packets to IPv4 or ARP based on EtherType. |
| `ipv4` | Handles IPv4 packet routing and validation. Manages the ARP cache for address resolution. |
| `transport` | Implements socket-based protocols. `udp.zig` handles datagrams, `icmp.zig` handles Echo Request/Reply. |

### `src/drivers/pci/` (PCI Subsystem)
Enumerates via legacy Port I/O (initially) or ECAM (future) to discover devices.

| File | Description |
|------|-------------|
| `enumeration.zig` | Scans PCI bus/slot/function combinations. |
| `device.zig` | Defines `PCIDevice` struct and BAR (Base Address Register) parsing. |
| `ecam.zig` | Support for PCIe Enhanced Configuration Access Mechanism. |

### `src/lib/` (Kernel Libraries)
Standalone libraries used by the kernel but not dependent on kernel internals.

| File | Description |
|------|-------------|
| `limine.zig` | Zig definitions for the Limine Boot Protocol requests and responses. |
| `multiboot2.zig` | Structs and tags for parsing the Multiboot2 information structure provided by GRUB. |
| `prng.zig` | `Xoroshiro128+` pseudo-random number generator, seeded by `arch.entropy`. |
| `ring_buffer.zig` | A generic, thread-safe (when used with locks) compile-time ring buffer. |

### `src/kernel/syscall/`
Architecture-independent handlers for system calls.

| File | Description |
|------|-------------|
| `handlers.zig` | Maps register values from `arch` to kernel function calls. |
| `table.zig` | Arrays of function pointers indexed by syscall number. |
| `net.zig` | Implements `socket`, `bind`, `connect`, `sendto`, `recvfrom`. |
| `random.zig` | Implements `getrandom` (syscall 318). |

## Key Design Principles

1.  **Strict HAL Layering**: The `src/arch` directory is the **only** allowed location for `asm` blocks and direct hardware register access. All other kernel code must use HAL abstractions.
2.  **Separate Drivers/Stack**: Network drivers (`src/drivers/net`) are decoupled from the protocol stack (`src/net`). They communicate via generic `Interface` and `PacketBuffer` structures.
3.  **Unified UAPI**: `src/uapi` is shared source code between the Kernel and Userland applications to guarantee ABI compatibility for struct definitions and constant values.
