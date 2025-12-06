# Tasks: Linux Compatibility Layer - Runtime Infrastructure

**Input**: Design documents from `/specs/007-linux-compat-layer/`
**Prerequisites**: plan.md, spec.md, data-model.md, contracts/, research.md, quickstart.md

**Tests**: Integration tests included as static C binaries loaded via InitRD.

**Organization**: Tasks grouped by user story to enable independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3, US4)
- Include exact file paths in descriptions

## Path Conventions

- **Kernel code**: `src/kernel/`
- **HAL layer**: `src/kernel/hal/` or `src/arch/x86_64/`
- **Library code**: `src/lib/`
- **Test programs**: `tests/userland/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and verify prerequisites from dependent specs

- [ ] T001 Verify spec 003-microkernel-userland-networking scheduler exists in src/kernel/sched/
- [ ] T002 Verify spec 003-microkernel-userland-networking dispatch table exists in src/kernel/syscall/table.zig (Linux ABI per spec 005)
- [ ] T003 Verify spec 006-sysv-abi-init process creation exists in src/kernel/process/task.zig
- [ ] T004 [P] Create src/kernel/hal/ directory structure for timer and entropy HAL
- [ ] T005 [P] Create src/lib/ directory for PRNG library code
- [ ] T006 [P] Create tests/userland/ directory for test binaries

---

## Phase 1.5: Architecture Hardening (Critical Silent Killers)

**Purpose**: Address x86_64 freestanding Zig "gotchas" that cause silent kernel crashes

**CRITICAL**: These must be completed before ANY other kernel code to prevent hard-to-debug issues

- [ ] T007 Disable Red Zone in build.zig: `kernel_options.cpu_features_sub.add(.red_zone)`
- [ ] T008 Disable MMX/SSE for kernel code in build.zig (userland FPU state preserved via FXSAVE/FXRSTOR in Spec 003 T043c-e)
- [ ] T009 Implement swapgs in syscall entry stub in src/arch/x86_64/syscall.zig (swap user GS with kernel GS)
- [ ] T010 Create emergency print function in src/kernel/debug/serial.zig (bypasses spinlocks for panic output)
- [ ] T011 Update panic.zig to use emergency print and detect deadlock/recursion in src/kernel/panic.zig
- [ ] T012 Copy Limine response data to kernel BSS before PMM init in src/kernel/boot/limine_copy.zig
- [ ] T013 Use interrupt-driven delays instead of spin loops for TCG timing in src/arch/x86_64/time.zig

### Crash Diagnostics (FR-032-034 from archived/004)

- [ ] T013a Implement dump_registers() helper for exception handlers in src/hal/x86_64/debug.zig
- [ ] T013b Page fault handler prints CR2 (fault address) and RIP (instruction pointer)

**Checkpoint**: Architecture is hardened against silent killers - safe to proceed with feature implementation

---

## Phase 2: Foundational (HAL and Core Data Structures)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**CRITICAL**: No user story work can begin until this phase is complete

### HAL Layer

- [ ] T014 [P] Implement rdtsc() inline assembly wrapper in src/kernel/hal/timer.zig
- [ ] T015 [P] Implement CPUID check for RDRAND support in src/kernel/hal/entropy.zig
- [ ] T016 [P] Implement rdrand() inline assembly wrapper in src/kernel/hal/entropy.zig
- [ ] T017 Implement TSC calibration using PIT in src/kernel/hal/timer.zig (use interrupt-driven delay per T013)
- [ ] T018 Implement collectTscEntropy() with timing jitter in src/kernel/hal/entropy.zig

### Core Data Structures

- [ ] T019 [P] Implement Xoroshiro128Plus PRNG in src/lib/prng.zig
- [ ] T020 [P] Implement FileDescriptorKind enum in src/kernel/process/fd_table.zig
- [ ] T021 [P] Implement FileDescriptor struct in src/kernel/process/fd_table.zig
- [ ] T022 Implement FileDescriptorTable with init(), allocate(), get() in src/kernel/process/fd_table.zig
- [ ] T023 [P] Implement Timespec extern struct in src/kernel/time/types.zig
- [ ] T024 [P] Implement ClockID enum in src/kernel/time/types.zig
- [ ] T025 [P] Implement TSCCalibration struct in src/kernel/time/types.zig
- [ ] T026 [P] Implement ZombieEntry struct in src/kernel/process/zombie.zig
- [ ] T027 Implement ZombieTable with add(), reap(), hasChildren() in src/kernel/process/zombie.zig
- [ ] T028 [P] Implement EntropyState struct with init() in src/kernel/random/state.zig
- [ ] T029 [P] Implement LinuxCompatState global in src/kernel/compat/state.zig

### Error Codes

- [ ] T030 Add Linux errno constants (ECHILD, EAGAIN, EFAULT, EBADF, EINVAL, EMFILE) to src/kernel/errno.zig

### Boot Initialization

- [ ] T031 Call TSC calibration in kernel boot sequence in src/kernel/main.zig
- [ ] T032 Call PRNG seeding in kernel boot sequence in src/kernel/main.zig (after TSC calibration)

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Pre-Opened Standard File Descriptors (Priority: P1)

**Goal**: Programs can write to FD 1/2 and read from FD 0 immediately at process start without explicit open() calls.

**Independent Test**: Load test_stdio.c that calls `write(1, "Hello", 5)` - verify output appears on console.

### Implementation for User Story 1

- [ ] T033 [US1] Extend Process struct with fd_table field in src/kernel/process/task.zig
- [ ] T034 [US1] Call fd_table.init() in createProcess() in src/kernel/process/task.zig
- [ ] T035 [US1] Update sys_write to dispatch based on FD kind (Console) in src/kernel/syscall/io.zig
- [ ] T036 [US1] Update sys_read to dispatch based on FD kind (Keyboard) in src/kernel/syscall/io.zig
- [ ] T037 [US1] Handle FD allocation on open() starting from lowest available in src/kernel/syscall/file.zig
- [ ] T038 [US1] Handle FD close() allowing reuse of FD 0, 1, 2 in src/kernel/syscall/file.zig

### Integration Test for User Story 1

- [ ] T039 [US1] Create tests/userland/test_stdio.c - static C program using write(1) and write(2)
- [ ] T040 [US1] Compile test_stdio.c with musl-gcc -static and add to InitRD

**Checkpoint**: US1 complete - standard I/O works without open() calls

---

## Phase 3.5: VFS Device Shim (FR-VFS-01 through FR-VFS-06)

**Goal**: Programs can open /dev/null, /dev/zero, /dev/console, /dev/urandom via standard open() syscall.

**Note**: This implements the VFS requirements documented in spec.md but not previously tasked.

### VFS Device Implementation

- [ ] T041 [VFS] Create DeviceKind enum (Null, Zero, Console, Stdin, Stdout, Stderr, Urandom) in src/kernel/vfs/device.zig
- [ ] T042 [VFS] Implement isDevicePath() check for "/dev/" prefix in src/kernel/vfs/device.zig
- [ ] T043 [VFS] Implement lookupDevice() returning DeviceKind for known paths in src/kernel/vfs/device.zig
- [ ] T044 [VFS] Update sys_open to check VFS before InitRD in src/kernel/syscall/file.zig
- [ ] T045 [VFS] Implement /dev/null read (returns 0 EOF) and write (discards, returns count) in src/kernel/vfs/device.zig
- [ ] T046 [VFS] Implement /dev/zero read (fills buffer with zeros) in src/kernel/vfs/device.zig
- [ ] T047 [VFS] Implement /dev/console handlers (write to serial/framebuffer, read from keyboard) in src/kernel/vfs/device.zig
- [ ] T048 [VFS] Implement /dev/urandom read (returns PRNG bytes) in src/kernel/vfs/device.zig

### VFS Verification

- [ ] T049 [VFS] Create tests/userland/test_devnull.c - writes to /dev/null, reads EOF
- [ ] T050 [VFS] Compile test_devnull.c and verify in QEMU

**Checkpoint**: VFS device shim complete - /dev/ paths work

---

## Phase 4: User Story 2 - Shell Process Control with wait4 (Priority: P1)

**Goal**: Shell can spawn a child process and wait for it to complete before showing next prompt.

**Independent Test**: Run test_wait4.c that spawns a child, waits, and verifies exit code.

### Implementation for User Story 2

- [ ] T051 [US2] Extend Process struct with parent_pid, exit_code, exit_signal, core_dumped in src/kernel/process/task.zig
- [ ] T052 [US2] Extend ProcessState enum with WaitingForChild, Zombie, Dead in src/kernel/process/task.zig
- [ ] T053 [US2] Implement encodeWaitStatus() in Process struct in src/kernel/process/task.zig
- [ ] T054 [US2] Implement becomeZombie() in Process struct in src/kernel/process/task.zig
- [ ] T055 [US2] Update sys_exit to create zombie entry and wake parent in src/kernel/syscall/exit.zig
- [ ] T056 [US2] Implement sys_wait4 syscall handler in src/kernel/syscall/process.zig
- [ ] T057 [US2] Add sys_wait4 (61) to syscall dispatch table in src/kernel/syscall/table.zig
- [ ] T058 [US2] Validate wstatus pointer before write in sys_wait4 in src/kernel/syscall/process.zig
- [ ] T059 [US2] Implement hasLiveChildren() helper for WNOHANG in src/kernel/process/zombie.zig
- [ ] T060 [US2] Handle orphan adoption by init (PID 1) on parent exit in src/kernel/syscall/exit.zig

### Integration Test for User Story 2

- [ ] T061 [US2] Create tests/userland/test_child.c - exits with code 42
- [ ] T062 [US2] Create tests/userland/test_wait4.c - spawns child, waits, verifies WEXITSTATUS==42
- [ ] T063 [US2] Compile test binaries with musl-gcc -static and add to InitRD

**Checkpoint**: US2 complete - shell can wait for child processes

---

## Phase 5: User Story 3 - Timekeeping with clock_gettime (Priority: P2)

**Goal**: Programs can measure elapsed time and get wall-clock timestamps.

**Independent Test**: Run test_clock.c that measures 100ms delay and verifies within 10% accuracy.

### Implementation for User Story 3

- [ ] T064 [US3] Implement sys_clock_gettime syscall handler in src/kernel/syscall/time.zig
- [ ] T065 [US3] Implement CLOCK_MONOTONIC (id=1) using calibrated TSC in src/kernel/syscall/time.zig
- [ ] T066 [US3] Implement CLOCK_REALTIME (id=0) using boot_epoch + monotonic in src/kernel/syscall/time.zig
- [ ] T067 [US3] Add sys_clock_gettime (228) to syscall dispatch table in src/kernel/syscall/table.zig
- [ ] T068 [US3] Validate clock_id (must be 0 or 1) and return -EINVAL in src/kernel/syscall/time.zig
- [ ] T069 [US3] Validate timespec pointer and return -EFAULT in src/kernel/syscall/time.zig
- [ ] T070 [US3] Maintain monotonic high-water mark to prevent backward jumps in src/kernel/time/monotonic.zig

### Integration Test for User Story 3

- [ ] T071 [US3] Create tests/userland/test_clock.c - measures busy-loop delay, verifies within 10%
- [ ] T072 [US3] Compile test_clock.c with musl-gcc -static and add to InitRD

**Checkpoint**: US3 complete - timing operations work correctly

---

## Phase 6: User Story 4 - Entropy for Runtime Initialization (Priority: P2)

**Goal**: Language runtimes can seed hash maps using getrandom without crashing.

**Independent Test**: Run test_random.c that calls getrandom twice and verifies different values.

### Implementation for User Story 4

- [ ] T073 [US4] Implement sys_getrandom syscall handler in src/kernel/syscall/random.zig
- [ ] T074 [US4] Fill buffer using kernel PRNG in src/kernel/syscall/random.zig
- [ ] T075 [US4] Add sys_getrandom (318) to syscall dispatch table in src/kernel/syscall/table.zig
- [ ] T076 [US4] Validate buffer pointer and return -EFAULT in src/kernel/syscall/random.zig
- [ ] T077 [US4] Handle GRND_NONBLOCK flag (MVP: never blocks, ignore) in src/kernel/syscall/random.zig
- [ ] T078 [US4] Handle GRND_RANDOM flag (MVP: same as default) in src/kernel/syscall/random.zig

### Integration Test for User Story 4

- [ ] T079 [US4] Create tests/userland/test_random.c - calls getrandom twice, compares results
- [ ] T080 [US4] Compile test_random.c with musl-gcc -static and add to InitRD

**Checkpoint**: US4 complete - hash map seeding works

---

## Phase 7: Polish and Cross-Cutting Concerns

**Purpose**: Final integration, documentation, and verification

- [ ] T081 [P] Add comments explaining Linux ABI choices in all syscall handlers
- [ ] T082 [P] Update CLAUDE.md with new syscall numbers and file paths
- [ ] T083 Run all 5 test binaries in QEMU and verify expected output
- [ ] T084 Verify test_stdio.c output: "stdout works\nstderr works\n"
- [ ] T085 Verify test_devnull.c output: /dev/null operations succeed
- [ ] T086 Verify test_wait4.c output: child exit code 42 retrieved
- [ ] T087 Verify test_clock.c output: elapsed time within 10% of expected
- [ ] T088 Verify test_random.c output: two different random values
- [ ] T089 Run quickstart.md verification commands in QEMU
- [ ] T090 Code cleanup: remove unused imports and dead code

---

## Dependencies and Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Architecture Hardening (Phase 1.5)**: Depends on Setup - CRITICAL for kernel stability
- **Foundational (Phase 2)**: Depends on Architecture Hardening - BLOCKS all user stories
- **User Stories (Phase 3-6)**: All depend on Foundational phase completion
  - US1 and US2 are both P1: implement US1 first (simpler), then US2
  - US3 and US4 are both P2: can run in parallel after US1/US2
- **Polish (Phase 7)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational - No dependencies on other stories
- **User Story 2 (P1)**: Can start after Foundational - Uses zombie table (Foundation), integrates with sys_exit
- **User Story 3 (P2)**: Can start after Foundational - Uses TSC calibration (Foundation), fully independent
- **User Story 4 (P2)**: Can start after Foundational - Uses PRNG (Foundation), fully independent

### Within Each User Story

- Models/structs before syscall handlers
- Syscall handlers before dispatch table entries
- Dispatch table entries before integration tests
- All implementation before test compilation

### Parallel Opportunities

**Phase 2 (Foundational)**:
```
# Can run in parallel - different files:
T014: src/kernel/hal/timer.zig (rdtsc)
T015: src/kernel/hal/entropy.zig (CPUID check)
T016: src/kernel/hal/entropy.zig (rdrand)
T019: src/lib/prng.zig
T020-T021: src/kernel/process/fd_table.zig (enums/structs)
T023-T025: src/kernel/time/types.zig (structs)
T026: src/kernel/process/zombie.zig (struct)
T028-T29: src/kernel/random/state.zig, src/kernel/compat/state.zig
```

**User Stories 3 and 4** (after Foundation):
```
# Can run in parallel - independent syscalls:
US3 (clock_gettime): T054-T062
US4 (getrandom): T063-T070
```

---

## Parallel Example: Foundational Phase

```bash
# Launch all HAL tasks in parallel:
Task: "T014 Implement rdtsc() in src/kernel/hal/timer.zig"
Task: "T015 Implement CPUID check in src/kernel/hal/entropy.zig"
Task: "T016 Implement rdrand() in src/kernel/hal/entropy.zig"

# Launch all data structure tasks in parallel:
Task: "T019 Implement Xoroshiro128Plus in src/lib/prng.zig"
Task: "T020-T021 Implement FD types in src/kernel/process/fd_table.zig"
Task: "T023-T025 Implement time types in src/kernel/time/types.zig"
Task: "T026 Implement ZombieEntry in src/kernel/process/zombie.zig"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 1.5: Architecture Hardening (CRITICAL)
3. Complete Phase 2: Foundational
4. Complete Phase 3: User Story 1 (Pre-Opened FDs)
5. **STOP and VALIDATE**: Test with test_stdio.c in QEMU
6. Kernel now supports basic C printf() programs

### Full Implementation

1. Complete Setup + Architecture Hardening + Foundational
2. Complete US1 (Pre-Opened FDs) - Test independently
3. Complete US2 (wait4) - Test independently
4. Complete US3 (clock_gettime) and US4 (getrandom) in parallel - Test independently
5. Polish and final verification

### Key Milestones

| Milestone | Task Range | Deliverable |
|-----------|------------|-------------|
| Architecture Safe | T007-T013 | Kernel won't silently crash |
| Foundation Ready | T014-T032 | HAL + data structures ready |
| Basic I/O Works | T033-T040 | printf("Hello") works |
| Shell Works | T041-T053 | Shell can wait for commands |
| Timing Works | T054-T062 | Programs can measure time |
| Random Works | T063-T070 | Hash maps initialize correctly |
| Feature Complete | T071-T079 | All tests pass in QEMU |

---

## Summary

| Metric | Count |
|--------|-------|
| **Total Tasks** | 90 |
| **Setup** | 6 |
| **Architecture Hardening** | 7 |
| **Foundational** | 19 |
| **User Story 1 (P1)** | 8 |
| **VFS Device Shim** | 10 |
| **User Story 2 (P1)** | 13 |
| **User Story 3 (P2)** | 9 |
| **User Story 4 (P2)** | 8 |
| **Polish** | 10 |
| **Parallelizable [P]** | 21 |

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story is independently testable with its own test binary
- Architecture Hardening phase addresses the "silent killer" issues identified for x86_64 Zig kernels
- All test programs are static C binaries compiled with musl-gcc for Linux ABI compatibility
- Commit after each task or logical group
- Stop at any checkpoint to validate independently
