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
pub const fpu = @import("fpu.zig");
pub const debug = @import("debug.zig");
pub const entropy = @import("entropy.zig");
pub const syscall = @import("syscall.zig");
pub const mmio = @import("mmio.zig");
pub const mmio_device = @import("mmio_device.zig");
pub const pit = @import("pit.zig");
pub const timing = @import("timing.zig");
pub const apic = @import("apic/root.zig");
pub const smp = @import("smp.zig");

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

    // Initialize FPU subsystem for state save/restore
    fpu.init();

    // Initialize SYSCALL/SYSRET MSRs for fast system calls
    syscall.init();

    // Calibrate TSC for timing utilities (uses PIT channel 2, not channel 0)
    timing.calibrate();

    // Initialize PIT channel 0 to 100Hz for scheduler
    pit.init(100);
}
