# Boot Process Documentation

## Overview

ZigK uses the **Limine Bootloader** (v5.x protocol) for booting. The kernel is compiled as a standard 64-bit ELF executable and loaded into the higher half of virtual memory.

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
   - Sets up Memory Management (PMM/VMM/Heap)
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
| User Stack | `0xF0000000` (top) | Default user stack location |

## Limine Configuration

The bootloader is configured via `limine.cfg`:

```ini
TIMEOUT=5
SERIAL=yes
VERBOSE=yes

:ZigK Microkernel
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

## Building and Running

```bash
# Build kernel and create ISO
zig build iso

# Run in QEMU (macOS with Apple Silicon)
zig build run -Dbios=/opt/homebrew/share/qemu/edk2-x86_64-code.fd

# Or manually with UEFI
qemu-system-x86_64 -M q35 -m 256M -cdrom zigk.iso \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
  -serial stdio -display none -accel tcg
```

## Key Files

- `limine.cfg` - Bootloader configuration
- `src/lib/limine.zig` - Limine protocol bindings
- `src/kernel/main.zig` - Kernel entry point
- `src/arch/x86_64/boot/linker.ld` - Kernel linker script
