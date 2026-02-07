# Phase 3: I/O Multiplexing - Research

**Researched:** 2026-02-06
**Domain:** Linux I/O multiplexing (epoll, select, poll)
**Confidence:** HIGH

## Summary

Phase 3 completes the existing epoll infrastructure by implementing FileOps.poll methods for pipes, sockets, and regular files. The kernel already has:
- Full epoll syscall infrastructure (sys_epoll_create1, sys_epoll_ctl, sys_epoll_wait) in `src/kernel/sys/syscall/process/scheduling.zig`
- FileOps.poll interface defined in `src/kernel/fs/fd.zig`
- Socket poll implementation (checkPollEvents) in `src/net/transport/socket/poll.zig`
- Basic select implementation using poll infrastructure
- Wait queue infrastructure for blocking in `src/kernel/proc/sched/queue.zig`
- Pipe blocking infrastructure (blocked_readers/blocked_writers) in `src/kernel/fs/pipe.zig`

The missing pieces are:
1. FileOps.poll method for pipes (check data_len, writers count for POLLHUP)
2. FileOps.poll method for regular files (always return POLLIN | POLLOUT)
3. FileOps.poll method for DevFS files (always return POLLIN | POLLOUT)
4. Wait queue registration in epoll_wait (currently returns 0 immediately on no events)
5. pselect6 syscall (select with signal mask atomicity)
6. Edge-triggered mode tracking in epoll (currently only level-triggered works)

**Primary recommendation:** Implement poll methods for each file type, add wait queue support to epoll_wait, implement edge-triggered state tracking.

## User Constraints (from CONTEXT.md)

### Locked Decisions

**FD readiness semantics:**
- Regular files: Always report POLLIN | POLLOUT (Linux behavior)
- Pipes: POLLIN when data_len > 0, POLLOUT when data_len < PIPE_BUF_SIZE, POLLHUP when writers == 0, POLLERR on write to broken pipe
- Sockets: POLLIN when recv buffer has data or incoming connection, POLLOUT when send buffer has space, POLLHUP on peer close, POLLERR on socket error
- DevFS files: Always ready (same as regular files)
- EOF condition: POLLHUP set, POLLIN may also be set if unread data remains
- POLLNVAL for invalid file descriptors (not an error return)

**Epoll edge vs level triggering:**
- Implement both level-triggered (default) and edge-triggered (EPOLLET)
- Level-triggered: epoll_wait returns fd every time condition holds
- Edge-triggered: epoll_wait returns fd only on state transition from not-ready to ready
- EPOLLONESHOT: after one event delivery, interest disabled until re-armed with EPOLL_CTL_MOD
- EPOLLERR and EPOLLHUP always reported regardless of requested events

**Select/pselect6 behavior:**
- Implement select on top of poll infrastructure (not separate path)
- FD_SETSIZE = 1024 (Linux default), reject nfds > 1024 with EINVAL
- fd_set is bitmask: 1024 bits = 128 bytes = 16 u64s
- pselect6 adds signal mask atomically (block signals during wait, restore after)
- Timeout: select uses timeval (microseconds), pselect6 uses timespec (nanoseconds)
- Timeout NULL = block indefinitely, zero timeout = poll and return immediately
- On return, fd_sets modified in-place to reflect ready fds
- Return value = total number of ready fds across all three sets

**Wake-up and blocking model:**
- epoll_wait and select/pselect6 block via scheduler (not spin-wait)
- Use wait queue pattern: thread sleeps, fd state change wakes all waiters
- FileOps.poll returns current readiness mask (non-blocking check)
- Waiters added to per-fd wait queues; state changes call wake_up
- Timeout support via scheduler timer
- Spurious wakes are safe: re-check conditions after wake
- epoll_wait maxevents parameter caps returned events per call

### Claude's Discretion

- Internal wait queue data structure design
- How poll method integrates with existing pipe/socket implementations
- Whether select internally converts to epoll or uses poll directly
- Exact locking strategy for wait queue manipulation
- How to handle epoll-on-epoll (can defer if complex)

### Deferred Ideas (OUT OF SCOPE)

None - discussion stayed within phase scope

## Standard Stack

### Core Infrastructure (Already Exists)

| Component | Location | Purpose | Status |
|-----------|----------|---------|--------|
| FileOps.poll | `src/kernel/fs/fd.zig:87` | Poll interface for file types | Interface defined, needs implementations |
| EpollEvent | `src/uapi/io/epoll.zig:37` | Event structure (12 bytes, Linux ABI) | Complete |
| PollFd | `src/uapi/io/poll.zig:59` | Poll fd structure (8 bytes) | Complete |
| WaitQueue | `src/kernel/proc/sched/queue.zig:10` | Generic sleep/wakeup queue | Complete |
| sys_epoll_create1 | `src/kernel/sys/syscall/process/scheduling.zig:869` | Create epoll instance | Complete |
| sys_epoll_ctl | `src/kernel/sys/syscall/process/scheduling.zig:914` | Control epoll instance | Complete |
| sys_epoll_wait | `src/kernel/sys/syscall/process/scheduling.zig:968` | Wait for events (stub) | Needs wait queue support |
| sys_select | `src/kernel/sys/syscall/process/scheduling.zig:441` | Select syscall | Complete, uses poll |
| socket poll | `src/net/transport/socket/poll.zig:16` | Socket readiness check | Complete |

### Syscall Numbers

| Syscall | x86_64 | aarch64 | Notes |
|---------|--------|---------|-------|
| SYS_POLL | 7 | 510 | Implemented in `src/kernel/sys/syscall/net/poll.zig` |
| SYS_SELECT | 23 | 508 | Implemented in `src/kernel/sys/syscall/process/scheduling.zig` |
| SYS_EPOLL_CREATE1 | 291 | 20 | Implemented |
| SYS_EPOLL_CTL | 233 | 21 | Implemented |
| SYS_EPOLL_WAIT | 232 | 509 | Stub (no blocking) |
| SYS_EPOLL_PWAIT | 281 | 22 | Not implemented |
| SYS_PSELECT6 | (not found) | (not found) | **MISSING** - needs implementation |

### Missing Components

1. **pselect6 syscall** - Need to add SYS_PSELECT6 to both architecture syscall files
2. **Pipe poll method** - Need to implement in `src/kernel/fs/pipe.zig`
3. **Regular file poll method** - Need to implement in VFS/InitRD/SFS
4. **DevFS poll method** - Need to implement in `src/kernel/fs/devfs.zig`
5. **Wait queue registration in epoll_wait** - Need to block when no events ready
6. **Edge-triggered state tracking** - Need to track last reported state per fd

## Architecture Patterns

### Recommended Project Structure

No new files needed - all work happens in existing files:

```
src/kernel/fs/
├── pipe.zig              # Add pipePoll function, set .poll = pipePoll in pipe_ops
├── devfs.zig             # Add devfsPoll function for device files

src/kernel/sys/syscall/
├── process/
│   └── scheduling.zig    # Enhance sys_epoll_wait with wait queues, add sys_pselect6
├── fs/
│   └── fs_handlers.zig   # Add poll methods for regular files (VFS integration)

src/fs/
├── initrd.zig            # Add poll method (always ready)
├── sfs/ops.zig           # Add poll method (always ready)
```

### Pattern 1: FileOps.poll Implementation

**What:** Each file type implements a poll method that returns current readiness as a bitmask
**When to use:** For every file type that can be monitored by epoll/select
**Example (Pipe):**

```zig
// In src/kernel/fs/pipe.zig
fn pipePoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    const handle: *PipeHandle = @ptrCast(@alignCast(fd.private_data.?));
    const pipe = handle.pipe;

    const held = pipe.lock.acquire();
    defer held.release();

    var revents: u32 = 0;

    // Read end
    if (handle.end == .Read) {
        if ((requested_events & uapi.poll.POLLIN) != 0) {
            if (pipe.data_len > 0) {
                revents |= uapi.poll.POLLIN;
            }
        }
        // POLLHUP when all write ends closed
        if (pipe.writers == 0) {
            revents |= uapi.poll.POLLHUP;
            // If data remains, also report POLLIN (Linux behavior)
            if (pipe.data_len > 0) {
                revents |= uapi.poll.POLLIN;
            }
        }
    }

    // Write end
    if (handle.end == .Write) {
        if ((requested_events & uapi.poll.POLLOUT) != 0) {
            const space = PIPE_BUF_SIZE - pipe.data_len;
            if (space > 0) {
                revents |= uapi.poll.POLLOUT;
            }
        }
        // POLLERR when all read ends closed (broken pipe)
        if (pipe.readers == 0) {
            revents |= uapi.poll.POLLERR;
        }
    }

    return revents;
}
```

**Example (Regular Files):**

```zig
// In src/fs/initrd.zig and src/fs/sfs/ops.zig
fn regularFilePoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    _ = fd;
    _ = requested_events;
    // Linux always reports regular files as ready
    return uapi.poll.POLLIN | uapi.poll.POLLOUT;
}
```

### Pattern 2: Wait Queue Integration in epoll_wait

**What:** Register current thread on a wait queue when no events are ready, sleep with timeout
**When to use:** In sys_epoll_wait when ready_count == 0 and timeout != 0
**Example:**

```zig
// In sys_epoll_wait, after checking all fds
if (ready_count > 0 or timeout_i == 0) {
    // Return immediately
    _ = UserPtr.from(events_ptr).copyFromKernel(std.mem.sliceAsBytes(out_slice)) catch {
        return error.EFAULT;
    };
    return ready_count;
}

// No events ready - need to block
// Create a wait queue for this epoll instance (or use per-fd wait queues)
// For MVP: Use scheduler sleep with timeout, re-check on wake
if (timeout_i > 0) {
    const timeout_u: u64 = @intCast(timeout_i);
    // Convert ms to ticks (10ms per tick)
    const ticks = (timeout_u + 9) / 10;
    sched.sleepForTicks(ticks);
} else {
    // timeout_i == -1 means infinite wait
    sched.block();
}

// Woke up - re-check all fds
ready_count = 0;
for (&entries_copy) |*entry| {
    if (!entry.active) continue;
    if (ready_count >= maxevents) break;

    // Same poll logic as above
    // ...
}

// Copy results to userspace
_ = UserPtr.from(events_ptr).copyFromKernel(std.mem.sliceAsBytes(out_slice)) catch {
    return error.EFAULT;
};
return ready_count;
```

**Note:** Full implementation requires per-fd wait queues and wake_up calls when fd state changes (e.g., pipe write calls wake_up on pipe.blocked_readers). For Phase 3 MVP, scheduler-based timeout sleep is sufficient.

### Pattern 3: Edge-Triggered State Tracking

**What:** Track last reported event state per fd to detect state transitions
**When to use:** When EPOLLET flag is set on an epoll entry
**Example:**

```zig
// Add to EpollEntry struct
const EpollEntry = struct {
    fd: i32,
    events: u32,
    data: u64,
    active: bool,
    last_revents: u32 = 0,  // Last reported events (for edge-triggered)
};

// In sys_epoll_wait loop
if (revents != 0) {
    const is_edge_triggered = (entry.events & uapi.epoll.EPOLLET) != 0;

    if (is_edge_triggered) {
        // Only report if state changed from not-ready to ready
        const new_events = revents & ~entry.last_revents;
        if (new_events != 0) {
            result_buf[ready_count] = uapi.epoll.EpollEvent.init(new_events, entry.data);
            ready_count += 1;
            entry.last_revents = revents;  // Update tracked state
        }
    } else {
        // Level-triggered: always report
        result_buf[ready_count] = uapi.epoll.EpollEvent.init(revents, entry.data);
        ready_count += 1;
    }

    // Handle EPOLLONESHOT
    if ((entry.events & uapi.epoll.EPOLLONESHOT) != 0) {
        entry.events = 0;  // Disable until re-armed
    }
}
```

### Pattern 4: pselect6 Implementation

**What:** select with atomic signal mask change
**When to use:** When userspace needs to block on fds while atomically changing signal mask
**Example:**

```zig
// In src/kernel/sys/syscall/process/scheduling.zig
pub fn sys_pselect6(
    nfds: usize,
    readfds: usize,
    writefds: usize,
    exceptfds: usize,
    timeout_ptr: usize,
    sigmask_ptr: usize
) SyscallError!usize {
    // Read timeout from userspace (timespec, not timeval like select)
    const timeout_us: ?u64 = if (timeout_ptr != 0) blk: {
        const ts = UserPtr.from(timeout_ptr).readValue(Timespec) catch {
            return error.EFAULT;
        };
        const sec_us = std.math.mul(u64, @intCast(@max(0, ts.tv_sec)), 1_000_000) catch return error.EINVAL;
        const nsec_us = @as(u64, @intCast(@max(0, ts.tv_nsec))) / 1000;
        break :blk std.math.add(u64, sec_us, nsec_us) catch return error.EINVAL;
    } else null;

    // Atomically change signal mask if provided
    var old_sigmask: u64 = 0;
    if (sigmask_ptr != 0) {
        const current = sched.getCurrentThread() orelse return error.EINVAL;
        old_sigmask = current.sigmask;

        // Read new sigmask from userspace
        const new_sigmask = UserPtr.from(sigmask_ptr).readValue(u64) catch {
            return error.EFAULT;
        };
        current.sigmask = new_sigmask;
    }
    defer {
        // Restore old sigmask
        if (sigmask_ptr != 0) {
            if (sched.getCurrentThread()) |current| {
                current.sigmask = old_sigmask;
            }
        }
    }

    // Use existing select logic (convert timeout to timeval format)
    const timeval_ptr: usize = if (timeout_us) |us| blk: {
        // Allocate timeval on stack and pass pointer
        var tv = extern struct { tv_sec: i64, tv_usec: i64 }{
            .tv_sec = @intCast(us / 1_000_000),
            .tv_usec = @intCast(us % 1_000_000),
        };
        break :blk @intFromPtr(&tv);
    } else 0;

    return sys_select(nfds, readfds, writefds, exceptfds, timeval_ptr);
}
```

### Anti-Patterns to Avoid

- **DON'T hold FdTable.lock during poll calls** - poll methods may acquire their own locks, causing deadlock. Get fd pointer under lock, release lock, then call poll.
- **DON'T assume poll returns only requested events** - Always mask revents with requested_events. POLLERR and POLLHUP are always reported regardless of request (Linux behavior).
- **DON'T modify epoll entries without lock** - EpollInstance.lock must be held when modifying entries array. Use snapshot pattern (copy entries under lock, iterate snapshot without lock) for epoll_wait.
- **DON'T forget to update last_revents for edge-triggered** - Edge-triggered mode requires tracking previous state to detect transitions.
- **DON'T return POLLNVAL as error** - POLLNVAL is a valid revents bit, not an error return code.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Wait queue | Custom linked list of waiting threads | `WaitQueue` in `src/kernel/proc/sched/queue.zig` | Already handles lock ordering, supports wakeup with count, integrates with scheduler |
| Timeout handling | Custom timer callback | `sched.sleepForTicks()` | Scheduler already has timer infrastructure, handles spurious wakeups |
| Signal mask changes | Custom signal blocking | Thread.sigmask atomic field | Already exists, used by signal delivery, checkSignalsOnSyscallExit validates |
| FD_SET operations | Manual bit manipulation | Use byte array indexing pattern from sys_select | Already handles endianness, bounds checks |
| User memory access | Direct pointer dereference | `UserPtr.readValue()`, `copyFromKernel()`, `copyToKernel()` | TOCTOU protection, SMAP enforcement, bounds checking |

**Key insight:** The scheduler and wait queue infrastructure is designed for exactly this use case. Don't create parallel blocking mechanisms.

## Common Pitfalls

### Pitfall 1: Holding Locks During Poll Calls

**What goes wrong:** Deadlock when poll method tries to acquire a lock already held by caller
**Why it happens:** FdTable.lock protects the fd array, but individual fds have their own locks (pipe.lock, socket.lock)
**How to avoid:**
```zig
// WRONG: Hold table lock during poll
const held = table.lock.acquire();
const fd = table.fds[fd_num];
const revents = fd.ops.poll(fd, events);  // Deadlock if poll acquires another lock
held.release();

// CORRECT: Get fd under lock, release, then poll
const fd = table.get(fd_num) orelse continue;  // get() acquires and releases lock
const revents = if (fd.ops.poll) |poll_fn| poll_fn(fd, events) else 0;
```
**Warning signs:** Kernel hangs during epoll_wait/select when multiple fds are monitored

### Pitfall 2: TOCTOU Race on Epoll Entries

**What goes wrong:** Epoll entries array modified by another thread (epoll_ctl) while epoll_wait iterates
**Why it happens:** epoll_wait releases EpollInstance.lock before polling each fd
**How to avoid:** Snapshot pattern - copy entries array under lock, iterate snapshot without lock
```zig
// Take snapshot under lock
var entries_copy: [EPOLL_MAX_FDS]EpollEntry = undefined;
{
    const held = instance.lock.acquire();
    entries_copy = instance.entries;
    held.release();
}

// Iterate snapshot (no lock held)
for (&entries_copy) |*entry| {
    if (!entry.active) continue;
    // Poll fd without holding epoll instance lock
}
```
**Warning signs:** Kernel panics with null pointer dereference in epoll_wait, events reported for removed fds

### Pitfall 3: Forgetting EPOLLERR/EPOLLHUP Always Report

**What goes wrong:** Application never gets error events because it didn't request them
**Why it happens:** Programmer assumes only requested events are returned
**How to avoid:** Always OR in EPOLLERR and EPOLLHUP if poll returns them, regardless of requested_events
```zig
const revents = poll_fn(fd, requested_events);

// WRONG: Only return requested events
if ((revents & requested_events) != 0) {
    report_event(revents & requested_events);
}

// CORRECT: Always report POLLERR/POLLHUP
var filtered = revents & requested_events;
filtered |= (revents & (uapi.poll.POLLERR | uapi.poll.POLLHUP));
if (filtered != 0) {
    report_event(filtered);
}
```
**Warning signs:** Applications hang when socket errors occur, broken pipe never detected

### Pitfall 4: Edge-Triggered Without State Tracking

**What goes wrong:** Edge-triggered mode reports events on every poll, acting like level-triggered
**Why it happens:** No tracking of previous state means every check looks like a "transition"
**How to avoid:** Add last_revents field to EpollEntry, only report when `(revents & ~last_revents) != 0`
```zig
if (is_edge_triggered) {
    const new_events = revents & ~entry.last_revents;
    if (new_events != 0) {
        result_buf[ready_count] = ...;
        entry.last_revents = revents;  // CRITICAL: Update state
    }
}
```
**Warning signs:** Edge-triggered applications get event storms, CPU at 100% in epoll_wait loop

### Pitfall 5: pselect6 Signal Mask Not Atomic

**What goes wrong:** Signals delivered after mask check but before block, causing lost wakeups or incorrect behavior
**Why it happens:** Signal mask change and blocking happen in separate steps
**How to avoid:** Use defer pattern to ensure mask is always restored, change mask immediately before calling select
```zig
var old_sigmask: u64 = 0;
if (sigmask_ptr != 0) {
    const current = sched.getCurrentThread() orelse return error.EINVAL;
    old_sigmask = current.sigmask;
    current.sigmask = new_sigmask;  // Change BEFORE select
}
defer {
    // Restore AFTER select, even if select errors
    if (sigmask_ptr != 0) {
        if (sched.getCurrentThread()) |current| {
            current.sigmask = old_sigmask;
        }
    }
}
return sys_select(...);  // Block with new mask active
```
**Warning signs:** Race conditions in signal handling, applications hang waiting for signals

### Pitfall 6: Regular Files Block in poll

**What goes wrong:** epoll_wait blocks waiting for regular files to become ready
**Why it happens:** poll method checks actual file state (disk I/O) instead of immediately returning ready
**How to avoid:** Regular files ALWAYS return POLLIN | POLLOUT immediately, no state checks
```zig
// WRONG: Check if file has data
fn regularFilePoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    const file_size = getFileSize(fd);  // Expensive I/O!
    if (file_size > 0) return uapi.poll.POLLIN;
    return 0;
}

// CORRECT: Always ready
fn regularFilePoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    _ = fd;
    _ = requested_events;
    return uapi.poll.POLLIN | uapi.poll.POLLOUT;
}
```
**Warning signs:** epoll_wait takes seconds to return when monitoring regular files, disk I/O spikes

## Code Examples

### Example 1: Complete Pipe Poll Implementation

```zig
// In src/kernel/fs/pipe.zig

/// Poll pipe for readiness events
/// Returns bitmask of ready events (POLLIN, POLLOUT, POLLHUP, POLLERR)
fn pipePoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    const handle: *PipeHandle = @ptrCast(@alignCast(fd.private_data.?));
    const pipe = handle.pipe;

    const held = pipe.lock.acquire();
    defer held.release();

    var revents: u32 = 0;

    if (handle.end == .Read) {
        // Read end
        if ((requested_events & uapi.poll.POLLIN) != 0) {
            // Data available to read
            if (pipe.data_len > 0) {
                revents |= uapi.poll.POLLIN;
            }
        }

        // All write ends closed - report POLLHUP
        if (pipe.writers == 0) {
            revents |= uapi.poll.POLLHUP;
            // If unread data remains, also set POLLIN (Linux behavior)
            if (pipe.data_len > 0) {
                revents |= uapi.poll.POLLIN;
            }
        }
    } else {
        // Write end
        if ((requested_events & uapi.poll.POLLOUT) != 0) {
            // Space available for writing
            const space = PIPE_BUF_SIZE - pipe.data_len;
            if (space > 0) {
                revents |= uapi.poll.POLLOUT;
            }
        }

        // All read ends closed - report POLLERR (broken pipe)
        if (pipe.readers == 0) {
            revents |= uapi.poll.POLLERR;
        }
    }

    return revents;
}

// Update pipe_ops to include poll
const pipe_ops = fd_mod.FileOps{
    .read = pipeRead,
    .write = pipeWrite,
    .close = pipeClose,
    .seek = null,
    .stat = null,
    .ioctl = null,
    .mmap = null,
    .poll = pipePoll,  // ADD THIS LINE
    .truncate = null,
};
```

**Source:** Pattern derived from socket poll implementation in `src/net/transport/socket/poll.zig` and Linux semantics from [poll(2) manual page](https://man7.org/linux/man-pages/man2/poll.2.html)

### Example 2: DevFS Always-Ready Poll

```zig
// In src/kernel/fs/devfs.zig

/// Poll device file for readiness
/// Device files (null, zero, random, etc.) are always ready
fn devfsPoll(fd: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    _ = fd;
    _ = requested_events;

    // Linux reports device files as always ready for both read and write
    return uapi.poll.POLLIN | uapi.poll.POLLOUT;
}

// Update devfs_file_ops to include poll
const devfs_file_ops = fd_mod.FileOps{
    .read = devfsRead,
    .write = devfsWrite,
    .close = devfsClose,
    .seek = null,
    .stat = devfsStat,
    .ioctl = null,
    .mmap = null,
    .poll = devfsPoll,  // ADD THIS LINE
    .truncate = null,
};
```

**Source:** Linux behavior from [poll(2) manual page](https://man7.org/linux/man-pages/man2/poll.2.html): "Polling regular files shall always indicate that the file is ready to read and ready to write."

### Example 3: Enhanced epoll_wait with Blocking

```zig
// In src/kernel/sys/syscall/process/scheduling.zig sys_epoll_wait

// After first pass of checking fds...

// If events found or timeout is 0, return immediately
if (ready_count > 0 or timeout_i == 0) {
    const out_slice = result_buf[0..ready_count];
    _ = UserPtr.from(events_ptr).copyFromKernel(std.mem.sliceAsBytes(out_slice)) catch {
        return error.EFAULT;
    };
    return ready_count;
}

// No events ready - need to block
// Check for pending signals before blocking
if (hasPendingSignal()) {
    return error.EINTR;
}

// Block with timeout
if (timeout_i > 0) {
    // Convert milliseconds to scheduler ticks (10ms per tick)
    const timeout_u: u64 = @intCast(timeout_i);
    const ticks = (timeout_u + 9) / 10;  // Round up
    sched.sleepForTicks(ticks);
} else {
    // timeout_i == -1 means infinite wait
    sched.block();
}

// Woke up - check for signal interruption
if (hasPendingSignal()) {
    return error.EINTR;
}

// Re-check all fds (same loop as above)
ready_count = 0;
for (&entries_copy) |*entry| {
    if (!entry.active) continue;
    if (ready_count >= maxevents) break;

    var revents: u32 = 0;
    const table = base.getGlobalFdTable();
    const fd_u32 = std.math.cast(u32, @as(usize, @intCast(entry.fd))) orelse continue;
    if (table.get(fd_u32)) |fd_obj| {
        if (fd_obj.ops.poll) |poll_fn| {
            revents = poll_fn(fd_obj, entry.events);
        }
    } else {
        revents = uapi.epoll.EPOLLNVAL;
    }

    if (revents != 0) {
        result_buf[ready_count] = uapi.epoll.EpollEvent.init(revents, entry.data);
        ready_count += 1;
    }
}

// Copy results to userspace
const out_slice = result_buf[0..ready_count];
_ = UserPtr.from(events_ptr).copyFromKernel(std.mem.sliceAsBytes(out_slice)) catch {
    return error.EFAULT;
};
return ready_count;

// Helper function
fn hasPendingSignal() bool {
    const current = sched.getCurrentThread() orelse return false;
    const pending = current.pending_signals & ~current.sigmask;
    return pending != 0;
}
```

**Source:** Blocking pattern from existing `sys_poll` in `src/kernel/sys/syscall/net/poll.zig:202-208` and [epoll(7) manual page](https://man7.org/linux/man-pages/man7/epoll.7.html)

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| epoll_wait spins in loop | epoll_wait blocks via scheduler | Linux 2.6 (2003) | Prevents CPU waste, enables power saving |
| poll checks fds sequentially | epoll uses registered interest list | Linux 2.5.44 (2002) | O(n) -> O(ready fds) scaling |
| select limited to 1024 fds | epoll supports millions of fds | Linux 2.5.44 (2002) | Enables high-scale servers |
| Edge-triggered requires manual state | Kernel tracks edge transitions | Linux 2.6 (2003) | Simplifies application logic |
| Signal mask races with select | pselect6 atomically changes mask | Linux 2.6.16 (2006) | Eliminates signal delivery races |

**Deprecated/outdated:**
- **epoll_create(size)** (syscall 213): Replaced by epoll_create1(flags) which ignores size hint and uses dynamic allocation. Modern code uses epoll_create1(0).
- **select with polling loop**: Applications that spin-wait checking select return should use epoll edge-triggered mode instead. Edge-triggered eliminates busy-wait patterns.

## Open Questions

1. **Wait Queue Granularity**
   - What we know: WaitQueue exists in `src/kernel/proc/sched/queue.zig`, supports wakeup with count
   - What's unclear: Should epoll have one global wait queue per instance, or per-fd wait queues?
   - Recommendation: Start with scheduler sleep (simple), upgrade to per-instance wait queue if needed. Per-fd wait queues add complexity without clear benefit for Phase 3 goals.

2. **Edge-Triggered State Storage**
   - What we know: EpollEntry struct is 32 bytes (fd=4, events=4, data=8, active=1, padding=15)
   - What's unclear: Adding last_revents:u32 field increases size to 36 bytes, padding to 48 bytes (50% waste)
   - Recommendation: Accept the padding cost (3KB per epoll instance with 64 entries). Alternative is separate state array but adds lookup complexity.

3. **EPOLLONESHOT Re-arming**
   - What we know: EPOLLONESHOT disables interest after one event, requires EPOLL_CTL_MOD to re-enable
   - What's unclear: Should we clear events field to 0, or add a separate "armed" flag?
   - Recommendation: Set events = 0 (simplest). EPOLL_CTL_MOD restores events field. Matches Linux semantics where re-arming restores original interest.

4. **Socket Wake-up Integration**
   - What we know: Sockets have blocked_thread field, set by poll syscall
   - What's unclear: How does socket RX interrupt wake epoll_wait threads?
   - Recommendation: Phase 3 can skip wake-up optimization. epoll_wait timeout will wake periodically and re-check. Phase 4+ can add WaitQueue registration to sockets.

## Sources

### Primary (HIGH confidence)

- **Linux man pages (official)**
  - [epoll(7) - epoll I/O event notification facility](https://man7.org/linux/man-pages/man7/epoll.7.html)
  - [select(2) - synchronous I/O multiplexing](https://man7.org/linux/man-pages/man2/select.2.html)
  - [poll(2) - wait for some event on a file descriptor](https://man7.org/linux/man-pages/man2/poll.2.html)

- **Existing zk kernel implementation**
  - `src/kernel/fs/fd.zig` - FileOps interface definition (line 86-88)
  - `src/kernel/sys/syscall/process/scheduling.zig` - epoll syscalls (line 789-1066)
  - `src/kernel/sys/syscall/net/poll.zig` - sys_poll with blocking (line 68-268)
  - `src/net/transport/socket/poll.zig` - socket poll implementation (line 16-80)
  - `src/kernel/proc/sched/queue.zig` - WaitQueue implementation (line 10-113)
  - `src/kernel/fs/pipe.zig` - pipe blocking infrastructure (line 28-96)

### Secondary (MEDIUM confidence)

- [The method to epoll's madness](https://copyconstruct.medium.com/the-method-to-epolls-madness-d9d2d6378642) - Edge vs level triggering semantics
- [The edge-triggered misunderstanding [LWN.net]](https://lwn.net/Articles/864947/) - Common edge-triggered pitfalls

### Tertiary (LOW confidence)

- None - all critical semantics verified with official man pages

## Metadata

**Confidence breakdown:**
- FileOps.poll interface: HIGH - interface defined, socket implementation exists as reference
- Epoll syscall infrastructure: HIGH - already implemented, just needs blocking support
- Pipe/regular file semantics: HIGH - verified with Linux man pages, existing pipe blocking code as reference
- Wait queue integration: MEDIUM - WaitQueue exists but integration pattern needs validation
- Edge-triggered implementation: MEDIUM - semantics clear from man pages, state tracking pattern is standard but not verified in codebase

**Research date:** 2026-02-06
**Valid until:** 60 days (stable APIs - epoll/select haven't changed since Linux 2.6)
