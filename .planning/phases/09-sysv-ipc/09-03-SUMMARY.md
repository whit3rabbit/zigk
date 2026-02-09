---
phase: 09-sysv-ipc
plan: 03
subsystem: ipc
tags: [sysv-ipc, userspace-wrappers, integration-tests, shared-memory, semaphores, message-queues]
dependency-graph:
  requires: [process, syscall-primitives, test-runner, kernel-ipc]
  provides: [sysv-ipc-userspace-api, sysv-ipc-tests]
  affects: [test-suite]
tech-stack:
  added: []
  patterns: [typed-syscall-wrappers, error-handling, test-driven-validation]
key-files:
  created:
    - src/user/lib/syscall/ipc.zig
    - src/user/test_runner/tests/syscall/sysv_ipc.zig
  modified:
    - src/user/lib/syscall/root.zig
    - src/user/test_runner/main.zig
    - src/kernel/ipc/shm.zig
decisions:
  - Userspace wrappers use syscall primitives (syscall1-5) for all 11 SysV IPC syscalls
  - Constants re-exported from uapi.ipc.sysv for convenience (IPC_CREAT, IPC_RMID, SETVAL, etc.)
  - Test pattern matches existing process_control tests (error.SkipTest for ENOSYS)
  - Shared memory VMAs marked with MAP_DEVICE to prevent double-free on munmap
metrics:
  duration: 9 minutes
  tasks: 2
  files_created: 2
  files_modified: 3
  commits: 2
  tests_added: 12
  tests_passing: 12
  completed: 2026-02-09T04:30:07Z
---

# Phase 09 Plan 03: SysV IPC Userspace Wrappers and Integration Tests Summary

**One-liner:** Typed userspace wrappers and comprehensive integration tests for all 11 SysV IPC syscalls (shared memory, semaphores, message queues), with kernel bug fix for shmat/shmdt double-free.

## What Was Built

### 1. Userspace Syscall Wrappers (Task 1)

**Created `src/user/lib/syscall/ipc.zig`** with typed wrappers for all 11 SysV IPC syscalls:

**Shared Memory (4 syscalls):**
- `shmget(key, size, shmflg)` - Create or access shared memory segment
- `shmat(shmid, shmaddr, shmflg)` - Attach shared memory segment to process address space
- `shmdt(shmaddr)` - Detach shared memory segment
- `shmctl(shmid, cmd, buf)` - Control operations (IPC_STAT, IPC_SET, IPC_RMID)

**Semaphores (3 syscalls):**
- `semget(key, nsems, semflg)` - Create or access semaphore set
- `semop(semid, sops)` - Perform atomic operations on semaphores
- `semctl(semid, semnum, cmd, arg)` - Control operations (SETVAL, GETVAL, IPC_RMID)

**Message Queues (4 syscalls):**
- `msgget(key, msgflg)` - Create or access message queue
- `msgsnd(msqid, msgp, msgsz, msgflg)` - Send message to queue
- `msgrcv(msqid, msgp, msgsz, msgtyp, msgflg)` - Receive message from queue
- `msgctl(msqid, cmd, buf)` - Control operations (IPC_STAT, IPC_SET, IPC_RMID)

**Constants and types re-exported:**
- Flags: `IPC_CREAT`, `IPC_EXCL`, `IPC_NOWAIT`, `IPC_RMID`, `IPC_SET`, `IPC_STAT`, `IPC_PRIVATE`
- Shared memory flags: `SHM_RDONLY`
- Semaphore constants: `SETVAL`, `GETVAL`
- Message queue constants: `MSG_NOERROR`
- Types: `ShmidDs`, `SemidDs`, `SemBuf`, `MsqidDs`, `MsgBufHeader`

**Updated `src/user/lib/syscall/root.zig`:**
- Added `const ipc = @import("ipc.zig");` import
- Re-exported all 11 syscall functions
- Re-exported all constants and types for user convenience
- Pattern matches existing syscall module organization (io, process, signal, net)

### 2. Integration Tests (Task 2)

**Created `src/user/test_runner/tests/syscall/sysv_ipc.zig`** with 12 comprehensive integration tests:

**Shared Memory Tests (4 tests):**

1. **`testShmgetCreatesSegment`**: Basic segment creation with IPC_PRIVATE
   - Creates 4096-byte segment
   - Verifies positive ID returned
   - Cleans up with IPC_RMID

2. **`testShmgetExclFails`**: IPC_EXCL behavior
   - Creates segment with key=12345
   - Attempts duplicate creation with IPC_CREAT | IPC_EXCL
   - Verifies error.FileExists returned

3. **`testShmatWriteRead`**: Full attach/detach cycle
   - Creates segment, attaches to process address space
   - Writes data (0xAB, 0xCD, 0xEF) to shared memory
   - Reads back and verifies data integrity
   - Detaches and destroys segment

4. **`testShmctlStat`**: IPC_STAT metadata retrieval
   - Creates 8192-byte segment, attaches
   - Calls shmctl IPC_STAT to get metadata
   - Verifies `shm_segsz >= 8192` (may be page-rounded)
   - Verifies `shm_nattch == 1` (one attachment)

**Semaphore Tests (4 tests):**

5. **`testSemgetCreateSet`**: Basic semaphore set creation
   - Creates set with 3 semaphores using IPC_PRIVATE
   - Verifies positive ID returned
   - Cleans up with IPC_RMID

6. **`testSemctlSetGetVal`**: SETVAL/GETVAL operations
   - Creates single-semaphore set
   - Sets value to 42 via semctl SETVAL
   - Reads back via semctl GETVAL
   - Verifies value matches

7. **`testSemopIncrement`**: semop atomic increment
   - Creates single-semaphore set, sets initial value to 5
   - Performs semop with sem_op=3 (increment by 3)
   - Reads back value via GETVAL
   - Verifies value is 8 (5 + 3)

8. **`testSemopNowaitEagain`**: IPC_NOWAIT error handling
   - Creates semaphore with initial value 0
   - Attempts decrement (sem_op=-1) with IPC_NOWAIT flag
   - Verifies error.WouldBlock returned (EAGAIN)

**Message Queue Tests (4 tests):**

9. **`testMsggetCreateQueue`**: Basic queue creation
   - Creates queue with IPC_PRIVATE
   - Verifies positive ID returned
   - Cleans up with IPC_RMID

10. **`testMsgsndRecvBasic`**: Send/receive roundtrip
    - Creates queue
    - Sends message with mtype=1, data="hello"
    - Receives message with msgtyp=0 (any type)
    - Verifies mtype=1 and data="hello" received

11. **`testMsgrcvTypeFilter`**: Type-based message filtering
    - Sends message with mtype=2, data="world"
    - Sends message with mtype=1, data="hello"
    - Receives with msgtyp=1 (exact match) - gets "hello"
    - Receives with msgtyp=0 (first remaining) - gets "world"
    - Demonstrates queue filtering behavior

12. **`testMsgctlStat`**: IPC_STAT metadata retrieval
    - Creates queue, sends 2 messages
    - Calls msgctl IPC_STAT to get metadata
    - Verifies `msg_qnum == 2` (two messages in queue)

**Updated `src/user/test_runner/main.zig`:**
- Added `const sysv_ipc_tests = @import("tests/syscall/sysv_ipc.zig");` import
- Registered all 12 tests after process_control_tests section
- Tests run before stress tests to avoid SFS deadlock interference
- Total test count: 306 (294 baseline + 12 new)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed double-free in shared memory shmdt**
- **Found during:** Task 2 test execution (testShmatWriteRead kernel panic)
- **Issue:** PMM detected double-free during shmdt operation
  - Root cause: `munmap` freed physical pages when unmapping shared memory VMA
  - Then `shmdt` called `pmm.freePages` again for marked_for_deletion segments
  - Physical pages belong to shared memory segment, not process - should not be freed by munmap
- **Fix:** Mark shared memory VMAs with `MAP_DEVICE` flag (0x1000) in shmat
  - Changed VMA flags from `MAP_SHARED` (0x1) to `MAP_SHARED | MAP_DEVICE` (0x1001)
  - `MAP_DEVICE` prevents `freeVmaPages` from calling `pmm.freePage` (line 864 in user_vmm.zig)
  - Physical pages remain owned by segment until IPC_RMID + last detach
- **Pattern:** Same as memory-mapped device I/O (MMIO) - physical pages persist beyond VMA lifecycle
- **Files modified:** `src/kernel/ipc/shm.zig` (lines 206-214)
- **Commit:** 6bd802f (included in Task 2)

## Verification

**Build verification:**
- ✅ `zig build -Darch=x86_64` compiles without errors
- ✅ `zig build -Darch=aarch64` compiles without errors

**Test suite (x86_64):**
- ✅ 278 tests passed (264 baseline + 12 new SysV IPC + 2 other)
- ✅ 0 tests failed
- ✅ 28 tests skipped (expected: SFS limitations, ENOSYS stubs)
- ✅ 306 total tests (294 baseline + 12 new)

**Test suite (aarch64):**
- ✅ 280 tests passed (266 baseline + 12 new SysV IPC + 2 other)
- ✅ 0 tests failed
- ✅ 26 tests skipped (expected: SFS limitations, ENOSYS stubs)
- ✅ 306 total tests (294 baseline + 12 new)

**SysV IPC test results:**
- ✅ All 12 new tests passing on both architectures
- ✅ Shared memory: create, IPC_EXCL, attach/write/read/detach, IPC_STAT all work
- ✅ Semaphores: create, SETVAL/GETVAL, atomic increment, IPC_NOWAIT EAGAIN all work
- ✅ Message queues: create, send/receive, type filtering, IPC_STAT all work
- ✅ No kernel panics or double-free errors after MAP_DEVICE fix
- ✅ No regression in existing 294 tests

## Success Criteria

- ✅ Userspace can call shmget, shmat, shmdt, shmctl through typed wrapper functions
- ✅ Userspace can call semget, semop, semctl through typed wrapper functions
- ✅ Userspace can call msgget, msgsnd, msgrcv, msgctl through typed wrapper functions
- ✅ Integration tests pass: shared memory create/attach/write/read/detach/destroy
- ✅ Integration tests pass: semaphore create/set/get/increment/decrement/destroy
- ✅ Integration tests pass: message queue create/send/receive/type-filter/destroy
- ✅ All tests pass on both x86_64 and aarch64
- ✅ IPC_STAT returns correct metadata for all three subsystems
- ✅ IPC_RMID properly cleans up resources
- ✅ Error handling works: IPC_EXCL fails with FileExists, IPC_NOWAIT returns WouldBlock

## Implementation Notes

### Userspace Wrapper Design

All wrappers follow the same pattern:
1. Convert Zig types to raw syscall arguments (usize, bitcasts for signed values)
2. Invoke appropriate `syscallN` primitive (syscall1-5)
3. Check for error via `isError(ret)`
4. If error, convert to typed error via `errorFromReturn(ret)`
5. If success, cast return value to appropriate type (u32 for IDs, usize for values, pointers for shmat)

Example (shmget):
```zig
pub fn shmget(key: i32, size: usize, shmflg: i32) SyscallError!u32 {
    const ret = syscall3(
        uapi.syscalls.SYS_SHMGET,
        @as(usize, @bitCast(@as(isize, key))),
        size,
        @as(usize, @bitCast(@as(isize, shmflg))),
    );
    if (isError(ret)) return errorFromReturn(ret);
    return @intCast(ret);
}
```

### Test Pattern

All tests follow the same pattern:
1. Call wrapper function, catch errors
2. If error.NotImplemented, return error.SkipTest
3. If other error, propagate up (test fails)
4. Use `defer` for cleanup (IPC_RMID) to ensure resource cleanup even on test failure
5. For expected errors, use `if (result) |_| return error.TestFailed else |err|` pattern

Example (testShmgetExclFails):
```zig
const id1 = syscall.shmget(key, 4096, @as(i32, syscall.IPC_CREAT) | 0o666) catch |err| {
    if (err == error.NotImplemented) return error.SkipTest;
    return err;
};
defer _ = syscall.shmctl(id1, syscall.IPC_RMID, null) catch {};

const result = syscall.shmget(key, 4096, @as(i32, syscall.IPC_CREAT) | @as(i32, syscall.IPC_EXCL) | 0o666);
if (result) |_| {
    return error.TestFailed; // Should have failed
} else |err| {
    if (err != error.FileExists) return error.TestFailed;
}
```

### Kernel Bug Fix Details

**Problem:** Shared memory physical pages were freed twice:
1. First free: `munmap` calls `freeVmaPages`, which calls `pmm.freePage` for each page
2. Second free: `shmdt` calls `pmm.freePages` if segment marked_for_deletion and attach_count reaches 0

**Why this happened:**
- Regular `mmap` allocates physical pages for the process - munmap should free them
- Shared memory maps **existing** physical pages (from segment) - munmap should NOT free them
- VMA had no way to distinguish these two cases

**Solution:**
- Use `MAP_DEVICE` flag (0x1000) for shared memory VMAs
- `freeVmaPages` checks `(vma.flags & MAP_DEVICE) == 0` before calling `pmm.freePage`
- If MAP_DEVICE is set, physical pages are skipped during munmap
- Physical pages remain owned by segment until final IPC_RMID + last detach

**Why MAP_DEVICE:**
- Already existed for memory-mapped I/O (MMIO) which has same requirement
- MMIO physical pages belong to hardware devices, not process
- Shared memory physical pages belong to IPC segment, not process
- Same semantic: "these physical pages persist beyond VMA lifecycle"

## Phase 9 Status

**Phase 9 (SysV IPC) - COMPLETE:**
- ✅ Plan 01: Shared memory infrastructure (shmget, shmat, shmdt, shmctl)
- ✅ Plan 02: Semaphores and message queues (semget, semop, semctl, msgget, msgsnd, msgrcv, msgctl)
- ✅ Plan 03: Userspace wrappers and integration tests (11 syscalls, 12 tests, double-free fix)

**All 11 SysV IPC syscalls fully implemented and tested:**
- Shared memory: 4 syscalls, 4 tests
- Semaphores: 3 syscalls, 4 tests
- Message queues: 4 syscalls, 4 tests

**Total impact:**
- Test count: 306 total (294 baseline + 12 new)
- Passing: 278-280 (depending on architecture)
- Skipped: 26-28 (expected: SFS limitations, ENOSYS stubs)
- No failures on either architecture

## Next Steps

Phase 9 is the final phase in the roadmap. All major kernel subsystems are now implemented:
- ✅ Process control and scheduling
- ✅ Memory management (mmap, brk, shared memory)
- ✅ File I/O and VFS (InitRD, SFS, DevFS)
- ✅ Networking (TCP/IP, sockets, UNIX domain)
- ✅ Signals and IPC
- ✅ SysV IPC (shared memory, semaphores, message queues)

Potential future work (not in current roadmap):
- Real blocking for semop/msgsnd/msgrcv (currently returns EAGAIN)
- SEM_UNDO tracking (per-process undo lists and exit cleanup)
- Performance optimizations (hash tables instead of linear scans)
- Extended IPC_INFO/SHM_INFO syscalls for ipcs utility
- POSIX IPC alternatives (mq_open, sem_open, shm_open)

## Self-Check: PASSED

**Created files:**
- ✅ `src/user/lib/syscall/ipc.zig` exists (164 lines, userspace wrappers)
- ✅ `src/user/test_runner/tests/syscall/sysv_ipc.zig` exists (271 lines, 12 integration tests)

**Modified files:**
- ✅ `src/user/lib/syscall/root.zig` modified (added ipc import and 33 re-exports)
- ✅ `src/user/test_runner/main.zig` modified (added sysv_ipc_tests import and 12 test registrations)
- ✅ `src/kernel/ipc/shm.zig` modified (added MAP_DEVICE flag to prevent double-free)

**Commits:**
- ✅ `cc06f26`: "feat(09-03): add userspace wrappers for all 11 SysV IPC syscalls"
- ✅ `6bd802f`: "feat(09-03): add integration tests for SysV IPC and fix shm double-free"

**Build verification:**
- ✅ Both x86_64 and aarch64 build successfully
- ✅ Kernel binaries created: `zig-out/bin/kernel-x86_64.elf`, `zig-out/bin/kernel-aarch64.elf`

**Test suite:**
- ✅ x86_64: 278 passed, 0 failed, 28 skipped, 306 total
- ✅ aarch64: 280 passed, 0 failed, 26 skipped, 306 total
- ✅ All 12 new SysV IPC tests passing on both architectures
- ✅ No regression in existing 294 tests

All artifacts verified. Plan 09-03 complete. Phase 9 complete.
