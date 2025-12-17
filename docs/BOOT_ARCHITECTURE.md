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
*   **HHDM_OFFSET** = `0xFFFF_8000_0000_0000` (constant, verified against Limine response)

The `HHDM_OFFSET` is obtained from the Limine HHDM Request at boot (`src/kernel/main.zig:192-201`).

**HHDM vs Identity Mapping:**

Limine sets up three distinct page mappings before jumping to `_start`:
1. **Identity mapping** (phys 0x0 -> virt 0x0): Used only during early boot transition
2. **HHDM** (phys 0x0 -> virt 0xFFFF800000000000): Used by kernel for all physical memory access
3. **Higher-half kernel** (kernel code at 0xFFFFFFFF80000000): Where kernel ELF is loaded

The kernel discards the identity mapping after entry. All page table access uses HHDM via `paging.physToVirt()` (`src/arch/x86_64/paging.zig:173-189`):

```zig
pub fn physToVirt(phys: u64) [*]u8 {
    return @ptrFromInt(phys + hhdm_offset);
}
```

**Why HHDM matters:**
- Enables access to any physical address without explicit mapping
- Page table manipulation uses HHDM to read/write PML4/PDPT/PD/PT entries
- Avoids chicken-and-egg problem of needing page tables to access page tables

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

## 4. Demand Paging Architecture

Zscapek implements lazy (demand) paging for anonymous memory allocations. Physical pages are not allocated until first access.

### Virtual Memory Area (VMA) Structure

VMAs track user virtual address ranges. Defined in `src/kernel/user_vmm.zig`.

```text
Offset  Size    Type        Description
0x00    8       u64         start - Region start address (page-aligned)
0x08    8       u64         end - Region end address (exclusive)
0x10    4       u32         prot - Protection flags (PROT_READ|WRITE|EXEC)
0x14    4       u32         flags - Mapping flags (MAP_PRIVATE|SHARED|ANONYMOUS)
0x18    1       VmaType     vma_type - Allocation strategy
0x19    7       padding     Alignment padding
0x20    8       ?*Vma       next - Next VMA in sorted list
0x28    8       ?*Vma       prev - Previous VMA in sorted list
```

### VmaType Enum

Determines whether pages are allocated eagerly or on-demand:

| Type | Value | Allocation | Use Case |
|------|-------|------------|----------|
| Anonymous | 0 | Demand (lazy) | Standard mmap, heap, stack |
| File | 1 | Demand | File-backed mappings (future) |
| Device | 2 | Eager | MMIO regions, DMA buffers |

**Device mappings bypass demand paging** because hardware expects physical pages to exist at specific addresses before any access occurs.

### Page Fault Handler Flow

When a page fault occurs in user mode (CPL=3), the handler in `src/arch/x86_64/interrupts.zig` dispatches to the demand paging logic:

```text
1. CPU triggers #PF (vector 14)
   |
2. Check if user mode (CS & 3 == 3)
   |
3. Read CR2 (faulting address)
   |
4. Call registered page_fault_handler(cr2, error_code)
   |
5. Handler looks up VMA containing address
   |
   +-- Not found: Return false (SIGSEGV)
   |
   +-- Found: Check access permissions
       |
       +-- Write to read-only: Return false (SIGSEGV)
       |
       +-- Valid: Allocate zeroed page from PMM
           |
           Map page at fault address with VMA protection
           |
           Update process RSS accounting
           |
           Return true (retry instruction)
```

### x86_64 Page Fault Error Code

The error code pushed by the CPU indicates the fault type:

```text
Bit    Name    Meaning when set
0      P       Page was present (protection violation vs not-present)
1      W       Write access caused the fault
2      U       Fault occurred in user mode (CPL=3)
3      RSVD    Reserved bit set in page table entry
4      I/D     Instruction fetch caused the fault (NX violation)
```

**Demand paging handles**: Bit 0 = 0 (not-present), Bit 2 = 1 (user mode)

**Not handled (SIGSEGV)**: Bit 0 = 1 with Bit 1 = 1 and VMA lacks PROT_WRITE

### Key Implementation Files

| File | Purpose |
|------|---------|
| `src/kernel/user_vmm.zig` | VMA management, `handlePageFault()` |
| `src/arch/x86_64/interrupts.zig` | Handler dispatch, `setPageFaultHandler()` |
| `src/kernel/main.zig` | Handler registration |
| `src/kernel/syscall/base.zig` | `getCurrentProcessOrNull()` for safe process lookup |

### Lock Ordering (Page Faults)

Page faults can occur while other locks are held. The handler must avoid deadlock:

1. No locks held when calling `pmm.allocZeroedPage()`
2. VMA list is per-process (no global VMA lock)
3. Page table modifications use per-process PML4 (no global VMM lock needed)

## 5. Input Subsystem Architecture

Zscapek supports two input paths for keyboard and mouse devices.

### Dual-Path Input Architecture

```text
+------------------+                    +------------------+
|   Legacy Path    |                    |   Modern Path    |
+------------------+                    +------------------+
        |                                       |
   8042 PS/2                              PCI Bus
   Controller                                   |
   (I/O 0x60/0x64)                        XHCI Controller
        |                                       |
   IRQ1 (Keyboard)                        USB HID Device
   IRQ12 (Mouse)                                |
        |                                       |
+------------------+                    +------------------+
| drivers/keyboard |                    | drivers/usb/xhci |
+------------------+                    +------------------+
        |                                       |
        +-------------> Input Event Queue <-----+
                              |
                        Userland (syscall)
```

**Legacy Path (PS/2):**
- Controller: Intel 8042 at ports 0x60 (data) and 0x64 (status/command)
- Driver: `src/drivers/keyboard.zig`
- Interrupts: IRQ1 for keyboard, IRQ12 for mouse (via IOAPIC)

**Modern Path (USB):**
- Controller: XHCI (USB 3.0+) discovered via PCI enumeration
- Driver: `src/drivers/usb/xhci/root.zig`
- Interrupts: MSI-X or polling fallback

## 6. Hardware Initialization Quirks

These notes cover specific behaviors and requirements discovered during kernel bring-up.

### PS/2 Keyboard Initialization

The PS/2 controller requires explicit configuration before the keyboard generates scancodes.

**Initialization Sequence** (`src/drivers/keyboard.zig:352-437`):
1. Disable both PS/2 ports (commands 0xAD, 0xA7)
2. Flush output buffer (discard stale data)
3. Disable interrupts temporarily (clear config bits 0 and 1)
4. Controller self-test (command 0xAA, expect 0x55)
5. Port test (command 0xAB, expect 0x00)
6. Enable first port (command 0xAE)
7. Enable IRQ and translation mode (set config bits 0 and 6)
8. **Enable keyboard scanning** (send 0xF4 to data port, expect 0xFA acknowledgment)
9. Flush buffer again
10. Log final configuration

**Critical Step**: The `0xF4` (Enable Scanning) command at step 8 is required because some hardware does not enable scanning by default after a controller reset. Without this, the keyboard appears dead.

### USB/XHCI Port Reset

USB devices require a port reset to transition from "Powered" state to "Default/Addressed" state.

**Port Reset Sequence** (`src/drivers/usb/xhci/root.zig:440-487`):
1. Read PORTSC register for the target port
2. Verify device is connected (CCS bit = 1)
3. Assert Port Reset (PR bit = 1)
4. Clear status change bits (CSC, PEC, WRC, OCC, PRC) to avoid false triggers
5. Wait for reset completion (PR = 0, PED = 1) with 500ms timeout
6. Read port speed from PORTSC after reset

**Why this matters**: MacBook internal USB hubs and many modern USB devices require explicit port reset before responding to enumeration commands. Without reset, the device stays in "Powered" state and ignores Address Device commands.

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

## 7. Kernel ABI & Calling Convention

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

## 8. Security Architecture

### Stack Smashing Protection

The kernel uses compiler-inserted stack canaries to detect buffer overflows.

**Symbols** (`src/kernel/stack_guard.zig`):
*   **Canary**: `__stack_chk_guard` (exported at line 28, randomized at boot)
*   **Handler**: `__stack_chk_fail` (exported at line 33, halts kernel on corruption)
*   **Location**: Canary placed between local variables and return address by compiler

**Entropy Seeding** (`src/kernel/main.zig:280-291`):

The canary is seeded via hardware entropy during early boot:

```text
hal.entropy.init()     -->  Detect RDRAND support via CPUID
        |
prng.init()            -->  Seed xoroshiro128+ with two entropy values
        |
stack_guard.init()     -->  Generate canary via prng.next(), clear low byte
        |
scheduler.init()       -->  First threads created (all protected)
```

**Hardware Entropy Sources** (`src/arch/x86_64/entropy.zig`):
1. **RDRAND** (preferred): Intel/AMD hardware RNG via CPUID leaf 1, ECX bit 30
   - Provides cryptographic-quality randomness from on-chip DRBG
   - Retried up to 10 times on failure before fallback
2. **RDTSC** (fallback): Time Stamp Counter when RDRAND unavailable
   - Multiple samples with XOR mixing and bit rotations
   - Lower quality, not cryptographically secure

**Canary Format** (`stack_guard.zig:67`):

The low byte is cleared to 0x00 for null-terminator overflow detection:
```
[random 7 bytes][0x00]
```

This causes string-based overflows to include the null terminator in the overwrite, making detection more reliable.

### Privilege Separation
*   **Ring 0 (Kernel)**: Full access.
*   **Ring 3 (User)**: No direct hardware/memory access. Must use syscalls.
*   **Protection**:
    *   `U` bit in Page Tables prevents Ring 3 from accessing kernel pages.
    *   `SMAP/SMEP` (future): Prevent kernel from executing/accessing user pages accidentally.

### KASLR
Limine supports KASLR. The kernel is position-independent (PIE) but linked to high memory. The physical load address may vary, but virtual addresses are fixed by the linker script to `0xffffffff80000000`.

## 9. SMP Implementation Notes

### AP Trampoline Protocol

Application Processors (APs) start in Real Mode (16-bit). The BSP (Bootstrap Processor) must orchestrate their bring-up.

**Trampoline Loading** (`src/arch/x86_64/smp.zig:59-103`):
1. Allocate a page in low memory (0x1000-0xA0000, under 640KB)
2. Copy trampoline code from kernel image to allocated page
3. Create identity mapping for trampoline page (virtual = physical)
4. Patch immediate values in trampoline code

**INIT-SIPI-SIPI Sequence** (`src/arch/x86_64/smp.zig:205-215`):
```text
BSP                                         AP
 |                                           |
 |------ INIT IPI --------------------------->|  (Reset AP)
 |           10ms delay                       |
 |------ SIPI (vector = page >> 12) --------->|  (Wake at trampoline)
 |           200us delay                      |
 |------ SIPI (second, per Intel spec) ------>|
 |                                           |
 |                      [AP executes trampoline]
```

**Trampoline Mode Transitions** (`src/arch/x86_64/smp_trampoline.S`):

```text
Real Mode (16-bit)     Protected Mode (32-bit)     Long Mode (64-bit)
      |                        |                          |
  cli, setup DS/ES/SS     Set PE bit in CR0          Set LME+NXE in EFER
      |                        |                          |
  lgdt (temp GDT)         Enable PAE in CR4          Set PG bit in CR0
      |                        |                          |
  far jump 0x18:pm_entry  Load CR3 (BSP's PML4)      far jump 0x08:lm_entry
                                                           |
                                                      Load RSP, jump to kernel
```

**Trampoline Patching** (`src/arch/x86_64/smp.zig:111-169`):

These values are patched into the trampoline before sending SIPI:

| Patch Point | Size | Value |
|-------------|------|-------|
| PM jump target | 4 bytes | Physical addr of 32-bit entry |
| LM jump target | 4 bytes | Physical addr of 64-bit entry |
| CR3 | 4 bytes | BSP's page table base (from `cpu.readCr3()`) |
| RSP | 8 bytes | Per-AP stack top address |
| AP GDT | 8 bytes | Virtual addr of AP's GDT copy |
| Entry point | 8 bytes | `&apEntry` function pointer |

**Critical Requirement - NXE Bit** (`smp_trampoline.S:98-108`):

When enabling Long Mode in the trampoline (EFER MSR at 0xC0000080), the **NXE (No-Execute Enable)** bit (bit 11) MUST be set if the kernel page tables use the NX bit:

```assembly
mov $0xC0000080, %ecx    // IA32_EFER MSR
rdmsr
or $(1 << 8), %eax       // LME - Long Mode Enable
or $(1 << 11), %eax      // NXE - No-Execute Enable
wrmsr
```

Failure to set NXE causes the AP to #PF (Page Fault) immediately upon enabling paging, as it interprets the NX bits in page table entries as "reserved bits" that must be zero.

**Embedded GDT** (`smp_trampoline.S:162-182`):

The trampoline contains a temporary 4-entry GDT:
- 0x00: Null descriptor
- 0x08: 64-bit code (L=1, D=0)
- 0x10: Data (shared by all modes)
- 0x18: 32-bit code (L=0, D=1)