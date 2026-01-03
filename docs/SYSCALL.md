# Syscall Architecture

Quick reference for the Zscapek syscall subsystem. Covers build system integration, dispatch mechanism, developer guidelines, and supported syscalls.

## Build System Integration

### Module Dependency Graph

```
build.zig
    |
    +-- uapi_module (src/uapi/root.zig)
    |       |-- syscalls/       <- Syscall number definitions
    |       |   |-- root.zig    <- Re-exports all numbers (linux + zscapek)
    |       |   |-- linux.zig   <- Standard Linux syscall numbers
    |       |   `-- zscapek.zig <- Custom Zscapek extensions
    |       `-- errno.zig       <- SyscallError type and errno conversion
    |
    +-- syscall_base_module (src/kernel/sys/syscall/core/base.zig)
    |       |-- Shared state: current_process, global_fd_table, global_user_vmm
    |       `-- Accessor functions for all handler modules
    |
    +-- Handler Modules (each imports base.zig + domain-specific deps)
    |       |-- syscall_process_module    -> sys/syscall/process/process.zig
    |       |-- syscall_signals_module    -> sys/syscall/process/signals.zig
    |       |-- syscall_scheduling_module -> sys/syscall/process/scheduling.zig
    |       |-- syscall_io_module         -> sys/syscall/io/root.zig
    |       |-- syscall_fd_module         -> sys/syscall/fs/fd.zig
    |       |-- syscall_memory_module     -> sys/syscall/memory/memory.zig
    |       |-- syscall_execution_module  -> sys/syscall/core/execution.zig
    |       |-- syscall_custom_module     -> sys/syscall/misc/custom.zig
    |       |-- syscall_net_module        -> sys/syscall/net/net.zig
    |       |-- syscall_random_module     -> sys/syscall/misc/random.zig
    |       |-- syscall_input_module      -> sys/syscall/hw/input.zig
    |       |-- syscall_ipc_module        -> sys/syscall/misc/ipc.zig
    |       |-- syscall_interrupt_module  -> sys/syscall/hw/interrupt.zig
    |       |-- syscall_port_io_module    -> sys/syscall/hw/port_io.zig
    |       |-- syscall_mmio_module       -> sys/syscall/memory/mmio.zig
    |       |-- syscall_pci_module        -> sys/syscall/net/pci_syscall.zig
    |       |-- syscall_ring_module       -> sys/syscall/hw/ring.zig
    |       |-- syscall_hypervisor_module -> sys/syscall/hw/hypervisor.zig
    |       `-- syscall_fs_handlers_module -> sys/syscall/fs/fs_handlers.zig
    |
    +-- syscall_table_module (src/kernel/sys/syscall/core/table.zig)
            |-- Imports all handler modules
            `-- Comptime dispatch via reflection on uapi.syscalls
```

### How build.zig Wires Syscalls

1. **UAPI Module** - Defines syscall numbers in `src/uapi/syscalls/root.zig` by re-exporting from `linux.zig` and `zscapek.zig`.
2. **Base Module** - Provides shared state accessed by all handlers
3. **Handler Modules** - Each handler file is a separate Zig module with explicit imports
4. **Table Module** - Uses comptime reflection to auto-discover handlers

## Dispatch Mechanism

### Entry Point

Assembly entry (`src/arch/x86_64/asm_helpers.S`) saves registers and calls:
```zig
pub export fn dispatch_syscall(frame: *SyscallFrame) callconv(.c) void
```

### Comptime Handler Discovery

`table.zig` builds a dispatch table at compile time:

1. Iterates over `uapi.syscalls` declarations
2. Converts `SYS_READ` to `sys_read` via `toSyscallName()`
3. Searches handler modules in priority order (net -> process -> signals -> ...)
4. Builds array of `{ syscall_number, handler_module, handler_name }`

Runtime dispatch is an unrolled loop that LLVM optimizes to a jump table.

Networking syscalls live exclusively in `net.zig` (see `docs/FILESYSTEM.md`).
`net.zig` matches all network syscall numbers defined in `src/uapi/syscalls/root.zig`.
Do not add socket stubs to other modules. If a syscall has no handler in any
module, dispatch returns `error.ENOSYS`.

### Handler Signature

**Preferred (error union):**
```zig
pub fn sys_read(fd: usize, buf_ptr: usize, count: usize) SyscallError!usize {
    // Return bytes read on success, or error.EFAULT, error.EBADF, etc.
}
```

**Legacy (direct isize):**
```zig
pub fn sys_exit(status: usize) isize {
    // For non-returning syscalls only
}
```

The `callHandler` function auto-converts error unions to negative errno at the boundary.

## Developer Guidelines

### Best Practices

1.  **Argument Handling**:
    - Syscalls accept up to 6 arguments (`usize`).
    - Pointers must be validated using `user_mem.isValidUserPtr` or `user_mem.isValidUserAccess`.
    - Always use `usize` for arguments in the signature; cast to specific types (e.g., `i32`) inside the function if needed.

2.  **Concurrency & Safety**:
    - Syscalls run in the context of the calling thread (Ring 0).
    - Blocking is allowed (e.g., `sched.block()`), but be mindful of holding locks.
    - Use `sched.process_tree_lock` when iterating processes.
    - Ensure TCB safety when accessing thread-local data.
    - Protect shared kernel data structures (like `FdTable`) with appropriate locks.

3.  **Return Values**:
    - Use `SyscallError!usize` for standard error handling.
    - Success values must be non-negative (0 or positive).
    - Errors are automatically converted to negative errno values by the dispatch layer.
    - `error.ENOSYS` should be returned for unimplemented functionality.

4.  **Memory Access**:
    - Never dereference user pointers directly. Use `UserPtr` helpers.
    - Allocate kernel buffers for large data transfers (avoid large stack allocations).
    - Be aware of the `AccessMode` (Read/Write/Exec) when validating pointers.

5.  **Debugging**:
    - Use `console.debug` sparingly; it can flood the logs.
    - `strace`-like functionality is available via the `debug_enabled` build flag.

## Adding New Syscalls

   // In src/uapi/syscalls/zscapek.zig (for custom) or linux.zig
   pub const SYS_MYSYSCALL: usize = 999;
   ```

2. Create handler in appropriate module (e.g., `io.zig`):
   ```zig
   pub fn sys_mysyscall(arg1: usize, arg2: usize) SyscallError!usize {
       // Implementation
       return result;
   }
   ```

3. No registration needed - comptime reflection finds it automatically

## File Organization

```
src/kernel/sys/syscall/
    core/           - Core infrastructure
        base.zig       - Shared state (current_process, fd_table, user_vmm)
        table.zig      - Dispatch table (comptime reflection)
        user_mem.zig   - User pointer validation utilities
        execution.zig  - Process execution (fork, execve, arch_prctl)
        error_helpers.zig - Error handling utilities

    process/        - Process management
        process.zig    - Process lifecycle (exit, wait4, getpid, getppid, getuid, getgid)
        signals.zig    - Signal handling (rt_sigprocmask, rt_sigaction, rt_sigreturn)
        scheduling.zig - Scheduler (sched_yield, nanosleep, select, clock_gettime)

    fs/             - Filesystem syscalls
        fd.zig         - File descriptors (open, close, dup, dup2, pipe, lseek)
        fs_handlers.zig- Filesystem operations (mount, umount)

    memory/         - Memory management
        memory.zig     - Memory ops (mmap, mprotect, munmap, brk)
        mmio.zig       - MMIO mapping for userspace drivers

    net/            - Networking
        net.zig        - Sockets (socket, bind, listen, accept, connect, send, recv, poll)
        pci_syscall.zig- PCI configuration and enumeration

    hw/             - Hardware I/O
        input.zig      - Input devices (mouse, keyboard events)
        interrupt.zig  - Userspace interrupt waiting
        port_io.zig    - Raw port I/O access
        ring.zig       - Ring buffer IPC (create, attach, wait, notify)
        hypervisor.zig - Hypervisor access (VMware hypercall, detection)

    io/             - Async I/O
        root.zig       - I/O operations (read, write, writev, stat, fstat, ioctl, fcntl)

    io_uring/       - io_uring subsystem
        root.zig       - io_uring setup, enter, register

    misc/           - Miscellaneous
        custom.zig     - Zscapek extensions (debug_log, putchar, getchar, read_scancode)
        random.zig     - Random numbers (getrandom)
        ipc.zig        - Inter-process communication
```

## Syscall Quick Reference

### Conventions

- **ABI**: Linux x86_64 syscall convention
- **Entry**: RAX=number, RDI/RSI/RDX/R10/R8/R9=args 1-6
- **Return**: RAX >= 0 success, RAX < 0 is -errno
- **Clobbers**: RCX, R11

### Linux-Compatible Syscalls (0-999)

| # | Name | Signature | Handler |
|---|------|-----------|---------|
| 0 | read | (fd, buf, count) -> ssize_t | io.zig |
| 1 | write | (fd, buf, count) -> ssize_t | io.zig |
| 2 | open | (path, flags, mode) -> fd | fd.zig |
| 3 | close | (fd) -> int | fd.zig |
| 4 | stat | (path, statbuf) -> int | io.zig |
| 5 | fstat | (fd, statbuf) -> int | io.zig |
| 6 | lstat | (path, statbuf) -> int | io.zig |
| 7 | poll | (ufds, nfds, timeout) -> int | net.zig |
| 8 | lseek | (fd, offset, whence) -> off_t | fd.zig |
| 9 | mmap | (addr, len, prot, flags, fd, off) -> addr | memory.zig |
| 10 | mprotect | (addr, len, prot) -> int | memory.zig |
| 11 | munmap | (addr, len) -> int | memory.zig |
| 12 | brk | (brk) -> addr | memory.zig |
| 13 | rt_sigaction | (sig, act, oldact, size) -> int | signals.zig |
| 14 | rt_sigprocmask | (how, set, oldset, size) -> int | signals.zig |
| 15 | rt_sigreturn | () -> noreturn | signals.zig |
| 16 | ioctl | (fd, cmd, arg) -> int | io.zig |
| 17 | pread64 | (fd, buf, count, off) -> ssize_t | io.zig (-) |
| 18 | pwrite64 | (fd, buf, count, off) -> ssize_t | io.zig (-) |
| 19 | readv | (fd, iov, iovcnt) -> ssize_t | io.zig (-) |
| 20 | writev | (fd, iov, iovcnt) -> ssize_t | io.zig |
| 21 | access | (path, mode) -> int | fd.zig |
| 22 | pipe | (pipefd) -> int | fd.zig |
| 23 | select | (nfds, r, w, e, timeout) -> int | scheduling.zig |
| 24 | sched_yield | () -> int | scheduling.zig |
| 32 | dup | (oldfd) -> newfd | fd.zig |
| 33 | dup2 | (oldfd, newfd) -> int | fd.zig |
| 35 | nanosleep | (req, rem) -> int | scheduling.zig |
| 39 | getpid | () -> pid_t | process.zig |
| 41 | socket | (domain, type, protocol) -> fd | net.zig |
| 42 | connect | (fd, addr, addrlen) -> int | net.zig |
| 43 | accept | (fd, addr, addrlen) -> fd | net.zig |
| 44 | sendto | (fd, buf, len, flags, addr, len) -> ssize_t | net.zig |
| 45 | recvfrom | (fd, buf, len, flags, addr, len) -> ssize_t | net.zig |
| 46 | sendmsg | (fd, msg, flags) -> ssize_t | net.zig |
| 47 | recvmsg | (fd, msg, flags) -> ssize_t | net.zig |
| 48 | shutdown | (fd, how) -> int | net.zig |
| 49 | bind | (fd, addr, addrlen) -> int | net.zig |
| 50 | listen | (fd, backlog) -> int | net.zig |
| 51 | getsockname | (fd, addr, addrlen) -> int | net.zig |
| 52 | getpeername | (fd, addr, addrlen) -> int | net.zig |
| 54 | setsockopt | (fd, level, name, val, len) -> int | net.zig |
| 55 | getsockopt | (fd, level, name, val, len) -> int | net.zig |
| 56 | clone | (flags, stack, ptid, ctid, tls) -> pid_t | execution.zig |
| 57 | fork | () -> pid_t | execution.zig |
| 59 | execve | (path, argv, envp) -> int | execution.zig |
| 60 | exit | (code) -> noreturn | process.zig |
| 61 | wait4 | (pid, wstatus, options, rusage) -> pid_t | process.zig |
| 62 | kill | (pid, sig) -> int | signals.zig |
| 63 | uname | (name) -> int | process.zig |
| 72 | fcntl | (fd, cmd, arg) -> int | io.zig |
| 74 | fsync | (fd) -> int | io.zig |
| 75 | fdatasync | (fd) -> int | io.zig |
| 76 | truncate | (path, length) -> int | io.zig |
| 77 | ftruncate | (fd, length) -> int | io.zig |
| 78 | getdents | (fd, dirp, count) -> int | io.zig (-) |
| 79 | getcwd | (buf, size) -> char* | io.zig |
| 80 | chdir | (path) -> int | io.zig |
| 81 | fchdir | (fd) -> int | io.zig (-) |
| 82 | rename | (old, new) -> int | io.zig |
| 83 | mkdir | (path, mode) -> int | io.zig |
| 84 | rmdir | (path) -> int | io.zig |
| 85 | creat | (path, mode) -> fd | fd.zig |
| 86 | link | (old, new) -> int | io.zig |
| 87 | unlink | (path) -> int | fs_handlers.zig |
| 88 | symlink | (target, link) -> int | io.zig |
| 89 | readlink | (path, buf, size) -> ssize_t | io.zig |
| 90 | chmod | (path, mode) -> int | io.zig |
| 91 | fchmod | (fd, mode) -> int | io.zig |
| 92 | chown | (path, uid, gid) -> int | io.zig |
| 93 | fchown | (fd, uid, gid) -> int | io.zig |
| 94 | lchown | (path, uid, gid) -> int | io.zig |
| 95 | umask | (mask) -> mode_t | process.zig |
| 96 | gettimeofday | (tv, tz) -> int | scheduling.zig |
| 97 | getrlimit | (res, rlim) -> int | process.zig |
| 102 | getuid | () -> uid_t | process.zig |
| 104 | getgid | () -> gid_t | process.zig |
| 105 | setuid | (uid) -> int | process.zig |
| 106 | setgid | (gid) -> int | process.zig |
| 107 | geteuid | () -> uid_t | process.zig |
| 108 | getegid | () -> gid_t | process.zig |
| 110 | getppid | () -> pid_t | process.zig |
| 117 | setresuid | (ruid, euid, suid) -> int | process.zig |
| 118 | getresuid | (ruid, euid, suid) -> int | process.zig |
| 119 | setresgid | (rgid, egid, sgid) -> int | process.zig |
| 120 | getresgid | (rgid, egid, sgid) -> int | process.zig |
| 137 | statfs | (path, buf) -> int | io.zig |
| 138 | fstatfs | (fd, buf) -> int | io.zig |
| 158 | arch_prctl | (code, addr) -> int | execution.zig |
| 160 | setrlimit | (res, rlim) -> int | process.zig |
| 164 | settimeofday | (tv, tz) -> int | scheduling.zig |
| 165 | mount | (src, tgt, type, flags, data) -> int | fs_handlers.zig |
| 166 | umount2 | (target, flags) -> int | fs_handlers.zig |
| 170 | sethostname | (name, len) -> int | process.zig |
| 171 | setdomainname | (name, len) -> int | process.zig |
| 200 | tkill | (tid, sig) -> int | signals.zig |
| 202 | futex | (uaddr, op, val, timeout, uaddr2, val3) -> int | scheduling.zig |
| 217 | getdents64 | (fd, dirp, count) -> int | io.zig |
| 218 | set_tid_address | (tidptr) -> pid_t | signals.zig |
| 228 | clock_gettime | (clk_id, tp) -> int | scheduling.zig |
| 229 | clock_getres | (clk_id, res) -> int | scheduling.zig |
| 231 | exit_group | (code) -> noreturn | process.zig |
| 232 | epoll_wait | (epfd, events, max, timeout) -> int | scheduling.zig |
| 233 | epoll_ctl | (epfd, op, fd, event) -> int | scheduling.zig |
| 234 | tgkill | (tgid, tid, sig) -> int | signals.zig |
| 257 | openat | (dfd, filename, flags, mode) -> int | fd.zig |
| 291 | epoll_create1 | (flags) -> int | scheduling.zig |
| 292 | dup3 | (old, new, flags) -> int | fd.zig |
| 293 | pipe2 | (pipefd, flags) -> int | fd.zig |
| 318 | getrandom | (buf, count, flags) -> ssize_t | random.zig |
| 425 | io_uring_setup | (entries, params) -> int | - |
| 426 | io_uring_enter | (fd, submit, complete, flags, sig) -> int | - |
| 427 | io_uring_register | (fd, opcode, arg, nr_args) -> int | - |

### Zscapek Custom Extensions (1000-1999)

| # | Name | Signature | Handler |
|---|------|-----------|---------|
| 1000 | debug_log | (buf, len) -> ssize_t | custom.zig |
| 1001 | get_fb_info | (info_ptr) -> int | execution.zig |
| 1002 | map_fb | () -> addr | execution.zig |
| 1003 | read_scancode | () -> int | custom.zig |
| 1004 | getchar | () -> int | custom.zig |
| 1005 | putchar | (c) -> int | custom.zig |
| 1006 | fb_flush | () -> int | execution.zig |
| 1010 | read_input_event | (event_ptr) -> int | input.zig |
| 1011 | get_cursor_position | (pos_ptr) -> int | input.zig |
| 1012 | set_cursor_bounds | (bounds_ptr) -> int | input.zig |
| 1013 | set_input_mode | (mode) -> int | input.zig |
| 1020 | send | (pid, msg, len) -> int | ipc.zig |
| 1021 | recv | (msg, len) -> int | ipc.zig |
| 1022 | wait_interrupt | (irq) -> int | interrupt.zig |
| 1025 | register_ipc_logger | () -> int | ipc.zig |
| 1030 | mmap_phys | (phys, size) -> virt | mmio.zig |
| 1031 | alloc_dma | (res, pages) -> int | mmio.zig |
| 1032 | free_dma | (virt, size) -> int | mmio.zig |
| 1033 | pci_enumerate | (buf, max) -> int | pci_syscall.zig |
| 1034 | pci_config_read | (b,d,f,off) -> val | pci_syscall.zig |
| 1035 | pci_config_write | (b,d,f,off,val) -> int | pci_syscall.zig |
| 1036 | outb | (port, value) -> int | port_io.zig |
| 1037 | inb | (port) -> value | port_io.zig |
| 1026 | register_service | (name, len) -> int | ipc.zig |
| 1027 | lookup_service | (name, len) -> pid | ipc.zig |

### Ring Buffer IPC Syscalls (1040-1049)

| # | Name | Signature | Handler |
|---|------|-----------|---------|
| 1040 | ring_create | (sz, cnt, pid, name, len) -> id | ring.zig |
| 1041 | ring_attach | (id, res_ptr) -> int | ring.zig |
| 1042 | ring_detach | (id) -> int | ring.zig |
| 1043 | ring_wait | (id, min, time) -> cnt | ring.zig |
| 1044 | ring_notify | (id) -> int | ring.zig |
| 1045 | ring_wait_any | (ids, cnt, min, time) -> id | ring.zig |

### IOMMU DMA Syscalls (1046-1047)

| # | Name | Signature | Handler |
|---|------|-----------|---------|
| 1046 | alloc_iommu_dma | (bdf, result, pages) -> int | mmio.zig |
| 1047 | free_iommu_dma | (bdf, virt, pages, dma_addr) -> int | mmio.zig |

### Hypervisor Syscalls (1050-1059)

| # | Name | Signature | Handler |
|---|------|-----------|---------|
| 1050 | vmware_hypercall | (regs_ptr) -> int | hypervisor.zig |
| 1051 | get_hypervisor | () -> type | hypervisor.zig |

**Notes:**
- `vmware_hypercall`: Requires `CAP_HYPERVISOR` capability. Passes register struct to VMware hypercall interface.
- `get_hypervisor`: Returns hypervisor type enum (0=none, 1=vmware, 2=virtualbox, 3=kvm, 4=hyperv, 5=xen, 6=qemu_tcg).

### Implementation Status Legend

- Listed with handler file = Implemented
- `-` in Handler column = Defined in UAPI but returns ENOSYS

## Error Handling Pattern

Handlers use Zig error unions that map to Linux errno:

```zig
const SyscallError = uapi.errno.SyscallError;

pub fn sys_read(fd: usize, buf_ptr: usize, count: usize) SyscallError!usize {
    const fd_table = base.getGlobalFdTable();
    const file = fd_table.get(fd) orelse return error.EBADF;

    if (!user_mem.isValidUserPtr(buf_ptr, count)) {
        return error.EFAULT;
    }

    const bytes_read = try file.read(buf);
    return bytes_read;
}
```

Common errors:
- `error.EBADF` - Bad file descriptor
- `error.EFAULT` - Bad address (invalid user pointer)
- `error.EINVAL` - Invalid argument
- `error.ENOSYS` - Function not implemented
- `error.ENOMEM` - Out of memory
- `error.EAGAIN` - Resource temporarily unavailable

## User Memory Validation

Always validate user pointers before dereferencing:

```zig
const user_mem = @import("user_mem");

// Check if pointer is in valid user address space
if (!user_mem.isValidUserPtr(ptr, size)) {
    return error.EFAULT;
}

// Safe copy from user space
const data = user_mem.copyFromUser(kernel_buf, user_ptr, len) catch return error.EFAULT;

// Safe copy to user space
user_mem.copyToUser(user_ptr, kernel_buf, len) catch return error.EFAULT;
```

## Debugging

Syscalls are logged automatically when `debug_enabled = true`:
```
Syscall: #1 (args: 1 7ffe00001000 d)
```

Enable verbose logging in build:
```bash
zig build -Ddebug=true
```
