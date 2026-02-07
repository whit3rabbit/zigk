---
phase: 02-credentials-ownership
plan: 02
subsystem: process-credentials
tags: [setreuid, setregid, getgroups, setgroups, setfsuid, setfsgid, posix, linux-abi, syscalls]

# Dependency graph
requires:
  - phase: 02-01
    provides: fsuid/fsgid infrastructure, syscall numbers, auto-sync
provides:
  - 6 credential management syscalls (setreuid, setregid, getgroups, setgroups, setfsuid, setfsgid)
  - POSIX-compliant atomic UID/GID updates
  - Supplementary group management with capability enforcement
affects: [credential-checks, file-permissions, process-security]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "setfs* syscalls return previous value, not 0/-errno (Linux ABI)"
    - "UNCHANGED constant (0xFFFFFFFF) for selective credential updates"
    - "cred_lock for atomic credential modifications"

key-files:
  created: []
  modified:
    - src/kernel/sys/syscall/process/process.zig

key-decisions:
  - "setfsuid/setfsgid return previous value even on 'failure' (Linux ABI, not POSIX)"
  - "setreuid/setregid follow POSIX saved-set-user-ID rule (if ruid set, suid = new euid)"
  - "All credential modifications use cred_lock to prevent TOCTOU races"

patterns-established:
  - "setreuid/setregid: POSIX semantics with privilege checks matching setresuid/setresgid"
  - "getgroups/setgroups: supplementary group management with 16-entry limit"
  - "setfsuid/setfsgid: Linux-specific, returns old value, never errors"

# Metrics
duration: 4min
completed: 2026-02-07
---

# Phase 02 Plan 02: Credential Syscalls Summary

**6 credential management syscalls with POSIX atomic UID/GID updates and Linux-compatible filesystem identity overrides**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-07T02:57:02Z
- **Completed:** 2026-02-07T03:01:13Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments

- Implemented setreuid/setregid with POSIX saved-set-user-ID semantics
- Implemented getgroups/setgroups for supplementary group management
- Implemented setfsuid/setfsgid with Linux-specific return value convention
- All syscalls use cred_lock for atomic credential modifications
- Auto-sync fsuid/fsgid on euid/egid changes in setreuid/setregid

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement setreuid, setregid, setfsuid, setfsgid** - `c3b43e5` (feat)
2. **Task 2: Implement getgroups and setgroups** - `1afb636` (feat)

## Files Created/Modified

- `src/kernel/sys/syscall/process/process.zig` - Added 6 credential syscall handlers (284 lines total)

## Decisions Made

**1. setfsuid/setfsgid return previous value, not error**
- Linux ABI requires these syscalls to ALWAYS return the previous fsuid/fsgid value
- On permission failure, they return the old value without changing it
- This differs from standard POSIX syscalls that return 0/-errno
- Rationale: Matches Linux kernel behavior exactly for compatibility

**2. POSIX saved-set-user-ID rule for setreuid/setregid**
- If ruid is set, OR if euid is set to a value != old ruid, then suid = new euid
- This implements the POSIX privilege-dropping semantics correctly
- Enables processes to permanently drop privileges by setting all three UIDs

**3. Supplementary groups limited to 16**
- Process struct has fixed-size [16]u32 supplementary_groups array
- setgroups returns EINVAL if size > 16
- Matches Linux NGROUPS_MAX historical limit (modern kernels allow 65536, but 16 is sufficient for MVP)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

**Ready for:**
- Plan 02-03: File ownership syscalls (chown, fchown, lchown) can use fsuid/fsgid
- Plan 02-04: Capability management can leverage credential checking patterns
- File permission checks can now use supplementary groups for ACLs

**No blockers.**

## Self-Check: PASSED

---
*Phase: 02-credentials-ownership*
*Completed: 2026-02-07*
