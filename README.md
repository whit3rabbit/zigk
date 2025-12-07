# ZigK

A minimal x86_64 microkernel written in Zig, using GRUB2 with Multiboot2 protocol.

## Features

- Multiboot2 boot protocol via GRUB2
- Physical Memory Manager (bitmap allocator)
- Virtual Memory Manager (4-level paging)
- Kernel heap (thread-safe, coalescing free-list)
- GDT/IDT/PIC initialization
- PS/2 keyboard driver
- Serial console output (COM1)
- Round-robin scheduler with thread support

## Building an Running

See [BUILD.md](BUILD.md) for detailed instructions on:
- Setting up the development environment
- Building the kernel
- Creating bootable ISOs
- Running in QEMU (including Apple Silicon support)

## Boot Process

See [BOOT.md](BOOT.md) for technical details on:
- Multiboot2 protocol implementation
- Boot process flow
- Header structures and Flat Binary loading strategy
- Boot time: 1-2 seconds instead of instantaneous
- Slight input latency possible

**Required flags** (already set in build.zig):
```
-accel tcg    # Force software emulation
```

If you see `invalid accelerator hvf`, the TCG flag is missing.

### UEFI Booting (macOS fix)
If you get "No bootable device", your ISO is likely UEFI-only (common on macOS). Pass the path to your OVMF firmware:

```bash
# Example for Homebrew (Intel)
zig build run -Dbios=/usr/local/share/qemu/edk2-x86_64-code.fd

# Example for Homebrew (Apple Silicon)
zig build run -Dbios=/opt/homebrew/share/qemu/edk2-x86_64-code.fd
```

## Docker Build (Recommended)

Docker provides a consistent build environment across all platforms and handles all dependencies automatically.

### Quick Start

See [BUILD.md](BUILD.md#docker-build-recommended) for detailed instructions.

## Project Structure

See [FILESYSTEM.md](FILESYSTEM.md) for detailed structure.

## Architecture

ZigK follows a strict HAL (Hardware Abstraction Layer) design:

- **src/arch/** - Only location for inline assembly and hardware access
- **src/kernel/** - Architecture-agnostic kernel code
- **src/drivers/** - Bus-agnostic device drivers

All kernel code accesses hardware through the `hal` module interface.

## Architecture Notes

### Multiboot2 Boot Process

ZigK uses GRUB2 with the Multiboot2 protocol. The boot process:

1. GRUB2 loads kernel at physical address 1MB (0x100000)
2. GRUB2 calls 32-bit entry point `_start32` with Multiboot2 info in EBX
3. Bootstrap code (`boot32.S`) sets up page tables:
   - Identity map: 0x00000000 -> 0x00000000 (first 4GB)
   - Higher-half: 0xFFFFFFFF80000000 -> 0x00000000 (kernel)
   - HHDM: 0xFFFF800000000000 -> 0x00000000 (physical memory access)
4. Bootstrap enables long mode and jumps to 64-bit `_start` in Zig
5. Kernel initializes using Multiboot2 memory map

This approach works around a Zig 0.15.x linker regression where virtual addresses in linker scripts are ignored. Multiboot2 loads at physical addresses, allowing the kernel to set up its own virtual memory mapping.

## License

MIT
