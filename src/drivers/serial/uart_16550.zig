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
/// Uses atomic access to prevent data races when modifying from non-ISR context.
var onByteReceivedAtomic = std.atomic.Value(?*const fn (byte: u8) void).init(null);

/// Get the current receive callback
pub fn getOnByteReceived() ?*const fn (byte: u8) void {
    return onByteReceivedAtomic.load(.acquire);
}

/// Set the receive callback (thread-safe)
pub fn setOnByteReceived(callback: ?*const fn (byte: u8) void) void {
    onByteReceivedAtomic.store(callback, .release);
}

/// Initialize the global serial port (for early boot/panic)
/// Baud rate must be between 1 and 115200. Invalid values default to 115200.
pub fn init(port: u16, baud: u32) void {
    current_port = port;

    // Validate baud rate to prevent division by zero and invalid divisor
    const safe_baud: u32 = if (baud == 0 or baud > 115200) 115200 else baud;

    // Disable interrupts
    hal.io.outb(port + IER, 0x00);

    // Enable DLAB (set baud rate divisor)
    hal.io.outb(port + LCR, 0x80);

    // Set divisor (safe_baud is guaranteed to be 1..115200, so divisor is 1..115200)
    const divisor: u16 = @intCast(115200 / safe_baud);
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

/// Wait for any pending async TX to complete (non-blocking spin-wait).
/// Used by synchronous write functions to prevent output interleaving.
fn waitForAsyncComplete() void {
    // Spin until no async TX is pending
    while (tx_pending_atomic.load(.acquire) != null) {
        hal.cpu.pause();
    }
}

pub fn writeByte(byte: u8) void {
    // Wait for any async TX to complete to prevent interleaved output
    waitForAsyncComplete();
    while (!isTransmitEmpty()) {
        hal.cpu.pause();
    }
    hal.io.outb(current_port, byte);
}

pub fn writeString(str: []const u8) void {
    // Wait for any async TX to complete before acquiring lock
    waitForAsyncComplete();

    // Basic spinlock to prevent interleaved output from concurrent sync callers
    while (global_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        hal.cpu.pause();
    }
    defer global_lock.store(false, .release);

    for (str) |c| {
        if (c == '\n') writeByteRaw('\r');
        writeByteRaw(c);
    }
}

/// Low-level byte write without async check (for use when async is already clear)
fn writeByteRaw(byte: u8) void {
    while (!isTransmitEmpty()) {
        hal.cpu.pause();
    }
    hal.io.outb(current_port, byte);
}

/// Panic-safe string write - bypasses async wait and locks.
/// Use only in panic/fault handlers where blocking could deadlock.
pub fn writeStringPanic(str: []const u8) void {
    for (str) |c| {
        if (c == '\n') writeByteRaw('\r');
        writeByteRaw(c);
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
        // Wait for any async TX to complete before acquiring lock
        waitForAsyncComplete();
        const held = self.lock.acquire();
        defer held.release();
        for (data) |c| {
            if (c == '\n') self.putCharRaw('\r');
            self.putCharRaw(c);
        }
    }

    /// Low-level putChar without async check
    fn putCharRaw(self: *Serial, c: u8) void {
        while ((hal.io.inb(self.port + LSR) & 0x20) == 0) {
            hal.cpu.pause();
        }
        hal.io.outb(self.port, c);
    }

    pub fn putChar(self: *Serial, c: u8) void {
        waitForAsyncComplete();
        self.putCharRaw(c);
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
            if (getOnByteReceived()) |callback| {
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

/// Pending async TX state (protected by tx_lock, tx_pending uses atomic for early-out check)
var tx_pending_atomic = std.atomic.Value(?*io.IoRequest).init(null);
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
    if (tx_pending_atomic.load(.acquire) != null) {
        tx_lock.store(false, .release);
        io_request.complete(.{ .err = .EBUSY });
        return error.Busy;
    }

    // Store pending state
    tx_pending_atomic.store(io_request, .release);
    tx_buffer = data;

    // Transition IoRequest to in_progress
    _ = io_request.compareAndSwapState(.pending, .in_progress);

    // Store metadata for tracing
    io_request.op_data = .{
        .raw = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    };

    // SECURITY FIX: All state updates and first byte TX must happen inside lock
    // to prevent race with ISR. The ISR cannot fire until we enable THRE interrupt,
    // but we must ensure tx_index is set correctly before enabling it.

    // Wait for transmit empty before sending first byte (still inside lock)
    while (!isTransmitEmpty()) {
        hal.cpu.pause();
    }

    // Send first byte and set index to 1 atomically (w.r.t. ISR)
    const first_byte = data[0];
    hal.io.outb(current_port, first_byte);
    tx_index = 1;

    // Enable TX empty interrupt (THRE) - ISR can now fire safely
    // Read current IER, set bit 1, preserve receive interrupt if enabled
    const current_ier = hal.io.inb(current_port + IER);
    hal.io.outb(current_port + IER, current_ier | IER_TX_EMPTY);

    // Release lock AFTER enabling interrupt - ISR will acquire lock before accessing state
    tx_lock.store(false, .release);
}

/// Handle TX empty interrupt (called from handleIrq)
/// Returns true if this was a TX interrupt we handled
fn handleTxEmptyInterrupt() bool {
    // Quick check with atomic load - if no pending, nothing to do
    // This avoids lock acquisition overhead when no async TX is active
    if (tx_pending_atomic.load(.acquire) == null) return false;

    // Acquire TX lock
    while (tx_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        hal.cpu.pause();
    }
    defer tx_lock.store(false, .release);

    // Re-check under lock (could have been cleared by another interrupt)
    const request = tx_pending_atomic.load(.acquire) orelse return false;

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
    tx_pending_atomic.store(null, .release);
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
        if (getOnByteReceived()) |callback| {
            callback(data);
        }
    }
}
