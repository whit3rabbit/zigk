# Research: Microkernel with Userland and Networking

**Feature Branch**: `003-microkernel-userland-networking`
**Created**: 2025-12-04
**Status**: Complete

## Executive Summary

This document consolidates research findings for implementing a x86_64 microkernel with memory management, interrupt handling, preemptive multitasking, E1000 networking, and Ring 3 userland. All decisions comply with the ZigK Constitution principles.

---

## 1. Memory Management

### Decision: 4-Level Paging with Bitmap PMM, HHDM, and Free-List Heap

**Rationale**: x86_64 requires PML4 paging. Bitmap allocator provides O(1) page tracking with minimal overhead (0.025% of RAM). Free-list heap enables dynamic allocation with tracked deallocation per Principle IX. HHDM (Higher Half Direct Map) provided by Limine enables simple physical-to-virtual address translation without complex recursive mapping.

**Alternatives Considered**:
- Buddy allocator: More complex, better for large contiguous allocations - rejected for MVP simplicity
- Bump allocator only: No deallocation support - rejected for long-running kernel
- Slab allocator: Excellent for fixed-size objects - deferred to post-MVP
- Recursive page table mapping: Complex, error-prone - rejected in favor of HHDM

### HHDM (Higher Half Direct Map) Strategy

**Limine HHDM Request**: Add to `main.zig`:
```zig
pub export var hhdm_request: limine.HhdmRequest = .{};
```

**Physical-to-Virtual Conversion**:
```zig
var hhdm_offset: u64 = undefined;

pub fn init() void {
    if (hhdm_request.response) |response| {
        hhdm_offset = response.offset;
    } else {
        @panic("HHDM not available");
    }
}

pub fn physToVirt(phys: u64) [*]u8 {
    return @ptrFromInt(phys + hhdm_offset);
}

pub fn virtToPhys(virt: u64) u64 {
    return virt - hhdm_offset;
}
```

**Why HHDM is Critical**: To write a page table entry (which is at a physical address), the kernel needs a virtual address. HHDM maps all physical memory starting at `0xffff800000000000 + phys`, allowing direct access to any physical address without creating temporary mappings.

### Page Table Entry Structure

```zig
pub const PageTableEntry = packed struct(u64) {
    present: u1 = 0,
    writable: u1 = 0,
    user_accessible: u1 = 0,
    write_through: u1 = 0,
    cache_disabled: u1 = 0,
    accessed: u1 = 0,
    dirty: u1 = 0,
    huge_page: u1 = 0,
    global: u1 = 0,
    _reserved1: u3 = 0,
    physical_address: u40,
    _reserved2: u11 = 0,
    execute_disabled: u1 = 0,
};
```

### PMM Initialization Sequence

1. Parse Limine memory map response
2. Calculate total pages and allocate bitmap from usable region
3. Mark all pages as allocated initially
4. Second pass: mark usable regions as free
5. Reserve kernel pages and page table pages

### Heap Strategy (Simplified - No Bump-to-FreeList Handover)

- **Single allocator**: Free-list allocator initialized immediately after VMM
- **Initialization**: PMM allocates 2MB contiguous physical pages for heap region
- **No handover complexity**: Skip bump allocator entirely; free-list from the start
- **Principle IX compliance**: Track `allocated_count`, panic on double-free

**Initialization Sequence**:
1. PMM parses Limine memory map, initializes bitmap
2. VMM initializes with HHDM access
3. PMM allocates 512 contiguous pages (2MB) for heap
4. Heap initializer creates single large free block from 2MB region
5. All kernel allocations use free-list from this point

### Constitution Compliance

| Principle | Requirement | Implementation |
|-----------|-------------|----------------|
| V. Explicit Memory | Volatile pointers, validate before use | `@volatileStore` for PTEs, HHDM access |
| IX. Heap Hygiene | Track all allocations | `allocated_count` in free-list allocator |

### Key Resources

- [Paging - OSDev Wiki](https://wiki.osdev.org/Paging)
- [Memory Allocation - OSDev Wiki](https://wiki.osdev.org/Memory_Allocation)
- [Allocator Designs (Rust OS)](https://os.phil-opp.com/allocator-designs/)

---

## 2. Interrupt Handling

### Decision: 8259 PIC with Software Context Switching

**Rationale**: PIC is simpler than APIC for single-core MVP. Software context switching is required in x86_64 long mode (hardware task switching unsupported).

**Alternatives Considered**:
- APIC/LAPIC: Better for SMP, more complex - deferred to post-MVP
- IO-APIC: Required for MSI interrupts - not needed for E1000 legacy mode

### GDT Layout

| Entry | Selector | Description | DPL |
|-------|----------|-------------|-----|
| 0 | 0x00 | Null | - |
| 1 | 0x08 | Kernel Code | 0 |
| 2 | 0x10 | Kernel Data | 0 |
| 3 | 0x18 | User Data | 3 |
| 4 | 0x20 | User Code | 3 |
| 5-6 | 0x28 | TSS (16 bytes) | 0 |

### IDT Gate Descriptor (16 bytes)

```zig
pub const GateDescriptor = packed struct(u128) {
    offset_low: u16,
    segment_selector: u16,
    ist: u3 = 0,
    _reserved1: u5 = 0,
    gate_type: u4,        // 0xE=Interrupt, 0xF=Trap
    _reserved2: u1 = 0,
    dpl: u2 = 0,
    present: bool = true,
    offset_middle: u16,
    offset_high: u32,
    _reserved3: u32 = 0,
};
```

### PIC Remapping

- Master PIC: IRQ0-7 → vectors 0x20-0x27
- Slave PIC: IRQ8-15 → vectors 0x28-0x2F
- Required to avoid conflict with CPU exceptions (0x00-0x1F)

### Interrupt Stub Pattern

1. Push dummy error code (if exception doesn't provide one)
2. Push vector number
3. Save all general-purpose registers
4. Call high-level handler with context pointer
5. Restore registers
6. IRETQ (not IRET - must use 64-bit variant)

### TSS for Ring Transitions and IST (Interrupt Stack Table)

```zig
pub const TSS = packed struct {
    reserved0: u32 = 0,
    rsp0: u64,          // Kernel stack for Ring 3 → Ring 0
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist: [7]u64 = [_]u64{0} ** 7,  // IST[0] = Double Fault stack
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iopb_offset: u16 = 104,
};
```

**Critical: IST for Double Fault Prevention**

The Double Fault handler MUST use a dedicated stack via IST to prevent triple faults:

```zig
// Allocate dedicated stack for Double Fault (4KB)
var double_fault_stack: [4096]u8 align(16) = undefined;

pub fn initTSS() void {
    // IST entry 1 = Double Fault stack (top of stack)
    tss.ist[0] = @intFromPtr(&double_fault_stack) + double_fault_stack.len;
    tss.rsp0 = kernel_stack_top;
}

// In IDT setup for vector 0x08 (Double Fault):
pub fn setupDoubleFaultGate() void {
    var gate = &idt.entries[8];
    gate.ist = 1;  // Use IST[0] (entry 1 in hardware terms)
    // ... other gate setup
}
```

**Why IST is Critical**: If the kernel stack overflows, a Stack Fault (#SS) or Page Fault (#PF) occurs. If the handler tries to push to the same overflowing stack, a Double Fault (#DF) occurs. If the Double Fault handler also uses the bad stack, the CPU triple faults and reboots. IST provides a guaranteed-good stack for the Double Fault handler.

### Constitution Compliance

| Principle | Requirement | Implementation |
|-----------|-------------|----------------|
| I. Bare-Metal Zig | Inline asm for hardware ops | Port I/O, LGDT, LIDT, LTR |
| VI. Strict Layering | HAL contains hardware access | `hal/gdt.zig`, `hal/idt.zig`, `hal/pic.zig` |

### Key Resources

- [Interrupt Descriptor Table - OSDev Wiki](https://wiki.osdev.org/Interrupt_Descriptor_Table)
- [8259 PIC - OSDev Wiki](https://wiki.osdev.org/8259_PIC)
- [Context Switching - OSDev Wiki](https://wiki.osdev.org/Context_Switching)

---

## 3. E1000 Network Driver

### Decision: Legacy Descriptor Mode with Zero-Copy Buffer Passing

**Rationale**: Legacy mode is simpler and sufficient for MVP. Zero-copy aligns with Principle VII.

**Alternatives Considered**:
- Extended descriptors: More features, more complex - not needed for ICMP/UDP
- TCP offload: Requires extended descriptors - deferred

### PCI Enumeration

- Config Address Port: 0xCF8
- Config Data Port: 0xCFC
- E1000 Vendor ID: 0x8086
- E1000 Device ID: 0x100E (QEMU default)

### E1000 Register Map (Key Registers)

| Register | Offset | Purpose |
|----------|--------|---------|
| CTRL | 0x00000 | Device control |
| STATUS | 0x00008 | Link status |
| RCTL | 0x00100 | Receive control |
| TCTL | 0x00400 | Transmit control |
| RDBAL/H | 0x02800/04 | RX descriptor base |
| RDLEN | 0x02808 | RX ring length |
| RDH/RDT | 0x02810/18 | RX head/tail |
| TDBAL/H | 0x03800/04 | TX descriptor base |
| TDLEN | 0x03808 | TX ring length |
| TDH/TDT | 0x03810/18 | TX head/tail |
| ICR | 0x000C0 | Interrupt cause (auto-clear) |
| IMS | 0x000D0 | Interrupt mask set |
| RAL/RAH | 0x05400/04 | MAC address |

### Descriptor Structures (16 bytes each)

```zig
pub const TxDescriptor = packed struct(u128) {
    buffer_addr: u64,
    length: u16,
    cso: u8,
    cmd: u8,
    status: u8,
    css: u8,
    special: u16,
};

pub const RxDescriptor = packed struct(u128) {
    buffer_addr: u64,
    length: u16,
    checksum: u16,
    status: u8,
    errors: u8,
    special: u16,
};
```

### Initialization Sequence

1. Reset device (CTRL.RST)
2. Read MAC address from EEPROM
3. Set MAC in RAL/RAH
4. Allocate and configure RX/TX descriptor rings
5. Enable interrupts (IMS)
6. Enable RX/TX (RCTL.EN, TCTL.EN)

### Zero-Copy Pattern

```zig
pub const PacketBuffer = struct {
    data: [*]u8,      // Pointer, not owned copy
    len: u16,
    offset: u16,      // For layer stripping
};

// Each layer advances offset, no data copy
fn parseEthernet(buf: *PacketBuffer) !EthernetFrame {
    const header = @as(*const EthernetHeader, @ptrCast(buf.data + buf.offset)).*;
    buf.offset += 14;
    return .{ .header = header, .payload = buf };
}
```

### Constitution Compliance

| Principle | Requirement | Implementation |
|-----------|-------------|----------------|
| VI. Strict Layering | Driver in HAL, stack above | `hal/e1000.zig`, `net/ethernet.zig` |
| VII. Zero-Copy | Pointers over copies | `PacketBuffer` with offset advancement |

### Key Resources

- [Intel 8254x - OSDev Wiki](https://wiki.osdev.org/Intel_8254x)
- [MIT 6.828 Lab: Network Driver](https://pdos.csail.mit.edu/6.828/2019/labs/e1000.html)
- [PCI - OSDev Wiki](https://wiki.osdev.org/PCI)

---

## 4. Network Protocol Stack

### Decision: Minimal Stack (Ethernet → ARP → IPv4 → ICMP/UDP)

**Rationale**: Sufficient for ping reply (MVP goal) and basic UDP messaging.

**Alternatives Considered**:
- TCP: Complex state machine - deferred to post-MVP
- IPv6: Additional complexity - not required for MVP

### Protocol Header Structures

```zig
pub const EthernetHeader = packed struct(u112) {
    dest_mac: u48,
    src_mac: u48,
    ether_type: u16,  // 0x0800=IPv4, 0x0806=ARP
};

pub const ARPPacket = packed struct(u224) {
    hardware_type: u16,   // 1=Ethernet
    protocol_type: u16,   // 0x0800=IPv4
    hw_addr_len: u8,      // 6
    proto_addr_len: u8,   // 4
    operation: u16,       // 1=request, 2=reply
    src_mac: u48,
    src_ip: u32,
    dest_mac: u48,
    dest_ip: u32,
};

pub const IPv4Header = packed struct(u160) {
    version_ihl: u8,
    dscp_ecn: u8,
    total_length: u16,
    identification: u16,
    flags_frag: u16,
    ttl: u8,
    protocol: u8,         // 1=ICMP, 17=UDP
    checksum: u16,
    src_ip: u32,
    dest_ip: u32,
};

pub const ICMPHeader = packed struct(u64) {
    type: u8,             // 8=request, 0=reply
    code: u8,
    checksum: u16,
    id: u16,
    sequence: u16,
};

pub const UDPHeader = packed struct(u64) {
    src_port: u16,
    dest_port: u16,
    length: u16,
    checksum: u16,
};
```

### ARP Cache Design

```zig
pub const ARPCache = struct {
    entries: [256]ARPEntry,
    count: u16,

    pub fn lookup(self: *ARPCache, ip: u32) ?u48 { ... }
    pub fn add(self: *ARPCache, ip: u32, mac: u48) void { ... }
};
```

### Byte Order Helpers

```zig
pub fn htons(value: u16) u16 { return @byteSwap(value); }
pub fn ntohs(value: u16) u16 { return @byteSwap(value); }
pub fn htonl(value: u32) u32 { return @byteSwap(value); }
pub fn ntohl(value: u32) u32 { return @byteSwap(value); }
```

---

## 5. Userland and Syscalls

### Decision: SYSCALL/SYSRET with Round-Robin Scheduler

**Rationale**: SYSCALL is faster than INT 0x80. Round-robin is simple and fair for MVP.

**Alternatives Considered**:
- INT 0x80: Slower, more compatible - not needed for single-arch kernel
- Priority scheduler: More complex - deferred to post-MVP
- CFS: Linux-style fair scheduler - overkill for MVP

### MSR Configuration

| MSR | Address | Value |
|-----|---------|-------|
| IA32_EFER | 0xC0000080 | SCE=1 (bit 0) |
| IA32_STAR | 0xC0000081 | [63:48]=User CS, [47:32]=Kernel CS |
| IA32_LSTAR | 0xC0000082 | Address of syscall_entry |
| IA32_FMASK | 0xC0000084 | 0x200 (clear IF) |

### Syscall Register Convention

| Register | Purpose |
|----------|---------|
| RAX | Syscall number |
| RDI | Argument 0 |
| RSI | Argument 1 |
| RDX | Argument 2 |
| R10 | Argument 3 |
| R8 | Argument 4 |
| R9 | Argument 5 |
| RCX | Return address (saved by CPU) |
| R11 | Saved RFLAGS (saved by CPU) |
| RAX | Return value |

### Thread Structure

```zig
pub const Thread = struct {
    tid: u32,
    state: enum { ready, running, blocked, zombie },
    registers: *SavedRegisters,
    kernel_stack_base: u64,
    kernel_stack_ptr: u64,
    user_stack_base: u64,
    user_stack_ptr: u64,
    page_table_root: u64,
    time_slice: u32,
    next: ?*Thread,
    prev: ?*Thread,
};
```

### Jump to Ring 3 (IRETQ)

```zig
// Stack frame for IRETQ:
// [RSP+0]  SS
// [RSP+8]  RSP (user)
// [RSP+16] RFLAGS
// [RSP+24] CS
// [RSP+32] RIP (entry point)
```

### ELF Loading (Minimal)

1. Validate ELF magic (0x7F, 'E', 'L', 'F')
2. Check e_machine == EM_X86_64 (62)
3. Iterate PT_LOAD segments
4. Map pages and copy segment data
5. Zero BSS (p_memsz > p_filesz)
6. Return e_entry

### Constitution Compliance

| Principle | Requirement | Implementation |
|-----------|-------------|----------------|
| VI. Strict Layering | User cannot access hardware | Ring 3 CPL enforced |
| VIII. Capability-Based | Syscall validation | Validate all pointers, check capabilities |

### Key Resources

- [SYSCALL - Felix Cloutier](https://www.felixcloutier.com/x86/syscall)
- [Getting to Ring 3 - OSDev Wiki](https://wiki.osdev.org/Getting_to_Ring_3)
- [Context Switching - OSDev Wiki](https://wiki.osdev.org/Context_Switching)

---

## 6. Scheduler Design

### Decision: Timer-Driven Preemptive Round-Robin

**Rationale**: Simple, fair, sufficient for two threads (network worker + shell).

### Timer Configuration

- PIT Channel 0 at 100Hz (10ms tick)
- Timer interrupt triggers scheduler
- Each thread gets 10ms quantum

### Scheduler Algorithm

```
schedule():
    1. Dequeue next thread from ready queue
    2. Save current thread context
    3. If current thread was running, set to ready and re-enqueue
    4. Switch page tables if different
    5. Update TSS.rsp0 to new thread's kernel stack
    6. Restore new thread context
    7. Return (resumes new thread)
```

### Blocked Thread Handling

- Threads waiting for I/O move to blocked state
- Not in ready queue (skipped by scheduler)
- Interrupt handler moves back to ready when I/O completes

---

## 7. Keyboard Input

### Decision: PS/2 Keyboard via IRQ1

**Rationale**: PS/2 is standard in QEMU, simple to implement.

### Scancode Handling

1. IRQ1 fires on keypress
2. Read scancode from port 0x60
3. Translate to ASCII (using scancode table)
4. Buffer character for shell
5. Wake shell thread if blocked on input

---

## 8. Architecture Summary

### Source Code Layout

```text
src/
├── main.zig                 # Entry point, Limine requests
├── hal/                     # Hardware Abstraction Layer
│   ├── x86_64/
│   │   ├── gdt.zig         # GDT/TSS structures
│   │   ├── idt.zig         # IDT/gates
│   │   ├── pic.zig         # 8259 PIC
│   │   ├── pit.zig         # Timer
│   │   ├── port_io.zig     # inb/outb
│   │   ├── cpu.zig         # Control registers, MSRs
│   │   └── pci.zig         # PCI enumeration
│   └── hal.zig             # Unified HAL interface
├── mem/                     # Memory Management
│   ├── pmm.zig             # Physical memory manager
│   ├── vmm.zig             # Virtual memory manager
│   └── heap.zig            # Kernel heap
├── drivers/                 # Device Drivers
│   ├── e1000.zig           # Network driver
│   ├── keyboard.zig        # PS/2 keyboard
│   └── serial.zig          # COM1 debug output
├── net/                     # Network Stack
│   ├── ethernet.zig        # Ethernet parsing
│   ├── arp.zig             # ARP cache and handling
│   ├── ipv4.zig            # IPv4 parsing
│   ├── icmp.zig            # ICMP echo handling
│   └── udp.zig             # UDP handling
├── proc/                    # Process Management
│   ├── thread.zig          # Thread structure
│   ├── scheduler.zig       # Round-robin scheduler
│   ├── syscall.zig         # Syscall handler
│   └── elf.zig             # ELF loader
└── shell/                   # Userland Shell
    └── shell.zig           # Simple command shell
```

### Build Order (Dependency Chain)

1. **Memory Management** (PMM → VMM → Heap)
2. **Interrupts** (GDT → IDT → PIC → Timer)
3. **Scheduler** (Thread → Scheduler → Syscalls)
4. **Networking** (PCI → E1000 → Ethernet → ARP → IPv4 → ICMP/UDP)
5. **Userland** (ELF Loader → Shell)

---

## 9. Open Questions Resolved

| Question | Resolution |
|----------|------------|
| APIC vs PIC? | PIC for MVP (simpler), APIC deferred |
| Heap allocator type? | Free-list with tracking (Principle IX) |
| Syscall mechanism? | SYSCALL/SYSRET (faster than INT 0x80) |
| Network driver mode? | Legacy descriptors (simpler) |
| TCP support? | Deferred to post-MVP |
| SMP support? | Deferred to post-MVP |

---

## 10. InitRD (Initial Ramdisk) via Limine Modules

### Decision: TAR Archive Abstraction over Limine Modules

**Rationale**: Limine already supports module loading, providing a pointer to the file in memory. TAR is a simple, sequential format with 512-byte headers that requires minimal parsing. No need for a complex filesystem driver.

**Alternatives Considered**:
- Flat file (single file): Too limiting for games with multiple assets
- Custom format: Extra specification work with no benefit
- FAT filesystem: Overkill for read-only ramdisk

### Limine Module Request

```zig
pub export var module_request: limine.ModuleRequest = .{};

pub fn getInitrd() ?[]const u8 {
    const response = module_request.response orelse return null;
    if (response.module_count == 0) return null;
    const module = response.modules[0];
    return @as([*]const u8, @ptrFromInt(module.address))[0..module.size];
}
```

### TAR (USTAR) Header Structure

```zig
pub const TarHeader = packed struct {
    name: [100]u8,        // File name (null-terminated)
    mode: [8]u8,          // File mode (octal ASCII)
    uid: [8]u8,           // Owner UID (octal ASCII)
    gid: [8]u8,           // Owner GID (octal ASCII)
    size: [12]u8,         // File size in bytes (octal ASCII)
    mtime: [12]u8,        // Modification time (octal ASCII)
    checksum: [8]u8,      // Header checksum
    typeflag: u8,         // '0' = regular file, '5' = directory
    linkname: [100]u8,    // Link target (if symlink)
    magic: [6]u8,         // "ustar\0"
    version: [2]u8,       // "00"
    uname: [32]u8,        // Owner username
    gname: [32]u8,        // Owner group name
    devmajor: [8]u8,      // Device major (if device)
    devminor: [8]u8,      // Device minor (if device)
    prefix: [155]u8,      // Prefix for long filenames
    _pad: [12]u8,         // Padding to 512 bytes

    pub fn getSize(self: *const @This()) usize {
        // Parse octal ASCII size field
        var size: usize = 0;
        for (self.size) |c| {
            if (c == ' ' or c == 0) break;
            size = size * 8 + (c - '0');
        }
        return size;
    }

    pub fn getName(self: *const @This()) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        return self.name[0..end];
    }
};
```

### InitRD File Lookup

```zig
pub const InitRD = struct {
    data: []const u8,

    pub fn findFile(self: *const @This(), path: []const u8) ?File {
        var offset: usize = 0;
        while (offset + 512 <= self.data.len) {
            const header = @as(*const TarHeader, @ptrCast(self.data.ptr + offset));

            // Check for end of archive (empty name)
            if (header.name[0] == 0) break;

            const name = header.getName();
            const size = header.getSize();

            if (std.mem.eql(u8, name, path)) {
                return File{
                    .data = self.data[offset + 512 .. offset + 512 + size],
                    .size = size,
                };
            }

            // Skip to next header (round up to 512-byte boundary)
            offset += 512 + ((size + 511) & ~@as(usize, 511));
        }
        return null;
    }
};
```

---

## 11. Minimal libc for Doom Integration

### Decision: Zig-Implemented libc Subset with C-Compatible Exports

**Rationale**: doomgeneric is C code that requires standard libc functions. Instead of porting a full libc, implement only the functions Doom actually calls, using Zig and wrapping syscalls.

**Required Functions** (from doomgeneric analysis):

| Function | Category | Implementation |
|----------|----------|----------------|
| `malloc(size)` | Memory | Wrapper around `sbrk` |
| `free(ptr)` | Memory | Free-list deallocation |
| `realloc(ptr, size)` | Memory | malloc + memcpy + free |
| `memcpy(dst, src, n)` | Memory | Zig `@memcpy` |
| `memset(dst, c, n)` | Memory | Zig `@memset` |
| `memmove(dst, src, n)` | Memory | Zig `@memmove` |
| `strlen(s)` | String | Iterate until null |
| `strcpy(dst, src)` | String | Copy until null |
| `strcmp(s1, s2)` | String | Byte comparison |
| `printf(fmt, ...)` | I/O | Format + `write` syscall |
| `sprintf(buf, fmt, ...)` | I/O | Format to buffer |
| `fopen(path, mode)` | File | `open` syscall wrapper |
| `fread(buf, size, n, f)` | File | `read` syscall wrapper |
| `fseek(f, off, whence)` | File | `seek` syscall wrapper |
| `fclose(f)` | File | `close` syscall wrapper |
| `exit(code)` | Control | `exit` syscall |

### C Export Pattern in Zig

```zig
// src/user/lib/libc.zig
export fn malloc(size: usize) ?*anyopaque {
    return heap.alloc(size);
}

export fn free(ptr: ?*anyopaque) void {
    if (ptr) |p| heap.free(p);
}

export fn memcpy(dst: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    @memcpy(dst[0..n], src[0..n]);
    return dst;
}

export fn printf(fmt: [*:0]const u8, ...) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    const buf = formatToBuffer(fmt, ap);
    return @intCast(syscall.write(1, buf.ptr, buf.len));
}
```

### doomgeneric Integration

doomgeneric provides hooks that the OS fills in:

```c
// These must be implemented by the OS
void DG_Init();
void DG_DrawFrame();
void DG_SleepMs(uint32_t ms);
uint32_t DG_GetTicksMs();
int DG_GetKey(int* pressed, unsigned char* key);
void DG_SetWindowTitle(const char* title);
```

Zig implementations will use syscalls:
- `DG_DrawFrame`: Write to framebuffer via `mmap`-ed address
- `DG_SleepMs`: `sleep` syscall
- `DG_GetTicksMs`: `get_time` syscall
- `DG_GetKey`: `read_scancode` syscall

---

## 12. Extended Syscall Table

### Updated Syscall Numbers

| Number | Name | Description | Arguments |
|--------|------|-------------|-----------|
| 0 | SYS_EXIT | Terminate process | rdi: exit_code |
| 1 | SYS_WRITE | Write to fd | rdi: fd, rsi: buf, rdx: len |
| 2 | SYS_READ_CHAR | Read ASCII char | → rax: char |
| 3 | SYS_YIELD | Yield timeslice | - |
| 4 | SYS_GETPID | Get thread ID | → rax: tid |
| 5 | SYS_SLEEP | Sleep ms | rdi: ms |
| 6 | SYS_SEND_UDP | Send UDP | rdi: dest_ip, rsi: port, rdx: buf, r10: len |
| 7 | SYS_RECV_UDP | Recv UDP | rdi: buf, rsi: len → rax: actual_len |
| 8 | SYS_GET_TIME | Get ticks | → rax: ticks |
| 9 | SYS_READ_SCANCODE | Read raw scancode | → rax: scancode or -EAGAIN |
| 10 | SYS_GET_FB_INFO | Get framebuffer info | → struct in buf |
| 11 | SYS_MAP_FB | Map framebuffer | → rax: address |
| 12 | SYS_MMAP | Map memory | rdi: addr, rsi: len, rdx: prot, r10: flags |
| 13 | SYS_OPEN | Open file | rdi: path, rsi: flags → rax: fd |
| 14 | SYS_CLOSE | Close file | rdi: fd → rax: result |
| 15 | SYS_READ | Read from file | rdi: fd, rsi: buf, rdx: count → rax: bytes |
| 16 | SYS_SEEK | Seek in file | rdi: fd, rsi: offset, rdx: whence → rax: pos |
| 17 | SYS_SBRK | Expand heap | rdi: increment → rax: old_break |

### File Descriptor Table (per-process)

```zig
pub const FileDescriptor = struct {
    initrd_file: ?*const InitRD.File,
    position: usize,
    flags: u32,
};

pub const Process = struct {
    // ...
    fds: [16]?FileDescriptor,  // Max 16 open files per process
    next_fd: u32,
    heap_break: usize,         // Current program break for sbrk
    // ...
};
```

### SYS_SBRK Implementation

```zig
fn sysSbrk(increment: isize) !usize {
    const proc = scheduler.currentProcess();
    const old_break = proc.heap_break;

    if (increment == 0) return old_break;

    const new_break = if (increment > 0)
        old_break + @as(usize, @intCast(increment))
    else
        old_break - @as(usize, @intCast(-increment));

    // Validate new break doesn't exceed limits
    if (new_break > proc.heap_limit) return error.OutOfMemory;

    // Allocate/deallocate pages as needed
    const old_pages = (old_break + 4095) / 4096;
    const new_pages = (new_break + 4095) / 4096;

    if (new_pages > old_pages) {
        // Map new pages
        for (old_pages..new_pages) |page| {
            const phys = pmm.allocPage() orelse return error.OutOfMemory;
            // SECURITY: Zero-fill page before mapping to userland to prevent info leaks
            const virt_ptr = physToVirt(phys);
            @memset(virt_ptr[0..4096], 0);
            vmm.mapPage(proc.page_table, page * 4096, phys, .user_rw);
        }
    }

    proc.heap_break = new_break;
    return old_break;
}
```

---

## 13. Framebuffer Mapping for Games

### Decision: Map Physical Framebuffer into Userspace Address Space

**Rationale**: Games need 60fps rendering. Syscall-per-pixel is impossibly slow (~millions of syscalls per frame). Direct mapping allows bulk writes at memory bandwidth speeds.

### Implementation

```zig
fn sysMapFramebuffer() !usize {
    const proc = scheduler.currentProcess();
    const fb = limine.framebuffer_request.response.?.framebuffers[0];

    const fb_phys = @intFromPtr(fb.address) - hhdm_offset;
    const fb_size = fb.pitch * fb.height;
    const fb_pages = (fb_size + 4095) / 4096;

    // Find free virtual address range in userspace
    const user_vaddr = proc.findFreeVirtualRange(fb_pages) orelse
        return error.NoVirtualSpace;

    // Map framebuffer pages as user-writable, write-combining
    for (0..fb_pages) |i| {
        vmm.mapPage(
            proc.page_table,
            user_vaddr + i * 4096,
            fb_phys + i * 4096,
            .{ .user = true, .writable = true, .write_combining = true }
        );
    }

    return user_vaddr;
}
```

### Framebuffer Info Structure

```zig
pub const FramebufferInfo = extern struct {
    address: u64,     // Userspace virtual address (after mapping)
    width: u32,
    height: u32,
    pitch: u32,       // Bytes per row
    bpp: u16,         // Bits per pixel
    red_shift: u8,
    green_shift: u8,
    blue_shift: u8,
    _reserved: u8,
};
```

---

## 14. Heap Coalescing for Fragmentation Prevention

### Decision: Immediate Coalescing on Free with Boundary Tags

**Rationale**: Games like Doom perform many allocations and frees during gameplay. Without coalescing, the heap fragments into small unusable blocks. Boundary tags enable O(1) coalescing by storing block size at both ends.

### Block Header/Footer Structure

```zig
pub const BlockHeader = packed struct {
    size: u63,       // Block size including header/footer
    is_free: u1,     // 0 = allocated, 1 = free
};

pub const BlockFooter = packed struct {
    size: u63,       // Same size as header (for backward lookup)
    is_free: u1,     // Same flag
};
```

### Coalescing Algorithm

```zig
pub fn free(ptr: *anyopaque) void {
    const header = getHeader(ptr);
    header.is_free = 1;

    // Coalesce with next block if free
    const next_header = getNextHeader(header);
    if (next_header != null and next_header.is_free) {
        header.size += next_header.size;
        // Update footer to new combined size
        setFooter(header);
        // Remove next block from free list
        removeFromFreeList(next_header);
    }

    // Coalesce with previous block if free
    const prev_footer = getPrevFooter(header);
    if (prev_footer != null and prev_footer.is_free) {
        const prev_header = getHeaderFromFooter(prev_footer);
        prev_header.size += header.size;
        setFooter(prev_header);
        // header is now absorbed, don't add to free list
        return;
    }

    // Add this block to free list
    addToFreeList(header);
}
```

### Why Coalescing is Critical

Without coalescing:
1. Allocate 1KB 1000 times → Uses 1MB
2. Free all 1000 blocks → 1000 × 1KB free blocks
3. Try to allocate 512KB → FAILS (largest free block is 1KB)

With coalescing:
1. Allocate 1KB 1000 times → Uses 1MB
2. Free all 1000 blocks → Coalesce into one 1MB block
3. Try to allocate 512KB → SUCCEEDS

### Constitution Compliance

| Principle | Requirement | Implementation |
|-----------|-------------|----------------|
| IX. Heap Hygiene | Prevent fragmentation | Immediate coalescing on free |

---

## 15. Raw Keyboard Scancode Handling for Games

### Decision: Dual Buffers (ASCII + Scancode) with Ring Buffer

**Rationale**: The shell needs ASCII characters; games need raw scancodes for key up/down detection and non-ASCII keys (arrows, function keys). Running both buffers in parallel satisfies both use cases.

### PS/2 Scancode Sets

QEMU uses Scancode Set 1 (XT) by default:

| Key | Make Code | Break Code |
|-----|-----------|------------|
| ESC | 0x01 | 0x81 |
| W | 0x11 | 0x91 |
| A | 0x1E | 0x9E |
| S | 0x1F | 0x9F |
| D | 0x20 | 0xA0 |
| Space | 0x39 | 0xB9 |
| Up Arrow | 0xE0 0x48 | 0xE0 0xC8 |
| Down Arrow | 0xE0 0x50 | 0xE0 0xD0 |
| Left Arrow | 0xE0 0x4B | 0xE0 0xCB |
| Right Arrow | 0xE0 0x4D | 0xE0 0xCD |

### Keyboard IRQ Handler

```zig
var ascii_buffer: RingBuffer(u8, 256) = .{};
var scancode_buffer: RingBuffer(u8, 64) = .{};
var extended_mode: bool = false;

pub fn keyboardIrq() void {
    const scancode = port_io.inb(0x60);

    // Always buffer scancode for games
    scancode_buffer.push(scancode) catch {};

    // Handle extended scancode prefix
    if (scancode == 0xE0) {
        extended_mode = true;
        return;
    }

    const is_release = (scancode & 0x80) != 0;
    const key = scancode & 0x7F;

    // Only buffer ASCII on key press (not release)
    if (!is_release) {
        if (translateToAscii(key, extended_mode)) |ascii| {
            ascii_buffer.push(ascii) catch {};
        }
    }

    extended_mode = false;
}
```

### Key State Tracking for Games

Games often need to know which keys are currently held:

```zig
var key_states: [256]bool = [_]bool{false} ** 256;

pub fn isKeyDown(scancode: u8) bool {
    return key_states[scancode];
}

// In IRQ handler:
if (is_release) {
    key_states[key] = false;
} else {
    key_states[key] = true;
}
```

---

## 16. References

### OSDev Wiki
- [Paging](https://wiki.osdev.org/Paging)
- [Interrupt Descriptor Table](https://wiki.osdev.org/Interrupt_Descriptor_Table)
- [8259 PIC](https://wiki.osdev.org/8259_PIC)
- [Intel 8254x](https://wiki.osdev.org/Intel_8254x)
- [Getting to Ring 3](https://wiki.osdev.org/Getting_to_Ring_3)
- [Context Switching](https://wiki.osdev.org/Context_Switching)

### Intel Documentation
- [SYSCALL Instruction](https://www.felixcloutier.com/x86/syscall)
- [SYSRET Instruction](https://www.felixcloutier.com/x86/sysret)

### MIT 6.828
- [Lab: Network Driver](https://pdos.csail.mit.edu/6.828/2019/labs/e1000.html)

### Zig Resources
- [Zig Bare Bones - OSDev Wiki](https://wiki.osdev.org/Zig_Bare_Bones)
- [Packed Structs - zig.guide](https://zig.guide/working-with-c/packed-structs/)
