# Zig Version Policy

**Target Version**: Zig 0.15.x (current stable target for Zscapek)

## Build System Patterns (0.15.x)

### Module Creation

Zig 0.15.x uses `createModule` and `root_module` patterns:

```zig
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
```

### CPU Feature Manipulation

Disable SIMD features for kernel code (simpler context switching):

```zig
kernel.root_module.cpu_features_sub.add(.sse);
kernel.root_module.cpu_features_sub.add(.sse2);
kernel.root_module.cpu_features_sub.add(.mmx);
```

### Linker Script

```zig
kernel.setLinkerScript(b.path("src/linker.ld"));
```

## Breaking Changes from 0.14.x

1. `b.addModule` replaced with `b.createModule`
2. `exe.addModule` replaced with `root_module` in executable options
3. `exe.addIncludePath` replaced with `root_module.addIncludePath`
4. CPU features accessed via `root_module.cpu_features_sub`

## Freestanding Target Requirements

- `.os_tag = .freestanding` - No operating system
- `.abi = .none` - No standard ABI
- `.code_model = .kernel` - Kernel code model (disables Red Zone)

## Standard Library in Freestanding

Limited `std` functionality available:
- `std.mem` - Memory operations
- `std.atomic` - Atomic operations
- `std.math` - Math operations (integer only without FPU)
- `std.debug` - Panic infrastructure (needs custom handler)

Not available without OS:
- `std.fs` - Filesystem operations
- `std.net` - Network operations
- `std.Thread` - Threading (requires OS)
- `std.heap.page_allocator` - Page allocator (requires OS)

## References

- [Zig 0.15.0 Release Notes](https://ziglang.org/download/0.15.0/release-notes.html)
- [Zig Build System Documentation](https://ziglang.org/learn/build-system/)
