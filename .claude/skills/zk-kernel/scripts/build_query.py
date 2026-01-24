#!/usr/bin/env python3
"""
Build System Query Tool for zk kernel.

Query build configuration, module wiring, targets, and QEMU options.

Usage:
    python build_query.py modules        # Module dependency graph
    python build_query.py targets        # x86_64-freestanding targets
    python build_query.py options        # Build options (-D flags)
    python build_query.py artifacts      # Output paths (kernel.elf, ISO, disk.img)
    python build_query.py disk_image     # GPT disk image tool (tools/disk_image.zig)
    python build_query.py qemu           # QEMU run options
    python build_query.py commands       # Common build commands
"""

import sys

PATTERNS = {
    "modules": """
## Module Dependency Graph

Location: build.zig (createModule + addImport)

### Core Modules
```
config     <- Build options (version, heap_size, etc.)
uapi       <- Syscall numbers (src/uapi/syscalls/root.zig), errno codes
limine     <- Boot protocol parsing (src/lib/limine.zig)
hal        <- Hardware Abstraction Layer (src/arch/root.zig)
sync       <- Spinlock, synchronization (src/kernel/sync.zig)
```

### Memory Subsystem
```
pmm        <- Physical Memory Manager
vmm        <- Virtual Memory Manager (depends: hal, pmm)
heap       <- Kernel Heap Allocator (depends: slab)
slab       <- Slab Allocator (depends: pmm)
user_vmm   <- Userspace mmap/munmap (depends: vmm, pmm, heap)
```

### Scheduler & Threads
```
thread     <- Thread management (depends: hal, pmm, vmm, heap)
sched      <- Scheduler (depends: thread, sync, hal)
io         <- Kernel Async I/O reactor (depends: sched, sync, uapi)
```

### Drivers (in src/drivers/)
```
pci        <- PCIe ECAM enumeration (depends: hal, vmm, acpi)
ahci       <- SATA storage (depends: pci, pmm, vmm, io)
e1000e     <- Intel NIC (depends: pci, net, sched, heap)
usb        <- XHCI/EHCI (depends: pci, pmm, vmm, io)
keyboard   <- PS/2 (depends: hal, ring_buffer, io)
virtio     <- VirtIO base (depends: pmm, hal)
video      <- Framebuffer/VirtIO-GPU (depends: virtio, pci)
audio      <- AC97 (depends: pci, pmm, vmm)
hid        <- USB HID class (depends: usb)
```

### Network Stack
```
net        <- Full stack (depends: hal, uapi, prng, heap, io)
           Includes: ethernet, ipv4, tcp, udp, icmp, arp
```

### Filesystem
```
fs         <- VFS layer (depends: fd, heap, ahci, io)
```

### Import Pattern
```zig
// In kernel code, use package names from build.zig:
const hal = @import("hal");
const uapi = @import("uapi");
const console = @import("console");
const pmm = @import("pmm");
const sched = @import("sched");
```
""",

    "targets": """
## Build Targets

### Kernel Target
```zig
const kernel_target = b.resolveTargetQuery(.{
    .cpu_arch = .x86_64,
    .os_tag = .freestanding,
    .abi = .none,
    .cpu_features_sub = std.Target.x86.featureSet(&.{
        .mmx, .sse, .sse2, .avx, .avx2,  // Disabled for kernel
    }),
    .cpu_features_add = std.Target.x86.featureSet(&.{
        .soft_float,  // No FPU in kernel mode
    }),
});
```

**Why no SSE/AVX in kernel?**
- Prevents FPU register clobbering during interrupts
- Kernel context switch doesn't save FPU state
- User processes can use FPU (saved on context switch)

### User Target
```zig
const user_target = b.resolveTargetQuery(.{
    .cpu_arch = .x86_64,
    .os_tag = .freestanding,
    .abi = .none,
    // SSE enabled (default)
});
```

User programs CAN use SSE/AVX. FPU state saved on syscall entry.

### Output Format
- Kernel: ELF64, linked at 0xFFFF_FFFF_8000_0000
- User: ELF64 PIE, ASLR-randomized load address
""",

    "options": """
## Build Options

### Build-time Configuration
```bash
zig build -Dversion="1.0.0"          # Kernel version string
zig build -Dname="MyKernel"          # Kernel name
zig build -Dstack-size=32768         # Thread stack (bytes, default 16KB)
zig build -Dheap-size=4194304        # Kernel heap (bytes, default 2MB)
zig build -Dmax-threads=128          # Max threads (default 64)
zig build -Dtimer-hz=1000            # Timer frequency (default 100)
zig build -Dserial-baud=9600         # Serial baud rate (default 115200)
```

### Debug Options
```bash
zig build -Ddebug=false              # Disable debug output
zig build -Ddebug-memory=true        # Verbose memory logging
zig build -Ddebug-scheduler=true     # Verbose scheduler logging
zig build -Ddebug-network=true       # Verbose network logging
```

### Optimization Levels
```bash
zig build -Doptimize=Debug           # Debug build (default)
zig build -Doptimize=ReleaseSafe     # Release with safety checks
zig build -Doptimize=ReleaseFast     # Maximum optimization
zig build -Doptimize=ReleaseSmall    # Size optimization
```

### Accessing Config in Code
```zig
const config = @import("config");
const version = config.version;
const heap_size = config.heap_size;
if (config.debug_enabled) {
    console.printf("Debug: ...", .{});
}
```
""",

    "artifacts": """
## Build Artifacts

### Output Locations
```
zig-out/bin/
├── kernel.elf          # Main kernel binary
├── bootx64.efi         # UEFI bootloader
├── disk_image          # GPT disk image generator tool
├── shell.elf           # Shell program
├── httpd.elf           # HTTP server
├── doom.elf            # Doom port
├── netstack            # Network stack test
├── test_stdio          # Test programs
├── ...
├── uart_driver.elf     # Userspace drivers
├── ps2_driver.elf
├── virtio_net_driver.elf
└── virtio_blk_driver.elf

zk.iso                 # Bootable ISO (El Torito)
disk.img                 # GPT disk image (recommended)
esp_part.img             # EFI System Partition (FAT16)
iso_root/                # ISO staging directory
├── kernel.elf
├── initrd.tar           # Initial ramdisk (USTAR)
├── efi.img              # Embedded ESP for ISO
└── EFI/BOOT/
    └── BOOTX64.EFI      # UEFI bootloader
```

### Boot Images
- **disk.img (GPT)**: Recommended. Created by tools/disk_image.zig
- **zk.iso (El Torito)**: May not work with all UEFI firmware

### InitRD Format
- USTAR tarball created from initrd_contents/
- Mounted at / by init_proc
- Read-only filesystem
""",

    "disk_image": """
## GPT Disk Image Tool

Location: `tools/disk_image.zig`
Output: `disk.img`

### Purpose
Generates a GPT-partitioned disk image with an EFI System Partition for UEFI boot.
More reliable than ISO El Torito boot across UEFI firmware implementations.

### Usage
```bash
# Automatic (via build system)
zig build run -Drun-iso=false

# Manual
./zig-out/bin/disk_image esp_part.img disk.img
```

### Disk Layout
```
Sector 0:    Protective MBR
             - Partition 0: Type 0xEE (GPT protective)
             - Signature: 0x55AA at bytes 510-511

Sector 1:    GPT Header
             - Signature: "EFI PART"
             - Partition entries at LBA 2

Sector 2+:   GPT Partition Entries (128 entries)

LBA 2048+:   EFI System Partition (FAT16)
             - /EFI/BOOT/BOOTX64.EFI
             - /kernel.elf
             - /startup.nsh
```

### Common Issues
**MBR signature missing (offset 510-511 != 0x55AA)**:
- Cause: extern struct alignment padding
- Fix: Use packed struct or byte array for MBR layout
- Verify: `xxd -s 510 -l 2 disk.img` should show `55aa`

**UEFI drops to shell**:
- Check: `file disk.img` should NOT show just "data"
- Fix: `rm -rf .zig-cache && zig build run -Drun-iso=false`
""",

    "qemu": """
## QEMU Options

### Basic Run
```bash
zig build run                        # Build and run in QEMU
```

### Display Options
```bash
zig build run -Ddisplay=none         # Headless (serial only)
zig build run -Ddisplay=sdl          # SDL window
zig build run -Ddisplay=gtk          # GTK window
zig build run -Ddisplay=cocoa        # macOS native
```

### UEFI Boot
```bash
zig build run -Dbios=/path/to/OVMF.fd
```

### USB Hub Testing
```bash
zig build run -Dusb-hub=true         # Attach USB hub to XHCI
```

### macOS Apple Silicon
TCG acceleration is required (no KVM):
```bash
zig build run -Dqemu-args="-accel tcg,thread=multi -cpu max"
```

### Manual QEMU
```bash
qemu-system-x86_64 \\
    -M q35 \\
    -m 256M \\
    -cdrom zk.iso \\
    -device qemu-xhci,id=xhci \\
    -device usb-storage,drive=stick,bus=xhci.0 \\
    -drive id=stick,if=none,format=raw,file=disk.img \\
    -netdev user,id=net0 \\
    -device e1000e,netdev=net0 \\
    -serial stdio \\
    -display none
```

### Common Debug Flags
```bash
-d int              # Log interrupts
-d cpu_reset        # Log CPU resets
-D /tmp/qemu.log    # Write debug to file
-s -S               # GDB stub on :1234, wait for connect
```
""",

    "commands": """
## Common Build Commands

### Build Only
```bash
zig build                    # Build kernel + userland
zig build kernel             # Build kernel only (if step exists)
```

### Create ISO
```bash
zig build iso                # Build and create bootable ISO
```

### Run in QEMU
```bash
zig build run                # Build ISO and run in QEMU
zig build run -Ddisplay=none # Headless mode (serial output)
```

### Run Tests
```bash
zig build test               # Run unit tests
```

### Clean Build
```bash
rm -rf zig-cache zig-out     # Clean all build artifacts
rm -rf iso_root zk.iso  # Clean ISO artifacts
```

### Check Syntax
```bash
zig build --dry-run          # Check build script without running
```

### Cross-reference
```bash
zig build -Doptimize=Debug -Ddebug=true run
```

### Rebuild Limine (if needed)
```bash
cd limine && make clean && make
```
""",
}

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    query = sys.argv[1].lower()

    if query in PATTERNS:
        print(PATTERNS[query])
    else:
        matches = [k for k in PATTERNS.keys() if query in k]
        if matches:
            for m in matches:
                print(PATTERNS[m])
        else:
            print(f"Unknown topic: {query}")
            print(f"Available: {', '.join(PATTERNS.keys())}")
            sys.exit(1)

if __name__ == "__main__":
    main()
