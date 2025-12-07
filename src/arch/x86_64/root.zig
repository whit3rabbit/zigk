// x86_64 Architecture HAL Root Module
//
// This module re-exports all x86_64-specific hardware abstraction components.
// Kernel code should import this via the architecture-agnostic src/arch/root.zig
// to maintain portability.

pub const io = @import("io.zig");
pub const cpu = @import("cpu.zig");
pub const serial = @import("serial.zig");
pub const paging = @import("paging.zig");
pub const gdt = @import("gdt.zig");
pub const idt = @import("idt.zig");
pub const pic = @import("pic.zig");
pub const interrupts = @import("interrupts.zig");

/// Initialize all x86_64 HAL subsystems
pub fn init() void {
    // Initialize serial port for debug output first
    serial.initDefault();

    // GDT and TSS setup (required before interrupts)
    gdt.init();

    // Set up PIC before IDT (remap IRQs to vectors 32-47)
    pic.init();

    // Set up IDT with interrupt handlers
    idt.init();

    // Register interrupt handlers
    interrupts.init();
}
