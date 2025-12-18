# Boot Process Documentation

## Overview

Zscapek uses the **Limine Bootloader** (v5.x protocol) for booting. The kernel is compiled as a standard 64-bit ELF executable and loaded into the higher half of virtual memory.

**Developer Reference**: 

For detailed byte-level layouts, struct alignments, and hardware interface specifications, see **[BOOT_ARCHITECTURE.md](BOOT_ARCHITECTURE.md)**.

## Boot Flow

1. **BIOS/UEFI** hands control to Limine.
2. **Limine** reads `limine.cfg` and locates the kernel and modules.
3. **Limine** loads:
   - `kernel.elf` - The OS kernel
   - `shell.elf` - Userland shell module
   - (Optional) `initrd.tar` - Filesystem module
4. **Limine** sets up:
   - 64-bit Long Mode with paging enabled
   - Higher Half Direct Map (HHDM) for physical memory access
   - Framebuffer (if available)
   - Memory map
5. **Limine** jumps directly to the kernel entry point `_start` defined in `src/kernel/main.zig`.
6. **Kernel Initialization**:
   - Validates Limine protocol requests (HHDM, Framebuffer, Memory Map)
   - Initializes HAL (GDT/IDT/Serial/PIC)
   - Initializes SMP (brings up Application Processors)
   - Sets up Memory Management (PMM/VMM/Heap)
   - Registers demand paging handler for lazy memory allocation
   - Initializes VDSO (Virtual Dynamic Shared Object)
   - Initializes scheduler and creates idle thread
   - Scans modules to load the init process (shell or httpd)
   - Starts the scheduler

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

- `src/kernel/user_vmm.zig` - VMA management and `handlePageFault()`
- `src/arch/x86_64/interrupts.zig` - Page fault dispatch to demand paging handler
- `src/kernel/main.zig` - Handler registration via `setPageFaultHandler()`

## Address Space Layout Randomization (ASLR)

Zscapek implements full ASLR to randomize critical memory regions per-process, mitigating exploitation techniques that rely on predictable addresses (ROP, ret2libc, etc.).

### Randomized Regions

| Component | Base Address | Entropy | Range |
|-----------|--------------|---------|-------|
| Stack top | `0x7FFF_FFFF_F000` | 11 bits | 8MB (2048 pages) |
| PIE base | `0x5555_5000_0000` | 16 bits | 4GB (64KB granularity) |
| mmap base | `0x1000_0000_0000` | 20 bits | 4TB |
| Heap gap | After ELF end | 8 bits | 1MB (256 pages) |
| VDSO | `0x7FFF_E000_0000` | 12 bits | 16MB |

### Behavior

- **Process creation**: New ASLR offsets generated via `aslr.generateOffsets()`
- **Fork**: Child inherits parent's ASLR layout (same address space)
- **Execve**: New ASLR offsets generated (replaces address space)

### Entropy Source

ASLR uses the kernel PRNG (xoroshiro128+) seeded from hardware entropy (RDRAND/RDSEED) at boot. The `prng.range()` function uses rejection sampling to avoid modulo bias.

### Key Files

- `src/kernel/aslr.zig` - ASLR offset generation and configuration
- `src/kernel/process.zig` - Per-process `aslr_offsets` field
- `src/kernel/elf.zig` - Accepts randomized stack_top and pie_base
- `src/kernel/user_vmm.zig` - Randomized mmap_base per address space

## Limine Configuration

The bootloader is configured via `limine.cfg`:

```ini
TIMEOUT=5
SERIAL=yes
VERBOSE=yes

:Zscapek Microkernel
PROTOCOL=limine
KERNEL_PATH=boot:///boot/kernel.elf
MODULE_PATH=boot:///boot/modules/shell.elf
MODULE_CMDLINE=shell
```

## Limine Requests

The kernel declares Limine requests in `src/kernel/main.zig`:

- **Base Revision** - Protocol version check
- **HHDM Request** - Higher Half Direct Map offset
- **Memory Map Request** - Physical memory regions
- **Framebuffer Request** - Display buffer
- **Module Request** - Loaded modules (shell, httpd, initrd)
- **Kernel Address Request** - Kernel physical/virtual base

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

The ELF loader (`src/kernel/elf.zig`) must handle translation failures explicitly. Silent failures in `copyToUserspace` can leave mapped pages zeroed, causing immediate crashes when userspace executes.

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
    qemu-system-x86_64 -M q35 -m 128M -cdrom zscapek.iso \
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
    *   **Fix**: The GDT initialization must reload CS via far return after loading the new GDT. Limine bootloader uses a different GDT layout where kernel code may be at a different index than Zscapek's GDT. See "GDT Initialization and CS Reload" section below.
*   **"Integer Overflow" Panic**:
    *   **Cause**: Zig's safety checks (enabled in Debug/ReleaseSafe) catch overflows that other languages ignore.
    *   **Hint**: Check loop counters (e.g., `u3` cannot hold 8) and bitwise operations on differing integer widths (e.g., `~u32` inside `u64`). Use `+%` for wrapping addition if intentional.
*   **Keyboard/Mouse Not Working**:
    *   **Check**: Is the VM/hardware using PS/2 or USB input?
    *   **PS/2 (QEMU default)**: The kernel sends `0xF4` (Enable Scanning) to the keyboard during initialization (`src/drivers/keyboard.zig:410`). If no response, the 8042 controller may not be present.
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

When the kernel loads its own GDT, it must also reload the CS register. The Limine bootloader uses its own GDT with a different layout than Zscapek's GDT.

**The Problem:**

| GDT Index | Limine GDT | Zscapek GDT |
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
qemu-system-x86_64 -M q35 -m 256M -smp 4 -cdrom zscapek.iso \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
  -serial stdio -display none -accel tcg
```

### macOS/Apple Silicon Optimized

For better performance on Apple Silicon Macs using Hypervisor.framework:

```bash
# Using HVF acceleration (faster than TCG)
qemu-system-x86_64 -M q35 -m 256M -smp 4 -cdrom zscapek.iso \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
  -serial stdio -accel hvf -cpu host
```

Note: HVF acceleration requires x86_64 emulation layer on ARM. If issues occur, fall back to `-accel tcg`.

### USB Input Testing

To test the XHCI USB driver explicitly (bypassing default PS/2 emulation):

```bash
qemu-system-x86_64 -M q35 -m 256M -cdrom zscapek.iso \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
  -device qemu-xhci -device usb-kbd -device usb-mouse \
  -serial stdio -accel tcg
```

This configures QEMU with an XHCI controller and USB keyboard/mouse devices instead of legacy PS/2.

## Key Files

- `limine.cfg` - Bootloader configuration
- `src/lib/limine.zig` - Limine protocol bindings
- `src/kernel/main.zig` - Kernel entry point
- `src/arch/x86_64/boot/linker.ld` - Kernel linker script