# Phase 20: Signal Handling Extensions - Context

**Gathered:** 2026-02-14
**Status:** Ready for planning

<domain>
## Phase Boundary

Implement synchronous signal waiting (rt_sigtimedwait), signal queuing with data (rt_sigqueueinfo, rt_tgsigqueueinfo), and clock-aware sleeping (clock_nanosleep). These extend the existing signal infrastructure (rt_sigaction, rt_sigprocmask, signalfd, kill) with three new syscall families. No changes to signal handler dispatch or sigreturn.

</domain>

<decisions>
## Implementation Decisions

### Signal dequeue strategy (rt_sigtimedwait)
- Block using WaitQueue, consistent with v1.1 WaitQueue migration pattern (timerfd, signalfd, semop)
- Signal delivery path must wake rt_sigtimedwait waiters directly via WaitQueue when a matching signal is posted
- Populate full siginfo_t on dequeue: si_signo, si_code (SI_USER/SI_QUEUE/SI_KERNEL), si_pid, si_uid
- Use atomic CAS loop (@cmpxchgWeak) on pending_signals to check-and-clear signal bit, handling races if multiple threads wait on same signal
- Timeout returns EAGAIN (Linux-compatible), not ETIMEDOUT
- rt_sigtimedwait has priority over signalfd when both wait on the same signal -- synchronous consumption wins

### Clock nanosleep
- Support CLOCK_REALTIME and CLOCK_MONOTONIC only (no BOOTTIME -- suspend not relevant for zk)
- TIMER_ABSTIME: use WaitQueue with absolute deadline comparison in the wake check, not compute-delta-then-sleep
- On signal interrupt (EINTR): write remaining time back to user's rmtp timespec for non-ABSTIME relative sleeps
- Refactor existing sys_nanosleep to be a thin wrapper calling clock_nanosleep(CLOCK_MONOTONIC, 0, req, rem) -- one implementation, two entry points

### Siginfo data passing (rt_sigqueueinfo / rt_tgsigqueueinfo)
- Implement both rt_sigqueueinfo (process-wide) and rt_tgsigqueueinfo (thread-directed)
- Enforce si_code restriction: only allow SI_QUEUE (negative codes) from userspace, reject codes that could impersonate kernel-generated signals (si_code >= 0)
- Signal queuing infrastructure needed: per-thread queue to hold siginfo_t data for queued signals (vs. bitmask for standard signals)

### Permission model
- Permission checks: sender must have same real/effective UID as target process, OR have CAP_KILL capability
- If capability system (Phase 24) not yet available, fall back to UID check only -- designed to be extended later

### Testing
- Cross-process signal queuing tests included: fork + rt_sigqueueinfo to child exercises permission checks and PID lookup
- Same-process scenarios for rt_sigtimedwait with timeout, immediate signal, and blocked-then-woken paths
- clock_nanosleep tests for both relative and TIMER_ABSTIME modes, plus EINTR remaining-time writeback

### Claude's Discretion
- Signal queue implementation: fixed-size ring buffer vs linked list, queue depth limit
- Signal delivery ordering when both queued and bitmask entries exist for the same signo (follow Linux semantics)
- Exact WaitQueue integration points in the signal delivery path
- clock_nanosleep timer precision and internal scheduling mechanism

</decisions>

<specifics>
## Specific Ideas

- WaitQueue pattern is established from Phase 14 (timerfd, signalfd, semop, msgrcv) -- reuse that infrastructure
- pending_signals atomicity patterns are documented in MEMORY.md -- use @atomicRmw / @cmpxchgWeak consistently
- SigInfo struct (128 bytes, compile-time assertion) already exists from Phase 19 (waitid) -- reuse it

</specifics>

<deferred>
## Deferred Ideas

None -- discussion stayed within phase scope

</deferred>

---

*Phase: 20-signal-handling-extensions*
*Context gathered: 2026-02-14*
