// x86_64 Architecture HAL Root Module
//
// This module re-exports all x86_64-specific hardware abstraction components.
// Kernel code should import this via the architecture-agnostic src/arch/root.zig
// to maintain portability.

pub const io = @import("lib/io.zig");
pub const cpu = @import("kernel/cpu.zig");
pub const serial = @import("serial");
pub const mem = @import("mm/mem.zig");
pub const paging = @import("mm/paging.zig");
pub const gdt = @import("kernel/gdt.zig");
pub const idt = @import("kernel/idt.zig");
pub const pic = @import("kernel/pic.zig");
pub const interrupts = @import("kernel/interrupts/root.zig");
pub const fpu = @import("kernel/fpu.zig");
pub const debug = @import("kernel/debug.zig");
pub const entropy = @import("kernel/entropy.zig");
pub const syscall = @import("kernel/syscall.zig");
pub const mmio = @import("mm/mmio.zig");
pub const mmio_device = @import("mm/mmio_device.zig");
pub const pit = @import("kernel/pit.zig");
pub const timing = @import("kernel/timing.zig");
pub const apic = @import("kernel/apic/root.zig");
pub const smp = @import("kernel/smp.zig");
pub const userspace = @import("kernel/userspace.zig");
pub const iommu = @import("mm/iommu/root.zig");
pub const vmware = @import("hypervisor/vmware.zig");

pub fn earlyWrite(c: u8) void {
    asm volatile ("outb %%al, %%dx" : : [val] "{al}" (c), [port] "{dx}" (@as(u16, 0x3F8)));
}

pub fn earlyPrint(msg: []const u8) void {
    for (msg) |c| {
        earlyWrite(c);
    }
}

/// Initialize all x86_64 HAL subsystems
pub fn init(_: u64) void {
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

    // SECURITY: Enable SMEP/SMAP if supported
    // SMEP: Supervisor Mode Execution Prevention - prevents kernel from executing user-space code
    // SMAP: Supervisor Mode Access Prevention - prevents kernel from accessing user-space memory
    //       without explicit STAC/CLAC bracketing
    initSecurityFeatures();

    // Initialize SYSCALL/SYSRET MSRs for fast system calls
    syscall.init();

    // Calibrate TSC for timing utilities (uses PIT channel 2, not channel 0)
    timing.calibrate();

    // Initialize PIT channel 0 to 100Hz for scheduler
    pit.init(100);
}

/// Enable CPU security features (SMEP, SMAP, speculation control) if supported
fn initSecurityFeatures() void {
    const console = @import("console");

    // CPUID leaf 7, subleaf 0 contains extended feature flags
    const cpuid_result = cpu.cpuid(7, 0);

    // CR4 bit definitions
    const CR4_SMEP: u64 = 1 << 20; // Supervisor Mode Execution Prevention
    const CR4_SMAP: u64 = 1 << 21; // Supervisor Mode Access Prevention

    // CPUID.07H:EBX feature bits
    const CPUID_SMEP: u32 = 1 << 7;  // Bit 7: SMEP supported
    const CPUID_SMAP: u32 = 1 << 20; // Bit 20: SMAP supported

    var cr4 = cpu.readCr4();
    var features_enabled: u32 = 0;

    // Enable SMEP if supported
    if ((cpuid_result.ebx & CPUID_SMEP) != 0) {
        cr4 |= CR4_SMEP;
        features_enabled |= 1;
    }

    // Enable SMAP if supported
    if ((cpuid_result.ebx & CPUID_SMAP) != 0) {
        cr4 |= CR4_SMAP;
        features_enabled |= 2;
    }

    if (features_enabled != 0) {
        cpu.writeCr4(cr4);

        // Log what was enabled
        if (features_enabled == 3) {
            console.info("Security: SMEP and SMAP enabled", .{});
        } else if (features_enabled == 1) {
            console.info("Security: SMEP enabled (SMAP not supported)", .{});
        } else {
            console.info("Security: SMAP enabled (SMEP not supported)", .{});
        }
    } else {
        console.warn("Security: Neither SMEP nor SMAP supported by CPU", .{});
    }

    // Initialize speculation control (Spectre mitigations)
    // This detects IBPB/STIBP/SSBD support and caches the result
    cpu.initSpeculationControl();
    if (cpu.hasIbpb()) {
        console.info("Security: IBPB (Indirect Branch Prediction Barrier) available", .{});
    } else {
        console.warn("Security: IBPB not supported - Spectre v2 mitigation unavailable", .{});
    }
}
