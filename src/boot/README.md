# Boot Code Organization

This directory contains the platform-independent bootloader and boot structures.

## Directory Structure

- `common/` - Shared boot structures and constants used by both bootloader and kernel (e.g., `BootInfo`)
- `uefi/` - UEFI bootloader implementation (builds to `BOOTX64.EFI`)
  - `main.zig` - Entry point and main boot logic
  - `loader.zig` - ELF and initrd loading
  - `paging.zig` - Page table construction (Identity, HHDM, Kernel)
  - `graphics.zig` - GOP initialization and framebuffer setup
  - `menu.zig` - Interactive boot menu
  - `entropy.zig` - RNG/TSC entropy for KASLR

## Architecture-Specific Boot Code

Architecture-specific boot components live in `src/arch/<arch>/boot/`:

- `src/arch/x86_64/boot/linker.ld` - Kernel linker script for x86_64
- `src/arch/x86_64/boot/smp_trampoline.S` - Assembly trampoline for AP startup

## Boot Flow

1. **UEFI Entry**: Firmware loads `BOOTX64.EFI` from `EFI/BOOT/`
2. **Pre-Configuration**:
   - Initializes serial for debug output
   - Acquires entropy for KASLR (Hardware RNG or TSC)
   - Displays **Boot Menu** for user selection/command line
3. **Loading**:
   - Loads kernel ELF from filesystem
   - Loads `initrd.tar` (if present)
4. **Environment Setup**:
   - Initializes graphics via GOP
   - Finds ACPI RSDP
   - Builds **Page Tables** (mapping Identity, HHDM @ `0xFFFF800000000000`, and Kernel)
5. **handoff**:
   - Prepares `BootInfo` (including KASLR offsets for stack, heap, and MMIO)
   - Exits Boot Services
   - Loads new CR3 and jumps to kernel entry point
6. **Kernel Start**: Kernel begins at `src/kernel/main.zig` with System V ABI

## Supporting Tools

- `tools/disk_image.zig` - Generates GPT disk images containing the FAT32 EFI system partition and required files.
