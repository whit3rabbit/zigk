# Coding Conventions

**Analysis Date:** 2026-02-06

## Naming Patterns

**Files:**
- Syscall handlers: `sys_snake_case.zig` (e.g., `sys_stat`, `sys_fork`)
- Module organization: Lowercase with underscores (e.g., `user_mem.zig`, `error_helpers.zig`)
- Test files: `*_test.zig` or `*_tests.zig` suffix
- Constants: `UPPER_SNAKE_CASE` (e.g., `MAX_PATH_LEN`, `USER_SPACE_START`)

**Functions:**
- Syscall implementations: `sys_<name>(args) SyscallError!usize` (e.g., `sys_open`, `sys_read`)
- Internal functions: `camelCase` (e.g., `copyStringFromUser`, `isValidUserAccess`, `mapDeviceError`)
- Helper functions: Descriptive camelCase (e.g., `safeFdCast`, `perform_write_locked`)

**Variables:**
- Local/field variables: `snake_case` (e.g., `fd_num`, `start_offset`, `bytes_written`)
- Struct/type members: `snake_case` (e.g., `private_data`, `next_sibling`)
- Boolean flags: Descriptive (e.g., `wnohang`, `has_children`, `has_matching_child`)

**Types:**
- Struct names: `PascalCase` (e.g., `Process`, `FileDescriptor`, `UserPtr`)
- Enum names: `PascalCase` (e.g., `AccessMode`, `SyscallError`)
- Type aliases: `PascalCase` (e.g., `Errno`, `FdTable`)

## Code Style

**Formatting:**
- No explicit formatter configured (Zig 0.16.x default style)
- Indentation: 4 spaces
- Line length: No strict limit, but aim for readability
- Brace style: K&R style (opening brace on same line)

**Imports:**
- Standard library: `const std = @import("std");`
- Kernel modules: `const <module> = @import("<module>");`
- Package imports: `const <name> = @import("<name>");` (matches build.zig package names)
- Local imports: `const <module> = @import("<path>.zig");`

## Import Organization

**Order:**
1. Standard library imports (`std`)
2. Internal module imports (uapi, heap, fs, console, hal, etc.)
3. Local/same-directory imports (base.zig, user_mem.zig)
4. Type re-exports and const aliases

**Path Aliases (from build.zig packages):**
- `@import("std")` - Zig standard library
- `@import("uapi")` - User API definitions and syscall numbers
- `@import("heap")` - Memory allocator
- `@import("hal")` - Hardware abstraction layer
- `@import("fs")` - Filesystem VFS layer
- `@import("console")` - Debug logging
- `@import("sched")` - Scheduler
- `@import("process")` - Process management
- `@import("fd")` - File descriptor management
- `@import("user_vmm")` - User virtual memory
- `@import("signal")` - Signal handling

**Local module imports in syscall handlers:**
```zig
const base = @import("base.zig");           // Shared state (process, FD table)
const user_mem = @import("user_mem.zig");   // User pointer validation
const error_helpers = @import("error_helpers.zig"); // Error mapping
const utils = @import("utils.zig");         // Helper functions
```

## Error Handling

**Syscall error return type:**
All syscall implementations return `SyscallError!usize`:
```zig
pub fn sys_open(path_ptr: usize, flags: usize, mode: usize) SyscallError!usize {
    // Validate inputs
    if (!isValidUserAccess(path_ptr, path_len, .Read)) return error.EFAULT;

    // Perform operation
    // ...

    // Return usize on success, or error on failure
    return bytes_written;
}
```

**Error types:**
- `SyscallError` is defined in `uapi.errno` and maps to Linux errno values
- Common errors: `EFAULT`, `EINVAL`, `ENOMEM`, `ENOENT`, `EBADF`, `EACCES`, `ENOTDIR`, `EISDIR`, `EEXIST`
- Device layer errors are mapped via `error_helpers.mapDeviceError(isize)`

**Error handling patterns:**

1. **User pointer validation:**
```zig
if (!isValidUserAccess(ptr, len, AccessMode.Write)) {
    return error.EFAULT;
}
```

2. **Device layer error mapping:**
```zig
const result = try error_helpers.mapWriteError(do_write_locked(fd, kbuf));
```

3. **Allocation error handling:**
```zig
const buf = heap.allocator().alloc(u8, size) catch {
    return error.ENOMEM;
};
defer heap.allocator().free(buf);
```

4. **Catch-specific errors:**
```zig
const fd = syscall.open("/path", flags, mode) catch |err| {
    return if (err == error.EROFS or err == error.ENOENT) error.SkipTest else err;
};
```

## Memory Management

**Allocation pattern:**
- Allocate from heap: `const buf = heap.allocator().alloc(u8, size) catch return error.ENOMEM;`
- Deallocate with defer: `defer heap.allocator().free(buf);`
- Always pair allocations with deferred frees to prevent leaks

**User pointer safety:**
- Never dereference user pointers directly
- Use `UserPtr` wrapper: `const uptr = UserPtr.from(ptr_addr);`
- Copy via safe functions: `uptr.copyToKernel(buf)` or `uptr.readValue(T)`
- Validate bounds before copying: `isValidUserAccess(ptr, len, mode)`

**Buffer handling for user copies:**
1. Allocate kernel buffer: `const kbuf = heap.allocator().alloc(u8, size) catch ...`
2. Copy from user: `UserPtr.from(user_ptr).copyToKernel(kbuf)` or `copyFromUser(kbuf, user_ptr)`
3. Process kernel buffer (never touch original user pointer)
4. Defer free: `defer heap.allocator().free(kbuf);`

## Logging

**Framework:** Custom `console` module (`@import("console")`)

**Available functions:**
- `console.debug(fmt, args)` - Debug-level information
- `console.info(fmt, args)` - Informational messages
- `console.err(fmt, args)` - Error messages
- `console.warn(fmt, args)` - Warning messages (if available)

**Patterns:**
- Use format strings with placeholders: `console.debug("Process: Using init process (pid={})", .{init_process_cache.?.pid})`
- Pass arguments as tuple: `.{value1, value2, value3}`
- In tests, use `syscall.debug_print()` for userspace test output

**Example:**
```zig
console.err("sys_fork: Failed to fork process: {}", .{err});
console.debug("sys_execve: path='{s}'", .{path});
```

## Comments

**When to comment:**
- Complex algorithm logic (security-critical paths)
- Non-obvious behavior (e.g., TOCTOU race condition handling, lock ordering)
- TODO/FIXME items for known limitations
- Architecture decisions (e.g., why bounds check before page mapping)

**When NOT to comment:**
- Obvious code that reads clearly
- Simple variable assignments
- Standard patterns (defer, lock acquire/release)

**Style:**
- Use `//` for single-line comments
- Use `/* */` for multi-line documentation (rare)
- Doc comments for public functions: Use comment block before function

**Example:**
```zig
/// Validate that a user pointer is within the userspace address range.
/// Returns true if the pointer appears valid for userspace access.
///
/// Note: This is currently a bounds check only. Phase 2 will add page mapping
/// verification to ensure pages are actually mapped and accessible.
pub fn isValidUserPtr(ptr: usize, len: usize) bool {
    // Null pointer is never valid
    if (ptr == 0) return false;
    // ...
}
```

## Function Design

**Size guidelines:**
- Syscall handlers: 50-150 lines typical
- Complex operations (fork, exec): 100-200 lines acceptable
- Helpers: 10-40 lines preferred

**Parameters:**
- Syscall args passed as separate `usize` parameters matching Linux ABI
- Complex operations use structs (passed by pointer with locks)
- Slice parameters use `[]T` not `[*]T`

**Return values:**
- Syscalls: `SyscallError!usize` (usize = syscall return value)
- Helpers: Specific types or error unions (`!T`)
- Zero return: `return 0;` for success (Linux convention)
- No return value needed: `return error.EFAULT;` propagates upward

## Module Design

**Exports (pub):**
- Syscall handlers: All are `pub fn sys_*(...)`
- Validation functions: `pub fn isValidUserPtr`, `pub fn isValidUserAccess`
- Type-safe wrappers: `pub const UserPtr = struct { ... }`
- Constants: `pub const MAX_PATH_LEN`, `pub const USER_SPACE_START`

**Barrel files:**
- `io/root.zig` - Aggregates all I/O syscalls
- `process/root.zig` - Aggregates all process syscalls
- `core/base.zig` - Shared state (process, FD table, user memory)

**Organization pattern:**
```
src/kernel/sys/syscall/
├── core/
│   ├── base.zig           # Shared process/FD/VM state
│   ├── user_mem.zig       # User pointer validation
│   ├── error_helpers.zig  # Error mapping
│   └── table.zig          # Dispatch table
├── io/                    # File I/O syscalls
│   ├── root.zig
│   ├── stat.zig
│   ├── read_write.zig
│   └── ...
├── process/               # Process control syscalls
│   ├── root.zig
│   ├── process.zig
│   └── ...
└── memory/                # Memory management syscalls
```

## Lock Ordering (CRITICAL)

To prevent deadlocks, locks must be acquired in this order (lower number = acquired first):

1. `process_tree_lock`
2. `SFS.alloc_lock` (Filesystem allocation)
3. `FileDescriptor.lock`
4. `Scheduler/Runqueue Lock`
5. `tcp_state.lock` (Global TCP state)
6. `socket/state.lock` (Socket table)
7. Per-socket `sock.lock` / Per-TCB `tcb.mutex`
8. `UserVmm.lock` (must NOT be held during sleep)
9. `devices_lock` (USB device array RwLock)
10. Per-device `device_lock` (USB)
11. `FutexBucket.lock` (per-bucket spinlock)
12. `pmm.lock` (internal PMM, not held across calls)

**Rule:** Never acquire lock N while holding lock N-1 or lower.

## TOCTOU Prevention (Security Pattern)

**Refresh state under lock:**
Never rely on cached metadata (size, permissions, flags) acquired before acquiring a lock. Always re-read/verify after the lock is acquired.

**Pattern:**
```zig
// Get initial state (unprotected)
const file_meta = fs.vfs.Vfs.statPath(path);
if (file_meta == null) return error.ENOENT;

// Acquire lock and RE-VERIFY
const held = sched.process_tree_lock.acquireWrite();
defer held.release();

// Check again - state may have changed!
var zombie_proc: ?*Process = null;
var has_children = false;
var child = current_proc.first_child;
while (child) |c| {
    // Re-check conditions inside the lock
    if (c.state == .Zombie) { ... }
}
```

## Security Patterns (UserPtr)

**Type-safe user pointer access:**
All user-provided pointers must use `UserPtr` to enforce bounds checking and SMAP compliance:

```zig
// Create UserPtr from syscall argument
const buf_ptr = UserPtr.from(buf_addr);

// Method 1: Copy to kernel buffer
var kbuf: [64]u8 = undefined;
const len = try buf_ptr.copyToKernel(&kbuf);

// Method 2: Read single value
const addr: sockaddr = try buf_ptr.readValue(sockaddr);

// Method 3: Write back to user
try buf_ptr.writeValue(result_struct);

// Method 4: Offset and access
try buf_ptr.offset(16).writeValue(@as(u32, 42));
```

## Path Canonicalization

**Security requirement for all path syscalls:**
Paths must be canonicalized to prevent directory traversal attacks:

```zig
fn canonicalizePath(path: []const u8, out_buf: []u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (path[0] != '/') return null;  // Require absolute path

    // Remove // duplicates
    // Remove . components (/a/./b -> /a/b)
    // REJECT .. components (security)
    // Return slice of buffer containing clean path
}
```

**Pattern:** Copy raw path from user, canonicalize it, then pass clean path to internal functions.

## Comptime Constants and Validation

**Use comptime validation for error constants:**
```zig
comptime {
    // Verify our errno constants match Linux x86_64 ABI
    std.debug.assert(LINUX_EIO == 5);
    std.debug.assert(LINUX_EAGAIN == 11);
}
```

**Use comptime for type enforcement:**
```zig
pub fn copyStructFromUser(comptime T: type, ptr: UserPtr) UserPtrError!T {
    comptime {
        const info = @typeInfo(T);
        if (info != .@"struct") {
            @compileError("copyStructFromUser requires a struct type, got " ++ @typeName(T));
        }
    }
    return ptr.readValue(T);
}
```

---

*Conventions analysis: 2026-02-06*
