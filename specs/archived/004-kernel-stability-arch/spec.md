# Feature Specification: Kernel Stability Architecture Improvements

**Feature Branch**: `004-kernel-stability-arch`
**Created**: 2025-12-05
**Status**: Draft
**Input**: Architectural improvements for Phase 3/4 microkernel milestone addressing FPU/SSE state preservation, network buffer ownership, spinlock concurrency, struct alignment, socket abstraction, canonical address verification, build system configuration, userland process lifecycle, stack overflow detection, crash diagnostics, loopback networking, and DMA memory ordering.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Interrupt-Safe FPU/SSE State Preservation (Priority: P1)

As a kernel developer, I need the kernel to preserve userland FPU/SSE register state across interrupt boundaries so that userland programs performing floating-point or SIMD operations don't experience register corruption when interrupts fire.

**Why this priority**: This is a critical stability issue. Without FPU/SSE state preservation, any userland program using floating-point math (which is extremely common) will produce incorrect results or crash unpredictably after interrupts. This is a "silent killer" bug that is extremely difficult to diagnose.

**Independent Test**: Can be tested by running a userland program that performs continuous floating-point calculations while triggering frequent interrupts. The calculations must produce consistent, correct results.

**Acceptance Scenarios**:

1. **Given** a userland program performing XMM register operations, **When** an interrupt fires and the kernel ISR uses memcpy or other SIMD-using code, **Then** the userland XMM registers are restored to their pre-interrupt values upon IRET.
2. **Given** the kernel interrupt context structure, **When** an interrupt stub executes, **Then** the fxsave/fxrstor (or xsave/xrstor) instructions preserve the 512-byte FPU/SSE state area.
3. **Given** any interrupt handler, **When** it completes, **Then** the userland program continues with mathematically correct results.

---

### User Story 2 - Spinlock-Based Concurrency (Priority: P1)

As a kernel developer, I need fine-grained spinlock primitives instead of CLI-based "big kernel lock" so that syscalls can run with interrupts enabled and avoid deadlock scenarios during operations like ARP resolution.

**Why this priority**: Using CLI as a global lock causes deadlocks when a syscall (like sys_send_udp) triggers ARP resolution that requires receiving an interrupt-delivered ARP reply. This makes the entire kernel non-functional.

**Independent Test**: Can be tested by issuing a syscall that triggers ARP resolution and verifying the kernel can receive and process the ARP reply interrupt while the syscall is pending.

**Acceptance Scenarios**:

1. **Given** a syscall that requires ARP resolution, **When** the syscall initiates ARP lookup, **Then** interrupts remain enabled so ARP reply packets can be received.
2. **Given** the heap allocator or ARP cache, **When** multiple contexts (syscall and interrupt) attempt simultaneous access, **Then** a spinlock protects the data structure from corruption.
3. **Given** a syscall that cannot proceed due to missing ARP entry, **When** the ARP lookup is incomplete, **Then** the syscall returns a retry indicator rather than blocking with interrupts disabled.

---

### User Story 3 - Network Buffer Ownership Model (Priority: P2)

As a kernel developer, I need a clear buffer ownership model for network packet handling so that DMA ring buffers are not reused while the network stack still holds references to them.

**Why this priority**: Without clear ownership, packets received via DMA can be overwritten by new incoming packets before the stack finishes processing them. This causes data corruption and is a fundamental correctness issue, though for MVP a copy-out approach provides safety.

**Independent Test**: Can be tested by receiving a burst of network packets while the stack delays processing, and verifying no packet data corruption occurs.

**Acceptance Scenarios**:

1. **Given** a packet received into a DMA ring buffer, **When** the driver passes it to the network stack, **Then** the packet data is immediately copied to a kernel heap buffer for stack processing.
2. **Given** the DMA ring descriptor, **When** the packet has been copied out, **Then** the descriptor is immediately returned to the hardware for reuse.
3. **Given** a high packet arrival rate, **When** processing is slower than arrival, **Then** packets are dropped gracefully rather than corrupted.

---

### User Story 4 - Canonical Address Verification (Priority: P2)

As a kernel developer, I need syscall argument validation to check for canonical x86_64 addresses so that non-canonical user pointers trigger proper error handling rather than General Protection Faults.

**Why this priority**: Non-canonical addresses (where bits 48-63 don't match bit 47) cause #GP faults rather than #PF faults when dereferenced. A simple "addr < KERNEL_BASE" check is insufficient and leads to kernel crashes on malformed pointers.

**Independent Test**: Can be tested by passing a non-canonical address (e.g., 0x0000_8000_0000_0000) to a syscall and verifying it returns an error code rather than crashing.

**Acceptance Scenarios**:

1. **Given** a syscall that accepts a user pointer, **When** the pointer is non-canonical, **Then** the syscall returns an error before attempting to dereference the pointer.
2. **Given** a canonical user-space address, **When** it passes validation, **Then** the syscall proceeds to verify it's in valid user memory range.
3. **Given** any user-provided address, **When** validation runs, **Then** both canonicality and user-space range are verified.

---

### User Story 5 - Socket Abstraction Layer (Priority: P3)

As a kernel developer, I need a lightweight socket abstraction with per-socket receive queues so that UDP packet reception is properly demultiplexed and the architecture extends naturally to TCP.

**Why this priority**: Without socket abstraction, UDP is a "global free-for-all" that's hard to separate per-process and makes TCP implementation much harder later. This is a future-proofing investment.

**Independent Test**: Can be tested by binding two different UDP ports from userland and verifying packets to each port arrive in their respective receive queues.

**Acceptance Scenarios**:

1. **Given** a userland process that binds a UDP port, **When** a packet arrives for that port, **Then** the packet is placed in that socket's specific receive queue.
2. **Given** a file descriptor returned from socket creation, **When** the process calls recv, **Then** it receives packets only from its bound port.
3. **Given** the bind table in the kernel, **When** a packet arrives, **Then** the destination port lookup determines which socket's queue receives the packet.

---

### User Story 6 - Proper Struct Alignment for Hardware Interfaces (Priority: P3)

As a kernel developer, I need hardware descriptor structures to use proper alignment (extern struct or explicit alignment) so that memory-mapped I/O works correctly with hardware that expects natural alignment.

**Why this priority**: Zig's packed struct has specific alignment semantics that may conflict with hardware expectations (e.g., E1000 descriptors need 16-byte alignment). Incorrect alignment causes silent hardware misbehavior.

**Independent Test**: Can be tested by allocating E1000 descriptor rings and verifying each descriptor address is 16-byte aligned.

**Acceptance Scenarios**:

1. **Given** E1000 TX/RX descriptor allocation, **When** the allocator returns memory, **Then** each descriptor is aligned to 16 bytes.
2. **Given** hardware descriptor struct definitions, **When** compiled, **Then** field offsets match hardware specification requirements.
3. **Given** the heap allocator, **When** requesting aligned allocations, **Then** the returned pointer respects the requested alignment.

---

### User Story 7 - Userland Process Lifecycle (Priority: P1)

As a kernel developer, I need userland processes to properly start, execute, and terminate without causing system crashes. When a user process's `main()` function returns, the system must gracefully handle cleanup and exit rather than executing garbage memory.

**Why this priority**: Without proper process lifecycle management, no userland code can safely run. This is the foundation for all user-space functionality including shell execution and networking services.

**Independent Test**: Can be fully tested by spawning a simple user process that returns from main() and verifying the system remains stable with proper exit handling.

**Acceptance Scenarios**:

1. **Given** a user process with a main() function, **When** main() returns with an exit code, **Then** the system calls exit() and cleanly terminates the process without CPU faults.
2. **Given** a user process that exits, **When** the exit occurs, **Then** process resources are released and the scheduler removes it from the run queue.
3. **Given** the kernel transitioning to userland, **When** IRETQ is executed, **Then** segment selectors have RPL=3 bits set (CS | 3, SS | 3) to prevent General Protection Faults.

---

### User Story 8 - Stack Overflow Detection (Priority: P1)

As a kernel developer, I need immediate notification when kernel thread stacks overflow rather than silent memory corruption that causes mysterious crashes later.

**Why this priority**: Stack corruption is one of the most difficult bugs to diagnose. Without guard pages, overflows corrupt adjacent memory silently, leading to crashes with no clear cause.

**Independent Test**: Can be tested by deliberately causing a stack overflow in a kernel thread and verifying an immediate page fault at the guard page address.

**Acceptance Scenarios**:

1. **Given** a kernel stack allocation, **When** the stack is created, **Then** an unmapped guard page exists at the bottom of the stack (N+1 pages allocated, bottom page not present).
2. **Given** a thread overflows its stack, **When** the stack pointer reaches the guard page, **Then** a page fault is immediately triggered.
3. **Given** a stack overflow page fault, **When** the fault handler runs, **Then** the faulting thread ID and guard page address are logged to serial.

---

### User Story 9 - Crash Diagnostics (Priority: P2)

As a kernel developer investigating crashes, I need to see the faulting instruction address and memory address to correlate with source code using addr2line.

**Why this priority**: Without crash diagnostics, developers cannot identify which line of code caused the crash, making debugging extremely time-consuming.

**Independent Test**: Can be tested by causing a deliberate null pointer dereference and verifying CR2 and RIP values are printed.

**Acceptance Scenarios**:

1. **Given** a page fault occurs, **When** the fault handler runs, **Then** the CR2 (fault address) and RIP (instruction pointer) are printed to serial.
2. **Given** crash diagnostic output, **When** a developer uses llvm-addr2line with the RIP value, **Then** they can identify the exact source file and line number.
3. **Given** any CPU exception, **When** the exception handler runs, **Then** relevant register values are dumped for debugging.

---

### User Story 10 - Loopback Network Testing (Priority: P2)

As a kernel developer, I need to test the network stack (IP, UDP, ARP, checksums) without setting up complex QEMU TAP/bridge configurations, enabling faster development iterations.

**Why this priority**: Hardware-independent testing accelerates development. Loopback allows testing protocol logic separately from driver bugs.

**Independent Test**: Can be tested by sending a packet to 127.0.0.1 and verifying it is received by the same system through the protocol stack.

**Acceptance Scenarios**:

1. **Given** a loopback network interface, **When** a packet is sent to 127.0.0.1, **Then** the packet is immediately delivered back through the receive path.
2. **Given** loopback and E1000 drivers, **When** either is selected, **Then** they expose the same network interface for upper layers.
3. **Given** a loopback ping, **When** the full IP/ICMP stack processes it, **Then** checksums, ARP tables, and routing work correctly.

---

### User Story 11 - DMA Memory Ordering (Priority: P2)

As a kernel developer working with DMA devices (E1000, future NVMe), I need confidence that descriptor writes are committed to RAM before signaling hardware, preventing silent data corruption.

**Why this priority**: DMA bugs are extremely subtle - the system may work 99% of the time but occasionally corrupt data. Proper barriers ensure correctness.

**Independent Test**: Can be tested by verifying network packets are transmitted correctly under load, indicating descriptor writes are properly ordered.

**Acceptance Scenarios**:

1. **Given** a DMA descriptor ring, **When** descriptor fields are written, **Then** a memory barrier ensures writes are committed before updating the tail register.
2. **Given** volatile-marked DMA structures, **When** accessed, **Then** the compiler does not optimize away or reorder accesses.
3. **Given** the E1000 driver, **When** transmitting packets, **Then** no packets are corrupted due to write ordering issues.

---

### User Story 12 - Build System Code Model Configuration (Priority: P3)

As a kernel developer, I need the build system to configure the kernel code model correctly so that the Higher Half kernel can use efficient 32-bit signed relative addressing.

**Why this priority**: Without code_model = .kernel, the compiler may generate 64-bit absolute addressing that causes linker errors about relocations being out of range. This is a build-time issue that prevents compilation.

**Independent Test**: Can be tested by building the kernel and verifying no linker relocation errors occur for Higher Half addresses.

**Acceptance Scenarios**:

1. **Given** the kernel build configuration, **When** compiling for freestanding x86_64, **Then** the code model is set to .kernel.
2. **Given** kernel code in the Higher Half address space, **When** compiled, **Then** relative jumps and RIP-relative addressing work correctly.
3. **Given** any kernel build, **When** linking completes, **Then** no relocation overflow errors occur.

---

### Edge Cases

- What happens when fxsave/fxrstor is used on hardware without FPU/SSE support? (Must detect and handle legacy hardware or require SSE.)
- How does the spinlock handle nested acquisition attempts? (Must detect deadlock or use reentrant locking.)
- What happens when the network buffer pool is exhausted? (Must drop packets gracefully and log.)
- How does validation handle kernel-space addresses passed from userland? (Must reject any address >= KERNEL_BASE.)
- What happens when socket receive queues overflow? (Must drop oldest or newest packets with clear policy.)
- What happens when a thread exhausts its stack during interrupt handling (nested stack usage)?
- How does the system handle a page fault while already handling a page fault (double fault)?
- What happens when the loopback receive buffer is full when sending?
- How does serial logging behave when called from interrupt context while the lock is held?
- What happens if a user process attempts to execute kernel memory (SMEP/SMAP violations)?
- What happens when main() returns a non-zero exit code?

## Requirements *(mandatory)*

### Functional Requirements

**Interrupt State Preservation**

- **FR-001**: Kernel MUST save the 512-byte FPU/SSE state (fxsave) at interrupt entry before any kernel code executes.
- **FR-002**: Kernel MUST restore the FPU/SSE state (fxrstor) at interrupt exit after all kernel code completes.
- **FR-003**: The InterruptContext structure MUST include a 16-byte aligned fxsave_area of 512 bytes.

**Concurrency Primitives**

- **FR-004**: Kernel MUST provide a Spinlock primitive using atomic read-modify-write operations.
- **FR-005**: Syscalls MUST execute with interrupts enabled (except for brief critical sections protected by spinlocks).
- **FR-006**: The heap allocator MUST be protected by a spinlock for concurrent access.
- **FR-007**: The ARP cache MUST be protected by a spinlock for concurrent access.
- **FR-008**: Syscalls requiring unavailable resources (e.g., missing ARP entry) MUST return a retry error code rather than blocking.

**Network Buffer Management**

- **FR-009**: The network driver MUST copy received packet data from DMA buffers to kernel heap buffers immediately upon receipt.
- **FR-010**: DMA ring descriptors MUST be returned to hardware ownership immediately after packet copy-out.
- **FR-011**: The kernel MUST track buffer ownership through a clear allocation/free lifecycle.

**Address Validation**

- **FR-012**: All user pointer arguments MUST be validated for x86_64 canonical form before use.
- **FR-013**: Canonical validation MUST verify that bits 48-63 match bit 47 (sign extension).
- **FR-014**: User pointers MUST be verified to be below the kernel base address.
- **FR-015**: Validation failures MUST return an error code without attempting dereference.

**Socket Abstraction**

- **FR-016**: Kernel MUST maintain a Socket structure with associated receive queue for each bound port.
- **FR-017**: Kernel MUST maintain a BindTable mapping port numbers to Socket structures.
- **FR-018**: Incoming packets MUST be demultiplexed by destination port and placed in the appropriate Socket's receive queue.
- **FR-019**: The sys_recv_udp syscall MUST read from the calling process's Socket receive queue.

**Struct Alignment**

- **FR-020**: Hardware descriptor structures MUST use extern struct or explicit alignment annotations to match hardware requirements.
- **FR-021**: The heap allocator MUST support aligned allocation requests (allocAligned function).
- **FR-022**: E1000 descriptor rings MUST be allocated with 16-byte alignment.

**Userland Process Lifecycle**

- **FR-025**: Kernel MUST provide a userland entry point stub (crt0/start.zig) that calls exit() when main() returns.
- **FR-026**: The crt0 stub MUST use naked calling convention and noreturn semantics.
- **FR-027**: Kernel MUST set RPL=3 (bits 0-1) on CS and SS selectors when returning to userland via IRETQ.
- **FR-028**: The exit() syscall MUST cleanly terminate the process and release its resources.

**Stack Overflow Protection**

- **FR-029**: Kernel MUST allocate N+1 pages for kernel stacks with the bottom page left unmapped as a guard page.
- **FR-030**: The guard page MUST have its Present bit cleared to trigger page faults on access.
- **FR-031**: Stack overflow page faults MUST log the faulting thread ID and fault address.

**Crash Diagnostics**

- **FR-032**: Page fault handler MUST print CR2 (fault address) and RIP (instruction pointer) values to serial.
- **FR-033**: Exception handlers MUST dump relevant register values for debugging.
- **FR-034**: Kernel MUST provide a dump_registers or dump_stack_trace helper function.

**Loopback Network Interface**

- **FR-035**: Kernel MUST provide a loopback network interface (lo0) implementing the same interface as hardware drivers.
- **FR-036**: Loopback send() MUST immediately call receive() on the same interface with the packet data.
- **FR-037**: Loopback interface MUST support testing of IP, ARP, checksums, and port dispatch.

**DMA Memory Ordering**

- **FR-038**: DMA descriptor writes MUST use memory barriers (compiler fence) before updating hardware tail registers.
- **FR-039**: DMA structures MUST be marked volatile to prevent compiler optimization of hardware-visible memory.
- **FR-040**: Memory barriers MUST be implemented as `asm volatile("" ::: "memory")` for x86.

**Build Configuration**

- **FR-023**: The build system MUST set code_model to .kernel for the kernel target.
- **FR-024**: The kernel linker script MUST place the kernel in the Higher Half address space.

### Key Entities

- **InterruptContext**: Holds saved CPU state during interrupts, including general-purpose registers and fxsave_area for FPU/SSE state.
- **Spinlock**: Atomic lock primitive for protecting shared kernel resources from concurrent access.
- **NetworkBuffer**: Kernel heap buffer holding copied packet data with clear ownership semantics.
- **Socket**: Kernel structure representing a bound network endpoint with receive queue.
- **BindTable**: Mapping from port numbers to Socket structures for packet demultiplexing.
- **CanonicalAddress**: Validated user-space pointer that has passed canonicality and range checks.
- **Thread Control Block**: Represents a schedulable unit with stack pointer, state, and ID.
- **Guard Page**: An unmapped memory page at stack bottom for overflow detection.
- **NetworkInterface**: Abstract interface for network drivers (loopback or hardware E1000).
- **DMA Descriptor Ring**: Circular buffer shared between CPU and hardware for packet transmission/reception.
- **CRT0 Stub**: Minimal userland entry point that handles main() return and calls exit().

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Userland programs performing continuous floating-point operations produce 100% correct results across 1 million interrupt cycles.
- **SC-002**: Syscalls that trigger ARP resolution complete successfully without deadlock in all test scenarios.
- **SC-003**: Network packet processing handles burst traffic of 10,000 packets without data corruption.
- **SC-004**: Non-canonical address syscall arguments are rejected 100% of the time without kernel crashes.
- **SC-005**: Multiple UDP sockets bound to different ports receive only their own traffic with 100% accuracy.
- **SC-006**: Kernel builds complete without linker relocation errors for Higher Half addressing.
- **SC-007**: All hardware descriptor allocations meet 16-byte alignment requirements.
- **SC-008**: User processes can execute and exit cleanly with 100% of test runs producing no CPU faults on main() return.
- **SC-009**: Serial output from 4+ concurrent threads shows zero interleaved characters across 1000 log messages.
- **SC-010**: Stack overflow is detected immediately with page fault at guard address in 100% of overflow scenarios.
- **SC-011**: Crash dumps include CR2 and RIP values that correctly map to source locations via llvm-addr2line.
- **SC-012**: Loopback network successfully delivers packets through full IP stack without hardware dependencies.
- **SC-013**: Network transmissions under load show zero corrupted packets due to memory ordering issues.

## Assumptions

- Target architecture is x86_64 with standard paging and segment selectors.
- The target hardware supports SSE (required for fxsave/fxrstor). Legacy x87-only systems are not supported.
- Single-CPU execution (no SMP considerations for spinlocks in this phase).
- Network buffer pool size is statically configured and sufficient for expected traffic.
- Socket receive queues have a fixed maximum size; overflow drops newest packets.
- QEMU/emulated E1000 hardware is the primary test environment.
- The kernel runs in Ring 0 with full hardware access.
- Serial port (COM1) is available for debug output.
- Limine bootloader is used, providing standard memory map and boot information.
- 8KB or 16KB kernel stacks are sufficient for most operations.
- Spinlocks are sufficient for single-core operation (vs. more complex locking primitives).
