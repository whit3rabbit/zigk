# Research: Cross-Specification Consistency Unification

**Feature Branch**: `009-spec-consistency-unification`
**Date**: 2025-12-05

This document consolidates research findings for harmonizing Zscapek specifications.

---

## 1. Linux x86_64 Syscall Number Table

### Authoritative Syscall Numbers

The Linux x86_64 syscall numbers are defined in the kernel source at `arch/x86/entry/syscalls/syscall_64.tbl`. Key syscalls for Zscapek compatibility:

| Syscall | Number | Arguments |
|---------|--------|-----------|
| sys_read | 0 | fd, buf, count |
| sys_write | 1 | fd, buf, count |
| sys_open | 2 | filename, flags, mode |
| sys_close | 3 | fd |
| sys_stat | 4 | filename, statbuf |
| sys_fstat | 5 | fd, statbuf |
| sys_mmap | 9 | addr, len, prot, flags, fd, off |
| sys_mprotect | 10 | start, len, prot |
| sys_munmap | 11 | addr, len |
| sys_brk | 12 | brk |
| sys_ioctl | 16 | fd, cmd, arg |
| sys_pipe | 22 | fildes |
| sys_dup | 32 | fildes |
| sys_dup2 | 33 | oldfd, newfd |
| sys_nanosleep | 35 | rqtp, rmtp |
| sys_getpid | 39 | - |
| sys_fork | 57 | - |
| sys_execve | 59 | filename, argv, envp |
| sys_exit | 60 | error_code |
| sys_wait4 | 61 | pid, stat_addr, options, rusage |
| sys_kill | 62 | pid, sig |
| sys_uname | 63 | buf |
| sys_getppid | 110 | - |
| sys_getuid | 102 | - |
| sys_getgid | 104 | - |
| sys_geteuid | 107 | - |
| sys_getegid | 108 | - |
| sys_clock_gettime | 228 | clk_id, tp |
| sys_exit_group | 231 | error_code |
| sys_getrandom | 318 | buf, count, flags |

### Register Convention

```
syscall entry:
  RAX = syscall number
  RDI = arg1
  RSI = arg2
  RDX = arg3
  R10 = arg4 (note: NOT RCX, which is clobbered by syscall)
  R8  = arg5
  R9  = arg6

syscall return:
  RAX = return value (or -errno on error)
  RCX = destroyed (contains RIP for sysret)
  R11 = destroyed (contains RFLAGS for sysret)
```

### Custom Zscapek Extensions

To avoid conflicts with current and future Linux syscalls, Zscapek-specific syscalls should use numbers 548+. The Linux kernel reserves numbers up to ~547 as of kernel 6.x.

Recommended Zscapek custom syscall range:
- 1000-1999: Zscapek kernel extensions (conservative)
- 548-999: Alternative if smaller numbers preferred

### Conflict Resolution

**Spec 003 Issue**: Defines SYS_READ=2, SYS_WRITE=1 (custom)
**Resolution**: Update to Linux ABI: SYS_READ=0, SYS_WRITE=1

---

## 2. Zig 0.15.x Build System Patterns

### Breaking Changes from 0.13.x/0.14.x

Zig 0.15.x introduces significant build system API changes:

#### Module System (New in 0.15.x)

```zig
// OLD (0.13.x/0.14.x):
const exe = b.addExecutable(.{
    .name = "kernel",
    .root_source_file = .{ .path = "src/kernel/main.zig" },
    .target = target,
    .optimize = optimize,
});

// NEW (0.15.x):
const exe = b.addExecutable(.{
    .name = "kernel",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

#### Path Handling

```zig
// OLD:
.root_source_file = .{ .path = "src/main.zig" }

// NEW:
.root_source_file = b.path("src/main.zig")
```

#### Feature Flags for Freestanding x86_64

```zig
const kernel_module = b.createModule(.{
    .root_source_file = b.path("src/kernel/main.zig"),
    .target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    }),
    .optimize = .ReleaseSafe,
    .code_model = .kernel,  // Disables Red Zone automatically
});

// Disable SIMD for simpler context switching
kernel_module.cpu_features_sub.add(.sse);
kernel_module.cpu_features_sub.add(.sse2);
kernel_module.cpu_features_sub.add(.avx);
kernel_module.cpu_features_sub.add(.avx2);
kernel_module.cpu_features_sub.add(.mmx);
```

#### Red Zone Handling

The `.code_model = .kernel` setting automatically disables the Red Zone. For explicit control:

```zig
// Explicit Red Zone disable (alternative to code_model)
kernel_module.cpu_features_sub.add(.red_zone);
```

### Verified build.zig Template for Zscapek

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/main.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .kernel,
            .pic = false,
        }),
    });

    // Disable SIMD features
    kernel.root_module.cpu_features_sub.add(.sse);
    kernel.root_module.cpu_features_sub.add(.sse2);
    kernel.root_module.cpu_features_sub.add(.mmx);

    // Linker settings for kernel
    kernel.setLinkerScript(b.path("linker.ld"));

    b.installArtifact(kernel);
}
```

---

## 3. x86_64 Spinlock Implementation

### IRQ-Safe Spinlock Design

A spinlock for kernel use must be IRQ-safe to prevent deadlock when an interrupt handler tries to acquire a lock held by interrupted code.

```zig
pub const Spinlock = struct {
    locked: std.atomic.Value(u32) = .{ .raw = 0 },

    pub const Held = struct {
        lock: *Spinlock,
        irq_state: bool,

        pub fn release(self: Held) void {
            // Release lock before restoring interrupts
            self.lock.locked.store(0, .release);
            // Restore interrupt state
            if (self.irq_state) {
                asm volatile ("sti");
            }
        }
    };

    pub fn acquire(self: *Spinlock) Held {
        // Save and disable interrupts
        const irq_state = getInterruptFlag();
        asm volatile ("cli");

        // Spin until we acquire the lock
        while (self.locked.swap(1, .acquire) != 0) {
            // Pause instruction reduces power and improves spin-wait performance
            asm volatile ("pause");
        }

        return .{ .lock = self, .irq_state = irq_state };
    }

    fn getInterruptFlag() bool {
        var flags: u64 = undefined;
        asm volatile ("pushfq; pop %[flags]" : [flags] "=r" (flags));
        return (flags & 0x200) != 0; // IF flag is bit 9
    }
};
```

### Usage Pattern

```zig
var my_lock: Spinlock = .{};

fn criticalSection() void {
    const held = my_lock.acquire();
    defer held.release();

    // Critical section code here
    // Interrupts are disabled, lock is held
}
```

### Big Kernel Lock (BKL) for MVP

For the MVP, a single global lock simplifies development:

```zig
// src/kernel/lock.zig
pub var bkl: Spinlock = .{};

// Usage in syscall handler:
pub fn syscallHandler(...) isize {
    const held = bkl.acquire();
    defer held.release();

    // Handle syscall with BKL held
    return doSyscall(...);
}
```

### Future Refactoring Path

1. Start with BKL (single Spinlock)
2. Profile lock contention
3. Split into domain-specific locks: scheduler_lock, fd_table_lock, zombie_lock
4. Use reader-writer locks where appropriate

---

## 4. crt0 Entry Point Implementation

### SysV ABI Stack Layout at _start

When the kernel transfers control to userland, the stack contains:

```
RSP+0:    argc (8 bytes)
RSP+8:    argv[0] pointer
RSP+16:   argv[1] pointer
...
RSP+8*(argc+1): NULL (argv terminator)
RSP+8*(argc+2): envp[0] pointer
...
          NULL (envp terminator)
          auxv entries (ELF auxiliary vector)
```

### Minimal crt0 Implementation (Zig)

```zig
// src/userland/crt0.zig

const std = @import("std");

export fn _start() callconv(.Naked) noreturn {
    // Stack pointer points to argc
    // We need to call main(argc, argv, envp)
    asm volatile (
        \\  xor %%rbp, %%rbp          // Clear frame pointer (ABI requirement)
        \\  mov (%%rsp), %%rdi        // argc -> RDI (first argument)
        \\  lea 8(%%rsp), %%rsi       // argv -> RSI (second argument)
        \\  // Calculate envp = argv + argc + 1
        \\  lea 8(%%rsi,%%rdi,8), %%rdx  // envp -> RDX (third argument)
        \\  and $-16, %%rsp           // Align stack to 16 bytes
        \\  call main
        \\  mov %%eax, %%edi          // Return value -> exit code
        \\  mov $60, %%eax            // sys_exit
        \\  syscall
        \\  ud2                       // Unreachable
    );
    unreachable;
}

// Main function signature expected
extern fn main(argc: c_int, argv: [*]const [*:0]const u8, envp: [*]const [*:0]const u8) c_int;
```

### Minimal crt0 Implementation (C/Assembly)

```asm
# src/userland/crt0.S

.global _start
.type _start, @function

_start:
    xor %rbp, %rbp          # Clear frame pointer

    mov (%rsp), %rdi        # argc
    lea 8(%rsp), %rsi       # argv
    lea 8(%rsi,%rdi,8), %rdx  # envp = argv + (argc+1)*8

    and $-16, %rsp          # 16-byte align stack
    call main

    mov %eax, %edi          # exit(main_return_value)
    mov $60, %eax
    syscall

    ud2                     # Should never reach here
```

### Linking with crt0

For C programs:
```bash
x86_64-elf-gcc -nostdlib -nostartfiles -static \
    crt0.o program.c -o program
```

For Zig programs:
```zig
// In build.zig, link crt0 object
exe.addObjectFile(b.path("src/userland/crt0.o"));
```

---

## 5. Endianness Documentation

### Protocol vs Hardware Byte Order

| Domain | Byte Order | Zig Conversion |
|--------|-----------|----------------|
| IP/UDP/TCP headers | Big Endian (Network) | `std.mem.nativeToBig` |
| E1000 registers | Little Endian (Host) | None needed |
| E1000 descriptors | Little Endian (Host) | None needed |
| Limine protocol | Little Endian | None needed |

### Code Patterns

```zig
// Protocol headers - MUST swap
const IpHeader = extern struct {
    // ... other fields ...
    src_addr: u32,  // Network byte order in memory
    dst_addr: u32,

    pub fn getSrcAddr(self: *const IpHeader) u32 {
        return std.mem.bigToNative(u32, self.src_addr);
    }

    pub fn setSrcAddr(self: *IpHeader, addr: u32) void {
        self.src_addr = std.mem.nativeToBig(u32, addr);
    }
};

// E1000 registers - NO swap (x86_64 is little endian)
fn e1000WriteReg(base: [*]volatile u32, reg: u32, val: u32) void {
    base[reg / 4] = val;  // Direct write, no byte swap
}
```

---

## 6. VFS Device Shim

### Device Path Mapping

The VFS shim is a simple kernel-space lookup table, not a full filesystem:

```zig
const DeviceMapping = struct {
    path: []const u8,
    kind: FileDescriptorKind,
    flags: u32,
};

const device_mappings = [_]DeviceMapping{
    .{ .path = "/dev/null", .kind = .DevNull, .flags = O_RDWR },
    .{ .path = "/dev/zero", .kind = .DevZero, .flags = O_RDONLY },
    .{ .path = "/dev/console", .kind = .Console, .flags = O_WRONLY },
    .{ .path = "/dev/stdin", .kind = .Keyboard, .flags = O_RDONLY },
    .{ .path = "/dev/stdout", .kind = .Console, .flags = O_WRONLY },
    .{ .path = "/dev/stderr", .kind = .Console, .flags = O_WRONLY },
    .{ .path = "/dev/urandom", .kind = .DevUrandom, .flags = O_RDONLY },
    .{ .path = "/dev/random", .kind = .DevUrandom, .flags = O_RDONLY },
};

pub fn lookupDevicePath(path: []const u8) ?DeviceMapping {
    if (!std.mem.startsWith(u8, path, "/dev/")) return null;

    for (device_mappings) |mapping| {
        if (std.mem.eql(u8, path, mapping.path)) {
            return mapping;
        }
    }
    return null;  // Unknown /dev/ path -> ENOENT
}
```

### sys_open Integration

```zig
pub fn sys_open(pathname: [*:0]const u8, flags: i32, mode: u32) isize {
    const path = std.mem.sliceTo(pathname, 0);

    // Check /dev/ paths first
    if (lookupDevicePath(path)) |device| {
        return allocateFD(device.kind);
    }

    // Fall through to InitRD lookup
    return initrd_open(path, flags, mode);
}
```

---

## 7. Spec Amendment Summary

### Spec 001 (Minimal Kernel)

- **Change**: Zig version from "0.13.x/0.14.x" to "0.15.x"
- **Impact**: Build system patterns need updating

### Spec 003 (Microkernel Userland Networking)

- **Change 1**: Syscall numbers from custom to Linux ABI
- **Change 2**: Add Spinlock type definition
- **Change 3**: Add endianness section for protocol vs hardware
- **Impact**: All existing syscall code needs number updates

### Spec 006 (SysV ABI Init)

- **Change**: Add crt0 implementation requirements
- **Impact**: Userland programs need crt0 linked

### Spec 007 (Linux Compat Layer)

- **Change**: Add VFS shim for /dev/ paths
- **Impact**: sys_open behavior changes

### CLAUDE.md

- **Change**: Update Zig version references, add build patterns
- **Impact**: Code generation guidance updates

### New: Authoritative Syscall Table

- **Location**: `specs/syscall-table.md`
- **Content**: Single source of truth for all syscall numbers
- **Impact**: All specs reference this table

---

## 8. Migration Checklist

For existing spec 003 code (if any exists):

- [ ] Replace SYS_READ=2 with SYS_READ=0
- [ ] Verify SYS_WRITE=1 (already correct)
- [ ] Add SYS_OPEN=2, SYS_CLOSE=3
- [ ] Update build.zig to Zig 0.15.x patterns
- [ ] Add code_model = .kernel for Red Zone handling
- [ ] Wrap critical sections with Spinlock
- [ ] Verify E1000 code uses host byte order
- [ ] Verify protocol code uses network byte order

---

## Sources

- Linux kernel source: `arch/x86/entry/syscalls/syscall_64.tbl`
- Zig 0.15.x release notes and std.Build documentation
- Intel x86_64 Software Developer's Manual (spinlock patterns)
- System V Application Binary Interface (AMD64 Architecture Processor Supplement)
