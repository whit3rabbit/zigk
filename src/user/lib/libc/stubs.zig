// Stub functions that cannot be properly implemented
//
// These functions require kernel features not yet available or
// have no meaningful implementation in a freestanding kernel.

const syscall = @import("syscall.zig");

// =============================================================================
// Signal handling stubs
// =============================================================================

/// Signal handler type
pub const sighandler_t = ?*const fn (c_int) callconv(.c) void;

/// SIG_DFL - default signal action
pub const SIG_DFL: sighandler_t = null;

/// SIG_IGN - ignore signal
pub const SIG_IGN: sighandler_t = @ptrFromInt(1);

/// SIG_ERR - error return
pub const SIG_ERR: sighandler_t = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

/// Set signal handler (stub - no real signal support yet)
/// Returns previous handler or SIG_ERR on error
pub export fn signal(sig: c_int, handler: sighandler_t) sighandler_t {
    _ = sig;
    _ = handler;
    // No signal support in kernel yet - return SIG_DFL
    return SIG_DFL;
}

// =============================================================================
// setjmp/longjmp stubs
// =============================================================================

/// Jump buffer type - architecture dependent
/// For x86_64: stores RBX, RBP, R12-R15, RSP, RIP (8 registers * 8 bytes = 64 bytes)
pub const jmp_buf = [64]u8;

/// Save calling environment for later longjmp
/// Returns 0 on direct call, non-zero when returning from longjmp
pub export fn setjmp(env: ?*jmp_buf) c_int {
    // Cannot properly implement without assembly to save registers
    // Just return 0 indicating direct call
    _ = env;
    return 0;
}

/// Restore calling environment saved by setjmp
/// Never returns - transfers control to setjmp location
pub export fn longjmp(env: ?*jmp_buf, val: c_int) noreturn {
    // Cannot properly implement without assembly
    // Fall back to abort
    _ = env;
    _ = val;
    syscall.exit(134); // SIGABRT exit code
}

/// POSIX version of setjmp that saves signal mask
pub export fn sigsetjmp(env: ?*jmp_buf, savemask: c_int) c_int {
    _ = savemask;
    return setjmp(env);
}

/// POSIX version of longjmp for sigsetjmp
pub export fn siglongjmp(env: ?*jmp_buf, val: c_int) noreturn {
    longjmp(env, val);
}

// =============================================================================
// Locale stubs
// =============================================================================

/// Locale category constants
pub const LC_ALL: c_int = 0;
pub const LC_COLLATE: c_int = 1;
pub const LC_CTYPE: c_int = 2;
pub const LC_MESSAGES: c_int = 3;
pub const LC_MONETARY: c_int = 4;
pub const LC_NUMERIC: c_int = 5;
pub const LC_TIME: c_int = 6;

/// Set locale (stub - always returns "C" locale)
pub export fn setlocale(category: c_int, locale: ?[*:0]const u8) ?[*:0]const u8 {
    _ = category;
    _ = locale;
    // Only "C" locale supported
    return "C";
}

// =============================================================================
// Misc stubs
// =============================================================================

/// Raise a signal in current process (stub)
pub export fn raise(sig: c_int) c_int {
    _ = sig;
    // No signal support yet
    return -1;
}

/// Block all signals (stub)
pub export fn sigfillset(set: ?*anyopaque) c_int {
    _ = set;
    return 0;
}

/// Clear signal set (stub)
pub export fn sigemptyset(set: ?*anyopaque) c_int {
    _ = set;
    return 0;
}

/// Add signal to set (stub)
pub export fn sigaddset(set: ?*anyopaque, signum: c_int) c_int {
    _ = set;
    _ = signum;
    return 0;
}

/// Block signals (stub)
pub export fn sigprocmask(how: c_int, set: ?*const anyopaque, oldset: ?*anyopaque) c_int {
    _ = how;
    _ = set;
    _ = oldset;
    return 0;
}
