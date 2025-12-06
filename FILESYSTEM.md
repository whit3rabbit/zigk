Based on the detailed specifications provided--specifically the requirements for ARM portability (Spec 008), the microkernel/modular design (Spec 003), and the Linux syscall compatibility layer (Spec 005)--here is a recommended file tree structure.

This structure mirrors the **Linux Kernel** organization to ensure familiarity for OS developers, while leveraging **Zig's** module system to enforce the strict HAL layering required by your Constitution.

### Recommended File Structure

```text
zigk/
├── build.zig                  # Master build logic (Architecture selection FR-019)
├── build.zig.zon              # Dependencies (limine-zig)
├── limine.conf                # Bootloader config
├── specs/                     # Design documents (as provided)
│   ├── 001-minimal-kernel/    # Complete: Minimal bootable kernel
│   ├── 003-microkernel.../    # Complete: Microkernel with userland & networking
│   ├── 007-linux-compat.../   # Complete: Linux compatibility layer
│   ├── 009-spec-consistency/  # Complete: Cross-spec consistency unification
│   ├── syscall-table.md       # Authoritative Linux syscall numbers
│   ├── shared/                # Shared policies (zig-version, gotchas)
│   └── archived/              # Superseded specs (002,004,005,006,008)
│       └── README.md          # Documents merge destinations
├── tools/                     # Build scripts (ISO creation, QEMU runners)
└── src/
    ├── kernel/
    │   ├── main.zig           # Kernel Entry Point (kmain) - Limine requests
    │   └── syscall/           # [Spec 005/007] Modular syscall handlers
    │       ├── table.zig      # Dispatch table (Linux x86_64 ABI numbers)
    │       ├── handlers.zig   # Core syscall implementations
    │       └── process.zig    # Process-related syscalls (wait4, exit, etc.)
    ├── config.zig             # Compile-time configuration (Debug flags, constants)
    │
    ├── arch/                  # [Spec 008] Architecture Specifics (The HAL)
    │   │                      # ONLY place for Inline Assembly & Volatile MMIO
    │   ├── x86_64/            # Current Target
    │   │   ├── boot/          # linker.ld, multiboot/limine headers
    │   │   ├── mm/            # Paging bits (PTE definitions)
    │   │   ├── cpu.zig        # GDT, IDT, Control Registers
    │   │   ├── io.zig         # Port I/O (outb/inb)
    │   │   ├── serial.zig     # COM1 implementation
    │   │   └── time.zig       # PIT/TSC implementation
    │   │
    │   └── aarch64/           # [Spec 008] Future Target (Stubbed)
    │       ├── boot/
    │       ├── mm/
    │       └── uart.zig       # PL011 implementation
    │
    ├── kernel/                # [Spec 004] Core Kernel Subsystems (Arch-Agnostic)
    │   ├── sched/             # Scheduler, Thread structs, Idle Thread
    │   ├── irq/               # Generic IRQ dispatch logic
    │   ├── time/              # Generic timekeeping (clock_gettime)
    │   ├── panic.zig          # Panic handler
    │   └── printk.zig         # Logging abstraction (calls arch.serial)
    │
    ├── mm/                    # [Spec 003] Memory Management
    │   ├── heap.zig           # Free-list allocator (Coalescing logic)
    │   ├── pmm.zig            # Physical Page Allocator (Bitmap)
    │   └── vmm.zig            # Generic Virtual Memory logic
    │
    ├── drivers/               # [Spec 003] Device Drivers (Bus Agnostic)
    │   ├── pci/               # PCI Enumeration logic
    │   ├── net/               # Network Drivers
    │   │   └── e1000.zig      # Intel E1000 Driver
    │   └── input/
    │       └── keyboard.zig   # Scancode logic
    │
    ├── net/                   # [Spec 003/007] Networking Stack
    │   ├── core/              # PacketBuffer, Socket structs
    │   ├── ipv4/              # IP Layer, ARP Cache
    │   ├── ethernet/          # Frame parsing
    │   └── transport/         # UDP/TCP logic
    │
    ├── fs/                    # [Spec 003] Virtual File System
    │   ├── initrd/            # TAR/USTAR parser
    │   └── file.zig           # File Descriptor table logic
    │
    ├── uapi/                  # [Spec 005] UserSpace API (Shared Headers)
    │   │                      # Imported by both Kernel and Userland apps
    │   ├── syscalls.zig       # Syscall numbers (Arch-aware mapping)
    │   ├── errno.zig          # Linux-compatible error codes
    │   └── abi.zig            # Structs: timespec, sockaddr, stat
    │
    └── usr/                   # [Spec 003] Userland Applications (Ring 3)
        ├── lib/               # Mini-libc (malloc, printf, start.zig)
        ├── shell/             # The Shell application
        └── doom/              # Doomgeneric port
```

### Key Design Decisions & rationale

#### 1. The `arch/` Directory (The HAL)
*   **Requirement:** *Spec 008 User Story 1 (Strict HAL Boundary).*
*   **Linux Parallel:** Matches `arch/x86`, `arch/arm64`.
*   **Zig Implementation:** In `build.zig`, you map the module alias `hal` to `src/arch/{target}/root.zig`.
*   **Rule:** This is the **only** place where `asm volatile` or direct hardware addresses (0x3F8, 0xB8000) are allowed. The rest of the kernel imports `hal` and calls generic functions like `hal.console.write()`.

#### 2. `uapi/` (User API)
*   **Requirement:** *Spec 005 (Linux Syscall Compat) & Spec 008 (Arch-aware Syscalls).*
*   **Linux Parallel:** Matches `include/uapi`.
*   **Purpose:** These files are shared. The kernel uses them to define the ABI it implements. Userland programs (Shell, Doom) import them to know which register to put values in for `syscall` instructions. This ensures the kernel and userland never disagree on the value of `EAGAIN` or `SYS_write`.

#### 3. `mm/` vs `mem/`
*   **Requirement:** *Spec 003 Phase 1 (Memory).*
*   **Linux Parallel:** Matches Linux `mm/` (Memory Management).
*   **Structure:**
    *   `pmm.zig`: Handles the raw resource (physical RAM).
    *   `vmm.zig`: Handles the abstraction (Page tables).
    *   `heap.zig`: Handles kernel-internal dynamic memory (`alloc`/`free`).

#### 4. `net/` vs `drivers/net/`
*   **Requirement:** *Spec 003 User Story 3 (Network Buffer Ownership).*
*   **Linux Parallel:** Linux strictly separates the *stack* (`net/`) from the *hardware* (`drivers/net/`).
*   **Why:** Your `e1000.zig` (in `drivers/`) should just push raw bytes into a `PacketBuffer`. The code in `net/ipv4/` shouldn't care if those bytes came from an E1000, a Realtek card, or the Loopback interface (*Spec 004 US 10*).

#### 5. `usr/` (Embedded Userland)
*   **Requirement:** *Spec 003 User Story 3 (Ring 3 Userland).*
*   **Context:** Since you are building a monolithic binary (initially) or an ISO with modules, having userland source in-tree allows the build system to compile the kernel, then compile the shell using the kernel's `uapi`, and bundle them together into the ISO in one `zig build` command.

### Modular Build Configuration

In your `build.zig`, you can enforce this modularity programmatically:

```zig
// build.zig pseudocode
const target_arch = target.result.cpu.arch;

// Select HAL based on architecture (Spec 008)
const hal_path = switch (target_arch) {
    .x86_64 => "src/arch/x86_64/root.zig",
    .aarch64 => "src/arch/aarch64/root.zig",
    else => @panic("Unsupported architecture"),
};

// Create the HAL module
const hal_mod = b.createModule(.{ .root_source_file = .{ .path = hal_path } });

// Kernel module depends on HAL, but HAL depends on nothing generic
kernel.root_module.addImport("hal", hal_mod);
```

### Archived Specifications

The following specs were consolidated into active specs (003, 007) as of 2025-12-06:

| Archived Spec | Requirements Merged Into |
|---------------|-------------------------|
| 002-kernel-infrastructure | Spec 003 Phase 1 (panic, stack protection) |
| 004-kernel-stability-arch | Spec 003 Phase 3 (FPU/SSE, stack guards), Spec 007 Phase 1.5 (crash diagnostics) |
| 005-linux-syscall-compat | `specs/syscall-table.md` (authoritative table) |
| 006-sysv-abi-init | Spec 003 userland (crt0), Spec 007 (arch_prctl) |
| 008-arm-hal-portability | Spec 003 Phase 1.5 (HAL tasks), contracts/hal-interface.md |

See `specs/archived/README.md` for full details.