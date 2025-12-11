# ZigK Filesystem Structure

This structure mirrors the Linux kernel organization while keeping Zig modules aligned to the HAL boundary.

## Current Implementation Status

```text
zigk/
├── AGENTS.md                # AI agent instructions
├── CLAUDE.md                # Assistant guidelines
├── README.md                # Project overview
├── build.zig                # Build graph (Zig 0.15.x)
├── build.zig.zon            # Dependencies
├── docs/                    # Project documentation
│   ├── BOOT.md              # Boot process
│   ├── BOOT_ARCHITECTURE.md # Limine + kernel handoff details
│   ├── BUILD.md             # Build and run instructions
│   └── FILESYSTEM.md        # This file
├── specs/                   # Design documents
│   ├── 003-microkernel-userland-networking/
│   ├── 007-linux-compat-layer/
│   ├── 009-spec-consistency-unification/
│   ├── archived/            # Superseded specs
│   ├── shared/              # Shared policies (zig version, gotchas)
│   ├── DEPENDENCY-ORDER.md  # Link/load ordering constraints
│   └── syscall-table.md     # Authoritative syscall numbers
├── tools/
│   └── docker-build.sh      # Container build helper
├── tests/
│   ├── unit/                # Kernel unit tests
│   │   ├── main.zig         # Test runner
│   │   └── heap_fuzz.zig    # Allocator fuzzing
│   └── userland/            # Syscall/user ABI validation (C)
│       ├── test_clock.c
│       ├── test_devnull.c
│       ├── test_random.c
│       ├── test_stdio.c
│       └── test_wait4.c
├── iso_root/                # ISO staging (Limine config + modules)
├── limine/                  # Limine bootloader binaries and headers
├── limine.cfg               # Bootloader configuration
├── options.o                # Zig build options cache
├── zig-out/                 # Build outputs
├── zigk.iso                 # Generated ISO image
└── src/
    ├── arch/                # HAL - ONLY place for inline assembly
    │   ├── root.zig         # Architecture-neutral HAL interface
    │   ├── x86_64/
    │   │   ├── root.zig
    │   │   ├── asm_helpers.S
    │   │   ├── boot/
    │   │   │   └── linker.ld
    │   │   ├── cpu.zig
    │   │   ├── serial.zig
    │   │   ├── debug.zig
    │   │   ├── entropy.zig
    │   │   ├── fpu.zig
    │   │   ├── gdt.zig
    │   │   ├── idt.zig
    │   │   ├── interrupts.zig
    │   │   ├── io.zig
    │   │   ├── mmio.zig
    │   │   ├── paging.zig
    │   │   ├── pic.zig
    │   │   ├── syscall.zig
    │   │   └── acpi/
    │   │       ├── root.zig
    │   │       ├── mcfg.zig
    │   │       └── rsdp.zig
    │   └── aarch64/          # Placeholder for future ARM64 HAL
    │       ├── boot/
    │       └── mm/
    │
    ├── kernel/
    │   ├── main.zig
    │   ├── heap.zig
    │   ├── pmm.zig
    │   ├── vmm.zig
    │   ├── user_vmm.zig
    │   ├── kernel_stack.zig
    │   ├── stack_guard.zig
    │   ├── thread.zig
    │   ├── process.zig
    │   ├── sched.zig
    │   ├── sync.zig
    │   ├── fd.zig
    │   ├── devfs.zig
    │   ├── elf.zig
    │   ├── framebuffer.zig
    │   ├── debug/
    │   │   └── console.zig
    │   └── syscall/
    │       ├── handlers.zig
    │       ├── table.zig
    │       ├── net.zig
    │       ├── random.zig
    │       └── user_mem.zig
    │
    ├── drivers/
    │   ├── keyboard.zig
    │   ├── net/
    │   │   └── e1000e.zig
    │   └── pci/
    │       ├── root.zig
    │       ├── enumeration.zig
    │       ├── ecam.zig
    │       └── device.zig
    │
    ├── fs/
    │   ├── root.zig
    │   └── initrd.zig
    │
    ├── lib/
    │   ├── limine.zig
    │   ├── list.zig
    │   ├── prng.zig
    │   └── ring_buffer.zig
    │
    ├── net/
    │   ├── root.zig
    │   ├── sync.zig
    │   ├── core/
    │   │   ├── root.zig
    │   │   ├── interface.zig
    │   │   ├── packet.zig
    │   │   └── checksum.zig
    │   ├── ethernet/
    │   │   ├── root.zig
    │   │   └── ethernet.zig
    │   ├── ipv4/
    │   │   ├── root.zig
    │   │   ├── arp.zig
    │   │   ├── ipv4.zig
    │   │   └── reassembly.zig
    │   ├── dns/
    │   │   ├── root.zig
    │   │   ├── dns.zig
    │   │   └── client.zig
    │   └── transport/
    │       ├── root.zig
    │       ├── udp.zig
    │       ├── icmp.zig
    │       ├── tcp.zig
    │       ├── tcp/
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
    │       ├── socket.zig
    │       └── socket/
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
    ├── uapi/
    │   ├── root.zig
    │   ├── syscalls.zig
    │   ├── errno.zig
    │   └── poll.zig
    │
    └── user/
        ├── root.zig
        ├── crt0.zig
        ├── linker.ld
        ├── lib/
        │   └── syscall.zig
        ├── shell/
        │   └── main.zig
        └── httpd/
            └── main.zig
```

## Module Reference

### `src/kernel/`
| File | Description |
|------|-------------|
| `main.zig` | Kernel entry; wires Limine handoff into memory, driver, and scheduler bring-up. |
| `heap.zig` | Kernel heap allocator. |
| `pmm.zig` | Physical memory manager. |
| `vmm.zig` | Page table manager (map/unmap helpers). |
| `user_vmm.zig` | User address space creation and cloning. |
| `kernel_stack.zig` | Guarded kernel stack allocator in a dedicated VA range (unmapped guard pages). |
| `stack_guard.zig` | Guard page protections shared across stacks. |
| `thread.zig` | Thread creation and context management. |
| `process.zig` | Process lifecycle and address space wiring. |
| `sched.zig` | Scheduler core. |
| `sync.zig` | Spinlocks and synchronization helpers. |
| `fd.zig` | File descriptor table logic. |
| `devfs.zig` | Device filesystem. |
| `elf.zig` | ELF loader. |
| `framebuffer.zig` | Limine framebuffer setup. |
| `debug/console.zig` | Kernel console output. |

### `src/kernel/syscall/`
| File | Description |
|------|-------------|
| `handlers.zig` | Maps register values to kernel syscall handlers. |
| `table.zig` | Function pointers indexed by syscall number. |
| `net.zig` | `socket`, `bind`, `connect`, `sendto`, `recvfrom`. |
| `random.zig` | `getrandom` (syscall 318). |
| `user_mem.zig` | Validates and copies user memory safely. |

### `src/net/` (Network Stack)
A device-independent TCP/IP stack implementing Ethernet, IPv4/ARP, DNS, and socket-based UDP/TCP/ICMP.

| Submodule | Description |
|-----------|-------------|
| `core` | Packet buffers, interfaces, and checksumming utilities. |
| `ethernet` | Ethernet II framing and dispatch. |
| `ipv4` | IPv4 validation, ARP resolution, and fragment reassembly. |
| `dns` | DNS client and resolver. |
| `transport` | UDP datagrams, TCP streams, ICMP echo, and socket plumbing. |

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
| `list.zig` | Intrusive doubly linked list for scheduler and queues. |
| `prng.zig` | Xoroshiro128+ PRNG, seeded by `arch.entropy`. |
| `ring_buffer.zig` | Generic, thread-safe compile-time ring buffer. |

### `src/uapi/` (Shared Kernel/User ABI)
| File | Description |
|------|-------------|
| `root.zig` | UAPI module root. |
| `syscalls.zig` | Syscall numbers (Linux ABI). |
| `errno.zig` | Linux-compatible error codes. |
| `poll.zig` | Poll event definitions. |

### `src/user/` (Userland Runtime)
| File | Description |
|------|-------------|
| `crt0.zig` | Userland entry point (`_start`). |
| `linker.ld` | Userland linker script. |
| `lib/syscall.zig` | Syscall wrappers. |
| `shell/main.zig` | Shell application. |
| `httpd/main.zig` | HTTP server application. |

## Key Design Principles

1. **Strict HAL Layering**: `src/arch` is the **only** location for `asm` blocks and direct hardware access.
2. **Separate Drivers/Stack**: Network drivers (`src/drivers/net`) are decoupled from protocols (`src/net`).
3. **Unified UAPI**: `src/uapi` is shared between kernel and userland for ABI compatibility.
4. **Limine Boot**: Primary bootloader is Limine v5.x.
