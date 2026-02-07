# Syscall Architecture

Quick reference for the ZK syscall subsystem. Covers build system integration, dispatch mechanism, developer guidelines, and supported syscalls.

## Build System Integration

### Module Dependency Graph

```
build.zig
    |
    +-- uapi_module (src/uapi/root.zig)
    |       |-- syscalls/       <- Syscall number definitions
    |       |   |-- root.zig    <- Re-exports all numbers (arch-conditional linux + zk)
    |       |   |-- linux.zig   <- Linux x86_64 syscall numbers
    |       |   |-- linux_aarch64.zig <- Linux aarch64 syscall numbers
    |       |   `-- zk.zig <- Custom ZK extensions (same on all architectures)
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
    |       |-- syscall_virt_pci_module  -> sys/syscall/hw/virt_pci.zig
    |       |-- syscall_fs_handlers_module -> sys/syscall/fs/fs_handlers.zig
    |       |-- syscall_alarm_module       -> sys/syscall/misc/alarm.zig
    |       |-- syscall_sysinfo_module     -> sys/syscall/misc/sysinfo.zig
    |       |-- syscall_times_module       -> sys/syscall/misc/times.zig
    |       |-- syscall_itimer_module      -> sys/syscall/misc/itimer.zig
    |       |-- syscall_display_module     -> sys/syscall/hw/display.zig
    |       |-- syscall_flock_module       -> sys/syscall/fs/flock.zig
    |       `-- syscall_io_uring_module    -> sys/syscall/io_uring/root.zig
    |
    +-- syscall_table_module (src/kernel/sys/syscall/core/table.zig)
            |-- Imports all handler modules
            `-- Comptime dispatch via reflection on uapi.syscalls
```

### How build.zig Wires Syscalls

1. **UAPI Module** - Defines syscall numbers in `src/uapi/syscalls/root.zig`:
   - On x86_64: Re-exports from `linux.zig` + `zk.zig`
   - On aarch64: Re-exports from `linux_aarch64.zig` + `zk.zig`
   - Architecture selection happens at compile time via `builtin.cpu.arch`
2. **Base Module** - Provides shared state accessed by all handlers
3. **Handler Modules** - Each handler file is a separate Zig module with explicit imports
4. **Table Module** - Uses comptime reflection to auto-discover handlers

**Note**: Handler code is architecture-agnostic. The dispatch table matches `SYS_READ` to `sys_read` by name, so changing the numeric value of `SYS_READ` (0 on x86_64, 63 on aarch64) does not require any handler modifications.

**WARNING -- Syscall Number Collisions**: If two `SYS_*` constants in `uapi/syscalls/` resolve to the **same numeric value**, the comptime dispatch table will silently pick whichever handler it finds first in the `inline for` loop. The shadowed handler will never be called. This is especially dangerous on aarch64 where legacy x86_64 syscalls (e.g., `getpgrp`, `open`, `pipe`) do not exist natively and must be given unique compat numbers in the 500+ range. Every `SYS_*` constant **must** have a unique value within its architecture.

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
    - **Linux ABI type sizes matter**: `socklen_t` is `u32` (4 bytes), not `usize`. Reading 8 bytes from a 4-byte user variable via `readValue(usize)` picks up garbage from adjacent stack memory. This may silently work on x86_64 (adjacent bytes often zero) but fail on aarch64. Always match the exact C type size in `readValue`/`writeValue` calls.

5.  **Debugging**:
    - Use `console.debug` sparingly; it can flood the logs.
    - `strace`-like functionality is available via the `debug_enabled` build flag.

## Adding New Syscalls

   // In src/uapi/syscalls/zk.zig (for custom) or linux.zig
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
        flock.zig      - File locking (flock)
        fs_handlers.zig- Filesystem operations (mount, umount, mkdirat, unlinkat)

    memory/         - Memory management
        memory.zig     - Memory ops (mmap, mprotect, munmap, brk)
        mmio.zig       - MMIO mapping for userspace drivers

    net/            - Networking
        net.zig        - Sockets (socket, bind, listen, accept, connect, socketpair, send, recv, poll)
        pci_syscall.zig- PCI configuration and enumeration

    hw/             - Hardware I/O
        display.zig    - Display mode switching (set_display_mode)
        input.zig      - Input devices (mouse, keyboard events)
        interrupt.zig  - Userspace interrupt waiting
        port_io.zig    - Raw port I/O access
        ring.zig       - Ring buffer IPC (create, attach, wait, notify)
        hypervisor.zig - Hypervisor access (VMware hypercall, detection)
        virt_pci.zig   - Virtual PCI device emulation (create, BAR, caps, MMIO)

    io/             - Async I/O
        root.zig       - I/O operations (read, write, writev, stat, fstat, ioctl, fcntl)

    io_uring/       - io_uring subsystem
        root.zig       - io_uring dispatch
        setup.zig      - io_uring_setup
        enter.zig      - io_uring_enter
        register.zig   - io_uring_register

    misc/           - Miscellaneous
        alarm.zig      - Alarm timer (alarm)
        custom.zig     - ZK extensions (debug_log, putchar, getchar, read_scancode)
        ipc.zig        - Inter-process communication
        itimer.zig     - Interval timers (getitimer, setitimer)
        random.zig     - Random numbers (getrandom)
        sysinfo.zig    - System information (sysinfo)
        times.zig      - Process time accounting (times)
```

## Syscall Quick Reference

### Architecture Support

zk uses **standard Linux syscall numbers** for both supported architectures:

| Architecture | Syscall Numbers | ABI Source |
|--------------|-----------------|------------|
| x86_64 | `src/uapi/syscalls/linux.zig` | Linux x86_64 |
| aarch64 | `src/uapi/syscalls/linux_aarch64.zig` | Linux aarch64 |

**Important**: The syscall numbers in the tables below are **x86_64 specific**. aarch64 uses different numbers for the same syscalls. Use `syscall_query.py --arch aarch64 <name>` to look up aarch64 numbers.

Example differences:
- `read`: x86_64=0, aarch64=63
- `write`: x86_64=1, aarch64=64
- `mmap`: x86_64=9, aarch64=222
- `socket`: x86_64=41, aarch64=198

**aarch64 Compat Range (500+)**: Linux aarch64 omits several legacy x86_64 syscalls (`open`, `pipe`, `getpgrp`, `dup2`, etc.). ZK assigns these unique numbers in the 500-599 range in `linux_aarch64.zig` so userspace code can use the same syscall wrappers on both architectures. These numbers must not collide with any native aarch64 syscall number.

### Conventions (x86_64)

- **ABI**: Linux x86_64 syscall convention
- **Entry**: RAX=number, RDI/RSI/RDX/R10/R8/R9=args 1-6
- **Return**: RAX >= 0 success, RAX < 0 is -errno
- **Clobbers**: RCX, R11

### Conventions (aarch64)

- **ABI**: Linux aarch64 syscall convention
- **Entry**: X8=number, X0-X5=args 1-6
- **Return**: X0 >= 0 success, X0 < 0 is -errno
- **Clobbers**: None (caller-saved registers preserved)

### Linux-Compatible Syscalls (x86_64 numbers)

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
| 25 | mremap | (old, old_sz, new_sz, flags) -> addr | memory.zig (-) |
| 26 | msync | (addr, len, flags) -> int | memory.zig (-) |
| 27 | mincore | (addr, len, vec) -> int | memory.zig (-) |
| 28 | madvise | (addr, len, advice) -> int | memory.zig (-) |
| 32 | dup | (oldfd) -> newfd | fd.zig |
| 33 | dup2 | (oldfd, newfd) -> int | fd.zig |
| 34 | pause | () -> int | scheduling.zig |
| 35 | nanosleep | (req, rem) -> int | scheduling.zig |
| 36 | getitimer | (which, value) -> int | itimer.zig |
| 37 | alarm | (seconds) -> int | alarm.zig |
| 38 | setitimer | (which, new, old) -> int | itimer.zig |
| 39 | getpid | () -> pid_t | process.zig |
| 40 | sendfile | (out_fd, in_fd, off, count) -> ssize_t | io.zig (-) |
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
| 53 | socketpair | (domain, type, protocol, sv) -> int | net.zig |
| 54 | setsockopt | (fd, level, name, val, len) -> int | net.zig |
| 55 | getsockopt | (fd, level, name, val, len) -> int | net.zig |
| 56 | clone | (flags, stack, ptid, ctid, tls) -> pid_t | execution.zig |
| 57 | fork | () -> pid_t | execution.zig |
| 58 | vfork | () -> pid_t | execution.zig (-) |
| 59 | execve | (path, argv, envp) -> int | execution.zig |
| 60 | exit | (code) -> noreturn | process.zig |
| 61 | wait4 | (pid, wstatus, options, rusage) -> pid_t | process.zig |
| 62 | kill | (pid, sig) -> int | signals.zig |
| 63 | uname | (name) -> int | process.zig |
| 73 | flock | (fd, operation) -> int | flock.zig |
| 72 | fcntl | (fd, cmd, arg) -> int | io.zig |
| 74 | fsync | (fd) -> int | io.zig |
| 75 | fdatasync | (fd) -> int | io.zig |
| 76 | truncate | (path, length) -> int | io.zig |
| 77 | ftruncate | (fd, length) -> int | io.zig |
| 78 | getdents | (fd, dirp, count) -> int | io.zig (-) |
| 79 | getcwd | (buf, size) -> char* | io.zig |
| 80 | chdir | (path) -> int | io.zig |
| 81 | fchdir | (fd) -> int | io.zig (-) |
| 82 | rename | (old, new) -> int | fs_handlers.zig |
| 83 | mkdir | (path, mode) -> int | fs_handlers.zig |
| 84 | rmdir | (path) -> int | fs_handlers.zig |
| 85 | creat | (path, mode) -> fd | fd.zig |
| 86 | link | (old, new) -> int | io.zig |
| 87 | unlink | (path) -> int | fs_handlers.zig |
| 88 | symlink | (target, link) -> int | io.zig |
| 89 | readlink | (path, buf, size) -> ssize_t | io.zig |
| 90 | chmod | (path, mode) -> int | fs_handlers.zig |
| 91 | fchmod | (fd, mode) -> int | io.zig |
| 92 | chown | (path, uid, gid) -> int | io.zig |
| 93 | fchown | (fd, uid, gid) -> int | io.zig |
| 94 | lchown | (path, uid, gid) -> int | io.zig |
| 95 | umask | (mask) -> mode_t | process.zig |
| 96 | gettimeofday | (tv, tz) -> int | scheduling.zig |
| 97 | getrlimit | (res, rlim) -> int | process.zig |
| 98 | getrusage | (who, usage) -> int | process.zig (-) |
| 99 | sysinfo | (info) -> int | sysinfo.zig |
| 100 | times | (buf) -> clock_t | times.zig |
| 101 | ptrace | (req, pid, addr, data) -> long | - |
| 102 | getuid | () -> uid_t | process.zig |
| 104 | getgid | () -> gid_t | process.zig |
| 105 | setuid | (uid) -> int | process.zig |
| 106 | setgid | (gid) -> int | process.zig |
| 107 | geteuid | () -> uid_t | process.zig |
| 108 | getegid | () -> gid_t | process.zig |
| 109 | setpgid | (pid, pgid) -> int | process.zig |
| 110 | getppid | () -> pid_t | process.zig |
| 111 | getpgrp | () -> pid_t | process.zig |
| 112 | setsid | () -> pid_t | process.zig |
| 117 | setresuid | (ruid, euid, suid) -> int | process.zig |
| 118 | getresuid | (ruid, euid, suid) -> int | process.zig |
| 119 | setresgid | (rgid, egid, sgid) -> int | process.zig |
| 120 | getresgid | (rgid, egid, sgid) -> int | process.zig |
| 121 | getpgid | (pid) -> pid_t | process.zig |
| 124 | getsid | (pid) -> pid_t | process.zig |
| 125 | capget | (hdr, data) -> int | - |
| 126 | capset | (hdr, data) -> int | - |
| 127 | rt_sigpending | (set, size) -> int | signals.zig (-) |
| 128 | rt_sigtimedwait | (set, info, timeout, size) -> int | signals.zig (-) |
| 129 | rt_sigqueueinfo | (pid, sig, info) -> int | signals.zig (-) |
| 130 | rt_sigsuspend | (mask, size) -> int | signals.zig (-) |
| 131 | sigaltstack | (ss, old_ss) -> int | signals.zig (-) |
| 137 | statfs | (path, buf) -> int | io.zig |
| 138 | fstatfs | (fd, buf) -> int | io.zig |
| 149 | mlock | (addr, len) -> int | memory.zig (-) |
| 150 | munlock | (addr, len) -> int | memory.zig (-) |
| 151 | mlockall | (flags) -> int | memory.zig (-) |
| 152 | munlockall | () -> int | memory.zig (-) |
| 157 | prctl | (option, a2, a3, a4, a5) -> int | - |
| 158 | arch_prctl | (code, addr) -> int | execution.zig |
| 160 | setrlimit | (res, rlim) -> int | process.zig |
| 162 | sync | () -> int | io.zig (-) |
| 164 | settimeofday | (tv, tz) -> int | scheduling.zig |
| 165 | mount | (src, tgt, type, flags, data) -> int | fs_handlers.zig |
| 166 | umount2 | (target, flags) -> int | fs_handlers.zig |
| 170 | sethostname | (name, len) -> int | process.zig |
| 171 | setdomainname | (name, len) -> int | process.zig |
| 186 | gettid | () -> pid_t | signals.zig |
| 200 | tkill | (tid, sig) -> int | signals.zig |
| 202 | futex | (uaddr, op, val, timeout, uaddr2, val3) -> int | scheduling.zig |
| 217 | getdents64 | (fd, dirp, count) -> int | io.zig |
| 218 | set_tid_address | (tidptr) -> pid_t | signals.zig |
| 222 | timer_create | (clockid, sevp, timerid) -> int | scheduling.zig (-) |
| 223 | timer_settime | (id, flags, new, old) -> int | scheduling.zig (-) |
| 224 | timer_gettime | (id, curr) -> int | scheduling.zig (-) |
| 225 | timer_getoverrun | (id) -> int | scheduling.zig (-) |
| 226 | timer_delete | (id) -> int | scheduling.zig (-) |
| 228 | clock_gettime | (clk_id, tp) -> int | scheduling.zig |
| 229 | clock_getres | (clk_id, res) -> int | scheduling.zig |
| 230 | clock_nanosleep | (clk, flags, req, rem) -> int | scheduling.zig (-) |
| 231 | exit_group | (code) -> noreturn | process.zig |
| 232 | epoll_wait | (epfd, events, max, timeout) -> int | scheduling.zig |
| 233 | epoll_ctl | (epfd, op, fd, event) -> int | scheduling.zig |
| 234 | tgkill | (tgid, tid, sig) -> int | signals.zig |
| 253 | inotify_init | () -> fd | - |
| 254 | inotify_add_watch | (fd, path, mask) -> wd | - |
| 255 | inotify_rm_watch | (fd, wd) -> int | - |
| 257 | openat | (dfd, filename, flags, mode) -> int | fd.zig |
| 258 | mkdirat | (dfd, path, mode) -> int | fs_handlers.zig |
| 259 | mknodat | (dfd, path, mode, dev) -> int | - |
| 260 | fchownat | (dfd, path, uid, gid, flags) -> int | io.zig |
| 262 | newfstatat | (dfd, path, statbuf, flags) -> int | io.zig |
| 263 | unlinkat | (dfd, path, flags) -> int | fs_handlers.zig |
| 264 | renameat | (olddfd, old, newdfd, new) -> int | fs_handlers.zig |
| 265 | linkat | (olddfd, old, newdfd, new, flags) -> int | io.zig |
| 266 | symlinkat | (target, newdfd, link) -> int | io.zig |
| 267 | readlinkat | (dfd, path, buf, size) -> ssize_t | io.zig |
| 268 | fchmodat | (dfd, path, mode, flags) -> int | fs_handlers.zig |
| 269 | faccessat | (dfd, path, mode, flags) -> int | fd.zig |
| 272 | unshare | (flags) -> int | - |
| 275 | splice | (fd_in, off_in, fd_out, off_out, len, flags) -> ssize_t | - |
| 276 | tee | (fd_in, fd_out, len, flags) -> ssize_t | - |
| 277 | sync_file_range | (fd, off, nbytes, flags) -> int | - |
| 278 | vmsplice | (fd, iov, nr, flags) -> ssize_t | - |
| 281 | epoll_pwait | (epfd, events, max, timeout, sigmask, size) -> int | scheduling.zig (-) |
| 282 | signalfd | (fd, mask, flags) -> fd | - |
| 283 | timerfd_create | (clockid, flags) -> fd | - |
| 284 | eventfd | (initval, flags) -> fd | - |
| 285 | fallocate | (fd, mode, off, len) -> int | - |
| 286 | timerfd_settime | (fd, flags, new, old) -> int | - |
| 287 | timerfd_gettime | (fd, curr) -> int | - |
| 288 | accept4 | (fd, addr, addrlen, flags) -> fd | net.zig |
| 289 | signalfd4 | (fd, mask, sizemask, flags) -> fd | - |
| 290 | eventfd2 | (initval, flags) -> fd | - |
| 291 | epoll_create1 | (flags) -> int | scheduling.zig |
| 292 | dup3 | (old, new, flags) -> int | fd.zig |
| 293 | pipe2 | (pipefd, flags) -> int | fd.zig |
| 294 | inotify_init1 | (flags) -> fd | - |
| 295 | preadv | (fd, iov, iovcnt, off) -> ssize_t | - |
| 296 | pwritev | (fd, iov, iovcnt, off) -> ssize_t | - |
| 302 | prlimit64 | (pid, resource, new, old) -> int | process.zig (-) |
| 306 | syncfs | (fd) -> int | - |
| 308 | setns | (fd, nstype) -> int | - |
| 316 | renameat2 | (olddfd, old, newdfd, new, flags) -> int | - |
| 317 | seccomp | (op, flags, args) -> int | - |
| 318 | getrandom | (buf, count, flags) -> ssize_t | random.zig |
| 319 | memfd_create | (name, flags) -> fd | - |
| 326 | copy_file_range | (fd_in, off_in, fd_out, off_out, len, flags) -> ssize_t | - |
| 425 | io_uring_setup | (entries, params) -> int | - |
| 426 | io_uring_enter | (fd, submit, complete, flags, sig) -> int | - |
| 427 | io_uring_register | (fd, opcode, arg, nr_args) -> int | - |
| 435 | clone3 | (cl_args, size) -> pid_t | - |

### ZK Custom Extensions (1000-1999)

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

### Network Configuration Syscalls (1060-1069)

| # | Name | Signature | Handler |
|---|------|-----------|---------|
| 1060 | netif_config | (iface, cmd, data, len) -> int | net.zig |
| 1061 | arp_probe | (iface, target_ip, timeout) -> int | net.zig |
| 1062 | arp_announce | (iface, ip_addr) -> int | net.zig |

### Display Syscalls (1070)

| # | Name | Signature | Handler |
|---|------|-----------|---------|
| 1070 | set_display_mode | (width, height, flags) -> int | display.zig |

### Virtual PCI Device Emulation Syscalls (1080-1090)

| # | Name | Signature | Handler |
|---|------|-----------|---------|
| 1080 | vpci_create | () -> device_id | virt_pci.zig |
| 1081 | vpci_add_bar | (dev_id, config_ptr) -> int | virt_pci.zig |
| 1082 | vpci_add_cap | (dev_id, cap_ptr) -> offset | virt_pci.zig |
| 1083 | vpci_set_config | (dev_id, header_ptr) -> int | virt_pci.zig |
| 1084 | vpci_register | (dev_id) -> ring_id | virt_pci.zig |
| 1085 | vpci_inject_irq | (dev_id, irq_ptr) -> int | virt_pci.zig |
| 1086 | vpci_dma | (dma_op_ptr) -> bytes | virt_pci.zig |
| 1087 | vpci_get_bar_info | (dev_id, idx, info_ptr) -> int | virt_pci.zig |
| 1088 | vpci_destroy | (dev_id) -> int | virt_pci.zig |
| 1089 | vpci_wait_event | (dev_id, timeout_ms) -> count | virt_pci.zig |
| 1090 | vpci_respond | (dev_id, response_ptr) -> int | virt_pci.zig |

**Notes:**
- Requires `VirtualPciCapability` - controls max_devices, max_bar_size_mb, allowed_class, allow_dma, allow_irq_injection.
- `vpci_create`: Creates a virtual PCI device owned by the calling process. Returns device ID.
- `vpci_add_bar`: Adds a BAR to the device. Config includes bar_index, size, flags (MMIO/IO, 64-bit, prefetchable, intercept).
- `vpci_add_cap`: Adds a PCI capability (MSI, MSI-X, PM). Returns capability offset in config space.
- `vpci_set_config`: Sets the config header (vendor_id, device_id, class_code, etc.).
- `vpci_register`: Makes device visible to PCI subsystem. Creates event ring for MMIO interception if any BARs have intercept enabled. Returns ring_id.
- `vpci_inject_irq`: Injects MSI/MSI-X interrupt. Requires allow_irq_injection capability.
- `vpci_dma`: Performs DMA read/write operation. Requires allow_dma capability.
- `vpci_get_bar_info`: Retrieves BAR physical address and size after registration.
- `vpci_destroy`: Unregisters and destroys the virtual device. Frees all resources.
- `vpci_wait_event`: Waits for MMIO event on device's event ring. Blocks up to timeout_ms.
- `vpci_respond`: Submits response to an MMIO read event.

**UAPI Types** (see `src/uapi/virt_pci/`):
- `VPciConfigHeader` (24 bytes) - PCI config header fields
- `VPciBarConfig` (16 bytes) - BAR configuration
- `VPciCapConfig` (16 bytes) - Capability configuration
- `VPciDmaOp` (40 bytes) - DMA operation descriptor
- `VPciIrqConfig` (8 bytes) - IRQ injection parameters
- `VPciEvent` (48 bytes) - MMIO event from device
- `VPciResponse` (24 bytes) - Response to MMIO read

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
