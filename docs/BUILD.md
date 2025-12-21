# Build Instructions

## Prerequisites
- **Zig Compiler**: Version 0.16.x (Master/Nightly)
- **QEMU**: For running the kernel (`qemu-system-x86_64`)
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
| `-Dvars=[string]` | null | Path to UEFI vars (e.g. OVMF_VARS.fd) for QEMU |
| `-Drun-iso=[bool]` | true | Boot QEMU from ISO instead of FAT directory |

Example:
```bash
zig build -Dheap-size=4194304 -Ddebug=false
```

### 2. Create Bootable ISO
To build the OS image (`zigk.iso`):
```bash
zig build iso
```
Artifact: `zigk.iso`

**Note**: This step performs the following:
1.  Compiles `kernel.elf` and `BOOTX64.EFI`.
2.  Creates a UEFI-bootable ISO with an embedded EFI System Partition.

### 3. Run in QEMU
To build and immediately run the ISO in QEMU:
```bash
zig build run
```

#### macOS / UEFI Boot
On macOS, the run step auto-detects Homebrew OVMF firmware if present. You can still pass explicit firmware paths if needed.

**Apple Silicon (Homebrew)**:
```bash
zig build run -Dbios=/opt/homebrew/share/qemu/edk2-x86_64-code.fd -Dvars=/opt/homebrew/share/qemu/edk2-x86_64-vars.fd
```

**Intel Mac (Homebrew)**:
```bash
zig build run -Dbios=/usr/local/share/qemu/edk2-x86_64-code.fd -Dvars=/usr/local/share/qemu/edk2-x86_64-vars.fd
```

#### FAT Directory Boot (Legacy)
To boot directly from the `efi_root` directory instead of the ISO:
```bash
zig build run -Drun-iso=false
```

#### Common Run Flags
| Flag | Default | Description |
|------|---------|-------------|
| `-Drun-iso=[bool]` | true | Boot from `zigk.iso` (UEFI El Torito). Set false to boot from `efi_root` FAT directory. |
| `-Dbios=[string]` | auto | Path to UEFI firmware code image (OVMF). On macOS, auto-detects Homebrew `edk2-x86_64-code.fd`. |
| `-Dvars=[string]` | auto | Path to UEFI vars image. On macOS, auto-detects Homebrew `edk2-x86_64-vars.fd`. |
| `-Ddisplay=[string]` | default | QEMU display backend: `default`, `sdl`, `gtk`, `cocoa`, `none`. |
| `-Dusb-hub=[bool]` | false | Attach a USB hub to XHCI and connect the storage device through it. |

Examples:
```bash
# Headless serial-only output
zig build run -Ddisplay=none

# Boot from FAT directory instead of ISO
zig build run -Drun-iso=false

# Attach USB hub (useful for some USB storage setups)
zig build run -Dusb-hub=true

# Explicit OVMF paths (overrides auto-detection)
zig build run -Dbios=/path/to/OVMF_CODE.fd -Dvars=/path/to/OVMF_VARS.fd
```

#### Troubleshooting QEMU Boot
- **BdsDxe: failed to load Boot0 / Not Found**: OVMF likely cannot see the ISO. Use full OVMF code+vars images and ISO boot: `zig build run -Drun-iso=true -Dbios=... -Dvars=...`.
- **No bootable device**: Ensure OVMF firmware paths are valid. On macOS, verify Homebrew has `edk2-x86_64-code.fd` and `edk2-x86_64-vars.fd`.
- **UEFI shell opens instead of booting**: Confirm `BOOTX64.EFI` is present in the ISO (`zigk.iso`) and in the FAT directory (`zig-out/efi_root/EFI/BOOT/BOOTX64.EFI`), then rebuild with `zig build iso`.

### 4. Running Tests
To run the kernel unit tests:
```bash
zig build test
```

## Troubleshooting
**ISO creation fails**:
- Ensure `xorriso` is installed: `brew install xorriso` (macOS) or `apt install xorriso` (Linux).
- Verify the UEFI bootloader builds successfully (`zig-out/bin/BOOTX64.EFI`).
