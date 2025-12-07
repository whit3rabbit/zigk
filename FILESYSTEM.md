# ZigK Filesystem Structure

Based on the detailed specifications provided--specifically the requirements for ARM portability (Spec 008), the microkernel/modular design (Spec 003), and the Linux syscall compatibility layer (Spec 005)--here is the file tree structure.

This structure mirrors the **Linux Kernel** organization to ensure familiarity for OS developers, while leveraging **Zig's** module system to enforce the strict HAL layering required by the Constitution.

## Current Implementation Status (2025-12-07)

```text
zigk/
├── build.zig                  # [IMPL] Master build logic (Zig 0.15.x)
├── build.zig.zon              # [IMPL] Dependencies

├── BOOT.md                # [New] Boot process documentation
├── BUILD.md               # [New] Build instructions
├── CLAUDE.md                  # Project instructions
├── FILESYSTEM.md              # This file
├── specs/                     # Design documents
│   ├── 003-microkernel.../    # Active: Memory, scheduler, networking
│   ├── 007-linux-compat.../   # Active: Linux compatibility layer
│   ├── 009-spec-consistency/  # Complete: Spec unification
│   ├── syscall-table.md       # Authoritative syscall numbers
│   └── shared/                # Zig version policy, gotchas
├── tests/
│   └── unit/
│       ├── main.zig           # [IMPL] Test runner entry
│       └── heap_fuzz.zig      # [IMPL] Heap allocator fuzz tests (10,000 ops)
└── src/
    ├── config.zig             # [IMPL] Kernel configuration constants
    │
    ├── lib/

    │   ├── ring_buffer.zig    # [IMPL] Generic comptime ring buffer
    │   └── prng.zig           # [IMPL] Xoroshiro128+ PRNG (kernel entropy)
    │
    ├── uapi/                  # [IMPL] UserSpace API (Shared Headers)
    │   ├── root.zig           # [IMPL] UAPI module root
    │   ├── syscalls.zig       # [IMPL] Syscall numbers (Linux ABI + ZigK)
    │   └── errno.zig          # [IMPL] Linux-compatible error codes
    │
    ├── user/                  # [IMPL] Userland Runtime (Ring 3)
    │   ├── root.zig           # [IMPL] Userland module root
    │   ├── crt0.zig           # [IMPL] Entry point (_start, SysV ABI)
    │   ├── linker.ld          # [IMPL] Userland linker script
    │   └── lib/
    │       └── syscall.zig    # [IMPL] Syscall wrappers (all Linux + ZigK)
    │
    ├── drivers/               # [IMPL] Device Drivers
    │   └── keyboard.zig       # [IMPL] PS/2 keyboard (dual ring buffers)
    │
    ├── arch/                  # HAL - ONLY place for inline assembly
    │   ├── root.zig           # [IMPL] Architecture-agnostic HAL interface
    │   └── x86_64/
    │       ├── root.zig       # [IMPL] x86_64 HAL root module
    │       ├── cpu.zig        # [IMPL] CR/MSR/interrupt control
    │       ├── io.zig         # [IMPL] Port I/O (inb/outb)
    │       ├── serial.zig     # [IMPL] COM1 serial driver
    │       ├── paging.zig     # [IMPL] 4-level page table management
    │       ├── gdt.zig        # [IMPL] GDT/TSS configuration
    │       ├── idt.zig        # [IMPL] IDT configuration
    │       ├── interrupts.zig # [IMPL] Interrupt handlers + keyboard callback
    │       ├── pic.zig        # [IMPL] 8259 PIC configuration
    │       ├── fpu.zig        # [IMPL] FPU/SSE state management
    │       ├── debug.zig      # [IMPL] Register dump for exceptions
    │       ├── entropy.zig    # [IMPL] Hardware entropy (RDRAND/RDTSC)
    │       ├── asm_helpers.S  # [IMPL] Assembly helpers (lgdt, lidt, rdrand, rdtsc)
    │       └── boot/
    │           └── linker.ld  # [IMPL] Kernel linker script
    │
    └── kernel/                # Core kernel subsystems
        ├── main.zig           # [IMPL] Kernel entry, Multiboot2 init
        ├── pmm.zig            # [IMPL] Physical Memory Manager (bitmap)
        ├── vmm.zig            # [IMPL] Virtual Memory Manager (4-level paging)
        ├── heap.zig           # [IMPL] Kernel heap (thread-safe, coalescing)
        ├── sync.zig           # [IMPL] IRQ-safe Spinlock primitives
        ├── thread.zig         # [IMPL] Thread structure, states, context
        ├── sched.zig          # [IMPL] Round-robin scheduler, idle thread
        ├── stack_guard.zig    # [IMPL] Stack canary support (PRNG-randomized)
        ├── syscall/           # [IMPL] Syscall handlers
        │   └── random.zig     # [IMPL] sys_getrandom (syscall 318)
        └── debug/
            └── console.zig    # [IMPL] Debug console (serial writer)
```

**Legend:** [IMPL] = Implemented, [TODO] = Not yet implemented

## Module Reference (New Files)

### `src/arch/x86_64/entropy.zig`
Hardware entropy source module for RDRAND and RDTSC instructions.

| Export | Type | Description |
|--------|------|-------------|
| `init()` | `fn` | Initialize entropy subsystem, detect RDRAND via CPUID |
| `hasRdrand()` | `fn` | Check if RDRAND instruction is available |
| `rdrand64()` | `fn` | Get 64-bit random from RDRAND (returns `?u64`) |
| `rdtsc()` | `fn` | Read Time Stamp Counter (always available) |
| `getHardwareEntropy()` | `fn` | Best-effort entropy: RDRAND with RDTSC fallback |
| `isInitialized()` | `fn` | Check if module has been initialized |

**Imports:** `cpu.zig`
**External deps:** `_asm_rdrand64`, `_asm_rdtsc` from `asm_helpers.S`

---

### `src/lib/prng.zig`
Kernel-wide PRNG using xoroshiro128+ algorithm.

| Export | Type | Description |
|--------|------|-------------|
| `init()` | `fn` | Seed PRNG from hardware entropy (call before scheduler) |
| `next()` | `fn` | Generate 64-bit random value (thread-safe) |
| `fill(buf)` | `fn` | Fill byte slice with random data |
| `isInitialized()` | `fn` | Check if PRNG has been seeded |
| `range(max)` | `fn` | Random value in `[0, max)` with rejection sampling |

**Imports:** `hal` (for entropy), `sync` (for Spinlock)

---

### `src/kernel/syscall/random.zig`
Linux sys_getrandom syscall implementation (syscall 318).

| Export | Type | Description |
|--------|------|-------------|
| `GRND_NONBLOCK` | `u32` | Flag constant (0x1) |
| `GRND_RANDOM` | `u32` | Flag constant (0x2) |
| `sys_getrandom(buf_ptr, buflen, flags)` | `fn` | Fill userspace buffer with random bytes |

**Imports:** `uapi` (for errno), `prng`
**Returns:** Bytes written on success, `-EFAULT` or `-EINVAL` on error

---

### `src/kernel/heap.zig` (Updated)
Added secure memory deallocation helper.

| New Export | Type | Description |
|------------|------|-------------|
| `freeSecure(ptr, size)` | `fn` | Zero memory before freeing (prevents info leaks) |

---

### `src/arch/x86_64/asm_helpers.S` (Updated)
Added assembly helpers for entropy instructions.

| New Export | Signature | Description |
|------------|-----------|-------------|
| `_asm_rdrand64` | `(success: *u8) -> u64` | Execute RDRAND, set success flag |
| `_asm_rdtsc` | `() -> u64` | Execute RDTSC, return 64-bit counter |

## Planned Structure (Full Specification)

```text
zigk/
├── build.zig                  # Master build logic (Architecture selection FR-019)
├── build.zig.zon              # Dependencies

├── specs/                     # Design documents
│   ├── 001-minimal-kernel/    # Complete: Minimal bootable kernel
│   ├── 003-microkernel.../    # Complete: Microkernel with userland & networking
│   ├── 007-linux-compat.../   # Complete: Linux compatibility layer
│   ├── 009-spec-consistency/  # Complete: Cross-spec consistency unification
│   ├── syscall-table.md       # Authoritative Linux syscall numbers
│   ├── shared/                # Shared policies (zig-version, gotchas)
│   └── archived/              # Superseded specs (002,004,005,006,008)
│       └── README.md          # Documents merge destinations
├── tools/                     # Build scripts (ISO creation, QEMU runners)
├── tests/
│   └── unit/
│       ├── main.zig           # Test runner entry point
│       └── heap_fuzz.zig      # Heap allocator fuzz tests
└── src/
    ├── config.zig             # Compile-time configuration (Debug flags, constants)
    ├── lib/

    │   ├── ring_buffer.zig    # Generic comptime ring buffer
    │   └── prng.zig           # Xoroshiro128+ PRNG (kernel entropy)
    │
    ├── arch/                  # [Spec 008] Architecture Specifics (The HAL)
    │   │                      # ONLY place for Inline Assembly & Volatile MMIO
    │   ├── root.zig           # Architecture-agnostic HAL interface
    │   ├── x86_64/            # Current Target
    │   │   ├── root.zig       # x86_64 HAL root module
    │   │   ├── boot/          # linker.ld, multiboot headers
    │   │   ├── cpu.zig        # CR/MSR/interrupt control, CPUID
    │   │   ├── io.zig         # Port I/O (outb/inb)
    │   │   ├── serial.zig     # COM1 implementation
    │   │   ├── paging.zig     # 4-level page table management
    │   │   ├── gdt.zig        # GDT/TSS configuration
    │   │   ├── idt.zig        # IDT configuration
    │   │   ├── interrupts.zig # Interrupt handlers, ISR stubs
    │   │   ├── pic.zig        # 8259 PIC configuration
    │   │   ├── pit.zig        # Programmable Interval Timer
    │   │   ├── fpu.zig        # FPU/SSE state management
    │   │   ├── entropy.zig    # Hardware entropy (RDRAND/RDTSC)
    │   │   ├── asm_helpers.S  # Assembly helpers (lgdt, lidt, rdrand, rdtsc)
    │   │   └── syscall.zig    # SYSCALL/SYSRET configuration
    │   │
    │   └── aarch64/           # [Spec 008] Future Target (Stubbed)
    │       ├── boot/
    │       └── uart.zig       # PL011 implementation
    │
    ├── kernel/                # Core Kernel Subsystems (Arch-Agnostic)
    │   ├── main.zig           # Kernel entry point
    │   ├── pmm.zig            # Physical Memory Manager (bitmap allocator)
    │   ├── vmm.zig            # Virtual Memory Manager (4-level paging)
    │   ├── heap.zig           # Kernel heap (coalescing free-list)
    │   ├── sync.zig           # IRQ-safe spinlock primitives
    │   ├── thread.zig         # Thread structure, states
    │   ├── sched.zig          # Round-robin scheduler, idle thread
    │   ├── panic.zig          # Panic handler
    │   ├── syscall/           # Modular syscall handlers
    │   │   ├── table.zig      # Dispatch table (Linux x86_64 ABI)
    │   │   ├── random.zig     # sys_getrandom (syscall 318)
    │   │   ├── handlers.zig   # Core syscall implementations
    │   │   └── process.zig    # Process syscalls (wait4, exit, etc.)
    │   └── debug/
    │       └── console.zig    # Generic writer wrapping arch.serial
    │
    ├── drivers/               # [Spec 003] Device Drivers (Bus Agnostic)
    │   ├── pci.zig            # PCI enumeration logic
    │   ├── e1000.zig          # Intel E1000 NIC driver
    │   └── keyboard.zig       # PS/2 keyboard driver
    │
    ├── net/                   # [Spec 003/007] Networking Stack
    │   ├── ethernet.zig       # Ethernet frame parsing
    │   ├── arp.zig            # ARP cache and resolution
    │   ├── ip.zig             # IPv4 layer
    │   ├── icmp.zig           # ICMP (ping) handling
    │   └── udp.zig            # UDP transport
    │
    ├── fs/                    # [Spec 003] Virtual File System
    │   ├── initrd.zig         # TAR/USTAR parser
    │   └── fd.zig             # File descriptor table
    │
    ├── uapi/                  # [Spec 005] UserSpace API (Shared Headers)
    │   │                      # Imported by both Kernel and Userland apps
    │   ├── root.zig           # UAPI module root
    │   ├── syscalls.zig       # Syscall numbers (from syscall-table.md)
    │   ├── errno.zig          # Linux-compatible error codes
    │   └── abi.zig            # Structs: timespec, sockaddr, stat
    │
    └── user/                  # [Spec 003] Userland Applications (Ring 3)
        ├── crt0.zig           # C runtime entry point
        ├── lib/
        │   ├── syscall.zig    # Userland syscall wrappers
        │   └── libc.zig       # Mini libc (malloc, printf)
        └── shell.zig          # Shell application
```

## Key Design Decisions

### 1. The `arch/` Directory (The HAL)
- **Requirement:** Spec 008 User Story 1 (Strict HAL Boundary)
- **Linux Parallel:** Matches `arch/x86`, `arch/arm64`
- **Zig Implementation:** In `build.zig`, the module alias `hal` maps to `src/arch/root.zig`
- **Rule:** This is the **only** place where `asm volatile` or direct hardware addresses are allowed

### 2. `uapi/` (User API)
- **Requirement:** Spec 005 (Linux Syscall Compat) & Spec 008 (Arch-aware Syscalls)
- **Linux Parallel:** Matches `include/uapi`
- **Purpose:** Shared between kernel and userland to ensure ABI consistency

### 3. Memory Management (`kernel/`)
- **Structure:**
  - `pmm.zig`: Bitmap-based physical page allocator
  - `vmm.zig`: 4-level page table management, HHDM integration
  - `heap.zig`: Free-list allocator with immediate coalescing

### 4. `net/` vs `drivers/`
- **Linux Parallel:** Strictly separates stack (`net/`) from hardware (`drivers/`)
- **Why:** Network stack code should not care about hardware specifics

### 5. `user/` (Embedded Userland)
- **Requirement:** Spec 003 User Story 3 (Ring 3 Userland)
- **Purpose:** Single `zig build` compiles kernel + userland + bundles into ISO

## File Size Guidelines

Keep individual files under 500 lines where practical:
- **paging.zig:** ~200 lines (page table structures and helpers)
- **pmm.zig:** ~300 lines (bitmap allocator)
- **vmm.zig:** ~220 lines (virtual memory management)
- **heap.zig:** ~520 lines (free-list allocator with tests support)
- **heap_fuzz.zig:** ~370 lines (comprehensive fuzz tests)

For larger subsystems, split into multiple files in a directory.
