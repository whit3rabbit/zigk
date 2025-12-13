# Quickstart: Linux Compatibility Layer - Runtime Infrastructure

**Feature Branch**: `007-linux-compat-layer`
**Date**: 2025-12-05

This guide provides a rapid implementation path for Linux runtime infrastructure syscalls.

---

## Prerequisites

Before implementing this feature, ensure the following are complete:

- [ ] **003-microkernel-userland-networking**: Scheduler, timer interrupts, process table
- [ ] **005-linux-syscall-compat**: Syscall dispatch table, error code constants
- [ ] **006-sysv-abi-init**: Process creation, user stack setup

---

## Implementation Order

### Phase 1: Foundation (HAL Layer)

**1.1 TSC/Timer HAL** (`src/kernel/hal/timer.zig`)
```zig
// Minimum viable implementation
pub fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc" : "={eax}" (lo), "={edx}" (hi));
    return (@as(u64, hi) << 32) | lo;
}

pub fn calibrateTSC() u64 {
    // Use PIT for calibration (see research.md for details)
    const pit_hz = 1_193_182;
    const wait_ms = 10;
    const wait_ticks = pit_hz * wait_ms / 1000;

    const start = rdtsc();
    pitWait(wait_ticks);
    const end = rdtsc();

    return (end - start) * 1000 / wait_ms; // Hz
}
```

**1.2 Entropy HAL** (`src/kernel/hal/entropy.zig`)
```zig
pub fn hasRDRAND() bool {
    var ecx: u32 = undefined;
    asm volatile ("cpuid" : "={ecx}" (ecx) : "{eax}" (@as(u32, 1)) : "ebx", "edx");
    return (ecx >> 30) & 1 == 1;
}

pub fn rdrand() ?u64 {
    var val: u64 = undefined;
    var cf: u8 = undefined;
    asm volatile ("rdrand %[val]" : [val] "=r" (val), "=@ccc" (cf));
    return if (cf != 0) val else null;
}
```

### Phase 2: Core Data Structures

**2.1 PRNG** (`src/lib/prng.zig`)
```zig
pub const Xoroshiro128Plus = struct {
    s0: u64,
    s1: u64,

    pub fn next(self: *@This()) u64 {
        const result = self.s0 +% self.s1;
        const s1 = self.s0 ^ self.s1;
        self.s0 = rotl(self.s0, 24) ^ s1 ^ (s1 << 16);
        self.s1 = rotl(s1, 37);
        return result;
    }

    fn rotl(x: u64, comptime k: u6) u64 {
        return (x << k) | (x >> (64 - k));
    }
};
```

**2.2 File Descriptor Table** (`src/kernel/process/fd_table.zig`)
```zig
pub const FileDescriptorTable = struct {
    fds: [16]FileDescriptor = [_]FileDescriptor{.{}} ** 16,

    pub fn init(self: *@This()) void {
        self.fds[0] = .{ .kind = .Keyboard };
        self.fds[1] = .{ .kind = .Console };
        self.fds[2] = .{ .kind = .Console };
    }
};
```

**2.3 Zombie Table** (`src/kernel/process/zombie.zig`)
```zig
pub const ZombieTable = struct {
    entries: [64]ZombieEntry = [_]ZombieEntry{.{}} ** 64,
    count: u32 = 0,

    pub fn add(self: *@This(), pid: u32, parent_pid: u32, status: i32) bool { ... }
    pub fn reap(self: *@This(), pid: i32, parent_pid: u32) ?ZombieEntry { ... }
};
```

### Phase 3: Syscall Implementations

**3.1 getrandom** (`src/kernel/syscall/random.zig`) - Start here, simplest
```zig
var kernel_prng: Xoroshiro128Plus = undefined;
var prng_initialized: bool = false;

pub fn initPRNG() void {
    const seed = if (hal.hasRDRAND()) hal.rdrand() orelse hal.rdtsc() else hal.rdtsc();
    kernel_prng = .{ .s0 = seed, .s1 = seed ^ 0xdeadbeef };
    prng_initialized = true;
}

pub fn sys_getrandom(buf: [*]u8, len: usize, flags: u32) isize {
    _ = flags;
    if (!validateUserPtr(buf, len)) return -14; // EFAULT

    var i: usize = 0;
    while (i < len) {
        const rand = kernel_prng.next();
        const bytes = @as(*const [8]u8, @ptrCast(&rand));
        const n = @min(8, len - i);
        @memcpy(buf[i..][0..n], bytes[0..n]);
        i += n;
    }
    return @intCast(len);
}
```

**3.2 clock_gettime** (`src/kernel/syscall/time.zig`)
```zig
var tsc_hz: u64 = 0;
var boot_tsc: u64 = 0;
const BOOT_EPOCH: u64 = 1735689600; // 2025-01-01

pub fn initClock() void {
    tsc_hz = hal.calibrateTSC();
    boot_tsc = hal.rdtsc();
}

pub fn sys_clock_gettime(clock_id: i32, tp: *Timespec) isize {
    if (clock_id != 0 and clock_id != 1) return -22; // EINVAL
    if (!validateUserPtr(tp, @sizeOf(Timespec))) return -14; // EFAULT

    const now_tsc = hal.rdtsc() - boot_tsc;
    const ns = (now_tsc * 1_000_000_000) / tsc_hz;

    if (clock_id == 0) { // REALTIME
        tp.* = .{
            .tv_sec = @intCast(BOOT_EPOCH + ns / 1_000_000_000),
            .tv_nsec = @intCast(ns % 1_000_000_000),
        };
    } else { // MONOTONIC
        tp.* = .{
            .tv_sec = @intCast(ns / 1_000_000_000),
            .tv_nsec = @intCast(ns % 1_000_000_000),
        };
    }
    return 0;
}
```

**3.3 wait4** (`src/kernel/syscall/process.zig`) - Most complex
```zig
pub fn sys_wait4(pid: i32, wstatus: ?*i32, options: i32, rusage: ?*anyopaque) isize {
    _ = rusage;
    const current = scheduler.currentProcess();

    // Check for zombies first
    if (zombie_table.reap(pid, current.pid)) |zombie| {
        if (wstatus) |ws| ws.* = zombie.status;
        return @intCast(zombie.pid);
    }

    // WNOHANG: return immediately
    if (options & 0x1 != 0) {
        return if (hasLiveChildren(current.pid)) 0 else -10; // ECHILD
    }

    // Block until child exits
    current.state = .WaitingForChild;
    scheduler.yield();

    // Re-check after wakeup
    if (zombie_table.reap(pid, current.pid)) |zombie| {
        if (wstatus) |ws| ws.* = zombie.status;
        return @intCast(zombie.pid);
    }

    return -10; // ECHILD
}
```

### Phase 4: Integration

**4.1 Update Syscall Table** (`src/kernel/syscall/table.zig`)
```zig
pub fn dispatch(num: u64, a1: u64, a2: u64, a3: u64, a4: u64) isize {
    return switch (num) {
        // ... existing syscalls ...
        61 => sys_wait4(@intCast(a1), @ptrFromInt(a2), @intCast(a3), @ptrFromInt(a4)),
        228 => sys_clock_gettime(@intCast(a1), @ptrFromInt(a2)),
        318 => sys_getrandom(@ptrFromInt(a1), a2, @intCast(a3)),
        else => -38, // ENOSYS
    };
}
```

**4.2 Update Process Creation** (`src/kernel/process/task.zig`)
```zig
pub fn createProcess(...) !*Process {
    var proc = try allocator.create(Process);
    proc.fd_table.init(); // Pre-open FDs 0, 1, 2
    // ... rest of initialization ...
}
```

**4.3 Update exit() to Create Zombie** (`src/kernel/syscall/exit.zig`)
```zig
pub fn sys_exit(code: i32) noreturn {
    const proc = scheduler.currentProcess();
    const status = (code & 0xFF) << 8; // Normal exit encoding

    zombie_table.add(proc.pid, proc.parent_pid, status);

    // Wake parent if waiting
    if (findProcess(proc.parent_pid)) |parent| {
        if (parent.state == .WaitingForChild) {
            parent.state = .Ready;
            scheduler.enqueue(parent);
        }
    }

    proc.state = .Dead;
    scheduler.yield();
    unreachable;
}
```

### Phase 5: Initialization

**Boot Sequence** (`src/kernel/main.zig`)
```zig
pub fn kernelMain() void {
    // ... existing init ...

    // Initialize Linux compat layer
    time.initClock();      // Calibrate TSC
    random.initPRNG();     // Seed PRNG

    // ... start userland ...
}
```

---

## Testing Checklist

### Unit Tests (kernel-side)
- [ ] PRNG generates different values on successive calls
- [ ] TSC calibration returns reasonable frequency (100MHz - 5GHz)
- [ ] Zombie table add/reap works correctly
- [ ] FD table initializes with 0, 1, 2 open

### Integration Tests (userland binaries)

**test_stdio.c**:
```c
int main() {
    write(1, "stdout works\n", 13);
    write(2, "stderr works\n", 13);
    return 0;
}
```

**test_clock.c**:
```c
int main() {
    struct timespec t1, t2;
    clock_gettime(1, &t1); // MONOTONIC
    for (volatile int i = 0; i < 10000000; i++);
    clock_gettime(1, &t2);
    // Verify t2 > t1
    return (t2.tv_sec > t1.tv_sec || t2.tv_nsec > t1.tv_nsec) ? 0 : 1;
}
```

**test_random.c**:
```c
int main() {
    uint64_t a, b;
    getrandom(&a, 8, 0);
    getrandom(&b, 8, 0);
    return (a != b) ? 0 : 1;
}
```

**test_wait.c**:
```c
int main() {
    pid_t child = spawn("/test_child"); // Assumes spawn syscall
    int status;
    wait4(child, &status, 0, NULL);
    return WEXITSTATUS(status) == 42 ? 0 : 1;
}
```

---

## Common Pitfalls

1. **Forgetting to initialize FD table**: Pre-open FDs in createProcess(), not lazily
2. **TSC frequency drift**: Acceptable for MVP, but consider periodic recalibration later
3. **Zombie table overflow**: Log warning, don't crash; consider oldest-eviction policy
4. **PRNG not seeded before first getrandom**: Init at boot, before any userland runs
5. **wait4 blocking without scheduler yield**: Must context switch, not spin-wait
6. **Monotonic time going backward**: Keep high-water mark, return max(current, last)

---

## Verification Commands

```bash
# Build kernel with test programs
zig build

# Run in QEMU
qemu-system-x86_64 -cdrom zscapek.iso -serial stdio

# Expected output from test programs:
# stdout works
# stderr works
# Clock test: PASS
# Random test: PASS
# Wait test: PASS (exit code 42)
```

---

## Next Steps After Implementation

1. **Signals** (SIGCHLD): Notify parent when child exits
2. **rusage**: Track CPU time, memory usage per process
3. **CLOCK_PROCESS_CPUTIME_ID**: Per-process CPU time tracking
4. **True entropy collection**: Interrupt timing, disk I/O timing
5. **fork()**: Full process cloning with FD inheritance
