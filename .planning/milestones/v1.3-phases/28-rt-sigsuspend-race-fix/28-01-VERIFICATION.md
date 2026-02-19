---
phase: 28-rt-sigsuspend-race-fix
verified: 2026-02-16T00:00:00Z
status: passed
score: 3/3 must-haves verified
re_verification: false
---

# Phase 28: rt_sigsuspend Race Fix Verification Report

**Phase Goal:** Fix race condition where pending signals are not delivered when rt_sigsuspend atomically restores signal mask
**Verified:** 2026-02-16T00:00:00Z
**Status:** passed
**Re-verification:** No - initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|---------|----------|
| 1 | rt_sigsuspend delivers signals that were pending before the mask was restored | ✓ VERIFIED | sys_rt_sigsuspend sets temp mask, saves old mask in saved_sigmask, defers restoration until after checkSignalsOnSyscallExit runs (signals.zig:274-275). checkSignalsOnSyscallExit checks pending with temp mask active (signal.zig:340), delivers via setupSignalFrameForSyscall, restores mask in defer block (signal.zig:328-333) |
| 2 | rt_sigsuspend correctly blocks until a signal is delivered | ✓ VERIFIED | sys_rt_sigsuspend checks for pending unblocked signals (signals.zig:261-267). If none pending, calls sched.block() to suspend thread. Returns EINTR when woken by signal delivery (signals.zig:278) |
| 3 | Test demonstrates signal delivery during mask restoration works reliably on both architectures | ✓ VERIFIED | testRtSigsuspendBasic (signals.zig:500-559) blocks SIGUSR1, sends it (pending), calls rt_sigsuspend with empty mask (unblocks), verifies handler was called and EINTR returned. Test is substantive with complete flow validation |

**Score:** 3/3 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/kernel/proc/thread.zig` | saved_sigmask and has_saved_sigmask fields on Thread | ✓ VERIFIED | Lines 113-117: saved_sigmask (SigSet), has_saved_sigmask (bool) with proper documentation. Fields initialized to 0/false |
| `src/kernel/sys/syscall/process/signals.zig` | Race-free sys_rt_sigsuspend that defers mask restoration | ✓ VERIFIED | Lines 231-279: sys_rt_sigsuspend sets temp mask, saves old mask in saved_sigmask/has_saved_sigmask, blocks if needed, returns EINTR. NO restoration before return (removed the bug at old line 276) |
| `src/kernel/proc/signal.zig` | checkSignalsOnSyscallExit restores saved mask after signal delivery | ✓ VERIFIED | Lines 322-388: defer block at function entry (328-333) restores saved_sigmask AFTER all signal delivery logic. setupSignalFrameForSyscall uses saved_sigmask in ucontext (lines 255, 245, 473, 468) and clears has_saved_sigmask (lines 307-309, 530-532) |
| `src/user/test_runner/tests/syscall/signals.zig` | Un-skipped rt_sigsuspend test that validates race-free delivery | ✓ VERIFIED | Lines 500-559: testRtSigsuspendBasic is a complete test (59 lines) with setup, signal blocking, kill, rt_sigsuspend call, EINTR verification, handler invocation check, and cleanup. Not a placeholder |

### Key Link Verification

| From | To | Via | Status | Details |
|------|-----|-----|--------|---------|
| sys_rt_sigsuspend | Thread.saved_sigmask | Write to saved_sigmask field | ✓ WIRED | signals.zig:274-275 writes old_mask to current_thread.saved_sigmask and sets has_saved_sigmask = true |
| checkSignalsOnSyscallExit | Thread.saved_sigmask | Restoration in defer block | ✓ WIRED | signal.zig:329-331 reads has_saved_sigmask, restores from saved_sigmask, clears flag in defer block (runs after signal delivery) |
| setupSignalFrameForSyscall | Thread.saved_sigmask | ucontext.sigmask conditional assignment | ✓ WIRED | signal.zig:255, 473 use ternary to write saved_sigmask (if has_saved_sigmask) or current sigmask into ucontext. Also mcontext.oldmask uses saved mask (245, 468) |

**Critical Fix Verified:** dispatch_syscall skips setReturnSigned for SYS_RT_SIGRETURN (table.zig:188-190). This prevents clobbering the restored rax value from rt_sigreturn's ucontext, which would make rt_sigsuspend appear to succeed instead of returning -EINTR.

### Requirements Coverage

| Requirement | Status | Blocking Issue |
|-------------|--------|----------------|
| SIG-01: rt_sigsuspend correctly delivers pending signals without race condition | ✓ SATISFIED | All supporting truths verified. Deferred mask restoration pattern implemented correctly. rt_sigreturn rax clobber bug fixed in dispatch_syscall |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| signals.zig | 425, 465 | TODO comments about CAP_KILL capability | ℹ️ Info | Pre-existing capability system notes. Not blockers for this phase. No impact on rt_sigsuspend race fix |

**No blocking anti-patterns detected.**

### Human Verification Required

**None.** All observable truths can be verified programmatically through code inspection:
1. Mask restoration logic is explicit in defer block
2. Signal delivery timing is deterministic (temp mask active during checkSignalsOnSyscallExit)
3. Test validates the complete flow end-to-end

The test suite provides automated validation on both architectures (testRtSigsuspendBasic runs on x86_64 and aarch64).

### Gaps Summary

**No gaps found.** All must-haves verified:
- Thread struct has saved_sigmask fields (artifact level 1: exists)
- Fields are substantive (not stubs) with proper initialization and documentation (level 2)
- sys_rt_sigsuspend writes to saved_sigmask and defers restoration (level 3: wired)
- checkSignalsOnSyscallExit reads saved_sigmask and restores in defer block (level 3: wired)
- setupSignalFrameForSyscall uses saved_sigmask in ucontext construction (level 3: wired)
- Test is complete with proper signal blocking, pending delivery, EINTR verification
- dispatch_syscall correctly skips rt_sigreturn to preserve restored frame state

**Implementation Quality:**
- Follows Linux kernel's deferred mask restoration pattern
- Proper atomic operations for pending_signals visibility
- Complete error handling (EINVAL for wrong sigsetsize, EFAULT for bad mask_ptr)
- Documented with clear comments explaining the race fix
- Both interrupt and syscall signal delivery paths updated (checkSignals and checkSignalsOnSyscallExit)

**Commits Verified:**
- b1da1fc: Fix rt_sigsuspend mask restoration race (Task 1)
- e669aa9: Fix rt_sigreturn rax clobber and un-skip test (Task 2)

Both commits exist in git history and map to the documented task structure.

---

_Verified: 2026-02-16T00:00:00Z_
_Verifier: Claude (gsd-verifier)_
