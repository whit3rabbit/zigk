// Process control (stdlib.h)
//
// Functions for process termination and execution.

const syscall = @import("syscall");

/// Exit status codes
pub const EXIT_SUCCESS: c_int = 0;
pub const EXIT_FAILURE: c_int = 1;

/// Terminate the process with status code
pub export fn exit(status: c_int) noreturn {
    // Call atexit handlers (in reverse order)
    callAtexitHandlers();

    // Exit via syscall
    syscall.exit(@bitCast(status));
}

/// Abort the process (abnormal termination)
pub export fn abort() noreturn {
    // SIGABRT typically results in exit code 134
    syscall.exit(134);
}

/// Quick exit without calling atexit handlers
pub export fn _Exit(status: c_int) noreturn {
    syscall.exit(@bitCast(status));
}

/// Alias for _Exit
pub export fn _exit(status: c_int) noreturn {
    syscall.exit(@bitCast(status));
}

// Atexit handler storage
const MAX_ATEXIT_HANDLERS: usize = 32;
var atexit_handlers: [MAX_ATEXIT_HANDLERS]?*const fn () callconv(.c) void = [_]?*const fn () callconv(.c) void{null} ** MAX_ATEXIT_HANDLERS;
var atexit_count: usize = 0;

/// Register function to be called at exit
pub export fn atexit(func: ?*const fn () callconv(.c) void) c_int {
    if (func == null) return -1;

    if (atexit_count >= MAX_ATEXIT_HANDLERS) {
        return -1; // No room for more handlers
    }

    atexit_handlers[atexit_count] = func;
    atexit_count += 1;
    return 0;
}

/// Call all registered atexit handlers in reverse order
fn callAtexitHandlers() void {
    while (atexit_count > 0) {
        atexit_count -= 1;
        if (atexit_handlers[atexit_count]) |handler| {
            handler();
        }
    }
}

/// Execute shell command (stub - no shell in freestanding)
pub export fn system(command: ?[*:0]const u8) c_int {
    _ = command;
    // Command execution not supported without a shell
    return -1;
}
