# Codebase Concerns

**Analysis Date:** 2026-02-06

## Tech Debt

### SFS Close Deadlock (Critical)

**Issue:** After 50+ SFS operations, calling `close()` on SFS file descriptors deadlocks the system.

**Files:**
- `src/fs/sfs/ops.zig` (SFS operations)
- `src/kernel/sys/syscall/fs/file_io.zig` (close syscall)

**Impact:**
- SFS stress tests hang if explicit close() is called on many files
- Blocks reliable cleanup in user code
- Forces test workarounds (leaving FDs open, using reopen instead of close)

**Root Cause:** Lock ordering issue between `alloc_lock` and `fd.lock` during file close combined with waiting on I/O operations while holding locks.

**Current Workaround:** Tests avoid closing SFS files after many operations. Instead they use lseek() to reset position and reopen files.

**Fix Approach:**
1. Trace lock acquisition order in `sfsClose()` vs concurrent operations
2. Ensure no blocking I/O happens while holding spinlocks
3. Implement deferred close (queue close operations, process asynchronously)
4. Add test to catch regression once fixed

---

### SFS Flat Filesystem Limitation (Design Constraint)

**Issue:** SFS supports only flat directory structure with no subdirectories.

**Files:** `src/fs/sfs/ops.zig:L170-195` (mkdir implementation)

**Constraints:**
- Maximum 64 files/directories total per filesystem (4 directory blocks × 512 bytes / 32 bytes per entry)
- No nested paths - `/mnt/dir/subdir` not supported
- 32-character filename limit (null-terminated, so effectively 31 usable chars)

**Impact:**
- Cannot test directory nesting operations on SFS mount point
- Limits filesystem test scenarios
- Some edge case tests skip due to this constraint
- Users cannot organize files hierarchically on `/mnt`

**Status:** By design for embedded systems. Not a bug, documented limitation.

**Workaround:** Tests use InitRD (read-only) for directory structure testing. SFS tests limited to flat layouts.

---

### SFS Bitmap Invalidation Race

**Issue:** `bitmap_cache_valid` flag can become stale if multiple CPUs or interrupt handlers modify SFS state simultaneously.

**Files:** `src/fs/sfs/ops.zig`, `src/fs/sfs/alloc.zig`

**Current Code:**
```zig
if (self.bitmap_cache) |cache| {
    if (!self.bitmap_cache_valid) {
        loadBitmapIntoCached(self, cache);
        self.bitmap_cache_valid = true;
    }
}
```

**Risk:**
- No atomic flag update - ABA problem possible if two threads check `bitmap_cache_valid` before either updates it
- Cached bitmap could be stale if another CPU modified disk concurrently

**Fix Approach:**
1. Replace boolean flag with atomic u64 version counter
2. Increment version on every bitmap write
3. Check version before using cached bitmap
4. Add CPU barrier in alloc_lock critical section

---

## Known Bugs

### Socket Tests Trigger Kernel Panic (Active Blocker)

**Status:** Blocking - Socket tests disabled

**Severity:** HIGH

**Affected Tests:** All 8 socket tests in `src/user/test_runner/tests/syscall/sockets.zig`

**Symptom:**
```
Running: socket: create TCP

!!! KERNEL PANIC !!!
Message: IrqLock used before initialization - security violation
```

**Files:**
- Tests: `src/user/test_runner/tests/syscall/sockets.zig`
- Syscall: `src/kernel/sys/syscall/net/net.zig` (socket creation)
- Network init: `src/kernel/core/init_hw.zig` (network stack initialization)

**Root Cause:** Socket syscalls attempt to use `IrqLock` in network stack before it's initialized during kernel boot. The initialization order in `main.zig` doesn't guarantee socket layer is ready when first socket syscall executes.

**Impact:**
- 8 socket tests written but cannot run
- Network syscall coverage at 0%
- All socket operations fail with kernel panic
- Blocks network feature development

**Fix Steps:**
1. Identify where `IrqLock.init()` is called in network stack initialization
2. Move socket syscall dispatch registration to after `IrqLock` is guaranteed initialized
3. Or add lazy initialization to socket layer (check and init on first syscall)
4. Re-enable socket tests once kernel panic is resolved

---

### *at Syscall Kernel Pointer Bugs (Fixed in Recent Commit)

**Status:** FIXED (2026-02-05)

**Severity:** HIGH - Was causing EFAULT on all *at syscalls

**What Was Wrong:**
All `*at` syscalls (`fstatat`, `mkdirat`, `unlinkat`, `renameat`, `fchmodat`) copied paths from userspace to kernel buffers, then delegated to base syscalls passing the kernel buffer pointer. Base syscalls called `copyStringFromUser()` on the kernel pointer, which failed with EFAULT.

**Files:**
- `src/kernel/sys/syscall/fs/file_info.zig` (stat family)
- `src/kernel/sys/syscall/fs/dir_ops.zig` (mkdir/rmdir family)

**Fix Applied:**
- Extracted internal helpers: `statPathKernel()`, `mkdirKernel()`, `unlinkKernel()`, `rmdirKernel()`, `chmodKernel()`, `renameKernel()`
- Both base syscalls and *at variants now use these helpers
- Bypasses redundant `copyStringFromUser()` call

**Status:** Resolved in commit bd5d7f7 (2026-02-05)

---

### sys_newfstatat Not Registered (Fixed)

**Status:** FIXED (2026-02-05)

**What Was Wrong:**
Dispatch table converts `SYS_NEWFSTATAT` to function name `sys_newfstatat`, but implementation was named `sys_fstatat`. Registration mismatch caused syscall to be unmapped.

**Files:** `src/kernel/sys/syscall/io/root.zig`

**Fix Applied:**
```zig
pub const sys_newfstatat = stat.sys_fstatat;
```

**Status:** Resolved

---

### sys_uname Machine Field Hardcoded (Fixed)

**Status:** FIXED (2026-02-05)

**What Was Wrong:**
`sys_uname()` returned hardcoded machine="x86_64" regardless of actual architecture. On aarch64, this violated Linux ABI.

**Files:** `src/kernel/sys/syscall/misc/uname.zig`

**Fix Applied:**
```zig
// Now uses @import("builtin").cpu.arch at runtime
```

**Status:** Resolved

---

## Security Considerations

### User Memory Access Violations (Low Risk - Mitigated)

**Area:** User pointer dereferencing across codebase

**Risk:** Kernel code directly dereferencing user pointers without validation could:
- Read/write kernel memory if pointer passed is crafted
- Leak kernel stack/heap data
- Enable privilege escalation

**Current Mitigation:**
- `UserPtr` wrapper in `src/kernel/core/user_mem.zig` enforces bounds checks
- SMAP (Supervisor Mode Access Prevention) compliance verified
- Guidelines in `CLAUDE.md` require `UserPtr` for all user access

**Status:** Well-mitigated. All new code uses `UserPtr`.

---

### Capability System Not Fully Implemented (Medium Risk)

**Issue:** Capability checks exist but name-based capability granting is a security concern.

**Files:**
- `src/kernel/core/init_proc.zig:L463` (TODO comment)
- `src/kernel/proc/capabilities/root.zig`

**Current State:**
```zig
/// FIXME(security-high): Replace name-based capability granting with signed capability manifests
```

**Risk:**
- Capabilities currently granted by process name string match
- Attacker could rename binary and gain unintended capabilities
- No cryptographic verification of privilege

**Fix Approach:**
1. Implement capability manifest format (binary blob with signatures)
2. Use public key cryptography to verify manifest authenticity
3. Embed manifest in ELF executable or external file with signature
4. Load and verify at exec() time before granting capabilities

---

### Stack Data Leaks in Network Packets (Low Risk - Mitigated)

**Area:** Network packet header construction

**Risk:** Uninitialized padding bytes in headers could leak kernel stack memory to remote hosts

**Current Mitigation:**
Multiple security comments throughout network stack:
- `src/net/transport/tcp/tx/control.zig` - "Zero-initialize options buffer"
- `src/net/platform.zig` - "Zero-initialize buffer to prevent stack data leakage"
- TCP, ICMP, ARP all explicitly zero packets before use

**Status:** Well-handled. Good security practice observed.

---

### TCP ISN Randomization (Well-Implemented)

**Area:** TCP connection hijacking prevention

**Risk:** Predictable ISNs allow connection hijacking attacks

**Current Implementation:** RFC 6528 compliant - Uses SipHash-2-4 with hardware entropy mixing.

**Files:** `src/net/transport/tcp/state.zig`

**Status:** Secure. ISNs properly randomized using CSPRNG.

---

## Performance Bottlenecks

### SFS Block Allocation Under Lock

**Problem:** Block allocation holds `alloc_lock` (spinlock) while performing disk I/O.

**Files:** `src/fs/sfs/alloc.zig:L80-150`

**Impact:**
- Other CPUs spinning on lock while disk I/O blocks
- No preemption while lock held (spinlock)
- Scales poorly with >4 CPUs

**Current Implementation:** Actually fixed in recent refactor - I/O now happens under FD lock, not alloc_lock. Bitmap load deferred when possible.

**Status:** Already improved. Monitor for remaining issues.

---

### Large Monolithic Syscall Handlers

**Problem:** Some syscall files exceed 1900 lines of code.

**Files:**
- `src/kernel/sys/syscall/net/net.zig` (1969 lines) - All network syscalls combined
- `src/kernel/sys/syscall/net/msg.zig` (1123 lines) - Message queue operations
- `src/fs/sfs/ops.zig` (1565 lines) - All SFS file operations

**Impact:**
- Difficult to reason about complex logic
- Hard to test individual paths
- Risk of logic errors in deep nesting

**Fix Approach:**
1. Split monolithic files by operation type (read ops, write ops, etc.)
2. Extract complex logic into helper functions with unit tests
3. Keep public API stable while refactoring internals

**Priority:** Medium - Functions work but maintainability suffers.

---

### Scheduler Lock Contention

**Problem:** `process_tree_lock` covers all process lifecycle operations.

**Files:** `src/kernel/proc/sched/scheduler.zig`

**Impact:**
- Bottleneck for fork/exec/exit on many CPUs
- Process creation rate limited by lock fairness

**Optimization Path:**
1. Identify which tree operations truly require global lock
2. Use hierarchical locks (per-subtree locks)
3. Implement lock-free process lookup for common operations

**Priority:** Low - Only matters at scale (>16 CPUs).

---

## Fragile Areas

### Exception Handler Synchronization (Fragile)

**Component:** CPU exception handling and signal delivery

**Files:**
- `src/arch/x86_64/kernel/handlers.zig` (x86_64 exception handlers)
- `src/arch/aarch64/kernel/interrupts/root.zig` (aarch64 handlers)
- `src/kernel/sys/syscall/process/signals.zig` (signal delivery)

**Why Fragile:**
- Tight coupling between exception handler state and process signal state
- Race conditions possible between exception delivery and signal mask changes
- Architecture-specific fixup handlers for copy_from_user exceptions
- aarch64 had missing fixup check (was fixed in 8763477)

**Safe Modification:**
1. Never modify exception handler logic without testing both architectures
2. Add regression tests for any exception handler change
3. Use atomic operations for signal mask updates
4. Document assumptions about interrupt state clearly

**Test Coverage:**
- Signal handling tests exist but are marked complex/architecture-specific
- Some signal edge cases likely uncovered

---

### VFS Mount Point Resolution (Fragile)

**Component:** Path canonicalization and mount routing

**Files:**
- `src/fs/vfs.zig` (path resolution)
- `src/kernel/sys/syscall/io/dir.zig` (directory operations)

**Why Fragile:**
- Multiple filesystems (InitRD, SFS, DevFS) with different semantics
- Path traversal validation happens at multiple levels
- Symlinks not implemented (future complexity)
- TOCTOU races possible if file stat changes between path check and open

**Known Gaps:**
- Symlinks not resolved (safe for now - not implemented)
- Mount point switching has edge cases (e.g., `/mnt/../etc` traversal)
- Concurrent mkdir/rmdir on boundary conditions untested

**Safe Modification:**
1. Always test path traversal attempts (`.., /../, etc`)
2. Verify TOCTOU protection with regression tests
3. Document assumptions about mount point stability

---

### Copy-on-Write Fork Implementation (Fragile)

**Component:** Process forking and page table management

**Files:**
- `src/kernel/sys/syscall/core/execution.zig` (fork/clone)
- `src/kernel/mm/user_vmm.zig` (user address space)

**Why Fragile:**
- Recent bugs fixed: CS/SS register swap in child setup (2026-01-31)
- Recent bugs fixed: Process refcount double-unref (2026-01-31)
- aarch64 page table split (TTBR0/TTBR1) adds complexity
- Parent/child page table synchronization needs careful lock ordering

**Known Issues (Fixed):**
1. **CS/SS segment register swap** - GPF on child return to userspace (FIXED)
2. **Process refcount double-unref** - Panic in wait4() (FIXED)

**Safe Modification:**
1. Always test fork on both architectures after any change
2. Verify child process can return to userspace correctly
3. Test wait4() to ensure refcount is correct
4. Use fork stress tests to catch race conditions

**Test Coverage:**
- 8 process tests passing
- Should increase to 12+ with additional edge case tests

---

### aarch64 Architecture-Specific Code (Fragile)

**Component:** aarch64-specific implementations

**Files:**
- `src/arch/aarch64/kernel/interrupts/root.zig` (exception handling)
- `src/kernel/mm/user_vmm.zig` (page table management - TTBR0 vs TTBR1)
- `src/drivers/video/qxl/regs.zig` (aarch64 MMIO workarounds)

**Known Issues:**
1. **Data abort handler missing fixup check** - Addressed in 8763477
2. **sys_execve using writeCr3() instead of writeTtbr0()** - Addressed in 8763477
3. **Hardcoded x86_64 video driver support** - Some drivers only x86_64 (qxl, cirrus)

**Why Fragile:**
- aarch64 architecture very different from x86_64
- Exception handler differences (ESR encoding, page table split)
- MMIO access patterns differ
- Less testing infrastructure for aarch64 (fewer developers)

**Safe Modification:**
1. Always test on both architectures - **this is non-optional**
2. aarch64 bugs are harder to spot without dedicated testing
3. Use `RUN_BOTH=true ./scripts/run_tests.sh` for pre-commit validation
4. Document architectural assumptions in code comments

**Coverage:** 166 tests pass on both architectures (good parity).

---

## Scaling Limits

### File Descriptor Table (Hard Limit)

**Resource:** Process FD table

**Files:** `src/kernel/fd.zig`

**Current Capacity:** 256 FDs per process (fixed-size array)

**Limit:** Max 256 open files per process

**Scaling Path:**
1. Implement dynamic FD table (grows as needed)
2. Use sparse data structure (hash map or tree) for large FD counts
3. Handle fragmentation (FDs not released, table grows unbounded)

**Priority:** Low - 256 FDs sufficient for most use cases.

---

### SFS File Capacity (Hard Limit)

**Resource:** Files in SFS filesystem

**Current Capacity:** 64 files maximum

**Limit:** Cannot create > 64 files/directories on `/mnt`

**Scaling Path:**
1. Increase directory blocks from 4 to 8+ (doubles to 128 entries)
2. Implement linked directory blocks (remove fixed size limit)
3. Note: Requires on-disk format change, migration tool

**Impact:** Long-term, hits limit with realistic workloads. Planning needed before implementing SysV IPC (shared memory/semaphores).

**Priority:** Medium - Affects test stress tests and real deployments.

---

### Page Table Memory Overhead

**Resource:** User VMM memory structures

**Issue:** Each process maps page table hierarchy. With 4-level page tables on x86_64 and aarch64, large address spaces require significant kernel memory.

**Current Implementation:**
- Page tables allocated on-demand
- No aggressive cleanup (potential memory leak)
- No shared page table optimization

**Limit:** ~100 processes before page table memory exceeds reasonable bounds.

**Scaling Path:**
1. Implement page table pooling/reuse
2. Use sparse data structures for large gaps
3. Add page table memory tracking/limits

**Priority:** Low - Works for embedded systems target.

---

## Dependencies at Risk

### Zig 0.16.x Nightly Dependency (Medium Risk)

**Risk:** Nightly compiler version means breaking changes possible

**Files:** `build.zig` (build configuration)

**Impact:**
- Compiler updates may require code changes
- Incremental compilation can become stale
- No LTS stability guarantees

**Evidence of Risk:**
- Multiple Zig API changes documented in `CLAUDE.md`
- `std.fs.cwd()` removed (had to refactor)
- `std.atomic.compilerFence()` removed (had to replace)
- `std.mem.trimRight()` removed (had to implement)
- `std.meta.intToEnum()` changed API

**Mitigation:**
- Document all API changes in `CLAUDE.md`
- Pin compiler hash in CI environment
- Create upgrade test suite for Zig compiler updates

**Priority:** Medium - Track upstream changes closely.

---

## Missing Critical Features

### Signal Delivery Not Fully Implemented

**Feature Gap:** Interval timers set but do not expire

**Files:**
- `src/kernel/sys/syscall/misc/itimer.zig` (timer syscalls)
- `src/kernel/proc/signal.zig` (signal delivery)

**What's Missing:**
- Timer countdown mechanism (timers can be set/retrieved but don't expire)
- Signal delivery to process when timer fires
- SIGALRM, SIGVTALRM, SIGPROF delivery

**Impact:**
- Tests document this limitation
- Real programs relying on alarm signals will hang indefinitely
- No deadline-driven behavior possible

**Fix Approach:**
1. Implement timer hardware integration (APIC timer on x86_64)
2. Create kernel timer queue (ordered by expiration time)
3. On tick, walk queue and deliver SIGALRM to expired processes
4. Use signal delivery mechanism in `signals.zig`

**Priority:** Medium - Many POSIX programs need this.

---

### Symlinks Not Implemented

**Feature Gap:** Symbolic links (soft links) not supported

**Files:** `src/fs/vfs.zig`

**Impact:**
- Cannot create or follow symlinks
- Tests involving symlinks skip
- Some Unix tools expect symlink support

**Why Not Yet:**
- Adds complexity to path resolution (must follow links)
- Requires TOCTOU protection (symlink target could change)
- Not critical for embedded systems (most use cases covered by hardlinks)

**Fix Approach:**
1. Add symlink entry type to VFS
2. Implement readlink syscall
3. Add symlink following to path resolution
4. Add TOCTOU protection (bounded follow count)

**Priority:** Low - Feature-complete without symlinks for embedded.

---

### SysV IPC Not Implemented (Blocked)

**Feature Gap:** Shared memory, semaphores, message queues

**Files:** None - not yet implemented

**Impact:**
- Cannot use legacy IPC (PostgreSQL, Redis compatibility)
- Some distributed systems software unavailable
- Tests for IPC missing

**Blocking Issue:** SFS capacity limited to 64 files. SysV IPC needs persistent storage that would quickly exhaust SFS. Must increase SFS capacity first.

**Fix Sequence:**
1. Increase SFS to 128+ file capacity
2. Implement shared memory (shmget/shmat/shmdt)
3. Implement semaphores (semget/semop/semctl)
4. Implement message queues (msgget/msgsnd/msgrcv)

**Priority:** Low - Not required for microkernel core. Design target is embedded systems.

---

### User/Group IDs (Partial)

**Feature Gap:** UID/GID syscalls partially implemented

**Files:** `src/kernel/sys/syscall/process/process.zig`

**What's Implemented:**
- getuid/setuid (basic)
- getgid/setgid (basic)

**What's Missing:**
- setreuid/setregid (set real/effective separately)
- getgroups/setgroups (supplementary groups)
- setfsuid/setfsgid (filesystem UID for permission checks)

**Impact:** Limited privilege dropping for setuid programs.

**Priority:** Low - Can work around with getuid/setuid.

---

## Test Coverage Gaps

### Socket/Network Syscalls Untested (Critical Gap)

**What's Not Tested:** All socket syscalls

**Files:** `src/user/test_runner/tests/syscall/sockets.zig` (8 tests written but disabled)

**Risk:**
- Socket syscalls could have critical bugs
- No regression tests to prevent breakage
- Network features untested despite 190 syscalls implemented

**Blocker:** Kernel panic on socket creation (IrqLock not initialized)

**How to Unblock:**
1. Fix kernel initialization order
2. Re-enable socket tests
3. Target: 8+ socket tests passing

---

### Signal Handling Edge Cases

**What's Not Tested:** Signal delivery race conditions

**Files:** `src/kernel/sys/syscall/process/signals.zig` (6 signal tests written, marked architecture-specific)

**Risk:**
- Signal delivery has known race conditions (per CLAUDE.md)
- Edge cases between signal mask changes and delivery untested
- aarch64 signal delivery not thoroughly tested

**Coverage:** 6 tests written, some marked complex.

---

### aarch64-Specific Edge Cases

**What's Not Tested:** aarch64-specific exception handling corner cases

**Files:**
- `src/arch/aarch64/kernel/interrupts/root.zig` (exception handlers)

**Risk:**
- aarch64 has different exception model than x86_64
- Page fault handling differs (ESR vs error code)
- Data abort fixup handler recently added (could have bugs)

**Coverage:** 166 tests pass on aarch64, but signal/exception tests few.

---

### Memory Protection Edge Cases

**What's Not Tested:** PAGE_NONE, mixing PROT_EXEC with other flags

**Files:** `src/user/test_runner/tests/syscall/memory.zig` (7 memory tests, some skip on specific flag combinations)

**Risk:**
- Unusual flag combinations could cause kernel crash
- Page protection checks might not cover all cases

**Coverage:** 7/10 memory tests passing, 3 skip on complex cases.

---

## Incomplete Implementations

### HGFS (Hypervisor Guest Filesystem) - Stubs Only

**Status:** Placeholder, not functional

**Files:** `src/fs/hgfs.zig` (550 lines)

**Implemented:**
- Device enumeration
- Type checking

**Missing:**
- rename() - `// TODO: Implement rename`
- truncate() - `// TODO: Implement truncate`
- symlink() - `// TODO: Implement symlink`
- readlink() - `// TODO: Implement readlink`

**Impact:** HGFS unavailable as filesystem option.

**Priority:** Low - Requires VMware Tools integration.

---

### VirtIO Console Driver - Partial

**Status:** Incomplete

**Files:** `src/user/drivers/virtio_console/main.zig` (208 lines)

**Missing:**
- Proper virtqueue polling - `// TODO: Implement proper virtqueue polling`
- Proper virtqueue submission - `// TODO: Implement proper virtqueue submission`

**Impact:** Serial console may not work reliably on VirtIO.

**Priority:** Medium - Affects user I/O.

---

### VirtIO Balloon Driver - Stubs

**Status:** Completely unimplemented

**Files:** `src/user/drivers/virtio_balloon/main.zig`

**Missing:**
- Inflate queue - `// TODO: Allocate pages from kernel and submit to inflate queue`
- Deflate queue - `// TODO: Submit page addresses to deflate queue and free them`
- Full initialization - `// TODO: Implement full initialization with queue setup`

**Impact:** Cannot use balloon driver for memory hotplug.

**Priority:** Low - Feature not critical.

---

### Network Features - IPv6, NDP

**Status:** Partially implemented

**Files:**
- `src/net/ipv6/ndp/process.zig` (Neighbor Discovery)
- `src/net/ipv6/ipv6/transmit.zig` (IPv6 transmission)

**Missing:**
- Redirect processing - `// TODO: Implement redirect processing`
- Path MTU discovery - `// TODO: Phase 5`

**Impact:** IPv6 connectivity limited.

**Priority:** Low - IPv4 fully functional.

---

## Architectural Concerns

### Tight Coupling Between Scheduler and Timer

**Problem:** Timer interrupt directly invokes scheduler without queue.

**Files:**
- `src/arch/x86_64/kernel/idt.zig` (timer handler registration)
- `src/kernel/proc/sched/scheduler.zig` (scheduling logic)

**Risk:**
- Timer ISR must complete within tight deadline
- Complex scheduler logic in interrupt context
- Cannot use locks that might sleep

**Impact:**
- Scheduler must be very fast
- Complex timer handling code cannot block
- Difficult to add debugging/monitoring

**Better Architecture:**
1. Timer ISR sets a flag
2. Main loop polls flag and runs scheduler
3. Allows proper synchronization

**Priority:** Low - Works but could be cleaner.

---

### Global Network Lock Contention

**Problem:** Global `tcp_state.lock` serializes TCP operations.

**Files:** `src/net/transport/tcp/state.zig`

**Impact:**
- All TCP connections competing for single lock
- Doesn't scale beyond ~4 cores
- Network performance degrades with CPU count

**Better Architecture:**
1. Per-connection locks (local to TCB)
2. Lock-free hashtable for connection lookup
3. Read-write locks for shared state

**Priority:** Low - Works for embedded systems.

---

### Test Infrastructure QEMU Timeout Issues

**Problem:** QEMU doesn't auto-exit after test_runner completes.

**Files:**
- `scripts/run_tests.sh` (test runner script)
- `src/user/test_runner/main.zig` (test harness)

**Impact:**
- CI scripts rely on 60s timeout to exit
- Script reports timeout even on success
- Makes CI output less clear

**Fix Approach:**
1. Implement proper QEMU shutdown on test completion
2. Or use QEMU exit status to detect completion
3. Or call sys_exit() at end of tests

**Priority:** Low - Works but output unclear.

---

## Summary of Risk Levels

**Critical (Blocks Development):**
- Socket tests panic (kernel initialization bug)

**High (Should Fix Soon):**
- SFS close deadlock (50+ operations)
- aarch64 architecture test parity (some drivers x86_64 only)

**Medium (Track Closely):**
- SFS capacity limit (64 files)
- Capability system name-based grants
- Signal handling race conditions
- Zig compiler nightly dependency

**Low (Monitor, Nice to Have):**
- Other performance optimizations
- Incomplete drivers (HGFS, balloon)
- Missing feature implementations (symlinks, SysV IPC)

---

*Concerns audit: 2026-02-06*
