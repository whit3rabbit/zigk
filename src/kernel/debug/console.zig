// Generic Console Writer
//
// Provides architecture-agnostic debug output by wrapping the HAL serial driver.
// All kernel code should use this module for debug output rather than
// importing architecture-specific serial drivers directly.

const std = @import("std");
const hal = @import("hal");
const config = @import("config");

/// Print a string to the debug console
pub fn print(str: []const u8) void {
    hal.serial.writeString(str);
}

/// Print a string to the debug console without locking
/// UNSAFE: Use only in panic/crash situations
pub fn printUnsafe(str: []const u8) void {
    hal.serial.writeStringUnsafe(str);
}

/// Print a formatted string to the debug console
/// Note: In freestanding mode, we implement a minimal formatter
pub fn printf(comptime fmt: []const u8, args: anytype) void {
    std.fmt.format(writer, fmt, args) catch {};
}

/// Writer interface for compatibility with std patterns
const ConsoleRawWriter = struct {
    pub const Error = error{};
    pub fn write(self: ConsoleRawWriter, bytes: []const u8) Error!usize {
        _ = self;
        print(bytes);
        return bytes.len;
    }
};

/// Global writer instance
pub const writer = std.io.GenericWriter(ConsoleRawWriter, ConsoleRawWriter.Error, ConsoleRawWriter.write){ .context = ConsoleRawWriter{} };

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
