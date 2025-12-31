//! PS/2 Controller Low-Level Interface
//!
//! Shared PS/2 controller I/O routines for keyboard and mouse drivers.
//! Provides type-safe access to the 8042 PS/2 controller hardware.
//!
//! Port Layout:
//!   0x60 - Data port (read/write)
//!   0x64 - Status port (read) / Command port (write)

const hal = @import("hal");

// =============================================================================
// Port Addresses
// =============================================================================

/// PS/2 data port - read scancodes/mouse data, write device commands
pub const DATA_PORT: u16 = 0x60;

/// PS/2 status port (read) / command port (write)
pub const CMD_PORT: u16 = 0x64;

// Alias for code that uses KEYBOARD_* naming
pub const KEYBOARD_DATA_PORT = DATA_PORT;
pub const KEYBOARD_STATUS_PORT = CMD_PORT;
pub const KEYBOARD_CMD_PORT = CMD_PORT;

// =============================================================================
// Controller Commands (sent to CMD_PORT 0x64)
// =============================================================================

/// Disable first PS/2 port (keyboard)
pub const CMD_DISABLE_FIRST_PORT: u8 = 0xAD;

/// Disable second PS/2 port (mouse)
pub const CMD_DISABLE_SECOND_PORT: u8 = 0xA7;

/// Enable first PS/2 port (keyboard)
pub const CMD_ENABLE_FIRST_PORT: u8 = 0xAE;

/// Enable second PS/2 port (mouse)
pub const CMD_ENABLE_SECOND_PORT: u8 = 0xA8;

/// Read controller configuration byte
pub const CMD_READ_CONFIG: u8 = 0x20;

/// Write controller configuration byte
pub const CMD_WRITE_CONFIG: u8 = 0x60;

/// Controller self-test (returns 0x55 on success)
pub const CMD_SELF_TEST: u8 = 0xAA;

/// Test first PS/2 port (returns 0x00 on success)
pub const CMD_TEST_FIRST_PORT: u8 = 0xAB;

/// Test second PS/2 port (returns 0x00 on success)
pub const CMD_TEST_SECOND_PORT: u8 = 0xA9;

/// Write next byte to second PS/2 port (mouse)
pub const CMD_WRITE_MOUSE: u8 = 0xD4;

// =============================================================================
// Response Codes
// =============================================================================

/// Self-test passed response
pub const SELF_TEST_PASSED: u8 = 0x55;

/// Port test passed response
pub const PORT_TEST_PASSED: u8 = 0x00;

// =============================================================================
// Configuration Byte Bits
// =============================================================================

/// Enable IRQ1 for first port (keyboard)
pub const CONFIG_FIRST_PORT_IRQ: u8 = 0x01;

/// Enable IRQ12 for second port (mouse)
pub const CONFIG_SECOND_PORT_IRQ: u8 = 0x02;

/// Disable second port clock
pub const CONFIG_SECOND_PORT_CLOCK: u8 = 0x20;

/// Enable scancode translation (Set 2 -> Set 1)
pub const CONFIG_TRANSLATION: u8 = 0x40;

// =============================================================================
// Device Commands (sent to DATA_PORT 0x60)
// =============================================================================

/// Enable keyboard scanning
pub const KBD_CMD_ENABLE: u8 = 0xF4;

/// Device acknowledge
pub const ACK: u8 = 0xFA;
pub const KBD_ACK: u8 = ACK;

/// Request resend
pub const RESEND: u8 = 0xFE;

// Mouse-specific commands
pub const MOUSE_CMD_RESET: u8 = 0xFF;
pub const MOUSE_CMD_RESEND: u8 = 0xFE;
pub const MOUSE_CMD_SET_DEFAULTS: u8 = 0xF6;
pub const MOUSE_CMD_DISABLE_STREAMING: u8 = 0xF5;
pub const MOUSE_CMD_ENABLE_STREAMING: u8 = 0xF4;
pub const MOUSE_CMD_SET_SAMPLE_RATE: u8 = 0xF3;
pub const MOUSE_CMD_GET_DEVICE_ID: u8 = 0xF2;
pub const MOUSE_CMD_SET_RESOLUTION: u8 = 0xE8;
pub const MOUSE_SELF_TEST_PASSED: u8 = 0xAA;

// =============================================================================
// Status Register
// =============================================================================

/// PS/2 Controller Status Register (port 0x64)
/// Provides type-safe access to status bits without manual bit masking
pub const StatusReg = packed struct(u8) {
    /// Output buffer full - data available to read from port 0x60
    output_buffer_full: bool,
    /// Input buffer full - controller busy, don't write yet
    input_buffer_full: bool,
    /// System flag - set by firmware during POST
    system_flag: bool,
    /// Command/data - 0: data written to 0x60, 1: command written to 0x64
    command_data: bool,
    /// Reserved (keyboard-specific on some controllers)
    _reserved1: bool = false,
    /// Mouse data - 1: data in output buffer is from mouse, 0: from keyboard
    mouse_data: bool,
    /// Timeout error - communication timeout
    timeout_error: bool,
    /// Parity error - data transmission error
    parity_error: bool,

    comptime {
        if (@sizeOf(@This()) != 1) @compileError("StatusReg must be 1 byte");
    }

    /// Read status register from hardware
    pub fn read() StatusReg {
        return @bitCast(hal.io.inb(CMD_PORT));
    }

    /// Check if data is available to read
    pub fn hasData(self: StatusReg) bool {
        return self.output_buffer_full;
    }

    /// Check if any error occurred
    pub fn hasError(self: StatusReg) bool {
        return self.timeout_error or self.parity_error;
    }

    /// Check if controller is ready to accept input
    pub fn canWrite(self: StatusReg) bool {
        return !self.input_buffer_full;
    }

    /// Check if data is from mouse (not keyboard)
    pub fn isMouseData(self: StatusReg) bool {
        return self.mouse_data;
    }
};

// =============================================================================
// I/O Helper Functions
// =============================================================================

/// Default timeout for PS/2 operations (iterations)
const DEFAULT_TIMEOUT: u32 = 100_000;

/// Wait for PS/2 input buffer to be empty (ready to accept commands)
/// Returns true if ready, false on timeout
pub fn waitInputEmpty() bool {
    var timeout: u32 = DEFAULT_TIMEOUT;
    while (timeout > 0) : (timeout -= 1) {
        if (StatusReg.read().canWrite()) return true;
    }
    return false;
}

/// Wait for PS/2 output buffer to have data (ready to read)
/// Returns true if data available, false on timeout
pub fn waitOutputFull() bool {
    var timeout: u32 = DEFAULT_TIMEOUT;
    while (timeout > 0) : (timeout -= 1) {
        if (StatusReg.read().hasData()) return true;
    }
    return false;
}

/// Send command to PS/2 controller (port 0x64)
pub fn sendCommand(cmd: u8) void {
    _ = waitInputEmpty();
    hal.io.outb(CMD_PORT, cmd);
}

/// Send data to PS/2 controller (port 0x60)
pub fn sendData(data: u8) void {
    _ = waitInputEmpty();
    hal.io.outb(DATA_PORT, data);
}

/// Read data from PS/2 controller (port 0x60), with timeout
/// Returns null on timeout
pub fn readData() ?u8 {
    if (waitOutputFull()) {
        return hal.io.inb(DATA_PORT);
    }
    return null;
}

/// Flush any stale data from PS/2 output buffer
/// Discards up to 16 bytes to prevent infinite loop on stuck hardware
pub fn flushBuffer() void {
    var flush_count: u32 = 0;
    while (StatusReg.read().output_buffer_full and flush_count < 16) {
        _ = hal.io.inb(DATA_PORT);
        flush_count += 1;
    }
}

/// Send a command to the mouse (via controller's D4 command)
/// Retries on RESEND (0xFE) response, up to 3 attempts
pub fn sendMouseCommand(cmd: u8) bool {
    var retries: u8 = 3;
    while (retries > 0) : (retries -= 1) {
        sendCommand(CMD_WRITE_MOUSE);
        sendData(cmd);

        const response = readData() orelse return false;
        if (response == ACK) return true;
        if (response == RESEND) continue;
        return false; // Unexpected response
    }
    return false; // Max retries exceeded
}

/// Send a command with a data byte to the mouse
pub fn sendMouseCommandWithData(cmd: u8, data: u8) bool {
    if (!sendMouseCommand(cmd)) return false;
    sendCommand(CMD_WRITE_MOUSE);
    sendData(data);

    const response = readData() orelse return false;
    return response == ACK;
}

// =============================================================================
// Unit Tests
// =============================================================================

test "StatusReg packed struct size" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(StatusReg));
}
