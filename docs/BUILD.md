# Build Instructions

## Prerequisites
- **Zig Compiler**: Version 0.16.x (Master/Nightly)
- **QEMU**: For running the kernel (`qemu-system-x86_64` or `qemu-system-aarch64`)
- **Xorriso**: For creating ISO images

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
Artifact: `zig-out/bin/kernel-x86_64.elf` (or `kernel-aarch64.elf` for AArch64)

### Build Configuration
You can customize the build using `-D` flags with `zig build`.

| Option | Default | Description |
|--------|---------|-------------|
| `-Darch=[arch]` | x86_64 | Target architecture: `x86_64` or `aarch64` |
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
| `-Ddefault-boot=[string]` | "shell" | Default boot target: `shell` or `doom` |
| `-Dboot-logo=[bool]` | true | Show animated boot logo during init |
| `-Dbios=[string]` | auto | Path to BIOS/UEFI firmware (e.g. OVMF.fd) for QEMU |
| `-Dvars=[string]` | auto | Path to UEFI vars (e.g. OVMF_VARS.fd) for QEMU |
| `-Drun-iso=[bool]` | false | Boot QEMU from ISO instead of GPT disk image |
| `-Ddisplay=[string]` | "default" | QEMU display backend: `default`, `sdl`, `gtk`, `cocoa`, `none` |
| `-Dusb-hub=[bool]` | false | Attach USB hub to XHCI and connect storage through it |
| `-Dnvme=[bool]` | false | Add NVMe storage device for testing |
| `-Daudio=[string]` | "none" | QEMU audio backend: `none`, `coreaudio`, `pa`, `file` |
| `-Dallow-weak-entropy=[bool]` | false | Allow weak entropy for ASLR (TESTING ONLY) |

Example:
```bash
zig build -Dheap-size=4194304 -Ddebug=false
```

### 2. Create Bootable Images
Two boot methods are available: ISO and GPT disk image.

#### ISO Image (El Torito)
```bash
zig build iso                    # Default (x86_64)
zig build iso -Darch=x86_64      # Explicit x86_64
zig build iso -Darch=aarch64     # AArch64/ARM64
```
Artifact: `zigk.iso`

This creates a UEFI-bootable ISO with an embedded EFI System Partition using El Torito boot.

**Convenience aliases:**
```bash
zig build iso-x86_64             # Build x86_64 ISO
zig build iso-aarch64            # Build aarch64 ISO
```

**Note**: Some UEFI firmware implementations may not correctly detect El Torito EFI boot entries. If `zig build run` drops into the UEFI shell instead of booting, use the GPT disk image method below.

#### GPT Disk Image (Default)
```bash
zig build run                    # Uses GPT disk by default
```
Artifact: `disk.img`

This creates a GPT-partitioned disk image with an EFI System Partition. This is the default boot method and is more reliable across different UEFI firmware implementations.

**Note**: The `tools/disk_image.zig` tool generates the GPT disk from `esp_part.img` (a FAT filesystem). The disk includes:
- Protective MBR (sector 0)
- GPT header and partition table
- EFI System Partition with `EFI/BOOT/BOOTX64.EFI` (or `BOOTAA64.EFI`) and `kernel-<arch>.elf`

### 3. Run in QEMU
To build and immediately run the kernel in QEMU (uses GPT disk by default):
```bash
zig build run                    # Default (x86_64)
zig build run -Darch=x86_64      # Explicit x86_64
zig build run -Darch=aarch64     # AArch64/ARM64
```

**Convenience aliases:**
```bash
zig build run-x86_64             # Build and run x86_64 in QEMU
zig build run-aarch64            # Build and run aarch64 in QEMU
```

#### macOS / UEFI Boot
On macOS, the run step auto-detects Homebrew UEFI firmware if present. You can still pass explicit firmware paths if needed.

**x86_64 on Apple Silicon (Homebrew)**:
```bash
zig build run -Dbios=/opt/homebrew/share/qemu/edk2-x86_64-code.fd -Dvars=/opt/homebrew/share/qemu/edk2-x86_64-vars.fd
```

**x86_64 on Intel Mac (Homebrew)**:
```bash
zig build run -Dbios=/usr/local/share/qemu/edk2-x86_64-code.fd -Dvars=/usr/local/share/qemu/edk2-x86_64-vars.fd
```

**AArch64 on Apple Silicon (Homebrew)**:
```bash
zig build run -Darch=aarch64 -Dbios=/opt/homebrew/share/qemu/edk2-aarch64-code.fd -Dvars=/opt/homebrew/share/qemu/edk2-arm-vars.fd
```

#### ISO Boot
To boot from the ISO image instead of the default GPT disk:
```bash
zig build run -Drun-iso=true
```

#### Common Run Flags
| Flag | Default | Description |
|------|---------|-------------|
| `-Drun-iso=[bool]` | false | Boot from `zigk.iso` (UEFI El Torito). Default boots from `disk.img` (GPT Disk Image). |
| `-Dbios=[string]` | auto | Path to UEFI firmware code image. Auto-detects Homebrew paths on macOS. |
| `-Dvars=[string]` | auto | Path to UEFI vars image. Auto-detects Homebrew paths on macOS. |
| `-Ddisplay=[string]` | default | QEMU display backend: `default`, `sdl`, `gtk`, `cocoa`, `none`. |
| `-Dusb-hub=[bool]` | false | Attach a USB hub to XHCI and connect storage through it. |
| `-Dnvme=[bool]` | false | Add NVMe storage device for testing. |
| `-Daudio=[string]` | none | QEMU audio backend: `none`, `coreaudio`, `pa`, `file`. |

Examples:
```bash
# Headless serial-only output
zig build run -Ddisplay=none

# Boot from ISO instead of default GPT disk
zig build run -Drun-iso=true

# Run AArch64 build
zig build run -Darch=aarch64

# Attach USB hub (useful for some USB storage setups)
zig build run -Dusb-hub=true

# Test with NVMe storage device
zig build run -Dnvme=true

# Explicit UEFI firmware paths (overrides auto-detection)
zig build run -Dbios=/path/to/OVMF_CODE.fd -Dvars=/path/to/OVMF_VARS.fd
```

#### Troubleshooting QEMU Boot
- **BdsDxe: failed to load Boot0 / Not Found**: El Torito EFI boot not recognized. Use the default GPT disk image (don't pass `-Drun-iso=true`).
- **No bootable device**: Ensure UEFI firmware paths are valid. On macOS, verify Homebrew has the appropriate edk2 firmware files installed.
- **UEFI shell opens instead of booting**: If using `-Drun-iso=true`, the ISO El Torito boot may not be recognized by some UEFI firmware. Use the default GPT disk boot instead. Alternatively, ensure `BOOTX64.EFI` (or `BOOTAA64.EFI`) is present and rebuild with `zig build iso`.
- **disk.img has invalid MBR**: If `file disk.img` shows "data" instead of GPT, rebuild the disk_image tool: `rm -rf .zig-cache && zig build run`. The tool requires packed struct handling for correct MBR layout.

### 4. Running Tests
To run the kernel unit tests:
```bash
zig build test
```

## Troubleshooting
**ISO creation fails**:
- Ensure `xorriso` is installed: `brew install xorriso` (macOS) or `apt install xorriso` (Linux).
- Verify the UEFI bootloader builds successfully (`zig-out/bin/BOOTX64.EFI` or `BOOTAA64.EFI` for AArch64).
