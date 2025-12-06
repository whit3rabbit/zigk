# Implementation Plan: Cross-Specification Consistency Unification

**Branch**: `009-spec-consistency-unification` | **Date**: 2025-12-05 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/009-spec-consistency-unification/spec.md`

**Note**: This is a documentation/specification update feature, not a code implementation. It updates existing specs for consistency.

## Summary

Harmonize all ZigK specifications by: (1) unifying syscall numbers to Linux x86_64 ABI, (2) standardizing on Zig 0.15.x, (3) adding Spinlock infrastructure documentation, (4) clarifying endianness requirements, (5) defining VFS shim for /dev/ paths, and (6) specifying crt0 entry point requirements. This resolves cross-specification contradictions that would otherwise block implementation.

## Technical Context

**Language/Version**: Zig 0.15.x (freestanding x86_64 target)
**Primary Dependencies**: N/A (documentation updates only)
**Storage**: N/A
**Testing**: Spec consistency validation via grep/diff across spec files
**Target Platform**: N/A (specification documents)
**Project Type**: Documentation/specification updates
**Performance Goals**: N/A
**Constraints**: Updates must not change spec semantics beyond consistency fixes
**Scale/Scope**: 6 spec documents to update, 1 new authoritative syscall table

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Principle I: Bare-Metal Zig ✅ PASS
- All updates reinforce freestanding Zig requirements
- Zig version standardization (0.15.x) improves compliance

### Principle II: Limine Protocol Compliance ✅ N/A
- No changes to Limine protocol usage

### Principle III: Minimal Viable Kernel ✅ PASS
- Spinlock infrastructure prepares for incremental complexity
- VFS shim is minimal lookup table, not full filesystem

### Principle IV: QEMU-First Verification ✅ N/A
- Documentation changes; verification via spec review

### Principle V: Explicit Memory and Hardware ✅ PASS
- Endianness documentation makes byte order explicit
- Spinlock documentation makes locking explicit

### Principle VI: Strict Layering ✅ PASS
- VFS shim respects kernel/HAL boundary
- crt0 is userland code, not kernel

### Principle VII: Zero-Copy Networking ✅ N/A
- Endianness documentation supports but doesn't modify networking

### Principle VIII: Capability-Based Security ✅ PASS
- VFS shim enforces syscall-mediated device access
- /dev/ paths go through kernel validation

### Principle IX: Heap Hygiene ✅ N/A
- No new allocations introduced

## Project Structure

### Documentation (this feature)

```text
specs/009-spec-consistency-unification/
├── plan.md              # This file
├── research.md          # Research on best practices
├── data-model.md        # Entity definitions for new concepts
├── quickstart.md        # Step-by-step update guide
├── contracts/           # Amendment templates
└── tasks.md             # Update tasks
```

### Specifications to Update

```text
specs/
├── 001-minimal-kernel/spec.md      # Update Zig version to 0.15.x
├── 003-microkernel-userland-networking/spec.md  # Update syscall numbers, add Spinlock, add endianness
├── 006-sysv-abi-init/spec.md       # Add crt0 requirements
├── 007-linux-compat-layer/spec.md  # Add VFS shim requirements
└── syscall-table.md                # NEW: Authoritative syscall number table

CLAUDE.md                           # Update Zig version, build patterns
```

**Structure Decision**: This is a documentation-only feature. No source code changes. All deliverables are spec document updates and one new authoritative reference document.

## Complexity Tracking

> **No violations - all constitution checks passed or N/A**

---

## Post-Design Constitution Re-Check

*Re-evaluation after Phase 1 design artifacts (research.md, data-model.md, contracts/, quickstart.md)*

### Principle I: Bare-Metal Zig ✅ CONFIRMED
- All research reinforces Zig 0.15.x freestanding patterns
- Build system patterns use proper module creation API
- Inline assembly patterns documented for Spinlock, crt0

### Principle II: Limine Protocol Compliance ✅ N/A (unchanged)
- No Limine protocol changes in amendments

### Principle III: Minimal Viable Kernel ✅ CONFIRMED
- Spinlock is single-file, minimal implementation
- VFS shim is static lookup table, not dynamic filesystem
- crt0 is minimal entry code (~15 lines)

### Principle IV: QEMU-First Verification ✅ CONFIRMED
- Verification via grep/diff commands documented in quickstart.md
- Shell script provided for automated verification

### Principle V: Explicit Memory and Hardware ✅ CONFIRMED
- Endianness requirements are now explicit per domain
- Spinlock IRQ-safety is explicitly documented
- crt0 stack layout is explicitly specified

### Principle VI: Strict Layering ✅ CONFIRMED
- VFS shim is kernel-only lookup table
- crt0 is userland-only entry code
- HAL patterns preserved in Spinlock assembly

### Principle VII: Zero-Copy Networking ✅ N/A (unchanged)

### Principle VIII: Capability-Based Security ✅ CONFIRMED
- VFS device mappings enforce access modes (O_RDONLY, O_WRONLY)
- /dev/ paths validated by kernel before access

### Principle IX: Heap Hygiene ✅ N/A (unchanged)
- No allocations in any documented patterns

**Post-Design Verdict**: All principles remain satisfied. Documentation-only feature poses no architecture risks.
