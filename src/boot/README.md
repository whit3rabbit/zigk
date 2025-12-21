# Boot Code Organization

This directory contains the platform-independent bootloader and boot structures.

## Directory Structure

- `common/` - Shared boot structures and constants used by both bootloader and kernel
- `uefi/` - UEFI bootloader implementation (builds to BOOTX64.EFI)

## Architecture-Specific Boot Code

Architecture-specific boot components live in `src/arch/<arch>/boot/`:

- `src/arch/x86_64/boot/linker.ld` - Kernel linker script for x86_64

## Boot Flow

1. UEFI firmware loads `BOOTX64.EFI` from `EFI/BOOT/`
2. UEFI bootloader (`src/boot/uefi/main.zig`):
   - Initializes graphics via GOP
   - Sets up initial page tables
   - Loads kernel ELF from initrd
   - Prepares BootInfo structure
   - Jumps to kernel entry point
3. Kernel starts at `src/kernel/main.zig` with BootInfo
