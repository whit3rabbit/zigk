# Implementation Plan: Minimal Bootable Kernel

**Branch**: `001-minimal-kernel` | **Date**: 2025-12-04 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-minimal-kernel/spec.md`

## Summary

Build a minimal 64-bit operating system kernel in Zig that boots via the Limine
bootloader protocol, acquires framebuffer access, paints the screen dark blue to
verify video memory control, and halts the CPU in an infinite HLT loop. The build
system produces a bootable ISO for QEMU emulation. Debug output via COM1 serial
port enables kernel diagnostics.

## Technical Context

**Language/Version**: Zig (latest stable, 0.13.x/0.14.x) - freestanding target
**Primary Dependencies**: Limine bootloader v7.x+, limine-zig bindings
**Storage**: N/A (no filesystem operations in minimal kernel)
**Testing**: QEMU visual verification (framebuffer color) + serial output (-serial stdio)
**Target Platform**: x86_64 freestanding (bare metal, long mode)
**Project Type**: Single (kernel binary)
**Performance Goals**: Boot to framebuffer fill in <1 second under QEMU
**Constraints**: No stdlib runtime, no FPU/SIMD, kernel code model required
**Scale/Scope**: ~300-500 LOC for minimal kernel, 6 source files

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Requirement | Status |
|-----------|-------------|--------|
| I. Bare-Metal Zig | Freestanding x86_64, no stdlib runtime, inline asm for HLT/port I/O | PASS |
| II. Limine Protocol | All resources via Limine requests (framebuffer) | PASS |
| III. Minimal Viable Kernel | Single milestone: boot → framebuffer → halt | PASS |
| IV. QEMU-First Verification | ISO output, `zig build run` launches QEMU, serial output | PASS |
| V. Explicit Memory | Volatile framebuffer access, validate Limine response | PASS |

**Technical Constraints Compliance**:
- Target: x86_64 long mode | PASS
- Bootloader: Limine v7+ | PASS
- Build Output: ELF + ISO | PASS
- No stdlib beyond builtins | PASS
- No FPU operations | PASS (SIMD features disabled)
- Inline asm for port I/O (serial) | PASS (Constitution I permits for hardware ops)

## Project Structure

### Documentation (this feature)

```text
specs/001-minimal-kernel/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 output
├── quickstart.md        # Build and run instructions
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (repository root)

```text
src/
├── main.zig             # Kernel entry point, Limine requests, framebuffer fill
├── serial.zig           # COM1 serial port initialization and output
├── panic.zig            # Panic handler (prints to serial, then halts)
├── ssp.zig              # Stack smashing protection guard symbols
└── linker.ld            # Linker script for high-half kernel

limine.conf              # Limine bootloader configuration
build.zig                # Zig build system with ISO generation
build.zig.zon            # Zig package dependencies (limine-zig)

limine/                  # Limine bootloader binaries (git clone, gitignored)
iso_root/                # Generated ISO filesystem (gitignored)
zig-out/                 # Build artifacts (gitignored)
```

**Structure Decision**: Single-project kernel structure with modular source files.
Core logic in `main.zig`, infrastructure in dedicated modules (serial, panic, ssp).

## Source File Responsibilities

### src/main.zig
- Limine base revision and framebuffer request structures
- `_start` entry point (exported, noreturn)
- Base revision validation
- Framebuffer response validation
- Framebuffer fill loop (dark blue color)
- CPU halt loop

### src/serial.zig
- COM1 port address constants (0x3F8)
- Serial port initialization (baud rate, line control)
- `write` function for character output
- `writeString` function for string output
- Uses inline assembly for `outb` port I/O

### src/panic.zig
- Panic handler function (required for freestanding Zig)
- Signature: `pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn`
- Writes panic message to serial port
- Enters infinite HLT loop
- Prevents linker error: `undefined symbol: panic`

### src/ssp.zig
- Stack smashing protection symbols
- `__stack_chk_guard`: Stack canary value
- `__stack_chk_fail`: Called on stack corruption detection
- Required when Zig enables stack protection
- Halts CPU on stack corruption

## Complexity Tracking

> No constitution violations. Minimal implementation follows all principles.

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| Modular source files | Split into main/serial/panic/ssp | Better organization, reusable for future milestones |
| Serial output | COM1 at 0x3F8 | Standard PC serial port, QEMU supports -serial stdio |
| Stack protection | ssp.zig symbols | Prevents linker errors if Zig enables SSP |

## Build System Design

### build.zig Responsibilities

1. **Kernel Compilation**
   - Target: `x86_64-freestanding-none`
   - Code model: `.kernel` (required for 0xffffffff80000000+)
   - CPU features: Disable `mmx`, `sse`, `sse2`, `avx`, `avx2`
   - Enable: `soft_float`
   - Linker script: `src/linker.ld`
   - Root source: `src/main.zig` (imports other modules)

2. **Limine Download Step**
   - Shell command: `git clone --branch=v7.x-binary --depth=1`
   - Fallback: Manual download to `limine/` directory
   - Extract: `limine-bios.sys`, `limine-bios-cd.bin`, `BOOTX64.EFI`

3. **ISO Assembly Step**
   - Create `iso_root/` directory structure
   - Copy kernel.elf to `iso_root/boot/`
   - Copy limine.conf to `iso_root/boot/limine/`
   - Copy Limine binaries

4. **xorriso Step**
   - Generate hybrid BIOS/UEFI ISO
   - Run `limine bios-install` for BIOS boot support

5. **QEMU Run Step**
   - `qemu-system-x86_64 -cdrom zscapek.iso -m 128M -serial stdio`

### Linker Script Requirements

- Entry point: `_start` (exported from main.zig)
- Load address: `0xffffffff80000000` (high-half canonical)
- Sections: `.text`, `.rodata`, `.data`, `.bss`
- Program headers: `PT_LOAD` with proper flags
- Alignment: 4K between sections

### Limine Configuration

```conf
timeout: 0

/Zscapek
    protocol: limine
    kernel_path: boot():/boot/kernel.elf
```

## Kernel Entry Point Design

### Limine Request Structure

```zig
const limine = @import("limine");

pub export var framebuffer_request: limine.FramebufferRequest = .{};
pub export var base_revision: limine.BaseRevision = .{ .revision = 2 };
```

### Entry Function

```zig
export fn _start() callconv(.C) noreturn {
    serial.init();
    serial.writeString("Zscapek booting...\n");

    // 1. Verify base revision accepted
    if (!base_revision.is_supported()) {
        @panic("Limine base revision not supported");
    }

    // 2. Get framebuffer response
    // 3. Validate framebuffer exists
    // 4. Fill framebuffer with dark blue (0x00400000)

    serial.writeString("Framebuffer filled. Halting.\n");

    // 5. Halt loop
    while (true) {
        asm volatile ("hlt");
    }
}
```

### Serial Port Implementation

```zig
// src/serial.zig
const COM1: u16 = 0x3F8;

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

pub fn init() void {
    outb(COM1 + 1, 0x00); // Disable interrupts
    outb(COM1 + 3, 0x80); // Enable DLAB
    outb(COM1 + 0, 0x03); // Set divisor (lo byte) 38400 baud
    outb(COM1 + 1, 0x00); // Set divisor (hi byte)
    outb(COM1 + 3, 0x03); // 8 bits, no parity, one stop bit
    outb(COM1 + 2, 0xC7); // Enable FIFO
    outb(COM1 + 4, 0x0B); // IRQs enabled, RTS/DSR set
}

pub fn write(char: u8) void {
    outb(COM1, char);
}

pub fn writeString(str: []const u8) void {
    for (str) |char| {
        write(char);
    }
}
```

### Panic Handler Implementation

```zig
// src/panic.zig
const serial = @import("serial.zig");

pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    serial.writeString("PANIC: ");
    serial.writeString(msg);
    serial.write('\n');

    while (true) {
        asm volatile ("hlt");
    }
}
```

### Stack Smashing Protection

```zig
// src/ssp.zig
pub export var __stack_chk_guard: usize = 0xDEADBEEF;

pub export fn __stack_chk_fail() noreturn {
    @panic("Stack smashing detected");
}
```

### Framebuffer Fill Algorithm

```zig
// Dark blue in 32-bit BGRA: 0x00400000 (B=0x40, G=0x00, R=0x00)
const color: u32 = 0x00400000;
const fb_ptr: [*]volatile u32 = @ptrFromInt(fb.address);
const pixel_count = (fb.pitch / 4) * fb.height;

var i: usize = 0;
while (i < pixel_count) : (i += 1) {
    fb_ptr[i] = color;
}
```

## Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| Zig | 0.13.x / 0.14.x | Compiler |
| limine-zig | trunk | Zig bindings for Limine protocol |
| Limine | v7.x-binary | Bootloader binaries |
| xorriso | any | ISO creation |
| QEMU | any | x86_64 emulation |

### Host Requirements (macOS)

```bash
brew install xorriso qemu
```

## Verification Criteria

| Criterion | Method |
|-----------|--------|
| Kernel compiles | `zig build` succeeds |
| ISO created | `zscapek.iso` exists, valid ISO format |
| QEMU boots | No triple fault, reaches kernel |
| Serial output | "Zscapek booting..." appears in terminal |
| Framebuffer works | Screen fills with dark blue color |
| CPU halts | QEMU shows 0% CPU after init |

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Limine binary fetch fails | Fallback: manual download instructions in quickstart.md |
| xorriso not installed | Build step checks, clear error message |
| QEMU not installed | Separate `zig build iso` step for manual testing |
| Wrong Zig version | build.zig.zon specifies minimum version |
| Serial not working | QEMU -d int flag for debugging |
