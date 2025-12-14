# Zscapek Filesystem Structure

This structure mirrors the Linux kernel organization while keeping Zig modules aligned to the HAL boundary.

## Current Implementation Status

```text
zscapek/
├── .github/
│   └── workflows/
│       └── build-iso.yml     # GitHub Actions workflow to build release ISO
├── AGENTS.md                # AI agent instructions
├── CLAUDE.md                # Assistant guidelines
├── README.md                # Project overview
├── build.zig                # Build graph (Zig 0.15.x)
├── build.zig.zon            # Dependencies
├── Dockerfile               # Container build (local toolchain)
├── docker-compose.yml       # Compose helper for reproducible builds
├── docs/                    # Project documentation
│   ├── BOOT.md              # Boot process
│   ├── BOOT_ARCHITECTURE.md # Limine + kernel handoff details
│   ├── BUILD.md             # Build and run instructions
│   ├── FILESYSTEM.md        # This file
│   ├── GRAPHICS.md          # Framebuffer/console details
│   └── network.md           # Network stack design
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
│   │   ├── heap_fuzz.zig    # Allocator fuzzing
│   │   ├── vmm_test.zig     # VMM unit coverage
│   │   └── tcp_types_test.zig # TCP type packing/endianness tests
│   ├── userland/            # Syscall/user ABI validation (C/Zig)
│   │   ├── test_clock.c
│   │   ├── test_devnull.c
│   │   ├── test_random.c
│   │   ├── test_stdio.c
│   │   ├── test_wait4.c
│   │   └── soak_test.zig    # Long-running syscall soak test
│   └── scripts/
│       └── fuzz_packets.py  # Network fuzzer harness
├── iso_root/                # ISO staging (Limine config + modules)
├── limine/                  # Limine bootloader binaries and headers
├── limine.cfg               # Bootloader configuration
├── options.o                # Zig build options cache
├── zig-out/                 # Build outputs
├── zscapek.iso              # Generated ISO image
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
    │   ├── dma_allocator.zig
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
    │       ├── base.zig
    │       ├── table.zig
    │       ├── process.zig
    │       ├── signals.zig
    │       ├── scheduling.zig
    │       ├── io.zig
    │       ├── fd.zig
    │       ├── memory.zig
    │       ├── execution.zig
    │       ├── custom.zig
    │       ├── net.zig
    │       ├── random.zig
    │       └── user_mem.zig
    │
    ├── drivers/
    │   ├── keyboard.zig
    │   ├── mouse.zig
    │   ├── input/
    │   │   ├── keyboard_layout.zig
    │   │   └── layout.zig
    │   ├── net/
    │   │   └── e1000e.zig
    │   ├── pci/
    │   │   ├── root.zig
    │   │   ├── enumeration.zig
    │   │   ├── ecam.zig
    │   │   ├── capabilities.zig
    │   │   ├── device.zig
    │   │   └── msi.zig
    │   ├── serial/
    │   │   └── uart.zig
    │   ├── storage/
    │   │   └── ahci/
    │   │       ├── root.zig
    │   │       ├── hba.zig
    │   │       ├── port.zig
    │   │       ├── command.zig
    │   │       └── fis.zig
    │   ├── usb/
    │   │   ├── root.zig
    │   │   └── types.zig
    │   ├── video/
    │   │   ├── root.zig
    │   │   ├── interface.zig
    │   │   ├── framebuffer.zig
    │   │   ├── console.zig
    │   │   ├── ansi.zig
    │   │   ├── font.zig
    │   │   ├── virtio_gpu.zig
    │   │   └── font/
    │   │       ├── psf.zig
    │   │       └── types.zig
    │   └── virtio/
    │       ├── root.zig
    │       └── common.zig
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
    │   │   ├── pmtu.zig
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
    │   ├── abi.zig
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
        ├── test_asm.zig
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
| `dma_allocator.zig` | DMA-safe allocator for page-aligned, device-visible buffers. |
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
| `base.zig` | Shared state (current_process, fd_table, user_vmm) and accessors. |
| `table.zig` | Comptime dispatch table - auto-discovers handlers via reflection. |
| `process.zig` | `exit`, `wait4`, `getpid`, `getppid`, `getuid`, `getgid`. |
| `signals.zig` | `rt_sigprocmask`, `rt_sigaction`, `rt_sigreturn`, `set_tid_address`. |
| `scheduling.zig` | `sched_yield`, `nanosleep`, `select`, `clock_gettime`. |
| `io.zig` | `read`, `write`, `writev`, `stat`, `fstat`, `ioctl`, `fcntl`, `getcwd`. |
| `fd.zig` | `open`, `close`, `dup`, `dup2`, `pipe`, `lseek`. |
| `memory.zig` | `mmap`, `mprotect`, `munmap`, `brk`. |
| `execution.zig` | `fork`, `execve`, `arch_prctl`, `get_fb_info`, `map_fb`. |
| `custom.zig` | `debug_log`, `putchar`, `getchar`, `read_scancode`. |
| `net.zig` | `socket`, `bind`, `listen`, `accept`, `connect`, `sendto`, `recvfrom`. |
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
| `root.zig` | Filesystem registry and init hooks. |
| `initrd.zig` | TAR-format initial ramdisk for loading files at boot. |

### `src/drivers/pci/` (PCI Subsystem)
| File | Description |
|------|-------------|
| `root.zig` | PCI subsystem root. |
| `enumeration.zig` | Scans PCI bus/slot/function combinations. |
| `device.zig` | Defines `PCIDevice` struct and BAR parsing. |
| `ecam.zig` | PCIe Enhanced Configuration Access Mechanism. |
| `capabilities.zig` | Capability list parsing helpers. |
| `msi.zig` | MSI/MSI-X setup helpers. |

### `src/drivers/storage/ahci/` (SATA)
| File | Description |
|------|-------------|
| `root.zig` | AHCI driver entry and HBA discovery. |
| `hba.zig` | HBA register definitions and init helpers. |
| `port.zig` | Port bring-up, command submission, and IRQ handling. |
| `command.zig` | Command header/table composition. |
| `fis.zig` | SATA FIS structures for command/result exchange. |

### `src/drivers/video/` (Display Console)
| File | Description |
|------|-------------|
| `root.zig` | Video driver registry. |
| `interface.zig` | Driver-neutral interface for console backends. |
| `framebuffer.zig` | Framebuffer abstraction and modes. |
| `console.zig` | Double-buffered console implementation. |
| `ansi.zig` | ANSI escape parsing. |
| `font.zig` | Font loader/renderer wiring. |
| `font/psf.zig` | PSF font parsing. |
| `font/types.zig` | PSF font types. |
| `virtio_gpu.zig` | Virtio-GPU driver for paravirtualized output. |

### `src/drivers/net/`
| File | Description |
|------|-------------|
| `e1000e.zig` | Intel e1000e PCIe network driver with RX/TX rings. |

### `src/drivers/input/`
| File | Description |
|------|-------------|
| `keyboard_layout.zig` | Keymap tables. |
| `layout.zig` | Layout selection and lookup. |

### `src/drivers/` (top-level device entries)
| File | Description |
|------|-------------|
| `keyboard.zig` | PS/2 keyboard driver entry. |
| `mouse.zig` | PS/2 mouse driver entry. |

### `src/drivers/serial/`
| File | Description |
|------|-------------|
| `uart.zig` | 16550-compatible UART driver (serial console). |

### `src/drivers/usb/`
| File | Description |
|------|-------------|
| `root.zig` | USB stack scaffold. |
| `types.zig` | Shared USB descriptor/types. |

### `src/drivers/virtio/`
| File | Description |
|------|-------------|
| `root.zig` | Virtio driver registry. |
| `common.zig` | Virtio queue setup and feature negotiation helpers. |

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
| `abi.zig` | ABI layouts shared with userland. |
| `errno.zig` | Linux-compatible error codes. |
| `poll.zig` | Poll event definitions. |

### `src/user/` (Userland Runtime)
| File | Description |
|------|-------------|
| `crt0.zig` | Userland entry point (`_start`). |
| `linker.ld` | Userland linker script. |
| `lib/syscall.zig` | Syscall wrappers. |
| `shell/main.zig` | Shell application. |
| `test_asm.zig` | Minimal assembly sanity test program. |
| `httpd/main.zig` | HTTP server application. |

## Key Design Principles

1. **Strict HAL Layering**: `src/arch` is the **only** location for `asm` blocks and direct hardware access.
2. **Separate Drivers/Stack**: Network drivers (`src/drivers/net`) are decoupled from protocols (`src/net`).
3. **Unified UAPI**: `src/uapi` is shared between kernel and userland for ABI compatibility.
4. **Limine Boot**: Primary bootloader is Limine v5.x.
