# Data Model: Cross-Specification Consistency Unification

**Feature Branch**: `009-spec-consistency-unification`
**Date**: 2025-12-05

This document defines the key entities and concepts introduced or standardized by this specification update.

---

## Overview

This feature is a **documentation-only** update. No new runtime data structures are created. Instead, this document defines the conceptual entities that must be consistently documented across all specifications.

---

## 1. Authoritative Syscall Table

### Entity: SyscallEntry

Represents a single syscall definition in the authoritative table.

```
SyscallEntry:
  number: u64           # Linux x86_64 syscall number
  name: string          # Canonical name (e.g., "sys_read")
  signature: string     # Parameter types
  return_type: string   # Return type
  spec_ref: string      # Which spec defines the implementation
  status: enum          # Planned | Implemented | Deprecated
```

### Relationships

- Each `SyscallEntry` is referenced by one or more spec documents
- All specs MUST use numbers from this table
- Custom ZigK extensions use numbers 1000+

### Example Entry

```markdown
| Number | Name | Signature | Return | Spec | Status |
|--------|------|-----------|--------|------|--------|
| 0 | sys_read | fd: i32, buf: [*]u8, count: usize | isize | 005 | Planned |
| 1 | sys_write | fd: i32, buf: [*]const u8, count: usize | isize | 005 | Planned |
| 61 | sys_wait4 | pid: i32, wstatus: ?*i32, options: i32, rusage: ?*anyopaque | isize | 007 | Planned |
```

---

## 2. Spinlock Primitive

### Entity: Spinlock

The standardized mutual exclusion primitive for kernel code.

```zig
Spinlock:
  locked: atomic(u32)   # 0 = unlocked, 1 = locked

  methods:
    acquire() -> Held   # Disable IRQs, spin until lock acquired
    tryAcquire() -> ?Held  # Non-blocking attempt

  inner type:
    Held:
      lock: *Spinlock   # Reference to parent lock
      irq_state: bool   # Saved interrupt flag state

      methods:
        release()       # Release lock, restore IRQ state
```

### Invariants

1. `acquire()` MUST disable interrupts before attempting to lock
2. `release()` MUST release lock before restoring interrupt state
3. Lock MUST use atomic exchange (XCHG) for correctness
4. Nested acquisition on same lock is undefined behavior (deadlock)

### Usage Specification

All specs referencing critical sections MUST:
1. Identify the lock protecting the resource
2. Use explicit `acquire()`/`release()` calls
3. NOT rely on implicit "interrupts are disabled" assumptions

---

## 3. Endianness Categories

### Entity: ByteOrderCategory

Categorization of byte order requirements.

```
ByteOrderCategory:
  name: string          # Category identifier
  byte_order: enum      # BigEndian | LittleEndian | Native
  conversion_required: bool
  zig_function: string  # Conversion function to use
```

### Standard Categories

| Category | Byte Order | Conversion | Zig Function |
|----------|-----------|------------|--------------|
| ProtocolHeader | Big Endian | Yes (on x86_64) | `std.mem.nativeToBig` |
| HardwareRegister | Little Endian | No (on x86_64) | N/A |
| HardwareDescriptor | Little Endian | No (on x86_64) | N/A |
| LimineStruct | Little Endian | No (on x86_64) | N/A |
| InternalStruct | Native | No | N/A |

### Application to E1000 Driver

- Transmit/Receive descriptors: `HardwareDescriptor` (no swap)
- Control registers: `HardwareRegister` (no swap)
- IP/UDP headers in packet buffers: `ProtocolHeader` (must swap)

---

## 4. VFS Device Entry

### Entity: VFSDeviceEntry

Represents a virtual device path mapping.

```
VFSDeviceEntry:
  path: string              # e.g., "/dev/console"
  device_kind: enum         # Console | Keyboard | DevNull | DevZero | DevUrandom
  allowed_flags: u32        # O_RDONLY, O_WRONLY, O_RDWR
  description: string       # Human-readable description
```

### Standard Device Mappings

| Path | Kind | Flags | Description |
|------|------|-------|-------------|
| /dev/null | DevNull | O_RDWR | Discards writes, returns EOF on read |
| /dev/zero | DevZero | O_RDONLY | Returns zero bytes on read |
| /dev/console | Console | O_WRONLY | Kernel console output |
| /dev/stdin | Keyboard | O_RDONLY | Standard input (FD 0 equivalent) |
| /dev/stdout | Console | O_WRONLY | Standard output (FD 1 equivalent) |
| /dev/stderr | Console | O_WRONLY | Standard error (FD 2 equivalent) |
| /dev/urandom | DevUrandom | O_RDONLY | Kernel PRNG output |
| /dev/random | DevUrandom | O_RDONLY | Same as urandom (MVP) |

### Behavior

- `sys_open("/dev/X")` checks VFS shim BEFORE InitRD lookup
- Unknown `/dev/` paths return `-ENOENT`
- Non-`/dev/` paths fall through to InitRD

---

## 5. CRT0 Stack Layout

### Entity: UserStackLayout

Defines the stack structure at userland entry point.

```
UserStackLayout (at _start entry):
  RSP+0:              argc (u64)
  RSP+8:              argv[0] (pointer to string)
  RSP+16:             argv[1]
  ...
  RSP+8*(argc):       argv[argc-1]
  RSP+8*(argc+1):     NULL (argv terminator)
  RSP+8*(argc+2):     envp[0] (pointer to string)
  ...
                      NULL (envp terminator)
                      auxv[] (ELF auxiliary vector, optional)
```

### CRT0 Responsibilities

1. Extract `argc` from `RSP`
2. Calculate `argv = RSP + 8`
3. Calculate `envp = argv + (argc + 1) * 8`
4. Align stack to 16 bytes
5. Call `main(argc, argv, envp)`
6. Call `sys_exit(main_return_value)`

### Invariants

- Frame pointer (RBP) MUST be zeroed at entry
- Stack MUST be 16-byte aligned before `call main`
- `sys_exit` MUST be called even if main returns

---

## 6. Zig Version Specification

### Entity: ZigVersionRequirement

Specifies the target Zig version for the project.

```
ZigVersionRequirement:
  major: u8             # 0
  minor: u8             # 15
  patch: string         # "x" (any patch level)
  build_api_version: string  # Identifies breaking changes
```

### Current Requirement

```
Zig 0.15.x
Build API: root_module pattern
Target: x86_64-freestanding-none
```

### Build System Patterns

Required patterns for Zig 0.15.x compatibility:

```zig
// Module creation (0.15.x)
.root_module = b.createModule(.{ ... })

// Path handling (0.15.x)
.root_source_file = b.path("src/main.zig")

// Kernel code model (disables Red Zone)
.code_model = .kernel
```

---

## Relationships Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    Authoritative Syscall Table                   │
│  (specs/syscall-table.md - single source of truth)              │
└───────────────────────────┬─────────────────────────────────────┘
                            │ references
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│   Spec 003    │   │   Spec 005    │   │   Spec 007    │
│  (networking) │   │  (syscalls)   │   │   (compat)    │
├───────────────┤   ├───────────────┤   ├───────────────┤
│ - Spinlock    │   │ - Dispatch    │   │ - VFS shim    │
│ - Endianness  │   │   table       │   │ - FD handling │
│ - E1000 driver│   │ - Error codes │   │ - wait4       │
└───────────────┘   └───────────────┘   └───────────────┘
        │                                       │
        └───────────────────┬───────────────────┘
                            ▼
                    ┌───────────────┐
                    │   Spec 006    │
                    │   (SysV ABI)  │
                    ├───────────────┤
                    │ - Stack layout│
                    │ - crt0        │
                    │ - Process init│
                    └───────────────┘
                            │
                            ▼
                    ┌───────────────┐
                    │   Spec 001    │
                    │   (minimal)   │
                    ├───────────────┤
                    │ - Zig version │
                    │ - Build setup │
                    │ - Limine boot │
                    └───────────────┘
```

---

## Validation Rules

### Syscall Number Consistency
- All specs MUST reference `specs/syscall-table.md` for syscall numbers
- No spec may define its own syscall numbers

### Zig Version Consistency
- All specs MUST specify Zig 0.15.x
- CLAUDE.md MUST document 0.15.x build patterns
- Code examples MUST use 0.15.x API

### Spinlock Usage
- All critical sections MUST use explicit Spinlock
- No code may assume "interrupts are disabled" without lock

### Endianness Correctness
- Protocol headers MUST use network byte order
- Hardware access MUST use host byte order
- Each networking struct MUST document its byte order category

### VFS Path Handling
- `/dev/` paths handled by VFS shim
- Non-`/dev/` paths handled by InitRD
- Unknown `/dev/` paths return `-ENOENT`

### CRT0 Compliance
- All userland programs MUST link with crt0
- crt0 MUST follow SysV ABI stack layout
- crt0 MUST call sys_exit on completion
