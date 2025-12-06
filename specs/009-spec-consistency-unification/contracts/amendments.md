# Amendment Contracts: Cross-Specification Consistency Unification

**Feature Branch**: `009-spec-consistency-unification`
**Date**: 2025-12-05

This document defines the exact changes (amendments) to be made to each specification.

---

## Amendment Template Format

Each amendment follows this structure:

```
## Amendment: [SPEC-ID]-[SECTION]

**Target File**: path/to/spec.md
**Section**: Section name
**Change Type**: Add | Replace | Remove

### Before (if Replace/Remove)
[exact text to find]

### After (if Add/Replace)
[exact text to insert]

### Rationale
Why this change is necessary.
```

---

## Amendment: 001-ZIG-VERSION

**Target File**: `specs/001-minimal-kernel/spec.md`
**Section**: Technical Requirements / Language Version
**Change Type**: Replace

### Before
```
Zig 0.13.x/0.14.x
```

### After
```
Zig 0.15.x (or current stable)
```

### Rationale
Zig 0.15.x is the current development target. Build system API changed significantly between 0.14 and 0.15.

---

## Amendment: 003-SYSCALL-NUMBERS

**Target File**: `specs/003-microkernel-userland-networking/spec.md`
**Section**: Syscall Interface
**Change Type**: Replace

### Before
```
SYS_READ = 2
SYS_WRITE = 1
[any custom syscall numbering]
```

### After
```
All syscall numbers follow Linux x86_64 ABI.
See specs/syscall-table.md for authoritative numbers.

Key syscalls:
- sys_read = 0
- sys_write = 1
- sys_open = 2
- sys_close = 3
```

### Rationale
Linux ABI compatibility is required for running standard C programs. Custom numbers would require translation or break compatibility.

---

## Amendment: 003-SPINLOCK-DEFINITION

**Target File**: `specs/003-microkernel-userland-networking/spec.md`
**Section**: Kernel Primitives (new section or existing locking section)
**Change Type**: Add

### After
```markdown
### Spinlock Primitive

The kernel uses an IRQ-safe Spinlock for mutual exclusion:

```zig
pub const Spinlock = struct {
    locked: std.atomic.Value(u32) = .{ .raw = 0 },

    pub const Held = struct {
        lock: *Spinlock,
        irq_state: bool,

        pub fn release(self: Held) void;
    };

    pub fn acquire(self: *Spinlock) Held;
};
```

**Requirements**:
1. `acquire()` disables interrupts before spinning
2. `release()` restores interrupt state after unlocking
3. All critical sections use explicit lock operations
4. MVP uses a single Big Kernel Lock (BKL)

**Usage Pattern**:
```zig
const held = lock.acquire();
defer held.release();
// Critical section
```
```

### Rationale
Explicit locking prepares for transition from BKL to fine-grained locking in spec 004. Prevents implicit reliance on interrupt state.

---

## Amendment: 003-ENDIANNESS

**Target File**: `specs/003-microkernel-userland-networking/spec.md`
**Section**: Networking / Byte Order (new subsection)
**Change Type**: Add

### After
```markdown
### Byte Order Requirements

ZigK runs on x86_64 (Little Endian). Network protocols use Big Endian.

| Domain | Byte Order | Conversion |
|--------|-----------|------------|
| IP/UDP/TCP headers | Big Endian | `std.mem.nativeToBig` |
| E1000 registers | Little Endian | None |
| E1000 descriptors | Little Endian | None |

**Implementation Rules**:
1. Protocol struct fields that cross the wire MUST be stored in network byte order
2. Protocol structs MUST provide accessor methods that handle conversion
3. Hardware register writes MUST NOT byte-swap
4. Hardware descriptor fields MUST NOT byte-swap

**Example**:
```zig
const UdpHeader = extern struct {
    src_port: u16,  // Network byte order in memory
    dst_port: u16,

    pub fn getSrcPort(self: *const UdpHeader) u16 {
        return std.mem.bigToNative(u16, self.src_port);
    }
};
```
```

### Rationale
E1000 uses host byte order for registers and descriptors. Confusing this with protocol byte order causes silent packet corruption.

---

## Amendment: 006-CRT0

**Target File**: `specs/006-sysv-abi-init/spec.md`
**Section**: Userland Entry Point (new section or extend existing)
**Change Type**: Add

### After
```markdown
### CRT0 Implementation

A crt0 (C runtime zero) implementation MUST be provided for userland programs.

**Stack Layout at _start**:
```
RSP+0:    argc (8 bytes)
RSP+8:    argv[0] pointer
...
RSP+8*(argc+1): NULL (argv terminator)
RSP+8*(argc+2): envp[0] pointer
...
          NULL (envp terminator)
```

**CRT0 Responsibilities**:
1. Clear frame pointer (RBP = 0) per ABI
2. Extract argc from RSP
3. Calculate argv = RSP + 8
4. Calculate envp = argv + (argc + 1) * 8
5. Align stack to 16 bytes
6. Call main(argc, argv, envp)
7. Call sys_exit(main_return_value)

**Reference Implementation**:
```zig
export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\  xor %%rbp, %%rbp
        \\  mov (%%rsp), %%rdi
        \\  lea 8(%%rsp), %%rsi
        \\  lea 8(%%rsi,%%rdi,8), %%rdx
        \\  and $-16, %%rsp
        \\  call main
        \\  mov %%eax, %%edi
        \\  mov $60, %%eax
        \\  syscall
        \\  ud2
    );
}
```

**Linking Requirement**:
All userland programs MUST link with crt0. Failure to include crt0 results in crash at entry.
```

### Rationale
Without crt0, programs receive garbage arguments. The stack layout is defined by spec 006, but the code to parse it was not specified.

---

## Amendment: 007-VFS-SHIM

**Target File**: `specs/007-linux-compat-layer/spec.md`
**Section**: File Descriptor Handling (extend existing)
**Change Type**: Add

### After
```markdown
### VFS Device Shim

The kernel provides a minimal VFS shim for virtual device paths.

**Supported Paths**:
| Path | Behavior |
|------|----------|
| /dev/null | Discards writes, returns EOF on read |
| /dev/zero | Returns zero bytes on read |
| /dev/console | Maps to console output |
| /dev/stdin | Maps to FD 0 behavior |
| /dev/stdout | Maps to FD 1 behavior |
| /dev/stderr | Maps to FD 2 behavior |
| /dev/urandom | Returns PRNG bytes |
| /dev/random | Same as /dev/urandom (MVP) |

**sys_open Behavior**:
1. If path starts with "/dev/", check VFS shim first
2. If VFS shim has mapping, allocate FD with device kind
3. If no mapping, return -ENOENT (not fall through)
4. Non-/dev/ paths use InitRD lookup

**Implementation Note**:
This is a kernel lookup table, not a filesystem. No inodes, no directory operations, no mount points.
```

### Rationale
Linux programs expect /dev/ paths to work. Without the shim, fopen("/dev/null") fails even though null device behavior is simple.

---

## Amendment: CLAUDE-MD-ZIG

**Target File**: `CLAUDE.md`
**Section**: Active Technologies / Commands
**Change Type**: Replace/Add

### Before
```
Zig (latest stable, 0.13.x/0.14.x) - freestanding target
```

### After
```
Zig 0.15.x - freestanding x86_64 target

## Build Patterns (Zig 0.15.x)

```zig
// Module creation
const kernel = b.addExecutable(.{
    .name = "kernel.elf",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
        }),
        .optimize = optimize,
        .code_model = .kernel,  // Disables Red Zone
    }),
});

// Disable SIMD
kernel.root_module.cpu_features_sub.add(.sse);
kernel.root_module.cpu_features_sub.add(.sse2);
kernel.root_module.cpu_features_sub.add(.mmx);
```
```

### Rationale
CLAUDE.md guides AI code generation. Outdated patterns cause build failures.

---

## New Document: syscall-table.md

**Target File**: `specs/syscall-table.md` (NEW FILE)
**Change Type**: Create

### Content
```markdown
# ZigK Authoritative Syscall Table

This is the single source of truth for all syscall numbers in ZigK.
All specifications MUST reference this table.

## Linux x86_64 ABI Syscalls

| Number | Name | Signature | Implementing Spec |
|--------|------|-----------|-------------------|
| 0 | sys_read | (fd, buf, count) -> ssize_t | 005 |
| 1 | sys_write | (fd, buf, count) -> ssize_t | 005 |
| 2 | sys_open | (path, flags, mode) -> fd | 007 |
| 3 | sys_close | (fd) -> int | 005 |
| 9 | sys_mmap | (addr, len, prot, flags, fd, off) -> addr | 005 |
| 11 | sys_munmap | (addr, len) -> int | 005 |
| 12 | sys_brk | (brk) -> addr | 005 |
| 39 | sys_getpid | () -> pid_t | 005 |
| 57 | sys_fork | () -> pid_t | Future |
| 59 | sys_execve | (path, argv, envp) -> int | 006 |
| 60 | sys_exit | (code) -> noreturn | 005 |
| 61 | sys_wait4 | (pid, wstatus, options, rusage) -> pid_t | 007 |
| 102 | sys_getuid | () -> uid_t | 005 |
| 104 | sys_getgid | () -> gid_t | 005 |
| 110 | sys_getppid | () -> pid_t | 005 |
| 228 | sys_clock_gettime | (clk_id, tp) -> int | 007 |
| 231 | sys_exit_group | (code) -> noreturn | 005 |
| 318 | sys_getrandom | (buf, count, flags) -> ssize_t | 007 |

## ZigK Custom Extensions

Reserved range: 1000-1999

| Number | Name | Signature | Implementing Spec |
|--------|------|-----------|-------------------|
| (none yet) | | | |

## Register Convention

```
Entry:
  RAX = syscall number
  RDI = arg1, RSI = arg2, RDX = arg3
  R10 = arg4, R8 = arg5, R9 = arg6

Return:
  RAX = result or -errno
  RCX, R11 = destroyed
```

## Error Codes

| Errno | Value | Description |
|-------|-------|-------------|
| EPERM | 1 | Operation not permitted |
| ENOENT | 2 | No such file or directory |
| ESRCH | 3 | No such process |
| EINTR | 4 | Interrupted system call |
| EIO | 5 | I/O error |
| EBADF | 9 | Bad file descriptor |
| ECHILD | 10 | No child processes |
| EAGAIN | 11 | Resource temporarily unavailable |
| ENOMEM | 12 | Out of memory |
| EACCES | 13 | Permission denied |
| EFAULT | 14 | Bad address |
| EINVAL | 22 | Invalid argument |
| EMFILE | 24 | Too many open files |
| ENOSYS | 38 | Function not implemented |
```

### Rationale
Centralizes syscall definitions. Prevents specs from defining conflicting numbers. Provides single reference point.

---

## Verification Checklist

After applying all amendments:

- [ ] `grep -r "SYS_READ.*=.*2" specs/` returns no matches
- [ ] `grep -r "0\.13" specs/` returns no matches (Zig version)
- [ ] `grep -r "0\.14" specs/` returns no matches (Zig version)
- [ ] All specs contain reference to `specs/syscall-table.md`
- [ ] Spec 003 contains Spinlock definition
- [ ] Spec 003 contains Endianness section
- [ ] Spec 006 contains crt0 section
- [ ] Spec 007 contains VFS shim section
- [ ] `specs/syscall-table.md` exists
- [ ] CLAUDE.md contains Zig 0.15.x build patterns
