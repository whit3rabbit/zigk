# Tasks: Cross-Specification Consistency Unification

**Input**: Design documents from `/specs/009-spec-consistency-unification/`
**Prerequisites**: plan.md, spec.md, data-model.md, contracts/, research.md, quickstart.md

**Tests**: No code tests - this is a documentation-only feature. Verification via grep/diff commands.

**Organization**: Tasks grouped by user story to enable independent implementation and verification of each documentation update.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3, etc.)
- Include exact file paths in descriptions

## Path Conventions

- **Spec documents**: `specs/[NNN-feature-name]/spec.md`
- **Root config**: `CLAUDE.md`
- **New documents**: `specs/syscall-table.md`

---

## Phase 1: Setup

**Purpose**: Verify prerequisites and prepare for amendments

- [X] T001 Verify specs/001-minimal-kernel/spec.md exists and is readable
- [X] T002 [P] Verify specs/003-microkernel-userland-networking/spec.md exists and is readable
- [X] T003 [P] Verify specs/006-sysv-abi-init/spec.md exists and is readable
- [X] T004 [P] Verify specs/007-linux-compat-layer/spec.md exists and is readable
- [X] T005 [P] Verify CLAUDE.md exists at repository root
- [X] T006 Create backup of all files to be modified (optional but recommended)

---

## Phase 2: Foundational - Create Authoritative Syscall Table

**Purpose**: Create the new authoritative reference document that all other amendments will reference

**CRITICAL**: This must be complete before spec amendments can reference it

- [X] T007 Create specs/syscall-table.md with Linux x86_64 syscall numbers from contracts/amendments.md
- [X] T008 Add syscall register convention section (RAX, RDI, RSI, RDX, R10, R8, R9)
- [X] T009 Add Linux errno constants table (EPERM through ENOSYS)
- [X] T010 Add ZigK custom extensions section (reserved range 1000-1999, empty for now)
- [X] T011 Verify specs/syscall-table.md is syntactically valid markdown

**Checkpoint**: Authoritative syscall table exists - spec amendments can now reference it

---

## Phase 3: User Story 1 - Unified Syscall Number Table (Priority: P1)

**Goal**: All specifications use the same syscall numbering scheme (Linux x86_64 ABI).

**Independent Test**: `grep -r "SYS_READ.*=.*2" specs/` returns no matches; all specs reference syscall-table.md.

### Implementation for User Story 1

- [X] T012 [US1] Search specs/003-microkernel-userland-networking/spec.md for custom syscall numbers (SYS_READ=2, SYS_WRITE=1, etc.)
- [X] T013 [US1] Replace custom syscall definitions with reference to specs/syscall-table.md in specs/003-microkernel-userland-networking/spec.md
- [X] T014 [US1] Add "See specs/syscall-table.md" reference to any syscall section in specs/003-microkernel-userland-networking/spec.md
- [X] T015 [US1] Add syscall-table.md reference to specs/005-linux-syscall-compat/spec.md (if exists)
- [X] T016 [US1] Add syscall-table.md reference to specs/007-linux-compat-layer/spec.md

### Verification for User Story 1

- [X] T017 [US1] Run `grep -r "SYS_READ.*=.*2" specs/` - verify no matches
- [X] T018 [US1] Run `grep -r "syscall-table.md" specs/` - verify references in updated specs

**Checkpoint**: US1 complete - all specs use unified syscall numbers from authoritative table

---

## Phase 4: User Story 2 - Standardized Zig Version (Priority: P1)

**Goal**: All specs and CLAUDE.md reference Zig 0.15.x consistently.

**Independent Test**: `grep -r "0\.13\|0\.14" specs/ CLAUDE.md` returns no matches; all reference 0.15.x.

### Implementation for User Story 2

- [X] T019 [P] [US2] Search specs/001-minimal-kernel/spec.md for Zig version references (0.13.x, 0.14.x)
- [X] T020 [P] [US2] Search CLAUDE.md for Zig version references
- [X] T021 [US2] Replace "Zig 0.13.x/0.14.x" with "Zig 0.15.x (or current stable)" in specs/001-minimal-kernel/spec.md
- [X] T022 [US2] Replace old Zig version references in CLAUDE.md with "Zig 0.15.x"
- [X] T023 [US2] Add Zig 0.15.x build patterns section to CLAUDE.md (root_module, createModule, code_model)
- [X] T024 [US2] Update any build.zig examples in specs to use 0.15.x std.Build API patterns

### Verification for User Story 2

- [X] T025 [US2] Run `grep -r "0\.13" specs/ CLAUDE.md` - verify no matches
- [X] T026 [US2] Run `grep -r "0\.14" specs/ CLAUDE.md` - verify no matches
- [X] T027 [US2] Run `grep -c "0\.15" CLAUDE.md` - verify at least 1 match
- [X] T028 [US2] Run `grep -c "root_module\|createModule" CLAUDE.md` - verify build patterns present

**Checkpoint**: US2 complete - unified Zig version across all documentation

---

## Phase 5: User Story 3 - Spinlock Infrastructure (Priority: P2)

**Goal**: Spec 003 defines Spinlock primitive for explicit locking.

**Independent Test**: `grep -c "Spinlock" specs/003-microkernel-userland-networking/spec.md` returns >= 1.

### Implementation for User Story 3

- [X] T029 [US3] Identify the Kernel Primitives or Locking section in specs/003-microkernel-userland-networking/spec.md
- [X] T030 [US3] Add Spinlock type definition with acquire()/release() methods per contracts/amendments.md
- [X] T031 [US3] Add Spinlock.Held inner type documentation
- [X] T032 [US3] Add Spinlock requirements list (IRQ-safe, explicit operations, BKL for MVP)
- [X] T033 [US3] Add Spinlock usage pattern code example

### Verification for User Story 3

- [X] T034 [US3] Run `grep -c "Spinlock" specs/003-microkernel-userland-networking/spec.md` - verify >= 3 matches
- [X] T035 [US3] Run `grep -c "acquire\|release" specs/003-microkernel-userland-networking/spec.md` - verify >= 2 matches

**Checkpoint**: US3 complete - Spinlock infrastructure documented for future locking transition

---

## Phase 6: User Story 4 - Explicit Endianness Documentation (Priority: P2)

**Goal**: Spec 003 explicitly documents byte order for protocol headers vs hardware registers.

**Independent Test**: `grep -ci "byte order\|endian" specs/003-microkernel-userland-networking/spec.md` returns >= 1.

### Implementation for User Story 4

- [X] T036 [US4] Identify the Networking section in specs/003-microkernel-userland-networking/spec.md
- [X] T037 [US4] Add "Byte Order Requirements" subsection per contracts/amendments.md
- [X] T038 [US4] Add endianness table (IP/UDP = Big Endian, E1000 = Little Endian)
- [X] T039 [US4] Add implementation rules (protocol swap, hardware no-swap)
- [X] T040 [US4] Add UdpHeader accessor example showing bigToNative usage

### Verification for User Story 4

- [X] T041 [US4] Run `grep -ci "byte order" specs/003-microkernel-userland-networking/spec.md` - verify >= 1
- [X] T042 [US4] Run `grep -c "bigToNative\|nativeToBig" specs/003-microkernel-userland-networking/spec.md` - verify >= 1

**Checkpoint**: US4 complete - endianness requirements explicit for networking implementation

---

## Phase 7: User Story 5 - VFS Shim for Device Paths (Priority: P2)

**Goal**: Spec 007 documents VFS shim for /dev/ virtual device paths.

**Independent Test**: `grep -ci "vfs.*shim\|/dev/" specs/007-linux-compat-layer/spec.md` returns >= 1.

### Implementation for User Story 5

- [X] T043 [US5] Identify File Descriptor or sys_open section in specs/007-linux-compat-layer/spec.md
- [X] T044 [US5] Add "VFS Device Shim" section per contracts/amendments.md
- [X] T045 [US5] Add supported device paths table (/dev/null, /dev/console, /dev/stdin, etc.)
- [X] T046 [US5] Add sys_open behavior rules (check /dev/ first, then InitRD)
- [X] T047 [US5] Add implementation note (lookup table, not filesystem)

### Verification for User Story 5

- [X] T048 [US5] Run `grep -ci "vfs" specs/007-linux-compat-layer/spec.md` - verify >= 1
- [X] T049 [US5] Run `grep -c "/dev/null\|/dev/console" specs/007-linux-compat-layer/spec.md` - verify >= 2

**Checkpoint**: US5 complete - VFS device shim documented for Linux compatibility

---

## Phase 8: User Story 6 - Userland Entry Point crt0 (Priority: P2)

**Goal**: Spec 006 documents crt0 implementation for argc/argv parsing.

**Independent Test**: `grep -ci "crt0" specs/006-sysv-abi-init/spec.md` returns >= 1.

### Implementation for User Story 6

- [X] T050 [US6] Identify Process or Entry Point section in specs/006-sysv-abi-init/spec.md
- [X] T051 [US6] Add "CRT0 Implementation" section per contracts/amendments.md
- [X] T052 [US6] Add stack layout diagram (argc at RSP, argv at RSP+8, envp calculation)
- [X] T053 [US6] Add CRT0 responsibilities list (7 steps)
- [X] T054 [US6] Add reference _start implementation in Zig
- [X] T055 [US6] Add linker requirement note (programs must link with crt0)

### Verification for User Story 6

- [X] T056 [US6] Run `grep -ci "crt0" specs/006-sysv-abi-init/spec.md` - verify >= 3
- [X] T057 [US6] Run `grep -c "_start\|argc\|argv" specs/006-sysv-abi-init/spec.md` - verify >= 3

**Checkpoint**: US6 complete - crt0 entry point documented for userland programs

---

## Phase 9: Polish & Cross-Cutting Verification

**Purpose**: Final validation and cleanup

### Full Verification Suite

- [X] T058 [P] Run `test -f specs/syscall-table.md && echo "PASS"` - syscall table exists
- [X] T059 [P] Run `grep -r "SYS_READ.*=.*2" specs/` - verify no custom numbers
- [X] T060 [P] Run `grep -r "0\.13\|0\.14" specs/ CLAUDE.md` - verify no old Zig versions
- [X] T061 [P] Run `grep -c "Spinlock" specs/003-microkernel-userland-networking/spec.md` - verify present
- [X] T062 [P] Run `grep -ci "endian\|byte order" specs/003-microkernel-userland-networking/spec.md` - verify present
- [X] T063 [P] Run `grep -ci "crt0" specs/006-sysv-abi-init/spec.md` - verify present
- [X] T064 [P] Run `grep -ci "vfs" specs/007-linux-compat-layer/spec.md` - verify present
- [X] T065 [P] Run `grep -c "root_module" CLAUDE.md` - verify build patterns present

### Documentation Cleanup

- [X] T066 Update specs/009-spec-consistency-unification/spec.md status from "Draft" to "Implemented"
- [X] T067 Run quickstart.md verify-consistency.sh script (if created)
- [X] T068 Review all modified files for formatting consistency
- [ ] T069 Commit all changes with descriptive message per quickstart.md

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup - creates syscall-table.md
- **User Stories (Phase 3-8)**: All depend on Foundational (syscall-table.md must exist first)
  - US1 and US2 are both P1 priority - do US1 first (syscall references)
  - US3, US4, US5, US6 are all P2 priority - can proceed in parallel
- **Polish (Phase 9)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Requires syscall-table.md from Foundational phase
- **User Story 2 (P1)**: Independent - can run in parallel with US1
- **User Story 3 (P2)**: Independent - different file than US1/US2
- **User Story 4 (P2)**: Same file as US3 (spec 003) - run after US3
- **User Story 5 (P2)**: Independent - different file (spec 007)
- **User Story 6 (P2)**: Independent - different file (spec 006)

### Parallel Opportunities

**Phase 1 (Setup)** - All [P] tasks can run in parallel:
```
T002: Verify spec 003
T003: Verify spec 006
T004: Verify spec 007
T005: Verify CLAUDE.md
```

**User Stories 3, 5, 6** (after US1/US2) - Different files, can run in parallel:
```
US3/US4: specs/003-microkernel-userland-networking/spec.md
US5: specs/007-linux-compat-layer/spec.md
US6: specs/006-sysv-abi-init/spec.md
```

**Phase 9 (Polish)** - All verification tasks can run in parallel:
```
T058-T065: All grep verification commands
```

---

## Parallel Example: P2 User Stories

```bash
# After US1 and US2 complete, launch P2 stories in parallel:

# Terminal 1: US3 + US4 (same file, sequential)
Task: "T029-T035 Spinlock in spec 003"
Task: "T036-T042 Endianness in spec 003"

# Terminal 2: US5
Task: "T043-T049 VFS shim in spec 007"

# Terminal 3: US6
Task: "T050-T057 crt0 in spec 006"
```

---

## Implementation Strategy

### MVP First (User Stories 1 + 2 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (create syscall-table.md)
3. Complete Phase 3: User Story 1 (syscall unification)
4. Complete Phase 4: User Story 2 (Zig version)
5. **STOP and VALIDATE**: Run grep verification for syscalls and Zig version
6. This resolves the two P1 blocking issues

### Full Implementation

1. Complete Setup + Foundational + US1 + US2 (MVP)
2. Complete US3 (Spinlock) + US4 (Endianness) - same file, sequential
3. Complete US5 (VFS) and US6 (crt0) in parallel
4. Complete Polish phase verification
5. Commit with descriptive message

### Key Milestones

| Milestone | Task Range | Deliverable |
|-----------|------------|-------------|
| Setup Complete | T001-T006 | All files verified accessible |
| Syscall Table Created | T007-T011 | specs/syscall-table.md exists |
| Syscalls Unified (P1) | T012-T018 | No custom syscall numbers in specs |
| Zig Version Unified (P1) | T019-T028 | All specs reference 0.15.x |
| Spinlock Documented (P2) | T029-T035 | Spec 003 has Spinlock section |
| Endianness Documented (P2) | T036-T042 | Spec 003 has byte order section |
| VFS Shim Documented (P2) | T043-T049 | Spec 007 has VFS section |
| crt0 Documented (P2) | T050-T057 | Spec 006 has crt0 section |
| Feature Complete | T058-T069 | All verifications pass |

---

## Summary

| Metric | Count |
|--------|-------|
| **Total Tasks** | 69 |
| **Setup** | 6 |
| **Foundational** | 5 |
| **User Story 1 (P1)** | 7 |
| **User Story 2 (P1)** | 10 |
| **User Story 3 (P2)** | 7 |
| **User Story 4 (P2)** | 7 |
| **User Story 5 (P2)** | 7 |
| **User Story 6 (P2)** | 8 |
| **Polish** | 12 |
| **Parallelizable [P]** | 16 |

---

## Notes

- [P] tasks = different files, no dependencies on incomplete tasks
- [Story] label maps task to specific user story for traceability
- This is a documentation-only feature - no code compilation or QEMU testing required
- Verification is via grep/diff commands, not unit tests
- US3 and US4 modify the same file (spec 003) - run sequentially within that file
- Commit after each user story or logical group
- Stop at any checkpoint to validate independently
