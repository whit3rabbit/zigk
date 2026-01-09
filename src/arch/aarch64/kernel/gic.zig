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
const paging = @import("../mm/paging.zig");

// SECURITY: GIC configuration is bundled into an immutable struct.
// We use atomic pointer swap to publish the configuration atomically.
// This prevents race conditions during SMP bringup where secondary CPUs
// could observe partial writes to individual base address variables.
//
// Memory ordering:
//   - Writer (init): stores config, then stores pointer with .release
//   - Readers: load pointer with .acquire, guaranteed to see all config fields
const GicConfig = struct {
    gicd_base: u64,
    gicc_base: u64,
    gic_version: u8,
    max_irq: u32,
};

// Static storage for the GIC configuration (written once during init)
var gic_config_storage: GicConfig = .{
    .gicd_base = 0,
    .gicc_base = 0,
    .gic_version = 0,
    .max_irq = 0,
};

// SECURITY: Atomic pointer to published configuration.
// null = not initialized, non-null = initialized and safe to read.
// Acquire ordering on load ensures we see all fields written before publish.
// Release ordering on store ensures all config writes are visible before pointer.
var gic_config_ptr: std.atomic.Value(?*const GicConfig) = std.atomic.Value(?*const GicConfig).init(null);

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

/// Get the GIC configuration atomically (acquire ordering).
/// Returns null if GIC is not initialized.
fn getConfig() ?*const GicConfig {
    return gic_config_ptr.load(.acquire);
}

/// Get GIC config or panic if not initialized.
fn getConfigOrPanic() *const GicConfig {
    return getConfig() orelse @panic("GIC: Not initialized");
}

/// Access GIC Distributor register via HHDM
/// SECURITY: Uses HHDM mapping for post-VMM safety
fn writeGicd(offset: u32, val: u32) void {
    const config = getConfigOrPanic();
    const virt = paging.physToVirt(config.gicd_base + offset);
    const addr: *volatile u32 = @ptrCast(@alignCast(virt));
    addr.* = val;
}

fn readGicd(offset: u32) u32 {
    const config = getConfigOrPanic();
    const virt = paging.physToVirt(config.gicd_base + offset);
    const addr: *volatile u32 = @ptrCast(@alignCast(virt));
    return addr.*;
}

/// Access GIC CPU Interface register via HHDM
fn writeGicc(offset: u32, val: u32) void {
    const config = getConfigOrPanic();
    const virt = paging.physToVirt(config.gicc_base + offset);
    const addr: *volatile u32 = @ptrCast(@alignCast(virt));
    addr.* = val;
}

fn readGicc(offset: u32) u32 {
    const config = getConfigOrPanic();
    const virt = paging.physToVirt(config.gicc_base + offset);
    const addr: *volatile u32 = @ptrCast(@alignCast(virt));
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
            gic_config_storage.gicd_base = QEMU_VIRT_GICD_BASE;
            gic_config_storage.gicc_base = QEMU_VIRT_GICC_BASE;
            gic_config_storage.gic_version = 2;
        } else if (!isValidGicAddress(boot_info.gic_cpu_base)) {
            console.err("GIC: Invalid GICC address from DTB: 0x{x}", .{boot_info.gic_cpu_base});
            console.warn("GIC: Falling back to QEMU virt defaults", .{});
            gic_config_storage.gicd_base = QEMU_VIRT_GICD_BASE;
            gic_config_storage.gicc_base = QEMU_VIRT_GICC_BASE;
            gic_config_storage.gic_version = 2;
        } else {
            gic_config_storage.gicd_base = boot_info.gic_dist_base;
            gic_config_storage.gicc_base = boot_info.gic_cpu_base;
            gic_config_storage.gic_version = boot_info.gic_version;
            console.info("GIC: Using DTB config (v{d}, GICD=0x{x}, GICC=0x{x})", .{
                gic_config_storage.gic_version,
                gic_config_storage.gicd_base,
                gic_config_storage.gicc_base,
            });
        }
    } else {
        // Fallback to QEMU virt defaults
        gic_config_storage.gicd_base = QEMU_VIRT_GICD_BASE;
        gic_config_storage.gicc_base = QEMU_VIRT_GICC_BASE;
        gic_config_storage.gic_version = 2;
        console.warn("GIC: No DTB config, using QEMU virt defaults", .{});
    }

    initCore();
}

/// Legacy init function for backwards compatibility
/// Uses QEMU virt defaults directly
pub fn init() void {
    gic_config_storage.gicd_base = QEMU_VIRT_GICD_BASE;
    gic_config_storage.gicc_base = QEMU_VIRT_GICC_BASE;
    gic_config_storage.gic_version = 2;
    console.warn("GIC: Using legacy init with QEMU virt defaults", .{});
    initCore();
}

/// Write to GICD during initialization (before pointer is published)
/// Uses identity mapping during early init - bootloader maps GIC as Device memory
fn writeGicdInit(offset: u32, val: u32) void {
    const phys = gic_config_storage.gicd_base + offset;
    const addr: *volatile u32 = @ptrFromInt(phys);
    // DSB+ISB sequence for QEMU TCG stability
    asm volatile ("dsb sy" ::: "memory");
    asm volatile ("isb" ::: "memory");
    addr.* = val;
    asm volatile ("dsb sy" ::: "memory");
    asm volatile ("isb" ::: "memory");
}

fn earlyPrintHex(val: u32) void {
    const hex = "0123456789abcdef";
    var buf: [10]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const shift: u5 = @truncate(i * 4);
        buf[9 - @as(usize, i)] = hex[@as(usize, (val >> shift) & 0xF)];
    }
    earlyPrint(&buf);
}

/// Read from GICD during initialization (before pointer is published)
/// Uses identity mapping during early init - bootloader maps GIC as Device memory
fn readGicdInit(offset: u32) u32 {
    const phys = gic_config_storage.gicd_base + offset;
    const addr: *volatile u32 = @ptrFromInt(phys);
    asm volatile ("dsb sy" ::: "memory");
    asm volatile ("isb" ::: "memory");
    const val = addr.*;
    asm volatile ("dsb sy" ::: "memory");
    return val;
}

/// Write to GICC during initialization (before pointer is published)
/// Uses identity mapping during early init - bootloader maps GIC as Device memory
fn writeGiccInit(offset: u32, val: u32) void {
    const phys = gic_config_storage.gicc_base + offset;
    const addr: *volatile u32 = @ptrFromInt(phys);
    asm volatile ("dsb sy" ::: "memory");
    asm volatile ("isb" ::: "memory");
    addr.* = val;
    asm volatile ("dsb sy" ::: "memory");
    asm volatile ("isb" ::: "memory");
}

/// Core GIC initialization (called after addresses are set in gic_config_storage)
/// SECURITY: Uses *Init variants that access storage directly since pointer
/// is not yet published. Publishes atomically at the end.
// Direct serial write for debugging (bypasses console lock)
fn earlyPrint(msg: []const u8) void {
    const UART_BASE: u64 = 0x09000000;
    const FR: u32 = 0x18;
    const DR: u32 = 0x00;
    const FR_TXFF: u32 = 1 << 5;

    for (msg) |c| {
        // Wait for TX FIFO to have space
        while (true) {
            const fr_ptr: *volatile u32 = @ptrFromInt(UART_BASE + FR);
            if ((fr_ptr.* & FR_TXFF) == 0) break;
        }
        const dr_ptr: *volatile u32 = @ptrFromInt(UART_BASE + DR);
        dr_ptr.* = c;
    }
}

fn initCore() void {
    // Disable Distributor
    writeGicdInit(GICD_CTLR, 0);

    // Get number of supported interrupts
    const typer = readGicdInit(GICD_TYPER);
    const it_lines = ((typer & 0x1F) + 1) * 32;

    // Store max IRQ for bounds checking
    gic_config_storage.max_irq = it_lines;

    // Disable all interrupts
    var i: u32 = 0;
    while (i < it_lines) : (i += 32) {
        writeGicdInit(GICD_ICENABLER + (i / 32) * 4, 0xFFFFFFFF);
    }

    // Set processor target for all interrupts to CPU 0
    i = 32; // Skip SGIs and PPIs
    while (i < it_lines) : (i += 4) {
        writeGicdInit(GICD_ITARGETSR + i, 0x01010101);
    }

    // Set priority for all interrupts
    i = 0;
    while (i < it_lines) : (i += 4) {
        writeGicdInit(GICD_IPRIORITYR + i, 0xA0A0A0A0);
    }

    // Enable Distributor
    writeGicdInit(GICD_CTLR, 1);

    // Initialize CPU Interface
    writeGiccInit(GICC_PMR, 0xF0); // Priority mask
    writeGiccInit(GICC_CTLR, 1); // Enable CPU Interface

    // SECURITY: Publish configuration atomically with release ordering.
    // All writes to gic_config_storage are now complete; secondary CPUs
    // that load this pointer with acquire ordering will see all fields.
    gic_config_ptr.store(&gic_config_storage, .release);
    console.info("GIC: Initialized ({d} interrupt lines)", .{it_lines});
}

/// Check if GIC is initialized
/// SECURITY: Uses acquire ordering to synchronize with init's release store.
pub fn isInitialized() bool {
    return getConfig() != null;
}

/// Get GIC version
pub fn getVersion() u8 {
    const config = getConfig() orelse return 0;
    return config.gic_version;
}

/// Enable an IRQ in the GIC Distributor
/// SECURITY: Validates IRQ number against supported range.
/// Uses checked arithmetic for register offset calculation (defense-in-depth).
pub fn enableIrq(irq: u32) void {
    const config = getConfig() orelse {
        @panic("GIC: enableIrq called before initialization");
    };
    if (irq >= config.max_irq) {
        // Log and return silently - invalid IRQ shouldn't crash the kernel
        console.err("GIC: enableIrq({d}) out of range (max={d})", .{ irq, config.max_irq });
        return;
    }
    // SECURITY: Use checked arithmetic for register offset calculation.
    // With valid max_irq bounds this cannot overflow, but defense-in-depth
    // protects against corrupted max_irq values.
    const reg_offset = std.math.mul(u32, irq / 32, 4) catch {
        console.err("GIC: enableIrq offset overflow for IRQ {d}", .{irq});
        return;
    };
    const reg = std.math.add(u32, GICD_ISENABLER, reg_offset) catch {
        console.err("GIC: enableIrq register overflow for IRQ {d}", .{irq});
        return;
    };
    const bit = @as(u32, 1) << @truncate(irq % 32);
    writeGicd(reg, bit);
}

/// Disable an IRQ in the GIC Distributor
/// SECURITY: Validates IRQ number against supported range.
/// Uses checked arithmetic for register offset calculation (defense-in-depth).
pub fn disableIrq(irq: u32) void {
    const config = getConfig() orelse {
        @panic("GIC: disableIrq called before initialization");
    };
    if (irq >= config.max_irq) {
        console.err("GIC: disableIrq({d}) out of range (max={d})", .{ irq, config.max_irq });
        return;
    }
    // SECURITY: Use checked arithmetic for register offset calculation.
    const reg_offset = std.math.mul(u32, irq / 32, 4) catch {
        console.err("GIC: disableIrq offset overflow for IRQ {d}", .{irq});
        return;
    };
    const reg = std.math.add(u32, GICD_ICENABLER, reg_offset) catch {
        console.err("GIC: disableIrq register overflow for IRQ {d}", .{irq});
        return;
    };
    const bit = @as(u32, 1) << @truncate(irq % 32);
    writeGicd(reg, bit);
}

/// Get maximum supported IRQ number
pub fn getMaxIrq() u32 {
    const config = getConfig() orelse return 0;
    return config.max_irq;
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
