// 8253/8254 Programmable Interval Timer (PIT) Driver
//
// The PIT is used to generate periodic interrupts (IRQ0) for the scheduler.
// Base frequency is 1.193182 MHz.

const io = @import("io.zig");
const pic = @import("pic.zig");

// PIT Ports
const PIT_CHANNEL0: u16 = 0x40;
const PIT_CHANNEL1: u16 = 0x41;
const PIT_CHANNEL2: u16 = 0x42;
const PIT_COMMAND: u16 = 0x43;

// Base frequency in Hz
const BASE_FREQUENCY: u32 = 1193182;

/// Initialize the PIT Channel 0 to specified frequency
pub fn init(frequency: u32) void {
    // Calculate divisor
    // Divisor = Base Freq / Target Freq
    const divisor = BASE_FREQUENCY / frequency;

    // Command byte:
    // Channel 0 (00)
    // Access Mode: lobyte/hibyte (11)
    // Mode 3: Square wave generator (011)
    // Binary mode (0)
    // 00 11 011 0 = 0x36
    io.outb(PIT_COMMAND, 0x36);

    // Write divisor (lobyte then hibyte)
    io.outb(PIT_CHANNEL0, @truncate(divisor));
    io.outb(PIT_CHANNEL0, @truncate(divisor >> 8));

    // Unmask IRQ0 (Timer) in PIC
    pic.enableIrq(0);
}

/// Disable PIT interrupts
pub fn disable() void {
    pic.disableIrq(0);
}
