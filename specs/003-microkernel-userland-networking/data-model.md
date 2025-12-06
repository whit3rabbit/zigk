# Data Model: Microkernel with Userland and Networking

**Feature Branch**: `003-microkernel-userland-networking`
**Created**: 2025-12-04

## Overview

This document defines the core data structures for the microkernel. All structures use Zig packed structs where hardware layout is required, and regular structs for kernel-internal data.

---

## 1. Memory Management Entities

### PageTableEntry

Hardware-defined structure for x86_64 4-level paging.

| Field | Type | Description |
|-------|------|-------------|
| present | u1 | Entry is valid |
| writable | u1 | Page is writable |
| user_accessible | u1 | Accessible from Ring 3 |
| write_through | u1 | Write-through caching |
| cache_disabled | u1 | Caching disabled |
| accessed | u1 | Page has been accessed |
| dirty | u1 | Page has been written |
| huge_page | u1 | 2MB/1GB page (PD/PDPT) |
| global | u1 | Not flushed on CR3 reload |
| _reserved1 | u3 | Reserved bits |
| physical_address | u40 | Physical frame number |
| _reserved2 | u11 | Reserved bits |
| execute_disabled | u1 | No-execute bit |

**Validation Rules**:
- `present` must be 1 for valid entries
- `physical_address` must be 4KB-aligned (bits 0-11 are implicit 0)
- `user_accessible` = 0 for kernel pages (FR-003)
- `user_accessible` = 1 for userland pages (FR-004)

**State Transitions**:
- Unmapped → Mapped: Set `present = 1`, populate address
- Mapped → Unmapped: Set `present = 0`, invalidate TLB

---

### PhysicalPage

Kernel-internal tracking for physical memory.

| Field | Type | Description |
|-------|------|-------------|
| frame_number | u64 | Physical page index (addr / 4096) |
| ref_count | u16 | Reference count for sharing |
| flags | PageFlags | Usage flags |

**PageFlags**:
- `free`: Available for allocation
- `kernel`: Kernel-owned, not swappable
- `user`: User-owned, potentially swappable
- `dma`: Used for DMA buffers (E1000)

---

### HeapBlock

Free-list allocator block header.

| Field | Type | Description |
|-------|------|-------------|
| next | ?*HeapBlock | Next free block |
| size | u64 | Size of this block (including header) |

**Validation Rules**:
- `size` must be >= sizeof(HeapBlock)
- `next` must point to valid heap region or be null

---

## 2. Interrupt Handling Entities

### GDTEntry

Global Descriptor Table entry (8 bytes).

| Field | Type | Description |
|-------|------|-------------|
| limit_low | u16 | Segment limit (bits 0-15) |
| base_low | u16 | Base address (bits 0-15) |
| base_mid | u8 | Base address (bits 16-23) |
| access | u8 | Access flags |
| limit_high_flags | u8 | Limit (16-19) + flags |
| base_high | u8 | Base address (bits 24-31) |

**Access Byte**:
- Bit 7: Present
- Bits 6-5: DPL (0 = kernel, 3 = user)
- Bit 4: Descriptor type (1 = code/data)
- Bits 3-0: Type flags

---

### TSSDescriptor

Task State Segment descriptor (16 bytes, spans two GDT slots).

| Field | Type | Description |
|-------|------|-------------|
| limit_low | u16 | TSS size (bits 0-15) |
| base_low | u16 | TSS address (bits 0-15) |
| base_mid | u8 | TSS address (bits 16-23) |
| access | u8 | Type = 0x89 (available TSS) |
| limit_flags | u8 | Limit (16-19) + flags |
| base_high_low | u8 | TSS address (bits 24-31) |
| base_high | u32 | TSS address (bits 32-63) |
| _reserved | u32 | Must be 0 |

---

### TSS

Task State Segment (104 bytes minimum).

| Field | Type | Description |
|-------|------|-------------|
| _reserved0 | u32 | Reserved |
| rsp0 | u64 | Ring 0 stack pointer |
| rsp1 | u64 | Ring 1 stack pointer |
| rsp2 | u64 | Ring 2 stack pointer |
| _reserved1 | u64 | Reserved |
| ist | [7]u64 | Interrupt stack table |
| _reserved2 | u64 | Reserved |
| _reserved3 | u16 | Reserved |
| iopb_offset | u16 | I/O permission bitmap offset |

**Validation Rules**:
- `rsp0` must point to valid kernel stack (FR-013)
- `iopb_offset` = 104 (no I/O bitmap)
- **`ist[0]` MUST point to dedicated Double Fault stack (4KB, 16-byte aligned)**

**IST Configuration (CRITICAL)**:
| IST Entry | Vector | Purpose |
|-----------|--------|---------|
| IST[0] (ist=1) | 8 (Double Fault) | Dedicated stack to prevent triple fault |
| IST[1-6] | - | Reserved for future use |

**Why IST[0] is Required**: If kernel stack overflows, Double Fault uses this separate stack. Without it, the Double Fault handler would try to use the already-overflowed stack, causing a triple fault (CPU reset).

---

### IDTGate

Interrupt Descriptor Table gate (16 bytes).

| Field | Type | Description |
|-------|------|-------------|
| offset_low | u16 | Handler address (bits 0-15) |
| segment | u16 | Code segment selector |
| ist | u3 | IST index (0 = no IST) |
| _reserved1 | u5 | Reserved |
| gate_type | u4 | 0xE = interrupt, 0xF = trap |
| _reserved2 | u1 | Reserved |
| dpl | u2 | Descriptor privilege level |
| present | u1 | Gate is valid |
| offset_mid | u16 | Handler address (bits 16-31) |
| offset_high | u32 | Handler address (bits 32-63) |
| _reserved3 | u32 | Reserved |

**Validation Rules**:
- `present` = 1 for active handlers
- `segment` = 0x08 (kernel code segment)
- `gate_type` = 0xE for hardware interrupts

---

### InterruptContext

Saved CPU state on interrupt entry. **MUST be `extern struct`** to guarantee memory layout matches the exact order pushed by CPU and assembly interrupt stubs.

| Field | Type | Description |
|-------|------|-------------|
| r15 | u64 | General register |
| r14 | u64 | General register |
| r13 | u64 | General register |
| r12 | u64 | General register |
| r11 | u64 | General register |
| r10 | u64 | General register |
| r9 | u64 | General register |
| r8 | u64 | General register |
| rdi | u64 | General register |
| rsi | u64 | General register |
| rdx | u64 | General register |
| rcx | u64 | General register |
| rbx | u64 | General register |
| rax | u64 | General register |
| rbp | u64 | Base pointer |
| vector | u64 | Interrupt vector number |
| error_code | u64 | Error code (or 0) |
| rip | u64 | Instruction pointer |
| cs | u64 | Code segment |
| rflags | u64 | CPU flags |
| rsp | u64 | Stack pointer |
| ss | u64 | Stack segment |

**Implementation Note**: Use `pub const InterruptContext = extern struct { ... }` in Zig code. Standard Zig structs do NOT guarantee field order or memory layout. Using a regular struct here will cause register values to be misread, leading to crashes or undefined behavior.

---

## 3. Network Entities

### EthernetFrame

Ethernet II frame header (14 bytes).

| Field | Type | Description |
|-------|------|-------------|
| dest_mac | [6]u8 | Destination MAC address |
| src_mac | [6]u8 | Source MAC address |
| ether_type | u16 | Protocol type (big-endian) |

**EtherType Values**:
- 0x0800: IPv4
- 0x0806: ARP
- 0x86DD: IPv6 (not implemented)

---

### ARPPacket

ARP request/reply packet (28 bytes).

| Field | Type | Description |
|-------|------|-------------|
| hardware_type | u16 | 1 = Ethernet (big-endian) |
| protocol_type | u16 | 0x0800 = IPv4 (big-endian) |
| hw_addr_len | u8 | 6 for MAC |
| proto_addr_len | u8 | 4 for IPv4 |
| operation | u16 | 1 = request, 2 = reply (big-endian) |
| sender_mac | [6]u8 | Sender MAC address |
| sender_ip | u32 | Sender IP address (big-endian) |
| target_mac | [6]u8 | Target MAC address |
| target_ip | u32 | Target IP address (big-endian) |

**State Transitions (ARP Cache Entry)**:
- Unknown → Pending: ARP request sent
- Pending → Resolved: ARP reply received
- Resolved → Expired: Timeout (optional for MVP)

---

### ARPCacheEntry

ARP cache entry for IP-to-MAC mapping.

| Field | Type | Description |
|-------|------|-------------|
| ip_addr | u32 | IP address (network byte order) |
| mac_addr | [6]u8 | MAC address |
| state | ARPState | Entry state |
| timestamp | u64 | Last update time (ticks) |

**ARPState**:
- `free`: Slot available
- `pending`: ARP request sent, awaiting reply
- `resolved`: Valid MAC address cached

---

### IPv4Header

IPv4 packet header (20 bytes minimum).

| Field | Type | Description |
|-------|------|-------------|
| version_ihl | u8 | Version (4) + header length |
| dscp_ecn | u8 | DSCP + ECN |
| total_length | u16 | Total packet length (big-endian) |
| identification | u16 | Fragment ID (big-endian) |
| flags_fragment | u16 | Flags + fragment offset (big-endian) |
| ttl | u8 | Time to live |
| protocol | u8 | Upper protocol (1=ICMP, 17=UDP) |
| checksum | u16 | Header checksum (big-endian) |
| src_ip | u32 | Source IP (big-endian) |
| dest_ip | u32 | Destination IP (big-endian) |

**Validation Rules**:
- `version_ihl` >> 4 must equal 4
- `version_ihl` & 0x0F must be >= 5
- `checksum` must validate to 0 when computed

---

### ICMPHeader

ICMP message header (8 bytes).

| Field | Type | Description |
|-------|------|-------------|
| type | u8 | Message type |
| code | u8 | Message code |
| checksum | u16 | ICMP checksum (big-endian) |
| id | u16 | Identifier (big-endian) |
| sequence | u16 | Sequence number (big-endian) |

**Type Values**:
- 0: Echo Reply
- 8: Echo Request

---

### UDPHeader

UDP datagram header (8 bytes).

| Field | Type | Description |
|-------|------|-------------|
| src_port | u16 | Source port (big-endian) |
| dest_port | u16 | Destination port (big-endian) |
| length | u16 | UDP length including header (big-endian) |
| checksum | u16 | UDP checksum (big-endian, 0 = disabled) |

---

### PacketBuffer

Zero-copy packet buffer reference.

| Field | Type | Description |
|-------|------|-------------|
| data | [*]u8 | Pointer to packet data |
| len | u16 | Total packet length |
| offset | u16 | Current parse offset |
| capacity | u16 | Buffer capacity |

**Validation Rules**:
- `offset` + remaining data <= `len`
- `len` <= `capacity`
- `data` must point to valid DMA buffer for TX

---

### TxDescriptor

E1000 transmit descriptor (16 bytes).

| Field | Type | Description |
|-------|------|-------------|
| buffer_addr | u64 | Physical buffer address |
| length | u16 | Buffer length |
| cso | u8 | Checksum offset |
| cmd | u8 | Command flags |
| status | u8 | Status flags |
| css | u8 | Checksum start |
| special | u16 | VLAN/special field |

**Command Flags**:
- 0x01: EOP (End of Packet)
- 0x02: IFCS (Insert FCS)
- 0x08: RS (Report Status)

**Status Flags**:
- 0x01: DD (Descriptor Done)

---

### RxDescriptor

E1000 receive descriptor (16 bytes).

| Field | Type | Description |
|-------|------|-------------|
| buffer_addr | u64 | Physical buffer address |
| length | u16 | Received length |
| checksum | u16 | Packet checksum |
| status | u8 | Status flags |
| errors | u8 | Error flags |
| special | u16 | VLAN/special field |

**Status Flags**:
- 0x01: DD (Descriptor Done)
- 0x02: EOP (End of Packet)

---

## 4. Process Management Entities

### Thread

Kernel thread/task structure.

| Field | Type | Description |
|-------|------|-------------|
| tid | u32 | Thread ID |
| state | ThreadState | Current state |
| priority | u8 | Scheduling priority |
| context | *InterruptContext | Saved CPU context |
| kernel_stack_base | u64 | Kernel stack base address |
| kernel_stack_ptr | u64 | Current kernel stack pointer |
| user_stack_base | u64 | User stack base address |
| user_stack_ptr | u64 | Current user stack pointer |
| page_table | u64 | CR3 value (PML4 physical address) |
| time_slice | u32 | Remaining time quantum (ms) |
| next | ?*Thread | Next thread in queue |
| prev | ?*Thread | Previous thread in queue |

**ThreadState**:
- `ready`: Eligible for scheduling
- `running`: Currently executing
- `blocked`: Waiting for I/O or event
- `zombie`: Terminated, awaiting cleanup

**State Transitions**:
- Created → Ready: Thread initialized
- Ready → Running: Scheduler selects thread
- Running → Ready: Preempted by timer
- Running → Blocked: Waiting for I/O
- Blocked → Ready: I/O complete
- Running → Zombie: Thread exits

---

### SyscallRegisters

Saved registers on syscall entry.

| Field | Type | Description |
|-------|------|-------------|
| rax | u64 | Syscall number / return value |
| rdi | u64 | Argument 0 |
| rsi | u64 | Argument 1 |
| rdx | u64 | Argument 2 |
| r10 | u64 | Argument 3 |
| r8 | u64 | Argument 4 |
| r9 | u64 | Argument 5 |
| rcx | u64 | Return address (set by SYSCALL) |
| r11 | u64 | Saved RFLAGS (set by SYSCALL) |
| rsp | u64 | User stack pointer |

---

## 5. Shell Entities

### InputBuffer

Keyboard input buffer for shell.

| Field | Type | Description |
|-------|------|-------------|
| buffer | [256]u8 | Character buffer |
| head | u8 | Read position |
| tail | u8 | Write position |

**Validation Rules**:
- Buffer is circular: `(tail + 1) % 256 == head` means full
- `head == tail` means empty

---

### Command

Parsed shell command.

| Field | Type | Description |
|-------|------|-------------|
| name | []const u8 | Command name |
| args | [][]const u8 | Command arguments |

---

## 6. InitRD Filesystem Entities

### InitRDHeader

Header at the start of the InitRD image.

| Field | Type | Description |
|-------|------|-------------|
| magic | u32 | Magic number 0x52444E49 ("INRD") |
| version | u16 | Format version (1) |
| entry_count | u16 | Number of file entries |
| data_offset | u32 | Offset to file data region |

**Validation Rules**:
- `magic` must equal 0x52444E49
- `version` must equal 1
- `entry_count` <= 256 (reasonable limit for MVP)

---

### InitRDFileEntry

File entry in the InitRD file table.

| Field | Type | Description |
|-------|------|-------------|
| name | [32]u8 | Null-terminated filename |
| offset | u32 | Offset from InitRD start to file data |
| size | u32 | File size in bytes |
| flags | u8 | File flags (reserved) |
| _reserved | [3]u8 | Padding for alignment |

**Validation Rules**:
- `name` must be null-terminated
- `offset + size` must not exceed InitRD size
- Maximum filename length: 31 characters

---

### FileDescriptor

Per-process file descriptor.

| Field | Type | Description |
|-------|------|-------------|
| initrd_entry | ?*const InitRDFileEntry | Pointer to InitRD file entry (null if closed) |
| position | u64 | Current read position |
| flags | u32 | Open flags (O_RDONLY, etc.) |

**Validation Rules**:
- `position` <= `initrd_entry.size`
- Only O_RDONLY supported for InitRD

**State Transitions**:
- Closed → Open: `sys_open()` success
- Open → Closed: `sys_close()` called

---

### FileDescriptorTable

Per-thread file descriptor table.

| Field | Type | Description |
|-------|------|-------------|
| fds | [16]FileDescriptor | File descriptors 0-15 |
| next_fd | u8 | Next available FD index |

**Validation Rules**:
- FD 0, 1, 2 reserved for stdin, stdout, stderr
- Available FDs: 3-15 (13 slots for files)

---

## 7. Framebuffer Entities

### FramebufferInfo

Information about the system framebuffer.

| Field | Type | Description |
|-------|------|-------------|
| address | u64 | Physical address of framebuffer |
| width | u32 | Width in pixels |
| height | u32 | Height in pixels |
| pitch | u32 | Bytes per row |
| bpp | u16 | Bits per pixel (typically 32) |
| red_mask_size | u8 | Red channel bits |
| red_mask_shift | u8 | Red channel position |
| green_mask_size | u8 | Green channel bits |
| green_mask_shift | u8 | Green channel position |
| blue_mask_size | u8 | Blue channel bits |
| blue_mask_shift | u8 | Blue channel position |

**Validation Rules**:
- `bpp` must be 24 or 32 for MVP
- `pitch` >= `width * (bpp / 8)`

---

### UserFramebufferMapping

Tracking userland framebuffer mappings.

| Field | Type | Description |
|-------|------|-------------|
| thread_id | u32 | Thread that has the mapping |
| user_vaddr | u64 | Virtual address in user space |
| page_count | u32 | Number of pages mapped |
| is_mapped | bool | Whether mapping is active |

**Validation Rules**:
- Only one framebuffer mapping per thread
- Pages must have user + write + write-through flags

---

## 8. Raw Keyboard Input Entities

### ScancodeBuffer

Ring buffer for raw keyboard scancodes.

| Field | Type | Description |
|-------|------|-------------|
| buffer | [64]u8 | Scancode storage |
| head | u8 | Read position (0-63) |
| tail | u8 | Write position (0-63) |

**Validation Rules**:
- `(tail + 1) % 64 == head` means full
- `head == tail` means empty
- On overflow, drop oldest entry (advance head)

**State Transitions**:
- Empty → Has Data: Key event received
- Has Data → Empty: All scancodes consumed
- Full → Full: New scancode overwrites oldest

---

### KeyboardState

Complete keyboard driver state.

| Field | Type | Description |
|-------|------|-------------|
| ascii_buffer | InputBuffer | ASCII character buffer (existing) |
| scancode_buffer | ScancodeBuffer | Raw scancode buffer (new) |
| shift_pressed | bool | Shift key held |
| ctrl_pressed | bool | Ctrl key held |
| alt_pressed | bool | Alt key held |

**Design Note**: Both buffers are populated on each key event. Games read from scancode_buffer; shell reads from ascii_buffer.

---

## 9. Dynamic Heap Entities

### UserHeapInfo

Per-thread userland heap tracking.

| Field | Type | Description |
|-------|------|-------------|
| base_addr | u64 | Heap start address (after BSS) |
| current_break | u64 | Current program break |
| max_break | u64 | Maximum allowed break (heap limit) |

**Validation Rules**:
- `current_break` >= `base_addr`
- `current_break` <= `max_break`
- `base_addr` must be page-aligned

**State Transitions**:
- Initial: `current_break = base_addr`
- After sbrk(n): `current_break += n` (page-aligned)

---

## 10. Entity Relationships

```
┌─────────────────────────────────────────────────────────────────┐
│                        Memory Management                         │
├─────────────────────────────────────────────────────────────────┤
│  PageTableEntry ─────► PhysicalPage                             │
│       │                     │                                    │
│       │ maps to             │ tracked by                         │
│       ▼                     ▼                                    │
│  VirtualAddress        PMM Bitmap                                │
│                             │                                    │
│                             │ allocates from                     │
│                             ▼                                    │
│                        HeapBlock ◄──── Free List                 │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                         Networking                               │
├─────────────────────────────────────────────────────────────────┤
│  E1000 ─────► TxDescriptor ─────► PacketBuffer                  │
│    │              │                    │                         │
│    │              │                    │ contains                │
│    ▼              ▼                    ▼                         │
│  RxDescriptor    DMA Buffer      EthernetFrame                  │
│    │                                   │                         │
│    │                                   │ encapsulates            │
│    │                                   ▼                         │
│    │                             ARPPacket / IPv4Header          │
│    │                                   │                         │
│    │                                   │ encapsulates            │
│    │                                   ▼                         │
│    │                             ICMPHeader / UDPHeader          │
│    │                                                             │
│    └─────────────► ARPCacheEntry                                │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                      Process Management                          │
├─────────────────────────────────────────────────────────────────┤
│  Scheduler ─────► ReadyQueue ─────► Thread                      │
│                        │               │                         │
│                        │               │ has                     │
│                        │               ▼                         │
│                        │         InterruptContext                │
│                        │               │                         │
│                        │               │ saved on                │
│                        │               ▼                         │
│                        │         SyscallRegisters                │
│                        │                                         │
│                        └───────► TSS.rsp0 (kernel stack)        │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                      InitRD Filesystem                           │
├─────────────────────────────────────────────────────────────────┤
│  InitRDHeader ─────► InitRDFileEntry[] ─────► File Data         │
│       │                     │                                    │
│       │                     │ referenced by                      │
│       ▼                     ▼                                    │
│  Limine Module         FileDescriptor ◄──── FileDescriptorTable │
│                             │                                    │
│                             │ tracks                             │
│                             ▼                                    │
│                        Read Position                             │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                      Framebuffer + Input                         │
├─────────────────────────────────────────────────────────────────┤
│  Limine Framebuffer ─────► FramebufferInfo                      │
│       │                         │                                │
│       │                         │ maps to                        │
│       ▼                         ▼                                │
│  Physical Pages          UserFramebufferMapping ◄── Thread      │
│                                                                  │
│  PS/2 Keyboard ─────► KeyboardState                             │
│                            │                                     │
│                            ├───► ascii_buffer (shell)           │
│                            └───► scancode_buffer (games)        │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                      Dynamic Heap                                │
├─────────────────────────────────────────────────────────────────┤
│  Thread ─────► UserHeapInfo                                     │
│                    │                                             │
│                    │ tracks                                      │
│                    ▼                                             │
│               base_addr ◄──── current_break ◄──── max_break     │
│                    │              │                              │
│                    │              │ grows via                    │
│                    │              ▼                              │
│                    └─────────► sys_sbrk()                       │
└─────────────────────────────────────────────────────────────────┘
```

---

## 11. Size Summary

| Entity | Size (bytes) | Alignment |
|--------|--------------|-----------|
| PageTableEntry | 8 | 8 |
| PageTable (512 entries) | 4096 | 4096 |
| GDTEntry | 8 | 8 |
| TSSDescriptor | 16 | 8 |
| TSS | 104 | 8 |
| IDTGate | 16 | 8 |
| IDT (256 entries) | 4096 | 8 |
| InterruptContext | 176 | 8 |
| EthernetFrame | 14 | 1 |
| ARPPacket | 28 | 1 |
| IPv4Header | 20 | 1 |
| ICMPHeader | 8 | 1 |
| UDPHeader | 8 | 1 |
| TxDescriptor | 16 | 16 |
| RxDescriptor | 16 | 16 |
| Thread | ~128 | 8 |
| ARPCacheEntry | 24 | 8 |
| InitRDHeader | 12 | 4 |
| InitRDFileEntry | 44 | 4 |
| FileDescriptor | 24 | 8 |
| FileDescriptorTable | 392 | 8 |
| FramebufferInfo | 32 | 8 |
| UserFramebufferMapping | 24 | 8 |
| ScancodeBuffer | 66 | 1 |
| KeyboardState | ~330 | 8 |
| UserHeapInfo | 24 | 8 |
