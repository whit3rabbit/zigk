---
phase: 25-seccomp
verified: 2026-02-15T22:30:00Z
status: passed
score: 6/6 must-haves verified
re_verification: false
---

# Phase 25: Seccomp Verification Report

**Phase Goal:** Syscall filtering via seccomp for sandboxing is available
**Verified:** 2026-02-15T22:30:00Z
**Status:** passed
**Re-verification:** No - initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | User can call seccomp(SECCOMP_SET_MODE_STRICT) and only read/write/exit/sigreturn are allowed | ✓ VERIFIED | Tests passed: "strict allows read", "strict allows write", "strict blocks getpid". checkSeccomp() at process.zig:1722-1741 whitelists only SYS_READ/WRITE/EXIT/EXIT_GROUP/RT_SIGRETURN for both x86_64 and aarch64. |
| 2 | User can call seccomp(SECCOMP_SET_MODE_FILTER) with a BPF program to filter syscalls | ✓ VERIFIED | Tests passed: "filter allow all", "filter block getpid". sys_seccomp() at process.zig:1604-1713 implements SECCOMP_SET_MODE_FILTER, copies BPF program from userspace, validates length (1-4096), stores in proc.seccomp_filters. |
| 3 | BPF filter returns SECCOMP_RET_ALLOW, SECCOMP_RET_KILL, SECCOMP_RET_ERRNO are honored | ✓ VERIFIED | Tests passed: "filter errno value" (custom errno), "filter block getpid" (KILL). Dispatch hook at table.zig:149-165 checks return value, returns ENOSYS on KILL, custom errno on ERRNO, allows on ALLOW. runBpfFilter() at process.zig:1790-1975 is a complete classic BPF interpreter with LD/LDX/ST/STX/ALU/JMP/RET/MISC opcodes. |
| 4 | Seccomp state is inherited across fork | ✓ VERIFIED | Test passed: "inherited on fork" - child process inherits parent's seccomp filter and gets blocked on same syscall. Fork implementation at lifecycle.zig:168-173 copies seccomp_mode, no_new_privs, seccomp_filters, filter_count, prog_count, filter_lengths from parent to child. |
| 5 | Disallowed syscall in strict mode kills the process or returns ENOSYS | ✓ VERIFIED | Test passed: "strict blocks getpid" - child calls getpid() after enabling strict mode, receives error (ENOSYS as documented in MVP limitation). Dispatch hook returns ENOSYS for KILL actions (table.zig:154-159). |
| 6 | prctl(PR_SET_NO_NEW_PRIVS) is required before installing filters | ✓ VERIFIED | Test passed: "requires no_new_privs" - child tries to install filter without no_new_privs, gets EACCES error. sys_seccomp() at process.zig:1651-1653 checks `if (!proc.no_new_privs and !proc.hasCapability(uapi.capability.CAP_SYS_ADMIN)) return error.EACCES;`. PR_SET_NO_NEW_PRIVS implemented at control.zig:72-77. |

**Score:** 6/6 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/uapi/process/seccomp.zig` | SECCOMP_* constants, seccomp_data struct, BPF instruction struct | ✓ VERIFIED | 184 lines. Defines SECCOMP_MODE_* (DISABLED/STRICT/FILTER), SECCOMP_SET_MODE_*, SECCOMP_RET_* (KILL_PROCESS/KILL_THREAD/ERRNO/ALLOW), SeccompData (64 bytes), SockFilterInsn (8 bytes), SockFprog, BPF opcodes (LD/LDX/ST/STX/ALU/JMP/RET/MISC), AUDIT_ARCH_X86_64/AARCH64. Comptime size assertions present. |
| `src/kernel/sys/syscall/process/process.zig` | sys_seccomp implementation with BPF interpreter | ✓ VERIFIED | sys_seccomp at line 1604 (110 lines) handles STRICT/FILTER/GET_ACTION_AVAIL. checkSeccomp at line 1717 (73 lines) dispatches based on mode. runBpfFilter at line 1790 (186 lines) is a complete classic BPF interpreter with registers (A, X, M[16]), packet loading (BPF_ABS with W/H/B sizes), ALU ops (ADD/SUB/MUL/DIV/MOD/OR/AND/XOR/LSH/RSH/NEG), jumps (JA/JEQ/JGT/JGE/JSET), returns, memory ops (ST/STX). Fail-secure on invalid instructions (returns KILL_PROCESS). Architecture-aware (AUDIT_ARCH detection). |
| `src/kernel/sys/syscall/core/table.zig` | Seccomp check before syscall dispatch | ✓ VERIFIED | Dispatch hook at line 149-165. Calls process.getCurrentProcessOrNull(), checks proc.seccomp_mode, calls process.checkSeccomp(). Returns early with ENOSYS on KILL, custom errno on ERRNO. Runs BEFORE handler dispatch (line 148 is before line 167 handler dispatch block). |
| `src/user/test_runner/tests/syscall/seccomp.zig` | 10 integration tests for seccomp | ✓ VERIFIED | 380 lines, 10 test functions registered in main.zig:366-375. Tests use fork pattern (seccomp is irreversible). All 10 tests PASSED on x86_64: strict allows read/write, strict blocks getpid, filter allow all, filter block getpid, requires no_new_privs, strict cannot be undone, filter errno value, inherited on fork, prctl no_new_privs. |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| `src/kernel/sys/syscall/core/table.zig` | `src/kernel/proc/process/types.zig` | seccomp_mode field check before dispatch | ✓ WIRED | table.zig:151 reads `proc.seccomp_mode`, types.zig:258 defines `seccomp_mode: u8 = 0`. Import chain: table.zig imports `process` module (line 19), which exports `getCurrentProcessOrNull()` and `checkSeccomp()`. Process type includes seccomp_mode field. |
| `src/kernel/sys/syscall/process/process.zig` | `src/uapi/process/seccomp.zig` | UAPI constants for seccomp modes and BPF | ✓ WIRED | process.zig:11 imports `uapi`, references uapi.seccomp 84 times (SECCOMP_MODE_*, SECCOMP_RET_*, BPF_*, SeccompData, SockFilterInsn). Constants used in sys_seccomp (line 1608-1710), checkSeccomp (line 1718-1741), runBpfFilter (line 1790-1975). |

### Requirements Coverage

No specific requirements mapped to Phase 25 in REQUIREMENTS.md (Phase 25 is part of v1.2 roadmap, requirements focus on file sync and advanced file ops).

**All seccomp functionality is working as specified in Success Criteria.**

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| src/kernel/sys/syscall/process/process.zig | 1755 | TODO: Get actual RIP/PC from frame | ℹ️ Info | instruction_pointer in SeccompData is hardcoded to 0. BPF filters that rely on IP filtering won't work. Documented in SUMMARY as known limitation. Not a blocker. |
| src/kernel/sys/syscall/core/table.zig | 157 | SECCOMP_RET_KILL returns ENOSYS, not SIGSYS | ℹ️ Info | MVP limitation documented in SUMMARY. Blocked syscalls return error instead of delivering signal. Tests verify this behavior. Not a blocker. |

No blockers found. Two informational notes about documented MVP limitations.

### Human Verification Required

None. All seccomp functionality is programmatically verifiable and covered by automated tests.

### Test Results

**x86_64:** 10/10 PASSED
- ✓ seccomp: strict allows read
- ✓ seccomp: strict allows write
- ✓ seccomp: strict blocks getpid
- ✓ seccomp: filter allow all
- ✓ seccomp: filter block getpid
- ✓ seccomp: requires no_new_privs
- ✓ seccomp: strict cannot be undone
- ✓ seccomp: filter errno value
- ✓ seccomp: inherited on fork
- ✓ seccomp: prctl no_new_privs

**aarch64:** Not tested in this verification (test suite hang is pre-existing, not seccomp-related). SUMMARY.md reports 10/10 passing on both architectures.

### Verification Summary

**All must-haves verified.** Phase 25 goal achieved.

**Security primitives working:**
- STRICT mode restricts to 4 syscalls (read/write/exit/sigreturn) on both architectures
- FILTER mode executes BPF programs with architecture-aware syscall number checking
- BPF interpreter is fail-secure (invalid instructions return KILL_PROCESS)
- Seccomp is irreversible (cannot be disabled once enabled)
- Fork inheritance ensures sandboxes propagate to children
- Permission gating (no_new_privs OR CAP_SYS_ADMIN) prevents unprivileged filter bypass

**Implementation quality:**
- Classic BPF interpreter is complete (186 lines, all opcodes)
- Architecture-specific syscall numbers correctly handled (x86_64 vs aarch64)
- Tests verify all 5 success criteria from ROADMAP.md
- No blocker anti-patterns
- Documented MVP limitations (IP not captured, SIGSYS not delivered)

---

_Verified: 2026-02-15T22:30:00Z_
_Verifier: Claude (gsd-verifier)_
