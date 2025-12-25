# Boot Process Documentation

## Overview

Zscapek uses a custom UEFI bootloader written in Zig. The kernel is compiled as a standard 64-bit ELF executable and loaded into the higher half of virtual memory.

**Developer Reference**:

For detailed byte-level layouts, struct alignments, and hardware interface specifications, see **[BOOT_ARCHITECTURE.md](BOOT_ARCHITECTURE.md)**.

## Boot Flow

1. **UEFI Firmware** loads `EFI/BOOT/BOOTX64.EFI` from the EFI System Partition.
2. **UEFI Bootloader** (`src/boot/uefi/main.zig`):
   - Loads `kernel.elf` from the filesystem
   - Loads `initrd.tar` (initial ramdisk) if present
   - Parses ELF headers and loads PT_LOAD segments into memory
   - Searches symbol table for `_uefi_start` entry point
   - Initializes GOP (Graphics Output Protocol) for framebuffer
   - Gets UEFI memory map and converts to BootInfo format
   - Locates RSDP (ACPI Root System Description Pointer)
   - Creates PML4 page tables:
     - Identity map: 0-4GB (for boot transition)
     - HHDM: 0xFFFF800000000000 maps all physical memory
     - Kernel: High-half kernel segments
   - Calls `ExitBootServices()` to take control from UEFI
   - Loads new page tables (switches CR3)
   - Jumps to `_uefi_start` with BootInfo pointer

3. **Kernel Entry** (`_uefi_start` in `src/kernel/core/main.zig`):
   - Receives BootInfo structure with memory map, framebuffer, RSDP, and initrd
   - Initializes HAL, memory management, and all subsystems

### UEFI Bootloader Files

| File | Purpose |
|------|---------|
| `src/boot/uefi/main.zig` | Main entry, boot sequence orchestration |
| `src/boot/uefi/loader.zig` | ELF parsing, segment loading, symbol lookup, initrd loading |
| `src/boot/uefi/memory.zig` | UEFI memory map handling |
| `src/boot/uefi/graphics.zig` | GOP initialization |
| `src/boot/uefi/paging.zig` | PML4 page table creation |
| `src/boot/common/boot_info.zig` | Shared BootInfo structure |

### Boot Methods

Zscapek supports two boot methods for QEMU:

#### GPT Disk Image (Recommended)
```bash
zig build run -Drun-iso=false
```
This creates `disk.img`, a GPT-partitioned disk with an EFI System Partition. More reliable across UEFI firmware implementations.

The `tools/disk_image.zig` tool generates the disk image:
- Sector 0: Protective MBR (type 0xEE, signature 0x55AA)
- Sector 1: GPT header
- Sectors 2+: Partition entries and EFI System Partition (FAT16)

#### ISO Image (Hybrid GPT)
```bash
zig build run -Drun-iso=true   # or just: zig build run
```
Creates `zigk.iso` with hybrid GPT/El Torito structure via xorriso's `-isohybrid-gpt-basdat` option.

**Note**: QEMU boots the ISO as a hard disk (not CDROM) to work around an EDK2 El Torito firmware limitation. The ISO file remains valid for burning to real optical media.

### Running

```bash
# Build and run with UEFI (GPT disk - recommended)
zig build run -Drun-iso=false -Dbios=/opt/homebrew/share/qemu/edk2-x86_64-code.fd

# Or manually with QEMU
qemu-system-x86_64 -M q35 -m 256M \
  -drive if=none,format=raw,id=esp,file=disk.img \
  -device ide-hd,drive=esp,bus=ide.0,bootindex=1 \
  -drive if=pflash,format=raw,readonly=on,file=/path/to/edk2-x86_64-code.fd \
  -serial stdio -accel tcg
```

## Kernel Initialization

4. **Kernel Initialization** (`src/kernel/core/main.zig`):
   - Validates BootInfo structure (HHDM, Framebuffer, Memory Map)
   - Initializes HAL (GDT/IDT/Serial/PIC)
   - Initializes Memory Management (PMM/VMM via `core/init_mem.zig`)
   - Initializes VDSO (Virtual Dynamic Shared Object)
   - Initializes File Systems (VFS)
   - Initializes Security (Entropy, PRNG, Stack Guard via `core/stack_guard.zig`)
   - Initializes APIC (replaces legacy PIC) & Re-seeds Stack Guard
   - Initializes SMP (brings up Application Processors)
   - Initializes Async I/O Reactor
   - Initializes Signal Handling
   - Initializes Hardware (PCI, Network*, USB, Audio, Storage, VirtIO-GPU) via `core/init_hw.zig`
     * *Note: Kernel network stack is currently disabled for userspace migration.*
   - Loads Init Process (scans modules for drivers and init candidate)
   - Starts Scheduler and Futex subsystem

## Memory Layout

### Virtual Address Space

```
0x0000_0000_0000_0000 - 0x0000_7FFF_FFFF_FFFF  User space (128 TB)
0xFFFF_8000_0000_0000 - 0xFFFF_FFFF_7FFF_FFFF  HHDM (physical memory access)
0xFFFF_FFFF_8000_0000 - 0xFFFF_FFFF_FFFF_FFFF  Kernel (top 2 GB)
```

### Key Addresses

| Region | Virtual Address | Description |
|--------|----------------|-------------|
| Kernel Base | `0xFFFFFFFF80000000` | Kernel code and data |
| HHDM Base | `0xFFFF800000000000` | Direct map of physical memory |
| Kernel Stacks | `0xFFFFA00000000000` | Per-thread kernel stacks |
| User Stack | `0x7FFF_FFFF_F000` (base) | User stack location (ASLR randomized) |
| VDSO / VVAR | `0x7FFF_E000_0000` (base) | Shared kernel-user pages (ASLR randomized) |
| PIE Base | `0x5555_5000_0000` (base) | Position-independent executable load address (ASLR randomized) |
| User mmap region | `0x1000_0000_0000` (base) | Demand-paged anonymous mappings (ASLR randomized) |

## Demand Paging

Zscapek implements lazy (demand) paging for anonymous memory mappings. When userspace calls `mmap()`, the kernel reserves virtual address space by creating a VMA (Virtual Memory Area) but does not allocate physical pages. Physical pages are allocated on-demand when the memory is first accessed.

### How It Works

1. **mmap()**: Creates a VMA entry tracking the address range, protection flags, and mapping type. No physical pages allocated.

2. **First Access**: When userspace reads/writes the mapped region, a page fault occurs (not-present page).

3. **Page Fault Handler**: The kernel's demand paging handler:
   - Looks up the faulting address in the process's VMA list
   - Verifies access permissions (write to read-only = SIGSEGV)
   - Allocates a zeroed physical page from PMM
   - Maps the page into the process's address space
   - Returns to userspace to retry the instruction

4. **VMA Types**:
   - `Anonymous`: Zero-filled on demand (standard mmap behavior)
   - `Device`: Eagerly mapped for MMIO/DMA (never demand-paged)
   - `File`: Reserved for future file-backed mappings

### Benefits

- **Memory efficiency**: Only allocate pages that are actually used
- **Faster mmap()**: Returns immediately without allocation overhead
- **Overcommit support**: Map more virtual memory than physical RAM available

### Key Files

- `src/kernel/mm/user_vmm.zig` - VMA management and `handlePageFault()`
- `src/arch/x86_64/interrupts.zig` - Page fault dispatch to demand paging handler
- `src/kernel/core/main.zig` - Handler registration via `setPageFaultHandler()`

## Address Space Layout Randomization (ASLR)

Zscapek implements full ASLR to randomize critical memory regions per-process, mitigating exploitation techniques that rely on predictable addresses (ROP, ret2libc, etc.).

### Randomized Regions

| Component | Base Address | Entropy | Range |
|-----------|--------------|---------|-------|
| Stack top | `0x7FFF_FFFF_F000` | 11 bits | 8MB (2048 pages) |
| PIE base | `0x5555_5000_0000` | 16 bits | 4GB (64KB granularity) |
| mmap base | `0x1000_0000_0000` | 20 bits | 4TB |
| Heap gap | After ELF end | 8 bits | 1MB (256 pages) |
| VDSO | `0x7FFF_E000_0000` | 16 bits | 256MB (65536 pages) |

### Behavior

- **Process creation**: New ASLR offsets generated via `aslr.generateOffsets()`
- **Fork**: Child inherits parent's ASLR layout (same address space)
- **Execve**: New ASLR offsets generated (replaces address space)

### Entropy Source

ASLR uses the kernel PRNG (xoroshiro128+) seeded from hardware entropy (RDRAND/RDSEED) at boot. The `prng.range()` function uses rejection sampling to avoid modulo bias.

### Key Files

- `src/kernel/mm/aslr.zig` - ASLR offset generation and configuration
- `src/kernel/proc/process/types.zig` - Per-process `aslr_offsets` field
- `src/kernel/core/elf/root.zig` - Accepts randomized stack_top and pie_base
- `src/kernel/mm/user_vmm.zig` - Randomized mmap_base per address space

## ELF Loading and Userland Binaries

### Freestanding Entry Points in Zig

For userland programs targeting `freestanding`, the `_start` symbol must be explicitly exported:

```zig
// CORRECT: Entry point is exported and visible to linker
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\    mov $1, %%rax
        \\    ...
    );
}

// WRONG: comptime asm does NOT export symbols
comptime {
    asm(
        \\.global _start
        \\_start:
        \\    ...
    );
}
```

The `comptime { asm(...) }` pattern generates assembly but does not create a symbol the linker can find. The result is an ELF with `e_entry = 0`.

### Diagnosing ELF Entry Point Issues

If a userland binary crashes immediately on first instruction:

1. **Check the ELF entry point**: `llvm-objdump --file-headers binary`
   - `start address: 0x0000000000000000` means the linker didn't find `_start`

2. **Check symbol table**: `llvm-objdump --syms binary | grep _start`
   - `*UND*` (undefined) means the symbol doesn't exist in the binary

3. **Verify opcodes at entry**: The ELF loader logs first 4 bytes
   - `00 00 00 00` = memory is zeroed, copy failed or wrong entry
   - Valid x86 prologue often starts with `55` (push rbp) or similar

### ELF Loader Error Handling

The ELF loader (`src/kernel/core/elf/root.zig`) must handle translation failures explicitly. Silent failures in `copyToUserspace` can leave mapped pages zeroed, causing immediate crashes when userspace executes.

Pattern for safe segment loading:
```zig
// copyToUserspace returns error if VMM translation fails
try copyToUserspace(pml4_phys, vaddr, src);
```

### Auxiliary Vector (auxv)

Static ELF binaries (especially those using musl or glibc) require auxiliary vector entries on the stack. The kernel passes these via `setupStack`:

| AT_* Constant | Value | Description |
|---------------|-------|-------------|
| AT_PHDR (3)   | addr  | Address of program headers in memory |
| AT_PHENT (4)  | 56    | Size of each program header entry |
| AT_PHNUM (5)  | count | Number of program headers |
| AT_PAGESZ (6) | 4096  | System page size |
| AT_ENTRY (9)  | addr  | Original entry point |
| AT_SYSINFO_EHDR (33) | addr | Address of VDSO header (for fast syscalls) |

Without these, C runtime initialization may fail silently or crash.

### Linker Script Requirements

Userland linker scripts (`src/user/linker.ld`) must specify:

```ld
ENTRY(_start)           /* Must match exported symbol */
USER_BASE = 0x400000;   /* Load address in user space */
```

The `ENTRY` directive only works if the symbol exists in the object files.

## Troubleshooting & Debugging

If the kernel fails to boot or panics early, consider the following:

### 1. Serial Console is Critical
The framebuffer log may scroll too fast or be initialized too late. Rely on the serial console (COM1/0x3F8) for debugging.
*   **QEMU**: Use `-serial stdio` to see logs in your terminal.
*   **Real Hardware**: Connect a serial cable to COM1 or use a USB-to-serial adapter. Set baud rate to 115200.
*   **Formatting**: Ensure your console writer supports `std.fmt`. If using a custom writer, be wary of format specifiers like `{:0>16x}` causing parser errors; simple `{x}` is safer for basic debugging.
*   **Minimal QEMU Command**: For serial-only debugging without display:
    ```bash
    qemu-system-x86_64 -M q35 -m 128M \
      -drive file=zigk.iso,format=raw,if=none,id=boot \
      -device ide-hd,drive=boot,bus=ide.0,bootindex=1 \
      -drive if=pflash,format=raw,readonly=on,file=/path/to/edk2-x86_64-code.fd \
      -serial stdio -display none -accel tcg
    ```

### 2. Common Failures
*   **Silent Reset / Boot Loop**: 
    *   **Cause**: Triple Fault or Stack Overflow.
    *   **Hint**: If it happens during deep recursions or large iterations (like PCI enumeration), check your stack usage. The kernel stack is small (typically 16KB). **Allocate large structures (e.g., arrays of devices) on the Heap.**
*   **"General Protection Fault" (GPF)**:
    *   **Cause 1**: Unaligned memory access, often when reading packed ACPI structs.
    *   **Fix**: Ensure all pointers to packed structs (like `*Rsdp` or `*McfgBase`) are cast with `align(1)`, e.g., `@as(*align(1) const T, ptr)`.
    *   **Cause 2**: CS register pointing to wrong GDT entry (e.g., TSS selector 0x28 instead of KERNEL_CODE 0x08).
    *   **Fix**: The GDT initialization must reload CS via far return after loading the new GDT. The UEFI bootloader uses a different GDT layout where kernel code may be at a different index than Zscapek's GDT. See "GDT Initialization and CS Reload" section below.
*   **"Integer Overflow" Panic**:
    *   **Cause**: Zig's safety checks (enabled in Debug/ReleaseSafe) catch overflows that other languages ignore.
    *   **Hint**: Check loop counters (e.g., `u3` cannot hold 8) and bitwise operations on differing integer widths (e.g., `~u32` inside `u64`). Use `+%` for wrapping addition if intentional.
*   **Keyboard/Mouse Not Working**:
    *   **Check**: Is the VM/hardware using PS/2 or USB input?
    *   **PS/2 (QEMU default)**: The kernel sends `0xF4` (Enable Scanning) to the keyboard during initialization.
    *   **Note**: Keyboard and Mouse drivers are being moved to userspace (Phase 5). The kernel now spawns `ps2_driver` or `uart_driver` if found in boot modules.
    *   **USB (MacBook/Modern PC)**: Requires XHCI driver with Port Reset logic. The driver must reset ports to transition devices from "Powered" to "Default/Addressed" state.
    *   **QEMU Fix**: Add `-device qemu-xhci -device usb-kbd -device usb-mouse` to force USB mode.
    *   **Serial Diagnostics**: Check serial console for "PS/2 keyboard: enable failed" or "XHCI: Port reset" messages.

### 3. SWAPGS and Syscall Entry Crashes

If syscall entry faults at `mov %rsp, %gs:8` with CR2 = 0x8 (or similar low address), the GS base MSRs are misconfigured.

**The SWAPGS Dance:**

x86_64 uses two MSRs for the GS segment base:
- `IA32_GS_BASE` (0xC0000101) - Current GS base
- `IA32_KERNEL_GS_BASE` (0xC0000102) - Swapped with GS_BASE by SWAPGS

The `SWAPGS` instruction atomically exchanges these two values. Both interrupt handlers (isr_common) and syscall entry use SWAPGS to switch between user and kernel GS.

**Required State:**

| Mode | GS_BASE | KERNEL_GS_BASE |
|------|---------|----------------|
| Kernel (after entry SWAPGS) | &kernel_gs_data | user_gs (0) |
| User (after exit SWAPGS) | user_gs (0) | &kernel_gs_data |

**Initialization (before first user process):**

```zig
// CORRECT: Set GS_BASE for kernel, leave KERNEL_GS_BASE as 0
hal.cpu.writeMsr(hal.cpu.IA32_GS_BASE, @intFromPtr(&bsp_gs_data));

// WRONG: Setting KERNEL_GS_BASE directly
// syscall_arch.setKernelGsBase(@intFromPtr(&bsp_gs_data));
```

**Why this matters:**

1. Kernel boots with GS_BASE = undefined, KERNEL_GS_BASE = 0
2. If you set KERNEL_GS_BASE = &kernel_data (wrong approach):
   - First SWAPGS to user: GS_BASE = &kernel_data, KERNEL_GS_BASE = undefined
   - Syscall SWAPGS: GS_BASE = undefined (crash!)
3. If you set GS_BASE = &kernel_data (correct approach):
   - First SWAPGS to user: GS_BASE = 0 (user), KERNEL_GS_BASE = &kernel_data
   - Syscall SWAPGS: GS_BASE = &kernel_data (works!)

The first context switch to user mode (via `isr_common` IRETQ) does SWAPGS, which swaps the values. So you must set GS_BASE initially so it ends up in KERNEL_GS_BASE after that first swap.

### 4. GDT Initialization and CS Reload

When the kernel loads its own GDT, it must also reload the CS register. The UEFI firmware uses its own GDT with a different layout than Zscapek's GDT.

**The Problem:**

| GDT Index | UEFI GDT | Zscapek GDT |
|-----------|------------|----------|
| 0 | Null | Null |
| 1 (0x08) | Kernel Code | Kernel Code |
| 2 (0x10) | Kernel Data | Kernel Data |
| 3 (0x18) | ? | User Data |
| 4 (0x20) | ? | User Code |
| 5 (0x28) | Kernel Code (16-bit?) | **TSS** |

If the GDT is loaded but CS is not reloaded, CS still contains the old selector value. When Zscapek's GDT is active, that selector now points to the TSS entry instead of kernel code. The next `iretq` instruction triggers a GP fault with error code 0x28.

**The Fix:**

After loading the new GDT with `lgdt`, reload CS via a far return:

```zig
fn reloadSegments() void {
    asm volatile (
        // Reload data segments
        \\mov %[ds], %%ds
        \\mov %[ds], %%es
        \\mov %[ds], %%ss
        \\xor %%eax, %%eax
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        // Reload CS via far return (push CS:RIP, then lretq)
        \\pushq %[cs]
        \\lea 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        :
        : [ds] "r" (@as(u16, KERNEL_DATA)),
          [cs] "r" (@as(u64, KERNEL_CODE)),
        : .{ .rax = true, .memory = true }
    );
}
```

**Symptoms if CS is not reloaded:**
- GP fault (#GP) with error code 0x28 (or other GDT index)
- Fault occurs at `iretq` instruction in interrupt return path
- Debugging shows CS contains unexpected selector value

## Building and Running

```bash
# Build kernel and create ISO
zig build iso

# Run in QEMU (macOS with Apple Silicon)
zig build run -Dbios=/opt/homebrew/share/qemu/edk2-x86_64-code.fd

# Or manually with UEFI and SMP (4 cores)
qemu-system-x86_64 -M q35 -m 256M -smp 4 \
  -drive file=zigk.iso,format=raw,if=none,id=boot \
  -device ide-hd,drive=boot,bus=ide.0,bootindex=1 \
  -drive if=pflash,format=raw,readonly=on,file=/path/to/edk2-x86_64-code.fd \
  -serial stdio -display none -accel tcg
```

### macOS/Apple Silicon Optimized

For better performance on Apple Silicon Macs using Hypervisor.framework:

```bash
# Using HVF acceleration (faster than TCG)
qemu-system-x86_64 -M q35 -m 256M -smp 4 \
  -drive file=zigk.iso,format=raw,if=none,id=boot \
  -device ide-hd,drive=boot,bus=ide.0,bootindex=1 \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
  -serial stdio -accel hvf -cpu host
```

Note: HVF acceleration requires x86_64 emulation layer on ARM. If issues occur, fall back to `-accel tcg`.

### USB Input Testing

To test the XHCI USB driver explicitly (bypassing default PS/2 emulation):

```bash
qemu-system-x86_64 -M q35 -m 256M \
  -drive file=zigk.iso,format=raw,if=none,id=boot \
  -device ide-hd,drive=boot,bus=ide.0,bootindex=1 \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
  -device qemu-xhci -device usb-kbd -device usb-mouse \
  -serial stdio -accel tcg
```

This configures QEMU with an XHCI controller and USB keyboard/mouse devices instead of legacy PS/2.

## Key Files

### UEFI Bootloader
- `src/boot/uefi/main.zig` - UEFI bootloader entry point
- `src/boot/uefi/loader.zig` - ELF loader with symbol table search, initrd loading
- `src/boot/uefi/memory.zig` - UEFI memory map processing
- `src/boot/uefi/graphics.zig` - GOP framebuffer initialization
- `src/boot/uefi/paging.zig` - Page table construction
- `src/boot/common/boot_info.zig` - Shared BootInfo structure

### Kernel
- `src/kernel/core/main.zig` - Kernel entry point (`_uefi_start`)
- `src/arch/x86_64/boot/linker.ld` - Kernel linker script

## UEFI Boot Troubleshooting

### Calling Convention Mismatch

**Symptom**: Kernel receives garbage values in BootInfo fields despite bootloader setting correct values.

**Cause**: UEFI executables use the **Microsoft x64 ABI** (first argument in RCX), while the kernel uses **System V AMD64 ABI** (first argument in RDI).

**Solution**: The UEFI bootloader uses inline assembly to explicitly set RDI before jumping to the kernel:

```zig
// Put boot_info pointer in RDI (System V first arg) and jump to kernel
asm volatile (
    \\mov %[bi], %%rdi
    \\jmp *%[entry]
    :
    : [bi] "r" (boot_info_ptr),
      [entry] "r" (entry_addr),
);
```

### Identity Mapping Required for Stack

**Symptom**: Double Fault immediately after VMM initialization.

**Cause**: UEFI bootloader uses a stack in low memory (identity-mapped region). When VMM creates new page tables, it must preserve the identity mapping or the stack becomes inaccessible.

**Solution**: VMM copies all 512 PML4 entries (not just 256-511) to preserve identity mapping for UEFI boot.

### Symbol Table Lookup

**Symptom**: Kernel crashes immediately on entry.

**Cause**: UEFI bootloader defaults to ELF entry point (`_start`) if `_uefi_start` symbol is not found.

**Solution**: The loader searches the ELF symbol table for `_uefi_start`. If not found, it falls back to `e_entry` which is `_start`. Ensure the kernel exports `_uefi_start`:

```zig
export fn _uefi_start(boot_info: *BootInfo.BootInfo) callconv(.c) noreturn {
    // UEFI-specific initialization
}
```

## AArch64 Boot

The UEFI bootloader supports both x86_64 and aarch64 architectures. AArch64 has significant differences in page table format and system register configuration.

### Running AArch64

```bash
# Build and run aarch64 target
zig build run-aarch64 -Dbios=/opt/homebrew/share/qemu/edk2-aarch64-code.fd
```

### Key Differences from x86_64

| Aspect | x86_64 | AArch64 |
|--------|--------|---------|
| Page Table Register | CR3 | TTBR0_EL1 / TTBR1_EL1 |
| Address Split | Single CR3 for all | TTBR0 = lower half, TTBR1 = upper half |
| Memory Attributes | Page table flags | MAIR_EL1 + AttrIndx in PTE |
| Translation Control | Implicit | TCR_EL1 explicit config |

### AArch64 Address Space Split

AArch64 uses two translation table base registers:
- **TTBR0_EL1**: Translates addresses starting with `0x0000...` (lower half, user space)
- **TTBR1_EL1**: Translates addresses starting with `0xFFFF...` (upper half, kernel)

The kernel at `0xFFFFFFFF80000000` and HHDM at `0xFFFF800000000000` both require TTBR1.

### Critical System Registers

#### MAIR_EL1 (Memory Attribute Indirection Register)
Defines memory type attributes referenced by page table entries via AttrIndx field:

```zig
const MAIR_DEVICE: u64 = 0x00;       // Index 0: Device-nGnRnE
const MAIR_NORMAL_WB: u64 = 0xFF;    // Index 1: Normal, Write-Back, R+W Allocate
const MAIR_NORMAL_NC: u64 = 0x44;    // Index 2: Normal, Non-Cacheable

const mair_value: u64 = MAIR_DEVICE | (MAIR_NORMAL_WB << 8) | (MAIR_NORMAL_NC << 16);
```

#### TCR_EL1 (Translation Control Register)
Configures translation granule and address size for both TTBR0 and TTBR1:

| Field | Value | Meaning |
|-------|-------|---------|
| T0SZ | 16 | 48-bit VA for TTBR0 |
| T1SZ | 16 | 48-bit VA for TTBR1 |
| TG0 | 0b00 | 4KB granule for TTBR0 |
| TG1 | 0b10 | 4KB granule for TTBR1 |
| IPS | 0b010 | 40-bit physical address (1TB) |
| SH0/SH1 | 0b11 | Inner Shareable |
| ORGN/IRGN | 0b01 | Write-Back, Write-Allocate |

### AArch64 Page Table Entry Format

Unlike x86_64 where flags are directly in the PTE, AArch64 uses MAIR indirection:

```zig
fn toRawAarch64(flags: PageFlags, phys_addr: u64) u64 {
    var raw: u64 = 0x3;  // Valid + Page descriptor
    if (flags.huge_page) raw = 0x1;  // Block descriptor

    // AttrIndx = 1 for normal memory (bits [4:2])
    raw |= (1 << 2);

    if (flags.no_execute) raw |= (1 << 54);  // UXN
    if (!flags.writable) raw |= (1 << 7);    // AP[2] = read-only
    if (flags.user) raw |= (1 << 6);         // AP[1] = EL0 accessible

    raw |= (1 << 10);  // AF (Access Flag) - required!
    raw |= (3 << 8);   // SH = Inner Shareable

    raw |= (phys_addr & 0x000F_FFFF_FFFF_F000);
    return raw;
}
```

**Critical Fields:**
- **AttrIndx [4:2]**: Index into MAIR_EL1 (0=Device, 1=Normal WB, 2=Normal NC)
- **AF [10]**: Access Flag - must be set or hardware faults on first access
- **SH [9:8]**: Shareability (3 = Inner Shareable for SMP)

### Loading Page Tables (AArch64)

The page table switch sequence must:
1. Temporarily disable MMU (optional but safer)
2. Configure MAIR_EL1
3. Configure TCR_EL1
4. Set TTBR0_EL1 (identity map) and TTBR1_EL1 (kernel/HHDM)
5. Invalidate TLB
6. Re-enable MMU

```zig
asm volatile (
    // Disable MMU
    \\mrs x4, sctlr_el1
    \\bic x5, x4, #1
    \\msr sctlr_el1, x5
    \\isb
    // Configure memory attributes
    \\msr mair_el1, %[mair]
    \\msr tcr_el1, %[tcr]
    // Set page table bases (same table for both in bootloader)
    \\msr ttbr0_el1, %[root]
    \\msr ttbr1_el1, %[root]
    // Invalidate TLB
    \\tlbi vmalle1
    \\dsb sy
    \\isb
    // Re-enable MMU
    \\msr sctlr_el1, x4
    \\isb
    :
    : [mair] "r" (mair_value), [tcr] "r" (tcr_value), [root] "r" (root_phys)
    : .{ .x4 = true, .x5 = true, .memory = true }
);
```

### AArch64 Boot Troubleshooting

#### Translation Fault at Kernel Entry

**Symptom**: `Synchronous Exception` with `ESR: EC 0x21` (Instruction Abort) and `Translation fault, zeroth level` at `0xFFFFFFFF800190B4`.

**Cause**: TTBR1_EL1 not configured. The bootloader only set TTBR0, but kernel addresses require TTBR1.

**Fix**: Set both TTBR0_EL1 and TTBR1_EL1 in `loadPageTables()`.

#### Memory Access Faults After Page Table Load

**Symptom**: Data abort or instruction abort after successful jump to kernel.

**Cause**: AttrIndx not set in page table entries. Default (0) means Device memory, which cannot be used for instruction fetch.

**Fix**: Set AttrIndx = 1 (bits [4:2]) for Normal Write-Back memory:
```zig
raw |= (1 << 2);  // MAIR index 1
```

#### Access Flag Fault

**Symptom**: Repeated faults at same address.

**Cause**: AF bit not set in PTE. Hardware requires AF=1.

**Fix**: Always set AF in page table entries:
```zig
raw |= (1 << 10);  // Access Flag
```

### Key Files (AArch64)

| File | Purpose |
|------|---------|
| `src/boot/uefi/paging.zig` | Dual-arch page table creation, TTBR/TCR/MAIR setup |
| `src/arch/aarch64/boot/entry.S` | Kernel entry point (`kentry`) |
| `src/arch/aarch64/boot/linker.ld` | Kernel linker script with high-half layout |