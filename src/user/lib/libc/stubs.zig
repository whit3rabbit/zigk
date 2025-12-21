// Stub functions that cannot be properly implemented
//
// These functions require kernel features not yet available or
// have no meaningful implementation in a freestanding kernel.

const syscall = @import("syscall");

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

/// Set signal handler
/// Returns previous handler or SIG_ERR on error
pub export fn signal(sig: c_int, handler: sighandler_t) sighandler_t {
    var act: syscall.SigAction = undefined;
    act.handler = @intFromPtr(handler);
    act.flags = syscall.uapi.signal.SA_RESTART | syscall.uapi.signal.SA_RESETHAND;
    act.mask = 0;
    act.restorer = 0;
    
    var old_act: syscall.SigAction = undefined;
    syscall.sigaction(sig, &act, &old_act) catch return SIG_ERR;
    
    return @ptrFromInt(old_act.handler);
}

// =============================================================================
// setjmp/longjmp for x86_64 (implemented in setjmp.S)
// =============================================================================

/// Jump buffer type - architecture dependent
/// For x86_64: stores RBX, RBP, R12-R15, RSP, RIP (8 registers * 8 bytes = 64 bytes)
/// Layout:
///   [0]:  RBX
///   [8]:  RBP
///   [16]: R12
///   [24]: R13
///   [32]: R14
///   [40]: R15
///   [48]: RSP (value after setjmp returns)
///   [56]: RIP (return address)
pub const jmp_buf = [64]u8;

/// Save calling environment for later longjmp
/// Returns 0 on direct call, non-zero when returning from longjmp
/// Implemented in setjmp.S
pub extern fn setjmp(env: ?*jmp_buf) callconv(.c) c_int;

/// Restore calling environment saved by setjmp
/// Never returns - transfers control to setjmp location
/// Implemented in setjmp.S
pub extern fn longjmp(env: ?*jmp_buf, val: c_int) callconv(.c) noreturn;

/// POSIX version of setjmp that saves signal mask
/// Implemented in setjmp.S (signal mask not actually saved)
pub extern fn sigsetjmp(env: ?*jmp_buf, savemask: c_int) callconv(.c) c_int;

/// POSIX version of longjmp for sigsetjmp
/// Implemented in setjmp.S
pub extern fn siglongjmp(env: ?*jmp_buf, val: c_int) callconv(.c) noreturn;

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

/// Raise a signal in current process
pub export fn raise(sig: c_int) c_int {
    const pid = syscall.getpid();
    syscall.kill(pid, sig) catch return -1;
    return 0;
}

/// Block all signals
pub export fn sigfillset(set: ?*anyopaque) c_int {
    if (set) |s| {
        const ptr = @as(*syscall.SigSet, @ptrCast(@alignCast(s)));
        ptr.* = ~@as(syscall.SigSet, 0);
    }
    return 0;
}

/// Clear signal set
pub export fn sigemptyset(set: ?*anyopaque) c_int {
    if (set) |s| {
        const ptr = @as(*syscall.SigSet, @ptrCast(@alignCast(s)));
        ptr.* = 0;
    }
    return 0;
}

/// Add signal to set
pub export fn sigaddset(set: ?*anyopaque, signum: c_int) c_int {
    if (set) |s| {
        const ptr = @as(*syscall.SigSet, @ptrCast(@alignCast(s)));
        syscall.uapi.signal.sigaddset(ptr, @intCast(signum));
    }
    return 0;
}

/// Remove signal from set
pub export fn sigdelset(set: ?*anyopaque, signum: c_int) c_int {
    if (set) |s| {
         const ptr = @as(*syscall.SigSet, @ptrCast(@alignCast(s)));
         syscall.uapi.signal.sigdelset(ptr, @intCast(signum));
    }
    return 0;
}

/// Check if signal is in set
pub export fn sigismember(set: ?*const anyopaque, signum: c_int) c_int {
    if (set) |s| {
        const ptr = @as(*const syscall.SigSet, @ptrCast(@alignCast(s)));
        if (syscall.uapi.signal.sigismember(ptr.*, @intCast(signum))) {
            return 1;
        }
    }
    return 0;
}

/// Change signal mask
pub export fn sigprocmask(how: c_int, set: ?*const anyopaque, oldset: ?*anyopaque) c_int {
    const set_ptr = if (set) |s| @as(*const syscall.SigSet, @ptrCast(@alignCast(s))) else null;
    const oldset_ptr = if (oldset) |s| @as(*syscall.SigSet, @ptrCast(@alignCast(s))) else null;
    
    syscall.sigprocmask(how, set_ptr, oldset_ptr) catch return -1;
    return 0;
}

/// Assert fail handler
pub export fn __assert_fail(expr: ?[*:0]const u8, file: ?[*:0]const u8, line: c_uint, func: ?[*:0]const u8) noreturn {
    _ = expr;
    _ = file;
    _ = line;
    _ = func;
    // Print error to stderr (fd 2)
    // We can't use detailed printf here to avoid loops if printf fails
    const msg = "Assertion failed!\n";
    _ = syscall.write(2, msg, msg.len) catch {};
    syscall.exit(134);
}
