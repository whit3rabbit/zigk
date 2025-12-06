# Implementation Plan: Microkernel with Userland and Networking

**Branch**: `003-microkernel-userland-networking` | **Date**: 2025-12-05 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/003-microkernel-userland-networking/spec.md`

## Summary

Build a microkernel with complete memory management (4-level paging, heap allocator), interrupt handling (keyboard, network, timer IRQs with 16-byte stack alignment), preemptive multitasking (round-robin scheduler with Idle Thread), E1000 networking (ARP/UDP/ICMP with proper byte order), Ring 3 userland with syscall interface, InitRD file access, and direct framebuffer rendering for game support.

## Technical Context

**Language/Version**: Zig 0.13.x/0.14.x - freestanding x86_64 target
**Primary Dependencies**: Limine bootloader v7.x+, limine-zig bindings
**Storage**: InitRD via Limine Modules (flat file or TAR archive abstraction)
**Testing**: QEMU x86_64 with E1000 networking, host-side tcpdump/Wireshark for network verification
**Target Platform**: x86_64 bare metal (QEMU emulation for development)
**Project Type**: Single kernel binary with embedded userland
**Performance Goals**: <100ms ping latency, 10+ minute stable operation, 60 fps framebuffer rendering capability
**Constraints**: No libc, no std runtime, single CPU core, <2MB kernel heap
**Scale/Scope**: 2+ concurrent threads (network worker + userland shell/game), basic network stack (ARP/ICMP/UDP)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Bare-Metal Zig | PASS | Freestanding x86_64 target, no std runtime, inline asm only for hardware ops |
| II. Limine Protocol Compliance | PASS | Boot via Limine, use HHDM for memory access, modules for InitRD |
| III. Minimal Viable Kernel | PASS | Incremental milestones: boot → memory → interrupts → scheduler → networking → userland |
| IV. QEMU-First Verification | PASS | All testing in QEMU x86_64, bootable ISO output |
| V. Explicit Memory and Hardware | PASS | Volatile pointers for MMIO, explicit heap tracking, no hidden allocations |
| VI. Strict Layering | PASS | HAL (src/hal/) for hardware, kernel subsystems above HAL interfaces |
| VII. Zero-Copy Networking | PASS | Pointer-based packet handling, copy only at userspace boundary |
| VIII. Capability-Based Security | PASS | Syscall-only hardware access from userland, pointer validation |
| IX. Heap Hygiene | PASS | Tracked allocations in free-list heap, explicit deallocation paths |

**Gate Status**: PASSED - All principles satisfied

## Project Structure

### Documentation (this feature)

```text
specs/003-microkernel-userland-networking/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (syscall interfaces)
│   ├── syscall-interface.md
│   └── initrd-format.md
└── tasks.md             # Phase 2 output
```

### Source Code (repository root)

```text
src/
├── kernel/
│   ├── main.zig          # Kernel entry point
│   ├── scheduler.zig     # Preemptive round-robin scheduler + Idle Thread
│   └── heap.zig          # Free-list heap allocator
├── hal/
│   └── x86_64/
│       ├── gdt.zig       # GDT with TSS for IST
│       ├── idt.zig       # IDT with 16-byte RSP alignment stubs
│       ├── paging.zig    # 4-level page tables with HHDM
│       ├── pic.zig       # PIC configuration
│       └── syscall.zig   # syscall/sysret setup
├── drivers/
│   ├── keyboard.zig      # PS/2 keyboard IRQ1 handler
│   └── e1000.zig         # E1000 NIC driver with RX/TX rings
├── net/
│   ├── ethernet.zig      # Ethernet frame parsing (Big Endian)
│   ├── arp.zig           # ARP cache and request/reply
│   ├── ip.zig            # IPv4 header handling
│   ├── icmp.zig          # ICMP echo request/reply
│   └── udp.zig           # UDP datagram handling
├── fs/
│   └── initrd.zig        # InitRD abstraction over Limine Modules
├── user/
│   ├── shell.zig         # Ring 3 userland shell
│   ├── lib/
│   │   └── libc.zig      # Minimal libc replacement (malloc, free, printf, memcpy)
│   └── doom/             # doomgeneric C source (linked with Zig userland)
└── lib/
    ├── console.zig       # Framebuffer text output
    └── serial.zig        # Serial port debug output

tests/
├── integration/
│   ├── ping_test.sh      # Host-side ping verification
│   └── tcpdump_verify.sh # Packet capture verification
└── unit/
    └── heap_test.zig     # Heap allocator unit tests
```

**Structure Decision**: Single kernel project with HAL separation (src/hal/x86_64/), kernel subsystems (src/kernel/, src/net/, src/fs/), drivers (src/drivers/), and userland (src/user/) including minimal libc and Doom integration.

## Syscall Table

| Number | Name | Description | Parameters |
|--------|------|-------------|------------|
| 0 | SYS_EXIT | Terminate process | exit_code: i32 |
| 1 | SYS_WRITE | Write to display | fd: u32, buf: *const u8, len: usize |
| 2 | SYS_READ_CHAR | Read ASCII character | (blocking) → char: u8 |
| 3 | SYS_YIELD | Yield timeslice | - |
| 4 | SYS_GETPID | Get thread ID | - → tid: u32 |
| 5 | SYS_SLEEP | Sleep milliseconds | ms: u64 |
| 6 | SYS_SEND_UDP | Send UDP packet | dest_ip: u32, port: u16, buf: *const u8, len: usize |
| 7 | SYS_RECV_UDP | Receive UDP packet | buf: *u8, len: usize → actual_len: usize |
| 8 | SYS_GET_TIME | Get system ticks | - → ticks: u64 |
| 9 | SYS_READ_SCANCODE | Read raw scancode | - → scancode: u8 (or -EAGAIN) |
| 10 | SYS_GET_FB_INFO | Get framebuffer info | - → {width, height, pitch, bpp} |
| 11 | SYS_MAP_FB | Map framebuffer to userspace | - → *u8 (framebuffer address) |
| 12 | SYS_MMAP | Map memory (anonymous/framebuffer) | addr: ?*u8, len: usize, prot: u32, flags: u32 |
| 13 | SYS_OPEN | Open file from InitRD | path: *const u8, flags: u32 → fd: i32 |
| 14 | SYS_CLOSE | Close file descriptor | fd: u32 → result: i32 |
| 15 | SYS_READ | Read from file | fd: u32, buf: *u8, count: usize → bytes_read: isize |
| 16 | SYS_SEEK | Seek in file | fd: u32, offset: i64, whence: u32 → new_pos: i64 |
| 17 | SYS_SBRK | Expand heap | increment: isize → old_break: *u8 |

**Byte Order Note**: All multi-byte syscall parameters use host byte order (Little Endian). The kernel converts to network byte order (Big Endian) internally for network operations.

## Complexity Tracking

> No constitution violations requiring justification.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| *None* | - | - |

## Implementation Phases

### Phase 1: Memory Management Foundation

**Goal**: 4-level paging with HHDM and free-list heap

**Components**:
1. **PMM (Physical Memory Manager)**
   - Parse Limine memory map response
   - Implement bitmap allocator for page tracking
   - Reserve kernel pages, heap region (2MB)

2. **VMM (Virtual Memory Manager)**
   - Request HHDM from Limine
   - Implement `physToVirt()`/`virtToPhys()` using HHDM offset
   - 4-level page table creation (PML4 → PDPT → PD → PT)
   - Map kernel at higher half

3. **Heap Allocator**
   - Free-list allocator with block headers
   - **Coalescing on free** (FR-002a/b/c) - merge adjacent free blocks
   - Track allocation count for hygiene (Principle IX)

**Verification**: Serial debug output showing page allocation, heap alloc/free cycles

---

### Phase 2: Interrupt Infrastructure

**Goal**: GDT, TSS, IDT with proper alignment and IST

**Components**:
1. **GDT Setup**
   - Kernel code (0x08), data (0x10)
   - User code (0x20), data (0x18) - note: data before code for sysret
   - TSS descriptor (16 bytes)

2. **TSS Configuration**
   - `rsp0` for Ring 3 → Ring 0 transition
   - **IST[0] for Double Fault** (FR-009a/b) - dedicated 4KB stack

3. **IDT Setup**
   - 256 gates, interrupt type (0xE)
   - **16-byte RSP alignment stubs** (FR-009c/d) - push padding before calling Zig
   - Vector 8 (Double Fault): `ist = 1` to use IST[0]

4. **PIC Configuration**
   - Remap IRQ0-15 to vectors 0x20-0x2F
   - Enable IRQ1 (keyboard), IRQ0 (timer)

**Verification**: Trigger division by zero, verify handler runs without crash

---

### Phase 3: Timer and Scheduler

**Goal**: Preemptive round-robin with Idle Thread

**Components**:
1. **PIT Timer**
   - 100Hz tick (10ms quantum)
   - IRQ0 handler triggers scheduler

2. **Thread Structure**
   - State: Ready, Running, Blocked, Zombie
   - Kernel/user stack pointers
   - Saved register context

3. **Scheduler**
   - Ready queue (circular linked list)
   - Context switch: save regs → swap CR3 → update TSS.rsp0 → restore regs
   - **Idle Thread** (FR-013a/b/c) - created at boot, runs `hlt` loop

**Verification**: Two threads printing to serial, alternating output

---

### Phase 4: Keyboard and Input

**Goal**: PS/2 keyboard with dual buffers (ASCII + scancode)

**Components**:
1. **IRQ1 Handler**
   - Read port 0x60 for scancode
   - **Dual buffer** (FR-030b): ASCII buffer for shell, scancode buffer for games
   - Handle extended codes (0xE0 prefix)

2. **Scancode Buffer** (FR-030c/d)
   - 64-entry ring buffer
   - Store make/break codes
   - Drop oldest on overflow

3. **Key State Tracking**
   - 256-entry array for pressed keys
   - Update on make/break

**Verification**: Type keys, see ASCII in shell, read scancodes via syscall

---

### Phase 5: Syscall Interface

**Goal**: SYSCALL/SYSRET with Big Kernel Lock

**Components**:
1. **MSR Configuration**
   - IA32_STAR: Kernel/User segment selectors
   - IA32_LSTAR: syscall_entry address
   - IA32_FMASK: Clear IF on syscall

2. **Syscall Entry** (FR-023a/b)
   - **CLI first** - Big Kernel Lock
   - SWAPGS for kernel GS base
   - Switch to kernel stack (from TSS.rsp0)
   - Validate user pointers with interrupts disabled

3. **Syscall Dispatch**
   - Syscall number in RAX
   - Args in RDI, RSI, RDX, R10, R8, R9
   - Return value in RAX

4. **Basic Syscalls**
   - SYS_EXIT, SYS_WRITE, SYS_YIELD, SYS_GETPID, SYS_SLEEP

**Verification**: Userland program calls syscall, returns to kernel correctly

---

### Phase 6: Ring 3 Userland

**Goal**: Jump to user mode, run simple shell

**Components**:
1. **User Page Tables**
   - Map userland code/data with `user_accessible = 1`
   - Separate user stack

2. **IRETQ to Ring 3**
   - Push SS, RSP, RFLAGS, CS, RIP
   - Execute IRETQ

3. **Shell Program**
   - Read keyboard via SYS_READ_CHAR
   - Write to console via SYS_WRITE
   - Basic command parsing (help, echo)

**Verification**: Shell prompt appears, can type and see output

---

### Phase 7: Networking (E1000)

**Goal**: E1000 driver with ping reply

**Components**:
1. **PCI Enumeration**
   - Find device 8086:100E
   - Read BAR0 for MMIO base

2. **E1000 Initialization**
   - Reset device
   - Read MAC from EEPROM/RAL
   - Configure RX/TX descriptor rings
   - Enable interrupts (IMS)

3. **RX/TX Handling**
   - RX: IRQ on packet receive, read descriptors, pass to stack
   - TX: Fill descriptor, bump tail pointer
   - **Handle overflow** (FR-019a) - drop packets when ring full

4. **Network Worker Thread**
   - Separate kernel thread for protocol processing
   - IRQ handler queues packets, signals worker
   - Worker processes ARP/IP/ICMP/UDP stack
   - Decouples interrupt latency from protocol complexity

**Verification**: Receive packet, observe in debug log

---

### Phase 8: Network Stack

**Goal**: ARP, IPv4, ICMP, UDP

**Components**:
1. **Ethernet Parser**
   - **Big Endian** (FR-019b/c) - use `@byteSwap` for fields
   - Check EtherType (0x0800 IPv4, 0x0806 ARP)

2. **ARP**
   - Cache (256 entries)
   - Request/Reply handling
   - Respond to ARP requests for our IP

3. **IPv4**
   - Header parsing, checksum validation
   - Protocol dispatch (1=ICMP, 17=UDP)

4. **ICMP**
   - Echo Request (type 8) → Echo Reply (type 0)
   - Copy ID and sequence, recalculate checksum

5. **UDP**
   - Port-based dispatch
   - SYS_SEND_UDP, SYS_RECV_UDP syscalls

**Verification**: `ping <kernel-ip>` from host, receive replies

---

### Phase 9: InitRD Filesystem

**Goal**: Load files via Limine Modules

**Components**:
1. **Limine Module Request**
   - Parse module response
   - Get InitRD base address and size

2. **InitRD Parser** (FR-027a)
   - Simple file table format or TAR
   - Index file entries by name

3. **File Syscalls** (FR-027b/c/d/e)
   - SYS_OPEN: Lookup in file table, allocate FD
   - SYS_READ: Read from file position
   - SYS_SEEK: Update position (SEEK_SET/CUR/END)
   - SYS_CLOSE: Release FD

4. **File Descriptor Table** (FR-027f/g)
   - 16 FDs per process
   - Validate FD on each operation

**Verification**: Load test file from InitRD, read contents

---

### Phase 10: Dynamic Heap and Framebuffer

**Goal**: sbrk for userland, framebuffer mapping

**Components**:
1. **SYS_SBRK** (FR-028a/b/c/d)
   - Track per-process heap break
   - Map pages on demand
   - Return old break, update to new break

2. **SYS_GET_FB_INFO** (FR-029)
   - Return width, height, pitch, bpp from Limine

3. **SYS_MMAP_FB** (FR-029a/b/c/d)
   - Map framebuffer physical pages to userspace
   - Write-through/uncached page flags
   - Only allow framebuffer region (security)

**Verification**: Userland writes pixels, they appear on screen

---

### Phase 11: Integration and Testing

**Goal**: Stable 10+ minute operation

**Components**:
1. **Integration Tests**
   - Ping flood test (10 minutes)
   - Shell interaction during network load
   - File read while networking

2. **Debug Infrastructure**
   - Serial logging for all subsystems
   - Host-side tcpdump for network verification

3. **Performance Validation**
   - <100ms ping latency
   - 60fps framebuffer capability

**Verification**: SC-001 through SC-013 pass

---

## Dependencies Graph

```
Phase 1 (Memory) ──┬──► Phase 2 (Interrupts) ──┬──► Phase 3 (Scheduler)
                   │                            │
                   │                            └──► Phase 4 (Keyboard)
                   │
                   └──► Phase 7 (E1000) ──────────► Phase 8 (Network Stack)

Phase 3 ──┬──► Phase 5 (Syscalls) ──► Phase 6 (Userland)
          │
          └──► Phase 9 (InitRD)

Phase 6 ──► Phase 10 (Heap + Framebuffer)

All Phases ──► Phase 11 (Integration)
```

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Triple fault during IST setup | Test Double Fault handler early with intentional stack overflow |
| Silent network failures | Always verify with host-side tcpdump |
| Heap fragmentation | Implement coalescing before any long-running tests |
| TOCTOU in syscalls | Big Kernel Lock (CLI) verified by assertion |
| RSP alignment crashes | Test interrupt handlers with SSE-using code early |
