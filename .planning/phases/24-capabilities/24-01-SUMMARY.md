---
phase: 24-capabilities
plan: 01
subsystem: kernel, syscall, process
tags: [capabilities, capget, capset, posix, linux-abi, security]

# Dependency graph
requires:
  - phase: 23-posix-timers
    provides: "Process struct with per-process fields, syscall dispatch infrastructure"
provides:
  - "Linux-compatible capget/capset syscalls (SYS_CAPGET=125/90, SYS_CAPSET=126/91)"
  - "UAPI capability types (CapUserHeader, CapUserData, 41 CAP_* constants)"
  - "Per-process capability bitmasks (cap_effective, cap_permitted, cap_inheritable)"
  - "Fork-inherited capability sets"
  - "Userspace capget/capset wrappers"
affects: [future privilege-dropping, exec-time capability transformation, seccomp integration]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Linux capability v1/v3 version negotiation pattern"
    - "Monotonically decreasing permitted set (security invariant)"
    - "UAPI types in src/uapi/process/ accessible via uapi.capability"

key-files:
  created:
    - src/uapi/process/capability.zig
    - src/user/test_runner/tests/syscall/capabilities.zig
  modified:
    - src/kernel/proc/process/types.zig
    - src/kernel/proc/process/lifecycle.zig
    - src/kernel/sys/syscall/process/process.zig
    - src/uapi/root.zig
    - src/user/lib/syscall/process.zig
    - src/user/lib/syscall/root.zig
    - src/user/test_runner/main.zig

key-decisions:
  - "UAPI types registered via uapi/root.zig (uapi.capability) rather than separate build module -- avoids build.zig complexity"
  - "Default CAP_FULL_SET (bits 0-40) for all processes since all run as root (uid=0)"
  - "Inheritable set starts empty (Linux convention) -- prevents unintended capability leakage across execve"
  - "No new dispatch table module -- functions added to existing process.zig module to avoid stack growth risk"
  - "findProcessByPidForCaps uses read lock on process_tree_lock (priority 1) for cross-process capget queries"

patterns-established:
  - "Capability security invariant: new_perm must be subset of old_perm (irreversible drop)"
  - "Version negotiation: invalid version writes preferred version back to userspace and returns EINVAL"

# Metrics
duration: 8min
completed: 2026-02-16
---

# Phase 24 Plan 01: Capability Syscalls Summary

**Linux-compatible capget/capset syscalls with per-process effective/permitted/inheritable bitmasks supporting v1 (32-bit) and v3 (64-bit) header formats**

## Performance

- **Duration:** 8 min
- **Started:** 2026-02-16T00:12:17Z
- **Completed:** 2026-02-16T00:20:04Z
- **Tasks:** 2
- **Files modified:** 9

## Accomplishments
- 2 new kernel syscalls (sys_capget, sys_capset) auto-registered via dispatch table
- UAPI types: CapUserHeader, CapUserData, 41 CAP_* constants (0-40) with correct Linux values
- Per-process capability bitmasks (cap_effective, cap_permitted, cap_inheritable) in Process struct
- v1 (32-bit single data struct) and v3 (64-bit two data structs) format support
- Security rules: effective subset of permitted, permitted monotonically decreasing, inheritable bounded by permitted|inheritable
- Fork copies capability bitmasks from parent to child
- 10 integration tests passing on x86_64, both architectures build cleanly

## Task Commits

Each task was committed atomically:

1. **Task 1: Create capability UAPI types, add per-process bitmasks, implement sys_capget and sys_capset** - `10b4291` (feat)
2. **Task 2: Add userspace wrappers and integration tests** - `8f7ba42` (feat)

## Files Created/Modified
- `src/uapi/process/capability.zig` - Linux capability UAPI types, 41 CAP_* constants, CapUserHeader/CapUserData structs
- `src/kernel/proc/process/types.zig` - Added cap_effective/cap_permitted/cap_inheritable u64 fields to Process
- `src/kernel/proc/process/lifecycle.zig` - Fork inherits capability bitmasks from parent to child
- `src/kernel/sys/syscall/process/process.zig` - sys_capget and sys_capset implementations with security rules
- `src/uapi/root.zig` - Registered capability module as uapi.capability
- `src/user/lib/syscall/process.zig` - Userspace capget/capset wrappers and capability constants
- `src/user/lib/syscall/root.zig` - Re-exported capability functions and key constants
- `src/user/test_runner/tests/syscall/capabilities.zig` - 10 integration tests
- `src/user/test_runner/main.zig` - Test registration

## Decisions Made
- Used existing uapi module path (uapi.capability) instead of creating a separate build module -- keeps build.zig clean and consistent with other UAPI submodules
- Default capability values are CAP_FULL_SET (bits 0-40) for effective and permitted, 0 for inheritable -- matches Linux root behavior since all zk processes run as uid=0
- Functions added to existing process.zig syscall module rather than creating new module -- avoids dispatch table growth and potential stack overflow per MEMORY.md guidance
- Cross-process capget uses findProcessByPidForCaps (separate from process_mod.findProcessByPid) to limit scope to children and parent

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Capability subsystem complete and tested
- Ready for future privilege-dropping workflows (exec-time capability transformation)
- Foundation in place for integrating POSIX capabilities with zk's existing hardware capability system

## Self-Check: PASSED

All 9 files verified present. Both commit hashes (10b4291, 8f7ba42) verified in git log.

---
*Phase: 24-capabilities*
*Completed: 2026-02-16*
