// IDE Interrupt Handling
//
// Provides IRQ handlers for IDE channels (IRQ14/15).
// For PIO mode, interrupts are optional but help with async I/O.
//
// Reference: ATA/ATAPI-7 Specification

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const registers = @import("registers.zig");

// ============================================================================
// IRQ Vector Numbers
// ============================================================================

/// Primary IDE IRQ (14) mapped to vector 32 + 14 = 46
pub const PRIMARY_VECTOR: u8 = 46;
/// Secondary IDE IRQ (15) mapped to vector 32 + 15 = 47
pub const SECONDARY_VECTOR: u8 = 47;

// ============================================================================
// Controller Reference
// ============================================================================

/// Global controller reference for IRQ handlers
var g_controller: ?*anyopaque = null;
var g_primary_channel: ?registers.Channel = null;
var g_secondary_channel: ?registers.Channel = null;

// ============================================================================
// Interrupt Handlers
// ============================================================================

/// Primary IDE channel interrupt handler (IRQ14)
fn primaryIrqHandler(frame: *hal.idt.InterruptFrame) void {
    _ = frame;

    if (g_primary_channel) |channel| {
        // Read status register to clear interrupt condition
        const status = registers.readStatus(channel);
        _ = status;

        // TODO: Wake any waiting threads when async I/O is implemented
        // For now, PIO mode uses polling so interrupts just acknowledge
    }

    // Send EOI to PIC/APIC
    hal.apic.sendEoiForIrq(registers.PRIMARY_IRQ);
}

/// Secondary IDE channel interrupt handler (IRQ15)
fn secondaryIrqHandler(frame: *hal.idt.InterruptFrame) void {
    _ = frame;

    if (g_secondary_channel) |channel| {
        // Read status register to clear interrupt condition
        const status = registers.readStatus(channel);
        _ = status;

        // TODO: Wake any waiting threads when async I/O is implemented
    }

    // Send EOI to PIC/APIC
    hal.apic.sendEoiForIrq(registers.SECONDARY_IRQ);
}

// ============================================================================
// Registration
// ============================================================================

pub const IrqError = error{
    RegistrationFailed,
};

/// Register IRQ handlers for IDE channels
pub fn registerIrqHandlers(
    controller: *anyopaque,
    primary: ?registers.Channel,
    secondary: ?registers.Channel,
) IrqError!void {
    g_controller = controller;
    g_primary_channel = primary;
    g_secondary_channel = secondary;

    // Register primary channel handler if channel exists
    if (primary != null) {
        hal.interrupts.registerHandler(PRIMARY_VECTOR, primaryIrqHandler);

        // Unmask IRQ14 in PIC
        hal.pic.enableIrq(registers.PRIMARY_IRQ);

        console.info("IDE: Registered IRQ14 handler (vector {d})", .{PRIMARY_VECTOR});
    }

    // Register secondary channel handler if channel exists
    if (secondary != null) {
        hal.interrupts.registerHandler(SECONDARY_VECTOR, secondaryIrqHandler);

        // Unmask IRQ15 in PIC
        hal.pic.enableIrq(registers.SECONDARY_IRQ);

        console.info("IDE: Registered IRQ15 handler (vector {d})", .{SECONDARY_VECTOR});
    }
}

/// Unregister IRQ handlers
pub fn unregisterIrqHandlers() void {
    if (g_primary_channel != null) {
        hal.pic.disableIrq(registers.PRIMARY_IRQ);
    }

    if (g_secondary_channel != null) {
        hal.pic.disableIrq(registers.SECONDARY_IRQ);
    }

    g_controller = null;
    g_primary_channel = null;
    g_secondary_channel = null;
}

/// Enable interrupts on a channel (clear nIEN bit)
pub fn enableChannelInterrupts(channel: registers.Channel) void {
    registers.writeControl(channel, .{ .nien = false });
}

/// Disable interrupts on a channel (set nIEN bit)
pub fn disableChannelInterrupts(channel: registers.Channel) void {
    registers.writeControl(channel, .{ .nien = true });
}
