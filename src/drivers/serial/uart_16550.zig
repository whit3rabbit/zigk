// Generic 16550 UART Driver
//
// Provides support for the standard 16550 UART found on most x86 systems
// and many other architectures.
//
// This driver communicates with the hardware via Port I/O (x86) or MMIO.
// Architecture-specific I/O is abstracted via the HAL.

const std = @import("std");
const hal = @import("hal");
const sync = @import("sync");
const io = @import("io");

// Register offsets
const DATA = 0;
const IER = 1;
const FCR = 2;
const LCR = 3;
const MCR = 4;
const LSR = 5;
const MSR = 6;
const SCR = 7;

// Default COM ports (x86 specific, but used as defaults)
pub const COM1 = 0x3F8;
pub const COM2 = 0x2F8;
pub const COM3 = 0x3E8;
pub const COM4 = 0x2E8;

var current_port: u16 = COM1;
var initialized: bool = false;
var global_lock = std.atomic.Value(bool).init(false);

/// Callback for received bytes (to avoid circular dependency with keyboard driver)
pub var onByteReceived: ?*const fn(byte: u8) void = null;

/// Initialize the global serial port (for early boot/panic)
pub fn init(port: u16, baud: u32) void {
    current_port = port;

    // Disable interrupts
    hal.io.outb(port + IER, 0x00);

    // Enable DLAB (set baud rate divisor)
    hal.io.outb(port + LCR, 0x80);

    // Set divisor
    const divisor = @as(u16, @truncate(115200 / baud));
    hal.io.outb(port + DATA, @truncate(divisor & 0xFF));
    hal.io.outb(port + IER, @truncate(divisor >> 8));

    // 8 bits, no parity, one stop bit
    hal.io.outb(port + LCR, 0x03);

    // Enable FIFO, clear them, with 14-byte threshold
    hal.io.outb(port + FCR, 0xC7);

    // IRQs enabled, RTS/DSR set
    hal.io.outb(port + MCR, 0x0B);

    initialized = true;
}

pub fn initDefault() void {
    init(COM1, 115200);
}

/// Enable receive interrupts for the global port
pub fn enableReceiveInterrupts() void {
    hal.io.outb(current_port + IER, 0x01);
}

fn isTransmitEmpty() bool {
    return (hal.io.inb(current_port + LSR) & 0x20) != 0;
}

pub fn writeByte(byte: u8) void {
    while (!isTransmitEmpty()) {
        hal.cpu.pause();
    }
    hal.io.outb(current_port, byte);
}

pub fn writeString(str: []const u8) void {
    // Basic spinlock to prevent interleaved output
    while (global_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        hal.cpu.pause();
    }
    defer global_lock.store(false, .release);

    for (str) |c| {
        if (c == '\n') writeByte('\r');
        writeByte(c);
    }
}

pub fn writeStringPanic(str: []const u8) void {
    for (str) |c| {
        if (c == '\n') writeByte('\r');
        writeByte(c);
    }
}

/// Object-oriented interface (matching old uart.zig)
pub const Serial = struct {
    port: u16,
    lock: sync.Spinlock = .{},

    pub fn init(port: u16) Serial {
        const self = Serial{ .port = port };
        // Use the global init logic
        @import("uart_16550.zig").init(port, 115200);
        return self;
    }

    pub fn write(self: *Serial, data: []const u8) void {
        const held = self.lock.acquire();
        defer held.release();
        for (data) |c| {
            if (c == '\n') self.putChar('\r');
            self.putChar(c);
        }
    }

    pub fn putChar(self: *Serial, c: u8) void {
        while ((hal.io.inb(self.port + LSR) & 0x20) == 0) {
            hal.cpu.pause();
        }
        hal.io.outb(self.port, c);
    }

    /// UART Interrupt Handler
    pub fn handleIrq() void {
        const port = current_port;
        // Read Interrupt Identification Register (IIR)
        const iir = hal.io.inb(port + 2);
        
        // Check if interrupt is pending (Bit 0 == 0 means pending)
        if ((iir & 0x01) != 0) return;

        // Check ID (Bits 1-3)
        // 010 (2) = Received Data Available
        // 110 (6) = Character Timeout
        const id = (iir >> 1) & 0x07;
        if (id == 2 or id == 6) {
             const data = hal.io.inb(port);
             if (onByteReceived) |callback| {
                 callback(data);
             }
        }
    }
};

pub const Writer = struct {
    pub const Error = error{};
    pub const Context = void;

    pub fn write(context: Context, data: []const u8) Error!usize {
        _ = context;
        writeString(data);
        return data.len;
    }
};

pub const writer = Writer{};

// -----------------------------------------------------------------------------
// Async I/O Support
// -----------------------------------------------------------------------------

/// Pending async TX state (single writer, protected by tx_lock)
var tx_pending: ?*io.IoRequest = null;
var tx_buffer: []const u8 = &.{};
var tx_index: usize = 0;
var tx_lock = std.atomic.Value(bool).init(false);

/// IER bit masks
const IER_RX_AVAILABLE: u8 = 0x01; // Bit 0: Enable Received Data Available Interrupt
const IER_TX_EMPTY: u8 = 0x02; // Bit 1: Enable Transmitter Holding Register Empty Interrupt

/// Async transmit error types
pub const AsyncTxError = error{
    Busy, // Another async TX is in progress
    InvalidParam, // Empty or null buffer
};

/// Write data asynchronously with IoRequest completion
///
/// Begins transmission and returns immediately. The IoRequest will be
/// completed when all bytes have been transmitted via the THRE interrupt.
///
/// Flow:
/// 1. Caller allocates IoRequest via io.allocRequest(.serial_tx)
/// 2. This function sends first byte and enables THRE interrupt
/// 3. THRE interrupt fires after each byte, ISR sends next byte
/// 4. When all bytes sent, ISR completes IoRequest with bytes_sent
/// 5. Caller's Future becomes ready
///
/// @param data Data to transmit (must remain valid until completion)
/// @param io_request IoRequest to complete on TX completion
/// @return error if another async TX is in progress
pub fn writeAsync(data: []const u8, io_request: *io.IoRequest) AsyncTxError!void {
    if (data.len == 0) {
        io_request.complete(.{ .err = .EINVAL });
        return error.InvalidParam;
    }

    // Acquire TX lock (simple spinlock)
    while (tx_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        hal.cpu.pause();
    }

    // Check if async TX already in progress
    if (tx_pending != null) {
        tx_lock.store(false, .release);
        io_request.complete(.{ .err = .EBUSY });
        return error.Busy;
    }

    // Store pending state
    tx_pending = io_request;
    tx_buffer = data;
    tx_index = 0;

    // Transition IoRequest to in_progress
    _ = io_request.compareAndSwapState(.pending, .in_progress);

    // Store metadata for tracing
    io_request.op_data = .{
        .raw = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    };

    tx_lock.store(false, .release);

    // Send first byte (this primes the interrupt)
    const first_byte = data[0];
    tx_index = 1;

    // Wait for transmit empty before sending first byte
    while (!isTransmitEmpty()) {
        hal.cpu.pause();
    }
    hal.io.outb(current_port, first_byte);

    // Enable TX empty interrupt (THRE)
    // Read current IER, set bit 1, preserve receive interrupt if enabled
    const current_ier = hal.io.inb(current_port + IER);
    hal.io.outb(current_port + IER, current_ier | IER_TX_EMPTY);
}

/// Handle TX empty interrupt (called from handleIrq)
/// Returns true if this was a TX interrupt we handled
fn handleTxEmptyInterrupt() bool {
    // Quick check without lock - if no pending, nothing to do
    if (tx_pending == null) return false;

    // Acquire TX lock
    while (tx_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        hal.cpu.pause();
    }
    defer tx_lock.store(false, .release);

    const request = tx_pending orelse return false;

    // Check if more data to send
    if (tx_index < tx_buffer.len) {
        // Send next byte
        hal.io.outb(current_port, tx_buffer[tx_index]);
        tx_index += 1;
        return true;
    }

    // All data sent - complete the request
    const bytes_sent = tx_buffer.len;

    // Disable TX empty interrupt
    const current_ier = hal.io.inb(current_port + IER);
    hal.io.outb(current_port + IER, current_ier & ~IER_TX_EMPTY);

    // Clear pending state before completing (avoid race)
    tx_pending = null;
    tx_buffer = &.{};
    tx_index = 0;

    // Complete IoRequest (this may wake blocked thread)
    request.complete(.{ .ok = bytes_sent });

    return true;
}

/// Extended IRQ handler that also checks TX interrupts
pub fn handleIrqAsync() void {
    const port = current_port;
    // Read Interrupt Identification Register (IIR)
    const iir = hal.io.inb(port + 2);

    // Check if interrupt is pending (Bit 0 == 0 means pending)
    if ((iir & 0x01) != 0) return;

    // Check ID (Bits 1-3)
    // 001 (1) = Transmitter Holding Register Empty (THRE)
    // 010 (2) = Received Data Available
    // 110 (6) = Character Timeout
    const id = (iir >> 1) & 0x07;

    if (id == 1) {
        // THRE interrupt - transmitter ready for next byte
        _ = handleTxEmptyInterrupt();
    } else if (id == 2 or id == 6) {
        // Received data
        const data = hal.io.inb(port);
        if (onByteReceived) |callback| {
            callback(data);
        }
    }
}
