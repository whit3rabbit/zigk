# Feature Specification: Linux Syscall ABI Compatibility

**Feature Branch**: `005-linux-syscall-compat`
**Created**: 2025-12-05
**Status**: Draft
**Input**: Adopt Linux x86_64 syscall ABI to enable running standard software (C programs, Zig std lib) without porting

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Run Static C "Hello World" (Priority: P1)

As a kernel developer, I want to compile a simple C program on Linux using static linking and run it directly on ZigK without modification, proving basic Linux binary compatibility.

**Why this priority**: This is the minimal proof that Linux ABI compatibility works. If a static "Hello World" runs, the core syscall dispatch (write, exit) is correct, and the path is open for more complex software.

**Independent Test**: Compile `int main() { write(1, "Hello\n", 6); return 0; }` with `gcc -static -o hello hello.c` on Linux, copy to ZigK initrd, and verify it prints "Hello" and exits cleanly.

**Acceptance Scenarios**:

1. **Given** a statically-linked Linux x86_64 binary using sys_write(1) and sys_exit(60), **When** executed on ZigK, **Then** it produces correct output and exits with the specified code.
2. **Given** a Linux binary calling syscall 1 (write) with fd=1, **When** executed, **Then** the output appears on the console/serial.
3. **Given** a Linux binary calling syscall 60 (exit) with code 0, **When** executed, **Then** the process terminates and the scheduler removes it.

---

### User Story 2 - Run Zig Programs with Standard Library (Priority: P1)

As a kernel developer, I want to compile Zig programs targeting `x86_64-linux-musl` and have `std.debug.print` work correctly on ZigK.

**Why this priority**: Zig is the native development language for ZigK. If Zig's standard library works, developers can use familiar debugging and I/O patterns without custom OS ports.

**Independent Test**: Compile a Zig program with `std.debug.print("Test\n", .{})` targeting linux-musl, run on ZigK, and verify output appears.

**Acceptance Scenarios**:

1. **Given** a Zig program compiled with `-target x86_64-linux-musl`, **When** it calls std.debug.print, **Then** the output appears correctly on ZigK.
2. **Given** Zig's std library using syscall 1 (write), **When** the program runs, **Then** writes to stdout (fd 1) appear on the console.
3. **Given** a Zig program that exits normally, **When** main() returns, **Then** the exit syscall terminates the process cleanly.

---

### User Story 3 - Network Socket Operations (Priority: P2)

As a kernel developer, I want standard socket syscalls (socket, sendto, recvfrom) to work so that networking code compiled for Linux can run on ZigK.

**Why this priority**: Network compatibility enables standard socket-based applications. Using Berkeley socket API numbers (41, 44, 45) means Python's socket module and similar can eventually work.

**Independent Test**: Create a UDP echo client using socket/sendto/recvfrom syscalls on Linux, run it on ZigK against loopback, and verify packets are sent and received.

**Acceptance Scenarios**:

1. **Given** a program calling syscall 41 (socket) for UDP, **When** executed, **Then** a valid file descriptor is returned.
2. **Given** a program calling syscall 44 (sendto) with a UDP socket, **When** executed, **Then** the packet is transmitted correctly.
3. **Given** a program calling syscall 45 (recvfrom) on a bound socket, **When** a packet arrives, **Then** the data and source address are returned correctly.

---

### User Story 4 - Memory Allocation via brk (Priority: P2)

As a kernel developer, I want the brk syscall (12) to work with Linux semantics so that C library heap allocators (musl, glibc static) function correctly.

**Why this priority**: Most C programs require dynamic memory. The brk syscall is the foundation for malloc in static libc implementations. Getting this right enables complex software.

**Independent Test**: Run a C program that allocates memory with malloc(), writes to it, and reads back correctly.

**Acceptance Scenarios**:

1. **Given** a program calling syscall 12 (brk) with address 0, **When** executed, **Then** the current program break address is returned.
2. **Given** a program calling syscall 12 (brk) with a higher address, **When** executed, **Then** the program break is extended and the new address is returned.
3. **Given** memory allocated via brk, **When** the program writes and reads, **Then** data is preserved correctly.

---

### User Story 5 - Process Scheduling Syscalls (Priority: P3)

As a kernel developer, I want sched_yield (24), nanosleep (35), and getpid (39) syscalls to work so that multi-threaded and timing-aware Linux programs function correctly.

**Why this priority**: These syscalls enable cooperative multitasking, timing delays, and process identification - common patterns in real applications.

**Independent Test**: Run a program that calls getpid(), sleeps for 100ms, and yields, verifying each syscall behaves correctly.

**Acceptance Scenarios**:

1. **Given** a program calling syscall 39 (getpid), **When** executed, **Then** the current process ID is returned.
2. **Given** a program calling syscall 35 (nanosleep) with a timespec struct, **When** executed, **Then** the process sleeps for the specified duration.
3. **Given** a program calling syscall 24 (sched_yield), **When** executed, **Then** the scheduler runs another process (if available) before returning.

---

### User Story 6 - File Descriptor Operations (Priority: P3)

As a kernel developer, I want read (0), open (2), and close (3) syscalls to work with Linux numbers so that file-based I/O patterns are compatible.

**Why this priority**: File descriptor operations are fundamental to Unix-style programs. Even without a full filesystem, these syscalls are needed for stdin/stdout and future device access.

**Independent Test**: Open a file from initrd, read its contents, and close it using Linux syscall numbers.

**Acceptance Scenarios**:

1. **Given** a program calling syscall 0 (read) on stdin, **When** input is available, **Then** data is read correctly.
2. **Given** a program calling syscall 2 (open) on an initrd file, **When** the file exists, **Then** a valid file descriptor is returned.
3. **Given** a program calling syscall 3 (close) on an open descriptor, **When** executed, **Then** the descriptor is released and subsequent use fails.

---

### User Story 7 - Custom ZigK Extensions (Priority: P3)

As a kernel developer, I want ZigK-specific features (framebuffer, scancodes) accessible via syscalls in the 1000+ range so they don't conflict with future Linux syscalls.

**Why this priority**: Custom features are needed for ZigK's unique capabilities (graphical output, direct keyboard access) while preserving Linux compatibility for standard operations.

**Independent Test**: Call syscall 1000 (get_fb_info), syscall 1001 (map_fb), and syscall 1002 (read_scancode) and verify they work correctly.

**Acceptance Scenarios**:

1. **Given** a program calling syscall 1000 (get_fb_info), **When** executed, **Then** framebuffer dimensions and format are returned.
2. **Given** a program calling syscall 1001 (map_fb), **When** executed, **Then** the framebuffer is mapped into user address space.
3. **Given** a program calling syscall 1002 (read_scancode), **When** a key is pressed, **Then** the raw scancode is returned.

---

### Edge Cases

- What happens when an unimplemented Linux syscall number is called? (Must return -ENOSYS error)
- How does the system handle syscall arguments that exceed valid ranges?
- What happens when brk is called with an address lower than the current break?
- How does nanosleep handle being interrupted by a signal (if signals are later implemented)?
- What happens when socket operations are called before network initialization?
- How does the system handle file descriptors that were never opened?

## Requirements *(mandatory)*

### Functional Requirements

**Core Syscall Renumbering**

- **FR-001**: Kernel MUST use Linux x86_64 syscall number 0 for sys_read.
- **FR-002**: Kernel MUST use Linux x86_64 syscall number 1 for sys_write.
- **FR-003**: Kernel MUST use Linux x86_64 syscall number 2 for sys_open.
- **FR-004**: Kernel MUST use Linux x86_64 syscall number 3 for sys_close.
- **FR-005**: Kernel MUST use Linux x86_64 syscall number 12 for sys_brk (replacing custom sbrk).
- **FR-006**: Kernel MUST use Linux x86_64 syscall number 24 for sys_sched_yield.
- **FR-007**: Kernel MUST use Linux x86_64 syscall number 35 for sys_nanosleep.
- **FR-008**: Kernel MUST use Linux x86_64 syscall number 39 for sys_getpid.
- **FR-009**: Kernel MUST use Linux x86_64 syscall number 60 for sys_exit.

**Network Socket Compatibility**

- **FR-010**: Kernel MUST use Linux x86_64 syscall number 41 for sys_socket.
- **FR-011**: Kernel MUST use Linux x86_64 syscall number 44 for sys_sendto (replacing custom SYS_SEND_UDP).
- **FR-012**: Kernel MUST use Linux x86_64 syscall number 45 for sys_recvfrom (replacing custom SYS_RECV_UDP).

**Syscall Semantics**

- **FR-013**: sys_brk MUST accept an absolute address (not increment) and return the new/current program break.
- **FR-014**: sys_brk MUST return the current break when called with address 0.
- **FR-015**: sys_nanosleep MUST accept a pointer to a timespec structure (seconds, nanoseconds).
- **FR-016**: sys_socket MUST return a file descriptor for the requested socket type.
- **FR-017**: sys_sendto and sys_recvfrom MUST accept sockaddr structures for addressing.

**ZigK Custom Extensions**

- **FR-018**: Kernel MUST reserve syscall numbers 1000+ for ZigK-specific extensions.
- **FR-019**: Kernel MUST implement syscall 1000 for get_framebuffer_info.
- **FR-020**: Kernel MUST implement syscall 1001 for map_framebuffer.
- **FR-021**: Kernel MUST implement syscall 1002 for read_scancode.

**Error Handling**

- **FR-022**: Unimplemented syscall numbers MUST return -ENOSYS (error code 38).
- **FR-023**: Invalid syscall arguments MUST return appropriate Linux error codes (EINVAL, EFAULT, EBADF, etc.).

### Key Entities

- **Syscall Number Table**: Mapping of syscall numbers to handler functions, using Linux x86_64 ABI.
- **timespec Structure**: Linux-compatible time structure with seconds and nanoseconds fields.
- **sockaddr Structure**: Linux-compatible socket address structure for network operations.
- **File Descriptor**: Integer handle for open files, sockets, and devices.
- **Process Break**: Memory address marking the end of the process data segment (for brk).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Static Linux x86_64 "Hello World" binary runs correctly on ZigK with no modifications.
- **SC-002**: Zig programs compiled with `-target x86_64-linux-musl` produce correct std.debug.print output.
- **SC-003**: C programs using malloc/free (via brk) allocate and access memory correctly.
- **SC-004**: UDP network programs using socket/sendto/recvfrom transmit packets successfully.
- **SC-005**: Programs calling getpid receive a valid process ID.
- **SC-006**: Programs calling nanosleep pause for the correct duration (within 10% accuracy).
- **SC-007**: ZigK custom syscalls (1000+) function without conflicting with Linux numbers.
- **SC-008**: Unimplemented syscalls return -ENOSYS consistently.

## Assumptions

- Target ABI is Linux x86_64 (System V AMD64 calling convention for syscalls).
- Only essential syscalls are implemented initially; full POSIX compliance is not required.
- Static linking is the primary use case; dynamic linking/ld.so is out of scope.
- Signals are not implemented in this phase; nanosleep cannot be interrupted.
- File operations (open/read/close) work only with initrd files initially.
- Socket operations are limited to UDP; TCP is out of scope for this feature.
- The existing custom syscall implementations are refactored, not duplicated.
