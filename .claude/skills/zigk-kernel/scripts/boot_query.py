#!/usr/bin/env python3
"""
Boot Process Query Tool for zigk kernel.

Query boot flow, BootInfo structure, memory layout, and troubleshooting.

Usage:
    python boot_query.py flow          # Boot flow stages (UEFI -> kernel)
    python boot_query.py bootinfo      # BootInfo structure (144 bytes)
    python boot_query.py memory        # Memory layout (HHDM, kernel, user)
    python boot_query.py paging        # Page table setup (PML4/TTBR)
    python boot_query.py abi           # Calling convention (MS x64 vs SysV)
    python boot_query.py entry         # Kernel entry points
    python boot_query.py init          # Kernel initialization sequence
    python boot_query.py troubleshoot  # Common boot failures
    python boot_query.py aarch64       # AArch64 differences
"""

import sys

PATTERNS = {
    "flow": """
## Boot Flow Stages

### Stage 1: UEFI Firmware
- Loads EFI/BOOT/BOOTX64.EFI from EFI System Partition

### Stage 2: UEFI Bootloader (src/boot/uefi/main.zig)
1. Loads kernel.elf from filesystem
2. Loads initrd.tar if present
3. Parses ELF headers, loads PT_LOAD segments
4. Searches symbol table for _uefi_start (fallback: e_entry -> _start)
5. Initializes GOP framebuffer
6. Gets UEFI memory map -> BootInfo format
7. Locates RSDP (ACPI Root System Description Pointer)
8. Creates PML4 page tables:
   - Identity map: 0-4GB (boot transition)
   - HHDM: 0xFFFF800000000000 -> all physical memory
   - Kernel: 0xFFFFFFFF80000000 -> ELF segments
9. Calls ExitBootServices()
10. Loads new page tables (CR3)
11. Jumps to _start with BootInfo pointer (RDI)

### Stage 3: Kernel Entry (src/kernel/core/main.zig)
- Receives BootInfo* in RDI (System V AMD64 ABI)
- Validates BootInfo structure
- Initializes HAL, memory, drivers, scheduler

### Key Files
| File | Purpose |
|------|---------|
| src/boot/uefi/main.zig | Boot sequence orchestration |
| src/boot/uefi/loader.zig | ELF parsing, initrd loading |
| src/boot/uefi/memory.zig | Memory map handling |
| src/boot/uefi/graphics.zig | GOP initialization |
| src/boot/uefi/paging.zig | Page table creation |
| src/boot/common/boot_info.zig | BootInfo structure |
| src/kernel/core/main.zig | Kernel entry (_start) |

### Boot Methods
**GPT Disk Image (Recommended):**
```bash
zig build run -Drun-iso=false
```

**ISO Image (Hybrid GPT):**
```bash
zig build run -Drun-iso=true
```
""",

    "bootinfo": """
## BootInfo Structure (144 bytes)

Location: src/boot/common/boot_info.zig

```text
Offset  Size  Field                 Description
------  ----  -----                 -----------
0x00    8     memory_map            Pointer to MemoryDescriptor array
0x08    8     memory_map_count      Number of memory entries
0x10    8     descriptor_size       Size of each descriptor
0x18    8     framebuffer           Optional FramebufferInfo pointer
0x20    8     rsdp                  ACPI RSDP physical address
0x28    8     initrd_addr           InitRD address (0 if none)
0x30    8     initrd_size           InitRD size
0x38    8     cmdline               Optional command line pointer
0x40    8     hhdm_offset           HHDM base (0xFFFF800000000000)
0x48    8     kernel_phys_base      Kernel physical load address
0x50    8     kernel_virt_base      Kernel virtual base
0x58    8     stack_region_offset   KASLR: kernel stack offset
0x60    8     mmio_region_offset    KASLR: MMIO region offset
0x68    8     heap_offset           KASLR: kernel heap offset
0x70    8     dtb_addr              Device Tree (AArch64, 0 on x86_64)
0x78    8     gic_dist_base         GIC Distributor (AArch64)
0x80    8     gic_cpu_base          GIC CPU Interface (AArch64)
0x88    1     gic_version           GIC version (2 or 3)
0x89    7     _gic_padding          Alignment padding
```

Total size: 144 bytes (0x90)

### MemoryDescriptor (40 bytes)
```text
Offset  Size  Field        Description
0x00    4     type         MemoryType enum (u32)
0x04    4     (padding)    Implicit alignment
0x08    8     phys_start   Physical start address
0x10    8     virt_start   Virtual start (usually 0)
0x18    8     num_pages    Number of 4KB pages
0x20    8     attribute    Memory attributes
```

### FramebufferInfo (40 bytes)
```text
Offset  Size  Field             Description
0x00    8     address           Physical address
0x08    8     width             Pixels
0x10    8     height            Pixels
0x18    8     pitch             Bytes per row
0x20    2     bpp               Bits per pixel
0x22    1     red_mask_size
0x23    1     red_mask_shift
0x24    1     green_mask_size
0x25    1     green_mask_shift
0x26    1     blue_mask_size
0x27    1     blue_mask_shift
```

### Memory Types
| Type | Value | Usable |
|------|-------|--------|
| Conventional | 7 | Yes |
| BootServicesCode | 3 | Yes (after exit) |
| BootServicesData | 4 | Yes (after exit) |
| RuntimeServicesCode | 5 | No (preserve) |
| RuntimeServicesData | 6 | No (preserve) |
| ACPIReclaim | 9 | Yes (after ACPI init) |
| ACPINvs | 10 | No (preserve) |
| KernelStack | 0x1000 | Custom |
| KernelCode | 0x1001 | Custom |
| KernelData | 0x1002 | Custom |
| Framebuffer | 0x1003 | Custom |
""",

    "memory": """
## Virtual Memory Layout

### x86_64 Address Space
```text
0xFFFF_FFFF_FFFF_FFFF  --- Top of Memory
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
0x0000_7FFF_E000_0000  --- VDSO / VVAR Base (ASLR randomized)
                        |
0x0000_7FFF_FFFF_F000  --- User Stack Top Base (ASLR randomized)
                        |
0x0000_5555_5000_0000  --- PIE Load Base (ASLR randomized)
                        |
0x0000_1000_0000_0000  --- User mmap Base (ASLR randomized)
                        |
0x0000_0000_0040_0000  --- User Space Bottom
                        |
0x0000_0000_0000_0000  --- NULL
```

### Key Addresses
| Region | Address | Notes |
|--------|---------|-------|
| Kernel | 0xFFFFFFFF80000000 | 2GB window, higher half |
| HHDM | 0xFFFF800000000000 | Physical memory direct map |
| Kernel stacks | 0xFFFFA00000000000 | Guard pages between |
| User top | 0x00007FFFFFFFFFFF | Canonical lower half |
| User bottom | 0x0000000000400000 | First valid user addr |

### HHDM Translation
```zig
// Physical to virtual (kernel access)
pub fn physToVirt(phys: u64) [*]u8 {
    return @ptrFromInt(phys + hhdm_offset);
}

// Virtual to physical
pub fn virtToPhys(virt: u64) u64 {
    return virt - hhdm_offset;
}
```

### Why HHDM Matters
- Enables access to any physical address without explicit mapping
- Page table manipulation uses HHDM to read/write PML4/PDPT/PD/PT entries
- Avoids chicken-and-egg problem of needing page tables to access page tables
""",

    "paging": """
## Page Table Setup

### x86_64 PML4 Layout
```text
PML4 Index  Virtual Range                           Mapping
---------   -------------                           -------
0           0x0000_0000_0000_0000 - 0x007F...       Identity (0-4GB)
256         0xFFFF_8000_0000_0000 - 0xFFFF...       HHDM (all physical)
511         0xFFFF_FFFF_8000_0000 - 0xFFFF...       Kernel segments
```

### Page Table Flags
| Mapping | Present | Writable | Global | Huge (2MB) |
|---------|---------|----------|--------|------------|
| Identity | Yes | Yes | Yes | Where aligned |
| HHDM | Yes | Yes | Yes | Where aligned |
| Kernel .text | Yes | No | Yes | No |
| Kernel .data/.bss | Yes | Yes | Yes | No |

### Page Table Entry (8 bytes)
```text
63  62     52 51                        12 11 9 8 7 6 5 4 3 2 1 0
+--+---------+--------------------------+----+-+-+-+-+-+-+-+-+-+
|XD| Avail   | Physical Address [51:12] |Avail|G|S|D|A|C|W|U|W|P|
+--+---------+--------------------------+----+-+-+-+-+-+-+-+-+-+
```

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | P | Present |
| 1 | W | Writable |
| 2 | U | User Accessible |
| 7 | S | Page Size (1=Huge: 2MB/1GB) |
| 8 | G | Global (TLB preserved on CR3 switch) |
| 63 | XD | Execute Disable (NX bit) |

### Identity Mapping Preservation
**Critical:** VMM must copy ALL 512 PML4 entries (not just 256-511)
because UEFI bootloader stack resides in identity-mapped region.
Failure causes Double Fault when stack becomes inaccessible.

### Page Table Loading
```zig
// Switch to new page tables
asm volatile ("mov %[root], %%cr3" : : [root] "r" (root_phys));
```
""",

    "abi": """
## UEFI to Kernel ABI

### Calling Convention Mismatch
| Component | ABI | First Arg Register |
|-----------|-----|-------------------|
| UEFI Bootloader | Microsoft x64 | RCX |
| Kernel | System V AMD64 | RDI |

### Solution: Explicit Register Setup
The bootloader must set RDI before jumping to kernel:

```zig
// In bootloader (x86_64-uefi target)
asm volatile (
    \\\\mov %[bi], %%rdi
    \\\\jmp *%[entry]
    :
    : [bi] "r" (@intFromPtr(&boot_info)),
      [entry] "r" (kernel_entry_addr),
);
```

### Kernel Entry Signature
```zig
// Kernel (x86_64-freestanding target)
export fn _start(boot_info: *BootInfo.BootInfo) callconv(.c) noreturn {
    // boot_info arrives in RDI per System V AMD64 ABI
}
```

### Symptom of ABI Mismatch
**Problem:** Kernel receives garbage in BootInfo fields
**Cause:** Bootloader passed argument in RCX, kernel reads from RDI
**Fix:** Use inline assembly to move value to RDI before jump

### AArch64 ABI
```zig
// AArch64 uses X0 for first argument
asm volatile (
    \\\\mov x0, %[bi]
    \\\\br %[entry]
    :
    : [bi] "r" (@intFromPtr(&boot_info)),
      [entry] "r" (kernel_entry_addr),
);
```
""",

    "entry": """
## Kernel Entry Points

### Primary Entry: _start
Location: src/kernel/core/main.zig

```zig
export fn _start(boot_info: *BootInfo.BootInfo) callconv(.c) noreturn {
    // Validates BootInfo
    // Initializes HAL, memory, drivers
    // Starts scheduler
}
```

### Symbol Table Search
The bootloader searches for `_uefi_start` first, falls back to `e_entry` (_start).
This allows future differentiation between UEFI and other boot methods.

```zig
// In loader.zig
const uefi_entry = findSymbol(symtab, strtab, "_uefi_start") catch ehdr.e_entry;
```

### Entry Point Validation
```zig
fn validateBootInfo(boot_info: *const BootInfo.BootInfo) void {
    // HHDM offset must be in kernel space
    if (boot_info.hhdm_offset < 0xFFFF800000000000) {
        hal.cpu.halt();
    }
    // Memory map count within bounds
    if (boot_info.memory_map_count > 256) {
        hal.cpu.halt();
    }
    // Memory map pointer not null
    if (@intFromPtr(boot_info.memory_map) == 0) {
        hal.cpu.halt();
    }
}
```

### ELF Entry Point Debugging
```bash
# Check entry point
llvm-objdump --file-headers kernel.elf
# start address: 0xFFFFFFFF80000000 (good)
# start address: 0x0000000000000000 (bad - no _start symbol)

# Check symbol table
llvm-objdump --syms kernel.elf | grep _start
# *UND* = undefined (bad)
```
""",

    "init": """
## Kernel Initialization Sequence

Location: src/kernel/core/main.zig

### Initialization Steps (14 stages)
1. **Early Serial** - Prove entry, debug output before HAL
2. **Validate BootInfo** - Security checks (HHDM, memmap)
3. **HAL Init** - GDT, IDT, Serial, legacy PIC
4. **UART Driver** - Serial console backend
5. **GS Base** - Syscall per-CPU data setup
6. **Paging Init** - Set HHDM offset
7. **Memory Layout** - Apply KASLR offsets
8. **Memory Management** - PMM, VMM, kernel heap (via init_mem.zig)
9. **Framebuffer** - Video console (via init_fb.zig)
10. **VFS** - Virtual filesystem, mount InitRD at /
11. **Security** - Entropy, PRNG, Stack Guard (via stack_guard.zig)
12. **APIC** - Replace PIC, parse MADT, configure I/O APICs
13. **SMP** - Bring up Application Processors
14. **Devices** - Network, USB, Storage, Input (via init_hw.zig)

### Key Subsystem Files
```text
src/kernel/core/init_mem.zig   - PMM/VMM/Heap initialization
src/kernel/core/init_fs.zig    - VFS and filesystem mounts
src/kernel/core/init_hw.zig    - Device driver initialization
src/kernel/core/init_proc.zig  - InitRD loading, init process
src/kernel/core/stack_guard.zig - Stack canary setup
```

### Initialization Order Rationale
1. Serial first: Debug output before anything can fail
2. Memory before drivers: Drivers need heap allocation
3. Security before threads: Canary must be set before spawning
4. APIC before SMP: Timer/interrupt infrastructure needed
5. Devices last: Requires all subsystems ready
""",

    "troubleshoot": """
## Boot Troubleshooting

### Silent Reset / Boot Loop
**Cause:** Triple Fault or Stack Overflow
**Hint:** Check stack usage during PCI enumeration
**Fix:** Allocate large structures on heap, not stack (DeviceList ~16KB)

### General Protection Fault (GPF)

**Cause 1:** Unaligned ACPI struct access
**Fix:** Cast with align(1): `@as(*align(1) const T, ptr)`

**Cause 2:** CS pointing to wrong GDT entry after lgdt
**Fix:** Reload CS via far return after GDT switch:
```zig
\\\\pushq %[cs]
\\\\lea 1f(%%rip), %%rax
\\\\pushq %%rax
\\\\lretq
\\\\1:
```

**Cause 3:** GP fault with error code 0x28
**Meaning:** CS selector 0x28 points to TSS (not code segment)
**Fix:** Reload CS after loading new GDT

### Integer Overflow Panic
**Cause:** Zig safety checks (loop counters, bit ops)
**Examples:**
- `u3` counter overflow at 8
- `~u32` inside `u64` sets upper 32 bits
**Fix:** Check integer widths, use +% for wrapping

### Keyboard/Mouse Not Working
**PS/2:** Check 0xF4 (Enable Scanning) sent
**USB:** Ensure XHCI port reset sequence complete
**QEMU:** Add `-device qemu-xhci -device usb-kbd -device usb-mouse`

### SWAPGS Crash
**Symptom:** Fault at `mov %rsp, %gs:8` with CR2 = 0x8
**Cause:** GS base MSRs misconfigured
**Fix:** Set GS_BASE (not KERNEL_GS_BASE) before first user switch:
```zig
// CORRECT: Set GS_BASE initially
hal.cpu.writeMsr(hal.cpu.IA32_GS_BASE, @intFromPtr(&bsp_gs_data));

// WRONG: Setting KERNEL_GS_BASE directly
// syscall_arch.setKernelGsBase(@intFromPtr(&bsp_gs_data));
```

### ExitBootServices Failure
**Cause:** Memory map key stale
**Fix:** Get fresh map immediately before exit, retry once on key mismatch

### Double Fault After VMM Init
**Cause:** Identity mapping not preserved
**Fix:** Copy ALL 512 PML4 entries, not just 256-511
""",

    "aarch64": """
## AArch64 Boot Differences

### Address Space Split
| Register | Range | Purpose |
|----------|-------|---------|
| TTBR0_EL1 | 0x0000... | User, identity map |
| TTBR1_EL1 | 0xFFFF... | Kernel, HHDM |

Kernel at 0xFFFFFFFF80000000 and HHDM at 0xFFFF800000000000 both require TTBR1.

### System Registers

**MAIR_EL1 (Memory Attribute Indirection Register)**
```zig
const MAIR_DEVICE: u64 = 0x00;       // Index 0: Device-nGnRnE
const MAIR_NORMAL_WB: u64 = 0xFF;    // Index 1: Normal, Write-Back
const MAIR_NORMAL_NC: u64 = 0x44;    // Index 2: Normal, Non-Cacheable

const mair_value = MAIR_DEVICE | (MAIR_NORMAL_WB << 8) | (MAIR_NORMAL_NC << 16);
```

**TCR_EL1 (Translation Control Register)**
| Field | Value | Meaning |
|-------|-------|---------|
| T0SZ | 16 | 48-bit VA for TTBR0 |
| T1SZ | 16 | 48-bit VA for TTBR1 |
| TG0 | 0b00 | 4KB granule for TTBR0 |
| TG1 | 0b10 | 4KB granule for TTBR1 |
| IPS | 0b010 | 40-bit physical address (1TB) |

### Page Table Entry Format (Critical Bits)
| Bits | Field | Description |
|------|-------|-------------|
| 0 | Valid | Entry is valid |
| 1 | Table | 1 for L3 page descriptor |
| 4:2 | AttrIndx | MAIR index (0=Device, 1=Normal WB) |
| 7:6 | AP | Access Permissions |
| 9:8 | SH | Shareability (3 = Inner Shareable) |
| 10 | AF | Access Flag - MUST be set! |
| 11 | nG | Non-Global (set for user pages) |
| 53 | PXN | Privileged Execute Never |
| 54 | UXN | User Execute Never (CRITICAL!) |
| 63:55 | Software | Software-defined bits |

### Access Permission (AP) Encoding
| AP[1:0] | Kernel | User |
|---------|--------|------|
| 0b00 | RW | None |
| 0b01 | RW | RW |
| 0b10 | RO | None |
| 0b11 | RO | RO |

### Common AArch64 Boot Errors

**Translation fault at 0xFFFFFFFF80...**
- Cause: TTBR1 not set
- Fix: Set BOTH TTBR0_EL1 and TTBR1_EL1

**Instruction abort after paging enable**
- Cause: AttrIndx = 0 (Device memory) for code
- Fix: Set AttrIndx = 1: `raw |= (1 << 2);`

**Repeated faults at same address**
- Cause: AF (Access Flag) not set
- Fix: Always set: `raw |= (1 << 10);`

**User process Instruction Abort (UXN Bug)**
- Symptom: Instruction Abort at user entry point (EC=0x20/0x21)
- Cause: UXN bit (54) set for user code pages
- Detection: ESR shows Instruction Abort at user address
- Fix: Set `entry.uxn = flags.no_execute` NOT `entry.uxn = flags.user`
```zig
// WRONG: Accidentally sets UXN=1 for user pages
entry.user_accessible = flags.user;  // If mapped to bit 54!

// CORRECT: UXN only set for non-executable pages
entry.uxn = flags.no_execute;
```

**Memory exhaustion during boot**
- Symptom: OutOfMemory errors despite free pages
- Cause: RAM starts at 0x40000000 on QEMU virt, PMM searches from 0
- Fix: Initialize PMM search_hint based on memory_start

### Page Table Loading (AArch64)
```zig
asm volatile (
    // Disable MMU
    \\\\mrs x4, sctlr_el1
    \\\\bic x5, x4, #1
    \\\\msr sctlr_el1, x5
    \\\\isb
    // Configure memory attributes
    \\\\msr mair_el1, %[mair]
    \\\\msr tcr_el1, %[tcr]
    // Set page table bases
    \\\\msr ttbr0_el1, %[root]
    \\\\msr ttbr1_el1, %[root]
    // Invalidate TLB
    \\\\tlbi vmalle1
    \\\\dsb sy
    \\\\isb
    // Re-enable MMU
    \\\\msr sctlr_el1, x4
    \\\\isb
    :
    : [mair] "r" (mair_value), [tcr] "r" (tcr_value), [root] "r" (root_phys)
);
```

### Key Files
| File | Purpose |
|------|---------|
| src/boot/uefi/paging.zig | Dual-arch paging |
| src/arch/aarch64/boot/entry.S | Kernel entry |
| src/arch/aarch64/boot/linker.ld | High-half layout |
| src/arch/aarch64/mm/paging.zig | AArch64 page table entry format |
""",
}

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print("\nAvailable topics:", ", ".join(PATTERNS.keys()))
        sys.exit(1)

    query = sys.argv[1].lower()

    if query in PATTERNS:
        print(PATTERNS[query])
    else:
        # Fuzzy match
        matches = [k for k in PATTERNS.keys() if query in k]
        if matches:
            for m in matches:
                print(f"=== {m} ===")
                print(PATTERNS[m])
        else:
            print(f"Unknown topic: {query}")
            print(f"Available: {', '.join(PATTERNS.keys())}")
            sys.exit(1)

if __name__ == "__main__":
    main()
