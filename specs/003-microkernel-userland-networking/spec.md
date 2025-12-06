# Feature Specification: Monolithic Kernel with Userland and Networking

**Feature Branch**: `003-microkernel-userland-networking`
**Created**: 2025-12-04
**Status**: Draft
**Input**: User description: "Monolithic Kernel with Userland and Networking: Memory (Paging/VMM, Heap Allocator), Interrupts (Keyboard/Network IRQs), Preemptive Multitasking, E1000 Networking (ARP/UDP/ICMP), Ring 3 Userland Shell with Syscalls"

**Architecture Note**: This is technically a **Monolithic Kernel** (drivers compile into the kernel binary, running in Ring 0). The branch name retains "microkernel" for historical reasons. In a true microkernel, drivers run as separate userspace processes (Ring 3).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - ICMP Ping Reply (Priority: P1)

The kernel can respond to incoming ICMP echo requests (pings) from external systems on the network. When a remote machine sends a ping to the kernel's network interface, the kernel receives the packet through the network driver, processes it through the network stack, recognizes it as an ICMP echo request, and sends back an appropriate ICMP echo reply.

**Why this priority**: This is the core goal of the MVP. Ping reply demonstrates that all fundamental networking components are working together: the network driver, interrupt handling, packet parsing, and packet transmission. It's a clear, binary success metric.

**Independent Test**: Can be tested by running the kernel in QEMU with network enabled and pinging the virtual machine's IP address from the host. Success means receiving ping replies.

**Acceptance Scenarios**:

1. **Given** the kernel is running with an assigned IP address, **When** an external host sends an ICMP echo request, **Then** the kernel sends back an ICMP echo reply within 100ms
2. **Given** the kernel is under normal operation, **When** multiple pings are received in sequence, **Then** each ping receives a corresponding reply in order
3. **Given** the kernel receives a malformed ICMP packet, **When** parsing fails, **Then** the packet is dropped silently without crashing

---

### User Story 2 - Preemptive Multitasking with Two Threads (Priority: P1)

The kernel runs at least two concurrent threads: a kernel network worker thread that handles incoming network packets and a userland terminal thread. The scheduler preemptively switches between these threads based on time slices, ensuring neither thread monopolizes the CPU.

**Why this priority**: Multitasking is foundational for the system. Without it, the kernel cannot simultaneously handle network events and user interaction. This is a prerequisite for the other features.

**Independent Test**: Can be tested by running both threads and observing that keyboard input is processed while network packets are also being handled. Neither task should block the other.

**Acceptance Scenarios**:

1. **Given** both network worker and terminal threads are running, **When** a timer interrupt fires, **Then** the scheduler switches to the next ready thread
2. **Given** the terminal thread is processing user input, **When** a network packet arrives, **Then** the network interrupt triggers and the packet is queued for processing
3. **Given** a thread is blocked waiting for I/O, **When** the scheduler runs, **Then** it skips blocked threads and runs ready threads

---

### User Story 3 - Ring 3 Userland Shell (Priority: P2)

A simple command-line shell runs in user mode (Ring 3) on the processor. Users can type commands on the keyboard, and the shell displays output to the screen. The shell communicates with the kernel exclusively through system calls.

**Why this priority**: Userland demonstrates proper privilege separation and syscall infrastructure. It's essential for a microkernel architecture but can function with minimal features initially.

**Independent Test**: Can be tested by booting the kernel, seeing a shell prompt, typing characters, and observing them echoed to the screen. Basic commands like "help" or "echo" should work.

**Acceptance Scenarios**:

1. **Given** the kernel has booted, **When** initialization completes, **Then** a shell prompt appears on screen
2. **Given** the shell is waiting for input, **When** the user types a character, **Then** the character is echoed to the display via syscall
3. **Given** the user types a command and presses Enter, **When** the shell processes the input, **Then** it invokes the appropriate syscall and displays the result
4. **Given** the shell process attempts a privileged operation directly, **When** executed, **Then** a protection fault occurs and is handled gracefully

---

### User Story 4 - ARP Resolution (Priority: P2)

The kernel can discover the MAC address of other machines on the local network using ARP. When the kernel needs to send a packet to an IP address, it first checks its ARP cache. If the MAC address is unknown, it broadcasts an ARP request and processes ARP replies to populate the cache.

**Why this priority**: ARP is required for any IP-level communication including ping replies. Without ARP, the kernel cannot send packets to external hosts.

**Independent Test**: Can be tested by sending ARP requests from the host to the kernel's IP address and observing ARP replies. The kernel's ARP table can be inspected for cached entries.

**Acceptance Scenarios**:

1. **Given** another host sends an ARP request for the kernel's IP, **When** the packet is received, **Then** the kernel responds with its MAC address
2. **Given** the kernel needs to send to an unknown IP, **When** it sends an ARP request, **Then** it receives and caches the reply MAC address
3. **Given** an ARP cache entry exists, **When** a packet needs to be sent, **Then** the cached MAC is used without re-querying

---

### User Story 5 - UDP Message Sending (Priority: P3)

The kernel can send UDP datagrams to remote hosts. Applications or the kernel itself can construct UDP packets with a destination IP, port, and payload, then transmit them over the network.

**Why this priority**: UDP provides basic transport-layer messaging capability. While not required for ping, it extends the networking stack for future application use.

**Independent Test**: Can be tested by having the kernel send a UDP packet to a listening netcat process on the host. The message content should arrive intact.

**Acceptance Scenarios**:

1. **Given** a destination IP and port, **When** a UDP send is requested with payload data, **Then** a valid UDP packet is transmitted
2. **Given** a UDP packet arrives for a bound port, **When** processed by the stack, **Then** the payload is delivered to the appropriate handler
3. **Given** a UDP packet arrives for an unbound port, **When** processed, **Then** the packet is dropped silently

---

### User Story 6 - Keyboard Input Processing (Priority: P2)

The kernel handles keyboard interrupts and translates scan codes into characters. These characters are buffered and made available to the userland shell through syscalls.

**Why this priority**: Keyboard input is essential for the interactive shell. Without it, users cannot interact with the system.

**Independent Test**: Can be tested by pressing keys and observing corresponding characters appear on screen. Special keys (Enter, Backspace) should behave correctly.

**Acceptance Scenarios**:

1. **Given** the keyboard IRQ is enabled, **When** a key is pressed, **Then** an interrupt fires and the scan code is read
2. **Given** a printable key scan code, **When** translated, **Then** the correct ASCII character is buffered
3. **Given** the input buffer is full, **When** another key is pressed, **Then** the keystroke is dropped to prevent overflow

---

### User Story 7 - InitRD File Access (Priority: P2)

A userland application can open, read, seek, and close files stored in an Initial Ramdisk (InitRD) loaded via Limine Modules. This enables loading game data files like DOOM.WAD without requiring a full filesystem implementation.

**Why this priority**: File access is required for any non-trivial userland application (games, utilities). InitRD is simpler than a full filesystem and uses Limine's existing module loading capability.

**Independent Test**: Can be tested by loading an InitRD containing a test file, then running a userland program that opens the file, reads its contents, and verifies the data matches expected values.

**Acceptance Scenarios**:

1. **Given** an InitRD is loaded via Limine Modules, **When** userland calls `sys_open("/doom.wad", O_RDONLY)`, **Then** a valid file descriptor is returned
2. **Given** a file is open, **When** userland calls `sys_read(fd, buffer, count)`, **Then** the requested bytes are read into the buffer
3. **Given** a file is open, **When** userland calls `sys_seek(fd, offset, SEEK_SET)`, **Then** subsequent reads start from the specified offset
4. **Given** an invalid path, **When** userland calls `sys_open("/nonexistent")`, **Then** an error code is returned (-ENOENT)
5. **Given** an open file descriptor, **When** userland calls `sys_close(fd)`, **Then** the descriptor is released and cannot be used again

---

### User Story 8 - Dynamic Heap Expansion (Priority: P2)

A userland application can dynamically grow its heap at runtime using `sys_sbrk` or anonymous memory mapping. This enables memory-intensive applications like games to allocate large buffers.

**Why this priority**: Static heap sizes are insufficient for games and complex applications. Dynamic heap expansion is a fundamental POSIX capability required for most C libraries.

**Independent Test**: Can be tested by a userland program calling `sys_sbrk` multiple times to expand the heap, writing to the new memory, and verifying the writes persist.

**Acceptance Scenarios**:

1. **Given** a userland process with an initial heap, **When** it calls `sys_sbrk(4096)`, **Then** the heap grows by 4096 bytes and the previous break address is returned
2. **Given** the heap has been expanded, **When** the process writes to the new memory region, **Then** the write succeeds without page fault
3. **Given** `sys_sbrk(0)` is called, **When** the syscall completes, **Then** the current break address is returned without modification
4. **Given** insufficient physical memory, **When** `sys_sbrk` is called, **Then** an error code is returned (-ENOMEM)

---

### User Story 9 - Direct Framebuffer Rendering (Priority: P2)

A userland application can map the video framebuffer into its address space for high-performance direct pixel manipulation, enabling smooth graphics rendering for games.

**Why this priority**: Syscall-per-pixel rendering is too slow for real-time graphics. Mapping the framebuffer allows games to write directly to video memory at maximum speed.

**Independent Test**: Can be tested by a userland program mapping the framebuffer, writing a test pattern directly to the mapped memory, and verifying the pattern appears on screen.

**Acceptance Scenarios**:

1. **Given** a userland process, **When** it calls `sys_mmap_framebuffer()`, **Then** it receives a pointer to the mapped framebuffer in its address space
2. **Given** the framebuffer is mapped, **When** the process writes pixel data to the mapped address, **Then** the pixels appear on screen immediately
3. **Given** the framebuffer is mapped, **When** the process attempts to access beyond the framebuffer size, **Then** a page fault occurs and is handled
4. **Given** framebuffer info request, **When** `sys_get_framebuffer_info()` is called, **Then** width, height, pitch, and pixel format are returned

---

### User Story 10 - Raw Keyboard Scancodes (Priority: P2)

A userland application can read raw keyboard scancodes (make/break codes) for game input, rather than only translated ASCII characters.

**Why this priority**: Games need to detect key press and release events, handle multiple simultaneous keys, and process keys that don't have ASCII equivalents (arrow keys, modifiers).

**Independent Test**: Can be tested by pressing a key, reading the make code, releasing the key, and reading the break code, verifying both are received.

**Acceptance Scenarios**:

1. **Given** a userland game, **When** a key is pressed, **Then** `sys_read_scancode()` returns the make code (key down)
2. **Given** a key was pressed, **When** the key is released, **Then** `sys_read_scancode()` returns the break code (key up, typically make code | 0x80)
3. **Given** multiple keys are held, **When** scancodes are read, **Then** all held keys' states can be tracked
4. **Given** no key events pending, **When** `sys_read_scancode()` is called, **Then** it returns -EAGAIN (non-blocking) or blocks until input

---

### Edge Cases

- What happens when the heap runs out of memory during packet allocation?
  - The allocation fails gracefully, the packet is dropped, and the system continues operating
- What happens when an interrupt fires during a critical section?
  - Interrupts are temporarily disabled during critical sections to prevent race conditions
- What happens when a userland process makes an invalid syscall number?
  - The kernel returns an error code without crashing; the process handles the error
- What happens when network packets arrive faster than they can be processed?
  - Packets are queued up to a limit, then excess packets are dropped
- What happens when the scheduler has no ready threads?
  - The Idle Thread is selected (see FR-013a); CPU halts until next interrupt

### Debugging Considerations

- **Network Debugging**: Cannot debug networking solely from inside the OS; MUST use host-side packet capture (tcpdump/Wireshark on tap0 interface) to observe actual bytes transmitted
- **Silent Failures**: Malformed network packets (wrong endianness, incorrect checksums) will be silently dropped by receiving hosts with no visible error inside the kernel

## Requirements *(mandatory)*

### Functional Requirements

**Memory Management**
- **FR-001**: System MUST implement 4-level paging for virtual memory management on x86-64
- **FR-002**: System MUST provide a heap allocator for dynamic kernel memory allocation (PMM allocates 2MB chunk for free-list heap after VMM init)
- **FR-003**: System MUST map kernel memory as privileged (Ring 0 only)
- **FR-004**: System MUST map userland memory as unprivileged (Ring 3 accessible)
- **FR-005**: System MUST handle page faults and report errors appropriately
- **FR-005a**: System MUST request and use Limine's Higher Half Direct Map (HHDM) to access physical memory for page table manipulation
- **FR-005b**: System MUST use HHDM offset (provided by Limine) to convert physical addresses to virtual addresses when modifying page tables

**Interrupt Handling**
- **FR-006**: System MUST configure the Programmable Interrupt Controller for hardware interrupts
- **FR-007**: System MUST handle keyboard interrupts (IRQ1) and buffer keystrokes
- **FR-008**: System MUST handle network card interrupts for packet reception
- **FR-009**: System MUST handle timer interrupts for preemptive scheduling
- **FR-009a**: System MUST configure TSS Interrupt Stack Table (IST) with a dedicated stack for Double Fault exceptions to prevent triple faults on kernel stack overflow
- **FR-009b**: Double Fault handler (vector 0x08) MUST use IST entry 1 to ensure it has a valid stack even when the original stack overflowed
- **FR-009c**: All IDT interrupt stubs MUST ensure RSP is 16-byte aligned before calling Zig handler functions (SysV ABI requirement; CPU pushes 40 bytes, so alignment padding may be needed)
- **FR-009d**: Failure to align stack for interrupt handlers will cause random GPF crashes when compiler uses SSE/AVX instructions for memcpy or string formatting

**Multitasking**
- **FR-010**: System MUST implement a preemptive scheduler with time-slice-based switching
- **FR-011**: System MUST support at least 2 concurrent threads (kernel network worker + userland terminal)
- **FR-012**: System MUST save and restore full thread context on switches
- **FR-013**: System MUST maintain separate kernel and user stacks per thread
- **FR-013a**: System MUST create a persistent Idle Thread at boot with lowest priority that executes `hlt` in a loop
- **FR-013b**: Idle Thread ensures scheduler ALWAYS has at least one runnable thread when all other threads are blocked (prevents scheduler crash/hang)
- **FR-013c**: Scheduler MUST select Idle Thread when no other threads are in Ready state

**Spinlock Primitive**

The kernel uses an IRQ-safe Spinlock for mutual exclusion:

```zig
pub const Spinlock = struct {
    locked: std.atomic.Value(u32) = .{ .raw = 0 },

    pub const Held = struct {
        lock: *Spinlock,
        irq_state: bool,

        pub fn release(self: Held) void;
    };

    pub fn acquire(self: *Spinlock) Held;
};
```

- **FR-LOCK-01**: Spinlock `acquire()` MUST disable interrupts before spinning
- **FR-LOCK-02**: Spinlock `release()` MUST restore interrupt state after unlocking
- **FR-LOCK-03**: All critical sections MUST use explicit Spinlock operations, not implicit CLI assumptions
- **FR-LOCK-04**: MVP uses a single Big Kernel Lock (BKL); structure enables future fine-grained locking

**Usage Pattern**:
```zig
const held = lock.acquire();
defer held.release();
// Critical section
```

**Networking**
- **FR-014**: System MUST implement a driver for the Intel E1000 network interface
- **FR-015**: System MUST transmit and receive Ethernet frames through the E1000
- **FR-016**: System MUST implement ARP request/reply for MAC address resolution
- **FR-017**: System MUST implement ICMP echo request/reply (ping)
- **FR-018**: System MUST implement UDP datagram sending and receiving
- **FR-019**: System MUST maintain an ARP cache for resolved addresses
- **FR-019a**: E1000 driver MUST handle RX ring buffer overflow gracefully by dropping excess packets rather than overwriting memory or causing lockups
- **FR-019b**: All multi-byte fields in network protocol headers (Ethernet, IP, ARP, ICMP, UDP) MUST use network byte order (Big Endian)
- **FR-019c**: System MUST convert between host byte order (Little Endian on x86) and network byte order using `@byteSwap` or `std.mem.nativeToBig`/`bigToNative`
- **FR-019d**: Syscall interfaces for networking (e.g., `sys_send_udp`) MUST document expected byte order for all parameters (typically host byte order for API, kernel converts to network order)

**Byte Order Requirements**

ZigK runs on x86_64 (Little Endian). Network protocols use Big Endian.

| Domain | Byte Order | Conversion |
|--------|-----------|------------|
| IP/UDP/TCP headers | Big Endian | `std.mem.nativeToBig` |
| E1000 registers | Little Endian | None |
| E1000 descriptors | Little Endian | None |

**Implementation Rules**:
1. Protocol struct fields that cross the wire MUST be stored in network byte order
2. Protocol structs MUST provide accessor methods that handle conversion
3. Hardware register writes MUST NOT byte-swap
4. Hardware descriptor fields MUST NOT byte-swap

**Example**:
```zig
const UdpHeader = extern struct {
    src_port: u16,  // Network byte order in memory
    dst_port: u16,

    pub fn getSrcPort(self: *const UdpHeader) u16 {
        return std.mem.bigToNative(u16, self.src_port);
    }
};
```

**Userland**

> **Syscall Numbers**: All syscall numbers follow Linux x86_64 ABI.
> See [syscall-table.md](../syscall-table.md) for authoritative numbers.

- **FR-020**: System MUST run userland code in Ring 3 (unprivileged mode)
- **FR-021**: System MUST provide syscalls for I/O operations (read keyboard, write to display)
- **FR-022**: System MUST implement syscalls using the syscall/sysret instructions
- **FR-023**: System MUST protect kernel memory from userland access
- **FR-023a**: System MUST use a "Big Kernel Lock" (disable interrupts during syscalls) to prevent TOCTOU race conditions when validating user pointers
- **FR-023b**: All syscall handlers MUST validate user pointers before and during access with interrupts disabled

**Shell**
- **FR-024**: Shell MUST display a prompt and accept keyboard input
- **FR-025**: Shell MUST echo typed characters to the display
- **FR-026**: Shell MUST process basic commands (help, echo, or equivalent)

**InitRD Filesystem**
- **FR-027**: System MUST load Initial Ramdisk via Limine Modules request
- **FR-027a**: InitRD parser MUST support a simple file table format (flat list of {name, offset, size} entries) or TAR archive
- **FR-027b**: System MUST implement `sys_open(path, flags)` syscall returning file descriptor or -ENOENT
- **FR-027c**: System MUST implement `sys_read(fd, buf, count)` syscall for sequential file reading
- **FR-027d**: System MUST implement `sys_seek(fd, offset, whence)` syscall supporting SEEK_SET, SEEK_CUR, SEEK_END
- **FR-027e**: System MUST implement `sys_close(fd)` syscall to release file descriptor
- **FR-027f**: System MUST validate all file descriptor indices before access (-EBADF on invalid)
- **FR-027g**: Maximum open file descriptors per process: 16 (sufficient for games)

**Dynamic Heap**
- **FR-028**: System MUST implement `sys_sbrk(increment)` syscall for userland heap expansion
- **FR-028a**: `sys_sbrk(0)` MUST return current program break without modification
- **FR-028b**: `sys_sbrk(n)` MUST expand heap by n bytes, return previous break address, or -ENOMEM on failure
- **FR-028c**: Newly allocated heap pages MUST be mapped with user-accessible permissions (Ring 3 readable/writable)
- **FR-028d**: Initial program break MUST be set after BSS segment of loaded userland program
- **FR-028e**: **SECURITY**: Newly allocated heap pages MUST be zero-filled before mapping to userland to prevent information leakage from kernel/previous process memory

**Heap Coalescing**
- **FR-002a**: Kernel heap allocator MUST implement block coalescing on `free()` to merge adjacent free blocks
- **FR-002b**: Coalescing MUST merge both backward (preceding block) and forward (following block) when adjacent blocks are free
- **FR-002c**: Failure to coalesce will cause heap fragmentation, eventually exhausting memory even when total free bytes are sufficient

**Framebuffer Mapping**
- **FR-029**: System MUST implement `sys_get_framebuffer_info()` syscall returning {width, height, pitch, bpp, pixel_format}
- **FR-029a**: System MUST implement `sys_mmap_framebuffer()` syscall to map video memory into userland address space
- **FR-029b**: Framebuffer mapping MUST use page table entries with user-accessible and write-through/uncached flags
- **FR-029c**: Framebuffer physical address and size MUST be obtained from Limine Framebuffer response
- **FR-029d**: System MUST prevent userland from mapping arbitrary physical memory (only framebuffer region allowed)

**Raw Keyboard Input**
- **FR-030**: System MUST implement `sys_read_scancode()` syscall returning raw PS/2 scan codes
- **FR-030a**: Scancode syscall MUST return make codes (key press) and break codes (key release, typically scancode | 0x80)
- **FR-030b**: System MUST maintain separate buffers for ASCII characters (existing) and raw scancodes (new)
- **FR-030c**: Scancode buffer MUST be at least 64 entries to handle rapid key events
- **FR-030d**: When scancode buffer is full, oldest entries MUST be dropped (ring buffer behavior)

### Key Entities

- **Page Table**: Hierarchical structure mapping virtual addresses to physical addresses with permission bits
- **Thread/Task**: Execution context including registers, stack pointers, state (ready/running/blocked), and privilege level
- **Heap Block**: Dynamically allocated memory region with metadata for allocation tracking
- **Ethernet Frame**: Network packet containing source/destination MAC, type field, and payload
- **ARP Entry**: Cached mapping of IP address to MAC address with optional timeout
- **Network Packet Buffer**: Memory region holding received or pending network data
- **Syscall Interface**: Defined set of kernel services accessible from userland
- **File Descriptor**: Index into per-process file table, referencing an InitRD file with current read offset
- **InitRD**: In-memory filesystem loaded via Limine Modules, containing flat file table or TAR entries
- **InitRD File Entry**: {name: [32]u8, offset: u64, size: u64} mapping filename to InitRD data region
- **Framebuffer Mapping**: Userland-accessible virtual address range mapped to video memory physical pages
- **Scancode Buffer**: Ring buffer (64 entries) storing raw PS/2 keyboard scan codes for game input

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Kernel successfully responds to ICMP ping requests from external hosts with reply latency under 100ms
- **SC-002**: Scheduler switches between at least 2 threads continuously without deadlock or starvation
- **SC-003**: Userland shell accepts keyboard input and displays characters with no perceptible input lag
- **SC-004**: ARP resolution completes within 500ms for hosts on the local network
- **SC-005**: UDP packets are transmitted with correct headers as verified by packet capture
- **SC-006**: Kernel runs stably for at least 10 minutes of continuous operation under ping load
- **SC-007**: Page faults from userland invalid memory access are caught and handled without kernel crash
- **SC-008**: Kernel boots to interactive shell prompt within 5 seconds in QEMU
- **SC-009**: InitRD files can be opened, read sequentially and with seeking, and closed without data corruption
- **SC-010**: Userland process can allocate at least 4MB of heap memory via repeated `sys_sbrk` calls
- **SC-011**: Framebuffer writes from userland appear on screen within one frame refresh (16ms at 60Hz)
- **SC-012**: Raw keyboard scancodes are received for both key press and key release events
- **SC-013**: Kernel heap remains usable after 1000+ allocate/free cycles (coalescing prevents fragmentation)

## Clarifications

### Session 2025-12-05

- Q: What heap allocator strategy should be used? → A: PMM allocates 2MB contiguous chunk, free-list heap manages it (no bump-to-freelist handover complexity)
- Q: What syscall mechanism should be used? → A: syscall/sysret instructions (fast, modern x86-64 standard)
- Q: How to access physical memory for page tables? → A: Use Limine HHDM request; all physical addresses accessed via `hhdm_offset + phys_addr`
- Q: How to prevent triple fault on Double Fault? → A: TSS IST entry 1 provides dedicated Double Fault stack
- Q: How to prevent TOCTOU in syscall pointer validation? → A: Big Kernel Lock (CLI) during syscall processing for MVP

### Session 2025-12-05 (Critical Implementation Details)

- Q: How to prevent random GPF crashes in interrupt handlers? → A: Ensure 16-byte RSP alignment in IDT stubs before calling Zig code (SysV ABI requirement; CPU pushes 40 bytes, need padding)
- Q: What happens when all threads are blocked? → A: Idle Thread (created at boot, lowest priority, executes `hlt` loop) ensures scheduler always has a runnable thread
- Q: How to handle network byte order? → A: All protocol headers use Big Endian; use `@byteSwap` or `std.mem.nativeToBig` for conversion; syscall APIs use host byte order (kernel converts)
- Q: How to debug silent network failures? → A: Use host-side tcpdump/Wireshark on tap0 interface to observe actual transmitted bytes
- Q: Does network packet processing require a dedicated thread? → A: Interrupt handler performs minimal work (read descriptor, queue packet); network worker thread processes protocol stack. Scheduler is required before networking for this thread.

### Session 2025-12-05 (Doom Compatibility)

- Q: What InitRD format should be used? → A: Simple flat file table (header with entry count, followed by {name, offset, size} entries), easier than TAR parsing for MVP
- Q: How should `sys_sbrk` handle page alignment? → A: Increment rounds up to page boundary; kernel maps new pages on demand
- Q: Why map framebuffer directly vs syscall-per-pixel? → A: Performance: Doom renders ~300K pixels/frame at 35fps; syscall overhead would make this impossible
- Q: How to handle framebuffer cache coherency? → A: Map with write-through or uncached page attributes (PCD/PWT bits in PTE)
- Q: How does scancode buffer differ from ASCII buffer? → A: Scancodes include make/break codes for key up/down tracking; ASCII buffer only stores printable characters on key press
- Q: What IP address should the kernel use? → A: Static configuration: IP 10.0.2.15, netmask 255.255.255.0, gateway 10.0.2.2 (QEMU user-mode networking defaults)

### Session 2025-12-05 (Build Environment)

- Q: What Zig version should be used? → A: Zig 0.15.x (or current stable). See CLAUDE.md for build patterns.

## Assumptions

- Target platform is x86-64 architecture
- Bootloader is Limine (as per existing project setup)
- QEMU is the primary test environment with E1000 as the default network device
- The kernel is mapped at higher-half virtual address (0xFFFF800000000000+) via Limine; identity mapping is NOT used
- Physical memory is accessed exclusively through Limine's Higher Half Direct Map (HHDM) offset
- InitRD provides read-only file access; all game assets and data are loaded at boot via Limine Modules
- Single CPU core (no SMP support required for MVP)
- Network configuration (IP address) can be statically assigned
- No security hardening beyond basic Ring 0/Ring 3 separation required for MVP
- Framebuffer resolution is 320x200 (Doom native) or 640x480 with software scaling
- Maximum InitRD size: 16MB (sufficient for Doom shareware WAD ~4MB + headroom)
- Userland heap maximum: 8MB (sufficient for Doom's memory requirements)
