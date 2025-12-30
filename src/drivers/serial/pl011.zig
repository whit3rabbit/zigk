// PrimeCell UART (PL011) Driver
//
// Provides support for the ARM PL011 UART found on many AArch64 systems
// including the QEMU 'virt' machine.

const std = @import("std");
const sync = @import("sync");

// Register offsets (multiplied by 4 for 32-bit MMIO)
const DR     = 0x00; // Data Register
const FR     = 0x18; // Flag Register
const IBRD   = 0x24; // Integer Baud Rate Register
const FBRD   = 0x28; // Fractional Baud Rate Register
const LCR_H  = 0x2C; // Line Control Register
const CR     = 0x30; // Control Register
const IMSC   = 0x38; // Interrupt Mask Set/Clear Register
const ICR    = 0x44; // Interrupt Clear Register

// FR bits
const FR_TXFF = 1 << 5; // Transmit FIFO full
const FR_RXFE = 1 << 4; // Receive FIFO empty

// LCR_H bits
const LCR_H_FEN = 1 << 4; // Enable FIFOs
const LCR_H_WLEN_8 = 3 << 5; // Word length 8 bits

// CR bits
const CR_UARTEN = 1 << 0; // UART enable
const CR_TXE    = 1 << 8; // Transmit enable
const CR_RXE    = 1 << 9; // Receive enable

// Default base address for QEMU 'virt' UART0
pub const UART0_BASE = 0x09000000;
pub const COM1 = UART0_BASE; // For compatibility with x86 code

var uart_base: u64 = UART0_BASE;
var output_lock: sync.Spinlock = .{};

fn writeReg(offset: u32, val: u32) void {
    const addr: *volatile u32 = @ptrFromInt(uart_base + offset);
    addr.* = val;
}

fn readReg(offset: u32) u32 {
    const addr: *volatile u32 = @ptrFromInt(uart_base + offset);
    return addr.*;
}

pub fn init(base: u64, _: u32) void {
    uart_base = base;

    // Disable UART before configuration
    writeReg(CR, 0);

    // Clear all interrupts
    writeReg(ICR, 0x7FF);

    // Set baud rate (assuming 24MHz clock for 115200)
    writeReg(IBRD, 13);
    writeReg(FBRD, 1);

    // 8 bit, FIFO enabled, no parity
    writeReg(LCR_H, LCR_H_WLEN_8 | LCR_H_FEN);

    // Enable UART, TX, and RX
    writeReg(CR, CR_UARTEN | CR_TXE | CR_RXE);

    initialized = true;
}

pub fn initDefault() void {
    init(UART0_BASE, 115200);
}

pub fn writeByte(byte: u8) void {
    while ((readReg(FR) & FR_TXFF) != 0) {}
    writeReg(DR, byte);
}

pub fn writeString(str: []const u8) void {
    const held = output_lock.acquire();
    defer held.release();
    for (str) |c| {
        if (c == '\n') writeByte('\r');
        writeByte(c);
    }
}

/// Panic-safe string write - bypasses lock.
/// Use only in panic/fault handlers where blocking could deadlock.
pub fn writeStringPanic(str: []const u8) void {
    for (str) |c| {
        if (c == '\n') writeByte('\r');
        writeByte(c);
    }
}

pub const Serial = struct {
    base: u64,

    pub fn init(base: u64) Serial {
        const s = Serial{ .base = base };
        @import("pl011.zig").init(base, 115200);
        return s;
    }

    pub fn write(self: *Serial, data: []const u8) void {
        _ = self;
        writeString(data);
    }

    pub fn handleIrq() void {}
};
