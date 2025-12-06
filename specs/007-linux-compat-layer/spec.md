# Feature Specification: Linux Compatibility Layer - Runtime Infrastructure

**Feature Branch**: `007-linux-compat-layer`
**Created**: 2025-12-05
**Status**: Draft
**Input**: Complete the Linux Compatibility Layer with runtime infrastructure requirements: pre-opened standard file descriptors (0, 1, 2), clock_gettime syscall, getrandom syscall, and wait4 syscall for shell support.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Pre-Opened Standard File Descriptors (Priority: P1)

Standard libraries (C, Zig, Python) assume that when a process starts, file descriptors 0, 1, and 2 are already open. Without this, the first `printf` or `std.debug.print` call fails with EBADF and the program crashes or produces no output.

**Why this priority**: This is foundational for any userland program. If the kernel starts a process with an empty FD table, no standard I/O works. This must be in place before any other runtime feature matters.

**Independent Test**: Load a static C program that calls `write(1, "Hello\n", 6)` without explicitly opening any files. Verify it prints "Hello" to the console without errors.

**Acceptance Scenarios**:

1. **Given** the kernel creates a new user process, **When** it jumps to the entry point, **Then** FD 0 is mapped to keyboard input (stdin)
2. **Given** a new user process starts, **When** it writes to FD 1 or FD 2, **Then** output appears on the console/framebuffer without any prior open() call
3. **Given** a C program using `printf("Hello")`, **When** it runs on ZigK, **Then** the output appears correctly via the pre-opened FD 1
4. **Given** a userland process closes FD 0, 1, or 2, **When** a subsequent open() is called, **Then** the lowest available FD number is returned (standard behavior)

---

### User Story 2 - Shell Process Control with wait4 (Priority: P1)

A shell's main loop requires: print prompt, read input, spawn child, wait for child, repeat. Without wait4/waitpid, the shell cannot know when a command finishes, causing prompts to print over command output or race conditions.

**Why this priority**: This is essential for User Story 3 in spec 003 (Ring 3 Userland Shell). The shell cannot function as an interactive command interpreter without process waiting.

**Independent Test**: Run a shell that spawns a child process executing a test command. Verify the shell waits for the child to complete before printing the next prompt.

**Acceptance Scenarios**:

1. **Given** a parent process spawns a child, **When** the parent calls wait4(child_pid, ...), **Then** it blocks until the child terminates
2. **Given** a child process calls exit(42), **When** the parent calls wait4, **Then** the status includes exit code 42 (extractable via WEXITSTATUS)
3. **Given** a child process terminates, **When** the parent has not yet called wait4, **Then** the child becomes a zombie until reaped
4. **Given** a parent calls wait4 with WNOHANG, **When** no child has exited, **Then** it returns 0 immediately without blocking
5. **Given** a parent process terminates without waiting, **When** orphan children exist, **Then** they are adopted by the init process (PID 1)

---

### User Story 3 - Timekeeping with clock_gettime (Priority: P2)

Modern runtimes need specific types of time. Python's `import time`, C's `gettimeofday`, and Zig's `std.time` all rely on clock_gettime. Without it, timing operations fail and programs cannot measure elapsed time or get wall-clock timestamps.

**Why this priority**: Required for any program that uses timers, timestamps, or performance measurement. Lower priority than P1 because basic programs can run without it, but essential for real applications.

**Independent Test**: Run a program that calls clock_gettime with CLOCK_MONOTONIC, sleeps for 100ms, calls again, and verifies the difference is approximately 100ms.

**Acceptance Scenarios**:

1. **Given** a program calls clock_gettime with CLOCK_REALTIME (0), **When** executed, **Then** it receives the current Unix timestamp (seconds since 1970-01-01)
2. **Given** a program calls clock_gettime with CLOCK_MONOTONIC (1), **When** executed twice with a 100ms sleep between, **Then** the difference is approximately 100ms
3. **Given** a program calls clock_gettime with an invalid clock_id, **When** executed, **Then** it returns -EINVAL
4. **Given** CLOCK_MONOTONIC values, **When** compared across calls, **Then** they are always non-decreasing (never jump backwards)
5. **Given** a program passes an invalid timespec pointer, **When** clock_gettime is called, **Then** it returns -EFAULT

---

### User Story 4 - Entropy for Runtime Initialization (Priority: P2)

Modern language runtimes (Python, Go, Rust, Zig) enable hash randomization by default to prevent DoS attacks on hash tables. They seed hash maps using getrandom. Without it, runtimes may refuse to start or crash during initialization.

**Why this priority**: Critical for running real language runtimes like Python. Lower than P1 because simple C programs work without it, but Python and Go will fail at startup.

**Independent Test**: Run a Zig program that initializes a HashMap. Verify initialization succeeds and the hash map functions correctly.

**Acceptance Scenarios**:

1. **Given** a program calls getrandom(buf, 16, 0), **When** executed, **Then** 16 bytes of random data are written to buf
2. **Given** a program calls getrandom twice, **When** comparing results, **Then** the returned data differs (not deterministic)
3. **Given** a program requests more bytes than available entropy with GRND_NONBLOCK, **When** executed, **Then** it returns -EAGAIN
4. **Given** an invalid buffer pointer, **When** getrandom is called, **Then** it returns -EFAULT
5. **Given** the MVP uses a seeded PRNG (not true entropy), **When** programs use getrandom, **Then** they boot successfully (functional compatibility over cryptographic security)

---

### Edge Cases

- What happens when a process closes stdin (FD 0) and then opens a file? The file gets FD 0 (lowest available), which may confuse programs expecting stdin.
- How does the system handle clock_gettime with a NULL timespec pointer? Must return -EFAULT.
- What happens when wait4 is called on a PID that doesn't exist or isn't a child? Must return -ECHILD.
- How does the system handle getrandom requests larger than available entropy? For MVP, the PRNG can generate unlimited bytes (no blocking).
- What happens when wait4 is called and the child was already reaped by another thread? Must return -ECHILD.
- How does the zombie process table handle exhaustion? Limit zombie count and log warnings.

## Requirements *(mandatory)*

> **Syscall Numbers**: All syscall numbers follow Linux x86_64 ABI.
> See [syscall-table.md](../syscall-table.md) for authoritative numbers.

### Functional Requirements

**Pre-Opened Standard File Descriptors**

- **FR-PROC-05**: When creating a user process, the kernel MUST initialize the File Descriptor table with FD 0 mapped to Keyboard Input (stdin).
- **FR-PROC-06**: When creating a user process, the kernel MUST initialize FD 1 mapped to Console/Framebuffer output (stdout).
- **FR-PROC-07**: When creating a user process, the kernel MUST initialize FD 2 mapped to Console/Framebuffer output (stderr).
- **FR-PROC-08**: The pre-opened FDs MUST behave identically to FDs opened via sys_open for the same devices.
- **FR-PROC-09**: Closing FD 0, 1, or 2 MUST be allowed, with the FD number becoming available for reuse by subsequent open() calls.

**Process Waiting (wait4/waitpid)**

- **FR-PROC-10**: Kernel MUST implement syscall 61 (wait4) with Linux-compatible signature and semantics.
- **FR-PROC-11**: wait4 MUST support waiting for a specific child PID (pid > 0), any child (pid = -1), or any child in process group (pid = 0 or pid < -1).
- **FR-PROC-12**: wait4 MUST support the WNOHANG option (0x1) to return immediately if no child has exited.
- **FR-PROC-13**: wait4 status MUST encode exit code in bits 15-8, core dump flag in bit 7, and signal number in bits 6-0.
- **FR-PROC-14**: When a process terminates, it MUST become a Zombie until its parent acknowledges it via wait4.
- **FR-PROC-15**: Zombie processes MUST retain only minimal kernel data (PID, exit status) until reaped.
- **FR-PROC-16**: wait4 on an invalid or non-child PID MUST return -ECHILD (error code 10).
- **FR-PROC-17**: The rusage parameter to wait4 MAY be NULL; if non-NULL, resource usage statistics SHOULD be populated (or zeroed for MVP).

**Timekeeping (clock_gettime)**

- **FR-TIME-01**: Kernel MUST implement syscall 228 (clock_gettime) with Linux-compatible signature.
- **FR-TIME-02**: clock_gettime MUST support CLOCK_REALTIME (clock_id = 0) returning Unix timestamp.
- **FR-TIME-03**: clock_gettime MUST support CLOCK_MONOTONIC (clock_id = 1) returning time since boot.
- **FR-TIME-04**: timespec structure MUST be {tv_sec: i64, tv_nsec: i64} (16 bytes total on x86-64).
- **FR-TIME-05**: CLOCK_MONOTONIC values MUST be monotonically non-decreasing (never go backwards).
- **FR-TIME-06**: clock_gettime with invalid clock_id MUST return -EINVAL (error code 22).
- **FR-TIME-07**: clock_gettime with invalid timespec pointer MUST return -EFAULT (error code 14).
- **FR-TIME-08**: CLOCK_REALTIME MAY return a static epoch if no RTC is available (document as assumption).

**Entropy (getrandom)**

- **FR-RAND-01**: Kernel MUST implement syscall 318 (getrandom) with Linux-compatible signature.
- **FR-RAND-02**: getrandom MUST write up to buflen bytes of random data to the provided buffer.
- **FR-RAND-03**: getrandom MUST support flags = 0 for default behavior (urandom source).
- **FR-RAND-04**: getrandom SHOULD support GRND_NONBLOCK (0x1) flag to return -EAGAIN if entropy unavailable.
- **FR-RAND-05**: getrandom with invalid buffer pointer MUST return -EFAULT.
- **FR-RAND-06**: For MVP, getrandom MAY use a PRNG (xorshift, LCG) seeded from RDRAND, RDTSC, or boot timestamp.
- **FR-RAND-07**: If RDRAND instruction is available (check CPUID), it SHOULD be used for initial entropy.
- **FR-RAND-08**: The PRNG state MUST be initialized at kernel boot before any user process starts.

**VFS Device Shim**

The kernel provides a minimal VFS shim for virtual device paths.

**Supported Paths**:
| Path | Behavior |
|------|----------|
| /dev/null | Discards writes, returns EOF on read |
| /dev/zero | Returns zero bytes on read |
| /dev/console | Maps to console output |
| /dev/stdin | Maps to FD 0 behavior |
| /dev/stdout | Maps to FD 1 behavior |
| /dev/stderr | Maps to FD 2 behavior |
| /dev/urandom | Returns PRNG bytes |
| /dev/random | Same as /dev/urandom (MVP) |

- **FR-VFS-01**: sys_open MUST check for /dev/ prefix before InitRD lookup
- **FR-VFS-02**: If VFS shim has mapping for /dev/ path, allocate FD with device kind
- **FR-VFS-03**: If no VFS mapping exists for /dev/ path, return -ENOENT (not fall through)
- **FR-VFS-04**: Non-/dev/ paths use InitRD lookup
- **FR-VFS-05**: /dev/console MUST map to console output (FD behavior matching stdout)
- **FR-VFS-06**: /dev/null MUST return EOF on read and discard writes

**Implementation Note**:
This is a kernel lookup table, not a filesystem. No inodes, no directory operations, no mount points.

### Key Entities

- **File Descriptor Table**: Per-process array mapping FD numbers (0, 1, 2, ...) to kernel file/device objects.
- **Zombie Process**: Terminated process awaiting parent acknowledgment; retains PID and exit status only.
- **timespec Structure**: Linux-compatible time structure with seconds (tv_sec) and nanoseconds (tv_nsec).
- **PRNG State**: Kernel random number generator state, seeded at boot, providing getrandom data.
- **Wait Queue**: Processes blocked in wait4, woken when a child changes state.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Static C "Hello World" using printf (which writes to FD 1) prints correctly without explicit open() calls.
- **SC-002**: Zig programs using std.debug.print produce correct output on ZigK.
- **SC-003**: Shell waits for child processes to complete before displaying the next prompt.
- **SC-004**: Programs using CLOCK_MONOTONIC measure elapsed time within 10% accuracy.
- **SC-005**: Programs calling clock_gettime with CLOCK_REALTIME receive a valid Unix timestamp.
- **SC-006**: Zig HashMap initialization succeeds using getrandom for seed.
- **SC-007**: Python REPL (when supported) successfully starts and runs basic commands.
- **SC-008**: Zombie processes are correctly reaped when parent calls wait4.
- **SC-009**: wait4 with WNOHANG returns 0 immediately when no child has exited.
- **SC-010**: 1000 allocation/free cycles with runtime library code complete without hash collision attacks or crashes.

## Consolidated Linux Syscall Table for MVP

This specification, combined with 005-linux-syscall-compat and 006-sysv-abi-init, provides the following syscall coverage:

| Linux ID | Name             | ZigK MVP Implementation Notes                          |
|----------|------------------|--------------------------------------------------------|
| 0        | sys_read         | Read from Console (FD 0) or InitRD files              |
| 1        | sys_write        | Write to Console (FD 1/2)                              |
| 2        | sys_open         | Open InitRD files                                      |
| 3        | sys_close        | Close FDs                                              |
| 9        | sys_mmap         | Allocate Heap / Map Framebuffer (w/ custom flag)       |
| 10       | sys_mprotect     | Change memory protection                               |
| 11       | sys_munmap       | Free Heap                                              |
| 12       | sys_brk          | Legacy Heap (libc compatibility)                       |
| 24       | sys_sched_yield  | Yield CPU                                              |
| 35       | sys_nanosleep    | Sleep                                                  |
| 39       | sys_getpid       | Return Thread ID                                       |
| 41       | sys_socket       | Create UDP socket handle                               |
| 44       | sys_sendto       | Send UDP                                               |
| 45       | sys_recvfrom     | Recv UDP                                               |
| 60       | sys_exit         | Terminate thread                                       |
| 61       | sys_wait4        | Wait for child (Shell requirement)                     |
| 158      | sys_arch_prctl   | Set FS/GS base (TLS for Zig/C runtimes)                |
| 228      | sys_clock_gettime| Time/Performance counters                              |
| 318      | sys_getrandom    | Entropy for Hash Maps                                  |

**Custom Extensions (1000+)**:

| ZigK ID | Name              | Implementation Notes                                   |
|---------|-------------------|--------------------------------------------------------|
| 1000    | sys_debug_log     | Bypass FD 1 for kernel debugging                       |
| 1001    | sys_map_fb        | Map framebuffer into userspace                         |
| 1002    | sys_read_scancode | Game input (raw keyboard scancodes)                    |

## Assumptions

- Target ABI is Linux x86_64 (System V AMD64 calling convention).
- RDRAND instruction availability is checked via CPUID; fallback to RDTSC-based entropy if unavailable.
- CLOCK_REALTIME returns a static epoch (e.g., 2025-01-01 00:00:00) if no hardware RTC is available.
- CLOCK_MONOTONIC uses the TSC or PIT timer ticks converted to nanoseconds.
- For MVP, the PRNG for getrandom is "insecure" but functionally compatible for runtime bootstrapping.
- Init process (PID 1) is responsible for reaping orphaned zombies.
- This specification complements 005-linux-syscall-compat and 006-sysv-abi-init for complete Linux ABI compatibility.
