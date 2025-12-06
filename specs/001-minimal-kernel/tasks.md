# Tasks: Minimal Bootable Kernel

**Input**: Design documents from `/specs/001-minimal-kernel/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, quickstart.md

**Tests**: No unit tests requested. Verification is via QEMU visual inspection (dark blue screen) and serial output.

**Organization**: Six phases with infrastructure modules preceding user story implementation.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Single project (kernel)**: `src/` at repository root
- Build configuration at root: `build.zig`, `build.zig.zon`, `limine.conf`

---

## Phase 1: Setup (Project Initialization)

**Purpose**: Create project structure and configure Zig build system

- [ ] T001 [P] Create src/ directory at repository root
- [ ] T002 [P] Create build.zig.zon with limine-zig dependency at repository root
- [ ] T003 [P] Create .gitignore with zig-cache/, zig-out/, iso_root/, *.iso, limine/ at repository root

**Checkpoint**: Project structure ready for build system implementation

---

## Phase 2: Infrastructure Modules (Serial, Panic, SSP)

**Purpose**: Create foundational modules required by the kernel before main implementation

**CRITICAL**: These modules must exist before main.zig can compile (panic handler required for freestanding Zig)

- [ ] T004 [P] Create src/serial.zig with COM1 port constant (0x3F8)
- [ ] T005 Implement outb() assembly wrapper function in src/serial.zig
- [ ] T006 Implement init() function with COM1 initialization sequence in src/serial.zig
- [ ] T007 Implement write(char: u8) function in src/serial.zig
- [ ] T008 Implement writeString(str: []const u8) function in src/serial.zig
- [ ] T009 [P] Create src/panic.zig with panic handler using serial output
- [ ] T010 [P] Create src/ssp.zig with __stack_chk_guard export (0xDEADBEEF)
- [ ] T011 Add __stack_chk_fail() noreturn function to src/ssp.zig

**Checkpoint**: Infrastructure modules ready. Serial output, panic handler, and SSP symbols available.

---

## Phase 3: Build System & Bootloader

**Purpose**: Core build infrastructure that compiles kernel and produces bootable ISO

- [ ] T012 Create build.zig with x86_64-freestanding target configuration at repository root
- [ ] T013 Add limine-zig module import to build.zig at repository root
- [ ] T014 Add kernel executable definition with code_model=.kernel to build.zig at repository root
- [ ] T015 [P] Create src/linker.ld with high-half load address (0xffffffff80000000)
- [ ] T016 Configure linker script integration in build.zig at repository root
- [ ] T017 Add Limine binary acquisition step to build.zig at repository root (see Implementation Note below)
- [ ] T018 Add ISO assembly step to build.zig at repository root
- [ ] T019 Add xorriso ISO creation step to build.zig at repository root
- [ ] T020 Add QEMU run step to build.zig at repository root
- [ ] T021 [P] Create limine.conf with ZigK boot entry at repository root

**Implementation Note for T017**:
> Limine binary download in build.zig is complex (requires std.http or shell commands).
> **Recommended approach**: Use a simple shell command step that runs:
> ```bash
> git clone https://github.com/limine-bootloader/limine.git --branch=v7.x-binary --depth=1
> ```
> **Fallback**: If automated download fails, manually clone Limine binaries to `limine/`
> directory at repository root and skip the download step in build.zig.

**Checkpoint**: `zig build` should succeed (even with stub kernel). ISO generation configured.

---

## Phase 4: User Story 1 - Boot and Display Color (Priority: P1)

**Goal**: Kernel boots via Limine, acquires framebuffer, fills screen with dark blue color

**Spec Reference**: US1 - Boot and Display Color

**Independent Test**: Run `zig build run` - QEMU shows dark blue screen

**Acceptance Criteria**:
- Screen fills with dark blue color uniformly
- No flickering or corruption
- Display remains stable

### Implementation for User Story 1

- [ ] T022 [US1] Create src/main.zig with Limine base revision request (.revision = 2)
- [ ] T023 [US1] Add framebuffer request structure to src/main.zig
- [ ] T024 [US1] Import and re-export panic handler from src/panic.zig in src/main.zig
- [ ] T025 [US1] Import ssp module to provide SSP symbols in src/main.zig
- [ ] T026 [US1] Implement _start entry point with export and noreturn in src/main.zig
- [ ] T027 [US1] Add serial.init() call at start of _start in src/main.zig
- [ ] T028 [US1] Add base revision validation logic in src/main.zig
- [ ] T029 [US1] Add framebuffer response validation (check response exists and framebuffer_count > 0) in src/main.zig
- [ ] T030 [US1] Implement framebuffer fill loop with dark blue color (0x00400000 BGRA) in src/main.zig

**Checkpoint**: `zig build` compiles kernel successfully. Framebuffer fill implemented.

---

## Phase 5: User Story 2 - CPU Idle After Initialization (Priority: P2)

**Goal**: CPU enters low-power halt state after initialization completes

**Spec Reference**: US2 - CPU Idle After Initialization

**Independent Test**: Run `zig build run` - QEMU shows ~0% CPU usage after boot

**Acceptance Criteria**:
- CPU enters halt state after framebuffer fill
- CPU utilization near zero in emulator
- System remains stable indefinitely

### Implementation for User Story 2

- [ ] T031 [US2] Implement CPU halt loop with HLT instruction after framebuffer fill in src/main.zig

**Checkpoint**: `zig build run` launches QEMU with dark blue screen and low CPU usage

---

## Phase 6: User Story 3 - Bootable Image Creation (Priority: P3)

**Goal**: Build process produces bootable ISO that works in emulators

**Spec Reference**: US3 - Bootable Image Creation

**Independent Test**: `zig build iso` produces zigk.iso that boots in QEMU

**Acceptance Criteria**:
- Build command produces bootable disk image
- Image boots successfully in emulator
- Image contains kernel and bootloader configuration

### Implementation for User Story 3

> Note: Most of this is already covered in Phase 3 (Build System). This phase validates
> the complete integration and adds the convenience `iso` build step.

- [ ] T032 [US3] Add `zig build iso` step (build ISO without running QEMU) to build.zig at repository root
- [ ] T033 [US3] Verify ISO structure contains boot/kernel.elf and boot/limine/ directory

**Checkpoint**: `zig build iso` produces valid zigk.iso

---

## Phase 7: Polish & Verification

**Purpose**: Final validation and documentation

- [ ] T034 [P] Verify serial output shows "ZigK booting..." via `zig build run`
- [ ] T035 [P] Verify kernel boots without triple fault via `zig build run`
- [ ] T036 [P] Verify dark blue color displays correctly in QEMU (uniform, no artifacts)
- [ ] T037 [P] Verify CPU halts (QEMU shows ~0% CPU usage after boot)
- [ ] T038 [P] Verify kernel runs stable for 60+ seconds without crashes
- [ ] T039 Update README.md with build instructions at repository root

---

## Dependencies & Execution Order

### Phase Dependencies

```text
Phase 1: Setup
    │
    ▼
Phase 2: Infrastructure Modules (serial, panic, ssp)
    │
    ▼
Phase 3: Build System & Bootloader
    │
    ▼
Phase 4: User Story 1 (Boot + Display)
    │
    ▼
Phase 5: User Story 2 (CPU Halt)
    │
    ▼
Phase 6: User Story 3 (ISO Validation)
    │
    ▼
Phase 7: Polish & Verification
```

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Infrastructure (Phase 2)**: Depends on Setup - provides modules for main.zig
- **Build System (Phase 3)**: Depends on Infrastructure - needs modules to exist
- **User Story 1 (Phase 4)**: Depends on Build System - kernel code requires build system
- **User Story 2 (Phase 5)**: Depends on US1 - halt comes after display
- **User Story 3 (Phase 6)**: Depends on US2 - validates complete kernel
- **Polish (Phase 7)**: Depends on all user stories complete

### Within Phase 2 (Infrastructure)

```text
T004 (serial.zig file) ──► T005 (outb) ──► T006 (init) ──► T007 (write) ──► T008 (writeString)
T009 (panic.zig) - depends on serial.zig existing for import
T010 (ssp.zig file) ──► T011 (__stack_chk_fail)
```

### Within Phase 4 (User Story 1)

Sequential execution required:

1. T022-T023: Limine requests (must exist before entry point uses them)
2. T024-T025: Import panic and ssp modules
3. T026: Entry point skeleton
4. T027: Serial initialization call
5. T028-T029: Validation logic
6. T030: Framebuffer fill

### Parallel Opportunities

```text
Phase 1:
  T001, T002, T003 can all run in parallel (different files)

Phase 2:
  T004 and T010 can start in parallel (different files)
  T009 can start after T004-T008 complete (needs serial.zig)

Phase 3:
  T015 and T021 can run in parallel (linker.ld and limine.conf are independent)

Phase 7:
  T034, T035, T036, T037, T038 can all run in parallel (independent verifications)
```

---

## Task Details Reference

### T005: outb Assembly Wrapper

```zig
fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}
```

### T006: Serial Initialization Sequence

```zig
pub fn init() void {
    outb(COM1 + 1, 0x00); // Disable interrupts
    outb(COM1 + 3, 0x80); // Enable DLAB
    outb(COM1 + 0, 0x03); // Set divisor (lo byte) 38400 baud
    outb(COM1 + 1, 0x00); // Set divisor (hi byte)
    outb(COM1 + 3, 0x03); // 8 bits, no parity, one stop bit
    outb(COM1 + 2, 0xC7); // Enable FIFO
    outb(COM1 + 4, 0x0B); // IRQs enabled, RTS/DSR set
}
```

### T009: Panic Handler

```zig
const serial = @import("serial.zig");

pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    serial.writeString("PANIC: ");
    serial.writeString(msg);
    serial.write('\n');
    while (true) {
        asm volatile ("hlt");
    }
}
```

### T010-T011: SSP Symbols

```zig
pub export var __stack_chk_guard: usize = 0xDEADBEEF;

pub export fn __stack_chk_fail() noreturn {
    @panic("Stack smashing detected");
}
```

### T012: build.zig Target Configuration

```zig
const target = b.resolveTargetQuery(.{
    .cpu_arch = .x86_64,
    .os_tag = .freestanding,
    .abi = .none,
    .cpu_features_add = std.Target.x86.featureSet(&.{.soft_float}),
    .cpu_features_sub = std.Target.x86.featureSet(&.{
        .mmx, .sse, .sse2, .sse3, .ssse3, .sse4_1, .sse4_2, .avx, .avx2,
    }),
});
```

### T015: Linker Script Key Sections

- Entry: `_start`
- Load address: `0xffffffff80000000`
- Sections: `.text`, `.rodata`, `.data`, `.bss`
- Program headers: `PT_LOAD` with execute/read/write flags

### T030: Framebuffer Fill Color

```zig
// Dark blue in BGRA format (Blue=0x40, Green=0x00, Red=0x00, Alpha=0x00)
const dark_blue: u32 = 0x00400000;
```

---

## Implementation Strategy

### MVP First (Infrastructure + User Story 1)

1. Complete Phase 1: Setup (~3 tasks)
2. Complete Phase 2: Infrastructure (~8 tasks)
3. Complete Phase 3: Build System (~10 tasks)
4. Complete Phase 4: User Story 1 (~9 tasks)
5. **VALIDATE**: `zig build` compiles successfully

### Full Feature

6. Complete Phase 5: User Story 2 (~1 task)
7. Complete Phase 6: User Story 3 (~2 tasks)
8. **VALIDATE**: `zig build run` shows dark blue screen with low CPU
9. Complete Phase 7: Polish (~6 tasks)

### Incremental Checkpoints

| Phase | Validation |
|-------|------------|
| Setup | `ls src/` shows directory, `build.zig.zon` exists |
| Infrastructure | `src/serial.zig`, `src/panic.zig`, `src/ssp.zig` exist with correct signatures |
| Build System | `zig build` succeeds (with stub or actual kernel) |
| User Story 1 | `zig build` compiles kernel with framebuffer fill |
| User Story 2 | `zig build run` shows dark blue with ~0% CPU |
| User Story 3 | `zig build iso` produces valid zigk.iso |
| Polish | README has instructions, serial output verified, all verifications pass |

---

## Notes

- **Infrastructure First**: Phase 2 creates serial, panic, and ssp modules BEFORE main.zig
- **Panic Handler Critical**: T009 prevents linker error: `undefined symbol: panic`
- **SSP Symbols**: T010-T011 prevent linker errors when Zig enables stack protection
- **Serial for Debugging**: Infrastructure enables debug output from panic and main
- **T017 Complexity**: Limine download may need fallback to manual clone
- Phase 1 tasks marked [P] as they are independent files
- Phase 2 has specific dependencies within serial.zig (outb → init → write → writeString)
- User Story phases have [US#] labels for traceability
- Verification is visual (QEMU) + serial output rather than automated tests
- Commit after each phase completion for clean history
