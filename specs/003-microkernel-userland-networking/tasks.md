# Tasks: Microkernel with Userland and Networking

**Input**: Design documents from `/specs/003-microkernel-userland-networking/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: Integration tests are included (host-side ping verification, tcpdump capture). Unit tests are minimal per Zig OS development conventions.

**Organization**: Tasks are grouped by implementation phase from plan.md, with user stories mapped to their enabling phases.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task enables (e.g., US1, US2)
- Include exact file paths in descriptions

## Path Conventions

Based on plan.md structure:
- Kernel: `src/kernel/`
- HAL: `src/arch/x86_64/`
- Drivers: `src/drivers/`
- Network: `src/net/`
- Filesystem: `src/fs/`
- Userland: `src/user/`
- Libraries: `src/lib/`

---

## Phase 1: Setup (Project Initialization)

**Purpose**: Build system and core booting infrastructure

- [ ] T001 Create project directory structure per plan.md layout
- [ ] T002 Configure build.zig with freestanding x86_64 target, Limine integration, uapi module exposure to kernel and userland, AND test runner step for host-based unit tests
- [ ] T003 [P] Add limine.zig bindings as build dependency in build.zig.zon
- [ ] T004 [P] Create limine.conf bootloader configuration
- [ ] T005 Create src/kernel/main.zig with Limine entry point and requests (framebuffer, memory_map, hhdm, modules)
- [ ] T006 [P] Implement src/lib/serial.zig for debug output (COM1, 115200 baud)
- [ ] T006a [P] Implement src/kernel/panic.zig with panic handler (FR-004 from archived/002)
- [ ] T006b [P] Implement stack guard canary __stack_chk_guard in src/kernel/stack_guard.zig (FR-009 from archived/002)
- [ ] T006c [P] Implement __stack_chk_fail handler that calls panic (FR-010 from archived/002)
- [ ] T006d Enable stack smashing protection in build.zig if supported (FR-008 from archived/002)
- [ ] T007 [P] Implement src/lib/console.zig for framebuffer text rendering

### Shared uapi Module

- [ ] T007a Create src/uapi/ directory structure per FILESYSTEM.md
- [ ] T007b Create src/uapi/syscalls.zig with syscall numbers from specs/syscall-table.md
- [ ] T007c Create src/uapi/errno.zig with Linux errno constants (EPERM through ENOSYS)
- [ ] T007d Create src/uapi/abi.zig with shared structs (Timespec, SockAddr, Stat)

- [ ] T008 Verify kernel boots to "ZigK booting..." message in QEMU

**Checkpoint**: Kernel boots and displays debug output

---

## Phase 1.5: HAL Infrastructure (Constitution Compliance)

**Purpose**: Establish HAL module structure per contracts/hal-interface.md before drivers are implemented

**CRITICAL**: Drivers implemented in later phases MUST import from hal module only, never use inline assembly directly

### HAL Module Structure

- [ ] T008a Create src/arch/root.zig unified interface re-exporting all x86_64 modules
- [ ] T008b Create src/arch/x86_64/ directory structure per hal-interface.md
- [ ] T008c [P] Create src/arch/x86_64/port_io.zig with inb/outb/inw/outw/inl/outl functions
- [ ] T008d [P] Create src/arch/x86_64/cpu.zig with CR/MSR/interrupt control functions
- [ ] T008e [P] Verify src/lib/serial.zig uses hal.port for I/O (no direct port access)

### HAL Enforcement Verification

- [ ] T008f Add build.zig check: files in src/drivers/ MUST NOT contain "asm volatile" except for memory barriers
- [ ] T008g Document in CLAUDE.md: drivers MUST import hal, not x86_64 modules directly

**Checkpoint**: HAL layer exists; all port I/O flows through hal.port

---

## Phase 2: Foundational - Memory Management

**Purpose**: Physical and virtual memory infrastructure required by ALL user stories

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

### PMM (Physical Memory Manager)

- [ ] T009 Create src/kernel/pmm.zig with bitmap allocator structure
- [ ] T010 Implement Limine memory map parsing in src/kernel/pmm.zig
- [ ] T011 Implement page allocation/deallocation in src/kernel/pmm.zig
- [ ] T012 Reserve kernel pages and 2MB heap region in src/kernel/pmm.zig

### VMM (Virtual Memory Manager)

- [ ] T013 Create src/arch/x86_64/paging.zig with PageTableEntry packed struct (FR-001)
- [ ] T014 Implement HHDM offset extraction from Limine response (FR-005a/b)
- [ ] T015 Implement physToVirt()/virtToPhys() using HHDM offset in src/arch/x86_64/paging.zig
- [ ] T016 Implement 4-level page table creation (PML4 → PDPT → PD → PT) in src/arch/x86_64/paging.zig
- [ ] T017 Implement mapPage() with kernel/user permission flags (FR-003/FR-004)

### Heap Allocator

- [ ] T018 Create src/kernel/heap.zig with free-list allocator structure
- [ ] T019 Implement block header/footer with boundary tags for coalescing (FR-002a)
- [ ] T020 Implement alloc() with first-fit search in src/kernel/heap.zig
- [ ] T021 Implement free() with forward/backward coalescing (FR-002b/c)
- [ ] T022 Add allocation count tracking for hygiene verification (Principle IX)
- [ ] T023 Verify heap alloc/free cycles via serial debug output

### Heap Allocator Verification (Enhanced)

- [ ] T023a Create tests/unit/heap_fuzz.zig with randomized heap testing
- [ ] T023b Fuzz test performs 10,000 random alloc/free sequences with varying sizes (8 bytes to 64KB)
- [ ] T023c Fuzz test verifies coalescing by checking free block count decreases after adjacent frees
- [ ] T023d Fuzz test verifies no memory corruption by writing patterns to allocated blocks and checking on free
- [ ] T023e Run heap fuzz test before Phase 7 (Networking) to ensure allocator stability. Execute via `zig build test` on host using std.heap.page_allocator as backing allocator for unit test isolation from kernel runtime.

**Verification**: Heap fuzz test passes 10,000 iterations without corruption or fragmentation

**Checkpoint**: Memory management complete - PMM allocates pages, VMM maps them, Heap provides dynamic allocation

---

## Phase 3: Foundational - Interrupt Infrastructure

**Purpose**: GDT, TSS, IDT required by ALL user stories

### GDT Setup

- [ ] T024 Create src/arch/x86_64/gdt.zig with GDTEntry packed struct
- [ ] T025 Define kernel code (0x08), kernel data (0x10), user data (0x18), user code (0x20) segments
- [ ] T026 Implement TSSDescriptor (16 bytes spanning two slots) in src/arch/x86_64/gdt.zig
- [ ] T027 Implement LGDT inline assembly in src/arch/x86_64/gdt.zig

### TSS Configuration

- [ ] T028 Create TSS structure with rsp0, IST array in src/arch/x86_64/gdt.zig
- [ ] T029 Allocate 4KB Double Fault stack for IST[0] (FR-009a)
- [ ] T030 Configure TSS.ist[0] to point to Double Fault stack (FR-009b)
- [ ] T031 Implement LTR instruction to load TSS

### IDT Setup

- [ ] T032 Create src/arch/x86_64/idt.zig with IDTGate packed struct (16 bytes)
- [ ] T033 Implement interrupt stub generator with **16-byte RSP alignment** (FR-009c/d)
- [ ] T034 Configure 256 IDT gates with proper gate types (0xE = interrupt)
- [ ] T035 Configure Double Fault (vector 8) to use IST index 1
- [ ] T036 Implement LIDT inline assembly in src/arch/x86_64/idt.zig
- [ ] T037 Implement InterruptContext structure for saved register state

### PIC Configuration

- [ ] T038 Create src/arch/x86_64/pic.zig with PIC initialization
- [ ] T039 Remap IRQ0-15 to vectors 0x20-0x2F in src/arch/x86_64/pic.zig
- [ ] T040 Implement interrupt masking functions in src/arch/x86_64/pic.zig
- [ ] T041 Implement EOI (End of Interrupt) sending in src/arch/x86_64/pic.zig

### Verification

- [ ] T042 Implement division by zero exception handler for testing
- [ ] T043 Verify exception handler runs without triple fault
- [ ] T043a [P] Implement page fault (vector 14) handler in src/arch/x86_64/idt.zig with error code parsing and serial debug output (FR-005)
- [ ] T043b Verify page fault handler catches invalid memory access without triple fault

### FPU/SSE State Preservation (FR-FPU-01 through FR-FPU-07)

- [ ] T043c Add 512-byte aligned FPU state area to Thread structure in src/kernel/thread.zig (FR-FPU-04)
- [ ] T043d Implement FXSAVE in interrupt entry stub in src/arch/x86_64/interrupts.zig (FR-FPU-02)
- [ ] T043e Implement FXRSTOR in interrupt exit stub in src/arch/x86_64/interrupts.zig (FR-FPU-03)
- [ ] T043f Verify build.zig disables SSE/MMX for kernel code only (FR-FPU-05)
- [ ] T043g [P] (Optional) Implement CR0.TS lazy FPU switching with #NM handler in src/arch/x86_64/fpu.zig (FR-FPU-07)

### Stack Guard Pages (FR-029-031 from archived/004)

- [ ] T043h Allocate N+1 pages for kernel stacks with bottom page unmapped (guard page)
- [ ] T043i Verify stack overflow triggers page fault at guard page address
- [ ] T043j Page fault handler logs faulting thread ID and fault address for guard page faults

### Crash Diagnostics (FR-032-034 from archived/004)

- [ ] T043k Page fault handler prints CR2 (fault address) and RIP (instruction pointer)
- [ ] T043l Implement dump_registers() helper for exception handlers in src/arch/x86_64/debug.zig

**Checkpoint**: Interrupt infrastructure complete - exceptions handled, IRQs routed, FPU state preserved

---

## Phase 4: User Story 2 - Preemptive Multitasking (Priority: P1)

**Goal**: Scheduler switches between 2+ threads with Idle Thread fallback

**Independent Test**: Two threads print alternating output to serial

### Timer (PIT)

- [ ] T044 [US2] Create src/arch/x86_64/pit.zig with PIT configuration
- [ ] T045 [US2] Configure PIT Channel 0 for 100Hz (10ms quantum)
- [ ] T046 [US2] Enable IRQ0 (timer) in PIC

### Thread Structure

- [ ] T047 [US2] Create src/kernel/thread.zig with Thread struct (tid, state, context, stacks)
- [ ] T048 [US2] Define ThreadState enum (Ready, Running, Blocked, Zombie)
- [ ] T049 [US2] Implement kernel stack allocation per thread

### Scheduler

- [ ] T050 [US2] Create src/kernel/scheduler.zig with ready queue (circular linked list)
- [ ] T051 [US2] Implement context switch: save regs → swap CR3 → update TSS.rsp0 → restore regs
- [ ] T052 [US2] Create **Idle Thread** at boot with lowest priority (FR-013a)
- [ ] T053 [US2] Implement Idle Thread entry: `while(true) { asm volatile("hlt"); }`
- [ ] T054 [US2] Ensure scheduler selects Idle Thread when no other threads ready (FR-013b/c)
- [ ] T055 [US2] Implement timer IRQ0 handler that calls scheduler.schedule()

### Verification

- [ ] T056 [US2] Create two test threads printing to serial
- [ ] T057 [US2] Verify alternating thread output in serial log

**Checkpoint**: US2 complete - Scheduler preemptively switches between threads, Idle Thread prevents deadlock

---

## Phase 5: User Story 6 - Keyboard Input Processing (Priority: P2)

**Goal**: PS/2 keyboard IRQ1 handler with ASCII and scancode buffers

**Independent Test**: Type keys, see characters on console

### IRQ1 Handler

- [ ] T058 [US6] Create src/drivers/keyboard.zig with IRQ1 handler (MUST import arch module for I/O, MUST NOT use inline assembly directly)
- [ ] T059 [US6] Implement port 0x60 scancode reading
- [ ] T060 [US6] Implement scancode-to-ASCII translation table
- [ ] T061 [US6] Implement **dual buffers**: ASCII ring buffer (256) + scancode ring buffer (64) (FR-030b)
- [ ] T062 [US6] Handle extended scancodes (0xE0 prefix)
- [ ] T063 [US6] Enable IRQ1 (keyboard) in PIC

### Scancode Buffer (for US10)

- [ ] T064 [US6] Implement 64-entry scancode ring buffer (FR-030c)
- [ ] T065 [US6] Store make codes (key press) and break codes (key release | 0x80) (FR-030a)
- [ ] T066 [US6] Drop oldest entry on overflow (ring buffer behavior) (FR-030d)

### Key State Tracking

- [ ] T067 [P] [US6] Implement 256-entry key_states array for pressed keys
- [ ] T068 [US6] Update key_states on make/break codes

### Verification

- [ ] T069 [US6] Press keys, verify ASCII appears on console
- [ ] T070 [US6] Verify scancode buffer receives make/break codes

**Checkpoint**: US6 complete - Keyboard input works for shell and games

---

## Phase 5.5: Userland Runtime (crt0)

**Purpose**: Minimal C runtime providing userland entry point, stack setup, and syscall wrappers

**CRITICAL**: Must be complete before Phase 6 (Ring 3 Userland Shell) can execute

### Entry Point

- [ ] T070a Create src/user/crt0.zig with _start export as userland entry point
- [ ] T070b Implement stack frame setup (RBP initialization, RSP 16-byte alignment per SysV ABI)
- [ ] T070c Call extern main() and pass return value to sys_exit

### Syscall Wrappers

- [ ] T070d Create src/user/lib/syscall.zig with inline assembly syscall instruction
- [ ] T070e Implement syscall wrappers: sys_exit (60), sys_write (1), sys_read (0)
- [ ] T070f Implement syscall wrappers: sys_brk (12), sys_sched_yield (24), sys_nanosleep (35)
- [ ] T070g Implement syscall wrappers: sys_getpid (39), sys_clock_gettime (228), sys_getrandom (318)

### Build Integration

- [ ] T070h Update build.zig to link crt0.zig as entry point for all userland executables

**Checkpoint**: Userland programs can start via _start and make syscalls

---

## Phase 6: User Story 3 - Ring 3 Userland Shell (Priority: P2)

**Goal**: Userland shell runs in Ring 3 with syscall interface

**Independent Test**: Shell prompt appears, can type and see echoed output

### Syscall Infrastructure

- [ ] T071 [US3] Create src/arch/x86_64/syscall.zig with MSR configuration
- [ ] T072 [US3] Configure IA32_STAR with kernel/user segment selectors
- [ ] T073 [US3] Configure IA32_LSTAR with syscall_entry address
- [ ] T074 [US3] Configure IA32_FMASK to clear IF (disable interrupts on entry)
- [ ] T075 [US3] Implement syscall_entry: **CLI first** (Big Kernel Lock) → SWAPGS → switch stack (FR-023a)
- [ ] T076 [US3] Implement user pointer validation with interrupts disabled (FR-023b)
- [ ] T077 [US3] Create src/kernel/syscall/ directory with table.zig (dispatch) and handlers.zig

**Note**: All syscall handlers MUST import syscall numbers from `@import("uapi").syscalls` to ensure kernel/userland consistency.

### Basic Syscalls (Linux x86_64 ABI - see specs/syscall-table.md)

- [ ] T078 [P] [US3] Implement sys_exit (60) in src/kernel/syscall/
- [ ] T079 [P] [US3] Implement sys_write (1) - write to console in src/kernel/syscall/
- [ ] T080 [P] [US3] Implement sys_read (0) - read from keyboard/FD in src/kernel/syscall/
- [ ] T081 [P] [US3] Implement sys_sched_yield (24) - yield timeslice
- [ ] T082 [P] [US3] Implement sys_getpid (39) - return thread ID
- [ ] T083 [P] [US3] Implement sys_nanosleep (35) - block thread for timespec duration

### User Page Tables

- [ ] T084 [US3] Create user address space with user_accessible=1 flag in page tables (FR-004)
- [ ] T085 [US3] Allocate separate user stack per thread
- [ ] T086 [US3] Map shell code/data into user address space

### Ring 3 Transition

- [ ] T087 [US3] Implement IRETQ to Ring 3 (push SS, RSP, RFLAGS, CS, RIP)
- [ ] T088 [US3] Verify user code executes in Ring 3 (CPL=3)

### Shell Program

- [ ] T089 [US3] Create src/user/shell.zig with main entry point
- [ ] T090 [US3] Implement shell prompt display via SYS_WRITE (FR-024)
- [ ] T091 [US3] Implement character echo via SYS_READ_CHAR + SYS_WRITE (FR-025)
- [ ] T092 [US3] Implement basic command parsing (help, echo) (FR-026)
- [ ] T093 [US3] Create src/user/lib/syscall.zig with syscall wrappers for userland

**Note**: Userland syscall wrappers MUST import numbers from `@import("uapi").syscalls` - same source as kernel.

### Verification

- [ ] T094 [US3] Boot kernel, verify shell prompt appears
- [ ] T095 [US3] Type characters, verify they echo to display
- [ ] T096 [US3] Run "help" command, verify output

**Checkpoint**: US3 complete - Userland shell runs in Ring 3 with syscall interface

---

## Phase 7: User Story 1 - ICMP Ping Reply (Priority: P1) 🎯 MVP

**Goal**: Kernel responds to ICMP echo requests

**Independent Test**: `ping <kernel-ip>` from host receives replies

### PCI Enumeration

- [ ] T097 [US1] Create src/arch/x86_64/pci.zig with PCI configuration space access
- [ ] T098 [US1] Implement PCI device enumeration (bus/device/function scan)
- [ ] T099 [US1] Find E1000 device (vendor 0x8086, device 0x100E)
- [ ] T100 [US1] Read BAR0 for MMIO base address
- [ ] T100a [P] [US1] Create src/net/config.zig with static IP (10.0.2.15), netmask (255.255.255.0), gateway (10.0.2.2) constants

### E1000 Driver

- [ ] T101 [US1] Create src/drivers/e1000.zig with register offset definitions (MUST import arch module for I/O, MUST NOT use inline assembly directly)
- [ ] T102 [US1] Implement device reset (CTRL.RST)
- [ ] T103 [US1] Read MAC address from EEPROM/RAL
- [ ] T104 [US1] Allocate RX/TX descriptor rings (16 entries each)
- [ ] T105 [US1] Configure RX descriptor ring (RDBAL, RDBAH, RDLEN, RDH, RDT)
- [ ] T106 [US1] Configure TX descriptor ring (TDBAL, TDBAH, TDLEN, TDH, TDT)
- [ ] T107 [US1] Allocate packet buffers for RX ring
- [ ] T108 [US1] Enable RX/TX (RCTL.EN, TCTL.EN)
- [ ] T109 [US1] Enable E1000 interrupts (IMS register)
- [ ] T110 [US1] Implement RX overflow handling - drop packets when ring full (FR-019a)

### Network IRQ Handler

- [ ] T111 [US1] Read E1000 Interrupt Line from PCI config space (offset 0x3C) and register IRQ handler for that line (do NOT hardcode IRQ11)
- [ ] T112 [US1] Implement RX interrupt: read descriptors, pass packets to stack
- [ ] T113 [US1] Implement TX completion handling

### Ethernet Layer

- [ ] T114 [US1] Create src/net/ethernet.zig with EthernetFrame struct
- [ ] T115 [US1] Implement **Big Endian** field access using @byteSwap (FR-019b/c)
- [ ] T116 [US1] Implement packet dispatch by EtherType (0x0800=IPv4, 0x0806=ARP)
- [ ] T117 [US1] Implement Ethernet frame transmission

### ARP (Required for Ping)

- [ ] T118 [US1] Create src/net/arp.zig with ARPPacket struct (Big Endian fields)
- [ ] T119 [US1] Implement ARP cache (256 entries) with lookup/add functions
- [ ] T120 [US1] Implement ARP request handling - respond with our MAC
- [ ] T121 [US1] Implement ARP reply handling - cache received MAC

### IPv4

- [ ] T122 [US1] Create src/net/ip.zig with IPv4Header struct (Big Endian fields)
- [ ] T123 [US1] Implement IP header parsing with checksum validation
- [ ] T124 [US1] Implement protocol dispatch (1=ICMP, 17=UDP)
- [ ] T125 [US1] Implement IP header checksum calculation

### ICMP

- [ ] T126 [US1] Create src/net/icmp.zig with ICMPHeader struct (Big Endian fields)
- [ ] T127 [US1] Implement Echo Request (type 8) parsing
- [ ] T128 [US1] Implement Echo Reply (type 0) generation: swap src/dst, copy ID/sequence
- [ ] T129 [US1] Implement ICMP checksum calculation
- [ ] T130 [US1] Send ICMP Echo Reply via Ethernet TX

### Verification

- [ ] T131 [US1] Run QEMU with TAP networking and static IP (requires sudo)
- [ ] T131a [US1] **Fallback**: Run QEMU with SLIRP mode using port forwarding (no sudo required)
- [ ] T131b [US1] SLIRP verification: kernel binds UDP 5555, host sends to localhost:5555
- [ ] T132 [US1] Verify `ping <kernel-ip>` receives replies <100ms (SC-001)
- [ ] T133 [US1] Use tcpdump on host to verify packet byte order

**Checkpoint**: US1 (MVP) complete - Kernel replies to pings

---

## Phase 8: User Story 4 - ARP Resolution (Priority: P2)

**Goal**: Kernel discovers MAC addresses via ARP requests

**Independent Test**: Send ARP request from host, kernel responds; kernel sends ARP request, caches reply

### ARP Enhancements

- [ ] T134 [US4] Implement outbound ARP request generation in src/net/arp.zig
- [ ] T135 [US4] Implement ARP reply reception and cache update
- [ ] T136 [US4] Implement pending packets queue while waiting for ARP reply
- [ ] T137 [US4] Verify ARP cache lookup before sending IP packets

**Checkpoint**: US4 complete - Full ARP resolution works bidirectionally

---

## Phase 9: User Story 5 - UDP Message Sending (Priority: P3)

**Goal**: Kernel can send/receive UDP datagrams

**Independent Test**: Kernel sends UDP to netcat on host; host sends UDP to kernel

### UDP Implementation

- [ ] T138 [US5] Create src/net/udp.zig with UDPHeader struct (Big Endian fields)
- [ ] T139 [US5] Implement UDP header parsing
- [ ] T140 [US5] Implement UDP checksum calculation (optional for MVP)
- [ ] T141 [US5] Implement port-based dispatch for incoming UDP

### Socket Syscalls (Linux x86_64 ABI - see specs/syscall-table.md)

- [ ] T141a [US5] Implement sys_socket (41) - create UDP socket handle in src/kernel/syscall/
- [ ] T142 [US5] Implement sys_sendto (44) in src/kernel/syscall/
- [ ] T143 [US5] Implement sys_recvfrom (45) in src/kernel/syscall/
- [ ] T144 [US5] Document byte order in syscall interface (FR-019d)

### Verification

- [ ] T145 [US5] Run `nc -u -l 5555` on host
- [ ] T146 [US5] Kernel sends UDP packet, verify receipt in netcat

**Checkpoint**: US5 complete - UDP messaging works

---

## Phase 10: User Story 7 - InitRD File Access (Priority: P2)

**Goal**: Userland can open/read/seek/close files from InitRD

**Independent Test**: Load test file from InitRD, read contents, verify data

### Limine Module Parsing

- [ ] T147 [US7] Add module_request to Limine requests in src/kernel/main.zig
- [ ] T148 [US7] Parse Limine module response for InitRD base/size

### InitRD Parser

- [ ] T149 [US7] Create src/fs/initrd.zig with TAR header struct (FR-027a)
- [ ] T150 [US7] Implement TAR archive traversal (512-byte headers)
- [ ] T151 [US7] Implement file lookup by name (findFile function)

### File Descriptor Table

- [ ] T152 [US7] Create per-thread file descriptor table (16 entries) (FR-027g)
- [ ] T153 [US7] Implement FD allocation/deallocation
- [ ] T154 [US7] Validate FD indices before access (FR-027f)

### File Syscalls (Linux x86_64 ABI - see specs/syscall-table.md)

- [ ] T155 [US7] Implement sys_open (2) - lookup file, allocate FD (FR-027b)
- [ ] T156 [US7] Implement sys_close (3) - release FD (FR-027e)
- [ ] T157 [US7] Implement sys_read (0) - read from file position (FR-027c)
- [ ] T158 [US7] Implement sys_lseek (8) - update position (SEEK_SET/CUR/END) (FR-027d)

### Verification

- [ ] T159 [US7] Create test InitRD TAR with test.txt
- [ ] T160 [US7] Userland opens file, reads contents, verifies data (SC-009)

**Checkpoint**: US7 complete - InitRD file access works

---

## Phase 11: User Story 8 - Dynamic Heap Expansion (Priority: P2)

**Goal**: Userland can grow heap via sys_sbrk

**Independent Test**: Allocate 4MB heap via repeated sbrk calls

### Heap Break Tracking

- [ ] T161 [US8] Add heap_break and heap_limit to Thread struct
- [ ] T162 [US8] Set initial program break after BSS segment (FR-028d)

### sys_brk Implementation (Linux x86_64 ABI - see specs/syscall-table.md)

- [ ] T163 [US8] Implement sys_brk (12) in src/kernel/syscall/ (FR-028)
- [ ] T164 [US8] Handle brk(0) returning current break (FR-028a)
- [ ] T165 [US8] Handle brk(addr) expanding heap, mapping pages on demand (FR-028b)
- [ ] T166 [US8] Map new pages with user-accessible permissions (FR-028c)
- [ ] T167 [US8] Return -ENOMEM on insufficient physical memory

### Verification

- [ ] T168 [US8] Userland allocates 4MB via repeated sbrk calls (SC-010)
- [ ] T169 [US8] Write to allocated memory, verify no page faults

**Checkpoint**: US8 complete - Dynamic heap works

---

## Phase 12: User Story 9 - Direct Framebuffer Rendering (Priority: P2)

**Goal**: Userland can map framebuffer for direct pixel access

**Independent Test**: Userland writes test pattern, appears on screen

### Framebuffer Info Syscall (ZigK Custom Extensions 1000+ - see specs/syscall-table.md)

- [ ] T170 [US9] Implement sys_get_fb_info (1000) returning width/height/pitch/bpp (FR-029)
- [ ] T171 [US9] Parse Limine framebuffer response for pixel format

### Framebuffer Mapping

- [ ] T172 [US9] Implement sys_map_fb (1001) in src/kernel/syscall/ (FR-029a)
- [ ] T173 [US9] Map framebuffer physical pages with user-accessible + write-through flags (FR-029b)
- [ ] T174 [US9] Get framebuffer physical address from Limine response (FR-029c)
- [ ] T175 [US9] **Security**: Only allow framebuffer region mapping (FR-029d)

### Verification

- [ ] T176 [US9] Userland maps framebuffer, writes test pattern
- [ ] T177 [US9] Verify pattern appears on screen within 16ms (SC-011)

**Checkpoint**: US9 complete - Direct framebuffer rendering works

---

## Phase 13: User Story 10 - Raw Keyboard Scancodes (Priority: P2)

**Goal**: Userland games can read raw scancodes for input

**Independent Test**: Press key, read make code; release key, read break code

### Scancode Syscall (ZigK Custom Extensions 1000+ - see specs/syscall-table.md)

- [ ] T178 [US10] Implement sys_read_scancode (1002) in src/kernel/syscall/ (FR-030)
- [ ] T179 [US10] Return scancode from scancode buffer (implemented in US6)
- [ ] T180 [US10] Return -EAGAIN when buffer empty (non-blocking)

### Time Syscall (Linux x86_64 ABI - see specs/syscall-table.md)

- [x] T181 [P] [US10] DEFERRED TO SPEC 007: sys_clock_gettime (228) - see Spec 007 Phase 5 (T064-T072)

### Verification

- [ ] T182 [US10] Press key, verify make code received
- [ ] T183 [US10] Release key, verify break code received (SC-012)

**Checkpoint**: US10 complete - Raw keyboard scancodes work for games

---

## Phase 14: Minimal libc for Doom (Stretch Goal)

**Purpose**: C library replacement for linking doomgeneric

**Note**: This phase enables Doom integration but is not required for core OS functionality

- [ ] T184 [P] Create src/user/lib/libc.zig with malloc/free using sbrk
- [ ] T185 [P] Implement memcpy, memset, memmove in src/user/lib/libc.zig
- [ ] T186 [P] Implement strlen, strcpy, strcmp in src/user/lib/libc.zig
- [ ] T187 Implement printf with SYS_WRITE in src/user/lib/libc.zig
- [ ] T188 Implement fopen/fread/fseek/fclose wrapping file syscalls
- [ ] T189 Create doomgeneric hooks: DG_Init, DG_DrawFrame, DG_GetKey, DG_GetTicksMs, DG_SleepMs

---

## Phase 15: Polish & Integration Testing

**Purpose**: Stability verification and cross-cutting concerns

### Integration Tests

**QEMU Network Modes**:
- **TAP Mode** (requires sudo): `-netdev tap,id=n0,ifname=tap0,script=no -device e1000,netdev=n0`
- **SLIRP Mode** (no sudo): `-netdev user,id=n0,hostfwd=udp::5555-:5555 -device e1000,netdev=n0`

- [ ] T190 Create tests/integration/ping_test.sh for 10-minute ping flood (TAP mode, requires sudo)
- [ ] T190a **Fallback**: Create tests/integration/slirp_test.sh for SLIRP-based network testing (no sudo)
- [ ] T190b SLIRP test: kernel binds UDP 5555, host sends to localhost:5555, verify echo
- [ ] T190c Implement loopback network interface in src/net/loopback.zig (per archived/004 US10)
- [ ] T190d Loopback self-test: send ICMP echo to 127.0.0.1, verify reply through stack
- [ ] T190e Run loopback test in QEMU with no network device to verify stack logic
- [ ] T191 Create tests/integration/tcpdump_verify.sh for packet format validation
- [ ] T192 Verify kernel stable for 10+ minutes under ping load (SC-006)
- [ ] T193 Verify shell responsive during network activity

**Checkpoint**: Network tests pass in at least one mode (TAP, SLIRP, or loopback)

### Debug Infrastructure

- [ ] T194 [P] Add serial logging for all subsystems
- [ ] T195 [P] Add heap allocation/deallocation debug output
- [ ] T196 Verify heap coalescing prevents fragmentation after 1000+ cycles (SC-013)

### Performance Validation

- [ ] T197 Verify ping latency <100ms (SC-001)
- [ ] T198 Verify boot to shell <5 seconds (SC-008)
- [ ] T199 Verify framebuffer rendering capability at 60fps

### Documentation

- [ ] T200 Run quickstart.md validation steps
- [ ] T201 Update CLAUDE.md with final project structure

---

## Dependencies & Execution Order

### Phase Dependencies

```
Phase 1 (Setup) ─────────────► Phase 2 (Memory) ──┬──► Phase 3 (Interrupts)
                                                   │
                                                   └──► Phase 7 (Network/US1)

Phase 3 (Interrupts) ─────┬──► Phase 4 (Scheduler/US2)
                          │
                          └──► Phase 5 (Keyboard/US6)

Phase 4 (Scheduler/US2) ──┬──► Phase 6 (Userland/US3)
                          │
                          └──► Phase 7 (Network/US1)

Phase 6 (Userland/US3) ───┬──► Phase 10 (InitRD/US7)
                          ├──► Phase 11 (Heap/US8)
                          ├──► Phase 12 (Framebuffer/US9)
                          └──► Phase 13 (Scancodes/US10)

Phase 7 (US1) ────────────┬──► Phase 8 (ARP/US4)
                          └──► Phase 9 (UDP/US5)

All User Stories ─────────────► Phase 15 (Integration)
```

### User Story Dependencies

| Story | Depends On | Can Parallelize With |
|-------|------------|---------------------|
| US2 (Scheduler) | Phase 3 (Interrupts) | - |
| US6 (Keyboard) | Phase 3 (Interrupts) | US2 |
| US3 (Userland) | US2 (Scheduler) | - |
| US1 (Ping) | Phase 2 (Memory), Phase 3 (Interrupts) | US3, US6 |
| US4 (ARP) | US1 (Ping) | - |
| US5 (UDP) | US1 (Ping) | US4 |
| US7 (InitRD) | US3 (Userland) | US8, US9, US10 |
| US8 (Heap) | US3 (Userland) | US7, US9, US10 |
| US9 (Framebuffer) | US3 (Userland) | US7, US8, US10 |
| US10 (Scancodes) | US6 (Keyboard), US3 (Userland) | US7, US8, US9 |

### Parallel Opportunities

Within each phase, tasks marked [P] can run in parallel:

```bash
# Phase 1: Setup
T003, T004, T006, T007 can run in parallel

# Phase 6: Userland syscalls
T078, T079, T080, T081, T082, T083 can run in parallel

# Phase 7: Network protocols
T114, T118, T122, T126 (Ethernet, ARP, IP, ICMP) can start in parallel
```

---

## Implementation Strategy

### MVP First (US1: ICMP Ping Reply)

1. Complete Phase 1: Setup
2. Complete Phase 2: Memory Management
3. Complete Phase 3: Interrupt Infrastructure
4. Complete Phase 4: Scheduler (US2) - Required for network worker thread
5. Complete Phase 7: Network Stack (US1)
6. **STOP and VALIDATE**: Ping test from host

### Incremental Delivery

| Increment | Stories | Test Criteria |
|-----------|---------|---------------|
| MVP | US1, US2 | Ping replies work |
| Basic Shell | +US3, US6 | Interactive shell |
| Full Network | +US4, US5 | ARP resolution, UDP |
| File Access | +US7 | InitRD file I/O |
| Game Support | +US8, US9, US10 | Heap, framebuffer, scancodes |
| Doom | +Phase 14 | Doom runs |

---

## Critical Implementation Details

| Constraint | Implementation | Failure Mode |
|------------|---------------|--------------|
| Stack Alignment | T033: Push padding in IDT stubs | Random GPF crashes |
| Idle Thread | T052-T054: Create at boot | Scheduler hang/crash |
| HHDM | T014-T015: Use Limine HHDM | Page table corruption |
| Byte Order | T115, T118, T122, T126: Use @byteSwap | Silent packet drops |
| Big Kernel Lock | T075: CLI on syscall entry | TOCTOU races |
| IST for Double Fault | T029-T030: Configure TSS.ist[0] | Triple fault |
| Heap Coalescing | T019, T021: Boundary tags | Memory exhaustion |

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to enabling user story
- All network protocol tasks MUST use Big Endian byte order
- Always verify with host-side tcpdump for network issues
- Commit after each task or logical group
- Stop at any checkpoint to validate independently
