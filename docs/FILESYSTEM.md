# Zscapek Filesystem Structure

This structure mirrors the Linux kernel organization while keeping Zig modules aligned to the HAL boundary.

## Current Implementation Status

```text
zscapek/
├── .github/
│   └── workflows/
│       └── build-iso.yml     # GitHub Actions workflow to build release ISO
├── AGENTS.md                # Symlink to CLAUDE.md
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
│   ├── DOOM.md              # DOOM port documentation
│   ├── FILESYSTEM.md        # This file
│   ├── GRAPHICS.md          # Framebuffer/console details
│   ├── KEYBOARD.md          # Keyboard input (PS/2 and USB)
│   ├── network.md           # Network stack design
│   └── SYSCALL.md           # Syscall implementation guide
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
│   │   ├── msi_allocator_test.zig # MSI allocator tests
│   │   ├── vmm_test.zig     # VMM unit coverage
│   │   └── tcp_types_test.zig # TCP type packing/endianness tests
│   ├── userland/            # Syscall/user ABI validation (C/Zig)
│   │   ├── test_clock.c
│   │   ├── test_devnull.c
│   │   ├── test_random.c
│   │   ├── test_stdio.c
│   │   ├── test_wait4.c
│   │   ├── test_writev.zig
│   │   └── soak_test.zig    # Long-running syscall soak test
│   ├── integration/         # Integration tests (placeholder)
│   └── scripts/
│       └── fuzz_packets.py  # Network fuzzer harness
├── initrd_contents/         # InitRD source files
├── initrd.tar               # Generated USTAR initrd
├── iso_root/                # ISO staging (Limine config + modules)
├── limine/                  # Limine bootloader binaries and headers
├── limine.cfg               # Bootloader configuration
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
    │   │   ├── pit.zig
    │   │   ├── smp.zig
    │   │   ├── syscall.zig
    │   │   ├── timing.zig
    │   │   ├── acpi/
    │   │   │   ├── root.zig
    │   │   │   ├── madt.zig
    │   │   │   ├── mcfg.zig
    │   │   │   └── rsdp.zig
    │   │   └── apic/
    │   │       ├── root.zig
    │   │       ├── ioapic.zig
    │   │       └── lapic.zig
    │   └── aarch64/          # Placeholder for future ARM64 HAL
    │       ├── boot/
    │       └── mm/
    │
    ├── kernel/
    │   ├── main.zig
    │   ├── boot.zig
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
    │   ├── signal.zig
    │   ├── pipe.zig
    │   ├── panic.zig
    │   ├── fd.zig
    │   ├── devfs.zig
    │   ├── elf.zig
    │   ├── framebuffer.zig
    │   ├── init_mem.zig
    │   ├── init_hw.zig
    │   ├── init_fs.zig
    │   ├── init_proc.zig
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
    │       ├── input.zig
    │       └── user_mem.zig
    │
    ├── drivers/
    │   ├── keyboard.zig
    │   ├── mouse.zig
    │   ├── audio/
    │   │   ├── root.zig
    │   │   └── ac97.zig
    │   ├── input/
    │   │   ├── root.zig
    │   │   ├── cursor.zig
    │   │   ├── keyboard_layout.zig
    │   │   ├── layout.zig
    │   │   └── layouts/
    │   │       ├── dvorak.zig
    │   │       └── us.zig
    │   ├── net/
    │   │   └── e1000e/
    │   │       ├── root.zig
    │   │       ├── config.zig
    │   │       ├── ctl.zig
    │   │       ├── desc.zig
    │   │       ├── pool.zig
    │   │       ├── regs.zig
    │   │       ├── rx.zig
    │   │       └── tx.zig
    │   ├── pci/
    │   │   ├── root.zig
    │   │   ├── access.zig
    │   │   ├── enumeration.zig
    │   │   ├── ecam.zig
    │   │   ├── capabilities.zig
    │   │   ├── device.zig
    │   │   ├── legacy.zig
    │   │   └── msi.zig
    │   ├── serial/
    │   │   └── uart.zig
    │   ├── storage/
    │   │   └── ahci/
    │   │       ├── root.zig
    │   │       ├── adapter.zig
    │   │       ├── hba.zig
    │   │       ├── port.zig
    │   │       ├── command.zig
    │   │       └── fis.zig
    │   ├── usb/
    │   │   ├── root.zig
    │   │   ├── types.zig
    │   │   ├── class/
    │   │   │   └── hid.zig
    │   │   ├── ehci/
    │   │   │   ├── root.zig
    │   │   │   └── regs.zig
    │   │   └── xhci/
    │   │       ├── root.zig
    │   │       ├── context.zig
    │   │       ├── device.zig
    │   │       ├── regs.zig
    │   │       ├── ring.zig
    │   │       ├── transfer.zig
    │   │       └── trb.zig
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
    │   ├── initrd.zig
    │   ├── vfs.zig
    │   ├── sfs.zig
    │   └── partitions/
    │       ├── root.zig
    │       ├── gpt.zig
    │       └── mbr.zig
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
    │   ├── loopback.zig
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
    │   ├── poll.zig
    │   ├── dirent.zig
    │   ├── input.zig
    │   ├── mman.zig
    │   ├── signal.zig
    │   ├── sound.zig
    │   └── stat.zig
    │
    └── user/
        ├── root.zig
        ├── crt0.zig
        ├── linker.ld
        ├── audio_test.zig
        ├── test_asm.zig
        ├── lib/
        │   ├── syscall.zig
        │   ├── syscall_exports.zig
        │   └── libc/
        │       ├── root.zig
        │       ├── ctype.zig
        │       ├── errno.zig
        │       ├── internal.zig
        │       ├── stubs.zig
        │       ├── time.zig
        │       ├── memory/
        │       │   ├── root.zig
        │       │   └── allocator.zig
        │       ├── stdio/
        │       │   ├── root.zig
        │       │   ├── file.zig
        │       │   ├── format.zig
        │       │   ├── fprintf.zig
        │       │   ├── printf.zig
        │       │   ├── sscanf.zig
        │       │   ├── streams.zig
        │       │   └── vprintf.zig
        │       ├── stdlib/
        │       │   ├── root.zig
        │       │   ├── convert.zig
        │       │   ├── env.zig
        │       │   ├── math.zig
        │       │   ├── process.zig
        │       │   ├── random.zig
        │       │   └── sort.zig
        │       ├── string/
        │       │   ├── root.zig
        │       │   ├── case.zig
        │       │   ├── concat.zig
        │       │   ├── error.zig
        │       │   ├── mem.zig
        │       │   ├── search.zig
        │       │   ├── str.zig
        │       │   └── tokenize.zig
        │       └── unistd/
        │           └── root.zig
        ├── shell/
        │   └── main.zig
        ├── httpd/
        │   └── main.zig
        └── doom/
            ├── main.zig
            ├── doomgeneric_zscapek.zig
            ├── i_sound_stub.zig
            └── doomgeneric/
                └── (C source files for DOOM port)
```

## Module Reference

### `src/kernel/`
| File | Description |
|------|-------------|
| `main.zig` | Kernel entry; wires Limine handoff into memory, driver, and scheduler bring-up. |
| `boot.zig` | Boot-time initialization sequencing. |
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
| `signal.zig` | Signal delivery and handling infrastructure. |
| `pipe.zig` | Pipe implementation for IPC. |
| `panic.zig` | Kernel panic handling. |
| `fd.zig` | File descriptor table logic. |
| `devfs.zig` | Device filesystem. |
| `elf.zig` | ELF loader. |
| `framebuffer.zig` | Limine framebuffer setup. |
| `init_mem.zig` | Memory subsystem initialization. |
| `init_hw.zig` | Hardware initialization (drivers, interrupts). |
| `init_fs.zig` | Filesystem initialization. |
| `init_proc.zig` | Process subsystem initialization. |
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
| `custom.zig` | Zscapek extensions (`debug_log`, `putchar`, `getchar`, `read_scancode`). |
| `net.zig` | `socket`, `bind`, `listen`, `accept`, `connect`, `sendto`, `recvfrom`. |
| `random.zig` | `getrandom` (syscall 318). |
| `input.zig` | Input device syscalls (keyboard, mouse). |
| `user_mem.zig` | Validates and copies user memory safely. |

### `src/arch/x86_64/`
| File | Description |
|------|-------------|
| `root.zig` | x86_64 HAL exports. |
| `cpu.zig` | CPU feature detection and control. |
| `serial.zig` | Serial port output. |
| `debug.zig` | Debug utilities. |
| `entropy.zig` | Hardware entropy (RDRAND/RDSEED). |
| `fpu.zig` | FPU/SSE state management. |
| `gdt.zig` | Global Descriptor Table. |
| `idt.zig` | Interrupt Descriptor Table. |
| `interrupts.zig` | Interrupt handlers. |
| `io.zig` | Port I/O. |
| `mmio.zig` | Memory-mapped I/O. |
| `paging.zig` | Page table management. |
| `pic.zig` | Legacy 8259 PIC. |
| `pit.zig` | Programmable Interval Timer. |
| `smp.zig` | Symmetric Multi-Processing support. |
| `syscall.zig` | Syscall entry/exit. |
| `timing.zig` | High-resolution timing (TSC, HPET). |
| `acpi/root.zig` | ACPI table parsing entry. |
| `acpi/rsdp.zig` | RSDP/XSDP discovery. |
| `acpi/mcfg.zig` | MCFG table (PCIe config space). |
| `acpi/madt.zig` | MADT table (APIC configuration). |
| `apic/root.zig` | APIC subsystem exports. |
| `apic/lapic.zig` | Local APIC driver. |
| `apic/ioapic.zig` | I/O APIC driver. |

### `src/net/` (Network Stack)
A device-independent TCP/IP stack implementing Ethernet, IPv4/ARP, DNS, and socket-based UDP/TCP/ICMP.

| Submodule | Description |
|-----------|-------------|
| `core` | Packet buffers, interfaces, and checksumming utilities. |
| `ethernet` | Ethernet II framing and dispatch. |
| `ipv4` | IPv4 validation, ARP resolution, PMTU discovery, and fragment reassembly. |
| `dns` | DNS client and resolver. |
| `transport` | UDP datagrams, TCP streams, ICMP echo, and socket plumbing. |
| `loopback.zig` | Loopback interface (127.0.0.1). |

### `src/fs/` (Filesystem)
| File | Description |
|------|-------------|
| `root.zig` | Filesystem registry and init hooks. |
| `initrd.zig` | TAR-format initial ramdisk for loading files at boot. |
| `vfs.zig` | Virtual filesystem layer. |
| `sfs.zig` | Simple filesystem implementation. |
| `partitions/root.zig` | Partition table detection. |
| `partitions/gpt.zig` | GPT partition parsing. |
| `partitions/mbr.zig` | MBR partition parsing. |

### `src/drivers/pci/` (PCI Subsystem)
| File | Description |
|------|-------------|
| `root.zig` | PCI subsystem root. |
| `access.zig` | PCI config space access abstraction. |
| `enumeration.zig` | Scans PCI bus/slot/function combinations. |
| `device.zig` | Defines `PCIDevice` struct and BAR parsing. |
| `ecam.zig` | PCIe Enhanced Configuration Access Mechanism. |
| `legacy.zig` | Legacy PCI config space access (I/O ports). |
| `capabilities.zig` | Capability list parsing helpers. |
| `msi.zig` | MSI/MSI-X setup helpers. |

### `src/drivers/storage/ahci/` (SATA)
| File | Description |
|------|-------------|
| `root.zig` | AHCI driver entry and HBA discovery. |
| `adapter.zig` | AHCI adapter/controller abstraction. |
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

### `src/drivers/net/e1000e/`
| File | Description |
|------|-------------|
| `root.zig` | E1000e driver entry point and NIC initialization. |
| `config.zig` | Device configuration constants. |
| `ctl.zig` | Control register operations. |
| `desc.zig` | Descriptor ring structures. |
| `pool.zig` | Buffer pool management. |
| `regs.zig` | Register definitions. |
| `rx.zig` | Receive path handling. |
| `tx.zig` | Transmit path handling. |

### `src/drivers/audio/`
| File | Description |
|------|-------------|
| `root.zig` | Audio subsystem entry. |
| `ac97.zig` | AC'97 audio codec driver. |

### `src/drivers/input/`
| File | Description |
|------|-------------|
| `root.zig` | Input subsystem entry. |
| `cursor.zig` | Mouse cursor rendering. |
| `keyboard_layout.zig` | Keymap tables. |
| `layout.zig` | Layout selection and lookup. |
| `layouts/dvorak.zig` | Dvorak keyboard layout. |
| `layouts/us.zig` | US QWERTY keyboard layout. |

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
| `class/hid.zig` | USB HID class driver (keyboard/mouse). |
| `ehci/root.zig` | EHCI (USB 2.0) host controller driver. |
| `ehci/regs.zig` | EHCI register definitions. |
| `xhci/root.zig` | XHCI (USB 3.x) host controller driver. |
| `xhci/context.zig` | XHCI device context structures. |
| `xhci/device.zig` | XHCI device management. |
| `xhci/regs.zig` | XHCI register definitions. |
| `xhci/ring.zig` | XHCI ring buffer implementation. |
| `xhci/transfer.zig` | XHCI transfer handling. |
| `xhci/trb.zig` | Transfer Request Block definitions. |

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
| `dirent.zig` | Directory entry structures. |
| `input.zig` | Input event structures. |
| `mman.zig` | Memory mapping flags and constants. |
| `signal.zig` | Signal definitions and structures. |
| `sound.zig` | Audio IOCTL definitions. |
| `stat.zig` | File stat structures. |

### `src/user/` (Userland Runtime)
| File | Description |
|------|-------------|
| `root.zig` | User module exports. |
| `crt0.zig` | Userland entry point (`_start`). |
| `linker.ld` | Userland linker script. |
| `audio_test.zig` | Audio playback test application. |
| `test_asm.zig` | Minimal assembly sanity test program. |
| `lib/syscall.zig` | Syscall wrappers. |
| `lib/syscall_exports.zig` | Exported syscall symbols for libc. |
| `lib/libc/` | Minimal libc implementation for C program support. |
| `shell/main.zig` | Shell application. |
| `httpd/main.zig` | HTTP server application. |
| `doom/` | DOOM game port (doomgeneric). |

### `src/user/lib/libc/` (Minimal libc)
| Submodule | Description |
|-----------|-------------|
| `memory/` | malloc/free/realloc wrappers over mmap. |
| `stdio/` | File I/O, printf family, sscanf. |
| `stdlib/` | atoi, rand, qsort, environment. |
| `string/` | memcpy, strlen, strcpy, strstr, etc. |
| `unistd/` | POSIX wrappers (read, write, close). |
| `ctype.zig` | Character classification (isalpha, isdigit). |
| `errno.zig` | errno handling. |
| `time.zig` | time() and clock functions. |
| `stubs.zig` | Unimplemented function stubs. |

## Key Design Principles

1. **Strict HAL Layering**: `src/arch` is the **only** location for `asm` blocks and direct hardware access.
2. **Separate Drivers/Stack**: Network drivers (`src/drivers/net`) are decoupled from protocols (`src/net`).
3. **Unified UAPI**: `src/uapi` is shared between kernel and userland for ABI compatibility.
4. **Limine Boot**: Primary bootloader is Limine v5.x.
5. **Modular Initialization**: Boot sequence split into `init_mem.zig`, `init_hw.zig`, `init_fs.zig`, `init_proc.zig`.
