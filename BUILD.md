# Build Instructions

## Prerequisites
- **Zig Compiler**: Version 0.15.x (Master/Nightly)
- **QEMU**: For running the kernel (`qemu-system-x86_64`)
- **Xorriso**: For creating ISO images (part of `grub-common` or `xorriso`)
- **GRUB Tools**: `grub-mkrescue` (or `x86_64-elf-grub-mkrescue` on macOS)

## Quick Start (Docker)
The easiest way to build is using the provided Docker environment, which handles all dependencies.

```bash
# Build the Kernel and ISO
./tools/docker-build.sh iso

# Run Tests
./tools/docker-build.sh test
```

## Local Development

### 1. Build the Kernel (ELF)
To just compile the kernel ELF file:
```bash
zig build
```
Artifact: `zig-out/bin/kernel.elf`

### 2. Create Bootable ISO
To build the OS image (`zigk.iso`):
```bash
zig build iso
```
Artifact: `zigk.iso`

**Note**: This step performs the following:
1.  Compiles `kernel.elf`.
2.  Strips it to `kernel.bin` (Flat Binary) using `objcopy`.
3.  Creates a bootable ISO using GRUB rescue tools.

### 3. Run in QEMU
To build and immediately run the ISO in QEMU:
```bash
zig build run
```

### 4. Running Tests
To run the kernel unit tests:
```bash
zig build test
```

## Troubleshooting
**"grub-mkrescue not found"**:
- **Linux**: Install `grub-common` and `xorriso`.
- **macOS**: Install via Homebrew: `brew install x86_64-elf-grub xorriso`.

**"no multiboot header found"**:
- Ensure you are building the ISO correctly (the build script handles flat binary conversion).
- Verify `src/arch/x86_64/boot/boot32.S` and `linker.ld` address tags match.
