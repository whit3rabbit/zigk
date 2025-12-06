# Archived Specifications

These specifications were superseded by consolidation into active specs. Their requirements have been merged into specs with complete execution chains (spec.md + plan.md + tasks.md).

## Merge Destinations

| Archived Spec | Description | Requirements Merged Into |
|---------------|-------------|-------------------------|
| 001-minimal-kernel | Minimal bootable kernel (boot, framebuffer, halt) | Spec 003 Phase 1 (T001-T008) |
| 002-kernel-infrastructure | Serial logging, panic handler, stack protection | Spec 003 Phase 1 (T006a-d) |
| 004-kernel-stability-arch | FPU/SSE state, spinlocks, stack guards, crash diagnostics | Spec 003 Phase 3 (hardware), Spec 007 Phase 1.5 (process) |
| 005-linux-syscall-compat | Linux syscall numbers, errno codes | `specs/syscall-table.md` (authoritative table) |
| 006-sysv-abi-init | SysV ABI stack layout, CRT0, auxiliary vector | Spec 003 userland (crt0), Spec 007 (arch_prctl) |
| 008-arm-hal-portability | HAL boundary enforcement, console abstraction | Spec 003 Phase 1.5 (HAL tasks), contracts/hal-interface.md |

## Why These Were Archived

These specs existed as requirement documents (spec.md only) without plan.md or tasks.md files. This created "floating requirements" that were not part of any execution chain, risking:

1. Requirements being forgotten during implementation
2. Duplicate/conflicting work across specs
3. No clear ownership or scheduling

## How to Use Archived Specs

The original spec.md files remain in their archived folders for reference. If you need to understand the original requirements or acceptance criteria, consult the archived spec.md directly.

For implementation guidance, refer to the merged tasks in:
- `specs/003-microkernel-userland-networking/tasks.md`
- `specs/007-linux-compat-layer/tasks.md`
- `specs/syscall-table.md`

## Consolidation Date

Archived: 2025-12-06 (Spec 009 - Cross-Specification Consistency Unification)
