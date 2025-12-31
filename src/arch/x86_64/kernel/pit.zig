// 8253/8254 Programmable Interval Timer (PIT) Driver
//
// The PIT is used to generate periodic interrupts (IRQ0) for the scheduler.
// Base frequency is 1.193182 MHz.
//
// Channels:
//   - Channel 0: IRQ0 generation for scheduler (vectors 32-47)
//   - Channel 1: Legacy DRAM refresh (not used)
//   - Channel 2: Speaker/timing, gated via port 0x61

const io = @import("../lib/io.zig");
const pic = @import("pic.zig");
const timing = @import("timing.zig");

// PIT Ports
const PIT_CHANNEL0: u16 = 0x40;
const PIT_CHANNEL1: u16 = 0x41;
const PIT_CHANNEL2: u16 = 0x42;
const PIT_COMMAND: u16 = 0x43;
const SPEAKER_PORT: u16 = 0x61;

// Base frequency in Hz
pub const BASE_FREQUENCY: u32 = 1193182;

/// PIT Command Register bit fields
/// Bit layout: [channel:2][access:2][mode:3][bcd:1]
pub const Command = packed struct(u8) {
    bcd_mode: u1 = 0, // Bit 0: 0=binary (16-bit), 1=BCD (4 decades)
    mode: Mode = .square_wave, // Bits 1-3: Operating mode
    access: Access = .lobyte_hibyte, // Bits 4-5: Access mode
    channel: Channel = .ch0, // Bits 6-7: Channel select

    pub const Mode = enum(u3) {
        interrupt_on_terminal_count = 0, // Mode 0: One-shot
        hw_retriggerable_one_shot = 1, // Mode 1: Hardware retriggerable
        rate_generator = 2, // Mode 2: Divide by N counter
        square_wave = 3, // Mode 3: Square wave generator
        sw_triggered_strobe = 4, // Mode 4: Software triggered strobe
        hw_triggered_strobe = 5, // Mode 5: Hardware triggered strobe
        // Modes 6 and 7 are aliases for 2 and 3
    };

    pub const Access = enum(u2) {
        latch_count = 0, // Latch current count for reading
        lobyte_only = 1, // Read/write low byte only
        hibyte_only = 2, // Read/write high byte only
        lobyte_hibyte = 3, // Read/write low byte then high byte
    };

    pub const Channel = enum(u2) {
        ch0 = 0, // IRQ0 scheduler
        ch1 = 1, // Legacy DRAM refresh (not used)
        ch2 = 2, // Speaker/timing
        readback = 3, // Read-back command (8254 only)
    };
};

/// Initialize the PIT Channel 0 to specified frequency (Mode 3: square wave)
pub fn init(frequency: u32) void {
    // SECURITY: Prevent division by zero
    if (frequency == 0) return;

    // Calculate divisor: Base Freq / Target Freq
    const divisor = BASE_FREQUENCY / frequency;

    // Configure channel 0 for square wave mode
    const cmd = Command{
        .channel = .ch0,
        .access = .lobyte_hibyte,
        .mode = .square_wave,
        .bcd_mode = 0,
    };
    io.outb(PIT_COMMAND, @bitCast(cmd));

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

/// Configure a PIT channel in one-shot mode (Mode 0: interrupt on terminal count)
/// The counter counts down from `count` and triggers IRQ once when it reaches 0.
/// For channel 0, IRQ0 fires. For channel 2, poll readChannel2Out() for completion.
pub fn configureOneShot(channel: Command.Channel, count: u16) void {
    // Count of 0 is invalid for Mode 0 (it would mean 65536 but is confusing)
    if (count == 0) return;

    const port: u16 = switch (channel) {
        .ch0 => PIT_CHANNEL0,
        .ch1 => PIT_CHANNEL1,
        .ch2 => PIT_CHANNEL2,
        .readback => return, // Invalid for one-shot
    };

    const cmd = Command{
        .channel = channel,
        .access = .lobyte_hibyte,
        .mode = .interrupt_on_terminal_count,
        .bcd_mode = 0,
    };
    io.outb(PIT_COMMAND, @bitCast(cmd));

    // Write count value (lobyte then hibyte)
    io.outb(port, @truncate(count));
    io.outb(port, @truncate(count >> 8));
}

/// Configure a PIT channel with custom mode and count
pub fn configure(channel: Command.Channel, mode: Command.Mode, count: u16) void {
    const port: u16 = switch (channel) {
        .ch0 => PIT_CHANNEL0,
        .ch1 => PIT_CHANNEL1,
        .ch2 => PIT_CHANNEL2,
        .readback => return,
    };

    const cmd = Command{
        .channel = channel,
        .access = .lobyte_hibyte,
        .mode = mode,
        .bcd_mode = 0,
    };
    io.outb(PIT_COMMAND, @bitCast(cmd));

    io.outb(port, @truncate(count));
    io.outb(port, @truncate(count >> 8));
}

/// Read current counter value from a channel (latches count first)
pub fn readCount(channel: Command.Channel) u16 {
    const port: u16 = switch (channel) {
        .ch0 => PIT_CHANNEL0,
        .ch1 => PIT_CHANNEL1,
        .ch2 => PIT_CHANNEL2,
        .readback => return 0,
    };

    // Latch the count (access=0 with channel specified)
    const cmd = Command{
        .channel = channel,
        .access = .latch_count,
        .mode = .square_wave, // Mode bits ignored for latch
        .bcd_mode = 0,
    };
    io.outb(PIT_COMMAND, @bitCast(cmd));

    // Read lobyte then hibyte
    const lo = io.inb(port);
    const hi = io.inb(port);
    return (@as(u16, hi) << 8) | lo;
}

/// Enable/disable speaker gate and speaker output for channel 2
/// Port 0x61 bit 0: Gate for PIT channel 2
/// Port 0x61 bit 1: Speaker enable
pub fn setSpeakerGate(gate: bool, speaker: bool) void {
    var port61 = io.inb(SPEAKER_PORT);
    if (gate) {
        port61 |= 0x01;
    } else {
        port61 &= ~@as(u8, 0x01);
    }
    if (speaker) {
        port61 |= 0x02;
    } else {
        port61 &= ~@as(u8, 0x02);
    }
    io.outb(SPEAKER_PORT, port61);
}

/// Read Channel 2 OUT status (for polling one-shot completion)
/// OUT goes high when counter reaches 0 in Mode 0
pub fn readChannel2Out() bool {
    return (io.inb(SPEAKER_PORT) & 0x20) != 0;
}

/// Play a tone at specified frequency using the PC speaker
/// Duration is approximate (uses TSC-based delay if calibrated)
pub fn beep(frequency_hz: u32, duration_ms: u32) void {
    if (frequency_hz == 0) return;

    const divisor = BASE_FREQUENCY / frequency_hz;

    // Configure channel 2 for square wave
    const cmd = Command{
        .channel = .ch2,
        .access = .lobyte_hibyte,
        .mode = .square_wave,
        .bcd_mode = 0,
    };
    io.outb(PIT_COMMAND, @bitCast(cmd));
    io.outb(PIT_CHANNEL2, @truncate(divisor));
    io.outb(PIT_CHANNEL2, @truncate(divisor >> 8));

    // Enable gate and speaker
    setSpeakerGate(true, true);

    // Wait using TSC-based delay
    timing.delayMs(duration_ms);

    // Disable speaker
    setSpeakerGate(false, false);
}

/// Calculate the divisor needed for a target frequency
pub fn calculateDivisor(target_hz: u32) u16 {
    if (target_hz == 0) return 0xFFFF;
    return @truncate(BASE_FREQUENCY / target_hz);
}
