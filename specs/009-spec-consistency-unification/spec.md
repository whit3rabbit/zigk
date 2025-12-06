# Feature Specification: Cross-Specification Consistency Unification

**Feature Branch**: `009-spec-consistency-unification`
**Created**: 2025-12-05
**Status**: Implemented
**Input**: Resolve cross-specification contradictions, standardize on Linux syscall ABI, unify Zig version requirements, and address architectural gaps identified in spec analysis.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Unified Syscall Number Table (Priority: P1)

As a kernel developer, I want all specifications to use the same syscall numbering scheme so that code implemented for one spec does not break when the next spec is implemented. Currently, spec 003 defines custom syscall numbers (SYS_READ=2, SYS_WRITE=1) while spec 005 adopts Linux ABI (sys_read=0, sys_write=1), creating a blocker.

**Why this priority**: This is a fundamental blocker. Implementing spec 003's custom numbers, then switching to Linux numbers in spec 005, requires rewriting all userland code. This must be resolved before any syscall implementation begins.

**Independent Test**: Verify that all spec documents reference the same syscall number table. A grep across all specs for syscall numbers should show consistent values.

**Acceptance Scenarios**:

1. **Given** spec 003 is updated, **When** checking SYS_READ/SYS_WRITE definitions, **Then** they match Linux x86_64 ABI (0 and 1 respectively)
2. **Given** a consolidated syscall table exists, **When** reviewing any spec, **Then** syscall numbers reference the consolidated table
3. **Given** an implementer reads spec 003, **When** implementing syscalls, **Then** the numbers match what spec 005/007 expect
4. **Given** the userland shell from spec 003, **When** compiled with Linux syscall numbers, **Then** it works with the same kernel as static C binaries

---

### User Story 2 - Standardized Zig Version (Priority: P1)

As a kernel developer, I want a single Zig version target across all specs so that build.zig patterns and code compile correctly. Currently, spec 001 plans for Zig 0.13.x/0.14.x while CLAUDE.md references 0.15.x, causing build failures.

**Why this priority**: Zig 0.15.x has breaking changes to the build system API. Code generated based on 0.13 documentation will not compile on 0.15. This blocks all implementation work.

**Independent Test**: Verify all specs and CLAUDE.md reference the same Zig version. Run `zig version` and confirm build.zig uses compatible patterns.

**Acceptance Scenarios**:

1. **Given** all specs are updated, **When** checking Zig version references, **Then** they consistently state "Zig 0.15.x" or current stable
2. **Given** CLAUDE.md build rules, **When** generating build.zig code, **Then** it uses 0.15.x std.Build API patterns
3. **Given** build.zig is implemented, **When** running `zig build`, **Then** it compiles without deprecation warnings or API errors
4. **Given** documentation or code examples in specs, **When** using Zig APIs, **Then** they follow 0.15.x conventions

---

### User Story 3 - Spinlock Infrastructure for Future Locking (Priority: P2)

As a kernel developer, I want the MVP to use a Spinlock primitive (even if wrapped in a global lock) so that transitioning from Big Kernel Lock (spec 003) to fine-grained locking (spec 004) is a refactor rather than a rewrite.

**Why this priority**: Spec 003 disables interrupts (CLI) during syscalls. Spec 004 requires spinlocks. If code is written assuming "interrupts are off," it will have race conditions when interrupts are enabled. Structural preparation prevents this.

**Independent Test**: Verify that kernel code uses explicit lock.acquire()/lock.release() calls rather than relying on implicit CLI behavior.

**Acceptance Scenarios**:

1. **Given** a Spinlock type is defined in spec 003, **When** critical sections are identified, **Then** they use lock operations
2. **Given** the MVP uses a global Big Kernel Lock, **When** implemented, **Then** it is a single Spinlock instance
3. **Given** code review of spec 003 implementation, **When** checking for implicit "interrupts disabled" assumptions, **Then** none exist outside explicit lock scope
4. **Given** spec 004 is implemented later, **When** replacing global lock with fine-grained locks, **Then** the refactor is mechanical (split one lock into many)

---

### User Story 4 - Explicit Endianness Documentation (Priority: P2)

As a kernel developer, I want clear documentation distinguishing network protocol endianness from hardware register endianness so that E1000 driver commands work correctly.

**Why this priority**: Protocol headers (IP/UDP) are Big Endian. E1000 descriptors and registers are Little Endian (host order). Confusing these causes silent failures: packets are dropped, and the NIC ignores malformed commands.

**Independent Test**: Verify spec 003 explicitly documents endianness for each category. Review that E1000 driver code uses correct byte order.

**Acceptance Scenarios**:

1. **Given** spec 003 networking section, **When** reading endianness rules, **Then** it explicitly states: Protocol Headers = Big Endian, Hardware Registers = Little Endian
2. **Given** IP/UDP header struct definitions, **When** checking field byte order, **Then** they use network_to_host/host_to_network conversions
3. **Given** E1000 descriptor struct definitions, **When** checking field byte order, **Then** they use host order (no byte swapping)
4. **Given** a QEMU test with packet capture, **When** observing transmitted packets, **Then** headers are correctly formatted and NIC accepts commands

---

### User Story 5 - VFS Shim for Device Paths (Priority: P2)

As a kernel developer, I want sys_open to handle virtual device paths (/dev/console, /dev/null) so that Linux programs expecting these paths work without modification.

**Why this priority**: Spec 003 uses flat InitRD. Spec 007 introduces sys_open for Linux compatibility. Linux programs call fopen("/dev/stdout"), which fails if the kernel only searches InitRD.

**Independent Test**: Run a C program that opens "/dev/null" and "/dev/console" without these files existing in InitRD.

**Acceptance Scenarios**:

1. **Given** a program calls open("/dev/console", O_WRONLY), **When** executed, **Then** it receives a valid FD mapped to console output
2. **Given** a program calls open("/dev/null", O_RDWR), **When** reading, **Then** it receives EOF immediately; when writing, **Then** data is discarded
3. **Given** a program calls open("/nonexistent"), **When** the path is not in InitRD, **Then** it receives -ENOENT
4. **Given** a program opens "/doom.wad", **When** the file exists in InitRD, **Then** standard file access works
5. **Given** paths starting with "/dev/", **When** processed by sys_open, **Then** VFS shim handles them before InitRD lookup

---

### User Story 6 - Userland Entry Point (crt0) (Priority: P2)

As a kernel developer, I want a crt0 implementation that sets up argc/argv from the stack layout (spec 006) so that userland programs receive command-line arguments correctly.

**Why this priority**: Spec 006 defines the stack layout but not the entry point code that reads it. Without crt0, Zig/C programs receive garbage arguments or crash on entry.

**Independent Test**: Run a userland program that prints argc and argv[0]. Verify correct values are displayed.

**Acceptance Scenarios**:

1. **Given** crt0 is implemented, **When** a userland program's _start is called, **Then** it reads argc from the stack
2. **Given** crt0 extracts argv pointers, **When** main(argc, argv) is called, **Then** arguments are accessible
3. **Given** a shell command "echo hello world", **When** echo is spawned, **Then** argc=3 and argv=["echo", "hello", "world"]
4. **Given** Zig userland code, **When** compiled for ZigK, **Then** it uses the provided crt0 to initialize std.os arguments

---

### Edge Cases

- What happens when CLAUDE.md and specs disagree on Zig version? CLAUDE.md takes precedence as the runtime configuration.
- What happens when existing code uses old syscall numbers? Document migration path in updated specs.
- What happens when /dev/console is opened for reading? Return -EACCES (write-only device) or map to keyboard input.
- What happens when crt0 is not linked with a userland program? The program crashes on entry; document linker requirements.
- What happens when endianness is wrong in already-implemented code? Create a checklist for code review during spec 004.

## Requirements *(mandatory)*

### Functional Requirements

**Syscall Number Unification**

- **FR-SYS-01**: All specs MUST use Linux x86_64 syscall numbers for standard operations.
- **FR-SYS-02**: Spec 003 MUST be amended to change SYS_READ from 2 to 0 and remove custom numbering.
- **FR-SYS-03**: A consolidated syscall table MUST be maintained in a single authoritative location.
- **FR-SYS-04**: Custom ZigK extensions MUST use syscall numbers 1000+ to avoid Linux conflicts.

**Zig Version Standardization**

- **FR-ZIG-01**: All specs MUST reference Zig 0.15.x (or current stable) as the target version.
- **FR-ZIG-02**: CLAUDE.md MUST include explicit build system patterns for the target Zig version.
- **FR-ZIG-03**: build.zig examples in specs MUST use std.Build API compatible with target version.
- **FR-ZIG-04**: Any version-specific workarounds MUST be documented with version checks.

**Spinlock Infrastructure**

- **FR-LOCK-01**: Spec 003 MUST define a Spinlock type with acquire() and release() methods.
- **FR-LOCK-02**: Critical sections MUST use explicit Spinlock operations, not implicit CLI assumptions.
- **FR-LOCK-03**: The MVP MAY use a single global lock; the structure enables future refactoring.
- **FR-LOCK-04**: Spinlock implementation MUST be IRQ-safe (save and restore interrupt state).

**Endianness Documentation**

- **FR-NET-01**: Spec 003 MUST explicitly document: Protocol Headers use Network Byte Order (Big Endian).
- **FR-NET-02**: Spec 003 MUST explicitly document: E1000 Registers and Descriptors use Host Byte Order (Little Endian).
- **FR-NET-03**: Networking code MUST use @byteSwap or std.mem.nativeToBig for protocol fields.
- **FR-NET-04**: E1000 driver code MUST NOT byte-swap register or descriptor fields.

**VFS Device Shim**

- **FR-VFS-01**: sys_open MUST check for /dev/ prefix before InitRD lookup.
- **FR-VFS-02**: /dev/console MUST map to console output (FD behavior matching stdout).
- **FR-VFS-03**: /dev/null MUST return EOF on read and discard writes.
- **FR-VFS-04**: /dev/stdin, /dev/stdout, /dev/stderr MUST map to FD 0, 1, 2 respectively.
- **FR-VFS-05**: Unknown /dev/ paths MUST return -ENOENT.

**Userland Entry Point**

- **FR-CRT-01**: A crt0 implementation MUST be provided for userland programs.
- **FR-CRT-02**: crt0 MUST read argc from the stack per spec 006 layout.
- **FR-CRT-03**: crt0 MUST extract argv array pointers from the stack.
- **FR-CRT-04**: crt0 MUST call main(argc, argv) with correct arguments.
- **FR-CRT-05**: crt0 MUST call sys_exit with main's return value on completion.

### Key Entities

- **Authoritative Syscall Table**: Single document defining all syscall numbers, referenced by all specs.
- **Spinlock**: Mutual exclusion primitive with acquire/release semantics for critical sections.
- **VFS Device Map**: Kernel table mapping /dev/ paths to device handlers.
- **crt0**: C runtime zero, the entry point code that sets up the C/Zig runtime environment.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All spec documents pass a syscall number consistency check (automated grep/diff).
- **SC-002**: build.zig compiles without errors on Zig 0.15.x with no deprecation warnings.
- **SC-003**: Userland shell (spec 003) and static C binary (spec 005) use identical syscall numbers.
- **SC-004**: E1000 driver successfully transmits packets (verified by packet capture showing correct byte order).
- **SC-005**: Static C program calling open("/dev/null") succeeds without the file in InitRD.
- **SC-006**: Userland program prints correct argc/argv values when spawned with arguments.
- **SC-007**: Critical section code review shows no implicit "interrupts disabled" assumptions.
- **SC-008**: Kernel locks are explicit Spinlock objects, not raw CLI/STI pairs.

## Deliverables

This specification produces the following updates:

1. **Spec 003 Amendment**: Update syscall numbers to Linux ABI; add Spinlock definition; add endianness section.
2. **Spec 001 Amendment**: Update Zig version from 0.13.x/0.14.x to 0.15.x.
3. **CLAUDE.md Update**: Add Zig 0.15.x build patterns and explicit version enforcement.
4. **Spec 007 Amendment**: Add VFS shim requirements for /dev/ paths.
5. **Spec 006 Amendment**: Add crt0 implementation requirements.
6. **Authoritative Syscall Table**: New document in specs/ defining all syscall numbers.

## Assumptions

- Zig 0.15.x is the target development version (or current stable when implementation begins).
- Linux x86_64 syscall numbers are the authoritative standard for ABI compatibility.
- The VFS shim is a kernel-space lookup table, not a full filesystem abstraction.
- crt0 is minimal: stack setup, argc/argv extraction, call main, call exit.
- Spinlock implementation uses atomic instructions (xchg, cmpxchg) for correctness.
- This specification does not add new features; it harmonizes existing specifications.
