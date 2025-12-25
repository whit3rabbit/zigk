// Cross-architecture va_list abstraction
//
// Provides architecture-agnostic access to C variadic arguments.
// Works around LLVM @cVaArg limitation on aarch64 (GitHub #14096).

const builtin = @import("builtin");

/// Architecture-specific va_list implementation
pub const impl = switch (builtin.cpu.arch) {
    .x86_64 => @import("va_list/x86_64.zig"),
    .aarch64 => @import("va_list/aarch64.zig"),
    else => @compileError("Unsupported architecture for va_list"),
};

/// Cross-platform VaList wrapper for manual argument extraction
pub const VaList = impl.VaList;

/// C-compatible va_list type (pointer to opaque structure)
pub const c_va_list = ?*anyopaque;
