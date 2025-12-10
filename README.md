# ZigK

A minimal x86_64 microkernel written in Zig, using the Limine bootloader.

## Features

- Limine boot protocol (v5.x)
- Physical Memory Manager (bitmap allocator with refcounting)
- Virtual Memory Manager (4-level paging)
- Kernel heap (thread-safe, coalescing free-list)
- GDT/IDT/PIC initialization
- PS/2 keyboard driver
- Serial console output (COM1)
- Round-robin scheduler with thread support
- ELF loader for userspace programs
- Syscall interface (Linux-compatible numbers)

## Building and Running

See [BUILD.md](BUILD.md) for detailed instructions on:
- Setting up the development environment
- Building the kernel
- Creating bootable ISOs
- Running in QEMU (including Apple Silicon support)

## Boot Process

See [BOOT.md](BOOT.md) for technical details on:
- Limine protocol implementation
- Boot process flow
- Memory layout

### Quick Start

```bash
# Build and create ISO
zig build iso

# Run in QEMU (macOS Apple Silicon)
zig build run -Dbios=/opt/homebrew/share/qemu/edk2-x86_64-code.fd

# Run in QEMU (macOS Intel)
zig build run -Dbios=/usr/local/share/qemu/edk2-x86_64-code.fd
```

### UEFI Booting

The kernel requires UEFI firmware on macOS. Pass the path to your OVMF/EDK2 firmware:

```bash
qemu-system-x86_64 -M q35 -m 256M -cdrom zigk.iso \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
  -serial stdio -accel tcg
```

## Docker Build (Recommended)

Docker provides a consistent build environment across all platforms and handles all dependencies automatically.

See [BUILD.md](BUILD.md#docker-build-recommended) for detailed instructions.

## Project Structure

See [FILESYSTEM.md](FILESYSTEM.md) for detailed structure.

## Architecture

ZigK follows a strict HAL (Hardware Abstraction Layer) design:

- **src/arch/** - Only location for inline assembly and hardware access
- **src/kernel/** - Architecture-agnostic kernel code
- **src/drivers/** - Bus-agnostic device drivers

All kernel code accesses hardware through the `hal` module interface.

### Limine Boot Process

1. BIOS/UEFI loads Limine bootloader
2. Limine reads `limine.cfg` and loads kernel ELF + modules
3. Limine sets up 64-bit long mode with HHDM (Higher Half Direct Map)
4. Limine jumps to kernel entry point `_start` in Zig
5. Kernel initializes using Limine memory map and module info

## InitRD (Initial RAM Disk)

The kernel supports loading files from a TAR-format initial ramdisk. This allows userspace programs to access configuration files, scripts, or other resources at boot time.

### Creating an InitRD

```bash
# Create a directory with files to include
mkdir -p initrd_contents/etc
echo "root:x:0:0:root:/root:/bin/sh" > initrd_contents/etc/passwd

# Create USTAR TAR archive (required format)
tar --format=ustar -cvf initrd.tar -C initrd_contents .
```

### Adding InitRD to Boot

1. Copy `initrd.tar` to `iso_root/boot/`:
   ```bash
   cp initrd.tar iso_root/boot/initrd.tar
   ```

2. Add module entry to `limine.cfg`:
   ```
   MODULE_PATH=boot:///boot/initrd.tar
   MODULE_CMDLINE=initrd
   ```

3. Rebuild and run:
   ```bash
   zig build run -Dbios=/opt/homebrew/share/qemu/edk2-x86_64-code.fd
   ```

The kernel auto-detects modules with "initrd" or ".tar" in their cmdline/path and initializes the filesystem.

## License

MIT
