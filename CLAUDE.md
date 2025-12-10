# zigk Development Guidelines

A Zig-based microkernel for x86_64 using the Limine bootloader protocol.

## Active Technologies
- Zig 0.15.x (freestanding x86_64 target)
- Limine bootloader (v5.x protocol)
- QEMU for emulation

## Project Structure

```
src/
  arch/       # Hardware abstraction (x86_64, aarch64)
  kernel/     # Core kernel (scheduler, heap, syscalls, ELF loader)
  drivers/    # Device drivers
  fs/         # Filesystem (devfs, initrd)
  net/        # TCP/IP stack, sockets
  lib/        # Shared libraries (limine bindings)
  user/       # Userland programs (shell, httpd)
  uapi/       # User-kernel API definitions
specs/        # Feature specifications
```

## Commands

```bash
zig build              # Build kernel + userland
zig build iso          # Create bootable ISO
zig build run          # Build ISO and run in QEMU
zig build test         # Run unit tests
```

For macOS with Apple Silicon:
```bash
zig build run -Dbios=/opt/homebrew/share/qemu/edk2-x86_64-code.fd
```

## Architecture Rules

### HAL Barrier (Strict Layering)
- **FORBIDDEN**: `asm volatile`, direct port I/O, or CPU register access outside `src/arch/`
- **REQUIRED**: Kernel code must use the `hal` module interface
- Assembly helpers go in `src/arch/x86_64/asm_helpers.S`

### Memory Hygiene
- All dynamic memory uses the kernel heap allocator
- Heap provides 16-byte aligned allocations (required for SSE/FPU state)
- Zero-copy patterns for networking until userspace boundary

### Linux Compatibility
- Syscall numbers follow Linux x86_64 ABI (see `specs/syscall-table.md`)
- Error codes use standard Linux errno values

## Coding Style

- **Version**: Zig 0.15.x
- **Naming**: `snake_case` for functions/vars, `PascalCase` for structs/types
- **Errors**: Use `try` or explicit handling; avoid `catch unreachable` unless panic intended
- **Types**: Explicit integer widths (`u64`, `usize`)

### Zig 0.15.x Inline Assembly

```zig
// Clobber syntax
asm volatile ("cli"
    :
    :
    : .{ .memory = true }
);

// Register constraints
asm volatile ("out %[data], %[port]"
    :
    : [port] "{dx}" (port),
      [data] "{al}" (data),
);
```

- **lgdt/lidt**: Use separate `.S` assembly file (Zig cannot express indirect memory operands)
- **Naked functions**: Can ONLY contain inline assembly, no Zig code

## Testing & Debugging

- **Emulation**: QEMU with `-accel tcg` (required on Apple Silicon)
- **Serial output**: `-serial stdio` captures kernel logs
- **Debug builds**: `zig build -Doptimize=Debug`

## Key Files

- `specs/syscall-table.md` - Authoritative syscall numbers
- `src/lib/limine.zig` - Limine protocol bindings
- `src/kernel/main.zig` - Kernel entry point
- `src/arch/x86_64/asm_helpers.S` - Low-level assembly routines
- `limine.cfg` - Bootloader configuration

## Agent Instructions

- Use zig-programming skill when writing Zig code
- Use subagents for research or context7 for documentation
- No emojis or em dashes
- Comments explain "why", not "what"
