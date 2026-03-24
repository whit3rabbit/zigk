# Missing Linux Syscalls

This document lists Linux x86_64 syscalls not yet implemented in zk.

## Summary

| Metric | Count |
|--------|-------|
| Linux x86_64 syscalls | 420 |
| Implemented in zk | 224 (53%) |
| Missing | 196 |

All implemented syscalls use **correct Linux x86_64 numbers**. ZK extensions (1000+) do not conflict with Linux.

## Architecture Compatibility

### x86_64

Fully compatible with Linux x86_64 syscall ABI. Binaries compiled for Linux x86_64 will work (for implemented syscalls).

### aarch64 (ARM64)

**Fully compatible with Linux aarch64 syscall ABI.** Binaries compiled for Linux aarch64 will work (for implemented syscalls).

zk uses the correct Linux aarch64 syscall numbers on aarch64, matching the official Linux kernel ABI. The syscall number definitions are selected at compile time based on the target architecture:

| Syscall | x86_64 | aarch64 | Notes |
|---------|--------|---------|-------|
| `read` | 0 | 63 | Both work |
| `write` | 1 | 64 | Both work |
| `openat` | 257 | 56 | Both work |
| `close` | 3 | 57 | Both work |
| `mmap` | 9 | 222 | Both work |
| `socket` | 41 | 198 | Both work |
| `clone` | 220 | 220 | Same on aarch64 |

**Implementation Details:**

- `src/uapi/syscalls/linux.zig` - x86_64 syscall numbers
- `src/uapi/syscalls/linux_aarch64.zig` - aarch64 syscall numbers
- `src/uapi/syscalls/root.zig` - Conditional import based on target arch

**Legacy Syscall Compatibility (aarch64 only):**

Linux aarch64 does not have certain legacy syscalls (e.g., `open`, `pipe`, `stat`, `fork`). On zk/aarch64, these are available at reserved numbers (500-599) and internally redirect to modern variants:

| Legacy Syscall | zk/aarch64 Number | Redirects To |
|----------------|---------------------|--------------|
| `open` | 500 | `openat(AT_FDCWD, ...)` |
| `stat` | 503 | `newfstatat(AT_FDCWD, ...)` |
| `lstat` | 504 | `newfstatat(AT_FDCWD, ..., AT_SYMLINK_NOFOLLOW)` |
| `access` | 505 | `faccessat(AT_FDCWD, ...)` |
| `pipe` | 502 | `pipe2(..., 0)` |
| `fork` | 506 | `clone(...)` |

These 500+ numbers are zk-specific compatibility extensions, NOT part of the Linux aarch64 ABI. Standard Linux aarch64 binaries do not use them.

## Priority Guide

- **High**: Required for common POSIX programs
- **Medium**: Needed for specific use cases
- **Low**: Legacy, deprecated, or rarely used

## Recently Implemented

### 2026-02-22: SysV IPC, Scheduler, User/Group IDs, and More

34 new syscalls implemented across multiple subsystems.

**SysV IPC** (11 syscalls in `src/kernel/sys/syscall/ipc/`):
- Shared Memory: `shmget` (29), `shmat` (30), `shmctl` (31), `shmdt` (67)
- Semaphores: `semget` (64), `semop` (65), `semctl` (66)
- Message Queues: `msgget` (68), `msgsnd` (69), `msgrcv` (70), `msgctl` (71)

**User/Group ID Management** (6 syscalls in `process/process.zig`):
- `setreuid` (113), `setregid` (114), `getgroups` (115), `setgroups` (116), `setfsuid` (122), `setfsgid` (123)

**Scheduler** (9 syscalls in `scheduling.zig` and `control.zig`):
- `sched_setparam` (142), `sched_getparam` (143), `sched_setscheduler` (144), `sched_getscheduler` (145)
- `sched_get_priority_max` (146), `sched_get_priority_min` (147), `sched_rr_get_interval` (148)
- `sched_setaffinity` (203), `sched_getaffinity` (204)

**Additional** (8 syscalls):
- `waitid` (247), `pselect6` (270), `ppoll` (271), `futimesat` (261)
- `utimensat` (280), `rt_tgsigqueueinfo` (297), `preadv2` (327), `pwritev2` (328)

### 2026-02-05: Expanded Test Coverage & Kernel Bug Fixes

Added 95 new integration tests (186 total, up from 91) with 20 new userspace syscall wrappers. Fixed several kernel bugs discovered during testing.

**New Userspace Wrappers** (added to `src/user/lib/syscall/`):
- FD ops: `dup`, `dup2`, `pipe`, `pipe2`, `fcntl`, `pread64`
- File info: `stat`, `fstat`, `lstat`, `truncate`, `ftruncate`, `rename`, `chmod`, `link`, `symlink`, `readlink`
- Process: `umask`, `uname`
- Time: `clock_getres`, `gettimeofday`

**Kernel Bugs Fixed**:
- **`*at` syscall kernel pointer delegation**: All `*at` syscalls (fstatat, mkdirat, unlinkat, renameat, fchmodat) copied paths from userspace to kernel buffers, then passed kernel pointers to base syscalls which called `copyStringFromUser` again -- causing EFAULT. Fixed by extracting internal helpers (`statPathKernel`, `mkdirKernel`, `unlinkKernel`, `rmdirKernel`, `chmodKernel`, `renameKernel`).
- **`sys_newfstatat` not registered**: Dispatch table converts `SYS_NEWFSTATAT` to `sys_newfstatat` but function was named `sys_fstatat`. Fixed with alias in `io/root.zig`.
- **`sys_uname` machine field**: Was hardcoded to "x86_64" regardless of architecture. Fixed to use `@import("builtin").cpu.arch`.

**Test Coverage**: 166 pass, 0 fail, 20 skip on both x86_64 and aarch64.

### 2026-02-03: System Information and Timers

Phase 2 system compatibility syscalls:

| # | Name | Handler | Status |
|---|------|---------|--------|
| 99 | `sysinfo` | `misc/sysinfo.zig` | ✅ Implemented, tested (x86_64, aarch64) |
| 100 | `times` | `misc/times.zig` | ✅ Implemented, tested (x86_64, aarch64) |
| 36 | `getitimer` | `misc/itimer.zig` | ✅ Implemented, tested (x86_64, aarch64) |
| 38 | `setitimer` | `misc/itimer.zig` | ✅ Implemented, tested (x86_64, aarch64) |

**Features**:
- System statistics (uptime, memory, load averages, process count)
- Process CPU time tracking (user/system, self/children)
- Interval timers (ITIMER_REAL, ITIMER_VIRTUAL, ITIMER_PROF)

**Test Coverage**: 9 new tests covering basic operations, periodic timers, and timer independence. All tests passing on x86_64.

**Note**: Timer countdown/signal delivery not yet implemented (timers can be set/retrieved but do not expire).

### 2026-01-31: Process Management

Multi-process support syscalls:

| # | Name | Handler | Status |
|---|------|---------|--------|
| 57 | `fork` | `core/execution.zig:54` | ✅ Implemented, tested |
| 59 | `execve` | `core/execution.zig:207` | ✅ Implemented, userspace wrapper added |
| 56 | `clone` | `core/execution.zig:789` | ✅ Implemented |
| 61 | `wait4` | `process/process.zig:48` | ✅ Implemented, tested |
| 110 | `getppid` | `process/process.zig:174` | ✅ Implemented, tested |

**Kernel Bugs Fixed**:
- Fork CS/SS segment register swap (caused GPF on child return to userspace)
- Process refcount double-unref during zombie reaping (caused panic in wait4)

**Test Coverage**: 66/70 kernel tests passing (94%). Multi-process test infrastructure added.

## Missing by Category

### ~~SysV IPC - Shared Memory~~ (DONE)

All implemented in `src/kernel/sys/syscall/ipc/`: shmget, shmat, shmctl, shmdt.

### ~~SysV IPC - Semaphores~~ (DONE)

All implemented in `src/kernel/sys/syscall/ipc/`: semget, semop, semctl.

### ~~SysV IPC - Message Queues~~ (DONE)

All implemented in `src/kernel/sys/syscall/ipc/`: msgget, msgsnd, msgrcv, msgctl.

### ~~Timers & Alarms~~ (DONE)

All implemented: `pause` (scheduling.zig), `alarm` (alarm.zig), `getitimer`/`setitimer` (itimer.zig).

### ~~Process Groups & Sessions~~ (DONE)

All implemented: `setpgid`, `getpgrp`, `setsid`, `getpgid`, `getsid` (process.zig).

### ~~User/Group IDs~~ (DONE)

All implemented in `process/process.zig`: setreuid, setregid, getgroups, setgroups, setfsuid, setfsgid.

### ~~Scheduler~~ (DONE)

All implemented in `scheduling.zig` and `control.zig`: sched_setparam, sched_getparam, sched_setscheduler, sched_getscheduler, sched_get_priority_max, sched_get_priority_min, sched_rr_get_interval, sched_setaffinity, sched_getaffinity.

### Extended Attributes (Low Priority)

Used for SELinux, ACLs, capabilities on files.

| # | Name | Description |
|---|------|-------------|
| 188 | `setxattr` | Set extended attribute |
| 189 | `lsetxattr` | Set xattr (no follow) |
| 190 | `fsetxattr` | Set xattr by fd |
| 191 | `getxattr` | Get extended attribute |
| 192 | `lgetxattr` | Get xattr (no follow) |
| 193 | `fgetxattr` | Get xattr by fd |
| 194 | `listxattr` | List extended attributes |
| 195 | `llistxattr` | List xattr (no follow) |
| 196 | `flistxattr` | List xattr by fd |
| 197 | `removexattr` | Remove extended attribute |
| 198 | `lremovexattr` | Remove xattr (no follow) |
| 199 | `fremovexattr` | Remove xattr by fd |

### ~~File Locking~~ (DONE)

Implemented: `flock` (flock.zig).

### System Info (Medium Priority)

| # | Name | Description |
|---|------|-------------|
| 103 | `syslog` | Read/control kernel log |

`sysinfo` (99) and `times` (100) are now implemented (sysinfo.zig, times.zig).

### Filesystem (Low Priority)

| # | Name | Description |
|---|------|-------------|
| 132 | `utime` | Change file timestamps (legacy) |
| 133 | `mknod` | Create special file |
| 136 | `ustat` | Get filesystem stats (deprecated) |
| 139 | `sysfs` | Get filesystem type info |
| 153 | `vhangup` | Virtually hangup terminal |
| 155 | `pivot_root` | Change root filesystem |
| 161 | `chroot` | Change root directory |
| 163 | `acct` | Process accounting |

### Memory & Swap (Low Priority)

| # | Name | Description |
|---|------|-------------|
| 167 | `swapon` | Enable swap area |
| 168 | `swapoff` | Disable swap area |

### Privileged/Root Operations (Low Priority)

| # | Name | Description |
|---|------|-------------|
| 169 | `reboot` | Reboot system |
| 172 | `iopl` | Change I/O privilege level |
| 173 | `ioperm` | Set port I/O permissions |
| 179 | `quotactl` | Filesystem quota control |

### Module Loading (Low Priority)

Not needed for monolithic kernel design.

| # | Name | Description |
|---|------|-------------|
| 175 | `init_module` | Load kernel module |
| 176 | `delete_module` | Unload kernel module |

### Legacy/Deprecated (Do Not Implement)

These syscalls are deprecated or obsolete in modern Linux.

| # | Name | Status |
|---|------|--------|
| 134 | `uselib` | Deprecated |
| 135 | `personality` | Rarely used |
| 154 | `modify_ldt` | x86 specific, security risk |
| 156 | `_sysctl` | Deprecated, use /proc |
| 159 | `adjtimex` | NTP time adjustment |
| 174 | `create_module` | Removed in Linux 2.6 |
| 177 | `get_kernel_syms` | Removed in Linux 2.6 |
| 178 | `query_module` | Removed in Linux 2.6 |
| 180 | `nfsservctl` | Removed in Linux 3.1 |
| 181-185 | Various | Unimplemented stubs |

## Implementation Recommendations

### ~~Phase 1: Essential POSIX~~ (COMPLETE)

All implemented: flock, pause, alarm, setpgid/getpgid, setsid/getsid.

### ~~Phase 2: System Compatibility~~ (COMPLETE)

All implemented: sysinfo, times, getitimer/setitimer, setreuid/setregid, getgroups/setgroups, setfsuid/setfsgid.

### ~~Phase 3: Advanced Features~~ (COMPLETE)

All implemented: SysV shared memory (29-31, 67), SysV semaphores (64-66), SysV message queues (68-71), scheduler syscalls (142-148, 203-204).

### Not Recommended

- Extended attributes (complex, security model dependent)
- Module loading (monolithic kernel)
- Legacy syscalls (deprecated upstream)

## Checking Implementation Status

```bash
# Query missing syscalls
python3 .claude/skills/zk-kernel/scripts/syscall_query.py 73
# Returns: No syscall with number 73 (if not implemented)

# List all implemented
python3 .claude/skills/zk-kernel/scripts/syscall_query.py --all
```

## Adding New Syscalls

1. Add constant to `src/uapi/syscalls/linux.zig`
2. Implement handler in `src/kernel/sys/syscall/<category>/`
3. Register in `src/kernel/sys/syscall/core/table.zig`
4. Update `syscall_query.py` hardcoded data
5. Add tests

See `docs/SYSCALL.md` for implementation details.
