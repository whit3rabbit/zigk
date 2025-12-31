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
    .aarch64 => @import("aarch64/root.zig"),
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
pub const rtc = arch.rtc;
pub const apic = arch.apic;
pub const timing = arch.timing;
pub const smp = arch.smp;
pub const userspace = arch.userspace;
pub const iommu = arch.iommu;

// VMware hypervisor interface (x86_64 only - provides backdoor for vmmouse)
pub const vmware = if (builtin.cpu.arch == .x86_64) arch.vmware else struct {
    // Stub for non-x86_64 architectures
    pub const Registers = struct {
        eax: u32,
        ebx: u32,
        ecx: u32,
        edx: u32,
        esi: u32 = 0,
        edi: u32 = 0,
    };
    pub const BACKDOOR_MAGIC: u32 = 0;
    pub const BACKDOOR_PORT: u16 = 0;
    pub fn detect() bool {
        return false;
    }
    pub fn call(_: *Registers) void {}
};

pub fn earlyWrite(c: u8) void {
    arch.earlyWrite(c);
}

pub fn earlyPrint(msg: []const u8) void {
    arch.earlyPrint(msg);
}


/// Initialize the Hardware Abstraction Layer
/// Must be called early in kernel boot before using any HAL functions
pub fn init(hhdm_offset: u64) void {
    arch.init(hhdm_offset);
}
