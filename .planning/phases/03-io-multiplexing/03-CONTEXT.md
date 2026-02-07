# Phase 3: I/O Multiplexing - Context

**Gathered:** 2026-02-06
**Status:** Ready for planning

<domain>
## Phase Boundary

Complete the existing epoll infrastructure by implementing FileOps.poll for pipes, sockets, and regular files. Implement select/pselect6 on top of the poll infrastructure. Programs using epoll, select, or poll should get Linux-compatible readiness semantics.

</domain>

<decisions>
## Implementation Decisions

### FD readiness semantics
- Match Linux poll semantics exactly per fd type:
  - **Regular files**: Always report POLLIN | POLLOUT (always "ready") -- this is what Linux does
  - **Pipes**: POLLIN when bytes available in buffer, POLLOUT when space in write buffer, POLLHUP when all write ends closed (reader gets EOF), POLLERR on broken pipe write
  - **Sockets**: POLLIN when recv buffer has data or incoming connection (listen socket), POLLOUT when send buffer has space, POLLHUP on peer close, POLLERR on socket error
  - **DevFS files** (e.g., /dev/null, /dev/zero): Always ready, same as regular files
- EOF condition: POLLHUP is set, POLLIN may also be set if unread data remains (Linux behavior)
- Distinguish between POLLHUP (normal close) and POLLERR (error condition)
- POLLNVAL returned for invalid file descriptors, not an error return

### Epoll edge vs level triggering
- Implement both level-triggered (default) and edge-triggered (EPOLLET)
- Level-triggered: epoll_wait returns the fd every time it is polled while the condition holds
- Edge-triggered: epoll_wait returns the fd only when state transitions from not-ready to ready
- Implement EPOLLONESHOT: after one event delivery, the interest is disabled until re-armed with epoll_ctl(EPOLL_CTL_MOD)
- EPOLLERR and EPOLLHUP are always reported regardless of requested events (Linux behavior)
- epoll_ctl operations: EPOLL_CTL_ADD, EPOLL_CTL_MOD, EPOLL_CTL_DEL all implemented

### Select/pselect6 behavior
- Implement select on top of the internal poll infrastructure (not a separate path)
- FD_SETSIZE = 1024 (Linux default) -- reject nfds > 1024 with EINVAL
- fd_set is a bitmask: 1024 bits = 128 bytes = 16 u64s
- pselect6 adds signal mask atomically (block signals during wait, restore after)
- Timeout: select uses timeval (microseconds), pselect6 uses timespec (nanoseconds)
- Timeout of NULL = block indefinitely, zero timeout = poll and return immediately
- On return, fd_sets are modified in-place to reflect ready fds (Linux behavior)
- Return value = total number of ready fds across all three sets

### Wake-up and blocking model
- epoll_wait and select/pselect6 block the calling thread via scheduler (not spin-wait)
- Use wait queue pattern: thread sleeps, fd state change wakes all waiters on that fd
- FileOps.poll method returns current readiness mask (non-blocking check)
- Waiters are added to per-fd wait queues; state changes (write to pipe, socket data arrival) call wake_up
- Timeout support via scheduler timer -- thread is woken by either fd readiness or timeout expiry
- Spurious wakes are safe: re-check conditions after wake (standard Linux pattern)
- epoll_wait maxevents parameter caps returned events per call

### Claude's Discretion
- Internal wait queue data structure design
- How poll method integrates with existing pipe/socket implementations
- Whether select internally converts to epoll or uses poll directly
- Exact locking strategy for wait queue manipulation
- How to handle epoll-on-epoll (epoll fd monitoring another epoll fd) -- can defer if complex

</decisions>

<specifics>
## Specific Ideas

- Full Linux kernel compatibility is the goal -- when in doubt, match Linux behavior exactly
- All complexity should be embraced, not simplified away
- This phase directly unlocks Phase 4 (eventfd, timerfd, signalfd all need poll/epoll integration)
- Existing epoll infrastructure is partially built -- extend it, don't rewrite

</specifics>

<deferred>
## Deferred Ideas

None -- discussion stayed within phase scope

</deferred>

---

*Phase: 03-io-multiplexing*
*Context gathered: 2026-02-06*
