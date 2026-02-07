# Phase 4: Event Notification FDs - Research

**Researched:** 2026-02-07
**Domain:** Linux event notification file descriptors (eventfd, timerfd, signalfd)
**Confidence:** HIGH

## Summary

Phase 4 implements three types of event notification file descriptors that integrate with the completed epoll infrastructure from Phase 3. The kernel has all necessary building blocks in place:
- File descriptor infrastructure with FileOps.poll support (Phase 3)
- Timer wheel for timeout management (`src/kernel/io/timer.zig`)
- Signal handling subsystem with pending_signals tracking (`src/kernel/proc/signal.zig`)
- Scheduler sleep/wakeup primitives for blocking I/O
- Heap allocator for dynamic state allocation

The missing pieces are:
1. eventfd: 64-bit counter FD with read/write/poll ops and semaphore mode
2. timerfd: POSIX timer abstraction as FD with hrtimer-like expiration tracking
3. signalfd: Signal reception as FD read operations instead of signal handlers

**Primary recommendation:** Implement each event FD type as a separate FileOps vtable with dedicated state structures, following the pattern used for pipes and epoll instances. Use existing timer wheel for timerfd expiration tracking and signal infrastructure for signalfd.

## Standard Stack

### Core System Calls

| Syscall | x86_64 | aarch64 | Purpose |
|---------|--------|---------|---------|
| SYS_EVENTFD2 | 290 | 19 | Create eventfd with flags (preferred) |
| SYS_EVENTFD | 284 | 524 | Create eventfd without flags (legacy) |
| SYS_TIMERFD_CREATE | 283 | 85 | Create timerfd instance |
| SYS_TIMERFD_SETTIME | 286 | 86 | Arm/disarm timerfd timer |
| SYS_TIMERFD_GETTIME | 287 | 87 | Query timerfd state |
| SYS_SIGNALFD4 | 289 | 74 | Create signalfd with flags (preferred) |
| SYS_SIGNALFD | 282 | 523 | Create signalfd without flags (legacy) |

**Note:** All syscall numbers already defined in `src/uapi/syscalls/linux.zig` and `linux_aarch64.zig`. Legacy variants (without flags) can be implemented as wrappers calling the *2/*4 versions with flags=0.

### Required UAPI Structures

**Missing structures** (need to be added to `src/uapi/`):

```zig
// src/uapi/io/eventfd.zig
pub const EFD_CLOEXEC: u32 = 0x80000;     // O_CLOEXEC
pub const EFD_NONBLOCK: u32 = 0x800;      // O_NONBLOCK
pub const EFD_SEMAPHORE: u32 = 0x1;       // Semaphore-like read semantics

// src/uapi/io/timerfd.zig
pub const TFD_CLOEXEC: u32 = 0x80000;     // O_CLOEXEC
pub const TFD_NONBLOCK: u32 = 0x800;      // O_NONBLOCK
pub const TFD_TIMER_ABSTIME: u32 = 0x1;   // Absolute time (vs relative)
pub const TFD_TIMER_CANCEL_ON_SET: u32 = 0x2; // Cancel on clock change

pub const CLOCK_REALTIME: i32 = 0;
pub const CLOCK_MONOTONIC: i32 = 1;
pub const CLOCK_BOOTTIME: i32 = 7;

pub const ITimerSpec = extern struct {
    it_interval: TimeSpec,  // Repetition interval
    it_value: TimeSpec,     // Initial expiration
};

// src/uapi/io/signalfd.zig
pub const SFD_CLOEXEC: u32 = 0x80000;     // O_CLOEXEC
pub const SFD_NONBLOCK: u32 = 0x800;      // O_NONBLOCK

pub const SignalFdSigInfo = extern struct {
    ssi_signo: u32,     // Signal number
    ssi_errno: i32,     // Error number (unused)
    ssi_code: i32,      // Signal code
    ssi_pid: u32,       // PID of sender
    ssi_uid: u32,       // Real UID of sender
    ssi_fd: i32,        // File descriptor (SIGIO)
    ssi_tid: u32,       // Kernel timer ID (POSIX timers)
    ssi_band: u32,      // Band event (SIGIO)
    ssi_overrun: u32,   // POSIX timer overrun count
    ssi_trapno: u32,    // Trap number that caused signal
    ssi_status: i32,    // Exit status or signal (SIGCHLD)
    ssi_int: i32,       // Integer sent by sigqueue(3)
    ssi_ptr: u64,       // Pointer sent by sigqueue(3)
    ssi_utime: u64,     // User CPU time consumed (SIGCHLD)
    ssi_stime: u64,     // System CPU time consumed (SIGCHLD)
    ssi_addr: u64,      // Address that generated signal
    ssi_addr_lsb: u16,  // Least significant bit of address (SIGBUS)
    _pad: [46]u8,       // Pad to 128 bytes
};
```

### Existing Infrastructure to Reuse

| Component | Location | How to Use |
|-----------|----------|------------|
| TimerWheel | `src/kernel/io/timer.zig` | Add timerfd expirations to wheel, callback wakes blocked threads |
| Signal tracking | `src/kernel/proc/thread.zig:pending_signals` | signalfd reads from same queue as signal delivery |
| FileOps.poll | `src/kernel/fs/fd.zig:88` | Implement poll for each event FD type |
| Scheduler sleep | `src/kernel/proc/sched/scheduler.zig:block()` | Block threads waiting on event FDs |
| Heap allocator | `heap.allocator()` | Allocate event FD state structures |

## Architecture Patterns

### Recommended Project Structure

```
src/kernel/sys/syscall/io/
├── eventfd.zig           # eventfd2/eventfd syscalls + state
├── timerfd.zig           # timerfd_create/settime/gettime + state
├── signalfd.zig          # signalfd4/signalfd syscalls + state
└── root.zig              # Export syscalls (add to existing)

src/uapi/io/
├── eventfd.zig           # EFD_* flags
├── timerfd.zig           # TFD_* flags, ITimerSpec, CLOCK_* constants
└── signalfd.zig          # SFD_* flags, SignalFdSigInfo structure

src/user/lib/syscall/
└── io.zig                # Add userspace wrappers (eventfd2, timerfd_*, signalfd4)

src/user/test_runner/tests/syscall/
└── event_fds.zig         # Integration tests for all three FD types
```

### Pattern 1: eventfd Implementation

**What:** 64-bit counter that can be read, written, and polled. Two modes: normal (read returns full counter) and semaphore (read returns 1, decrements by 1).

**State Structure:**
```zig
// In src/kernel/sys/syscall/io/eventfd.zig
const EventFdState = struct {
    counter: std.atomic.Value(u64),  // Atomic 64-bit counter
    semaphore_mode: bool,             // EFD_SEMAPHORE flag
    lock: sync.Spinlock,              // Protects counter updates and waiter list
    blocked_readers: ?*sched.Thread,  // Threads waiting for counter > 0
    blocked_writers: ?*sched.Thread,  // Threads waiting for counter < MAX

    const MAX_COUNTER: u64 = 0xfffffffffffffffe;

    pub fn init(initval: u64, semaphore_mode: bool) EventFdState {
        return .{
            .counter = std.atomic.Value(u64).init(initval),
            .semaphore_mode = semaphore_mode,
            .lock = .{},
            .blocked_readers = null,
            .blocked_writers = null,
        };
    }
};
```

**Read Semantics:**
```zig
fn eventfdRead(fd: *fd_mod.FileDescriptor, buf: []u8) isize {
    if (buf.len < 8) return -@as(isize, @intCast(@intFromEnum(Errno.EINVAL)));

    const state: *EventFdState = @ptrCast(@alignCast(fd.private_data));
    const held = state.lock.acquire();
    defer held.release();

    const current_value = state.counter.load(.monotonic);

    // Block if counter is zero
    if (current_value == 0) {
        if ((fd.flags & fd_mod.O_NONBLOCK) != 0) {
            return -@as(isize, @intCast(@intFromEnum(Errno.EAGAIN)));
        }
        // Add to blocked_readers, release lock, block
        // (see pipe.zig pipeRead for full blocking pattern)
        held.release();
        sched.block();
        // Re-acquire lock after wake, re-check counter...
    }

    var result: u64 = undefined;
    if (state.semaphore_mode) {
        // Semaphore mode: return 1, decrement by 1
        result = 1;
        _ = state.counter.fetchSub(1, .release);
    } else {
        // Normal mode: return full value, reset to 0
        result = current_value;
        state.counter.store(0, .release);
    }

    // Wake blocked writers if counter was at MAX
    if (state.blocked_writers) |_| {
        // Wake writers (counter now has space)
        // (see pipe.zig wake pattern)
    }

    // Copy result to userspace
    @memcpy(buf[0..8], std.mem.asBytes(&result));
    return 8;
}
```

**Write Semantics:**
```zig
fn eventfdWrite(fd: *fd_mod.FileDescriptor, buf: []const u8) isize {
    if (buf.len < 8) return -@as(isize, @intCast(@intFromEnum(Errno.EINVAL)));

    var value: u64 = undefined;
    @memcpy(std.mem.asBytes(&value), buf[0..8]);

    // Reject value 0xffffffffffffffff (reserved for overflow signal)
    if (value == 0xffffffffffffffff) {
        return -@as(isize, @intCast(@intFromEnum(Errno.EINVAL)));
    }

    const state: *EventFdState = @ptrCast(@alignCast(fd.private_data));
    const held = state.lock.acquire();
    defer held.release();

    const current = state.counter.load(.monotonic);
    const new_value = current + value;

    // Check for overflow
    if (new_value > EventFdState.MAX_COUNTER or new_value < current) {
        if ((fd.flags & fd_mod.O_NONBLOCK) != 0) {
            return -@as(isize, @intCast(@intFromEnum(Errno.EAGAIN)));
        }
        // Block until space available (reader drains counter)
        // ...
    }

    state.counter.store(new_value, .release);

    // Wake blocked readers
    if (state.blocked_readers) |_| {
        // Wake readers (counter now > 0)
        // ...
    }

    return 8;
}
```

**Poll Implementation:**
```zig
fn eventfdPoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    const state: *EventFdState = @ptrCast(@alignCast(fd.private_data));
    const counter = state.counter.load(.monotonic);

    var revents: u32 = 0;

    // Readable if counter > 0
    if ((requested_events & uapi.epoll.EPOLLIN) != 0) {
        if (counter > 0) {
            revents |= uapi.epoll.EPOLLIN;
        }
    }

    // Writable if counter < MAX (at least 1 can be added)
    if ((requested_events & uapi.epoll.EPOLLOUT) != 0) {
        if (counter < EventFdState.MAX_COUNTER) {
            revents |= uapi.epoll.EPOLLOUT;
        }
    }

    return revents;
}
```

**Source:** Pattern derived from [eventfd(2) man page](https://man7.org/linux/man-pages/man2/eventfd.2.html) and existing pipe implementation in `src/kernel/fs/pipe.zig`.

### Pattern 2: timerfd Implementation

**What:** POSIX timer abstraction that delivers expiration events via read(). Supports one-shot and periodic timers with nanosecond precision.

**State Structure:**
```zig
// In src/kernel/sys/syscall/io/timerfd.zig
const TimerFdState = struct {
    clockid: i32,                      // CLOCK_REALTIME, CLOCK_MONOTONIC, etc.
    expiry_count: std.atomic.Value(u64), // Number of expirations since last read
    lock: sync.Spinlock,               // Protects timer state
    blocked_readers: ?*sched.Thread,   // Threads waiting for expiration
    armed: bool,                       // Is timer currently armed?
    interval_ns: u64,                  // Repetition interval (0 = one-shot)
    next_expiry_ns: u64,               // Absolute time of next expiration
    timer_wheel_slot: ?*io.TimerWheel, // Integration with kernel timer wheel

    pub fn init(clockid: i32) TimerFdState {
        return .{
            .clockid = clockid,
            .expiry_count = std.atomic.Value(u64).init(0),
            .lock = .{},
            .blocked_readers = null,
            .armed = false,
            .interval_ns = 0,
            .next_expiry_ns = 0,
            .timer_wheel_slot = null,
        };
    }
};
```

**timerfd_settime Implementation:**
```zig
pub fn sys_timerfd_settime(
    fd_num: usize,
    flags: usize,
    new_value_ptr: usize,
    old_value_ptr: usize
) SyscallError!usize {
    // Get timerfd instance
    const table = base.getGlobalFdTable();
    const fd = table.get(@intCast(fd_num)) orelse return error.EBADF;

    const state: *TimerFdState = @ptrCast(@alignCast(fd.private_data));

    // Read new timer spec from userspace
    const new_spec = UserPtr.from(new_value_ptr).readValue(uapi.io.ITimerSpec) catch {
        return error.EFAULT;
    };

    const held = state.lock.acquire();
    defer held.release();

    // Save old value if requested
    if (old_value_ptr != 0) {
        const old_spec = state.toITimerSpec();
        UserPtr.from(old_value_ptr).writeValue(old_spec) catch {
            return error.EFAULT;
        };
    }

    // Disarm if it_value is zero
    if (new_spec.it_value.tv_sec == 0 and new_spec.it_value.tv_nsec == 0) {
        state.armed = false;
        // Cancel any pending timer in timer wheel
        // ...
        return 0;
    }

    // Calculate expiration time
    const value_ns = timespecToNanoseconds(new_spec.it_value);
    const interval_ns = timespecToNanoseconds(new_spec.it_interval);

    if ((flags & uapi.io.TFD_TIMER_ABSTIME) != 0) {
        // Absolute time
        state.next_expiry_ns = value_ns;
    } else {
        // Relative time
        const now_ns = getClockNanoseconds(state.clockid);
        state.next_expiry_ns = now_ns + value_ns;
    }

    state.interval_ns = interval_ns;
    state.armed = true;

    // Register with timer wheel (convert ns to ticks)
    const ticks = (state.next_expiry_ns - getClockNanoseconds(state.clockid)) / io.timer.TICK_NS;
    // Add to timer wheel with callback to increment expiry_count and wake blocked_readers
    // ...

    return 0;
}
```

**Read Semantics:**
```zig
fn timerfdRead(fd: *fd_mod.FileDescriptor, buf: []u8) isize {
    if (buf.len < 8) return -@as(isize, @intCast(@intFromEnum(Errno.EINVAL)));

    const state: *TimerFdState = @ptrCast(@alignCast(fd.private_data));
    const held = state.lock.acquire();
    defer held.release();

    const count = state.expiry_count.load(.monotonic);

    // Block if no expirations
    if (count == 0) {
        if ((fd.flags & fd_mod.O_NONBLOCK) != 0) {
            return -@as(isize, @intCast(@intFromEnum(Errno.EAGAIN)));
        }
        // Block until expiration (timer callback wakes us)
        // ...
    }

    // Reset counter (consume expirations)
    state.expiry_count.store(0, .release);

    // Return expiration count
    @memcpy(buf[0..8], std.mem.asBytes(&count));
    return 8;
}
```

**Poll Implementation:**
```zig
fn timerfdPoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    const state: *TimerFdState = @ptrCast(@alignCast(fd.private_data));
    const count = state.expiry_count.load(.monotonic);

    var revents: u32 = 0;

    // Readable if at least one expiration occurred
    if ((requested_events & uapi.epoll.EPOLLIN) != 0) {
        if (count > 0) {
            revents |= uapi.epoll.EPOLLIN;
        }
    }

    return revents;
}
```

**Source:** Pattern derived from [timerfd_create(2) man page](https://man7.org/linux/man-pages/man2/timerfd_create.2.html) and [Linux kernel timerfd.c](https://github.com/torvalds/linux/blob/master/fs/timerfd.c).

### Pattern 3: signalfd Implementation

**What:** Signal reception via file descriptor instead of signal handlers. Reads return SignalFdSigInfo structures with signal metadata.

**State Structure:**
```zig
// In src/kernel/sys/syscall/io/signalfd.zig
const SignalFdState = struct {
    sigmask: u64,                     // Mask of signals to accept
    lock: sync.Spinlock,              // Protects state
    blocked_readers: ?*sched.Thread,  // Threads waiting for signals

    pub fn init(sigmask: u64) SignalFdState {
        // SECURITY: Silently ignore SIGKILL and SIGSTOP (cannot be caught)
        const filtered_mask = sigmask & ~(@as(u64, 1) << (uapi.signal.SIGKILL - 1))
                                       & ~(@as(u64, 1) << (uapi.signal.SIGSTOP - 1));
        return .{
            .sigmask = filtered_mask,
            .lock = .{},
            .blocked_readers = null,
        };
    }
};
```

**Read Semantics:**
```zig
fn signalfdRead(fd: *fd_mod.FileDescriptor, buf: []u8) isize {
    if (buf.len < @sizeOf(uapi.io.SignalFdSigInfo)) {
        return -@as(isize, @intCast(@intFromEnum(Errno.EINVAL)));
    }

    const state: *SignalFdState = @ptrCast(@alignCast(fd.private_data));
    const current = sched.getCurrentThread() orelse return -@as(isize, @intCast(@intFromEnum(Errno.EINVAL)));

    const held = state.lock.acquire();
    defer held.release();

    // Check for pending signals in our mask
    const pending = current.pending_signals & state.sigmask;

    if (pending == 0) {
        if ((fd.flags & fd_mod.O_NONBLOCK) != 0) {
            return -@as(isize, @intCast(@intFromEnum(Errno.EAGAIN)));
        }
        // Block until signal arrives
        // ...
    }

    // Find first pending signal
    const sig_bit = @ctz(pending);
    const signum = sig_bit + 1;

    // Clear the pending bit (consume signal)
    // CRITICAL: This prevents signal handler from also receiving it
    current.pending_signals &= ~(@as(u64, 1) << @truncate(sig_bit));

    // Build SignalFdSigInfo structure
    var info: uapi.io.SignalFdSigInfo = std.mem.zeroes(uapi.io.SignalFdSigInfo);
    info.ssi_signo = @intCast(signum);
    // TODO: Fill in ssi_code, ssi_pid, ssi_uid from signal queue metadata
    // For MVP, basic fields are sufficient

    // Copy to userspace
    @memcpy(buf[0..@sizeOf(uapi.io.SignalFdSigInfo)], std.mem.asBytes(&info));
    return @intCast(@sizeOf(uapi.io.SignalFdSigInfo));
}
```

**Poll Implementation:**
```zig
fn signalfdPoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    const state: *SignalFdState = @ptrCast(@alignCast(fd.private_data));
    const current = sched.getCurrentThread() orelse return 0;

    var revents: u32 = 0;

    // Readable if any signals in mask are pending
    if ((requested_events & uapi.epoll.EPOLLIN) != 0) {
        const pending = current.pending_signals & state.sigmask;
        if (pending != 0) {
            revents |= uapi.epoll.EPOLLIN;
        }
    }

    return revents;
}
```

**Updating existing FD:** signalfd4 with fd != -1
```zig
pub fn sys_signalfd4(fd_num: isize, mask_ptr: usize, flags: usize) SyscallError!usize {
    // Read mask from userspace
    const mask = UserPtr.from(mask_ptr).readValue(u64) catch {
        return error.EFAULT;
    };

    if (fd_num != -1) {
        // Update existing signalfd
        const table = base.getGlobalFdTable();
        const fd = table.get(@intCast(fd_num)) orelse return error.EBADF;

        const state: *SignalFdState = @ptrCast(@alignCast(fd.private_data));
        const held = state.lock.acquire();
        defer held.release();

        // Update mask
        state.sigmask = mask & ~(@as(u64, 1) << (uapi.signal.SIGKILL - 1))
                              & ~(@as(u64, 1) << (uapi.signal.SIGSTOP - 1));

        return @intCast(fd_num);
    }

    // Create new signalfd (same pattern as eventfd/timerfd)
    // ...
}
```

**Source:** Pattern derived from [signalfd(2) man page](https://man7.org/linux/man-pages/man2/signalfd.2.html) and [Using signalfd and pidfd to make signals less painful under Linux](https://unixism.net/2021/02/making-signals-less-painful-under-linux/).

### Pattern 4: FileOps Vtable Wiring

**What:** Each event FD type needs a FileOps vtable similar to pipes and epoll

**Example:**
```zig
// In src/kernel/sys/syscall/io/eventfd.zig
const eventfd_file_ops = fd_mod.FileOps{
    .read = eventfdRead,
    .write = eventfdWrite,
    .close = eventfdClose,
    .seek = null,  // Not seekable
    .stat = null,  // No stat support
    .ioctl = null,
    .mmap = null,
    .poll = eventfdPoll,
    .truncate = null,
    .getdents = null,
    .chown = null,
};

pub fn sys_eventfd2(initval: usize, flags: usize) SyscallError!usize {
    // Allocate state
    const state = heap.allocator().create(EventFdState) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(state);

    const semaphore = (flags & uapi.io.EFD_SEMAPHORE) != 0;
    state.* = EventFdState.init(@intCast(initval), semaphore);

    // Allocate FD
    const fd = heap.allocator().create(fd_mod.FileDescriptor) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(fd);

    var fd_flags: u32 = fd_mod.O_RDWR;
    if ((flags & uapi.io.EFD_NONBLOCK) != 0) {
        fd_flags |= fd_mod.O_NONBLOCK;
    }

    fd.* = fd_mod.FileDescriptor{
        .ops = &eventfd_file_ops,
        .flags = fd_flags,
        .private_data = state,
        .position = 0,
        .refcount = .{ .raw = 1 },
        .lock = .{},
        .cloexec = (flags & uapi.io.EFD_CLOEXEC) != 0,
    };

    // Install in FD table
    const table = base.getGlobalFdTable();
    const fd_num = table.allocAndInstall(fd) orelse {
        heap.allocator().destroy(fd);
        return error.EMFILE;
    };

    return fd_num;
}
```

### Anti-Patterns to Avoid

- **DON'T use global timer state** - Each timerfd must have independent timer state. Multiple processes can create multiple timerfds with different clocks and intervals.
- **DON'T call signal handlers when signalfd consumes signal** - Once a signal is read from signalfd, it MUST NOT be delivered to signal handlers. Clear the pending bit atomically.
- **DON'T allow SIGKILL or SIGSTOP in signalfd mask** - These are silently ignored per POSIX. Filter them out in sys_signalfd4.
- **DON'T overflow eventfd counter** - Maximum is 0xfffffffffffffffe. Writes that would exceed this must block (or fail with EAGAIN in non-blocking mode).
- **DON'T use wrong clock for timerfd** - CLOCK_REALTIME is wall-clock time (can jump), CLOCK_MONOTONIC is uptime (never goes backward). Applications choose based on use case.
- **DON'T forget to wake waiters on state change** - eventfd write must wake blocked readers, timerfd expiration must wake blocked readers, signal delivery must wake signalfd readers.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Timer expiration tracking | Custom timer list with polling | Existing `TimerWheel` in `src/kernel/io/timer.zig` | Already O(1) hierarchical wheel, integrates with reactor, supports nanosecond precision |
| Signal queue metadata | Parse signal stack frames | `Thread.pending_signals` bitmask | Already tracks pending signals, atomically updated on signal delivery |
| Thread blocking/wakeup | Custom sleep loop | `sched.block()` and `sched.unblock()` | Scheduler-aware sleep, prevents CPU waste, integrates with futex/wait queues |
| File descriptor allocation | Manual slot search | `FdTable.allocAndInstall()` | Atomic allocation prevents race between alloc and install |
| Atomic counter operations | Manual lock + increment | `std.atomic.Value(u64)` | Lock-free on x86_64/aarch64, prevents contention |

**Key insight:** The kernel already has production-quality timer, signal, and scheduling infrastructure. Event FDs are thin wrappers that expose these primitives via file descriptors.

## Common Pitfalls

### Pitfall 1: eventfd Counter Overflow Not Handled

**What goes wrong:** Writes that would cause counter to exceed MAX (0xfffffffffffffffe) are accepted, causing wraparound and incorrect behavior

**Why it happens:** Arithmetic overflow is silently ignored without explicit checks

**How to avoid:**
```zig
const current = state.counter.load(.monotonic);
const new_value = current + value;

// Check for overflow BEFORE updating counter
if (new_value > EventFdState.MAX_COUNTER or new_value < current) {
    // Overflow would occur - block or fail
    if ((fd.flags & fd_mod.O_NONBLOCK) != 0) {
        return -@as(isize, @intCast(@intFromEnum(Errno.EAGAIN)));
    }
    // Block until reader drains counter
}
```

**Warning signs:** eventfd reads return unexpected small values after many writes, tests with counter near MAX fail

### Pitfall 2: signalfd Consumes Signals Without Clearing pending_signals

**What goes wrong:** Signal is read from signalfd but remains in pending_signals, causing double delivery (both signalfd and signal handler receive it)

**Why it happens:** Read returns signal info but forgets to clear the pending bit

**How to avoid:**
```zig
// Find signal
const sig_bit = @ctz(pending);
const signum = sig_bit + 1;

// CRITICAL: Clear pending bit BEFORE releasing lock
current.pending_signals &= ~(@as(u64, 1) << @truncate(sig_bit));

// Now build SignalFdSigInfo and return
```

**Warning signs:** Signal handlers fire even when signals should only go to signalfd, race conditions in signal delivery

### Pitfall 3: timerfd Expiration Callback Not Waking Readers

**What goes wrong:** Timer expires but read() continues to block forever

**Why it happens:** Timer callback increments expiry_count but doesn't wake blocked threads

**How to avoid:**
```zig
// In timer expiration callback (registered with TimerWheel)
fn timerfdExpired(state: *TimerFdState) void {
    const held = state.lock.acquire();
    defer held.release();

    // Increment expiration count
    _ = state.expiry_count.fetchAdd(1, .release);

    // Wake all blocked readers
    if (state.blocked_readers) |thread| {
        sched.unblock(thread);
        state.blocked_readers = null;
    }

    // Re-arm if periodic
    if (state.interval_ns > 0) {
        state.next_expiry_ns += state.interval_ns;
        // Re-register with timer wheel
    }
}
```

**Warning signs:** timerfd_read blocks forever even after timer expiry, no EPOLLIN events on timerfd

### Pitfall 4: Semaphore Mode Read Returning Full Counter

**What goes wrong:** EFD_SEMAPHORE eventfd returns full counter value instead of 1

**Why it happens:** Forgot to check semaphore_mode flag in read

**How to avoid:**
```zig
var result: u64 = undefined;
if (state.semaphore_mode) {
    // Semaphore: ALWAYS return 1, decrement by 1
    result = 1;
    _ = state.counter.fetchSub(1, .release);
} else {
    // Normal: return full value, reset to 0
    result = current_value;
    state.counter.store(0, .release);
}
```

**Warning signs:** Semaphore-mode eventfd behaves like normal mode, concurrent readers see wrong values

### Pitfall 5: timerfd Absolute vs Relative Time Confusion

**What goes wrong:** TFD_TIMER_ABSTIME flag ignored, all timers treated as relative

**Why it happens:** Expiration time calculation doesn't check flags

**How to avoid:**
```zig
const value_ns = timespecToNanoseconds(new_spec.it_value);

if ((flags & uapi.io.TFD_TIMER_ABSTIME) != 0) {
    // Absolute: use value_ns directly as expiration time
    state.next_expiry_ns = value_ns;
} else {
    // Relative: add to current time
    const now_ns = getClockNanoseconds(state.clockid);
    state.next_expiry_ns = now_ns + value_ns;
}
```

**Warning signs:** Timers fire immediately when given future absolute times, timers never fire when given past absolute times

### Pitfall 6: signalfd Mask Updated Without Lock

**What goes wrong:** signalfd4 with existing fd races with read, causing torn reads of sigmask

**Why it happens:** sys_signalfd4 updates state.sigmask without acquiring state.lock

**How to avoid:**
```zig
// In sys_signalfd4 when updating existing fd
const state: *SignalFdState = @ptrCast(@alignCast(fd.private_data));
const held = state.lock.acquire();
defer held.release();

// Update mask under lock
state.sigmask = filtered_mask;
```

**Warning signs:** signalfd sometimes reports signals not in mask, race conditions in signal reception

## Code Examples

### Example 1: Complete eventfd2 Syscall

```zig
// In src/kernel/sys/syscall/io/eventfd.zig

const std = @import("std");
const heap = @import("heap");
const fd_mod = @import("fd");
const sched = @import("sched");
const sync = @import("sync");
const uapi = @import("uapi");
const base = @import("../base.zig");

const SyscallError = base.SyscallError;
const Errno = uapi.errno.Errno;

const EventFdState = struct {
    counter: std.atomic.Value(u64),
    semaphore_mode: bool,
    lock: sync.Spinlock,
    blocked_readers: ?*sched.Thread,
    blocked_writers: ?*sched.Thread,

    const MAX_COUNTER: u64 = 0xfffffffffffffffe;

    pub fn init(initval: u64, semaphore_mode: bool) EventFdState {
        return .{
            .counter = std.atomic.Value(u64).init(initval),
            .semaphore_mode = semaphore_mode,
            .lock = .{},
            .blocked_readers = null,
            .blocked_writers = null,
        };
    }
};

fn eventfdRead(fd: *fd_mod.FileDescriptor, buf: []u8) isize {
    if (buf.len < 8) return -@as(isize, @intCast(@intFromEnum(Errno.EINVAL)));

    const state: *EventFdState = @ptrCast(@alignCast(fd.private_data));
    const held = state.lock.acquire();
    defer held.release();

    const current_value = state.counter.load(.monotonic);

    if (current_value == 0) {
        if ((fd.flags & fd_mod.O_NONBLOCK) != 0) {
            return -@as(isize, @intCast(@intFromEnum(Errno.EAGAIN)));
        }
        // Blocking read implementation (see pipe.zig for full pattern)
        // Add to blocked_readers, release lock, block, re-acquire, re-check
        // ...
        return -@as(isize, @intCast(@intFromEnum(Errno.EINTR))); // Placeholder
    }

    var result: u64 = undefined;
    if (state.semaphore_mode) {
        result = 1;
        _ = state.counter.fetchSub(1, .release);
    } else {
        result = current_value;
        state.counter.store(0, .release);
    }

    // Wake blocked writers if counter was full
    if (state.blocked_writers) |thread| {
        sched.unblock(thread);
        state.blocked_writers = null;
    }

    @memcpy(buf[0..8], std.mem.asBytes(&result));
    return 8;
}

fn eventfdWrite(fd: *fd_mod.FileDescriptor, buf: []const u8) isize {
    if (buf.len < 8) return -@as(isize, @intCast(@intFromEnum(Errno.EINVAL)));

    var value: u64 = undefined;
    @memcpy(std.mem.asBytes(&value), buf[0..8]);

    if (value == 0xffffffffffffffff) {
        return -@as(isize, @intCast(@intFromEnum(Errno.EINVAL)));
    }

    const state: *EventFdState = @ptrCast(@alignCast(fd.private_data));
    const held = state.lock.acquire();
    defer held.release();

    const current = state.counter.load(.monotonic);
    const new_value = current + value;

    if (new_value > EventFdState.MAX_COUNTER or new_value < current) {
        if ((fd.flags & fd_mod.O_NONBLOCK) != 0) {
            return -@as(isize, @intCast(@intFromEnum(Errno.EAGAIN)));
        }
        // Block until space available
        // ...
        return -@as(isize, @intCast(@intFromEnum(Errno.EINTR))); // Placeholder
    }

    state.counter.store(new_value, .release);

    // Wake blocked readers
    if (state.blocked_readers) |thread| {
        sched.unblock(thread);
        state.blocked_readers = null;
    }

    return 8;
}

fn eventfdPoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    const state: *EventFdState = @ptrCast(@alignCast(fd.private_data));
    const counter = state.counter.load(.monotonic);

    var revents: u32 = 0;

    if ((requested_events & uapi.epoll.EPOLLIN) != 0) {
        if (counter > 0) {
            revents |= uapi.epoll.EPOLLIN;
        }
    }

    if ((requested_events & uapi.epoll.EPOLLOUT) != 0) {
        if (counter < EventFdState.MAX_COUNTER) {
            revents |= uapi.epoll.EPOLLOUT;
        }
    }

    return revents;
}

fn eventfdClose(fd: *fd_mod.FileDescriptor) isize {
    if (fd.private_data) |ptr| {
        const state: *EventFdState = @ptrCast(@alignCast(ptr));
        heap.allocator().destroy(state);
        fd.private_data = null;
    }
    return 0;
}

const eventfd_file_ops = fd_mod.FileOps{
    .read = eventfdRead,
    .write = eventfdWrite,
    .close = eventfdClose,
    .seek = null,
    .stat = null,
    .ioctl = null,
    .mmap = null,
    .poll = eventfdPoll,
    .truncate = null,
    .getdents = null,
    .chown = null,
};

pub fn sys_eventfd2(initval: usize, flags: usize) SyscallError!usize {
    const state = heap.allocator().create(EventFdState) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(state);

    const semaphore = (flags & uapi.io.EFD_SEMAPHORE) != 0;
    state.* = EventFdState.init(@intCast(initval), semaphore);

    const fd = heap.allocator().create(fd_mod.FileDescriptor) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(fd);

    var fd_flags: u32 = fd_mod.O_RDWR;
    if ((flags & uapi.io.EFD_NONBLOCK) != 0) {
        fd_flags |= fd_mod.O_NONBLOCK;
    }

    fd.* = fd_mod.FileDescriptor{
        .ops = &eventfd_file_ops,
        .flags = fd_flags,
        .private_data = state,
        .position = 0,
        .refcount = .{ .raw = 1 },
        .lock = .{},
        .cloexec = (flags & uapi.io.EFD_CLOEXEC) != 0,
    };

    const table = base.getGlobalFdTable();
    const fd_num = table.allocAndInstall(fd) orelse {
        heap.allocator().destroy(fd);
        return error.EMFILE;
    };

    return fd_num;
}

pub fn sys_eventfd(initval: usize) SyscallError!usize {
    return sys_eventfd2(initval, 0);
}
```

**Source:** Pattern from [eventfd(2) man page](https://man7.org/linux/man-pages/man2/eventfd.2.html) and existing epoll_create1 in `src/kernel/sys/syscall/process/scheduling.zig:1031`.

### Example 2: timerfd Integration with Timer Wheel

```zig
// In src/kernel/sys/syscall/io/timerfd.zig

// Timer expiration callback (called by TimerWheel)
fn timerfdExpired(req: *io.IoRequest) void {
    const state: *TimerFdState = @ptrCast(@alignCast(req.user_data));

    const held = state.lock.acquire();
    defer held.release();

    // Increment expiration count
    _ = state.expiry_count.fetchAdd(1, .release);

    // Wake blocked readers
    if (state.blocked_readers) |thread| {
        sched.unblock(thread);
        state.blocked_readers = null;
    }

    // Re-arm if periodic
    if (state.interval_ns > 0 and state.armed) {
        state.next_expiry_ns += state.interval_ns;
        const now_ns = getClockNanoseconds(state.clockid);
        const delta_ns = if (state.next_expiry_ns > now_ns)
            state.next_expiry_ns - now_ns
        else
            0;

        // Re-register with timer wheel
        const ticks = (delta_ns + io.timer.TICK_NS - 1) / io.timer.TICK_NS;
        io.getGlobalTimerWheel().add(req, ticks);
    }
}

pub fn sys_timerfd_settime(
    fd_num: usize,
    flags: usize,
    new_value_ptr: usize,
    old_value_ptr: usize
) SyscallError!usize {
    const table = base.getGlobalFdTable();
    const fd = table.get(@intCast(fd_num)) orelse return error.EBADF;

    const state: *TimerFdState = @ptrCast(@alignCast(fd.private_data));

    const new_spec = base.UserPtr.from(new_value_ptr).readValue(uapi.io.ITimerSpec) catch {
        return error.EFAULT;
    };

    const held = state.lock.acquire();
    defer held.release();

    // Save old value if requested
    if (old_value_ptr != 0) {
        const old_spec = state.toITimerSpec();
        base.UserPtr.from(old_value_ptr).writeValue(old_spec) catch {
            return error.EFAULT;
        };
    }

    // Cancel existing timer
    if (state.timer_request) |req| {
        io.getGlobalTimerWheel().cancel(req);
        state.timer_request = null;
    }

    // Disarm if it_value is zero
    if (new_spec.it_value.tv_sec == 0 and new_spec.it_value.tv_nsec == 0) {
        state.armed = false;
        return 0;
    }

    // Calculate expiration
    const value_ns = timespecToNanoseconds(new_spec.it_value);
    const interval_ns = timespecToNanoseconds(new_spec.it_interval);
    const now_ns = getClockNanoseconds(state.clockid);

    if ((flags & uapi.io.TFD_TIMER_ABSTIME) != 0) {
        state.next_expiry_ns = value_ns;
    } else {
        state.next_expiry_ns = now_ns + value_ns;
    }

    state.interval_ns = interval_ns;
    state.armed = true;

    // Create timer request
    const req = heap.allocator().create(io.IoRequest) catch {
        return error.ENOMEM;
    };
    req.* = io.IoRequest{
        .op = .timer,
        .user_data = state,
        .callback = timerfdExpired,
        // ... other fields
    };

    // Add to timer wheel
    const delta_ns = if (state.next_expiry_ns > now_ns)
        state.next_expiry_ns - now_ns
    else
        0;
    const ticks = (delta_ns + io.timer.TICK_NS - 1) / io.timer.TICK_NS;

    io.getGlobalTimerWheel().add(req, ticks);
    state.timer_request = req;

    return 0;
}
```

**Source:** Pattern from [timerfd_create(2) man page](https://man7.org/linux/man-pages/man2/timerfd_create.2.html) and [Linux kernel hrtimer documentation](https://lwn.net/Articles/167897/).

### Example 3: signalfd Read with Signal Consumption

```zig
// In src/kernel/sys/syscall/io/signalfd.zig

fn signalfdRead(fd: *fd_mod.FileDescriptor, buf: []u8) isize {
    if (buf.len < @sizeOf(uapi.io.SignalFdSigInfo)) {
        return -@as(isize, @intCast(@intFromEnum(Errno.EINVAL)));
    }

    const state: *SignalFdState = @ptrCast(@alignCast(fd.private_data));
    const current = sched.getCurrentThread() orelse {
        return -@as(isize, @intCast(@intFromEnum(Errno.EINVAL)));
    };

    const held = state.lock.acquire();
    defer held.release();

    // Check for pending signals in our mask
    const pending = current.pending_signals & state.sigmask;

    if (pending == 0) {
        if ((fd.flags & fd_mod.O_NONBLOCK) != 0) {
            return -@as(isize, @intCast(@intFromEnum(Errno.EAGAIN)));
        }
        // Block until signal arrives (simplified - full implementation needs wakeup integration)
        return -@as(isize, @intCast(@intFromEnum(Errno.EINTR)));
    }

    // Find first pending signal
    const sig_bit = @ctz(pending);
    const signum = sig_bit + 1;

    // CRITICAL: Clear pending bit atomically to consume signal
    current.pending_signals &= ~(@as(u64, 1) << @truncate(sig_bit));

    // Build SignalFdSigInfo
    var info: uapi.io.SignalFdSigInfo = std.mem.zeroes(uapi.io.SignalFdSigInfo);
    info.ssi_signo = @intCast(signum);
    info.ssi_code = 0;  // TODO: Get from signal queue metadata
    info.ssi_pid = 0;   // TODO: Get sender PID
    info.ssi_uid = 0;   // TODO: Get sender UID

    // Copy to userspace
    @memcpy(buf[0..@sizeOf(uapi.io.SignalFdSigInfo)], std.mem.asBytes(&info));
    return @intCast(@sizeOf(uapi.io.SignalFdSigInfo));
}

pub fn sys_signalfd4(fd_num: isize, mask_ptr: usize, flags: usize) SyscallError!usize {
    const mask = base.UserPtr.from(mask_ptr).readValue(u64) catch {
        return error.EFAULT;
    };

    // Filter out SIGKILL and SIGSTOP (cannot be caught)
    const filtered_mask = mask & ~(@as(u64, 1) << (uapi.signal.SIGKILL - 1))
                                & ~(@as(u64, 1) << (uapi.signal.SIGSTOP - 1));

    if (fd_num != -1) {
        // Update existing signalfd
        const table = base.getGlobalFdTable();
        const fd = table.get(@intCast(fd_num)) orelse return error.EBADF;

        const state: *SignalFdState = @ptrCast(@alignCast(fd.private_data));
        const held = state.lock.acquire();
        defer held.release();

        state.sigmask = filtered_mask;
        return @intCast(fd_num);
    }

    // Create new signalfd
    const state = heap.allocator().create(SignalFdState) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(state);

    state.* = SignalFdState.init(filtered_mask);

    const fd = heap.allocator().create(fd_mod.FileDescriptor) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(fd);

    var fd_flags: u32 = fd_mod.O_RDONLY;
    if ((flags & uapi.io.SFD_NONBLOCK) != 0) {
        fd_flags |= fd_mod.O_NONBLOCK;
    }

    fd.* = fd_mod.FileDescriptor{
        .ops = &signalfd_file_ops,
        .flags = fd_flags,
        .private_data = state,
        .position = 0,
        .refcount = .{ .raw = 1 },
        .lock = .{},
        .cloexec = (flags & uapi.io.SFD_CLOEXEC) != 0,
    };

    const table = base.getGlobalFdTable();
    const fd_num_new = table.allocAndInstall(fd) orelse {
        heap.allocator().destroy(fd);
        return error.EMFILE;
    };

    return fd_num_new;
}
```

**Source:** Pattern from [signalfd(2) man page](https://man7.org/linux/man-pages/man2/signalfd.2.html) and [signalfd implementation details](https://unixism.net/2021/02/making-signals-less-painful-under-linux/).

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| signal() handlers with global state | signalfd for event-driven signal handling | Linux 2.6.22 (2007) | Enables multiplexing signals with I/O, safer in multithreaded programs |
| setitimer() with SIGALRM | timerfd for pollable timers | Linux 2.6.25 (2008) | Allows multiple independent timers, integrates with epoll, nanosecond precision |
| pipe()/socketpair() for thread notification | eventfd for lightweight event signaling | Linux 2.6.22 (2007) | Uses 8 bytes instead of 4KB pipe buffer, faster, simpler semantics |
| eventfd (no flags) | eventfd2 with EFD_SEMAPHORE | Linux 2.6.30 (2009) | Semaphore mode enables decrement-by-1 reads, better for concurrent waiters |
| timerfd_create + timerfd_settime | Single call patterns | Linux 2.6.25 (2008) | Separation allows querying timer state, updating intervals, atomic re-arm |

**Deprecated/outdated:**
- **eventfd(initval)** (syscall 284): Replaced by eventfd2(initval, flags) which adds O_CLOEXEC, O_NONBLOCK, EFD_SEMAPHORE support. Modern code uses eventfd2.
- **signalfd(fd, mask, masksize)** (syscall 282): Replaced by signalfd4(fd, mask, flags) which adds SFD_CLOEXEC and SFD_NONBLOCK. Modern code uses signalfd4.
- **Polling eventfd via select/poll**: Applications should use epoll with EPOLLET for event FDs to avoid thundering herd with multiple waiters.

## Open Questions

1. **Timer Wheel Integration Strategy**
   - What we know: TimerWheel exists with O(1) insertion, 1ms tick granularity
   - What's unclear: Should timerfd use TimerWheel directly or create separate hrtimer-like infrastructure?
   - Recommendation: Use existing TimerWheel for MVP. 1ms granularity sufficient for most use cases. Kernel already has 10ms scheduler tick, sub-millisecond timers would require TSC/HPET integration (future work).

2. **signalfd Metadata Population**
   - What we know: SignalFdSigInfo has 20+ fields (pid, uid, code, etc.)
   - What's unclear: Current signal delivery only tracks pending_signals bitmask, not metadata per signal
   - Recommendation: For MVP, populate only ssi_signo. Full metadata requires signal queue infrastructure (Phase 5+). Applications rarely use metadata for basic signals.

3. **Multiple signalfd Instances for Same Signal**
   - What we know: Linux allows multiple signalfd FDs with overlapping masks
   - What's unclear: How should signal delivery choose which signalfd gets the signal?
   - Recommendation: First-come-first-served. Signal is consumed by first read() on any signalfd with that signal in mask. Matches Linux behavior (signals are process-wide, not per-FD).

4. **timerfd Clock Change Handling**
   - What we know: TFD_TIMER_CANCEL_ON_SET flag exists for CLOCK_REALTIME
   - What's unclear: Kernel doesn't track clock changes (no NTP, manual settimeofday)
   - Recommendation: Ignore TFD_TIMER_CANCEL_ON_SET for MVP. Accept flag but treat as no-op. Real implementation requires clock change notification infrastructure.

5. **eventfd in Non-Blocking Mode at Counter Limits**
   - What we know: Read blocks when counter=0, write blocks when counter would exceed MAX
   - What's unclear: Should poll return EPOLLOUT when counter is exactly MAX? (can't write even 1)
   - Recommendation: poll returns EPOLLOUT only when counter < MAX (at least 1 can be written). Matches Linux: poll checks "can write without blocking", and writing 1 to MAX counter would block.

## Sources

### Primary (HIGH confidence)

- **Linux man pages (official)**
  - [eventfd(2) - create a file descriptor for event notification](https://man7.org/linux/man-pages/man2/eventfd.2.html)
  - [timerfd_create(2) - timers that notify via file descriptors](https://man7.org/linux/man-pages/man2/timerfd_create.2.html)
  - [signalfd(2) - create a file descriptor for accepting signals](https://man7.org/linux/man-pages/man2/signalfd.2.html)

- **Existing zk kernel implementation**
  - `src/kernel/io/timer.zig` - TimerWheel for timeout management
  - `src/kernel/proc/signal.zig` - Signal delivery and pending_signals tracking
  - `src/kernel/proc/thread.zig` - Thread structure with signal state
  - `src/kernel/fs/pipe.zig` - Blocking I/O pattern with blocked_readers/writers
  - `src/kernel/sys/syscall/process/scheduling.zig` - epoll_create1 pattern for FD allocation
  - `src/uapi/syscalls/linux.zig` - Syscall numbers already defined

### Secondary (MEDIUM confidence)

- [eventfd semaphore-like behavior [LWN.net]](https://lwn.net/Articles/318151/) - EFD_SEMAPHORE semantics and use cases
- [The high-resolution timer API [LWN.net]](https://lwn.net/Articles/167897/) - hrtimer implementation patterns
- [Linux kernel timerfd.c](https://github.com/torvalds/linux/blob/master/fs/timerfd.c) - Reference implementation
- [Using signalfd and pidfd to make signals less painful under Linux](https://unixism.net/2021/02/making-signals-less-painful-under-linux/) - signalfd usage patterns and gotchas

### Tertiary (LOW confidence)

- [Use of new Linux APIs signalfd, timerfd, and eventfd](https://topic.alibabacloud.com/a/use-of-new-linux-apis-signalfd-timerfd-and-eventfd_1_16_32447622.html) - Blog post overview
- Community discussions on event FD performance characteristics

## Metadata

**Confidence breakdown:**
- eventfd specification: HIGH - man pages explicit, implementation pattern straightforward (counter + poll)
- timerfd specification: HIGH - man pages detailed, existing TimerWheel provides infrastructure
- signalfd specification: MEDIUM - man pages clear but metadata population requires signal queue enhancement
- Integration with epoll: HIGH - Phase 3 completed FileOps.poll infrastructure, pattern proven with pipes
- Timer wheel integration: MEDIUM - TimerWheel exists but timerfd callback pattern needs validation
- Signal consumption atomicity: HIGH - existing pending_signals bitmask supports atomic clear

**Research date:** 2026-02-07
**Valid until:** 60 days (stable APIs - event FDs unchanged since Linux 2.6.30)
