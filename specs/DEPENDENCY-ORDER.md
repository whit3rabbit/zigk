# Zscapek Specification Dependency Order

This document defines the correct implementation order for Zscapek specifications.

## Implementation Sequence

```
002 (Debug Infrastructure)
  |
  v
003 (Core Kernel + merged 001) --> Boot, memory, interrupts, FPU, basic syscalls
  |
  v
005 (Linux ABI Syscalls) --> Adds remaining Linux syscalls
  |
  v
006 (ABI Process Init) --> Stack layout, TLS, crt0
  |
  v
007 (Linux Compat Layer) --> VFS shim, wait4, clock_gettime, getrandom
  |
  v
004 (Stability) --> Fine-grained locking (parallel with 008)
008 (ARM Portability) --> HAL refactoring (parallel with 004)
```

## Archived Specifications

- **001-minimal-kernel**: Merged into Spec 003 Phase 1 (archived to `specs/_archived/`)

## Cross-Specification Dependencies

### Syscall Implementation Flow

| Syscall | Spec 003 | Spec 007 | Notes |
|---------|----------|----------|-------|
| sys_read (0) | T080 (basic) | T035 (FD dispatch) | 007 enhances 003 |
| sys_write (1) | T079 (basic) | T036 (FD dispatch) | 007 enhances 003 |
| sys_open (2) | T155 (InitRD) | T044 (VFS check) | 007 adds /dev/ paths |
| sys_close (3) | T156 (basic) | T038 (FD reuse) | 007 handles special FDs |
| sys_clock_gettime (228) | DEFERRED | T064-T072 | Spec 007 owns this |

### FPU State Preservation

- Spec 003 Phase 3 (T043c-g): Implements FXSAVE/FXRSTOR for userland FPU support
- Spec 007 T008: Documents that kernel SSE/MMX is disabled but userland FPU works

### VFS Device Shim

- Spec 007 Phase 3.5 (T041-T050): Implements /dev/null, /dev/zero, /dev/console, /dev/urandom
- Spec 003 Phase 10: InitRD file access (VFS checks device paths first)

## Parallel Implementation Opportunities

The following can be implemented in parallel after their dependencies are met:

- **Spec 004 and 008**: Both depend on 007 completion but are independent of each other
- **Within Spec 003**: Tasks marked [P] in the same phase can run in parallel
- **Within Spec 007**: User Stories 3 and 4 (clock_gettime and getrandom) can run in parallel

## Validation Checkpoints

| After Spec | Validation |
|------------|------------|
| 003 Phase 1 | Kernel boots with "Zscapek booting..." message |
| 003 Phase 7 | `ping <kernel-ip>` receives replies |
| 003 Phase 6 | Shell prompt appears, keyboard input works |
| 007 Phase 3 | `write(1, "hello", 5)` works without open() |
| 007 Phase 3.5 | `open("/dev/null", O_RDWR)` succeeds |
| 007 Phase 5 | `clock_gettime(CLOCK_MONOTONIC, &ts)` returns valid time |
