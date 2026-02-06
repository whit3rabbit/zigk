# Architecture

**Analysis Date:** 2026-02-06

## Pattern Overview

**Overall:** Microkernel with modular driver subsystem, strict HAL abstraction, and architecture-agnostic kernel core

**Key Characteristics:**
- Pure microkernel design: kernel space contains only scheduling, memory management, syscall dispatch, and synchronization
- Hardware abstraction through HAL (`src/arch/root.zig`) enforces architecture independence
- Dual-architecture support: x86_64 and aarch64 with compile-time architecture selection
- Modular drivers: Each subsystem (storage, network, USB, video) has independent init and can be conditionally compiled
- Syscall dispatch via comptime table generation from UAPI definitions
- Multi-layer isolation: Kernel core, HAL, Drivers, Userspace with strict dependency flow

## Layers

**Hardware Abstraction Layer (HAL):**
- Purpose: Provides architecture-agnostic interface to CPU control, interrupts, memory, I/O, timing
- Location: `src/arch/root.zig` (dispatcher), `src/arch/x86_64/` and `src/arch/aarch64/` (implementations)
- Contains: CPU operations, paging, interrupt handling, syscall entry/exit, timing, SMEP/SMAP, FPU state
- Depends on: Zig standard library, inline assembly (isolated to arch-specific code)
- Used by: Kernel core (`src/kernel/`) strictly; drivers via kernel-provided abstractions

**Kernel Core:**
- Purpose: Process scheduling, memory management, filesystem, IPC, syscall dispatch
- Location: `src/kernel/`
- Contains:
  - **Process/Scheduling** (`src/kernel/proc/sched/`): Per-CPU scheduler, thread state, context switching
  - **Memory Management** (`src/kernel/mm/`): PMM (physical page allocator), VMM (virtual memory), user address space (UserVmm), heap, slab allocator
  - **Filesystem** (`src/kernel/fs/`): VFS layer, file descriptors, pipes, DevFS
  - **Syscall Dispatch** (`src/kernel/sys/syscall/`): Comptime-generated dispatch table, per-subsystem handlers (process, memory, io, net, etc.)
  - **Core Services** (`src/kernel/core/`): Initialization (hardware, memory, processes, filesystem), panic/debug, ELF loader
  - **IPC/Sync** (`src/kernel/proc/ipc/`): Futex, message queues, signal delivery
- Depends on: HAL exclusively for hardware access
- Used by: Drivers (for allocators, scheduler APIs), syscall handlers (for kernel services)

**Driver Layer:**
- Purpose: Hardware device management (storage, network, USB, video, audio, input)
- Location: `src/drivers/`
- Contains:
  - **Storage**: AHCI/SATA, NVMe, IDE, VirtIO SCSI
  - **Network**: E1000e Ethernet NIC, VirtIO Network
  - **USB**: XHCI/EHCI host controllers, HID input class
  - **Video**: BGA, Cirrus, SVGA, QXL, VirtIO GPU
  - **Input**: PS/2 keyboard/mouse, VirtIO input
  - **Audio**: AC97, HDA, VirtIO Sound
  - **Virtio**: Common virtio infrastructure
  - **Hypervisor-specific**: VirtualBox (VMMDev, SharedFolders), VMware (VMMouse)
  - **PCI**: PCI enumeration, configuration access, capability enumeration
  - **Virt-PCI**: VFIO for userspace device drivers
- Depends on: Kernel allocators (PMM, heap), scheduler (for threaded processing), PCI subsystem, ACPI, IOMMU
- Used by: Kernel initialization (`init_hw.zig`), userspace drivers (via `/dev`)

**Network Stack:**
- Purpose: TCP/IP protocol implementation
- Location: `src/net/`
- Contains:
  - **Data Link**: Ethernet (ARP, MAC addressing)
  - **Internet**: IPv4, IPv6, ICMP, IGMP
  - **Transport**: TCP (with SipHash-2-4 ISN generation), UDP
  - **Application**: DNS, mDNS
  - **Socket Layer**: BSD socket API via syscalls
- Depends on: Driver layer (network interfaces), kernel memory/scheduler
- Used by: Syscall handlers for socket operations

**Filesystem:**
- Purpose: Multi-filesystem VFS with InitRD (read-only), SFS (writable), DevFS (virtual)
- Location: `src/fs/` (VFS/mount infrastructure), driver-mounted instances
- Mount Points:
  - `/` (InitRD): Read-only USTAR tarball from bootloader
  - `/mnt` (SFS): Writable simple filesystem (up to 64 files, 32-char names)
  - `/dev` (DevFS): Virtual device files (character devices, block devices)
- Depends on: Kernel memory, storage drivers
- Used by: Syscall handlers for file I/O

**Userspace:**
- Purpose: User-facing services, libraries, applications
- Location: `src/user/`
- Contains:
  - **libc**: POSIX C library wrapping syscalls (stdio, stdlib, string, unistd, memory)
  - **Syscall wrappers**: Typed syscall interfaces (`syscall/`)
  - **Applications**: Shell, Doom, Test Runner, Networking services
  - **Drivers**: Virtio drivers running in userspace (balloon, block, console, network)
- Depends on: Kernel syscalls (via `syscall_base`)
- Used by: End users, test infrastructure

## Data Flow

**System Call Path (x86_64):**

1. Userspace: Executes `syscall` instruction (RAX = syscall number, RDI-R9, R10 = args)
2. HAL Syscall Entry: `src/arch/x86_64/asm_helpers.S:_syscall_entry`
   - SWAPGS to access kernel GS (per-CPU data)
   - Stack switch: Load kernel stack from GS
   - SMAP stac (if enabled) to allow kernel->user memory access
   - Call `dispatch_syscall(frame)`
3. Kernel Dispatch: `src/kernel/sys/syscall/core/table.zig:dispatch_syscall`
   - Comptime-generated switch statement maps SYS_* number to handler function
   - Handler modules searched in priority order: net, process, signals, scheduling, io, fd, fs_handlers, flock, memory, execution, custom, etc.
4. Handler Execution: Handler module (e.g., `process.zig`, `io.zig`) implements `sys_<name>` function
   - Copy data from user memory via `UserPtr` (with SMAP verification)
   - Perform kernel operation (with proper locking per lock ordering)
   - Return `SyscallError!usize`
5. HAL Return: x86_64 HAL converts error to negative errno, sets RAX, executes SYSRET

**Process Creation (fork/execve):**

1. Userspace calls `fork()` (libc wrapper -> `SYS_FORK` syscall)
2. Kernel handler (`src/kernel/sys/syscall/process/fork.zig`):
   - Copies parent process struct, address space (COW or full copy)
   - Creates new thread in scheduler ready queue
   - Returns child PID to parent, 0 to child
3. Scheduler picks up new thread on next context switch
4. Child resumes from fork() with return value 0

**execve path:**
1. Userspace calls `execve(path, argv, envp)`
2. Kernel handler (`src/kernel/sys/syscall/core/execution.zig`):
   - Load ELF binary from filesystem using VFS
   - Parse ELF headers, segments
   - Teardown old address space (current process image)
   - Setup new address space with ELF segments
   - Create user stack with argc/argv/envp
   - Switch page tables to new address space (writeTtbr0 on aarch64, writeCr3 on x86_64)
   - Return to userspace at new entry point (_start)

**Interrupt/Exception Flow:**

1. Hardware interrupt/exception fires
2. HAL interrupt handler (`src/arch/x86_64/kernel/interrupts/handlers.zig` or aarch64 equivalent):
   - Save full CPU state (registers, flags)
   - Dispatch based on vector number
   - Special cases:
     - Page fault: Check if in copy_from_user fixup range; if so, redirect to fixup handler
     - Guard page access: Check if kernel thread stack guard; if so, panic with "stack overflow"
     - FPU unavailable: Lazy FPU state restore on context switch
     - Timer tick (vector 32/x86_64): Call scheduler.timerTick() for preemption
3. Handler executes (may block, reschedule, etc.)
4. HAL restore: Return to interrupted context

**State Management:**

- **Process State**: Linked list of processes in `process_tree_lock` RwLock; scheduler has per-CPU ready queues
- **Thread State**: Each thread has `Thread` struct with execution context (regs, stack, page table root, signal handlers)
- **Address Space**: Each process has `UserVmm` with VMAs (virtual memory areas), page table root (TTBR0 on aarch64, CR3 on x86_64)
- **Synchronization**: Spinlocks for fast paths (scheduler), RwLocks for process tree, Mutexes for I/O operations
- **ASLR**: Randomized kernel/user stack positions via `src/kernel/mm/aslr.zig`

## Key Abstractions

**UserPtr (Memory Safety):**
- Purpose: Safe user->kernel memory copying with bounds and permission checks
- Examples: Used in all syscall handlers before accessing user buffers
- Pattern: Construct `UserPtr` from userspace address, call `read`/`write` methods which verify SMAP compliance

**SyscallError (ABI Consistency):**
- Purpose: Map Zig error types to Linux errno values consistently across architectures
- Pattern: All syscall handlers return `SyscallError!T`; dispatcher converts to negative errno before SYSRET

**VirtualMemoryArea (VMA):**
- Purpose: Track contiguous user memory regions with permissions/flags
- Location: `src/kernel/mm/user_vmm.zig`
- Used for: mmap/munmap, fault handling, ASLR region allocation

**Thread/Process Hierarchy:**
- **Process**: User-visible process with PID, address space, file descriptor table, signal handlers
- **Thread**: CPU execution context with TID, kernel stack, CPU registers
- One process per thread for now (no multi-threading within process); multiple processes have separate address spaces

**FileDescriptor/Inode Abstraction:**
- Purpose: Uniform interface to files, directories, devices, pipes, sockets
- Location: `src/kernel/fs/fd.zig`, VFS in `src/fs/`
- Pattern: Each FD points to a Vnode (VFS inode); Vnode methods abstract underlying filesystem

## Entry Points

**Bootloader Entry Point:**
- Location: `src/boot/uefi/main.zig`
- Triggers: UEFI firmware calls EFI application entry point
- Responsibilities: UEFI services (allocate memory, load kernel ELF, setup BootInfo, jump to kernel)

**Kernel Entry Point:**
- Location: `src/kernel/core/main.zig:_start`
- Triggers: UEFI bootloader passes control via 64-bit call to _start with BootInfo pointer
- Responsibilities:
  1. Validate BootInfo (HHDM offset, memory map, kernel addresses)
  2. Initialize HAL (serial, GDT, IDT, interrupts, paging)
  3. Initialize memory subsystems (PMM, VMM, layout with ASLR)
  4. Initialize filesystem (InitRD from BootInfo)
  5. Initialize process management (first process loading)
  6. Initialize scheduler (per-CPU data, ready queues)
  7. Initialize drivers (PCI, network, USB, video via init_hw.zig)
  8. Hand off to scheduler.start() which never returns

**First Userspace Process (PID 1):**
- Location: Selected from InitRD by `src/kernel/core/init_proc.zig`
- Candidates (in preference order): test_runner, shell, doom, httpd
- Responsibilities: User-facing shell or service loop

**Interrupt Entry Points:**
- **SYSCALL Entry** (x86_64): `src/arch/x86_64/asm_helpers.S:_syscall_entry`
  - Triggered by `syscall` instruction from userspace
  - Performs stack switch, SWAPGS, calls dispatch_syscall

- **Exception Entry** (All archs): Vectors 0-31 mapped in IDT (x86_64) or handled in aarch64 exception table
  - Examples: Page Fault (#PF = 14), General Protection Fault (#GPF = 13), Divide by Zero (#DE = 0)

- **IRQ Entry** (x86_64): Vectors 32-47 (legacy PIC), 32+ (MSI-X)
  - Timer (vector 32 by default): Triggers scheduler preemption
  - Keyboard (vector 33): Character injection into input buffer
  - Serial (vector 34): Character reading for userspace serial driver
  - NIC (vector 34+MSI-X allocated): Packet RX/TX processing
  - USB (vector 34+MSI-X allocated): Transfer completion
  - Disk (vector 34+MSI-X allocated): I/O completion

## Error Handling

**Strategy:** Early panic for unrecoverable errors (corrupted kernel state), graceful fallback for missing features

**Patterns:**

**Syscall Errors (Recoverable):**
- Syscall handler returns `error.EPERM`, `error.EFAULT`, etc.
- Dispatcher converts to negative errno (e.g., `-EPERM = -1`)
- User process continues, can inspect errno and retry/handle

**Page Faults (May be recoverable):**
- Fault handler checks if in valid VMA with correct permissions
  - If yes: Allocate page, populate, return to faulting instruction
  - If no: Kill process with SIGSEGV signal
  - If in copy_from_user fixup: Jump to fixup handler (return EFAULT)

**Panic (Unrecoverable):**
- Examples: Corrupted kernel heap, unhandled exception, stack overflow
- Handler: Disables interrupts, prints stack trace to serial, enters infinite halt loop
- Location: `src/kernel/core/panic.zig`

**Timeout Handling:**
- Kernel uses timeout values for blocking syscalls (poll, select, futex_wait)
- Timer interrupt fires at timeout expiry, wakes waiting thread with ETIMEDOUT
- No busy-spin; scheduler handles wake-on-timeout via timeout_queue

## Cross-Cutting Concerns

**Logging:**
- Kernel uses `std.log` redirected to `console` backend via `kernelLogFn` in `src/kernel/core/main.zig`
- Console backends include UART (serial) and video framebuffer (framebuffer-based)
- Log levels: debug, info, warn, err

**Validation:**
- All user pointers validated via UserPtr before kernel access
- All syscall args range-checked (file descriptors, sizes, counts)
- Boot info validated before use (HHDM offset, memory map bounds)
- ACPI structures validated (signature, checksum, length)

**Authentication:**
- Capability system in `src/kernel/proc/capabilities/` (not traditional UNIX uid/gid)
- Checks: Can process access MMIO? Can process enumerate PCI? Can process trace other process?
- Default: Only kernel can access hardware; userspace must have explicit capability

**Signal Delivery:**
- Signals queued in process struct
- Delivered on next syscall exit or preemption
- Handler execution: Kernel sets up user-space stack frame with return trampoline, jumps to handler
- Async-safety: Only async-signal-safe syscalls can be called from handler

**Memory Safety:**
- Stack canaries: `__stack_chk_guard` and `__stack_chk_fail` for buffer overflow detection
- ASLR: Kernel/user space base addresses randomized at boot
- SMEP/SMAP: CPU features prevent kernel execution of user code, kernel access to user memory without STAC/CLAC

**Synchronization (Lock Ordering):**
Strict lock ordering (lower numbers acquired first) prevents deadlock:
1. `process_tree_lock` (RwLock, protects process/thread tree)
2. `SFS.alloc_lock` (Filesystem allocation)
3. `FileDescriptor.lock` (Individual FD locks)
4. `Scheduler/Runqueue Lock` (Per-CPU scheduler data)
5. `tcp_state.lock` (Global TCP state)
6. `socket/state.lock` (Socket table)
7. Per-socket `sock.lock`
8. `UserVmm.lock` (Process address space, read mode for translation, write for munmap)
8.5. `devices_lock` (USB devices RwLock)
8.6. `UsbDevice.device_lock` (Per-device spinlock)
9. `FutexBucket.lock` (Per-bucket futex spinlock)
10. `pmm.lock` (Internal PMM spinlock, not held across calls)

