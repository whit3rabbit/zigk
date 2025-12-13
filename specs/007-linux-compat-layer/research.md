# Research: Linux Compatibility Layer - Runtime Infrastructure

**Feature Branch**: `007-linux-compat-layer`
**Date**: 2025-12-05
**Status**: Complete

This document consolidates research findings for implementing Linux runtime infrastructure syscalls in Zscapek.

---

## 1. Pre-Opened Standard File Descriptors

### Decision
Initialize FD table at process creation with FDs 0, 1, 2 pre-opened to kernel-controlled devices.

### Rationale
Standard C libraries (musl, glibc) and language runtimes (Zig std, Python) assume FDs 0, 1, 2 exist at process start. The first `printf` or `write(1, ...)` will fail with EBADF if these aren't pre-opened.

### Alternatives Considered
1. **Lazy initialization on first use**: Rejected - breaks standard library assumptions
2. **User-space libc shim**: Rejected - defeats purpose of Linux ABI compatibility
3. **Magic syscall to request FDs**: Rejected - non-standard, incompatible with existing binaries

### Implementation Details

**FD Table Structure**:
```zig
pub const FileDescriptorKind = enum {
    Closed,     // Available for allocation
    Keyboard,   // FD 0 - stdin
    Console,    // FD 1, 2 - stdout/stderr
    InitRDFile, // Files from InitRD
};

pub const FileDescriptor = struct {
    kind: FileDescriptorKind,
    initrd_entry: ?*const InitRDFileEntry = null,
    position: u64 = 0,
    flags: u32 = 0,
};

pub const FileDescriptorTable = struct {
    fds: [16]FileDescriptor,

    pub fn init(self: *FileDescriptorTable) void {
        self.fds[0] = .{ .kind = .Keyboard };   // stdin
        self.fds[1] = .{ .kind = .Console };    // stdout
        self.fds[2] = .{ .kind = .Console };    // stderr
        for (3..16) |i| {
            self.fds[i] = .{ .kind = .Closed };
        }
    }
};
```

**Device Mapping**:
| FD | Device | Direction | Implementation |
|----|--------|-----------|----------------|
| 0 | Keyboard (stdin) | Read | PS/2 keyboard buffer (IRQ1) |
| 1 | Console (stdout) | Write | Serial COM1 + Framebuffer |
| 2 | Console (stderr) | Write | Serial COM1 + Framebuffer |

**FD Allocation on open()**:
- Must return lowest available FD number (POSIX requirement)
- If user closes FD 0 then calls open(), returns FD 0
- Critical for shell redirection: `close(1); open("file") // Returns 1`

---

## 2. wait4 Syscall (Process Waiting)

### Decision
Implement syscall 61 (wait4) with Linux-compatible status encoding and WNOHANG support.

### Rationale
Shell's main loop requires: print prompt, spawn child, **wait for child**, repeat. Without wait4, shell cannot determine when commands complete, causing race conditions and incorrect output ordering.

### Alternatives Considered
1. **Polling with getpid checks**: Rejected - inefficient, no exit code retrieval
2. **Signal-only notification (SIGCHLD)**: Rejected - signals not in MVP, wait4 still needed for reaping
3. **Custom simplified wait**: Rejected - breaks compatibility with standard shell implementations

### Implementation Details

**Syscall Signature**:
```c
pid_t wait4(pid_t pid, int *wstatus, int options, struct rusage *rusage);
// Syscall 61 on x86_64
// RDI = pid, RSI = wstatus pointer, RDX = options, R10 = rusage pointer
```

**Status Word Encoding** (32-bit):
```
Bits 0-6:   Signal number (0 if normal exit)
Bit 7:      Core dump flag
Bits 8-15:  Exit code (if signal == 0)
Bits 16-31: Reserved
```

**Status Construction**:
```zig
fn encodeStatus(exit_code: i32, signal: u8, core_dumped: bool) i32 {
    if (signal == 0) {
        // Normal exit
        return (exit_code & 0xFF) << 8;
    } else {
        // Killed by signal
        var status: i32 = signal & 0x7F;
        if (core_dumped) status |= 0x80;
        return status;
    }
}
```

**WNOHANG Flag** (0x1):
- Without WNOHANG: Block until child exits
- With WNOHANG: Return 0 immediately if no child exited, -ECHILD if no children

**Zombie Process Lifecycle**:
1. Child calls `exit(code)` - becomes zombie, retains only PID + exit status
2. Parent calls `wait4(child_pid, ...)` - reaps zombie, retrieves status
3. If parent dies first: orphaned zombies adopted by init (PID 1)

**Error Codes**:
- `-ECHILD (10)`: No matching child or no children exist
- `-EFAULT (14)`: Invalid wstatus/rusage pointer
- `-EINVAL (22)`: Invalid options

---

## 3. clock_gettime Syscall (Timekeeping)

### Decision
Implement syscall 228 using TSC (Time Stamp Counter) for CLOCK_MONOTONIC, static epoch + monotonic offset for CLOCK_REALTIME.

### Rationale
Modern runtimes require specific clock types. Python's `time.time()`, C's `gettimeofday()`, and Zig's `std.time` all rely on clock_gettime. Without it, timing operations fail.

### Alternatives Considered
1. **PIT-only timing**: Rejected - 1ms granularity too coarse, harder to get nanoseconds
2. **HPET**: Rejected - more complex initialization, not always available
3. **Custom timing syscall**: Rejected - breaks Linux ABI compatibility

### Implementation Details

**Syscall Signature**:
```c
int clock_gettime(clockid_t clock_id, struct timespec *tp);
// Syscall 228 on x86_64
// RDI = clock_id, RSI = timespec pointer
```

**timespec Structure** (16 bytes on x86_64):
```zig
pub const Timespec = extern struct {
    tv_sec: i64,   // Seconds
    tv_nsec: i64,  // Nanoseconds (0-999,999,999)
};
```

**Clock IDs**:
- `CLOCK_REALTIME (0)`: Wall-clock time since Unix epoch
- `CLOCK_MONOTONIC (1)`: Time since boot, never goes backward

**TSC-Based Implementation**:
```zig
// Calibrate at boot using PIT
var tsc_frequency_hz: u64 = 0;

pub fn calibrateTSC() void {
    // Use PIT Channel 2 as reference (1.193182 MHz)
    const pit_frequency = 1_193_182;
    const wait_ticks = pit_frequency / 100; // 10ms

    const start_tsc = rdtsc();
    pitWaitTicks(wait_ticks);
    const end_tsc = rdtsc();

    tsc_frequency_hz = (end_tsc - start_tsc) * 100;
}

pub fn clockMonotonic() Timespec {
    const tsc = rdtsc();
    const ns = (tsc * 1_000_000_000) / tsc_frequency_hz;
    return .{
        .tv_sec = @intCast(ns / 1_000_000_000),
        .tv_nsec = @intCast(ns % 1_000_000_000),
    };
}

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc" : "={eax}" (lo), "={edx}" (hi));
    return (@as(u64, hi) << 32) | lo;
}
```

**CLOCK_REALTIME Without RTC**:
```zig
// Static boot epoch (2025-01-01 00:00:00 UTC)
const boot_epoch_seconds: u64 = 1735689600;

pub fn clockRealtime() Timespec {
    const monotonic = clockMonotonic();
    return .{
        .tv_sec = boot_epoch_seconds + monotonic.tv_sec,
        .tv_nsec = monotonic.tv_nsec,
    };
}
```

**Error Codes**:
- `-EINVAL (22)`: Invalid clock_id
- `-EFAULT (14)`: Invalid timespec pointer

**Accuracy Target**: Within 10% for elapsed time measurements

---

## 4. getrandom Syscall (Entropy)

### Decision
Implement syscall 318 using RDRAND (if available) or RDTSC-seeded xoroshiro128+ PRNG.

### Rationale
Modern language runtimes enable hash randomization by default to prevent DoS attacks. They seed using getrandom. Without it, Python, Go, and even Zig's HashMap will fail to initialize.

### Alternatives Considered
1. **Return constant/predictable values**: Rejected - defeats hash randomization purpose
2. **Require RDRAND (fail if unavailable)**: Rejected - some older CPUs lack it
3. **Cryptographic RNG (ChaCha20)**: Rejected - overkill for hash seeding, adds complexity

### Implementation Details

**Syscall Signature**:
```c
ssize_t getrandom(void *buf, size_t buflen, unsigned int flags);
// Syscall 318 on x86_64
// RDI = buf, RSI = buflen, RDX = flags
```

**Flags**:
- `GRND_NONBLOCK (0x1)`: Return -EAGAIN if entropy unavailable (for MVP, never happens with PRNG)
- `GRND_RANDOM (0x2)`: Use /dev/random source (MVP: same as default)

**RDRAND Detection and Usage**:
```zig
pub fn hasRDRAND() bool {
    var ecx: u32 = undefined;
    asm volatile (
        "cpuid"
        : "={ecx}" (ecx)
        : "{eax}" (@as(u32, 1))
        : "ebx", "edx"
    );
    return (ecx >> 30) & 1 == 1; // Bit 30 = RDRAND support
}

pub fn rdrand() ?u64 {
    var value: u64 = undefined;
    var success: u8 = undefined;
    asm volatile (
        "rdrand %[value]"
        : [value] "=r" (value),
          "=@ccc" (success) // CF set on success
    );
    return if (success != 0) value else null;
}
```

**xoroshiro128+ PRNG** (recommended for hash seeding):
```zig
pub const Xoroshiro128Plus = struct {
    s0: u64,
    s1: u64,

    pub fn next(self: *Xoroshiro128Plus) u64 {
        const result = self.s0 +% self.s1;
        const s1 = self.s0 ^ self.s1;
        self.s0 = rotl(self.s0, 24) ^ s1 ^ (s1 << 16);
        self.s1 = rotl(s1, 37);
        return result;
    }

    fn rotl(x: u64, k: u6) u64 {
        return (x << k) | (x >> @intCast(64 - @as(u7, k)));
    }
};
```

**Boot-Time Seeding**:
```zig
var kernel_prng: Xoroshiro128Plus = undefined;

pub fn initPRNG() void {
    var seed0: u64 = 0;
    var seed1: u64 = 0;

    // Try RDRAND first (best entropy)
    if (hasRDRAND()) {
        seed0 = rdrandRetry(10) orelse rdtsc();
        seed1 = rdrandRetry(10) orelse rdtsc();
    } else {
        // Fallback to RDTSC with timing jitter
        for (0..16) |_| {
            seed0 ^= rdtsc();
            for (0..100) |_| asm volatile ("nop");
        }
        seed1 = rdtsc();
    }

    // Ensure non-zero (PRNG requirement)
    if (seed0 == 0) seed0 = 0x853c49e6748fea9b;
    if (seed1 == 0) seed1 = 0xda3e39cb94b95bdb;

    kernel_prng = .{ .s0 = seed0, .s1 = seed1 };
}
```

**getrandom Implementation**:
```zig
pub fn sysGetrandom(buf: [*]u8, buflen: usize, flags: u32) isize {
    _ = flags; // MVP: ignore flags, always succeed

    var i: usize = 0;
    while (i < buflen) {
        const rand = kernel_prng.next();
        const bytes = @as(*const [8]u8, @ptrCast(&rand));
        const remaining = buflen - i;
        const to_copy = @min(8, remaining);
        @memcpy(buf[i..][0..to_copy], bytes[0..to_copy]);
        i += to_copy;
    }

    return @intCast(buflen);
}
```

**Error Codes**:
- `-EFAULT (14)`: Invalid buffer pointer
- `-EAGAIN (11)`: Would block (with GRND_NONBLOCK, but MVP PRNG never blocks)

---

## 5. Integration with Existing Specs

### Dependencies on 003-microkernel-userland-networking
- **Scheduler**: Required for wait4 blocking (context switch when waiting)
- **Timer interrupts**: Required for clock_gettime (PIT for TSC calibration)
- **Process table**: Extended with parent_pid, exit_status for wait4

### Dependencies on 005-linux-syscall-compat
- **Syscall dispatch table**: Add entries 61, 228, 318
- **Error codes**: Use standard Linux errno values

### Dependencies on 006-sysv-abi-init
- **Process creation**: FD table initialized during process setup
- **Auxiliary vector**: AT_RANDOM can use getrandom for 16 bytes

---

## 6. Testing Strategy

### Pre-Opened FDs Test
```c
// test_stdio.c - compile with musl-gcc -static
int main() {
    write(1, "Hello from FD 1\n", 16);
    write(2, "Hello from FD 2\n", 16);
    return 0;
}
```

### wait4 Test
```c
// test_wait4.c
int main() {
    // Assuming spawn() syscall exists from 003 spec
    pid_t child = spawn("/test_child");
    int status;
    wait4(child, &status, 0, NULL);

    if (WIFEXITED(status)) {
        printf("Child exited with code %d\n", WEXITSTATUS(status));
    }
    return 0;
}
```

### clock_gettime Test
```c
// test_clock.c
int main() {
    struct timespec t1, t2;
    clock_gettime(CLOCK_MONOTONIC, &t1);

    // Sleep ~100ms (busy wait or nanosleep)
    volatile int x = 0;
    for (int i = 0; i < 10000000; i++) x++;

    clock_gettime(CLOCK_MONOTONIC, &t2);
    long delta_ns = (t2.tv_sec - t1.tv_sec) * 1000000000 + (t2.tv_nsec - t1.tv_nsec);
    printf("Elapsed: %ld ns\n", delta_ns);
    return (delta_ns > 50000000 && delta_ns < 500000000) ? 0 : 1;
}
```

### getrandom Test
```c
// test_random.c
int main() {
    uint64_t r1, r2;
    getrandom(&r1, sizeof(r1), 0);
    getrandom(&r2, sizeof(r2), 0);

    printf("Random 1: %lx\n", r1);
    printf("Random 2: %lx\n", r2);

    return (r1 != r2) ? 0 : 1; // Should differ
}
```

---

## 7. References

- Linux man pages: wait4(2), clock_gettime(2), getrandom(2)
- Intel SDM Vol. 2: RDTSC, RDRAND instructions
- OSDev Wiki: Programmable Interval Timer, File Descriptors
- Sebastiano Vigna: xoroshiro128+ PRNG (https://prng.di.unimi.it/)
- Linux kernel source: kernel/exit.c (wait4), kernel/time/posix-timers.c (clock_gettime)
