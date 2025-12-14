# Boot Architecture & ABI Reference

This document provides the definitive technical reference for Zscapek's boot process, struct alignments, memory layout, and hardware interfaces. It is intended for kernel developers needing byte-level precision.

## 1. Virtual Memory Map (x86_64)

Zscapek uses the standard Higher Half Kernel model.

```text
0xFFFF_FFFF_FFFF_FFFF  ─── Top of Memory
                        │
                        │  Kernel Image (Text/Data/BSS)
                        │  Mapped from ELF at link time
0xFFFF_FFFF_8000_0000  ─── Kernel Base (2 GB window)
                        │
                        │  (Gap)
                        │
0xFFFF_8000_0000_0000  ─── HHDM Base (Higher Half Direct Map)
                        │  Maps all physical RAM linearly
                        │  Phys 0x0 -> 0xFFFF_8000_0000_0000
                        │
0xFFFF_A000_0000_0000  ─── Kernel Stacks Region
                        │  Explicitly allocated stacks with guard pages
                        │
0x0000_7FFF_FFFF_FFFF  ─── User Space Top (Canonical)
                        │
                        │  User Stacks / Heap / Code
                        │
0x0000_0000_0000_0000  ─── User Space Bottom
```

### Physical to Virtual Translation

The kernel uses the **Higher Half Direct Map (HHDM)** provided by Limine to access physical memory.

*   **Virtual Address** = `Physical Address` + `HHDM_OFFSET`
*   **Physical Address** = `Virtual Address` - `HHDM_OFFSET`

The `HHDM_OFFSET` is obtained from the Limine HHDM Request at boot.

## 2. Limine Boot Protocol ABI

Limine uses a Request/Response mechanism. All pointers are 64-bit and 8-byte aligned.

### Generic Request Structure
All Limine requests share this 24-byte (3x u64) header structure.

```text
Offset  Size    Type    Description
0x00    8       u64[4]  Magic ID (Unique 4-u64 signature)
0x20    8       u64     Revision (0)
0x28    8       ptr     Response Pointer (Written by Limine)
```

**Note on Magic IDs**: Defined in `src/lib/limine.zig`. They identify the request type to the bootloader.

### Framebuffer Response Layout
The response pointer points to this structure in bootloader-reclaimable memory.

```text
Offset  Size    Type    Description
0x00    8       u64     Revision
0x08    8       u64     Framebuffer Count
0x10    8       ptr     Pointer to array of Framebuffer structs
```

### Framebuffer Struct
The actual video mode definition.

```text
Offset  Size    Type    Description
0x00    8       ptr     Address (Physical video memory)
0x08    8       u64     Width (pixels)
0x10    8       u64     Height (pixels)
0x18    8       u64     Pitch (Bytes per row)
0x20    2       u16     BPP (Bits per pixel)
0x22    1       u8      Memory Model
0x23    1       u8      Red Mask Size
0x24    1       u8      Red Mask Shift
0x25    1       u8      Green Mask Size
0x26    1       u8      Green Mask Shift
0x27    1       u8      Blue Mask Size
0x28    1       u8      Blue Mask Shift
0x29    7       u8[7]   Unused (Padding)
0x30    8       u64     EDID Size
0x38    8       ptr     EDID Pointer
```

### GS Base Register
The first context switch to user mode (via `isr_common` IRETQ) does SWAPGS, which swaps the values. So you must set GS_BASE initially so it ends up in KERNEL_GS_BASE after that first swap.

**Critical Note for SMP/Scheduler:**
When accessing per-CPU data *inside* the kernel (e.g., during scheduler initialization or timer ticks before returning to user), you must read `IA32_GS_BASE`, not `IA32_KERNEL_GS_BASE`. Even though you intend to access the "kernel" GS, if no SWAPGS has occurred (because we are already in kernel mode), the active base is still in the `IA32_GS_BASE` register. Reading `IA32_KERNEL_GS_BASE` will return 0 (or user base), leading to null pointer panics.

## 3. Hardware Structures (x86_64)

These structures are defined by the CPU architecture and must effectively use `packed` or `extern` alignment.

### GDT Entry (8 Bytes)
Defined in `src/arch/x86_64/gdt.zig`.

```text
63                               48 47       40 39       32
┌───────────────┬─┬─┬─┬────────────┬───────────┬───────────┐
│  Base 31:24   │G│D│L│ AVL/LimHi  │ P DPL S T │ Base 23:16│
└───────────────┴─┴─┴─┴────────────┴───────────┴───────────┘
31                               16 15                    0
┌──────────────────────────────────┬───────────────────────┐
│           Base 15:0              │       Limit 15:0      │
└──────────────────────────────────┴───────────────────────┘
```

*   **P**: Present (1)
*   **DPL**: Privilege Level (0=Kernel, 3=User)
*   **S**: Descriptor Type (1=Code/Data, 0=System)
*   **T**: Type (Read/Write/Execute flags)
*   **L**: Long Mode (1 for 64-bit code)

**Critical Note on GDT Loading:**
After loading a new GDT with `lgdt`, the segment registers (DS, ES, SS, FS, GS) can be reloaded with simple `mov` instructions. However, **CS cannot be loaded directly**. It must be reloaded via a far jump (`ljmp`) or far return (`lretq`). Failure to reload CS after switching GDTs will leave CS pointing to the old GDT's selector, which may now reference a completely different descriptor type (e.g., TSS instead of code segment), causing a GP fault on the next `iretq`.

### IDT Gate Descriptor (16 Bytes)
**Critical Difference**: In Long Mode (64-bit), interrupt gates are 16 bytes, not 8.
Defined in `src/arch/x86_64/idt.zig`.

```text
127                                                          96
┌─────────────────────────────────────────────────────────────┐
│                        Reserved (0)                         │
└─────────────────────────────────────────────────────────────┘
95                                                           64
┌─────────────────────────────────────────────────────────────┐
│                      Offset 63:32                           │
└─────────────────────────────────────────────────────────────┘
63               48 47 46  44 43    40 39  37 36  35  32 31  16
┌──────────────────┬─┬─────┬──────────┬──────┬───┬──────┬─────┐
│   Offset 31:16   │P│ DPL │0 1 1 1 0 │0 0 0 │IST│ Rsvd │ Sel │
└──────────────────┴─┴─────┴──────────┴──────┴───┴──────┴─────┘
15                                                            0
┌─────────────────────────────────────────────────────────────┐
│                        Offset 15:0                          │
└─────────────────────────────────────────────────────────────┘
```

*   **Sel**: Segment Selector (Kernel Code = 0x08)
*   **IST**: Interrupt Stack Table Index (1-7, 0=None)
*   **Type**: 0xE (1110) = 64-bit Interrupt Gate
*   **DPL**: Descriptor Privilege Level (3 for syscalls/user interrupts)

### TSS (Task State Segment) - 104 Bytes
Holds stack pointers for privilege level changes.
Defined in `src/arch/x86_64/gdt.zig`.

*   **RSP0 (Offset 0x04)**: Stack pointer to load when switching to Ring 0 (Kernel).
*   **IST1-7 (Offsets 0x24-0x54)**: Dedicated stacks for specific interrupts (e.g., Double Fault, NMI).
*   **IOPB Offset (Offset 0x66)**: I/O Permission Bitmap (set to 104 to disable).

### Page Table Entry (8 Bytes)
Used for PML4, PDPT, PD, and PT.
Defined in `src/arch/x86_64/paging.zig`.

```text
63  62     52 51                                       12 11 9 8 7 6 5 4 3 2 1 0
┌──┬─────────┬───────────────────────────────────────────┬────┬─┬─┬─┬─┬─┬─┬─┬─┬─┐
│XD│ Available│          Physical Address [51:12]         │Avail│G│S│D│A│C│W│U│W│P│
└──┴─────────┴───────────────────────────────────────────┴────┴─┴─┴─┴─┴─┴─┴─┴─┴─┘
```

*   **P**: Present
*   **W**: Writable
*   **U**: User Accessible
*   **WT**: Write Through
*   **CD**: Cache Disable
*   **A**: Accessed
*   **D**: Dirty
*   **S**: Page Size (1 = Huge Page: 2MB or 1GB)
*   **G**: Global (TLB preserved on CR3 switch)
*   **XD**: Execute Disable (NX bit)

## 4. Hardware Interface Technical Notes (Lessons Learned)

These notes cover specific behaviors and requirements discovered during kernel bring-up.

### ACPI Table Alignment
ACPI tables (RSDP, RSDT, XSDT, MCFG) are provided by firmware and often reside at non-natural alignments (e.g., 4-byte boundaries).
*   **Requirement**: All ACPI struct pointers must be cast as `*align(1) const T` to prevent General Protection Faults (GPF) or unaligned access implementations (like `memcpy`) from failing.
*   **Example**: `const rsdp = @as(*align(1) const Rsdp, @ptrFromInt(addr));`

### PCI Enumeration & Configuration
*   **ECAM Access**: The MCFG table provides the physical base address for the Enhanced Configuration Access Mechanism (ECAM). This region must be mapped into virtual memory before access.
*   **Memory Usage**: The `DeviceList` structure for PCI can be large (~16KB). Allocating this on the stack during early boot (where stack space is limited to ~4-16KB) will cause a **Double Fault / Stack Overflow**. It must be allocated on the heap.
*   **Bar Sizing Logic**:
    *   To size a BAR, write `0xFFFFFFFF` to it and read back.
    *   **Integer Overflow Risk**: Creating a size mask by inverting a 32-bit read in a 64-bit variable (e.g., `~bar_read`) will set the upper 32-bits to 1, resulting in an incorrect size (e.g., 18 Exabytes). Mask operations must be strictly width-controlled.
    *   **Loop Counters**: Iterating through functions (0-7) with a `u3` counter will cause an integer overflow when incrementing to 8 to exit the loop. Use `u4`.

## 5. Kernel ABI & Calling Convention

### Interrupt Handling
When an interrupt occurs:
1.  **CPU Pushes**: SS, RSP, RFLAGS, CS, RIP (Hardware Frame).
2.  **Stub Pushes**: Error Code (or 0), Vector Number.
3.  **Handler Pushes**: All GPRs (RAX...R15).
4.  **Stack Alignment**: RSP is aligned to 16 bytes before calling Zig code.

**Stack Layout at Handler Entry**:
```
[ SS ] [ RSP ] [ RFLAGS ] [ CS ] [ RIP ] [ Err ] [ Vec ] [ Regs... ]
                                                              ^
                                                              |
                                                      Zig Function Args
```

### Syscall Interface (Linux ABI)
Zscapek implements a subset of the Linux ABI.

| Register | Purpose |
|---|---|
| **RAX** | Syscall Number |
| **RDI** | Argument 1 |
| **RSI** | Argument 2 |
| **RDX** | Argument 3 |
| **R10** | Argument 4 (Not RCX!) |
| **R8** | Argument 5 |
| **R9** | Argument 6 |
| **RAX** | Return Value |

*Note: The `syscall` instruction clobbers RCX and R11. Linux ABI uses R10 for the 4th argument instead of RCX.*

## 6. Security Architecture

### Stack Smashing Protection
*   **Canary**: `__stack_chk_guard` (randomized at boot).
*   **Handler**: `__stack_chk_fail` (panics kernel).
*   **Location**: Canary placed between local variables and return address.

### Privilege Separation
*   **Ring 0 (Kernel)**: Full access.
*   **Ring 3 (User)**: No direct hardware/memory access. Must use syscalls.
*   **Protection**:
    *   `U` bit in Page Tables prevents Ring 3 from accessing kernel pages.
    *   `SMAP/SMEP` (future): Prevent kernel from executing/accessing user pages accidentally.

### KASLR
Limine supports KASLR. The kernel is position-independent (PIE) but linked to high memory. The physical load address may vary, but virtual addresses are fixed by the linker script to `0xffffffff80000000`.

## 7. SMP Implementation Notes

### AP Trampoline
Application Processors (APs) start in Real Mode (16-bit). The kernel must:
1.  Copy a trampoline blob to low memory (e.g., `< 1MB`).
2.  Send SIPI (Startup IPI) to the AP to jump to that physical address.
3.  The trampoline transitions the AP to Protected Mode (32-bit) and then Long Mode (64-bit).

**Critical Requirement - NXE Bit:**
When enabling Long Mode in the trampoline (`EFER` MSR), the **NXE (No-Execute Enable)** bit (bit 11) MUST be set if the kernel page tables use the NX bit. Failure to set this will cause the AP to #PF (Page Fault) immediately upon enabling paging, as it encounters "reserved bits" (the NX bit) in the page tables that it doesn't think are valid.