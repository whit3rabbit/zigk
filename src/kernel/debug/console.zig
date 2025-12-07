// Generic Console Writer
//
// Provides architecture-agnostic debug output by wrapping the HAL serial driver.
// All kernel code should use this module for debug output rather than
// importing architecture-specific serial drivers directly.

const hal = @import("hal");
const config = @import("config");

/// Print a string to the debug console
pub fn print(str: []const u8) void {
    hal.serial.writeString(str);
}

/// Print a formatted string to the debug console
/// Note: In freestanding mode, we implement a minimal formatter
pub fn printf(comptime fmt: []const u8, args: anytype) void {
    // Use a simple inline formatter since std.fmt may not be available
    writeFormat(fmt, args);
}

/// Writer interface for compatibility with std patterns
pub const Writer = struct {
    const Self = @This();

    pub fn write(_: Self, bytes: []const u8) error{}!usize {
        print(bytes);
        return bytes.len;
    }

    pub fn writeAll(self: Self, bytes: []const u8) error{}!void {
        _ = try self.write(bytes);
    }

    pub fn writeByte(_: Self, byte: u8) error{}!void {
        hal.serial.writeByte(byte);
    }

    pub fn writeBytesNTimes(self: Self, bytes: []const u8, n: usize) error{}!void {
        for (0..n) |_| {
            try self.writeAll(bytes);
        }
    }
};

/// Global writer instance
pub const writer = Writer{};

// Simple format string implementation for freestanding
fn writeFormat(comptime fmt: []const u8, args: anytype) void {
    const ArgsType = @TypeOf(args);
    const args_fields = @typeInfo(ArgsType).@"struct".fields;

    comptime var arg_index: usize = 0;
    comptime var i: usize = 0;

    inline while (i < fmt.len) {
        if (fmt[i] == '{' and i + 1 < fmt.len and fmt[i + 1] == '}') {
            // Found {} placeholder
            if (arg_index < args_fields.len) {
                const arg = @field(args, args_fields[arg_index].name);
                writeArg(arg);
                arg_index += 1;
            }
            i += 2;
        } else if (fmt[i] == '{' and i + 2 < fmt.len and fmt[i + 1] == 's' and fmt[i + 2] == '}') {
            // Found {s} string placeholder
            if (arg_index < args_fields.len) {
                const arg = @field(args, args_fields[arg_index].name);
                // Handle both []const u8 and [*:0]const u8 types
                const ArgType = @TypeOf(arg);
                if (ArgType == []const u8) {
                    print(arg);
                } else if (@typeInfo(ArgType) == .pointer) {
                    // Null-terminated string pointer - convert to slice
                    const ptr: [*:0]const u8 = arg;
                    var len: usize = 0;
                    while (ptr[len] != 0) : (len += 1) {}
                    print(ptr[0..len]);
                }
                arg_index += 1;
            }
            i += 3;
        } else if (fmt[i] == '{' and i + 2 < fmt.len and fmt[i + 1] == 'd' and fmt[i + 2] == '}') {
            // Found {d} decimal placeholder
            if (arg_index < args_fields.len) {
                const arg = @field(args, args_fields[arg_index].name);
                writeDecimal(arg);
                arg_index += 1;
            }
            i += 3;
        } else if (fmt[i] == '{' and i + 2 < fmt.len and fmt[i + 1] == 'x' and fmt[i + 2] == '}') {
            // Found {x} hex placeholder
            if (arg_index < args_fields.len) {
                const arg = @field(args, args_fields[arg_index].name);
                writeHex(arg);
                arg_index += 1;
            }
            i += 3;
        } else {
            hal.serial.writeByte(fmt[i]);
            i += 1;
        }
    }
}

fn writeArg(arg: anytype) void {
    const T = @TypeOf(arg);
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .Slice and ptr.child == u8) {
                print(arg);
            } else {
                writeHex(@intFromPtr(arg));
            }
        },
        .int, .comptime_int => writeDecimal(arg),
        .bool => print(if (arg) "true" else "false"),
        else => print("[?]"),
    }
}

fn writeDecimal(value: anytype) void {
    const T = @TypeOf(value);
    if (@typeInfo(T) == .comptime_int or @typeInfo(T) == .int) {
        var buf: [20]u8 = undefined;
        var v: u64 = if (value < 0) @intCast(-value) else @intCast(value);
        var i: usize = buf.len;

        if (v == 0) {
            hal.serial.writeByte('0');
            return;
        }

        while (v > 0) : (i -= 1) {
            buf[i - 1] = @intCast((v % 10) + '0');
            v /= 10;
        }

        if (@typeInfo(T) == .int and @typeInfo(T).int.signedness == .signed and value < 0) {
            hal.serial.writeByte('-');
        }

        print(buf[i..]);
    }
}

fn writeHex(value: anytype) void {
    const hex_chars = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v: u64 = @intCast(value);
    var i: usize = buf.len;

    if (v == 0) {
        print("0x0");
        return;
    }

    while (v > 0) : (i -= 1) {
        buf[i - 1] = hex_chars[@intCast(v & 0xF)];
        v >>= 4;
    }

    print("0x");
    print(buf[i..]);
}

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
