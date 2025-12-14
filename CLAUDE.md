# zscapek Development Guidelines

A Zig-based microkernel for x86_64 using the Limine bootloader protocol.

## Active Technologies
- Zig 0.15.x (freestanding x86_64 target)
- Limine bootloader (v5.x protocol)
- QEMU for emulation

## Project Structure

See [FILESYSTEM.md](docs/FILESYSTEM.md) for complete directory layout. Key directories:

- `src/arch/` - HAL (x86_64, aarch64) - ONLY place for inline assembly
- `src/kernel/` - Core kernel (scheduler, heap, syscalls, ELF loader)
- `src/net/` - TCP/IP stack, sockets, DNS
- `src/fs/` - Filesystem (initrd)
- `src/drivers/` - Device drivers (PCI, E1000e NIC)
- `src/user/` - Userland programs (shell, httpd)
- `specs/` - Feature specifications

When creating new files or folders, update this document.

## Commands

```bash
zig build              # Build kernel + userland
zig build iso          # Create bootable ISO
zig build run          # Build ISO and run in QEMU
zig build test         # Run unit tests

Mode,Command,Safety Checks,Optimizations,Best For
Debug,zig build -Doptimize=Debug,On,Off,Development
ReleaseSafe,zig build -Doptimize=ReleaseSafe,On,On,Production (Secure)
ReleaseFast,zig build -Doptimize=ReleaseFast,Off,On,Raw Speed (Gaming/Sim)
ReleaseSmall,zig build -Doptimize=ReleaseSmall,Off,Size,Embedded
```

For macOS with Apple Silicon:
```bash
zig build run -Dbios=/opt/homebrew/share/qemu/edk2-x86_64-code.fd
```

## Architecture Rules

See [BOOT_ARCHITECTURE.md](docs/BOOT_ARCHITECTURE.md) for boot process details.

### HAL Barrier (Strict Layering)
- **FORBIDDEN**: `asm volatile`, direct port I/O, or CPU register access outside `src/arch/`
- **REQUIRED**: Kernel code must use the `hal` module interface
- Assembly helpers go in `src/arch/x86_64/asm_helpers.S`

### Memory Hygiene
- All dynamic memory uses the kernel heap allocator
- Heap provides 16-byte aligned allocations (required for SSE/FPU state)
- Zero-copy patterns for networking until userspace boundary

### Linux Compatibility
- Syscall numbers follow Linux x86_64 ABI (see `specs/syscall-table.md`)
- Error codes use standard Linux errno values

## Syscall Handlers

Refer to [SYSCALL.md](docs/SYSCALL.md) for syscall handler details and build system integration.

### Handler Files (`src/kernel/syscall/`)
- `base.zig` - Shared state (current_process, fd_table, user_vmm) and accessors
- `process.zig` - Process lifecycle (exit, wait4, getpid, getppid, getuid, getgid)
- `signals.zig` - Signal handling (rt_sigprocmask, rt_sigaction, rt_sigreturn)
- `scheduling.zig` - Scheduler (sched_yield, nanosleep, select, clock_gettime)
- `io.zig` - I/O operations (read, write, writev, stat, fstat, ioctl, fcntl)
- `fd.zig` - File descriptors (open, close, dup, dup2, pipe, lseek)
- `memory.zig` - Memory management (mmap, mprotect, munmap, brk)
- `execution.zig` - Process execution (fork, execve, arch_prctl, fb syscalls)
- `custom.zig` - Zscapek extensions (debug_log, putchar, getchar, read_scancode)
- `net.zig` - Network syscalls (socket, bind, listen, accept, connect, etc.)
- `random.zig` - Random number syscalls (getrandom)
- `table.zig` - Dispatch table (auto-discovers handlers at comptime)
- `user_mem.zig` - User pointer validation utilities

### Naming Convention
Handler functions MUST be named `sys_<syscall_name>` in lowercase:
```zig
pub fn sys_read(...) SyscallError!usize { ... }
pub fn sys_getrandom(...) SyscallError!usize { ... }
pub fn sys_socket(...) SyscallError!usize { ... }
```

The dispatch table (`table.zig`) uses comptime reflection to match `SYS_READ` from `uapi/syscalls.zig` to `sys_read` in handler modules.

### Error Handling Pattern

**Required**: Use Zig error unions with `SyscallError`:
```zig
const SyscallError = uapi.errno.SyscallError;

pub fn sys_read(fd: usize, buf_ptr: usize, count: usize) SyscallError!usize {
    if (!isValidUserPtr(buf_ptr, count)) {
        return error.EFAULT;
    }
    // ... implementation ...
    return bytes_read;
}
```

**Forbidden** (legacy pattern, do not use in new code):
```zig
pub fn sys_read(...) isize {
    if (!isValidUserPtr(buf_ptr, count)) {
        return Errno.EFAULT.toReturn();  // Don't do this
    }
    return @intCast(bytes_read);
}
```

### Error Conversion

The dispatch layer (`callHandler` in `table.zig`) automatically converts error unions to negative errno values at the syscall boundary. Handlers should never manually convert errors.

For subsystem errors (e.g., socket layer), create a conversion helper:
```zig
fn socketErrorToSyscallError(err: socket.SocketError) SyscallError {
    return switch (err) {
        socket.SocketError.AddrInUse => error.EADDRINUSE,
        socket.SocketError.WouldBlock => error.EAGAIN,
        // ... complete mapping
    };
}
```

### Exception: Non-returning Handlers
Handlers that never return (e.g., `sys_exit`, `sys_exit_group`) may use `isize` since there is no success value:
```zig
pub fn sys_exit(status: usize) isize {
    process.exit(@truncate(status));
    unreachable;
}
```

### Adding New Syscalls
1. Add syscall number to `src/uapi/syscalls.zig` as `SYS_NAME`
2. Create handler as `pub fn sys_name(...) SyscallError!usize` in appropriate file
3. Dispatch table auto-discovers it at comptime (no manual registration needed)

## Coding Style

- **Version**: Zig 0.15.x
- **Naming**: `snake_case` for functions/vars, `PascalCase` for structs/types
- **Errors**: Use `try` or explicit handling; avoid `catch unreachable` unless panic intended
- **Types**: Explicit integer widths (`u64`, `usize`)

### Zig 0.15.x Inline Assembly

```zig
// Clobber syntax
asm volatile ("cli"
    :
    :
    : .{ .memory = true }
);

// Register constraints
asm volatile ("out %[data], %[port]"
    :
    : [port] "{dx}" (port),
      [data] "{al}" (data),
);
```

- **lgdt/lidt**: Use separate `.S` assembly file (Zig cannot express indirect memory operands)
- **Naked functions**: Can ONLY contain inline assembly, no Zig code

## Testing & Debugging

- **Emulation**: QEMU with `-accel tcg` (required on Apple Silicon)
- **Serial output**: `-serial stdio` captures kernel logs
- **Debug builds**: `zig build -Doptimize=Debug`

## Key Files

- `docs/FILESYSTEM.md` - Complete project structure
- `specs/syscall-table.md` - Authoritative syscall numbers
- `src/lib/limine.zig` - Limine protocol bindings
- `src/kernel/main.zig` - Kernel entry point
- `src/arch/x86_64/asm_helpers.S` - Low-level assembly routines
- `limine.cfg` - Bootloader configuration
- `src/fs/initrd.zig` - InitRD TAR filesystem parser

## InitRD Setup

The kernel loads an optional InitRD (Initial RAM Disk) in USTAR TAR format. Files in the initrd are accessible via `sys_open` syscalls.

### Creating InitRD

```bash
# Create contents directory
mkdir -p initrd_contents/etc
echo "config data" > initrd_contents/etc/config

# Create USTAR TAR (required format)
tar --format=ustar -cvf initrd.tar -C initrd_contents .

# Copy to ISO root
cp initrd.tar iso_root/boot/initrd.tar
```

### Limine Configuration

Add to `limine.cfg` after the kernel module:

```
MODULE_PATH=boot:///boot/initrd.tar
MODULE_CMDLINE=initrd
```

### Detection Logic

The kernel (`src/kernel/main.zig:initInitRD`) scans Limine modules for:
- Cmdline containing "initrd" or ".tar"
- Path containing "initrd" or ".tar"

When found, it initializes `fs.initrd.InitRD.instance` with the module data.

## Agent Instructions

- Use zig-programming skill when writing Zig code
- Use subagents for research or context7 for documentation
- No emojis or em dashes
- Comments explain "why", not "what"

## Zig Best Practices for Speed and Slice Safety

| Rule | Rationale (Security) |
| :--- | :--- |
| **1. Use Safe Build Modes by Default** | Compile your code with **`Debug`** (default) or **`ReleaseSafe`** (optimized, but with checks). These modes automatically enable **array bounds checking** and **integer overflow checking**, which are the main defense against buffer overruns when working with slices. |
| **2. Leverage Slices (`[]T`) and Const Slices (`[]const T`)** | Slices explicitly carry their length, which the compiler uses for the bounds checks mentioned above. Avoid using raw "many-item pointers" (`[*]T`) unless you are very certain you know the length and are manually managing safety.  |
| **3. Use `[]const T` for Read-Only Data** | Pass slices as `[]const T` whenever a function doesn't need to modify the data. This provides a compile-time guarantee that data cannot be accidentally changed, improving code safety and clarity. |
| **4. Avoid Dangling Slices/Pointers** | **Never** return a slice or pointer to memory allocated on a function's stack (a local variable that goes out of scope). This leads to **use-after-free** bugs. For memory that must persist beyond the current scope, use an **allocator** to manage heap memory, or ensure the slice points to a memory region with an explicitly managed lifetime. |
| **5. Be Explicit with Lifetime Management (Allocators)** | When allocating slices on the heap (e.g., using `std.mem.Allocator.alloc`), use `defer` to ensure the memory is freed. The `GeneralPurposeAllocator` (`std.heap.GeneralPurposeAllocator`) in debug builds is excellent for runtime detection of memory leaks, use-after-free, and double-free errors. |
| **6. Only Disable Safety for Bottlenecks** | For extreme performance gains, you can selectively disable runtime safety checks using `@setRuntimeSafety(false)` or compile with **`ReleaseFast`**. However, this should be **isolated** to small, heavily-tested functions, as it sacrifices the core security feature (bounds checking) that slices provide. |
| **7. Minimize Heap Allocations** | Heap allocations are slow. Prefer stack-allocated arrays and slices of those arrays, or use specialized allocators like **Arena Allocators** (`std.heap.ArenaAllocator`) to reduce allocation/deallocation overhead for temporary data. Slices themselves are cheap views, not allocations. |
| **8. Optimize Slicing Operations** | The Zig compiler is smart. Repeated slicing operations (e.g., slicing a slice) are often optimized into a single, efficient operation at compile time, leading to a zero-cost abstraction. Trust the built-in slicing (`array[start..end]`) before resorting to manual pointer manipulation. |
| **9. Prefer Contiguous Memory Access** | Use slices to process large, contiguous blocks of memory (arrays) with simple loops (`for (slice) |item|`). This maximizes **data locality** and allows the compiler and hardware to make better use of **CPU caches** and potentially use **SIMD** instructions for vectorized operations. |

* **Handle All Errors (Avoid Panics):** Use Zig's `error` unions and the `try`/`catch` keywords. This prevents unexpected control flow interruptions and promotes explicit error handling, making resource management (like freeing slice memory) more reliable, especially with `defer` and `errdefer`.
* **Avoid Unsafe C-style Idioms:** Zig's standard library and slices replace many C idioms like null-terminated strings (Zig uses `[:0]const u8` when needed for C interop, but `[]const u8` for pure Zig strings) and raw pointer arithmetic. Use the Zig-native slices and functions for better safety.
* **No undefined:** Avoid var x: i32 = undefined; unless you have a strict performance reason and initialize it immediately after.
* **No try in defer:** Do not put code that can fail inside a defer block (it swallows errors).
* **Checked Arithmetic:** Zig checks integer overflow by default. Use wrapping operators (e.g., +% for wrapping add) only if you explicitly want that behavior.
* **comptime:** Static Verification
This is Zig's "killer feature" for both speed and security. You can run arbitrary Zig code during compilation.
Best Practice: Use comptime checks to enforce invariants that C would check at runtime (or assert).
Speed Benefit: Pre-calculate complex lookup tables or math at compile time so the runtime cost is zero.
```
fn Matrix(comptime rows: usize, comptime cols: usize) type {
    if (rows != cols) @compileError("Matrix must be square!");
    return [rows][cols]f32;
}
```
- .error is a reserved word in Zig

### Threading Best Practices (ABI Safety)
When creating kernel threads that need access to context (e.g., driver instances), do **not** rely on Zig method calls or global state. The safest pattern is:
1. Define the entry point as `fn entry(ctx: ?*anyopaque) callconv(.c) void`.
2. Pass the context pointer (e.g., `self`) during thread creation.
3. In the entry point, cast `ctx` back to the concrete type: `const self: *Type = @ptrCast(@alignCast(ptr))`.
4. This ensures ABI compatibility (System V AMD64 passes 1st arg in RDI, which `createKernelThread` sets up) and avoids "NULL self" crashes caused by mismatching Zig vs C calling conventions.