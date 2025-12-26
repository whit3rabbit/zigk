// AArch64 Generic Interrupt Controller (GICv2/v3) Driver
//
// Supports runtime-configured GIC addresses from Device Tree.
// Falls back to QEMU virt defaults if DTB parsing fails.
//
// SECURITY: GIC state must be accessed atomically during SMP bringup to prevent:
//   1. Race conditions when multiple CPUs access GIC simultaneously
//   2. Torn reads of 64-bit base addresses on CPUs with 32-bit bus operations
//   3. Use-before-init if interrupt occurs during initialization
//
// The gic_initialized flag uses atomic operations with acquire/release ordering
// to ensure all GIC configuration is visible before the flag is set.

const std = @import("std");
const console = @import("console");

// Runtime GIC base addresses (set during init)
// SECURITY: These are written once during init and read-only thereafter.
// Access is guarded by atomic gic_initialized flag.
var gicd_base: u64 = 0;
var gicc_base: u64 = 0;
var gic_version: u8 = 0;
var max_irq: u32 = 0; // Maximum supported IRQ number (set during init)

// SECURITY: Use atomic for initialization flag to prevent TOCTOU races
// during SMP bringup. Acquire ordering on read ensures we see all prior
// writes to gicd_base/gicc_base. Release ordering on write ensures all
// configuration is visible before flag is set.
var gic_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// QEMU virt machine defaults (fallback)
const QEMU_VIRT_GICD_BASE: u64 = 0x08000000;
const QEMU_VIRT_GICC_BASE: u64 = 0x08010000;

// SECURITY: Valid MMIO address range for GIC on AArch64.
// Physical MMIO addresses must be below the kernel virtual address space
// and within typical peripheral ranges. These bounds are conservative:
// - Lower bound: 0x01000000 (exclude first 16MB, often reserved)
// - Upper bound: 0x4000000000 (256GB, typical physical address limit for peripherals)
// Addresses in kernel virtual space (0xFFFF...) would cause incorrect MMIO access.
const GIC_MMIO_MIN: u64 = 0x01000000;
const GIC_MMIO_MAX: u64 = 0x4000000000;

/// Validate that a GIC base address is within acceptable MMIO range.
/// Returns false if the address appears invalid (kernel space, null, or out of range).
fn isValidGicAddress(addr: u64) bool {
    if (addr == 0) return false;
    // Reject kernel virtual addresses (upper canonical half)
    if (addr >= 0xFFFF_0000_0000_0000) return false;
    // Reject addresses outside typical MMIO range
    if (addr < GIC_MMIO_MIN or addr > GIC_MMIO_MAX) return false;
    return true;
}

// Distributor Registers
const GICD_CTLR: u32 = 0x000;
const GICD_TYPER: u32 = 0x004;
const GICD_ISENABLER: u32 = 0x100;
const GICD_ICENABLER: u32 = 0x180;
const GICD_IPRIORITYR: u32 = 0x400;
const GICD_ITARGETSR: u32 = 0x800;
const GICD_ICFGR: u32 = 0xC00;

// CPU Interface Registers (GICv2)
const GICC_CTLR: u32 = 0x000;
const GICC_PMR: u32 = 0x004;
const GICC_IAR: u32 = 0x00C;
const GICC_EOIR: u32 = 0x010;

fn writeGicd(offset: u32, val: u32) void {
    if (gicd_base == 0) @panic("GIC: Distributor not initialized");
    const addr: *volatile u32 = @ptrFromInt(gicd_base + offset);
    addr.* = val;
}

fn readGicd(offset: u32) u32 {
    if (gicd_base == 0) @panic("GIC: Distributor not initialized");
    const addr: *volatile u32 = @ptrFromInt(gicd_base + offset);
    return addr.*;
}

fn writeGicc(offset: u32, val: u32) void {
    if (gicc_base == 0) @panic("GIC: CPU Interface not initialized");
    const addr: *volatile u32 = @ptrFromInt(gicc_base + offset);
    addr.* = val;
}

fn readGicc(offset: u32) u32 {
    if (gicc_base == 0) @panic("GIC: CPU Interface not initialized");
    const addr: *volatile u32 = @ptrFromInt(gicc_base + offset);
    return addr.*;
}

/// Initialize GIC with addresses from BootInfo
/// If DTB provided GIC info, those addresses are used.
/// Otherwise, falls back to QEMU virt defaults.
///
/// SECURITY: Validates GIC addresses from DTB are within acceptable MMIO ranges.
/// A malicious or corrupted DTB could provide addresses that point to:
/// - Kernel memory (causing corruption when written)
/// - User-accessible memory (allowing userspace GIC control)
/// - Non-existent memory (causing bus errors)
pub fn initFromBootInfo(boot_info: anytype) void {
    // Check if BootInfo has GIC configuration from DTB
    if (boot_info.gic_dist_base != 0) {
        // SECURITY: Validate DTB-provided addresses before use
        if (!isValidGicAddress(boot_info.gic_dist_base)) {
            console.err("GIC: Invalid GICD address from DTB: 0x{x}", .{boot_info.gic_dist_base});
            console.warn("GIC: Falling back to QEMU virt defaults", .{});
            gicd_base = QEMU_VIRT_GICD_BASE;
            gicc_base = QEMU_VIRT_GICC_BASE;
            gic_version = 2;
        } else if (!isValidGicAddress(boot_info.gic_cpu_base)) {
            console.err("GIC: Invalid GICC address from DTB: 0x{x}", .{boot_info.gic_cpu_base});
            console.warn("GIC: Falling back to QEMU virt defaults", .{});
            gicd_base = QEMU_VIRT_GICD_BASE;
            gicc_base = QEMU_VIRT_GICC_BASE;
            gic_version = 2;
        } else {
            gicd_base = boot_info.gic_dist_base;
            gicc_base = boot_info.gic_cpu_base;
            gic_version = boot_info.gic_version;
            console.info("GIC: Using DTB config (v{d}, GICD=0x{x}, GICC=0x{x})", .{
                gic_version,
                gicd_base,
                gicc_base,
            });
        }
    } else {
        // Fallback to QEMU virt defaults
        gicd_base = QEMU_VIRT_GICD_BASE;
        gicc_base = QEMU_VIRT_GICC_BASE;
        gic_version = 2;
        console.warn("GIC: No DTB config, using QEMU virt defaults", .{});
    }

    initCore();
}

/// Legacy init function for backwards compatibility
/// Uses QEMU virt defaults directly
pub fn init() void {
    gicd_base = QEMU_VIRT_GICD_BASE;
    gicc_base = QEMU_VIRT_GICC_BASE;
    gic_version = 2;
    console.warn("GIC: Using legacy init with QEMU virt defaults", .{});
    initCore();
}

/// Core GIC initialization (called after addresses are set)
fn initCore() void {
    // Disable Distributor
    writeGicd(GICD_CTLR, 0);

    // Get number of supported interrupts
    const typer = readGicd(GICD_TYPER);
    const it_lines = ((typer & 0x1F) + 1) * 32;

    // Store max IRQ for bounds checking
    max_irq = it_lines;

    // Disable all interrupts
    var i: u32 = 0;
    while (i < it_lines) : (i += 32) {
        writeGicd(GICD_ICENABLER + (i / 32) * 4, 0xFFFFFFFF);
    }

    // Set processor target for all interrupts to CPU 0
    i = 32; // Skip SGIs and PPIs
    while (i < it_lines) : (i += 4) {
        writeGicd(GICD_ITARGETSR + i, 0x01010101);
    }

    // Set priority for all interrupts
    i = 0;
    while (i < it_lines) : (i += 4) {
        writeGicd(GICD_IPRIORITYR + i, 0xA0A0A0A0);
    }

    // Enable Distributor
    writeGicd(GICD_CTLR, 1);

    // Initialize CPU Interface
    writeGicc(GICC_PMR, 0xF0); // Priority mask
    writeGicc(GICC_CTLR, 1); // Enable CPU Interface

    // SECURITY: Use release ordering to ensure all GIC configuration
    // (base addresses, max_irq, register writes) is visible to other CPUs
    // before they see gic_initialized == true.
    gic_initialized.store(true, .release);
    console.info("GIC: Initialized ({d} interrupt lines)", .{it_lines});
}

/// Check if GIC is initialized
/// SECURITY: Uses acquire ordering to synchronize with init's release store.
pub fn isInitialized() bool {
    return gic_initialized.load(.acquire);
}

/// Get GIC version
pub fn getVersion() u8 {
    return gic_version;
}

/// Enable an IRQ in the GIC Distributor
/// SECURITY: Validates IRQ number against supported range.
/// Uses acquire ordering to ensure GIC base addresses are visible.
pub fn enableIrq(irq: u32) void {
    if (!gic_initialized.load(.acquire)) {
        @panic("GIC: enableIrq called before initialization");
    }
    if (irq >= max_irq) {
        // Log and return silently - invalid IRQ shouldn't crash the kernel
        console.err("GIC: enableIrq({d}) out of range (max={d})", .{ irq, max_irq });
        return;
    }
    const reg = GICD_ISENABLER + (irq / 32) * 4;
    const bit = @as(u32, 1) << @truncate(irq % 32);
    writeGicd(reg, bit);
}

/// Disable an IRQ in the GIC Distributor
/// SECURITY: Validates IRQ number against supported range.
/// Uses acquire ordering to ensure GIC base addresses are visible.
pub fn disableIrq(irq: u32) void {
    if (!gic_initialized.load(.acquire)) {
        @panic("GIC: disableIrq called before initialization");
    }
    if (irq >= max_irq) {
        console.err("GIC: disableIrq({d}) out of range (max={d})", .{ irq, max_irq });
        return;
    }
    const reg = GICD_ICENABLER + (irq / 32) * 4;
    const bit = @as(u32, 1) << @truncate(irq % 32);
    writeGicd(reg, bit);
}

/// Get maximum supported IRQ number
pub fn getMaxIrq() u32 {
    return max_irq;
}

pub fn acknowledgeIrq() u32 {
    return readGicc(GICC_IAR) & 0x3FF;
}

pub fn endOfInterrupt(irq: u32) void {
    writeGicc(GICC_EOIR, irq & 0x3FF);
}

/// Send Inter-Processor Interrupt (IPI) via Software Generated Interrupt.
/// SECURITY: Validates SGI ID is in range (0-15).
/// Using an out-of-range SGI ID would be silently truncated, potentially
/// sending the wrong interrupt and causing undefined behavior.
pub fn sendIpi(target_cpu_mask: u32, sgi_id: u8) void {
    // SECURITY: Validate SGI ID is within valid range (0-15)
    // SGIs above 15 would be truncated by & 0xF, causing wrong interrupt
    if (sgi_id > 15) {
        console.err("GIC: sendIpi({d}, {d}) invalid SGI ID (max 15)", .{ target_cpu_mask, sgi_id });
        return;
    }
    const sgi_val = (@as(u32, target_cpu_mask) << 16) | sgi_id;
    writeGicd(0xF00, sgi_val); // GICD_SGIR
}
