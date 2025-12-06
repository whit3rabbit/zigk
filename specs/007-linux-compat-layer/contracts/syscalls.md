# Syscall Contracts: Linux Compatibility Layer

**Feature Branch**: `007-linux-compat-layer`
**Date**: 2025-12-05

This document defines the syscall interface contracts for Linux runtime infrastructure.

---

## Syscall Table Additions

| Number | Name | Description |
|--------|------|-------------|
| 61 | sys_wait4 | Wait for child process state change |
| 228 | sys_clock_gettime | Get time from specified clock |
| 318 | sys_getrandom | Get random bytes |

---

## 1. sys_wait4 (Syscall 61)

### Signature
```c
pid_t wait4(pid_t pid, int *wstatus, int options, struct rusage *rusage);
```

### Register Convention (x86_64 Linux ABI)
| Register | Parameter | Type |
|----------|-----------|------|
| RAX | Syscall number | 61 |
| RDI | pid | pid_t (i32) |
| RSI | wstatus | int* (nullable) |
| RDX | options | int |
| R10 | rusage | struct rusage* (nullable) |
| RAX (out) | Return value | pid_t or -errno |

### Parameters

**pid** (RDI):
- `> 0`: Wait for child with this specific PID
- `-1`: Wait for any child process
- `0`: Wait for any child in same process group (MVP: same as -1)
- `< -1`: Wait for any child in process group |pid| (MVP: same as -1)

**wstatus** (RSI):
- If non-NULL, store child's exit status at this address
- Status encoding:
  - Normal exit: `(exit_code & 0xFF) << 8`
  - Signal death: `(signal & 0x7F) | (core_dump ? 0x80 : 0)`

**options** (RDX):
- `0`: Block until child exits
- `WNOHANG (0x1)`: Return immediately if no child exited
- Other flags: Reserved, must be 0 for MVP

**rusage** (R10):
- MVP: Ignored if non-NULL (may zero-fill in future)

### Return Value
| Condition | Return Value |
|-----------|--------------|
| Child reaped | Child's PID (> 0) |
| WNOHANG, no child exited | 0 |
| No matching child | -ECHILD (-10) |
| Invalid wstatus pointer | -EFAULT (-14) |
| Invalid options | -EINVAL (-22) |

### Contract

```zig
/// Wait for child process to change state
///
/// Pre-conditions:
///   - Current process has at least one child (unless checking with WNOHANG)
///   - If wstatus != null, it points to valid writable user memory
///
/// Post-conditions:
///   - If child reaped: zombie entry removed, return child PID
///   - If WNOHANG and no child exited: return 0, no state change
///   - If no children exist: return -ECHILD
///
/// Side effects:
///   - Reaping removes zombie from kernel tables
///   - Without WNOHANG, may context switch to other processes
pub fn sys_wait4(pid: i32, wstatus: ?*i32, options: i32, rusage: ?*anyopaque) isize;
```

### Examples

```c
// Wait for any child, blocking
int status;
pid_t child = wait4(-1, &status, 0, NULL);
if (WIFEXITED(status)) {
    printf("Exit code: %d\n", WEXITSTATUS(status));
}

// Non-blocking check
pid_t result = wait4(-1, &status, WNOHANG, NULL);
if (result == 0) {
    // No child exited yet
} else if (result > 0) {
    // Child `result` exited
}
```

---

## 2. sys_clock_gettime (Syscall 228)

### Signature
```c
int clock_gettime(clockid_t clock_id, struct timespec *tp);
```

### Register Convention (x86_64 Linux ABI)
| Register | Parameter | Type |
|----------|-----------|------|
| RAX | Syscall number | 228 |
| RDI | clock_id | clockid_t (i32) |
| RSI | tp | struct timespec* |
| RAX (out) | Return value | 0 or -errno |

### Parameters

**clock_id** (RDI):
- `CLOCK_REALTIME (0)`: Wall-clock time since Unix epoch
- `CLOCK_MONOTONIC (1)`: Time since boot (never decreases)

**tp** (RSI):
- Pointer to timespec structure to fill:
  ```c
  struct timespec {
      time_t tv_sec;   // i64: seconds
      long   tv_nsec;  // i64: nanoseconds [0, 999999999]
  };
  ```

### Return Value
| Condition | Return Value |
|-----------|--------------|
| Success | 0 |
| Invalid clock_id | -EINVAL (-22) |
| Invalid tp pointer | -EFAULT (-14) |

### Contract

```zig
/// Get time from specified clock
///
/// Pre-conditions:
///   - clock_id is 0 (REALTIME) or 1 (MONOTONIC)
///   - tp points to valid writable user memory (16 bytes, 8-byte aligned)
///
/// Post-conditions:
///   - tp->tv_sec contains seconds component
///   - tp->tv_nsec contains nanoseconds in [0, 999999999]
///   - CLOCK_MONOTONIC values never decrease between calls
///
/// Accuracy:
///   - CLOCK_MONOTONIC: Within 10% for elapsed time measurements
///   - CLOCK_REALTIME: Static epoch + monotonic offset (no RTC sync)
pub fn sys_clock_gettime(clock_id: i32, tp: *Timespec) isize;
```

### Implementation Notes

**CLOCK_REALTIME**:
- Returns: `boot_epoch + monotonic_time`
- Boot epoch: 2025-01-01 00:00:00 UTC (1735689600)
- No RTC synchronization in MVP

**CLOCK_MONOTONIC**:
- Uses TSC (Time Stamp Counter) calibrated against PIT at boot
- TSC frequency determined by measuring ticks during known PIT interval
- Guaranteed non-decreasing (kernel maintains high-water mark)

### Examples

```c
// Measure elapsed time
struct timespec t1, t2;
clock_gettime(CLOCK_MONOTONIC, &t1);
do_work();
clock_gettime(CLOCK_MONOTONIC, &t2);
long elapsed_ns = (t2.tv_sec - t1.tv_sec) * 1000000000L +
                  (t2.tv_nsec - t1.tv_nsec);

// Get wall-clock timestamp
struct timespec now;
clock_gettime(CLOCK_REALTIME, &now);
printf("Unix timestamp: %ld\n", now.tv_sec);
```

---

## 3. sys_getrandom (Syscall 318)

### Signature
```c
ssize_t getrandom(void *buf, size_t buflen, unsigned int flags);
```

### Register Convention (x86_64 Linux ABI)
| Register | Parameter | Type |
|----------|-----------|------|
| RAX | Syscall number | 318 |
| RDI | buf | void* |
| RSI | buflen | size_t |
| RDX | flags | unsigned int |
| RAX (out) | Return value | bytes written or -errno |

### Parameters

**buf** (RDI):
- Pointer to buffer to fill with random bytes

**buflen** (RSI):
- Number of random bytes requested
- MVP may limit to 256 bytes per call

**flags** (RDX):
- `0`: Default behavior (urandom-like)
- `GRND_NONBLOCK (0x1)`: Return -EAGAIN if would block (MVP: never blocks)
- `GRND_RANDOM (0x2)`: Use /dev/random source (MVP: same as default)

### Return Value
| Condition | Return Value |
|-----------|--------------|
| Success | Number of bytes written (== buflen) |
| Invalid buf pointer | -EFAULT (-14) |
| Would block (GRND_NONBLOCK) | -EAGAIN (-11) |
| Invalid flags | -EINVAL (-22) |

### Contract

```zig
/// Get random bytes from kernel entropy pool
///
/// Pre-conditions:
///   - buf points to valid writable user memory of at least buflen bytes
///   - flags contains only valid bits (0x1, 0x2)
///
/// Post-conditions:
///   - buf[0..buflen] filled with random bytes
///   - Successive calls return different values (not deterministic)
///
/// Security note:
///   - MVP uses PRNG (xoroshiro128+) seeded from RDRAND/RDTSC
///   - Suitable for hash map seeding, NOT cryptographic use
pub fn sys_getrandom(buf: [*]u8, buflen: usize, flags: u32) isize;
```

### Implementation Notes

**Entropy Sources** (in order of preference):
1. RDRAND instruction (if CPUID indicates support)
2. RDTSC with timing jitter (fallback)

**PRNG**:
- Algorithm: xoroshiro128+ (128-bit state, 64-bit output)
- Seeded once at boot from hardware entropy
- State never reseeded (acceptable for MVP non-crypto use)

### Examples

```c
// Seed a hash map
uint64_t seed;
getrandom(&seed, sizeof(seed), 0);
hashmap_init(&map, seed);

// Get random buffer
uint8_t buffer[32];
ssize_t got = getrandom(buffer, sizeof(buffer), 0);
assert(got == sizeof(buffer));
```

---

## 4. Pre-Opened File Descriptors (Implicit Contract)

While not a syscall, this is a critical runtime contract:

### Contract

```zig
/// File descriptor initialization at process creation
///
/// Pre-conditions:
///   - New user process being created
///
/// Post-conditions:
///   - FD 0 (stdin) open, kind = Keyboard, flags = O_RDONLY
///   - FD 1 (stdout) open, kind = Console, flags = O_WRONLY
///   - FD 2 (stderr) open, kind = Console, flags = O_WRONLY
///   - FDs 3-15 closed, available for user allocation
///
/// Behavior:
///   - write(1, buf, len) outputs to serial + framebuffer
///   - write(2, buf, len) outputs to serial + framebuffer
///   - read(0, buf, len) reads from keyboard buffer
pub fn initProcessFDs(process: *Process) void;
```

### Affected Syscalls

| Syscall | FD | Behavior |
|---------|-----|----------|
| read(0) | stdin | Read from PS/2 keyboard buffer |
| write(1) | stdout | Write to Serial COM1 + Framebuffer |
| write(2) | stderr | Write to Serial COM1 + Framebuffer |

---

## Error Code Summary

| Errno | Value | Meaning |
|-------|-------|---------|
| EBADF | 9 | Bad file descriptor |
| ECHILD | 10 | No child processes |
| EAGAIN | 11 | Resource temporarily unavailable |
| EFAULT | 14 | Bad address (invalid pointer) |
| EINVAL | 22 | Invalid argument |
| EMFILE | 24 | Too many open files |

---

## Syscall Dispatch Integration

Add to syscall dispatch table (from 005-linux-syscall-compat):

```zig
pub const syscall_handlers = [_]?SyscallHandler{
    // ... existing entries ...
    [61] = sys_wait4,
    // ... gap ...
    [228] = sys_clock_gettime,
    // ... gap ...
    [318] = sys_getrandom,
};
```
