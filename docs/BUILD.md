# Build Instructions

## Prerequisites
- **Zig Compiler**: Version 0.16.x (Master/Nightly)
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

### Build Configuration
You can customize the build using `-D` flags with `zig build`.

| Option | Default | Description |
|--------|---------|-------------|
| `-Dversion=[string]` | "0.1.0" | Kernel version string |
| `-Dname=[string]` | "Zscapek" | Kernel name |
| `-Dstack-size=[int]` | 16384 | Default thread stack size in bytes |
| `-Dheap-size=[int]` | 2097152 | Kernel heap size in bytes (2MB) |
| `-Dmax-threads=[int]` | 64 | Maximum number of threads |
| `-Dtimer-hz=[int]` | 100 | Timer frequency in Hz |
| `-Dserial-baud=[int]` | 115200 | Serial port baud rate |
| `-Ddebug=[bool]` | true | Enable debug output |
| `-Ddebug-memory=[bool]` | false | Enable verbose memory allocation logging |
| `-Ddebug-scheduler=[bool]` | false | Enable verbose scheduler logging |
| `-Ddebug-network=[bool]` | false | Enable verbose network logging |
| `-Dbios=[string]` | null | Path to BIOS/UEFI firmware (e.g. OVMF.fd) for QEMU |

Example:
```bash
zig build -Dheap-size=4194304 -Ddebug=false
```

### 2. Create Bootable ISO
To build the OS image (`zscapek.iso`):
```bash
zig build iso
```
Artifact: `zscapek.iso`

**Note**: This step performs the following:
1.  Compiles `kernel.elf`.
2.  Strips it to `kernel.bin` (Flat Binary) using `objcopy`.
3.  Creates a bootable ISO using GRUB rescue tools.

### 3. Run in QEMU
To build and immediately run the ISO in QEMU:
```bash
zig build run
```

#### macOS / UEFI Boot
On macOS, if you encounter "No bootable device", it is likely because the generated ISO is UEFI-only. You must explicitly pass the path to the OVMF firmware (found in your QEMU installation).

**Apple Silicon (Homebrew)**:
```bash
zig build run -Dbios=/opt/homebrew/share/qemu/edk2-x86_64-code.fd
```

**Intel Mac (Homebrew)**:
```bash
zig build run -Dbios=/usr/local/share/qemu/edk2-x86_64-code.fd
```

### 4. Running Tests
To run the kernel unit tests:
```bash
zig build test
```

## Troubleshooting
**ISO creation fails**:
- Ensure `xorriso` is installed: `brew install xorriso` (macOS) or `apt install xorriso` (Linux).
- Check that the `limine/` directory contains the bootloader binaries.
