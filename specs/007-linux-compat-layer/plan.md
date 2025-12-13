# Implementation Plan: Linux Compatibility Layer - Runtime Infrastructure

**Branch**: `007-linux-compat-layer` | **Date**: 2025-12-05 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/007-linux-compat-layer/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

Implement Linux runtime infrastructure for complete userland compatibility: pre-opened standard file descriptors (0, 1, 2), wait4 syscall for shell process control, clock_gettime for timekeeping, and getrandom for entropy/hash map seeding. This complements specs 005-linux-syscall-compat and 006-sysv-abi-init to enable running standard C and Zig programs on Zscapek.

## Technical Context

**Language/Version**: Zig 0.15.x (freestanding x86_64 target)
**Primary Dependencies**: Limine bootloader v7.x+, limine-zig bindings
**Storage**: N/A (InitRD via Limine Modules for file access)
**Testing**: QEMU x86_64 verification, static C/Zig test binaries
**Target Platform**: x86_64 freestanding (bare-metal kernel)
**Project Type**: Single kernel project
**Performance Goals**: clock_gettime within 10% accuracy, wait4 latency <1ms
**Constraints**: No standard library, no libc, freestanding environment only
**Scale/Scope**: 4 new syscalls (wait4, clock_gettime, getrandom) + FD table initialization

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Principle I: Bare-Metal Zig ✅ PASS
- All code will be written in Zig targeting freestanding x86_64
- No external dependencies beyond Limine protocol
- Inline assembly only for: RDRAND/RDTSC (entropy), WRMSR (TSC calibration if needed)

### Principle II: Limine Protocol Compliance ✅ PASS
- Boot time resources (memory map, HHDM) already provided by Limine
- No new Limine requests required for this feature
- Framebuffer/Console output uses existing Limine framebuffer response

### Principle III: Minimal Viable Kernel ✅ PASS
- Each syscall is independently testable
- Pre-opened FDs can be tested with simple write(1) programs
- wait4 requires existing scheduler (from 003-microkernel spec)
- clock_gettime requires timer infrastructure (from 003-microkernel spec)
- getrandom is standalone (RDRAND/RDTSC seed + PRNG)

### Principle IV: QEMU-First Verification ✅ PASS
- All syscalls verifiable via QEMU with static test binaries
- clock_gettime testable by sleep+compare programs
- getrandom testable by comparing successive calls
- wait4 testable with parent/child process pairs

### Principle V: Explicit Memory and Hardware ✅ PASS
- FD table is explicit per-process array allocation
- PRNG state is explicit kernel-level structure
- Timer/clock access via volatile TSC reads or PIT configuration
- Zombie process table is explicit bounded data structure

### Principle VI: Strict Layering ✅ PASS
- Syscall handlers call into HAL for timer/entropy primitives
- No direct register manipulation in syscall code
- RDRAND/RDTSC wrapped in HAL functions

### Principle VII: Zero-Copy Networking ✅ N/A
- This feature does not involve networking

### Principle VIII: Capability-Based Security ✅ PASS
- FDs 0,1,2 map to kernel-controlled console/keyboard devices
- User processes cannot access raw hardware through these FDs
- wait4 validates that target PID is a child of caller

### Principle IX: Heap Hygiene ✅ PASS
- Zombie process entries allocated from bounded pool (no unbounded growth)
- FD table is fixed-size per-process array (16 entries per 003 spec)
- PRNG state is single kernel-global structure (no allocation)

## Project Structure

### Documentation (this feature)

```text
specs/007-linux-compat-layer/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
src/
├── kernel/
│   ├── syscall/
│   │   ├── table.zig        # Syscall dispatch table (add wait4, clock_gettime, getrandom)
│   │   ├── process.zig      # wait4 implementation
│   │   ├── time.zig         # clock_gettime implementation
│   │   └── random.zig       # getrandom implementation
│   ├── process/
│   │   ├── fd_table.zig     # File descriptor table with pre-opened FDs
│   │   ├── zombie.zig       # Zombie process management for wait4
│   │   └── task.zig         # Task/process structures (extend for parent-child)
│   └── hal/
│       ├── timer.zig        # TSC/PIT timer HAL for clock_gettime
│       └── entropy.zig      # RDRAND/RDTSC entropy HAL for getrandom
└── lib/
    └── prng.zig             # Xorshift PRNG for getrandom

tests/
├── userland/
│   ├── test_stdio.c         # Test pre-opened FDs (write to stdout)
│   ├── test_wait4.c         # Test wait4 with fork-like spawning
│   ├── test_clock.c         # Test clock_gettime accuracy
│   └── test_random.c        # Test getrandom returns different values
└── kernel/
    └── test_prng.zig        # Unit test for PRNG
```

**Structure Decision**: Single kernel project following established Zscapek patterns. Syscalls organized by domain (process, time, random). HAL layer isolates hardware access (RDRAND, TSC, PIT). Test programs are static C binaries loaded via InitRD.

## Complexity Tracking

> **No violations - all constitution checks passed**

---

## Post-Design Constitution Re-Check

*Re-evaluation after Phase 1 design artifacts (research.md, data-model.md, contracts/, quickstart.md)*

### Principle I: Bare-Metal Zig ✅ CONFIRMED
- All data structures (Xoroshiro128Plus, FileDescriptorTable, ZombieTable) are pure Zig
- Inline assembly isolated to HAL: `rdtsc()`, `rdrand()`, CPUID check
- No external dependencies introduced

### Principle II: Limine Protocol Compliance ✅ CONFIRMED
- No new Limine requests needed
- Existing framebuffer/console reused for FD 1/2 output
- Boot timestamp could optionally use Limine boot_time request (not required)

### Principle III: Minimal Viable Kernel ✅ CONFIRMED
- Each component independently testable per quickstart.md
- Clear implementation phases: HAL → Data Structures → Syscalls → Integration
- Dependencies on 003/005/006 specs documented

### Principle IV: QEMU-First Verification ✅ CONFIRMED
- Test binaries specified (test_stdio.c, test_clock.c, test_random.c, test_wait.c)
- All tests runnable in QEMU with serial output verification
- No hardware-specific requirements beyond standard x86_64

### Principle V: Explicit Memory and Hardware ✅ CONFIRMED
- ZombieTable uses bounded array (64 entries), no dynamic allocation
- FileDescriptorTable uses fixed array (16 entries)
- PRNG state is single global instance
- All hardware access via volatile/asm

### Principle VI: Strict Layering ✅ CONFIRMED
- HAL layer (`hal/timer.zig`, `hal/entropy.zig`) contains all hardware access
- Syscall handlers call HAL functions, never access hardware directly
- PRNG in `lib/prng.zig` is pure computation, no hardware dependency

### Principle VII: Zero-Copy Networking ✅ N/A (unchanged)

### Principle VIII: Capability-Based Security ✅ CONFIRMED
- wait4 validates parent_pid matches caller before reaping
- FD operations validate FD bounds and open state
- User pointers validated before write (EFAULT on invalid)

### Principle IX: Heap Hygiene ✅ CONFIRMED
- Bounded pools prevent unbounded growth
- No dynamic allocation in syscall hot paths
- Zombie table logs warning on overflow rather than OOM

**Post-Design Verdict**: All principles remain satisfied. No violations introduced during design phase.
