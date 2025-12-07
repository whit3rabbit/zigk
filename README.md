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

## Docker Build (Recommended)

Docker provides a consistent build environment across all platforms and handles all dependencies automatically.

### Quick Start

```bash
# Build the kernel
./tools/docker-build.sh build

# Build bootable ISO
./tools/docker-build.sh iso

# Run unit tests
./tools/docker-build.sh test

# Interactive development shell
./tools/docker-build.sh shell

# Clean build artifacts
./tools/docker-build.sh clean
```

### Using Docker Compose

```bash
# Build kernel
docker compose run build

# Build ISO
docker compose run build-iso

# Run tests
docker compose run test

# Interactive shell with QEMU available
docker compose run dev
```

### Multi-Architecture Builds

The Docker setup supports building for multiple architectures:

```bash
# Build for x86_64 (current)
docker compose run build-x86_64

# Build for aarch64 (future)
docker compose run build-aarch64

# Build all architectures
./tools/docker-build.sh all
```

### Building the Docker Image

```bash
# Build the base image
docker build -t zigk-builder .

# Build with QEMU support for testing
docker build --target dev -t zigk-builder:dev .
```

## Project Structure

```
zigk/
├── build.zig              # Build configuration

├── src/
│   ├── arch/x86_64/       # HAL (hardware abstraction)
│   ├── kernel/            # Core subsystems
│   ├── drivers/           # Device drivers
│   ├── lib/               # Shared utilities
│   └── uapi/              # Userspace API definitions
└── tests/unit/            # Host-side unit tests
```

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
