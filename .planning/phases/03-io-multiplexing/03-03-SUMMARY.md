---
phase: 03-io-multiplexing
plan: 03
subsystem: io-multiplexing
tags: [syscalls, select, pselect6, poll, ppoll, epoll, io-multiplexing, userspace-api]

requires:
  - 03-01-SUMMARY.md # FileOps.poll methods for all FD types
  - 03-02-SUMMARY.md # epoll_wait with blocking and edge-triggered

provides:
  - pselect6 syscall with signal mask atomicity
  - select/ppoll upgraded to use FileOps.poll for all FD types
  - sys_poll uses FileOps.poll uniformly (no socket special-casing)
  - userspace wrappers for epoll and select
  - complete I/O multiplexing surface area

affects:
  - future-testing # Test suite can now use epoll/select/pselect6 wrappers
  - future-networking # poll/select work uniformly across all fd types

tech-stack:
  added: []
  patterns:
    - "Signal mask atomicity in pselect6/ppoll"
    - "Shared selectInternal helper for select/pselect6"
    - "Uniform FileOps.poll dispatch in poll/ppoll"
    - "Userspace wrapper layer for I/O multiplexing"

key-files:
  created: []
  modified:
    - src/uapi/syscalls/linux.zig # Added SYS_PSELECT6 (270)
    - src/uapi/syscalls/linux_aarch64.zig # Added SYS_PSELECT6 (72)
    - src/uapi/syscalls/root.zig # Re-exported SYS_PSELECT6
    - src/uapi/root.zig # Re-exported SYS_PSELECT6
    - src/kernel/sys/syscall/process/scheduling.zig # sys_pselect6, selectInternal, upgraded sys_ppoll
    - src/kernel/sys/syscall/net/poll.zig # Upgraded sys_poll to use FileOps.poll
    - src/user/lib/syscall/io.zig # Added epoll_* and select wrappers

decisions:
  - title: "pselect6 signature matches Linux ABI"
    rationale: "Uses struct { sigset_t *ss; size_t ss_len; } for 6th argument, not direct sigset pointer"
    impact: "Userspace code must follow Linux convention for pselect6 signal mask passing"

  - title: "sys_ppoll upgraded from stub to full implementation"
    rationale: "Phase 3 plan called for ppoll to actually monitor fds, not just timeout"
    impact: "ppoll now works like poll but with timespec timeout and signal mask"

  - title: "sys_poll uses FileOps.poll uniformly"
    rationale: "All fd types now have .poll methods (from Plan 03-01), no need for socket special-casing"
    impact: "Simpler code, uniform behavior across pipes/files/devices/sockets"

  - title: "Blocking registration kept socket-specific in sys_poll"
    rationale: "Old blocking mechanism (sock.blocked_thread) still exists for sys_poll backward compat"
    impact: "Will be replaced with futex-based wakeup in future refactor"

metrics:
  tests-passing: 166
  tests-total: 186
  duration: 6
  completed: 2026-02-07
---

# Phase 03 Plan 03: select/pselect6/poll/ppoll Upgrade Summary

Complete I/O multiplexing surface area: pselect6 syscall, select/poll/ppoll upgraded to use FileOps.poll uniformly, and userspace wrappers added for epoll and select.

## One-liner

pselect6 syscall with signal mask atomicity, select/poll/ppoll upgraded to use FileOps.poll for all fd types, userspace epoll/select wrappers added

## What Was Built

### Syscall Implementations

**sys_pselect6 (270 x86_64, 72 aarch64):**
- Nanosecond-resolution timeout (struct timespec vs select's timeval)
- Atomic signal mask swap: reads sigmask_arg struct { sigset_t *ss; size_t ss_len; }
- Validates ss_len == 8 (size of u64 sigset)
- Applies mask with defer restoration
- Delegates to shared selectInternal helper

**sys_select (refactored):**
- Extracts timeout parsing (timeval to microseconds)
- Calls selectInternal for poll loop
- Preserves existing behavior, cleaner code

**selectInternal (shared helper):**
- Takes timeout_us: ?u64 (null = infinite, 0 = immediate, >0 = timeout)
- Polls FD sets via FileOps.poll for all fd types
- Blocks with scheduler yield until ready or timeout
- Returns ready count

**sys_ppoll (upgraded from stub):**
- Applies signal mask atomically (like pselect6)
- Copies pollfd array to kernel memory (TOCTOU protection)
- Poll loop:
  - For each fd: call fd.ops.poll if available
  - Fallback to isReadable/isWritable for fds without poll
  - Truncate u32 revents to i16 for PollFd.revents
- Blocks with scheduler yield until ready or timeout
- Returns ready count

**sys_poll (upgraded):**
- Removed hardcoded stdin/stdout/stderr special cases (console now has devfsPoll)
- Replaced socket-specific checkPollEvents with fd.ops.poll dispatch
- Universal logic: fd_table.get -> fd.ops.poll -> truncate to i16
- Kept old blocking registration (sock.blocked_thread) for backward compat
- Both check loops (initial and re-check) use same FileOps.poll pattern

### Userspace Wrappers

**Epoll API:**
- epoll_create1(flags) -> i32
- epoll_ctl(epfd, op, fd, event) -> usize
- epoll_wait(epfd, events, maxevents, timeout) -> usize
- Constants: EPOLL_CTL_ADD/DEL/MOD, EPOLLIN/OUT/ERR/HUP/ET/ONESHOT

**Select API:**
- select(nfds, readfds, writefds, exceptfds, timeout) -> usize

### Architecture Support

Both x86_64 and aarch64:
- SYS_PSELECT6 numbers verified unique (270 and 72)
- All syscalls compile and link correctly
- Existing test suite passes (166/186 tests, 20 skipped)

## How It Works

### Signal Mask Atomicity

**Problem:** Race between sigprocmask() and poll syscall:
```c
sigprocmask(SIG_SETMASK, &new_mask, &old_mask); // Window for signals here!
poll(fds, nfds, timeout);
sigprocmask(SIG_SETMASK, &old_mask, NULL);
```

**Solution:** pselect6/ppoll atomically swap mask:
```zig
old_mask = thread.sigmask;
thread.sigmask = new_mask;
defer thread.sigmask = old_mask; // Restored even on error
// ... poll loop ...
```

### Timeout Handling

**select:** struct timeval (seconds, microseconds)
**pselect6/ppoll:** struct timespec (seconds, nanoseconds)
**Internal:** Convert to microseconds, pass to selectInternal/poll loop
**Scheduler:** hal.timing.rdtsc() for precise timeout checks, sched.yield() for blocking

### FileOps.poll Dispatch

All I/O multiplexing syscalls now use the same pattern:
```zig
if (fd.ops.poll) |poll_fn| {
    revents = poll_fn(fd, events);
} else {
    // Fallback for legacy fds without poll
    if (fd.isReadable()) revents |= POLLIN;
    if (fd.isWritable()) revents |= POLLOUT;
}
```

No special-casing for sockets, pipes, devices - uniform behavior.

## Deviations from Plan

None - plan executed exactly as written.

## Testing & Verification

**Build verification:**
- x86_64: Compiled successfully
- aarch64: Compiled successfully

**Test suite:**
- Existing tests pass: 166/186 (20 skipped)
- No regressions introduced
- Existing poll/select tests continue to work

**Code verification:**
- SYS_PSELECT6 numbers unique (grep verified no collisions)
- sys_pselect6 function exists
- selectInternal shared by select and pselect6
- sys_ppoll uses FileOps.poll (not a stub anymore)
- sys_poll uses fd.ops.poll (no checkPollEvents in poll loops)
- Userspace wrappers accessible from io.zig

## Next Phase Readiness

**Ready for:** Testing phase that exercises I/O multiplexing APIs
**Blockers:** None
**Concerns:** Old blocking mechanism (sock.blocked_thread) in sys_poll should be replaced with futex-based wakeup in future refactor

## Dependencies

**Built on:**
- Plan 03-01: FileOps.poll methods for all FD types
- Plan 03-02: epoll_wait with blocking, edge-triggered, EPOLLONESHOT

**Enables:**
- Test suite can use epoll/select/pselect6 wrappers
- Applications can use any I/O multiplexing API uniformly

## Task Commits

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add pselect6 syscall and upgrade select/ppoll | c741ac8 | linux.zig, linux_aarch64.zig, root.zig (2x), scheduling.zig |
| 2 | Upgrade sys_poll and add userspace wrappers | 4c035af | poll.zig, io.zig |

## Implementation Notes

### Signal Mask Handling

**pselect6 6th argument:** Linux uses `struct { sigset_t *ss; size_t ss_len; }`, NOT direct sigset pointer
**Validation:** ss_len must be 8 (sizeof(u64))
**Application pattern:** Temporary mask during I/O wait, restored on return

### Timeout Resolution

**select:** microsecond (10^-6)
**pselect6/ppoll:** nanosecond (10^-9)
**Internal:** microsecond granularity (hal.timing.rdtsc checks)
**Conversion:** pselect6/ppoll convert timespec ns to us

### PollFd.revents Truncation

**FileOps.poll returns:** u32 (can include high-bit flags like EPOLLET)
**PollFd.revents type:** i16 (Linux ABI)
**Conversion:** `@bitCast(@as(u16, @truncate(revents)))` loses high bits
**Impact:** poll/ppoll cannot express edge-triggered mode (use epoll for that)

### Blocking Mechanism

**Current:** sys_poll uses old sock.blocked_thread registration
**Future:** Replace with futex-based wakeup matching epoll_wait pattern
**Reason for keeping:** Backward compat, avoids breaking existing socket code

## Self-Check: PASSED

All created files exist.
All commits exist in git log.
