// Generic Console Writer
//
// Provides architecture-agnostic debug output by wrapping the HAL serial driver.
// All kernel code should use this module for debug output rather than
// importing architecture-specific serial drivers directly.

const std = @import("std");
const hal = @import("hal");
const config = @import("config");

/// Function pointer to avoid circular dependency
pub var sendKernelMessageFn: ?*const fn (pid: usize, payload: []const u8) anyerror!void = null;

/// Console Backend Interface
pub const Backend = struct {
    context: ?*anyopaque,
    writeFn: *const fn (context: ?*anyopaque, str: []const u8) void,
    scrollFn: ?*const fn (context: ?*anyopaque, lines: usize, up: bool) void = null,
};

var backends: [4]Backend = undefined;
var backend_count: usize = 0;

/// Add a new output backend
pub fn addBackend(backend: Backend) void {
    if (backend_count < backends.len) {
        backends[backend_count] = backend;
        backend_count += 1;
    }
}

/// Context for IPC backend
const IpcBackendCtx = struct {
    pid: usize,
};
var ipc_ctx: IpcBackendCtx = undefined;

/// Wrapper to send logs via IPC
fn ipcWriteWrapper(ctx: ?*anyopaque, str: []const u8) void {
    const c: *IpcBackendCtx = @ptrCast(@alignCast(ctx));
    // Best effort send - ignore errors to avoid infinite loops in logging
    if (sendKernelMessageFn) |sendFn| {
        sendFn(c.pid, str) catch {};
    }
}

/// Register a process as the logging backend
pub fn addIpcBackend(pid: usize) void {
    ipc_ctx = .{ .pid = pid };
    addBackend(.{
        .context = &ipc_ctx,
        .writeFn = ipcWriteWrapper,
    });
}

/// Print a string to the debug console
pub fn print(str: []const u8) void {
    if (backend_count == 0) {
        // Fallback to HAL serial until backends are registered
        hal.serial.writeString(str);
        return;
    }

    for (backends[0..backend_count]) |b| {
        b.writeFn(b.context, str);
    }
}

/// Print a string to the debug console without locking
/// UNSAFE: Use only in panic/crash situations
pub fn printUnsafe(str: []const u8) void {
    // Try to use backends if available, but skip locks if possible?
    // Our backends (uart, console) are currently lock-free or simple.
    // However, for unsafe panic, maybe just dump to HAL serial for valid output.
    hal.serial.writeStringUnsafe(str); 
}

/// Scroll standard output up/down
pub fn scroll(lines: usize, up: bool) void {
    if (backend_count == 0) return;

    // Only scroll the first backend usually (graphical console)
    // Or iterate all? Typically only one graphical console exists.
    for (backends[0..backend_count]) |b| {
        if (b.scrollFn) |scrollFn| {
            scrollFn(b.context, lines, up);
        }
    }
}

/// Disable graphical backend when userspace claims exclusive framebuffer access.
/// Kernel output continues on serial only. Graphical backends are identified by
/// having a non-null scrollFn (serial backends don't support scrolling).
pub fn disableGraphicalBackend() void {
    var new_count: usize = 0;
    for (backends[0..backend_count]) |b| {
        // Keep backends without scroll support (serial)
        // Remove backends with scroll support (graphical)
        if (b.scrollFn == null) {
            backends[new_count] = b;
            new_count += 1;
        }
    }
    backend_count = new_count;
}

/// Print a formatted string to the debug console
/// Uses a fixed buffer for formatting - suitable for kernel debug output
pub fn printf(comptime fmt: []const u8, args: anytype) void {
    // Use a generous buffer for kernel debug messages
    var buf: [2048]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, fmt, args) catch |fmt_err| {
        // On error, print what we can
        switch (fmt_err) {
            error.NoSpaceLeft => {
                print(buf[0..]);
                print("[TRUNCATED]");
                return;
            },
        }
    };
    print(result);
}

/// Writer interface for compatibility with std patterns
/// Custom implementation that doesn't depend on std.io (unavailable in freestanding)
pub const Writer = struct {
    pub const Error = error{};

    pub fn write(_: Writer, bytes: []const u8) Error!usize {
        print(bytes);
        return bytes.len;
    }

    pub fn writeAll(_: Writer, bytes: []const u8) Error!void {
        print(bytes);
    }

    pub fn writeByte(_: Writer, byte: u8) Error!void {
        print(&[_]u8{byte});
    }

    pub fn writeByteNTimes(_: Writer, byte: u8, n: usize) Error!void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            print(&[_]u8{byte});
        }
    }

    pub fn printFmt(_: Writer, comptime fmt: []const u8, args: anytype) Error!void {
        printf(fmt, args);
    }
};

/// Global writer instance
pub const writer = Writer{};

/// Log levels for structured logging
pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    fn prefix(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "[DEBUG] ",
            .info => "[INFO]  ",
            .warn => "[WARN]  ",
            .err => "[ERROR] ",
        };
    }
};

/// Log a message with a specific level
pub fn log(level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    if (!config.debug_enabled and level == .debug) return;
    print(level.prefix());
    printf(fmt, args);
    print("\n");
}

/// Convenience functions for different log levels
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "panic formatting failed";

    printUnsafe("\n[PANIC] ");
    printUnsafe(msg);
    printUnsafe("\n");
    hal.cpu.haltForever();
}
