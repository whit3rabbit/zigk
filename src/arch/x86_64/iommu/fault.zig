// IOMMU Fault Handler
//
// Handles VT-d fault interrupts triggered by DMA access violations.
// When a device attempts to access memory outside its assigned IOVA space,
// the IOMMU generates a fault and optionally an interrupt.
//
// Fault reasons include:
//   - Translation fault (unmapped IOVA)
//   - Permission fault (read to write-only, or write to read-only)
//   - Invalid root/context entry
//
// Reference: Intel VT-d Spec Section 10.4 (Fault Recording)

const std = @import("std");
const console = @import("console");
const vtd = @import("vtd.zig");
const regs = @import("regs.zig");

/// Fault reason descriptions (VT-d Spec Table 10-2)
pub const FaultReason = enum(u8) {
    present_not_set_root = 0x01,
    present_not_set_context = 0x02,
    invalid_context_entry = 0x03,
    invalid_aw_context = 0x04,
    translation_fault = 0x05,
    invalid_page_table_entry = 0x06,
    root_table_error = 0x07,
    context_table_error = 0x08,
    root_reserved_bits = 0x09,
    context_reserved_bits = 0x0A,
    invalid_sp_level = 0x0B,
    pte_invalid_sp = 0x0C,
    pte_reserved_bits = 0x0D,
    _,

    pub fn description(self: FaultReason) []const u8 {
        return switch (self) {
            .present_not_set_root => "Root entry present bit not set",
            .present_not_set_context => "Context entry present bit not set",
            .invalid_context_entry => "Invalid context entry",
            .invalid_aw_context => "Invalid address width in context entry",
            .translation_fault => "Translation fault (unmapped IOVA)",
            .invalid_page_table_entry => "Invalid page table entry",
            .root_table_error => "Root table read error",
            .context_table_error => "Context table read error",
            .root_reserved_bits => "Reserved bits set in root entry",
            .context_reserved_bits => "Reserved bits set in context entry",
            .invalid_sp_level => "Invalid super page level",
            .pte_invalid_sp => "Super page with invalid address",
            .pte_reserved_bits => "Reserved bits set in PTE",
            else => "Unknown fault reason",
        };
    }
};

/// Decoded fault information for logging/debugging
pub const FaultInfo = struct {
    source_id: u16, // BDF of faulting device
    fault_addr: u64, // IOVA that caused fault
    is_write: bool, // Write (true) or read (false)
    reason: FaultReason, // Fault reason code
    domain_id: u16, // Domain ID (if available)
};

/// Process faults for all VT-d units
/// Should be called from the fault interrupt handler or periodically
pub fn processPendingFaults() u32 {
    var total_faults: u32 = 0;

    var i: u8 = 0;
    while (i < vtd.getUnitCount()) : (i += 1) {
        if (vtd.getUnit(i)) |unit| {
            const faults = unit.processFaults();
            total_faults += faults;
        }
    }

    return total_faults;
}

/// Log detailed fault information for security auditing
pub fn logFaultDetails(info: FaultInfo) void {
    const bus: u8 = @truncate(info.source_id >> 8);
    const dev: u5 = @truncate((info.source_id >> 3) & 0x1F);
    const func: u3 = @truncate(info.source_id & 0x07);

    console.err("IOMMU FAULT:", .{});
    console.err("  Device: {x:0>2}:{x:0>2}.{d}", .{ bus, dev, func });
    console.err("  Address: 0x{x:0>16}", .{info.fault_addr});
    console.err("  Type: {s}", .{if (info.is_write) "WRITE" else "READ"});
    console.err("  Reason: {s} (0x{x:0>2})", .{ info.reason.description(), @intFromEnum(info.reason) });
    console.err("  Domain: {d}", .{info.domain_id});
}

/// Check if there are any pending faults (without processing)
pub fn hasPendingFaults() bool {
    var i: u8 = 0;
    while (i < vtd.getUnitCount()) : (i += 1) {
        if (vtd.getUnit(i)) |unit| {
            const fsts = unit.readFaultStatus();
            if (fsts.ppf) return true;
        }
    }
    return false;
}

/// Get fault count for monitoring
pub fn getFaultCount() u32 {
    var count: u32 = 0;

    var i: u8 = 0;
    while (i < vtd.getUnitCount()) : (i += 1) {
        if (vtd.getUnit(i)) |unit| {
            const fsts = unit.readFaultStatus();
            if (fsts.ppf) {
                // Count pending faults (actual count requires reading FRCD registers)
                count += 1;
            }
        }
    }

    return count;
}

/// Interrupt handler for IOMMU faults
/// Called from the interrupt dispatch table when a VT-d fault interrupt fires
pub fn handleFaultInterrupt() void {
    const faults = processPendingFaults();

    if (faults > 0) {
        console.warn("IOMMU: Processed {d} DMA fault(s)", .{faults});
    }
}

/// Initialize fault handling (called during IOMMU init)
/// Currently just logs status; interrupt routing is platform-specific
pub fn init() void {
    // Check if any units have pending faults from before our init
    if (hasPendingFaults()) {
        console.warn("IOMMU: Clearing {d} pre-existing fault(s)", .{processPendingFaults()});
    }

    console.info("IOMMU: Fault handler initialized", .{});
}
