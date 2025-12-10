// Serial port driver for x86_64 (COM1)
// HAL layer - uses port I/O for UART communication
//
// Implements 8250/16550 UART protocol for debug output.
// This driver is in src/arch/ because it requires direct port I/O access.

const io = @import("io.zig");

// COM port base addresses
pub const COM1: u16 = 0x3F8;
pub const COM2: u16 = 0x2F8;
pub const COM3: u16 = 0x3E8;
pub const COM4: u16 = 0x2E8;

// UART register offsets (from base port)
const DATA: u16 = 0; // Data register (read/write)
const IER: u16 = 1; // Interrupt Enable Register
const FCR: u16 = 2; // FIFO Control Register (write)
const IIR: u16 = 2; // Interrupt Identification Register (read)
const LCR: u16 = 3; // Line Control Register
const MCR: u16 = 4; // Modem Control Register
const LSR: u16 = 5; // Line Status Register
const MSR: u16 = 6; // Modem Status Register
const SCR: u16 = 7; // Scratch Register

// Divisor Latch registers (when DLAB=1 in LCR)
const DLL: u16 = 0; // Divisor Latch Low
const DLH: u16 = 1; // Divisor Latch High

// Line Status Register bits
const LSR_DATA_READY: u8 = 0x01;
const LSR_OVERRUN_ERROR: u8 = 0x02;
const LSR_PARITY_ERROR: u8 = 0x04;
const LSR_FRAMING_ERROR: u8 = 0x08;
const LSR_BREAK_INDICATOR: u8 = 0x10;
const LSR_TX_HOLDING_EMPTY: u8 = 0x20;
const LSR_TX_EMPTY: u8 = 0x40;
const LSR_IMPENDING_ERROR: u8 = 0x80;

// Line Control Register bits
const LCR_DLAB: u8 = 0x80; // Divisor Latch Access Bit

// Current serial port configuration
var current_port: u16 = COM1;
var initialized: bool = false;
var lock = std.atomic.Value(bool).init(false);

const std = @import("std");

/// Initialize the serial port with specified baud rate
/// Default: 115200 baud, 8N1 (8 data bits, no parity, 1 stop bit)
pub fn init(port: u16, baud: u32) void {
    current_port = port;

    // Calculate divisor for baud rate
    // Base clock is 115200, divisor = 115200 / baud
    const divisor: u16 = @intCast(115200 / baud);

    // Disable interrupts
    io.outb(port + IER, 0x00);

    // Enable DLAB to set baud rate divisor
    io.outb(port + LCR, LCR_DLAB);

    // Set divisor (low byte first, then high byte)
    io.outb(port + DLL, @truncate(divisor));
    io.outb(port + DLH, @truncate(divisor >> 8));

    // Configure 8N1: 8 data bits, no parity, 1 stop bit
    // Clear DLAB at the same time
    io.outb(port + LCR, 0x03);

    // Enable and clear FIFOs, set 14-byte threshold
    io.outb(port + FCR, 0xC7);

    // Enable DTR, RTS, and OUT2 (required for interrupts)
    io.outb(port + MCR, 0x0B);

    // Test the serial chip with loopback mode
    io.outb(port + MCR, 0x1E); // Enable loopback
    io.outb(port + DATA, 0xAE); // Send test byte

    // Check if we receive the same byte back
    if (io.inb(port + DATA) != 0xAE) {
        // Serial port not working, but continue anyway
        // (might still work without loopback)
    }

    // Disable loopback, set normal operation mode
    io.outb(port + MCR, 0x0F);

    initialized = true;
}

/// Initialize COM1 at 115200 baud (convenience function)
pub fn initDefault() void {
    init(COM1, 115200);
}

/// Check if transmit buffer is empty and ready for new data
inline fn isTxReady() bool {
    return (io.inb(current_port + LSR) & LSR_TX_HOLDING_EMPTY) != 0;
}

/// Check if data is available to read
pub fn hasData() bool {
    return (io.inb(current_port + LSR) & LSR_DATA_READY) != 0;
}

/// Write a single byte to the serial port (blocking)
/// Silently returns if serial port is not initialized
pub fn writeByte(byte: u8) void {
    if (!initialized) return;

    // Acquire lock
    while (lock.swap(true, .acquire)) {
        asm volatile ("pause");
    }
    defer lock.store(false, .release);

    writeByteUnlocked(byte);
}

fn writeByteUnlocked(byte: u8) void {
    // Wait until transmit buffer is empty
    var retries: usize = 100000;
    while (!isTxReady() and retries > 0) {
        retries -= 1;
        asm volatile ("pause");
    }
    io.outb(current_port + DATA, byte);
}

/// Read a single byte from the serial port (blocking)
/// Returns 0 if serial port is not initialized
pub fn readByte() u8 {
    if (!initialized) return 0;

    // Wait until data is available
    while (!hasData()) {
        // Spin wait
    }
    return io.inb(current_port + DATA);
}

/// Write a string to the serial port
pub fn writeString(str: []const u8) void {
    // Acquire lock to ensure atomic output of the string
    while (lock.swap(true, .acquire)) {
        asm volatile ("pause");
    }
    defer lock.store(false, .release);

    for (str) |byte| {
        // Convert LF to CRLF for terminal compatibility
        if (byte == '\n') {
            writeByteUnlocked('\r');
        }
        writeByteUnlocked(byte);
    }
}

/// Write a string to the serial port without acquiring the lock
/// UNSAFE: Use only in panic/crash situations where deadlock is possible
pub fn writeStringUnsafe(str: []const u8) void {
    for (str) |byte| {
        if (byte == '\n') {
            writeByteUnlocked('\r');
        }
        writeByteUnlocked(byte);
    }
}

/// Writer interface compatible with std.io.Writer pattern
pub const Writer = struct {
    pub fn write(_: *const Writer, bytes: []const u8) error{}!usize {
        writeString(bytes);
        return bytes.len;
    }

    pub fn writeAll(self: *const Writer, bytes: []const u8) error{}!void {
        _ = try self.write(bytes);
    }

    pub fn writeByte(self: *const Writer, byte: u8) error{}!void {
        _ = self;
        serial.writeByte(byte);
    }

    pub fn writeBytesNTimes(self: *const Writer, bytes: []const u8, n: usize) error{}!void {
        for (0..n) |_| {
            try self.writeAll(bytes);
        }
    }
};

/// Global writer instance
pub const writer = Writer{};

// Provide module-level reference for Writer methods
const serial = @This();
