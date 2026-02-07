---
phase: 03-io-multiplexing
plan: 01
subsystem: io-multiplexing
tags: [epoll, poll, select, fileops, pipes, sockets, filesystem]

# Dependency graph
requires:
  - phase: 02-credentials-and-ownership
    provides: Phase 2 complete - foundation stable
provides:
  - FileOps.poll methods for all FD types (pipes, regular files, DevFS, sockets)
  - pipePoll for pipe read/write ends with state-dependent readiness
  - devfsPoll/initrdPoll/sfsPoll always returning ready (Linux behavior)
  - socketPoll delegating to socket layer checkPollEvents
affects: [03-02, 03-03, 03-04, 03-05, 03-06]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - FileOps.poll dispatch: every FD type implements poll method
    - Pipes report POLLIN/POLLOUT based on buffer state, POLLHUP/POLLERR on end closure
    - Regular files and device files always report ready
    - Sockets delegate to transport layer for readiness semantics

key-files:
  created: []
  modified:
    - src/kernel/fs/pipe.zig
    - src/kernel/fs/devfs.zig
    - src/fs/initrd.zig
    - src/fs/sfs/ops.zig
    - src/kernel/sys/syscall/net/net.zig

key-decisions:
  - "Pipes follow Linux semantics: POLLERR/POLLHUP always reported regardless of requested_events"
  - "Regular files and device files always ready per Linux behavior"
  - "Socket poll delegates to existing checkPollEvents in socket/poll.zig"

patterns-established:
  - "FileOps.poll signature: fn(fd: *FileDescriptor, requested_events: u32) u32"
  - "Poll methods return EPOLL* constants (low 16 bits match POLL* values)"
  - "Socket readiness: POLLIN when recv buffer has data, POLLOUT when send space, POLLHUP on peer close"

# Metrics
duration: 4min
completed: 2026-02-07
---

# Phase 3 Plan 01: FileOps Poll Foundation Summary

**FileOps.poll methods implemented for all FD types: pipes report state-dependent readiness, regular files always ready, sockets delegate to transport layer**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-07T13:05:51Z
- **Completed:** 2026-02-07T13:10:21Z
- **Tasks:** 3
- **Files modified:** 5

## Accomplishments
- Every FD type in the kernel now has a working FileOps.poll method
- Pipes implement correct Linux-compatible readiness semantics (POLLIN when data available, POLLOUT when space, POLLHUP when write ends closed, POLLERR when read ends closed)
- Regular files (initrd, SFS) and device files (console, null, zero) always report ready
- TCP/UDP sockets delegate to existing checkPollEvents for full readiness logic

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement pipePoll for pipe file descriptors** - `3b6a736` (feat)
2. **Task 2: Implement poll for regular files and DevFS** - `8ce7d58` (feat)
3. **Task 3: Implement socketPoll for TCP/UDP sockets** - `ef09591` (feat)

## Files Created/Modified
- `src/kernel/fs/pipe.zig` - pipePoll function wired into pipe_ops
- `src/kernel/fs/devfs.zig` - devfsPoll for console_ops, null_ops, zero_ops
- `src/fs/initrd.zig` - initrdPoll for initrd_ops
- `src/fs/sfs/ops.zig` - sfsPoll for sfs_ops
- `src/kernel/sys/syscall/net/net.zig` - socketPoll for socket_file_ops

## Decisions Made

Per locked user decision on socket readiness semantics:
- POLLIN when recv buffer has data or incoming connection
- POLLOUT when send buffer has space
- POLLHUP on peer close
- POLLERR on socket error

All implemented via existing checkPollEvents function in socket/poll.zig.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None - all implementations straightforward.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

Phase 3 foundation complete. Every FD type can now be polled for readiness. Next plans can implement:
- sys_poll (03-02)
- sys_select (03-03)
- sys_epoll_* family (03-04)
- Integration tests (03-05)

No blockers. All FileOps.poll methods tested via existing test suite (186 tests pass on x86_64).

## Self-Check: PASSED

All created/modified files exist:
- src/kernel/fs/pipe.zig - contains pipePoll
- src/kernel/fs/devfs.zig - contains devfsPoll
- src/fs/initrd.zig - contains initrdPoll
- src/fs/sfs/ops.zig - contains sfsPoll
- src/kernel/sys/syscall/net/net.zig - contains socketPoll

All commits exist:
- 3b6a736 (Task 1)
- 8ce7d58 (Task 2)
- ef09591 (Task 3)

---
*Phase: 03-io-multiplexing*
*Completed: 2026-02-07*
