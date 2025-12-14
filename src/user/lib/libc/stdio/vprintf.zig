// vprintf family implementations (stdio.h)
//
// These functions take a va_list instead of varargs.
// In Zig 0.15.x freestanding, va_list handling is limited.
// These implementations provide best-effort compatibility.

const std = @import("std");
const syscall = @import("syscall.zig");
const file_mod = @import("file.zig");

const FILE = file_mod.FILE;

/// va_list type for C interop
/// On x86_64, va_list is a pointer to a structure
pub const va_list = *anyopaque;

/// vprintf - print to stdout using va_list
/// Note: In freestanding Zig, va_list cannot be portably traversed.
/// This implementation provides a stub that returns 0.
/// Use printf() directly when possible.
pub export fn vprintf(fmt: [*:0]const u8, ap: va_list) c_int {
    _ = fmt;
    _ = ap;
    // Cannot portably iterate va_list in freestanding Zig
    // Callers should use printf() with explicit varargs
    return 0;
}

/// vfprintf - print to file using va_list
pub export fn vfprintf(stream: ?*FILE, fmt: [*:0]const u8, ap: va_list) c_int {
    _ = ap;
    if (stream == null) return -1;
    const f = stream.?;
    const len = std.mem.len(fmt);
    
    // Minimal implementation: just print the format string itself
    // This allows seeing error messages even if args are missing
    const written = syscall.write(f.fd, fmt, len) catch return -1;
    return @intCast(written);
}

/// vsprintf - format to string using va_list
pub export fn vsprintf(dest: ?[*]u8, fmt: [*:0]const u8, ap: va_list) c_int {
    _ = fmt;
    _ = ap;
    if (dest == null) return -1;
    dest.?[0] = 0;
    return 0;
}

/// vsnprintf - format to string with size limit using va_list
pub export fn vsnprintf(dest: ?[*]u8, size: usize, fmt: [*:0]const u8, ap: va_list) c_int {
    _ = fmt;
    _ = ap;
    if (dest == null or size == 0) return 0;
    dest.?[0] = 0;
    return 0;
}

/// vasprintf - allocate and format string using va_list (stub)
pub export fn vasprintf(strp: ?*?[*:0]u8, fmt: [*:0]const u8, ap: va_list) c_int {
    _ = fmt;
    _ = ap;
    if (strp == null) return -1;
    strp.?.* = null;
    return -1;
}

// Alternative implementation note:
// A full va_list implementation would require architecture-specific
// assembly to properly traverse the argument structure. The x86_64
// va_list is a complex structure that tracks register and stack args
// separately. In Zig freestanding mode without libc, we don't have
// access to the proper va_arg macro implementation.
//
// For full v* function support, callers should:
// 1. Use the non-v variants (printf, fprintf, etc.) which work correctly
// 2. Or wrap calls in a function that has explicit varargs
//
// Example wrapper:
//   pub fn my_vprintf_wrapper(fmt: [*:0]const u8, ...) c_int {
//       return printf(fmt, ...); // Forward varargs directly
//   }
