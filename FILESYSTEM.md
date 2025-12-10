# ZigK Filesystem Structure

This structure mirrors the **Linux Kernel** organization while leveraging **Zig's** module system to enforce strict HAL layering.

## Current Implementation Status

```text
zigk/
├── build.zig                  # Master build logic (Zig 0.15.x)
├── build.zig.zon              # Dependencies
├── limine.cfg                 # Limine bootloader configuration
├── BOOT.md                    # Boot process documentation
├── BUILD.md                   # Build instructions
├── CLAUDE.md                  # AI assistant guidelines
├── FILESYSTEM.md              # This file
├── README.md                  # Project overview
├── specs/                     # Design documents
│   ├── 003-microkernel.../    # Microkernel, Userland, Networking
│   ├── 007-linux-compat.../   # Linux compatibility layer
│   ├── 009-spec-consistency/  # Spec unification
│   ├── archived/              # Superseded specs
│   ├── shared/                # Shared policies (zig-version, gotchas)
│   └── syscall-table.md       # Authoritative syscall numbers
├── tests/
│   ├── unit/                  # Unit tests
│   │   ├── main.zig           # Test runner
│   │   └── heap_fuzz.zig      # Allocator fuzzing
│   └── integration/           # Integration tests
└── src/
    ├── lib/                   # Kernel-agnostic libraries
    │   ├── limine.zig         # Limine boot protocol definitions
    │   ├── prng.zig           # Xoroshiro128+ PRNG
    │   └── ring_buffer.zig    # Generic comptime ring buffer
    │
    ├── uapi/                  # UserSpace API (Shared Headers)
    │   ├── root.zig           # UAPI module root
    │   ├── syscalls.zig       # Syscall numbers (Linux ABI)
    │   ├── errno.zig          # Linux-compatible error codes
    │   └── poll.zig           # Poll event definitions
    │
    ├── user/                  # Userland Runtime (Ring 3)
    │   ├── root.zig           # Module root
    │   ├── crt0.zig           # Entry point (_start)
    │   ├── linker.ld          # Userland linker script
    │   ├── lib/
    │   │   └── syscall.zig    # Syscall wrappers
    │   ├── shell/
    │   │   └── main.zig       # User shell application
    │   └── httpd/
    │       └── main.zig       # HTTP server application
    │
    ├── fs/                    # Filesystem Implementations
    │   ├── root.zig           # Module root
    │   └── initrd.zig         # Initial ramdisk (TAR format)
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
    │   ├── sync.zig           # Network synchronization
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
    │   │   ├── arp.zig        # ARP resolution
    │   │   └── reassembly.zig # IP fragment reassembly
    │   ├── dns/               # DNS Client
    │   │   ├── root.zig
    │   │   ├── dns.zig        # DNS protocol
    │   │   └── client.zig     # DNS resolver
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
    │           ├── control.zig
    │           └── errors.zig
    │
    ├── arch/                  # HAL - ONLY place for inline assembly
    │   ├── root.zig           # Architecture-agnostic HAL interface
    │   ├── x86_64/            # x86_64 Implementation
    │   │   ├── root.zig       # Exports
    │   │   ├── asm_helpers.S  # Assembly routines (lgdt, lidt, etc.)
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
    │   │   ├── syscall.zig    # SYSCALL/SYSRET setup
    │   │   └── acpi/          # ACPI Tables
    │   │       ├── root.zig
    │   │       ├── rsdp.zig   # Root System Description
    │   │       └── mcfg.zig   # PCI MCFG table
    │   └── aarch64/           # ARM64 Stub
    │       └── (placeholder)
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
        ├── framebuffer.zig    # Graphics (Limine framebuffer)
        ├── stack_guard.zig    # Stack protections
        ├── debug/
        │   └── console.zig    # Kernel console
        └── syscall/           # Syscall Implementations
            ├── handlers.zig   # Main dispatch logic
            ├── table.zig      # Syscall table
            ├── net.zig        # Network syscalls
            ├── random.zig     # Entropy syscalls
            └── user_mem.zig   # User memory validation
```

## Module Reference

### `src/net/` (Network Stack)
A device-independent TCP/IP stack implementing Layer 2 (Ethernet), Layer 3 (IPv4/ARP), and Layer 4 (UDP/TCP/ICMP).

| Submodule | Description |
|-----------|-------------|
| `core` | Defines `PacketBuffer`, `Interface`, and checksumming utilities. |
| `ethernet` | Handles Ethernet II frames. Dispatches to IPv4 or ARP based on EtherType. |
| `ipv4` | Handles IPv4 packet routing, validation, and fragment reassembly. |
| `dns` | DNS client for hostname resolution. |
| `transport` | Socket-based protocols: UDP datagrams, TCP streams, ICMP echo. |

### `src/fs/` (Filesystem)
| File | Description |
|------|-------------|
| `initrd.zig` | TAR-format initial ramdisk for loading files at boot. |

### `src/drivers/pci/` (PCI Subsystem)
| File | Description |
|------|-------------|
| `enumeration.zig` | Scans PCI bus/slot/function combinations. |
| `device.zig` | Defines `PCIDevice` struct and BAR parsing. |
| `ecam.zig` | PCIe Enhanced Configuration Access Mechanism. |

### `src/lib/` (Kernel Libraries)
| File | Description |
|------|-------------|
| `limine.zig` | Zig definitions for Limine Boot Protocol. |
| `prng.zig` | Xoroshiro128+ PRNG, seeded by `arch.entropy`. |
| `ring_buffer.zig` | Generic, thread-safe compile-time ring buffer. |

### `src/kernel/syscall/`
| File | Description |
|------|-------------|
| `handlers.zig` | Maps register values to kernel function calls. |
| `table.zig` | Function pointers indexed by syscall number. |
| `net.zig` | `socket`, `bind`, `connect`, `sendto`, `recvfrom`. |
| `random.zig` | `getrandom` (syscall 318). |
| `user_mem.zig` | Validates and copies user memory safely. |

## Key Design Principles

1. **Strict HAL Layering**: `src/arch` is the **only** location for `asm` blocks and direct hardware access.
2. **Separate Drivers/Stack**: Network drivers (`src/drivers/net`) are decoupled from protocols (`src/net`).
3. **Unified UAPI**: `src/uapi` is shared between kernel and userland for ABI compatibility.
4. **Limine Boot**: Primary bootloader is Limine v5.x.
