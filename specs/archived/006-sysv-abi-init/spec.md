# Feature Specification: System V AMD64 ABI Process Initialization

**Feature Branch**: `006-sysv-abi-init`
**Created**: 2025-12-05
**Status**: Draft
**Input**: Adopt System V AMD64 ABI conventions for process initialization to run standard compiled programs (C, Zig, Rust) without runtime patching

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Standard Stack Layout at Process Start (Priority: P1)

As a kernel developer, I need the initial user stack to contain argc, argv, envp, and the Auxiliary Vector in the exact System V ABI layout so that standard libc initialization code works without modification.

**Why this priority**: This is the foundation for running any standard compiled program. Without the correct stack layout, libc's _start code reads garbage and crashes before main() is even called.

**Independent Test**: Load a static C program compiled with musl/glibc that prints argc and argv[0], and verify it produces correct output on Zscapek.

**Acceptance Scenarios**:

1. **Given** a user process starting, **When** the kernel jumps to the entry point, **Then** RSP points to argc, followed by argv pointers, NULL, envp pointers, NULL, and auxiliary vectors.
2. **Given** a C program accessing argv[0], **When** it runs on Zscapek, **Then** it correctly reads the program name from the stack.
3. **Given** a program compiled with stack canaries (SSP), **When** it starts, **Then** AT_RANDOM provides 16 bytes for canary initialization.

---

### User Story 2 - Thread Local Storage Support (Priority: P1)

As a kernel developer, I need the FS segment base register to be settable by userspace so that thread-local storage (TLS) works for errno, per-thread allocators, and modern runtime features.

**Why this priority**: Without TLS support, any program using errno (virtually all C programs), Zig's std.Thread, or Go's goroutine runtime will crash or produce incorrect results. This is essential for libc compatibility.

**Independent Test**: Run a C program that sets errno after a failed syscall and reads it back, verifying the value is preserved correctly.

**Acceptance Scenarios**:

1. **Given** a program calling arch_prctl with ARCH_SET_FS, **When** executed, **Then** the FS base register is set to the specified address.
2. **Given** TLS initialized via arch_prctl, **When** the program accesses thread-local variables, **Then** they read/write correctly via FS-relative addressing.
3. **Given** a multi-threaded program (if supported), **When** each thread sets its own FS base, **Then** thread-local variables are isolated per thread.

---

### User Story 3 - Generic Memory Mapping (mmap) (Priority: P1)

As a kernel developer, I need a standard mmap syscall so that modern memory allocators (mimalloc, jemalloc, Python's allocator) can request large memory regions without relying solely on brk.

**Why this priority**: Modern allocators strongly prefer mmap for large allocations. Without it, complex software will either fail or fall back to inefficient brk-based allocation, limiting what can run on Zscapek.

**Independent Test**: Run a program that uses mmap to allocate anonymous memory, writes to it, and reads it back correctly.

**Acceptance Scenarios**:

1. **Given** a program calling mmap with MAP_ANONYMOUS | MAP_PRIVATE, **When** executed, **Then** a new anonymous memory region is mapped at the returned address.
2. **Given** mmap with PROT_READ | PROT_WRITE, **When** the program writes and reads memory, **Then** data is preserved correctly.
3. **Given** mmap with a hint address of 0, **When** executed, **Then** the kernel chooses a suitable address and returns it.

---

### User Story 4 - Standard Error Codes (Priority: P2)

As a kernel developer, I need syscalls to return standard Linux errno values so that error handling in libc and application code works correctly.

**Why this priority**: Programs check specific error codes to determine what went wrong. Returning generic -1 prevents retry logic, proper error messages, and conditional behavior based on error type.

**Independent Test**: Call open() on a non-existent file and verify the returned error code is ENOENT (2), not a generic error.

**Acceptance Scenarios**:

1. **Given** a syscall that fails due to invalid argument, **When** it returns, **Then** the return value is -EINVAL (−22).
2. **Given** a syscall opening a non-existent file, **When** it returns, **Then** the return value is -ENOENT (−2).
3. **Given** a syscall with permission denied, **When** it returns, **Then** the return value is -EACCES (−13).

---

### User Story 5 - Auxiliary Vector Completeness (Priority: P2)

As a kernel developer, I need the Auxiliary Vector to include critical entries (AT_PAGESZ, AT_RANDOM, AT_PHDR/PHENT/PHNUM) so that runtime initialization, stack protection, and exception handling work correctly.

**Why this priority**: Stack canary initialization requires AT_RANDOM. Exception unwinding requires ELF program header information. Missing these causes crashes or security vulnerabilities.

**Independent Test**: Run a program that reads the auxiliary vector and verifies AT_PAGESZ returns 4096 and AT_RANDOM points to 16 random bytes.

**Acceptance Scenarios**:

1. **Given** a process starting, **When** it reads AT_PAGESZ from auxv, **Then** the value is 4096.
2. **Given** a process starting, **When** it reads AT_RANDOM from auxv, **Then** it points to 16 bytes of random data.
3. **Given** an ELF binary with program headers, **When** it reads AT_PHDR, **Then** it points to the loaded program headers in memory.

---

### User Story 6 - Memory Unmapping (munmap) (Priority: P3)

As a kernel developer, I need munmap to release memory so that long-running programs don't exhaust available memory.

**Why this priority**: Programs that allocate and free memory repeatedly need munmap to prevent memory leaks. Without it, allocators cannot return memory to the OS.

**Independent Test**: Allocate memory with mmap, unmap it with munmap, and verify the memory is no longer accessible (causes page fault).

**Acceptance Scenarios**:

1. **Given** a mapped memory region, **When** munmap is called with its address and size, **Then** the region is unmapped.
2. **Given** an unmapped region, **When** the program attempts to access it, **Then** a page fault occurs.
3. **Given** a partial unmap request, **When** munmap is called on part of a region, **Then** only that portion is unmapped.

---

### User Story 7 - Memory Protection Changes (mprotect) (Priority: P3)

As a kernel developer, I need mprotect to change memory permissions so that JIT compilers and runtime code generation work correctly.

**Why this priority**: JIT compilers (PyPy, V8, LuaJIT) need to write code to memory then make it executable. This is a future-proofing requirement for interpreted languages.

**Independent Test**: Allocate RW memory, write code to it, use mprotect to make it executable, then call into it.

**Acceptance Scenarios**:

1. **Given** a mapped region with PROT_READ | PROT_WRITE, **When** mprotect adds PROT_EXEC, **Then** code can be executed from that region.
2. **Given** a region with PROT_READ | PROT_WRITE | PROT_EXEC, **When** mprotect removes PROT_WRITE, **Then** writes cause a fault.
3. **Given** an unmapped address, **When** mprotect is called, **Then** it returns -ENOMEM.

---

### Edge Cases

- What happens when argc is 0 (no program name)? (Set argc=1 with empty or default program name)
- What happens when envp is empty? (Valid: NULL-terminated empty list)
- How does the system handle mmap with conflicting flags (e.g., MAP_FIXED on existing mapping)?
- What happens when arch_prctl is called with an invalid FS base address?
- How does the system handle mmap requests larger than available memory?
- What happens when munmap is called on an address that was never mapped?
- How does the system handle AT_RANDOM when no entropy source is available?

## Requirements *(mandatory)*

> **Syscall Numbers**: All syscall numbers follow Linux x86_64 ABI.
> See [syscall-table.md](../syscall-table.md) for authoritative numbers.

### Functional Requirements

**Initial Stack Layout**

- **FR-001**: Kernel MUST set RSP to point to argc (8 bytes) at process entry.
- **FR-002**: Stack layout MUST follow argc with argv[0..n] pointers, NULL terminator, envp[0..n] pointers, NULL terminator, then auxiliary vector entries ending with AT_NULL.
- **FR-003**: argv and envp string data MUST be placed below the pointers on the stack.
- **FR-004**: Initial stack MUST be 16-byte aligned per System V ABI requirements.

**Auxiliary Vector**

- **FR-005**: Kernel MUST provide AT_NULL (0) as the auxiliary vector terminator.
- **FR-006**: Kernel MUST provide AT_PAGESZ (6) with value 4096.
- **FR-007**: Kernel MUST provide AT_RANDOM (25) pointing to 16 bytes of random data on the stack.
- **FR-008**: Kernel SHOULD provide AT_PHDR (3), AT_PHENT (4), AT_PHNUM (5) for ELF binaries.
- **FR-009**: Kernel SHOULD provide AT_ENTRY (9) with the program entry point address.

**Thread Local Storage**

- **FR-010**: Kernel MUST implement syscall 158 (arch_prctl) with ARCH_SET_FS (0x1002) to set the FS base register.
- **FR-011**: Kernel MUST implement arch_prctl with ARCH_GET_FS (0x1003) to read the current FS base.
- **FR-012**: FS base changes MUST take effect immediately for subsequent memory accesses.

**Memory Mapping (mmap/munmap/mprotect)**

- **FR-013**: Kernel MUST implement syscall 9 (mmap) with standard Linux signature and semantics.
- **FR-014**: mmap MUST support MAP_ANONYMOUS (0x20) for anonymous memory allocation.
- **FR-015**: mmap MUST support MAP_PRIVATE (0x02) for private mappings.
- **FR-016**: mmap MUST support PROT_READ (0x1), PROT_WRITE (0x2), PROT_EXEC (0x4) protection flags.
- **FR-017**: mmap with addr=0 MUST choose a suitable address and return it.
- **FR-018**: Kernel MUST implement syscall 11 (munmap) to unmap memory regions.
- **FR-019**: Kernel MUST implement syscall 10 (mprotect) to change memory protection.

**Standard Error Codes**

- **FR-020**: Syscalls MUST return negative errno values on failure per Linux convention.
- **FR-021**: Kernel MUST use EPERM (1), ENOENT (2), EIO (5), EBADF (9), EAGAIN (11), ENOMEM (12), EACCES (13), EINVAL (22), ENOSYS (38) correctly.
- **FR-022**: All error codes MUST match Linux x86_64 generic errno definitions.

**CRT0 Implementation**

A crt0 (C runtime zero) implementation MUST be provided for userland programs.

**Stack Layout at _start**:
```
RSP+0:    argc (8 bytes)
RSP+8:    argv[0] pointer
...
RSP+8*(argc+1): NULL (argv terminator)
RSP+8*(argc+2): envp[0] pointer
...
          NULL (envp terminator)
```

**CRT0 Responsibilities**:
1. Clear frame pointer (RBP = 0) per ABI
2. Extract argc from RSP
3. Calculate argv = RSP + 8
4. Calculate envp = argv + (argc + 1) * 8
5. Align stack to 16 bytes
6. Call main(argc, argv, envp)
7. Call sys_exit(main_return_value)

- **FR-CRT-01**: A crt0 implementation MUST be provided for userland programs
- **FR-CRT-02**: crt0 MUST read argc from the stack per SysV ABI layout
- **FR-CRT-03**: crt0 MUST extract argv array pointers from the stack
- **FR-CRT-04**: crt0 MUST call main(argc, argv) with correct arguments
- **FR-CRT-05**: crt0 MUST call sys_exit with main's return value on completion

**Reference Implementation**:
```zig
export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\  xor %%rbp, %%rbp
        \\  mov (%%rsp), %%rdi
        \\  lea 8(%%rsp), %%rsi
        \\  lea 8(%%rsi,%%rdi,8), %%rdx
        \\  and $-16, %%rsp
        \\  call main
        \\  mov %%eax, %%edi
        \\  mov $60, %%eax
        \\  syscall
        \\  ud2
    );
}
```

**Linking Requirement**:
All userland programs MUST link with crt0. Failure to include crt0 results in crash at entry.

### Key Entities

- **Auxiliary Vector (auxv)**: Array of key-value pairs providing OS information to user processes at startup.
- **FS Base Register**: Segment base address used for thread-local storage access via FS-relative addressing.
- **Virtual Memory Area (VMA)**: Kernel structure tracking mapped memory regions with their permissions and backing.
- **errno**: Standard error code returned as negative value from failed syscalls.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Static C programs (musl-linked) correctly read argc and argv[0] from the stack on Zscapek.
- **SC-002**: Programs using errno (via TLS) preserve error values correctly across syscalls.
- **SC-003**: mmap-based allocations succeed for anonymous memory up to available physical memory.
- **SC-004**: AT_RANDOM provides 16 bytes that differ between process launches.
- **SC-005**: Syscall errors return the correct errno value (ENOENT for missing files, etc.) in 100% of tested cases.
- **SC-006**: Programs compiled with stack protection (SSP) initialize canaries and detect stack smashing.
- **SC-007**: Memory allocated via mmap can be freed via munmap without leaks over 1000 allocation cycles.

## Assumptions

- Target ABI is System V AMD64 (Linux x86_64 compatible).
- Only the essential auxiliary vector entries are implemented initially; full Linux compatibility is not required.
- FSGSBASE CPU instructions are not available; arch_prctl is the primary TLS mechanism.
- Single-threaded processes are the primary use case; multi-thread TLS isolation is a stretch goal.
- A source of randomness (RDRAND, timer jitter, or Limine-provided) is available for AT_RANDOM.
- mmap initially supports anonymous mappings only; file-backed mappings are out of scope.
- This specification complements 005-linux-syscall-compat for complete Linux ABI compatibility.
