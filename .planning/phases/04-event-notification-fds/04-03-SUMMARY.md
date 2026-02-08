---
phase: 04-event-notification-fds
plan: 03
subsystem: io
tags: [signalfd, signal, syscall, epoll]
requires:
  - phase: 04-event-notification-fds/04-01
    provides: "eventfd pattern, UAPI signalfd constants"
provides:
  - "signalfd kernel implementation with signal consumption"
  - "signalfd userspace wrappers"
affects: ["04-04-tests"]
tech-stack:
  added: []
  patterns: ["SignalFdState with signal mask filtering and consumption"]
key-files:
  created:
    - src/kernel/sys/syscall/io/signalfd.zig
  modified:
    - src/kernel/sys/syscall/io/root.zig
    - src/user/lib/syscall/io.zig
key-decisions:
  - "Use yield loop for blocking instead of full signal delivery wakeup integration (MVP pattern)"
  - "Filter SIGKILL and SIGSTOP from mask silently (POSIX requirement)"
  - "Consume signal by clearing pending_signals bit atomically during read"
  - "signalfd4 with fd >= 0 updates existing mask under lock (no new fd created)"
duration: 5min
completed: 2026-02-07
---

# Phase 4 Plan 3: Signalfd Implementation Summary

**signalfd syscalls with signal consumption, mask filtering, and epoll integration**

## Performance

**Execution time:** 5 minutes

**Task breakdown:**
- Task 1: Implement signalfd kernel syscalls (4 minutes)
- Task 2: Add signalfd userspace wrappers (1 minute)

## What Was Built

### Kernel Implementation (signalfd.zig)

**SignalFdState structure:**
- `sigmask: u64` - Bitmask of signals to accept (bit N-1 = signal N)
- `lock: Spinlock` - Protects mask updates
- `blocked_readers: ?*Thread` - Threads waiting for signals (unused in MVP)
- `reader_woken: atomic bool` - SMP wakeup flag (unused in MVP)

**Signal mask filtering:**
- `filterMask()` strips SIGKILL (bit 8) and SIGSTOP (bit 18) from mask
- These signals cannot be caught per POSIX, silently removed
- Applied on both creation and mask updates

**sys_signalfd4 syscall:**
- `fd_num == -1`: Create new signalfd with filtered mask
- `fd_num >= 0`: Update existing signalfd mask (verify ops pointer, lock, update)
- Flags: SFD_CLOEXEC, SFD_NONBLOCK validated
- Returns: fd number (new or existing)

**sys_signalfd syscall:**
- Delegates to sys_signalfd4(fd, mask, size, 0)
- Legacy API without flags parameter

**signalfdRead FileOps:**
- Validates buffer >= 128 bytes (sizeof SignalFdSigInfo)
- Acquires lock, checks `pending_signals & sigmask`
- If pending == 0:
  - O_NONBLOCK: return EAGAIN
  - Blocking: yield loop (release lock, sched.yield(), retry)
- Find first signal: `sig_bit = @ctz(pending)`, `signum = sig_bit + 1`
- **CRITICAL**: Clear pending bit to consume: `pending_signals &= ~(1 << sig_bit)`
- Build SignalFdSigInfo (only ssi_signo populated for MVP)
- Copy 128 bytes to userspace
- Return 128

**signalfdPoll FileOps:**
- No lock needed (single u64 load)
- Return EPOLLIN if `(pending_signals & sigmask) != 0`

**signalfdClose FileOps:**
- Destroy SignalFdState
- Return 0

### Userspace Wrappers (io.zig)

**Constants:**
- SFD_CLOEXEC: 0x80000
- SFD_NONBLOCK: 0x800

**SignalFdSigInfo structure:**
- 128-byte extern struct matching Linux ABI
- All fields defined (ssi_signo, ssi_code, ssi_pid, ssi_uid, etc.)
- Comptime assert for 128-byte size
- Currently only ssi_signo populated by kernel (MVP)

**signalfd4(fd, mask, flags) function:**
- syscall4 with SYS_SIGNALFD4
- sizemask parameter: @sizeOf(u64) = 8
- Returns i32 fd number

**signalfd(fd, mask) function:**
- Delegates to signalfd4(fd, mask, 0)

## Key Accomplishments

1. **Signal consumption works atomically** - Reading clears pending bit, preventing double delivery to both signalfd and signal handlers
2. **SIGKILL/SIGSTOP filtering** - Silently removed from mask per POSIX (cannot be caught)
3. **Mask updates on existing fds** - signalfd4 with fd >= 0 updates mask under lock
4. **Epoll integration** - signalfdPoll returns EPOLLIN when signals pending
5. **Non-blocking mode** - Returns EAGAIN immediately when no signals pending
6. **Blocking mode** - Yield loop pattern (signal delivery will set pending_signals during other thread execution)

## Technical Decisions

### Decision 1: Yield Loop for Blocking (MVP Pattern)

**Problem:** How to block when no signals are pending?

**Options considered:**
1. Integrate with signal delivery wakeup (add signalfd to a wait queue, wake on signal delivery)
2. Simple yield loop (release lock, sched.yield(), retry)

**Choice:** Yield loop (option 2)

**Rationale:**
- Signal delivery wakeup requires changes to signal.zig (cross-module dependency)
- Yield loop is simple, correct, and matches timerfd pattern
- Performance impact minimal (10ms tick granularity, signals are infrequent)
- Can be optimized later without breaking API

**Trade-off:** Burns CPU cycles in tight loop vs proper sleep/wake pattern

### Decision 2: Filter SIGKILL/SIGSTOP Silently

**Problem:** POSIX prohibits catching SIGKILL and SIGSTOP

**Options considered:**
1. Return EINVAL if mask includes these signals
2. Silently filter them out

**Choice:** Silent filtering (option 2)

**Rationale:**
- Linux behavior (man signalfd: "silently ignored")
- More robust (applications don't break if they accidentally include these)
- POSIX-compliant (cannot catch these signals regardless)

**Trade-off:** Application doesn't know mask was modified vs explicit error

### Decision 3: Consume Signal on Read

**Problem:** What happens to pending_signals when signalfd reads a signal?

**Options considered:**
1. Leave pending bit set (signal handler also receives it)
2. Clear pending bit (signal consumed)

**Choice:** Clear pending bit atomically (option 2)

**Rationale:**
- Linux semantics (signalfd consumes signals)
- Prevents double delivery (both signalfd and handler receiving same signal)
- Atomic clear under lock prevents races

**Implementation:** `pending_signals &= ~(1 << sig_bit)` after finding signal

### Decision 4: Only ssi_signo Populated (MVP)

**Problem:** SignalFdSigInfo has 20+ fields (ssi_code, ssi_pid, ssi_uid, ssi_addr, etc.)

**Options considered:**
1. Populate all fields (requires signal queue metadata)
2. Populate only ssi_signo, zero rest

**Choice:** Only ssi_signo (option 2)

**Rationale:**
- Current signal infrastructure only tracks pending_signals bitmask (no metadata)
- Full metadata requires signal queue with sender info (Phase 5+ work)
- Most applications only need signal number
- Zero-initialized struct is safe (applications check fields they care about)

**Future work:** Add signal queue to track metadata, populate remaining fields

## Deviations from Plan

None - plan executed exactly as written.

## Integration Points

### With Thread (pending_signals)

**Location:** src/kernel/proc/thread.zig:114

**How it works:**
- Thread has `pending_signals: u64` field (bit N-1 = signal N pending)
- signalfdRead reads this field to check for signals
- Atomically clears bit when consuming signal
- No lock needed on thread (single u64 load/store is atomic)

**Key insight:** Signal delivery (from signal.zig) sets bits, signalfd clears bits. No coordination needed beyond atomic operations.

### With Epoll (FileOps.poll)

**Location:** src/kernel/sys/syscall/process/scheduling.zig (epoll_wait)

**How it works:**
- epoll calls signalfdPoll on registered signalfds
- signalfdPoll checks `pending_signals & sigmask`
- Returns EPOLLIN if any signals pending
- epoll wakes threads waiting on that event

**Key insight:** No signalfd-specific epoll code needed. FileOps.poll integration is automatic.

### With Scheduler (sched.yield)

**Location:** src/kernel/proc/sched/root.zig

**How it works:**
- Blocking read releases lock, calls sched.yield()
- Scheduler picks another thread to run
- Signal delivery may occur in another thread's context
- Original thread wakes on next tick, re-checks pending_signals

**Key insight:** Yield loop works because pending_signals is shared across scheduler ticks. Inefficient but correct.

## Validation

**Build verification:**
- `zig build -Darch=x86_64` SUCCESS
- `zig build -Darch=aarch64` SUCCESS

**Test verification:**
- `zig build test` PASSED (unit tests)
- `ARCH=x86_64 ./scripts/run_tests.sh` PASSED (all existing tests, no regressions)

**Known limitations:**
- Signal metadata (ssi_code, ssi_pid, ssi_uid) not populated (requires signal queue)
- Blocking uses yield loop (burns CPU, should use proper sleep/wake)
- Multiple signalfd instances for same signal: first read() wins (POSIX compliant)

## Next Steps

**For Phase 4 Plan 4 (tests):**
1. Write test: create signalfd, send signal via kill(), read SignalFdSigInfo
2. Verify ssi_signo matches sent signal
3. Verify pending_signals bit is cleared after read
4. Test non-blocking mode (EAGAIN when no signals)
5. Test mask update (signalfd4 with existing fd)
6. Test SIGKILL/SIGSTOP filtering
7. Test epoll integration (EPOLLIN when signal pending)

**Future enhancements (beyond Phase 4):**
- Add signal queue to track metadata (ssi_code, ssi_pid, ssi_uid, ssi_addr)
- Integrate with signal delivery wakeup (blocked_readers wait queue)
- Support reading multiple signals per read() call (buf.len >= 256 = 2 signals)

## Performance Characteristics

**signalfd4 syscall:**
- O(1) creation (alloc state, install fd)
- O(1) mask update (lock, write sigmask)

**read() syscall:**
- O(1) signal check (single u64 AND operation)
- O(log n) find first signal (@ctz intrinsic)
- Blocking: O(ticks) until signal arrives (yield loop)

**poll() syscall:**
- O(1) (single u64 AND, no lock)

**Memory:**
- Per-fd overhead: 40 bytes (SignalFdState struct)
- No per-signal overhead (reuses thread.pending_signals)

**CPU:**
- Blocking read burns CPU in yield loop (should be fixed with wakeup integration)
- Non-blocking and poll are efficient

## Self-Check: PASSED

**Files created:**
- src/kernel/sys/syscall/io/signalfd.zig: EXISTS

**Commits:**
- b816c49: feat(04-03): implement signalfd kernel syscalls with signal consumption - EXISTS
- 22b55b7: feat(04-03): add signalfd userspace wrappers - EXISTS

All artifacts verified.
