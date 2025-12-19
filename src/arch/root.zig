//! Hardware Abstraction Layer (HAL) Root
//!
//! Provides an architecture-agnostic interface to hardware features.
//! Selects the appropriate implementation at compile time (currently only x86_64).
//!
//! Key Responsibilities:
//! - Expose hardware features (I/O, CPU control, Interrupts, Paging) via a unified API.
//! - Enforce strict layering: Kernel code must access hardware *only* through this module.
//! - Initialization of architecture-specific subsystems.

const builtin = @import("builtin");

// Architecture selection at compile time
pub const arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("x86_64/root.zig"),
    .aarch64 => @compileError("aarch64 support not yet implemented"),
    else => @compileError("Unsupported architecture"),
};

// Re-export architecture components for convenient access
pub const io = arch.io;
pub const cpu = arch.cpu;
pub const serial = arch.serial;
pub const mem = arch.mem;
pub const paging = arch.paging;
pub const gdt = arch.gdt;
pub const idt = arch.idt;
pub const pic = arch.pic;
pub const interrupts = arch.interrupts;
pub const fpu = arch.fpu;
pub const debug = arch.debug;
pub const entropy = arch.entropy;
pub const syscall = arch.syscall;
pub const mmio = arch.mmio;
pub const mmio_device = arch.mmio_device;
pub const pit = arch.pit;
pub const apic = arch.apic;
pub const timing = arch.timing;
pub const smp = arch.smp;

/// Initialize the Hardware Abstraction Layer
/// Must be called early in kernel boot before using any HAL functions
pub fn init() void {
    arch.init();
}
