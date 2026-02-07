---
phase: 02-credentials-ownership
plan: 01
subsystem: credentials
tags: [fsuid, fsgid, process, permissions, syscalls, credentials, posix]

# Dependency graph
requires:
  - phase: 01-quick-wins-trivial-stubs
    provides: Basic process structure and syscall infrastructure
provides:
  - fsuid/fsgid fields in Process struct for filesystem-specific credentials
  - Updated permission checking to use fsuid/fsgid instead of euid/egid
  - Syscall numbers defined for setreuid, setregid, getgroups, setgroups, setfsuid, setfsgid (both architectures)
  - Auto-sync mechanism in existing credential syscalls (setuid/setgid/setresuid/setresgid)
  - Userspace wrappers for all new credential and chown syscalls
affects: [02-02, 02-03, 02-04, 02-05, 02-06, 02-07, 02-08, 02-09, 02-10, phase-03, phase-04]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "fsuid/fsgid auto-sync pattern: credential syscalls that modify euid/egid automatically update fsuid/fsgid"
    - "Filesystem permission checks use fsuid/fsgid instead of euid/egid per POSIX standard"

key-files:
  created: []
  modified:
    - src/kernel/proc/process/types.zig
    - src/kernel/proc/perms.zig
    - src/uapi/syscalls/linux.zig
    - src/uapi/syscalls/linux_aarch64.zig
    - src/uapi/syscalls/root.zig
    - src/kernel/sys/syscall/process/process.zig
    - src/user/lib/syscall/process.zig

key-decisions:
  - "fsuid/fsgid replace euid/egid only in filesystem permission checks (open, access, stat, chown), not signal delivery or ptrace"
  - "Auto-sync fsuid/fsgid whenever euid/egid changes to maintain default POSIX behavior"
  - "Syscall numbers follow standard Linux ABI values (x86_64 and aarch64 have different numbering)"

patterns-established:
  - "Auto-sync pattern: All credential syscalls that modify euid must also update fsuid"
  - "Permission checking isolation: Filesystem ops use fsuid/fsgid, other ops use euid/egid"

# Metrics
duration: 5min
completed: 2026-02-07
---

# Phase 2 Plan 1: Infrastructure Summary

**fsuid/fsgid credentials added to Process struct with auto-sync from euid/egid and updated filesystem permission checking**

## Performance

- **Duration:** 5 min
- **Started:** 2026-02-07T02:49:12Z
- **Completed:** 2026-02-07T02:54:14Z
- **Tasks:** 2
- **Files modified:** 7

## Accomplishments
- Added fsuid/fsgid fields to Process struct for POSIX-compliant filesystem permission checking
- Updated perms.zig to use fsuid instead of euid for all filesystem permission checks (root bypass, owner matching)
- Defined syscall numbers for 6 new credential syscalls on both x86_64 and aarch64 with no collisions
- Implemented auto-sync mechanism in sys_setuid, sys_setgid, sys_setresuid, sys_setresgid to keep fsuid/fsgid in sync with euid/egid
- Created userspace wrappers for all new credential syscalls plus chown family

## Task Commits

Each task was committed atomically:

1. **Task 1: Add fsuid/fsgid to Process struct and update perms.zig** - `5afefae` (feat)
2. **Task 2: Add syscall numbers, auto-sync, and userspace wrappers** - `0d08294` (feat)

## Files Created/Modified
- `src/kernel/proc/process/types.zig` - Added fsuid/fsgid fields (auto-sync with euid/egid)
- `src/kernel/proc/perms.zig` - Updated checkAccess and checkCreatePermission to use fsuid instead of euid
- `src/uapi/syscalls/linux.zig` - Added SYS_SETREUID (113), SYS_SETREGID (114), SYS_GETGROUPS (115), SYS_SETGROUPS (116), SYS_SETFSUID (122), SYS_SETFSGID (123)
- `src/uapi/syscalls/linux_aarch64.zig` - Added SYS_SETREGID (143), SYS_SETREUID (145), SYS_SETFSUID (151), SYS_SETFSGID (152), SYS_GETGROUPS (158), SYS_SETGROUPS (159)
- `src/uapi/syscalls/root.zig` - Re-exported all 6 new syscall numbers
- `src/kernel/sys/syscall/process/process.zig` - Added fsuid/fsgid auto-sync in sys_setuid, sys_setgid, sys_setresuid, sys_setresgid
- `src/user/lib/syscall/process.zig` - Added userspace wrappers for setreuid, setregid, getgroups, setgroups, setfsuid, setfsgid, chown, fchown, lchown, fchownat

## Decisions Made
- **fsuid/fsgid scope**: Used only for filesystem permission checks (open, access, stat, chown). Other operations (signal delivery, ptrace, capability checks) continue using euid/egid. This matches standard POSIX behavior where fsuid/fsgid are a specialized mechanism for NFS server delegation and setuid programs.
- **Auto-sync by default**: When euid/egid changes, fsuid/fsgid automatically update unless explicitly overridden by setfsuid/setfsgid. This maintains POSIX compatibility where most programs never call setfsuid and expect fsuid == euid.
- **Syscall numbering**: Followed standard Linux ABI values for both architectures. No compat range needed for aarch64 as these syscalls exist in the standard aarch64 ABI.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None - both architectures compiled successfully, all existing tests pass.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

Ready for Phase 2 credential syscall implementations:
- fsuid/fsgid infrastructure complete and tested
- Syscall numbers defined with no collisions
- Auto-sync mechanism working
- Userspace wrappers ready for test usage
- All existing tests still passing (166+ tests)

**Blocker status:** None

---
*Phase: 02-credentials-ownership*
*Completed: 2026-02-07*

## Self-Check: PASSED

All commits verified to exist in git history.
