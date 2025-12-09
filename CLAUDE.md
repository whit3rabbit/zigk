# zigk Development Guidelines

The biggest gain from Zig is moving runtime crashes (segmentation faults, unaligned access, buffer overflows) into compile-time errors or safe panics. By switching pointers to slices and using the Allocator interface, the stack becomes memory-safe and highly portable.

## Active Technologies
- Zig 0.15.x - freestanding x86_64 target + GRUB2 (Multiboot2)
- limine

## Project Structure

Refer to `filesystem.md` for project structure.

## Commands

Build and run commands for Zig 0.15.x freestanding kernel:

```bash
zig build              # Build kernel
zig build run -Dbios=/opt/homebrew/share/qemu/edk2-x86_64-code.fd        # Build and run in QEMU on OSX
zig build test         # Run tests
```

## Code Style

Zig 0.15.x freestanding target: Follow standard conventions

## Build Patterns (Zig 0.15.x)

```zig
// Module creation (required for 0.15.x)
const kernel = b.addExecutable(.{
    .name = "kernel.elf",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
        }),
        .optimize = optimize,
        .code_model = .kernel,  // Disables Red Zone
    }),
});

// Disable SIMD for simpler context switching
kernel.root_module.cpu_features_sub.add(.sse);
kernel.root_module.cpu_features_sub.add(.sse2);
kernel.root_module.cpu_features_sub.add(.mmx);
```

## Recent Changes
- 009-spec-consistency-unification: Unified Zig version to 0.15.x, added syscall-table.md
- 007-linux-compat-layer: Added Linux runtime syscalls (wait4, clock_gettime, getrandom) + pre-opened FDs
- 003-microkernel-userland-networking: Added networking, userland shell, InitRD support


<!-- MANUAL ADDITIONS START -->
## 1. Context & Navigation
- **Project Structure**: ALWAYS verify file placement against `filesystem.md`.
- **Current Specs**: Refer to `specs/` for active feature requirements.
- **Workflow**: We follow Spec-Driven Development.
  1. `spec` (Requirements)
  2. `plan` (Architecture)
  3. `tasks` (Action Items)
  4. `implement` (Code)

## 2. Constitutional Enforcements (Non-Negotiable)
**I. The HAL Barrier (Strict Layering)**
- **FORBIDDEN**: Writing `asm volatile`, accessing `0x...` addresses, or touching CPU registers outside of `src/arch/`.
- **REQUIRED**: Kernel code (`src/kernel`, `src/net`) MUST use the `hal` module interface.
- **CHECK**: If writing a driver, ask: "Am I accessing a port directly?" If yes, move that logic to `src/arch`.

**II. Memory Hygiene**
- **FORBIDDEN**: Implicit allocations or hidden copies.
- **REQUIRED**: All dynamic memory uses the kernel heap allocator. Pointers > Copies.
- **NETWORKING**: Use Zero-Copy patterns (`PacketBuffer` pointers) until userspace boundary.

**III. Linux Compatibility**
- **SYSCALLS**: Use Linux x86_64 numbers. See `specs/syscall-table.md` for authoritative table.
- **ERROR CODES**: Use standard Linux errno (e.g., `-EAGAIN`).

## 3. Coding Style (Zig)
- **Version**: Zig 0.15.x (current stable target).
- **Errors**: Use `try` or explicit error handling. Avoid `catch unreachable` in kernel space unless panic is intended.
- **Types**: Use explicit integer widths (`u64`, `usize`).
- **Naming**: `snake_case` for functions/vars, `PascalCase` for structs/types.

## 3.1 Zig 0.15.x Inline Assembly Limitations
- **Clobber syntax**: Use `.{ .rax = true, .memory = true }` not `"rax", "memory"`.
- **Register constraints**: Use `"{rdi}"` for specific registers, `"r"` for any register.
- **Memory operands with lgdt/lidt**: Zig's inline asm cannot express indirect memory operands like `lgdt (%rdi)`. Use a separate `.S` assembly file (see `src/arch/x86_64/asm_helpers.S`).
- **Naked functions**: Can ONLY contain inline assembly, no Zig code or function calls.
- **comptime asm blocks**: Symbols defined in `comptime { asm(...) }` may not link across modules. Put assembly and its callers in the same file, or use a separate `.S` file added via `addAssemblyFile()` in build.zig.

## 4. Execution & Testing
- **Emulation**: We use QEMU.
- **Apple Silicon**: ALWAYS use `-accel tcg` for x86_64 emulation on ARM hosts.
- **Debug**: Use `-serial stdio` to capture kernel logging.

## 5. Agent Commands
- `/speckit.specify`: Create spec for new feature.
- `/speckit.plan`: Generate architecture plan.
- `/speckit.tasks`: Break plan into todo list.
- `/speckit.implement`: Write code based on tasks.
- `/speckit.analyze`: Check consistency between spec/plan/tasks.

Always use zig skill when writing zig code.
Never use emojis or em dashes.
Always write professional, technical, and concise code.
Add comments to your code on the "why" of your code or explaining steps.
Use  subagents for research or context7 for documentation.
<!-- MANUAL ADDITIONS END -->
- 1. specs/syscall-table.md - Single source of truth for syscall numbers
  2. specs/shared/zig-version-policy.md - Zig 0.15.x patterns and migrations
  3. specs/shared/zig-osdev-gotchas.md - Critical Zig OS development knowledge
