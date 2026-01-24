#!/usr/bin/env python3
"""
Memory Layout Query Tool for zk kernel.

Query virtual memory map, HHDM, hardware structures (GDT, IDT, PTE).

Usage:
    python memory_query.py virt          # Virtual memory map
    python memory_query.py hhdm          # HHDM translation
    python memory_query.py aslr          # ASLR configuration
    python memory_query.py gdt           # GDT entry format (8 bytes)
    python memory_query.py idt           # IDT entry format (16 bytes)
    python memory_query.py tss           # TSS structure (104 bytes)
    python memory_query.py pte           # Page table entry format
    python memory_query.py fault         # Page fault error codes
    python memory_query.py limine        # Limine boot mappings
    python memory_query.py addr          # Key addresses quick ref
    python memory_query.py vector        # Interrupt vector map
"""

import sys

PATTERNS = {
    "virt": """
## Virtual Memory Map

```text
0xFFFF_FFFF_FFFF_FFFF  --- Top of Memory
                        |
                        |  Kernel Image (Text/Data/BSS)
                        |  Mapped from ELF at link time
0xFFFF_FFFF_8000_0000  --- Kernel Base (2 GB window)
                        |
                        |  (Gap)
                        |
0xFFFF_A000_0000_0000  --- Kernel Stacks Region
                        |  Per-CPU stacks with guard pages
                        |
0xFFFF_8000_0000_0000  --- HHDM Base (Higher Half Direct Map)
                        |  Maps all physical RAM linearly
                        |  Phys 0x0 -> Virt 0xFFFF_8000_0000_0000
                        |
0x0000_7FFF_FFFF_FFFF  --- User Space Top (Canonical Hole)
                        |
0x0000_7FFF_E000_0000  --- VDSO / VVAR Base (ASLR +/- 256MB)
                        |
0x0000_7FFF_FFFF_F000  --- User Stack Top Base (ASLR -8MB)
                        |
0x0000_5555_5000_0000  --- PIE Load Base (ASLR +4GB)
                        |
0x0000_1000_0000_0000  --- User mmap Base (ASLR +4TB)
                        |
0x0000_0000_0040_0000  --- User Space Bottom
                        |
0x0000_0000_0000_0000  --- NULL
```
""",

    "addr": """
## Key Addresses

| Region | Base Address | Notes |
|--------|--------------|-------|
| Kernel | 0xFFFF_FFFF_8000_0000 | 2GB window, higher half |
| HHDM | 0xFFFF_8000_0000_0000 | Physical memory direct map |
| Kernel stacks | 0xFFFF_A000_0000_0000 | Guard pages between |
| User space top | 0x0000_7FFF_FFFF_FFFF | End of canonical lower half |
| User space bottom | 0x0000_0000_0040_0000 | First valid user address |
""",

    "hhdm": """
## HHDM (Higher Half Direct Map)

Physical memory is mapped linearly starting at HHDM base.

### Constants
```zig
const HHDM_BASE: u64 = 0xFFFF_8000_0000_0000;
```

### Translation Functions
```zig
// Physical to virtual (kernel access to physical memory)
pub fn physToVirt(phys: u64) [*]u8 {
    return @ptrFromInt(phys + 0xFFFF_8000_0000_0000);
}

// Virtual to physical
pub fn virtToPhys(virt: u64) u64 {
    return virt - 0xFFFF_8000_0000_0000;
}
```

### Usage
- Kernel accesses physical pages via HHDM
- Page tables store physical addresses
- DMA operations use physical addresses
""",

    "aslr": """
## ASLR Configuration

Location: src/kernel/mm/aslr.zig

| Component | Base Address | Entropy | Granularity | Max Offset |
|-----------|--------------|---------|-------------|------------|
| Stack top | 0x7FFF_FFFF_F000 | 22 bits | 4KB (page) | 16GB down |
| PIE base | 0x5555_5000_0000 | 16 bits | 64KB | 4GB up |
| mmap base | 0x1000_0000_0000 | 20 bits | 4KB (page) | 4TB up |
| Heap gap | After ELF end | 16 bits | 4KB (page) | 256MB up |
| TLS base | 0xB000_0000 | 16 bits | 4KB (page) | 256MB up |
| VDSO | 0x7FFF_E000_0000 | 16 bits | 4KB (page) | 256MB down |

### AslrOffsets Structure
```zig
pub const AslrOffsets = struct {
    stack_offset: u16,    // Subtracted from stack base (22 bits entropy)
    pie_offset: u16,      // Added to PIE base (64KB units)
    mmap_offset: u32,     // Added to mmap base (pages)
    heap_gap: u16,        // Gap after ELF (16 bits entropy)
    tls_offset: u16,      // TLS offset (16 bits entropy)
    stack_top: u64,       // Computed stack top
    mmap_start: u64,      // Computed mmap start
    tls_base: u64,        // Computed TLS base
};
```

### Entropy Constants
```zig
pub const STACK_ENTROPY_BITS: u5 = 22;   // 4M pages = 16GB range
pub const PIE_ENTROPY_BITS: u5 = 16;     // 64KB units = 4GB range
pub const MMAP_ENTROPY_BITS: u5 = 20;    // 1M pages = 4TB range
pub const HEAP_ENTROPY_BITS: u5 = 16;    // 64K pages = 256MB range
pub const TLS_ENTROPY_BITS: u5 = 16;     // 64K pages = 256MB range
```
""",

    "gdt": """
## GDT Entry Format (8 bytes)

```text
63                               48 47       40 39       32
+---------------+-+-+-+------------+-----------+-----------+
|  Base 31:24   |G|D|L| AVL/LimHi  | P DPL S T | Base 23:16|
+---------------+-+-+-+------------+-----------+-----------+
31                               16 15                    0
+----------------------------------+-----------------------+
|           Base 15:0              |       Limit 15:0      |
+----------------------------------+-----------------------+
```

### Flags
- P: Present (1)
- DPL: Privilege Level (0=Kernel, 3=User)
- S: Descriptor type (1=code/data, 0=system)
- L: Long Mode (1 for 64-bit code)
- G: Granularity (1=4KB pages)
- D: Default operand size

### Standard Selectors
| Selector | Ring | Type |
|----------|------|------|
| 0x08 | 0 | Kernel Code |
| 0x10 | 0 | Kernel Data |
| 0x18 | 3 | User Code |
| 0x20 | 3 | User Data |
| 0x28 | 0 | TSS (16-byte entry!) |

**Critical:** CS cannot be loaded directly after GDT switch. Must use far jump.
""",

    "idt": """
## IDT Gate Entry (16 bytes in 64-bit mode!)

```text
127                                                          96
+-------------------------------------------------------------+
|                        Reserved (0)                         |
+-------------------------------------------------------------+
95                                                           64
+-------------------------------------------------------------+
|                      Offset 63:32                           |
+-------------------------------------------------------------+
63               48 47 46  44 43    40 39  37 36  35  32 31  16
+------------------+-+-----+----------+------+---+------+-----+
|   Offset 31:16   |P| DPL |0 1 1 1 0 |0 0 0 |IST| Rsvd | Sel |
+------------------+-+-----+----------+------+---+------+-----+
15                                                            0
+-------------------------------------------------------------+
|                        Offset 15:0                          |
+-------------------------------------------------------------+
```

### Fields
- P: Present (1)
- DPL: Descriptor Privilege Level
- IST: Interrupt Stack Table Index (1-7, 0=None)
- Sel: Code Segment Selector (typically 0x08)
- Type: 0xE = 64-bit Interrupt Gate, 0xF = 64-bit Trap Gate

### IDT Entry in Zig
```zig
const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u3,
    reserved0: u5 = 0,
    gate_type: u4,
    zero: u1 = 0,
    dpl: u2,
    present: u1,
    offset_mid: u16,
    offset_high: u32,
    reserved1: u32 = 0,
};
```
""",

    "tss": """
## TSS Structure (104 bytes)

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0x00 | 4 | Reserved | Must be 0 |
| 0x04 | 8 | RSP0 | Ring 0 stack pointer |
| 0x0C | 8 | RSP1 | Ring 1 stack (unused) |
| 0x14 | 8 | RSP2 | Ring 2 stack (unused) |
| 0x1C | 8 | Reserved | Must be 0 |
| 0x24 | 8 | IST1 | Interrupt Stack 1 |
| 0x2C | 8 | IST2 | Interrupt Stack 2 |
| 0x34 | 8 | IST3 | Interrupt Stack 3 |
| 0x3C | 8 | IST4 | Interrupt Stack 4 |
| 0x44 | 8 | IST5 | Interrupt Stack 5 |
| 0x4C | 8 | IST6 | Interrupt Stack 6 |
| 0x54 | 8 | IST7 | Interrupt Stack 7 |
| 0x5C | 8 | Reserved | Must be 0 |
| 0x64 | 2 | Reserved | Must be 0 |
| 0x66 | 2 | IOPB | I/O Permission Bitmap offset (104 to disable) |

### TSS in Zig
```zig
const TSS = extern struct {
    reserved0: u32 = 0,
    rsp0: u64,           // Kernel stack for Ring 0
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist: [7]u64 = .{0} ** 7,  // Interrupt stacks
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iopb: u16 = 104,     // Disable I/O bitmap
};
```
""",

    "pte": """
## Page Table Entry (8 bytes) - x86_64

```text
63  62     52 51                                       12 11 9 8 7 6 5 4 3 2 1 0
+--+---------+-------------------------------------------+----+-+-+-+-+-+-+-+-+-+
|XD| Available|          Physical Address [51:12]        |Avail|G|S|D|A|C|W|U|W|P|
+--+---------+-------------------------------------------+----+-+-+-+-+-+-+-+-+-+
```

### Bits
| Bit | Name | Meaning |
|-----|------|---------|
| 0 | P | Present |
| 1 | W | Writable |
| 2 | U | User Accessible |
| 3 | PWT | Page Write-Through |
| 4 | PCD | Page Cache Disable |
| 5 | A | Accessed |
| 6 | D | Dirty |
| 7 | S | Page Size (1 = Huge: 2MB for PD, 1GB for PDPT) |
| 8 | G | Global |
| 63 | XD | Execute Disable (NX bit) |

### Common Flag Combinations
```zig
const PRESENT: u64 = 1 << 0;
const WRITABLE: u64 = 1 << 1;
const USER: u64 = 1 << 2;
const HUGE_PAGE: u64 = 1 << 7;
const NO_EXECUTE: u64 = 1 << 63;

// Kernel code: present, not writable, no user, exec
const KERNEL_CODE = PRESENT;

// Kernel data: present, writable, no user, no exec
const KERNEL_DATA = PRESENT | WRITABLE | NO_EXECUTE;

// User code: present, not writable, user, exec
const USER_CODE = PRESENT | USER;

// User data: present, writable, user, no exec
const USER_DATA = PRESENT | WRITABLE | USER | NO_EXECUTE;
```

---

## Page Table Entry (8 bytes) - AArch64

```text
63  62 61 60 59 58 57 56 55 54 53 52 51 50 49 48 47          12 11 10 9  8  7  6  5  4  3  2  1  0
+---+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+-------------+--+--+----+--+-----+--+-----+--+--+
|   |        Software       |UXN|PXN|Ct|DBM| Reserved |  Physical Address [47:12]   |nG|AF| SH |AP|NS|AttrIdx|Tbl|Val|
+---+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+-------------+--+--+----+--+-----+--+-----+--+--+
```

### Critical Bits (AArch64)
| Bits | Field | Description |
|------|-------|-------------|
| 0 | Valid | Entry is valid (1 = valid) |
| 1 | Table | For L3: must be 1 for page descriptor |
| 4:2 | AttrIndx | Index into MAIR_EL1 (0=Device, 1=Normal WB, 2=Normal NC) |
| 7:6 | AP | Access Permissions (see below) |
| 9:8 | SH | Shareability (3 = Inner Shareable) |
| 10 | AF | Access Flag - MUST be set! |
| 11 | nG | Non-Global (set for user pages) |
| 53 | PXN | Privileged Execute Never |
| 54 | UXN | User Execute Never (CRITICAL for user code!) |
| 63:55 | Software | Software-defined bits |

### Access Permission (AP) - AArch64
| AP[1:0] | EL1 (Kernel) | EL0 (User) |
|---------|--------------|------------|
| 0b00 | Read/Write | No access |
| 0b01 | Read/Write | Read/Write |
| 0b10 | Read-only | No access |
| 0b11 | Read-only | Read-only |

### Common Bug: UXN Bit
If user process gets Instruction Abort, check bit 54 (UXN).
UXN=1 blocks user execution! Must be 0 for executable user pages.
```zig
// WRONG: Sets UXN when making user page
entry.uxn = flags.user;  // Bug! UXN blocks execution

// CORRECT: Only set UXN for non-executable pages
entry.uxn = flags.no_execute;
```
""",

    "fault": """
## Page Fault Error Code

CR2 contains the faulting virtual address.

| Bit | Name | Meaning when SET |
|-----|------|------------------|
| 0 | P | Page was present (protection violation) |
| 1 | W | Write access caused fault |
| 2 | U | Fault occurred in user mode (CPL=3) |
| 3 | RSVD | Reserved bit was set in PTE |
| 4 | I/D | Instruction fetch (NX violation) |
| 5 | PK | Protection key violation |
| 6 | SS | Shadow stack access |
| 15 | SGX | SGX-related fault |

### Common Fault Types
```zig
// Demand paging: not-present + user mode
if ((error_code & 0x1) == 0 and (error_code & 0x4) != 0) {
    // Allocate page, map it, return
}

// Copy-on-write: present + write + user
if ((error_code & 0x7) == 0x7) {
    // Copy page, remap writable, return
}

// Invalid access: present + user + protection violation
if ((error_code & 0x5) == 0x5) {
    // Send SIGSEGV
}
```

### Handler Pattern
```zig
fn handlePageFault(cr2: u64, error_code: u64) void {
    const present = (error_code & 1) != 0;
    const write = (error_code & 2) != 0;
    const user = (error_code & 4) != 0;

    if (!present and user) {
        // Demand paging
    } else if (present and write and user) {
        // Copy-on-write
    } else {
        // Segfault or kernel panic
    }
}
```
""",

    "limine": """
## Limine Boot Mappings

Limine sets up three page table mappings before jumping to kernel:

### 1. Identity Mapping
- **Virtual**: 0x0 -> 0x...
- **Physical**: 0x0 -> 0x...
- **Purpose**: Early boot only
- **Status**: Discarded after kernel setup

### 2. HHDM (Higher Half Direct Map)
- **Virtual**: 0xFFFF_8000_0000_0000
- **Physical**: 0x0
- **Purpose**: Kernel physical memory access
- **Status**: Permanent

### 3. Higher-Half Kernel
- **Virtual**: 0xFFFF_FFFF_8000_0000
- **Physical**: Kernel ELF load address
- **Purpose**: Kernel code/data
- **Status**: Permanent

### Limine Protocol Access
```zig
// Get HHDM offset from Limine
const hhdm_request = limine.HhdmRequest{};
const hhdm_offset = hhdm_request.response.?.offset;

// Get memory map
const memmap_request = limine.MemmapRequest{};
const entries = memmap_request.response.?.entries();
```

### Memory Map Entry Types
```zig
pub const MemoryType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    kernel_and_modules = 6,
    framebuffer = 7,
};
```
""",

    "vector": """
## Interrupt Vector Map

### CPU Exceptions (0-31)
| Vector | Name | Type | Error Code |
|--------|------|------|------------|
| 0 | #DE | Divide Error | No |
| 1 | #DB | Debug | No |
| 2 | NMI | Non-Maskable Interrupt | No |
| 3 | #BP | Breakpoint | No |
| 4 | #OF | Overflow | No |
| 5 | #BR | Bound Range Exceeded | No |
| 6 | #UD | Invalid Opcode | No |
| 7 | #NM | Device Not Available | No |
| 8 | #DF | Double Fault | Yes (0) |
| 9 | - | Coprocessor Segment Overrun | No |
| 10 | #TS | Invalid TSS | Yes |
| 11 | #NP | Segment Not Present | Yes |
| 12 | #SS | Stack-Segment Fault | Yes |
| 13 | #GP | General Protection Fault | Yes |
| 14 | #PF | Page Fault | Yes |
| 15 | - | Reserved | - |
| 16 | #MF | x87 FPU Error | No |
| 17 | #AC | Alignment Check | Yes (0) |
| 18 | #MC | Machine Check | No |
| 19 | #XM | SIMD Floating-Point | No |
| 20 | #VE | Virtualization Exception | No |
| 21 | #CP | Control Protection | Yes |
| 22-31 | - | Reserved | - |

### IRQ Mapping (PIC/IOAPIC)
| Vector | IRQ | Device | ISA |
|--------|-----|--------|-----|
| 32 | 0 | PIT Timer | Yes |
| 33 | 1 | PS/2 Keyboard | Yes |
| 34 | 2 | Cascade (unused) | Yes |
| 35 | 3 | COM2 | Yes |
| 36 | 4 | COM1 | Yes |
| 37 | 5 | LPT2 / Sound | Yes |
| 38 | 6 | Floppy | Yes |
| 39 | 7 | LPT1 / Spurious | Yes |
| 40 | 8 | RTC | Yes |
| 41 | 9 | ACPI | Yes |
| 42 | 10 | Available | Yes |
| 43 | 11 | Available | Yes |
| 44 | 12 | PS/2 Mouse | Yes |
| 45 | 13 | Coprocessor | Yes |
| 46 | 14 | Primary IDE | Yes |
| 47 | 15 | Secondary IDE | Yes |

### Special Vectors
| Vector | Purpose |
|--------|---------|
| 128 (0x80) | Legacy Syscall (int 0x80) |
| 239 | APIC Timer |
| 240-254 | MSI-X Vectors (dynamic) |
| 255 | Spurious Interrupt |

### ZK Specifics
```zig
// Vector 128: Syscall entry (via int 0x80 or syscall instruction)
pub const SYSCALL_VECTOR: u8 = 0x80;

// APIC Timer for scheduler tick
pub const APIC_TIMER_VECTOR: u8 = 0xEF;  // 239

// Spurious interrupts (must not be masked)
pub const SPURIOUS_VECTOR: u8 = 0xFF;    // 255
```

### IRQ to Vector Calculation
```zig
// PIC remapped to 32-47
const vector = irq + 32;

// For MSI-X, vectors are dynamically allocated:
const msi_vector = hal.interrupts.allocateMsixVector();
```

### Exception Handler Signature
```zig
fn exceptionHandler(frame: *InterruptFrame, error_code: u64) void {
    const vector = frame.interrupt_number;
    const rip = frame.rip;
    const cr2 = hal.cpu.readCr2();  // Page fault address
    // ...
}
```
""",
}

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    query = sys.argv[1].lower()

    if query in PATTERNS:
        print(PATTERNS[query])
    else:
        matches = [k for k in PATTERNS.keys() if query in k]
        if matches:
            for m in matches:
                print(PATTERNS[m])
        else:
            print(f"Unknown topic: {query}")
            print(f"Available: {', '.join(PATTERNS.keys())}")
            sys.exit(1)

if __name__ == "__main__":
    main()
