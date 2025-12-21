# Zscapek Filesystem Structure

This structure mirrors the Linux kernel organization while keeping Zig modules aligned to the HAL boundary.

## Current Implementation Status

zscapek/
├── .claude/
│   ├── commands/            # Codex CLI command definitions
│   └── hooks/               # Local automation hooks
├── .dockerignore            # Docker ignore rules
├── .github/
│   └── workflows/
│       └── build-iso.yml     # GitHub Actions workflow to build release ISO
├── .gitignore
├── AGENTS.md                # Symlink to CLAUDE.md
├── CLAUDE.md                # Assistant guidelines
├── README.md                # Project overview
├── REFACTORED.md            # Refactor notes
├── TODO.md                  # Project task list
├── build.zig                # Build graph (Zig 0.16.x)
├── build.zig.snippet        # Build snippet for local experiments
├── build.zig.zon            # Dependencies
├── Dockerfile               # Container build (local toolchain)
├── docker-compose.yml       # Compose helper for reproducible builds
├── kernel_build.sh          # Local build helper
├── docs/                    # Project documentation
│   ├── ASYNC.md             # Async I/O and io_uring design
│   ├── BOOT.md              # Boot process
│   ├── BOOT_ARCHITECTURE.md # Limine + kernel handoff details
│   ├── BUILD.md             # Build and run instructions
│   ├── DOOM.md              # DOOM port documentation
│   ├── DRIVERS.md           # Driver development guide
│   ├── FILESYSTEM.md        # This file
│   ├── GRAPHICS.md          # Framebuffer/console details
│   ├── KEYBOARD.md          # Keyboard input (PS/2 and USB)
│   ├── network.md           # Network stack design
│   └── SYSCALL.md           # Syscall implementation guide
├── tools/
│   └── docker-build.sh      # Container build helper
├── tests/
│   ├── unit/                # Kernel unit tests
│   │   ├── main.zig         # Test runner
│   │   ├── heap_fuzz.zig    # Allocator fuzzing
│   │   ├── ipv4_reassembly.zig # IPv4 fragment reassembly tests
│   │   ├── slab_bench.zig   # Slab allocator micro-benchmark
│   │   ├── msi_allocator_test.zig # MSI allocator tests
│   │   ├── vmm_test.zig     # VMM unit coverage
│   │   └── tcp_types_test.zig # TCP type packing/endianness tests
│   ├── userland/            # Syscall/user ABI validation (C/Zig)
│   │   ├── test_clock.c
│   │   ├── test_devnull.c
│   │   ├── test_libc_fix.c
│   │   ├── test_libc_fixes.c
│   │   ├── test_libc_runner.zig
│   │   ├── test_random.c
│   │   ├── test_signals_fpu.c
│   │   ├── test_stdio.c
│   │   ├── test_threads.c
│   │   ├── test_vdso.c
│   │   ├── test_wait4.c
│   │   ├── test_writev.zig
│   │   └── soak_test.zig    # Long-running syscall soak test
│   ├── integration/         # Integration tests (placeholder)
│   └── scripts/
│       └── fuzz_packets.py  # Network fuzzer harness
├── initrd_contents/         # InitRD source files
├── limine/                  # Limine bootloader binaries and headers
├── limine.cfg               # Bootloader configuration
└── src/
    ├── arch/                # HAL - ONLY place for inline assembly
    │   ├── root.zig         # Architecture-neutral HAL interface
    │   ├── x86_64/
    │   │   ├── root.zig
    │   │   ├── asm_helpers.S
    │   │   ├── mem.zig
    │   │   ├── memcpy.S
    │   │   ├── smp_trampoline.S
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
    │   │   ├── mmio_device.zig
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
    │   │       ├── ipi.zig
    │   │       └── lapic.zig
    │   └── aarch64/          # Placeholder for future ARM64 HAL
    │       ├── boot/
    │       └── mm/
    │
    ├── kernel/
    │   ├── core/         # Boot, Main, Sync, Init, ELF, Debug
    │   │   ├── root.zig
    │   │   ├── main.zig
    │   │   ├── boot.zig
    │   │   ├── init_hw.zig
    │   │   ├── init_mem.zig
    │   │   ├── init_fs.zig
    │   │   ├── init_proc.zig
    │   │   ├── panic.zig
    │   │   ├── sync.zig
    │   │   ├── stack_guard.zig
    │   │   ├── debug/
    │   │   │   └── console.zig
    │   │   └── elf/
    │   │       ├── root.zig
    │   │       ├── loader.zig
    │   │       ├── types.zig
    │   │       └── validation.zig
    │   ├── mm/           # PMM, VMM, Heap, slab, IOMMU, ASLR
    │   │   ├── root.zig
    │   │   ├── pmm.zig
    │   │   ├── vmm.zig
    │   │   ├── user_vmm.zig
    │   │   ├── heap.zig
    │   │   ├── slab.zig
    │   │   ├── dma_allocator.zig
    │   │   ├── aslr.zig
    │   │   ├── tlb.zig
    │   │   ├── kernel_stack.zig
    │   │   └── iommu/
    │   │       ├── root.zig
    │   │       └── domain.zig
    │   ├── proc/         # Sched, Process, Thread, Signal, Futex, IPC
    │   │   ├── root.zig
    │   │   ├── thread.zig
    │   │   ├── signal.zig
    │   │   ├── futex.zig
    │   │   ├── perms.zig
    │   │   ├── ring.zig
    │   │   ├── sched/
    │   │   │   ├── root.zig
    │   │   │   ├── scheduler.zig
    │   │   │   └── cpu.zig
    │   │   ├── process/
    │   │   │   ├── root.zig
    │   │   │   ├── lifecycle.zig
    │   │   │   └── manager.zig
    │   │   ├── capabilities/
    │   │   │   └── root.zig
    │   │   └── ipc/
    │   │       ├── message.zig
    │   │       └── service.zig
    │   ├── sys/          # Syscall handlers, VDSO, Framebuffer
    │   │   ├── root.zig
    │   │   ├── vdso.zig
    │   │   ├── vdso_blob.zig
    │   │   ├── framebuffer.zig
    │   │   └── syscall/
    │   │       ├── table.zig
    │   │       ├── base.zig
    │   │       ├── process.zig
    │   │       ├── signals.zig
    │   │       ├── scheduling.zig
    │   │       ├── io/
    │   │       ├── fd.zig
    │   │       └── memory.zig
    │   ├── fs/           # Filesystem glue (DevFS, Pipe, FD)
    │   │   ├── root.zig
    │   │   ├── devfs.zig
    │   │   ├── fd.zig
    │   │   └── pipe.zig
    │   └── io/           # Async I/O (Reactor, Pool)
    │       ├── root.zig
    │       ├── kernel_io.zig
    │       ├── pool.zig
    │       ├── reactor.zig
    │       └── timer.zig
    │
    ├── drivers/
    │   ├── audio/
    │   │   ├── root.zig
    │   │   └── ac97.zig
    │   ├── input/
    │   │   ├── root.zig
    │   │   ├── keyboard.zig
    │   │   ├── mouse.zig
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
    │   │       ├── init.zig
    │   │       ├── pool.zig
    │   │       ├── regs.zig
    │   │       ├── rx.zig
    │   │       ├── tx.zig
    │   │       ├── types.zig
    │   │       └── worker.zig
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
    │   │   │   ├── hid.zig
    │   │   │   ├── hub.zig
    │   │   │   └── msc.zig
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
    │   ├── initrd/
    │   │   └── (initrd implementation)
    │   ├── meta.zig
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
    │   ├── constants.zig
    │   ├── clock.zig
    │   ├── entropy.zig
    │   ├── platform.zig
    │   ├── sync.zig
    │   ├── drivers/
    │   │   └── loopback.zig
    │   ├── core/
    │   │   ├── root.zig
    │   │   ├── interface.zig
    │   │   ├── packet.zig
    │   │   ├── checksum.zig
    │   │   └── pool.zig
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
    │   ├── epoll.zig
    │   ├── futex.zig
    │   ├── io_ring.zig
    │   ├── ipc_msg.zig
    │   ├── net_ipc.zig
    │   ├── poll.zig
    │   ├── ring.zig
    │   ├── sched.zig
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
        ├── crt0.S
        ├── linker.ld
        ├── tests/
        │   ├── audio_test.zig
        │   ├── test_asm.zig
        │   └── test_libc_fix_wrapper.zig
        ├── lib/
        │   ├── ring.zig
        │   ├── syscall.zig
        │   ├── syscall_exports.zig
        │   ├── console_stub.zig
        │   ├── sync_stub.zig
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
        │       │   ├── tokenize.zig
        │       └── unistd/
        │           └── root.zig
        ├── drivers/
        │   ├── ps2/
        │   │   └── main.zig
        │   ├── uart/
        │   │   └── main.zig
        │   ├── virtio_blk/
        │   │   └── main.zig
        │   └── virtio_net/
        │       └── main.zig
        ├── shell/
        │   └── main.zig
        ├── netstack/
        │   ├── io_stub.zig
        │   └── main.zig
        ├── httpd/
        │   └── main.zig
        └── doom/
            ├── main.zig
            ├── doomgeneric_zscapek.zig
            ├── i_sound_stub.zig
            ├── include/
            │   └── (C headers for DOOM port)
            └── doomgeneric/
                └── (C source files for DOOM port)
```

## Generated Artifacts

These files and directories are produced by local builds or tooling and are not source-controlled.

- `.zig-cache/` - Zig build cache
- `initrd.tar` - InitRD archive
- `iso_root/` - ISO staging directory
- `options.o` - Local build artifact
- `root.o` - Local build artifact
- `test_libc_fixes.o` - Local build artifact
- `test_vdso.asm` - Local build artifact
- `usb_disk.img` - QEMU disk image
- `zig-out/` - Zig build output
- `zscapek.iso` - Bootable ISO

## Module Reference

### `src/kernel/core/`
| File | Description |
|------|-------------|
| `main.zig` | Kernel entry; wires Limine handoff into subsystems. |
| `boot.zig` | Boot-time initialization sequencing. |
| `init_hw.zig` | Hardware initialization (drivers, interrupts). |
| `init_mem.zig` | Memory subsystem initialization. |
| `init_fs.zig` | Filesystem initialization. |
| `init_proc.zig` | Process subsystem initialization. |
| `panic.zig` | Kernel panic handling. |
| `sync.zig` | Spinlocks and synchronization helpers. |
| `stack_guard.zig` | Guard page protections shared across stacks. |
| `debug/` | Kernel console and debug helpers. |
| `elf/` | ELF loader and validation. |

### `src/kernel/mm/`
| File | Description |
|------|-------------|
| `pmm.zig` | Physical memory manager. |
| `vmm.zig` | Page table manager. |
| `user_vmm.zig` | User address space management. |
| `heap.zig` | Kernel heap allocator. |
| `slab.zig` | Slab allocator implementation. |
| `dma_allocator.zig` | DMA-safe allocator. |
| `aslr.zig` | Address randomization helpers. |
| `tlb.zig` | TLB shootdown helpers. |
| `kernel_stack.zig` | Guarded kernel stack allocator. |
| `iommu/` | IOMMU domain management. |

### `src/kernel/proc/`
| File | Description |
|------|-------------|
| `thread.zig` | Thread context management. |
| `signal.zig` | Signal delivery infrastructure. |
| `futex.zig` | Fast Userspace Mutex. |
| `perms.zig` | POSIX permission checks. |
| `ring.zig` | Zero-copy ring buffer manager. |
| `sched/` | CPU scheduler core. |
| `process/` | Process lifecycle and manager. |
| `capabilities/` | Capability-based access control. |
| `ipc/` | Message passing and services. |

### `src/kernel/sys/`
| File | Description |
|------|-------------|
| `vdso.zig` | VDSO mapping and setup. |
| `vdso_blob.zig` | Embedded VDSO payload. |
| `framebuffer.zig` | Limine framebuffer setup. |
| `syscall/` | Syscall table and handlers. |

### `src/kernel/fs/`
| File | Description |
|------|-------------|
| `devfs.zig` | Device filesystem. |
| ` pipe.zig` | Pipe implementation for IPC. |
| `fd.zig` | File descriptor table logic. |

### `src/kernel/core/`
| File | Description |
|------|-------------|
| `root.zig` | Shim exports for kernel core entry and boot lifecycle modules. |

### `src/kernel/mm/`
| File | Description |
|------|-------------|
| `root.zig` | Shim exports for memory management modules. |

### `src/kernel/proc/`
| File | Description |
|------|-------------|
| `root.zig` | Shim exports for process, thread, scheduling, and IPC modules. |

### `src/kernel/fs/`
| File | Description |
|------|-------------|
| `root.zig` | Shim exports for kernel filesystem glue (devfs, pipe, fd). |

### `src/kernel/sys/`
| File | Description |
|------|-------------|
| `root.zig` | Shim exports for syscall, vdso, and user ABI glue. |

### `src/kernel/elf/`
| File | Description |
|------|-------------|
| `root.zig` | ELF loader entry point. |
| `loader.zig` | ELF load and map implementation. |
| `setup.zig` | Process image setup helpers. |
| `types.zig` | ELF type definitions and constants. |
| `utils.zig` | ELF parsing helpers. |
| `validation.zig` | ELF header and segment validation. |

### `src/kernel/process/`
| File | Description |
|------|-------------|
| `root.zig` | Process subsystem entry points. |
| `types.zig` | Process and credential types. |
| `manager.zig` | Process table and lifecycle coordination. |
| `lifecycle.zig` | Process creation, exec, and exit flows. |

### `src/kernel/sched/`
| File | Description |
|------|-------------|
| `root.zig` | Scheduler module entry point. |
| `scheduler.zig` | Scheduler core logic. |
| `thread.zig` | Scheduler thread bookkeeping. |
| `cpu.zig` | Per-CPU scheduler state. |
| `queue.zig` | Run queue implementation. |

### `src/kernel/debug/`
| File | Description |
|------|-------------|
| `console.zig` | Kernel console output. |

### `src/kernel/capabilities/`
| File | Description |
|------|-------------|
| `root.zig` | Capability-based access control for user-space driver permissions. |

### `src/kernel/io/`
| File | Description |
|------|-------------|
| `root.zig` | Async I/O subsystem entry point. |
| `kernel_io.zig` | Kernel-side async I/O helpers. |
| `pool.zig` | I/O request pool management. |
| `reactor.zig` | Event reactor for async completion handling. |
| `timer.zig` | Timer-based I/O operations. |
| `types.zig` | Shared I/O types and structures. |

### `src/kernel/ipc/`
| File | Description |
|------|-------------|
| `message.zig` | Message-passing IPC for microkernel communication. |
| `service.zig` | IPC service registry and routing. |

### `src/kernel/sys/syscall/`

Syscall handlers organized by category:

### `src/kernel/sys/syscall/core/`
| File | Description |
|------|-------------|
| `base.zig` | Shared state (current_process, fd_table, user_vmm) and accessors. |
| `table.zig` | Comptime dispatch table - auto-discovers handlers via reflection. |
| `user_mem.zig` | Validates and copies user memory safely. |
| `execution.zig` | `fork`, `execve`, `arch_prctl`, `get_fb_info`, `map_fb`. |
| `error_helpers.zig` | Shared syscall error conversion helpers. |

### `src/kernel/sys/syscall/process/`
| File | Description |
|------|-------------|
| `process.zig` | `exit`, `wait4`, `getpid`, `getppid`, `getuid`, `getgid`. |
| `signals.zig` | `rt_sigprocmask`, `rt_sigaction`, `rt_sigreturn`, `set_tid_address`. |
| `scheduling.zig` | `sched_yield`, `nanosleep`, `select`, `clock_gettime`. |

### `src/kernel/sys/syscall/fs/`
| File | Description |
|------|-------------|
| `fd.zig` | `open`, `close`, `dup`, `dup2`, `pipe`, `lseek`. |
| `fs_handlers.zig` | Filesystem syscall helpers (mount, umount). |

### `src/kernel/sys/syscall/memory/`
| File | Description |
|------|-------------|
| `memory.zig` | `mmap`, `mprotect`, `munmap`, `brk`. |
| `mmio.zig` | Memory-mapped I/O access for user-space drivers. |

### `src/kernel/sys/syscall/net/`
| File | Description |
|------|-------------|
| `net.zig` | Networking syscalls (`socket`, `bind`, `listen`, `accept`, `connect`, `sendto`, `recvfrom`). |
| `pci_syscall.zig` | PCI device access for user-space drivers. |

### `src/kernel/sys/syscall/hw/`
| File | Description |
|------|-------------|
| `input.zig` | Input device syscalls (keyboard, mouse). |
| `interrupt.zig` | User-space interrupt handling for drivers. |
| `port_io.zig` | Port I/O access for user-space drivers. |
| `ring.zig` | Ring buffer IPC syscalls. |

### `src/kernel/sys/syscall/io/`
| File | Description |
|------|-------------|
| `root.zig` | I/O syscall entry points and wiring. |
| `read_write.zig` | `read`, `write`, `writev` handlers. |
| `fcntl.zig` | `fcntl` handling and flags. |
| `stat.zig` | `stat` and `fstat` handlers. |
| `dir.zig` | Directory-related syscalls. |
| `utils.zig` | I/O helpers for common path handling. |
| `error_helpers.zig` | I/O-specific error conversions. |

### `src/kernel/sys/syscall/io_uring/`
| File | Description |
|------|-------------|
| `root.zig` | io_uring subsystem entry point. |
| `types.zig` | io_uring type definitions. |
| `ring.zig` | Ring setup and shared state. |
| `submission.zig` | Submission queue handling. |
| `completion.zig` | Completion queue handling. |
| `request.zig` | Request allocation and lifecycle. |
| `instance.zig` | Per-instance state and tracking. |
| `ops.zig` | Supported io_uring operations. |
| `setup.zig` | `io_uring_setup` handler. |
| `enter.zig` | `io_uring_enter` handler. |
| `register.zig` | `io_uring_register` handler. |
| `fd.zig` | File descriptor helpers for io_uring. |

### `src/kernel/sys/syscall/misc/`
| File | Description |
|------|-------------|
| `custom.zig` | Zscapek extensions (`debug_log`, `putchar`, `getchar`, `read_scancode`). |
| `random.zig` | `getrandom` (syscall 318). |
| `ipc.zig` | IPC message passing syscalls. |

### `src/arch/x86_64/`
| File | Description |
|------|-------------|
| `root.zig` | x86_64 HAL exports. |
| `cpu.zig` | CPU feature detection and control. |
| `mem.zig` | Architecture memory helpers for optimized copy/fill. |
| `memcpy.S` | Optimized memcpy/memset helpers for freestanding builds. |
| `smp_trampoline.S` | AP bring-up trampoline. |
| `serial.zig` | Serial port output. |
| `debug.zig` | Debug utilities. |
| `entropy.zig` | Hardware entropy (RDRAND/RDSEED). |
| `fpu.zig` | FPU/SSE state management. |
| `gdt.zig` | Global Descriptor Table. |
| `idt.zig` | Interrupt Descriptor Table. |
| `interrupts.zig` | Interrupt handlers. |
| `io.zig` | Port I/O. |
| `mmio.zig` | Memory-mapped I/O. |
| `mmio_device.zig` | MMIO device helpers. |
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
| `apic/ipi.zig` | Inter-processor interrupt helpers. |

### `src/net/` (Network Stack)
A device-independent TCP/IP stack implementing Ethernet, IPv4/ARP, DNS, and socket-based UDP/TCP/ICMP.

| Submodule | Description |
|-----------|-------------|
| `core` | Packet buffers, interfaces, and checksumming utilities. |
| `ethernet` | Ethernet II framing and dispatch. |
| `ipv4` | IPv4 validation, ARP resolution, PMTU discovery, and fragment reassembly. |
| `dns` | DNS client and resolver. |
| `transport` | UDP datagrams, TCP streams, ICMP echo, and socket plumbing. |
| `drivers/loopback.zig` | Loopback interface (127.0.0.1). |
| `constants.zig` | Shared protocol constants (header sizes, options, ethertypes). |
| `clock.zig` | Network clock abstraction for timing and timeouts. |
| `entropy.zig` | Network stack entropy sources. |
| `platform.zig` | Platform glue for timers and memory. |

### `src/fs/` (Filesystem)
| File | Description |
|------|-------------|
| `root.zig` | Filesystem registry and init hooks. |
| `initrd.zig` | TAR-format initial ramdisk for loading files at boot. |
| `meta.zig` | File metadata for permission checks. |
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
| `init.zig` | Device initialization and lifecycle. |
| `pool.zig` | Buffer pool management. |
| `regs.zig` | Register definitions. |
| `rx.zig` | Receive path handling. |
| `tx.zig` | Transmit path handling. |
| `types.zig` | Shared device types and constants. |
| `worker.zig` | Background worker for IRQ and TX watchdog handling. |

### `src/drivers/audio/`
| File | Description |
|------|-------------|
| `root.zig` | Audio subsystem entry. |
| `ac97.zig` | AC'97 audio codec driver. |

### `src/drivers/input/`
| File | Description |
|------|-------------|
| `root.zig` | Input subsystem entry. |
| `keyboard.zig` | PS/2 keyboard driver entry. |
| `mouse.zig` | PS/2 mouse driver entry. |
| `cursor.zig` | Mouse cursor rendering. |
| `keyboard_layout.zig` | Keymap tables. |
| `layout.zig` | Layout selection and lookup. |
| `layouts/dvorak.zig` | Dvorak keyboard layout. |
| `layouts/us.zig` | US QWERTY keyboard layout. |

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
| `class/hub.zig` | USB hub class driver. |
| `class/msc.zig` | USB mass storage class driver. |
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
| `epoll.zig` | Epoll definitions. |
| `futex.zig` | Futex constants and types. |
| `io_ring.zig` | io_uring ABI structs. |
| `ipc_msg.zig` | IPC message structs for user-space drivers. |
| `net_ipc.zig` | Network IPC message definitions. |
| `poll.zig` | Poll event definitions. |
| `ring.zig` | Ring buffer IPC ABI structs. |
| `sched.zig` | Scheduling constants and structs. |
| `dirent.zig` | Directory entry structures. |
| `input.zig` | Input event structures. |
| `mman.zig` | Memory mapping flags and constants. |
| `signal.zig` | Signal definitions and structures. |
| `sound.zig` | Audio IOCTL definitions. |
| `stat.zig` | File stat structures. |

### `tools/vdso_gen/`
| File | Description |
|------|-------------|
| `build.sh` | VDSO build helper script. |
| `vdso.zig` | VDSO definitions and build inputs. |

### `src/user/` (Userland Runtime)
| File | Description |
|------|-------------|
| `root.zig` | User module exports. |
| `crt0.zig` | Userland entry point (`_start`). |
| `crt0.S` | Low-level startup assembly. |
| `linker.ld` | Userland linker script. |
| `audio_test.zig` | Audio playback test application. |
| `test_asm.zig` | Minimal assembly sanity test program. |
| `test_libc_fix_wrapper.zig` | libc regression test wrapper. |
| `lib/ring.zig` | Userspace ring buffer IPC helpers. |
| `lib/syscall.zig` | Syscall wrappers. |
| `lib/syscall_exports.zig` | Exported syscall symbols for libc. |
| `lib/console_stub.zig` | Console syscall shims for userland. |
| `lib/sync_stub.zig` | Synchronization syscall shims for userland. |
| `lib/libc/` | Minimal libc implementation for C program support. |
| `shell/main.zig` | Shell application. |
| `netstack/main.zig` | User-space network stack harness. |
| `netstack/io_stub.zig` | Netstack I/O syscall shims. |
| `httpd/main.zig` | HTTP server application. |
| `doom/` | DOOM game port (doomgeneric). |

### `src/user/drivers/` (User-space Drivers)
| Directory | Description |
|-----------|-------------|
| `ps2/main.zig` | PS/2 keyboard and mouse user-space driver. |
| `uart/main.zig` | UART serial port user-space driver. |
| `virtio_blk/main.zig` | VirtIO block device user-space driver. |
| `virtio_net/main.zig` | VirtIO network device user-space driver. |

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
6. **User-space Drivers**: Microkernel architecture with user-space drivers (`src/user/drivers/`) using capability-based access control.
7. **Async I/O**: io_uring-style async I/O subsystem (`src/kernel/io/`) for high-performance driver communication.
