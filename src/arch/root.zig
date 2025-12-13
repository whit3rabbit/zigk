// Architecture HAL Root Module
//
// Provides architecture-agnostic interface to hardware abstraction layer.
// This module selects the correct architecture implementation at compile time.
//
// Per Constitution Principle VI (Strict Layering):
// - Only src/arch/ may contain inline assembly or direct hardware access
// - Kernel code (src/kernel/, src/net/, etc.) MUST use this module
// - Never import architecture-specific modules directly outside of src/arch/

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
pub const pit = arch.pit;
pub const apic = arch.apic;
pub const timing = arch.timing;

/// Initialize the Hardware Abstraction Layer
/// Must be called early in kernel boot before using any HAL functions
pub fn init() void {
    arch.init();
}
