# Research: Minimal Zig Kernel with Limine

**Date**: 2025-12-04
**Feature**: 001-minimal-kernel

## Executive Summary

This document consolidates research findings for building a minimal x86_64 kernel
in Zig using the Limine bootloader. All technical unknowns have been resolved.

---

## 1. Limine Protocol for Zig

### Decision: Use limine-zig bindings with Limine v7.x protocol

**Rationale**: The official limine-zig library provides type-safe Zig bindings for
all Limine request structures. Using v7.x ensures stability while v10.x matures.

**Alternatives Considered**:
- Manual request structure definitions: More error-prone, no type safety
- Limine v10.x: Newer but config format changed (`.conf` vs `.cfg`)

### Request Structure Format

Limine uses a request/response pattern. Each request contains:
1. `id[4]`: 8-byte aligned magic ID (bootloader scans for this)
2. `revision`: Starts at 0, incremented when fields added
3. `response`: Pointer filled by bootloader at load time

### Framebuffer Request

```zig
const limine = @import("limine");

pub export var framebuffer_request: limine.FramebufferRequest = .{};
pub export var base_revision: limine.BaseRevision = .{ .revision = 2 };

// Access in kernel:
if (framebuffer_request.response) |response| {
    if (response.framebuffer_count > 0) {
        const fb = response.framebuffers()[0];
        // fb.address, fb.width, fb.height, fb.pitch, fb.bpp
    }
}
```

### Key Protocol Requirements

- Kernels MUST load at or above `0xffffffff80000000` (high-half)
- All pointers are 64-bit with higher-half offset pre-added
- Responses placed in bootloader-reclaimable memory
- Calling convention: SysV x86-64 ABI

---

## 2. Zig Build Configuration

### Decision: Use Zig 0.13.x/0.14.x with freestanding target

**Rationale**: Latest stable Zig provides required features (`code_model = .kernel`,
`resolveTargetQuery`). Freestanding target eliminates runtime dependencies.

**Alternatives Considered**:
- Zig 0.11.x: Missing `code_model` in build API
- Zig 0.12.x: Works but 0.13/0.14 have better cross-compilation

### Target Configuration

```zig
const target = b.resolveTargetQuery(.{
    .cpu_arch = .x86_64,
    .os_tag = .freestanding,
    .abi = .none,
    .cpu_features_add = std.Target.x86_64.featureSet(&.{.soft_float}),
    .cpu_features_sub = std.Target.x86_64.featureSet(&.{
        .mmx, .sse, .sse2, .sse3, .ssse3, .sse4_1, .sse4_2,
        .avx, .avx2,
    }),
});
```

### Code Model Requirement

```zig
kernel.root_module.code_model = .kernel;
```

The `.kernel` code model enables 32-bit signed relocations, required for high-half
addresses (top 2GB of 64-bit address space).

### Feature Flags

| Flag | Setting | Reason |
|------|---------|--------|
| `soft_float` | enabled | Kernel cannot use FPU without saving state |
| `mmx` | disabled | SIMD requires FPU context |
| `sse*` | disabled | Same as above |
| `avx*` | disabled | Same as above |

---

## 3. Linker Script

### Decision: Custom linker.ld with high-half load address

**Rationale**: Limine mandates high-half kernels. Custom script ensures proper
section placement and program headers.

### Complete Linker Script

```ld
OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

PHDRS {
    text PT_LOAD FLAGS((1 << 0) | (1 << 2));     /* Execute + Read */
    rodata PT_LOAD FLAGS((1 << 2));              /* Read only */
    data PT_LOAD FLAGS((1 << 1) | (1 << 2));     /* Write + Read */
}

SECTIONS {
    . = 0xffffffff80000000;

    .text : ALIGN(4K) {
        *(.text .text.*)
    } :text

    . += CONSTANT(MAXPAGESIZE);

    .rodata : ALIGN(4K) {
        *(.rodata .rodata.*)
    } :rodata

    . += CONSTANT(MAXPAGESIZE);

    .data : ALIGN(4K) {
        *(.data .data.*)
    } :data

    .bss : ALIGN(4K) {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
    }
}
```

### Key Points

- `ENTRY(_start)`: Entry point symbol from Zig
- `0xffffffff80000000`: High-half canonical address
- `PT_LOAD`: Required program headers for ELF loading
- `MAXPAGESIZE`: Proper spacing prevents overlap
- `/DISCARD/`: Remove unneeded sections

---

## 4. Limine Configuration

### Decision: Use limine.conf (v7+ format) with minimal config

**Rationale**: v7.x uses `.conf` format (not `.cfg`). Minimal config reduces
boot time and complexity.

### limine.conf

```
timeout: 0

/ZigK
    protocol: limine
    kernel_path: boot():/boot/kernel.elf
```

### Configuration Options

| Option | Value | Purpose |
|--------|-------|---------|
| `timeout` | 0 | Boot immediately |
| `protocol` | limine | Use Limine boot protocol |
| `kernel_path` | boot():/boot/kernel.elf | Kernel location on boot partition |

---

## 5. ISO Creation

### Decision: xorriso with hybrid BIOS/UEFI support

**Rationale**: Single ISO works on both BIOS and UEFI systems. xorriso is
available on all platforms via package managers.

### ISO Directory Structure

```
iso_root/
├── boot/
│   ├── kernel.elf
│   └── limine/
│       ├── limine.conf
│       ├── limine-bios.sys
│       └── limine-bios-cd.bin
└── EFI/
    └── BOOT/
        └── BOOTX64.EFI
```

### xorriso Command

```bash
xorriso -as mkisofs \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part \
    --efi-boot-image \
    --protective-msdos-label \
    iso_root -o zigk.iso
```

### Post-Processing

```bash
limine bios-install zigk.iso
```

Required for BIOS boot capability on the ISO.

---

## 6. Limine Binary Acquisition

### Decision: Git clone from binary release branch

**Rationale**: Binary releases are pre-built and ready to use. Git clone
integrates well with Zig build system.

### Acquisition Method

```bash
git clone https://github.com/limine-bootloader/limine.git \
    --branch=v7.x-binary --depth=1
```

### Required Files

| File | Purpose |
|------|---------|
| `limine-bios.sys` | BIOS stage 2 bootloader |
| `limine-bios-cd.bin` | BIOS CD boot sector |
| `limine-uefi-cd.bin` | UEFI CD boot image |
| `BOOTX64.EFI` | UEFI bootloader binary |
| `limine` | CLI tool for bios-install |

---

## 7. QEMU Configuration

### Decision: Minimal QEMU flags for development

**Rationale**: Simple configuration for rapid iteration. Additional flags
available for debugging when needed.

### Basic Run Command

```bash
qemu-system-x86_64 -cdrom zigk.iso -m 128M
```

### Debug Configuration

```bash
qemu-system-x86_64 \
    -cdrom zigk.iso \
    -m 128M \
    -serial stdio \
    -d int,cpu_reset \
    -no-reboot
```

| Flag | Purpose |
|------|---------|
| `-serial stdio` | Redirect serial to terminal |
| `-d int,cpu_reset` | Log interrupts and CPU resets |
| `-no-reboot` | Halt on triple fault instead of reboot |

---

## 8. Framebuffer Format

### Decision: Assume 32-bit BGRA format

**Rationale**: Most common framebuffer format. Limine provides actual format
in response for validation.

### Color Encoding

```zig
// Dark blue: R=0x00, G=0x00, B=0x40
// BGRA format: B=0x40, G=0x00, R=0x00, A=0x00
const dark_blue: u32 = 0x00400000;
```

### Pixel Write Pattern

```zig
const fb_ptr: [*]volatile u32 = @ptrFromInt(fb.address);
const pixels_per_row = fb.pitch / 4;  // pitch is in bytes
const total_pixels = pixels_per_row * fb.height;

for (0..total_pixels) |i| {
    fb_ptr[i] = dark_blue;
}
```

### Format Validation

```zig
// Verify expected format
if (fb.bpp != 32) {
    // Handle non-32bpp framebuffer
}
```

---

## 9. Host Dependencies

### macOS (primary development platform)

```bash
brew install xorriso qemu zig
```

### Linux

```bash
# Debian/Ubuntu
sudo apt install xorriso qemu-system-x86

# Arch
sudo pacman -S xorriso qemu-full
```

### Zig Installation

```bash
# Via package manager or download from ziglang.org
# Verify: zig version
```

---

## 10. Serial Port (COM1) for Debug Output

### Decision: Use COM1 (0x3F8) with direct port I/O

**Rationale**: COM1 is the standard PC serial port. QEMU supports `-serial stdio`
to redirect serial output to the terminal, enabling kernel debug messages.

### Port Addresses

| Port | Offset | Purpose |
|------|--------|---------|
| 0x3F8 | +0 | Data register (read/write) |
| 0x3F8 | +1 | Interrupt enable |
| 0x3F8 | +2 | FIFO control |
| 0x3F8 | +3 | Line control (DLAB) |
| 0x3F8 | +4 | Modem control |
| 0x3F8 | +5 | Line status |

### Initialization Sequence

```zig
outb(COM1 + 1, 0x00); // Disable interrupts
outb(COM1 + 3, 0x80); // Enable DLAB (set baud rate divisor)
outb(COM1 + 0, 0x03); // Set divisor to 3 (lo byte) 38400 baud
outb(COM1 + 1, 0x00); // (hi byte)
outb(COM1 + 3, 0x03); // 8 bits, no parity, one stop bit
outb(COM1 + 2, 0xC7); // Enable FIFO, clear them, with 14-byte threshold
outb(COM1 + 4, 0x0B); // IRQs enabled, RTS/DSR set
```

### Port I/O in Zig

```zig
fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}
```

---

## 11. Panic Handler (Required for Freestanding Zig)

### Decision: Implement custom panic handler that outputs to serial

**Rationale**: Freestanding Zig does not provide a default panic handler. The
linker will fail with `undefined symbol: panic` if not defined.

### Required Signature

```zig
pub fn panic(
    msg: []const u8,
    _: ?*@import("std").builtin.StackTrace,
    _: ?usize,
) noreturn {
    // Handle panic
}
```

### Implementation Strategy

1. Write "PANIC: " to serial
2. Write panic message to serial
3. Write newline
4. Enter infinite HLT loop

### Root Module Export

The panic handler must be accessible from the root module. Either:
- Define directly in main.zig, or
- Import from panic.zig: `pub const panic = @import("panic.zig").panic;`

---

## 12. Stack Smashing Protection (SSP)

### Decision: Provide SSP symbols to prevent linker errors

**Rationale**: Zig may enable stack protection which requires `__stack_chk_guard`
and `__stack_chk_fail` symbols. Without them, the linker fails.

### Required Exports

```zig
// Stack canary value
pub export var __stack_chk_guard: usize = 0xDEADBEEF;

// Called when stack corruption detected
pub export fn __stack_chk_fail() noreturn {
    @panic("Stack smashing detected");
}
```

### Alternatives Considered

- Disable stack protection in build: More complex, may miss actual bugs
- Use random canary: Requires randomness source (not available at boot)

---

## Unresolved Items

None. All technical decisions have been made and validated against research.

---

## References

- [Limine Protocol v7.x](https://github.com/limine-bootloader/limine/blob/v7.x/PROTOCOL.md)
- [limine-zig bindings](https://github.com/48cf/limine-zig)
- [Limine Zig Barebones](https://github.com/limine-bootloader/limine-zig-barebones)
- [OSDev Wiki: Limine](https://wiki.osdev.org/Limine)
- [Zig Build System](https://ziglang.org/documentation/master/#Build-System)
