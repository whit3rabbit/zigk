// x86_64 Architecture HAL Root Module
//
// This module re-exports all x86_64-specific hardware abstraction components.
// Kernel code should import this via the architecture-agnostic src/arch/root.zig
// to maintain portability.

pub const io = @import("io.zig");
pub const cpu = @import("cpu.zig");
pub const serial = @import("serial.zig");

/// Initialize all x86_64 HAL subsystems
pub fn init() void {
    // Initialize serial port for debug output first
    serial.initDefault();
}
