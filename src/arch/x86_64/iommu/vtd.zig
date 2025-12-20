// Intel VT-d Hardware Unit Abstraction
//
// Provides an interface to a single VT-d IOMMU hardware unit (DRHD).
// Each unit has its own register set and can perform DMA remapping
// for a set of PCI devices.
//
// Reference: Intel VT-d Specification 3.0+, Section 10 (Programming Interface)

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const regs = @import("regs.zig");
const acpi = @import("acpi");

const paging = hal.paging;
const Offset = regs.Offset;

/// VT-d Hardware Unit
/// Represents a single IOMMU hardware unit discovered via ACPI DMAR
pub const VtdUnit = struct {
    /// Physical base address of IOMMU registers
    reg_base_phys: u64,

    /// Virtual pointer to MMIO registers (via HHDM)
    reg_base: [*]volatile u8,

    /// Cached capability register
    cap: regs.CapabilityReg,

    /// Cached extended capability register
    ecap: regs.ExtCapabilityReg,

    /// PCI segment this unit belongs to
    segment: u16,

    /// Handles all devices in segment (INCLUDE_PCI_ALL)
    include_all: bool,

    /// Maximum domain ID supported
    max_domain_id: u16,

    /// Fault recording register offset
    fault_record_offset: u32,

    /// Number of fault recording registers
    num_fault_records: u8,

    /// IOTLB register offset
    iotlb_offset: u32,

    /// Translation enabled flag
    translation_enabled: bool,

    /// Root table physical address (when set)
    root_table_phys: u64,

    const Self = @This();

    /// Initialize a VT-d unit from DRHD information
    pub fn init(drhd: *const acpi.DrhdInfo) !Self {
        // Map the IOMMU registers via HHDM
        const reg_virt = paging.physToVirt(drhd.reg_base);
        const reg_ptr: [*]volatile u8 = @ptrFromInt(reg_virt);

        var unit = Self{
            .reg_base_phys = drhd.reg_base,
            .reg_base = reg_ptr,
            .cap = undefined,
            .ecap = undefined,
            .segment = drhd.segment,
            .include_all = drhd.include_pci_all,
            .max_domain_id = 0,
            .fault_record_offset = 0,
            .num_fault_records = 0,
            .iotlb_offset = 0,
            .translation_enabled = false,
            .root_table_phys = 0,
        };

        // Read and cache capability registers
        unit.cap = unit.readCapability();
        unit.ecap = unit.readExtCapability();

        // Calculate derived values
        unit.max_domain_id = @truncate(unit.cap.getMaxDomains());
        unit.fault_record_offset = unit.cap.getFaultRecordOffset();
        unit.num_fault_records = unit.cap.getNumFaultRecords();
        unit.iotlb_offset = unit.ecap.getIotlbOffset();

        // Validate minimum requirements
        if (!unit.cap.supports48BitGaw() and !unit.cap.supports39BitGaw()) {
            console.err("VT-d: Unit at 0x{x} does not support 39/48-bit guest address width", .{drhd.reg_base});
            return error.UnsupportedHardware;
        }

        return unit;
    }

    /// Read a 32-bit register
    pub fn readReg32(self: *const Self, offset: u32) u32 {
        const ptr: *volatile u32 = @ptrCast(@alignCast(self.reg_base + offset));
        return ptr.*;
    }

    /// Write a 32-bit register
    pub fn writeReg32(self: *Self, offset: u32, value: u32) void {
        const ptr: *volatile u32 = @ptrCast(@alignCast(self.reg_base + offset));
        ptr.* = value;
    }

    /// Read a 64-bit register
    pub fn readReg64(self: *const Self, offset: u32) u64 {
        const ptr: *volatile u64 = @ptrCast(@alignCast(self.reg_base + offset));
        return ptr.*;
    }

    /// Write a 64-bit register
    pub fn writeReg64(self: *Self, offset: u32, value: u64) void {
        const ptr: *volatile u64 = @ptrCast(@alignCast(self.reg_base + offset));
        ptr.* = value;
    }

    /// Read capability register
    pub fn readCapability(self: *const Self) regs.CapabilityReg {
        return @bitCast(self.readReg64(Offset.CAP));
    }

    /// Read extended capability register
    pub fn readExtCapability(self: *const Self) regs.ExtCapabilityReg {
        return @bitCast(self.readReg64(Offset.ECAP));
    }

    /// Read global status register
    pub fn readGlobalStatus(self: *const Self) regs.GlobalStsReg {
        return @bitCast(self.readReg32(Offset.GSTS));
    }

    /// Read fault status register
    pub fn readFaultStatus(self: *const Self) regs.FaultStsReg {
        return @bitCast(self.readReg32(Offset.FSTS));
    }

    /// Read version register
    pub fn readVersion(self: *const Self) regs.VersionReg {
        return @bitCast(self.readReg32(Offset.VER));
    }

    /// Set the root table address
    /// The root table must be 4KB aligned and allocated from physically contiguous memory
    pub fn setRootTable(self: *Self, phys_addr: u64) void {
        // Write root table address register
        var rtaddr = regs.RootTableAddrReg{};
        rtaddr.setAddress(phys_addr);
        rtaddr.ttm = 0; // Legacy mode (not scalable mode)
        self.writeReg64(Offset.RTADDR, @bitCast(rtaddr));

        // Issue Set Root Table Pointer command
        var gcmd = regs.GlobalCmdReg{};
        gcmd.srtp = true;
        self.writeReg32(Offset.GCMD, @bitCast(gcmd));

        // Wait for Root Table Pointer Status
        self.waitForStatus(.rtps);

        self.root_table_phys = phys_addr;
    }

    /// Enable DMA remapping (translation)
    pub fn enableTranslation(self: *Self) void {
        if (self.translation_enabled) return;

        // Flush write buffer if required
        self.flushWriteBuffer();

        // Issue Translation Enable command
        var gcmd = regs.GlobalCmdReg{};
        gcmd.te = true;
        self.writeReg32(Offset.GCMD, @bitCast(gcmd));

        // Wait for Translation Enable Status
        self.waitForStatus(.tes);

        self.translation_enabled = true;
        console.info("VT-d: Translation enabled for unit at 0x{x}", .{self.reg_base_phys});
    }

    /// Disable DMA remapping
    pub fn disableTranslation(self: *Self) void {
        if (!self.translation_enabled) return;

        // Clear Translation Enable bit
        self.writeReg32(Offset.GCMD, 0);

        // Wait for TES to clear
        while (true) {
            const gsts = self.readGlobalStatus();
            if (!gsts.tes) break;
        }

        self.translation_enabled = false;
    }

    /// Flush write buffer if required by hardware
    pub fn flushWriteBuffer(self: *Self) void {
        if (!self.cap.rwbf) return; // Not required

        // Issue Write Buffer Flush command
        var gcmd = regs.GlobalCmdReg{};
        gcmd.wbf = true;
        self.writeReg32(Offset.GCMD, @bitCast(gcmd));

        // Wait for WBF to clear (indicates completion)
        while (true) {
            const gsts = self.readGlobalStatus();
            if (!gsts.wbfs) break;
        }
    }

    /// Invalidate context cache globally
    pub fn invalidateContextGlobal(self: *Self) void {
        var ccmd = regs.ContextCmdReg{};
        ccmd.cirg = @intFromEnum(regs.ContextCmdReg.Granularity.global);
        ccmd.icc = true;
        self.writeReg64(Offset.CCMD, @bitCast(ccmd));

        // Wait for ICC to clear
        while (true) {
            const val: regs.ContextCmdReg = @bitCast(self.readReg64(Offset.CCMD));
            if (!val.icc) break;
        }
    }

    /// Invalidate context cache for a specific domain
    pub fn invalidateContextDomain(self: *Self, domain_id: u16) void {
        var ccmd = regs.ContextCmdReg{};
        ccmd.did = domain_id;
        ccmd.cirg = @intFromEnum(regs.ContextCmdReg.Granularity.domain);
        ccmd.icc = true;
        self.writeReg64(Offset.CCMD, @bitCast(ccmd));

        // Wait for ICC to clear
        while (true) {
            const val: regs.ContextCmdReg = @bitCast(self.readReg64(Offset.CCMD));
            if (!val.icc) break;
        }
    }

    /// Invalidate IOTLB globally
    pub fn invalidateIotlbGlobal(self: *Self) void {
        const iotlb_offset = if (self.iotlb_offset != 0) self.iotlb_offset else Offset.IOTLB_BASE;

        var iotlb = regs.IotlbInvReg{};
        iotlb.iirg = @intFromEnum(regs.IotlbInvReg.Granularity.global);
        iotlb.ivt = true;

        // Drain reads and writes if supported
        if (self.cap.drd) iotlb.dr = true;
        if (self.cap.dwd) iotlb.dw = true;

        self.writeReg64(iotlb_offset, @bitCast(iotlb));

        // Wait for IVT to clear
        while (true) {
            const val: regs.IotlbInvReg = @bitCast(self.readReg64(iotlb_offset));
            if (!val.ivt) break;
        }
    }

    /// Invalidate IOTLB for a specific domain
    pub fn invalidateIotlbDomain(self: *Self, domain_id: u16) void {
        const iotlb_offset = if (self.iotlb_offset != 0) self.iotlb_offset else Offset.IOTLB_BASE;

        var iotlb = regs.IotlbInvReg{};
        iotlb.did = domain_id;
        iotlb.iirg = @intFromEnum(regs.IotlbInvReg.Granularity.domain);
        iotlb.ivt = true;

        if (self.cap.drd) iotlb.dr = true;
        if (self.cap.dwd) iotlb.dw = true;

        self.writeReg64(iotlb_offset, @bitCast(iotlb));

        // Wait for IVT to clear
        while (true) {
            const val: regs.IotlbInvReg = @bitCast(self.readReg64(iotlb_offset));
            if (!val.ivt) break;
        }
    }

    /// Process pending fault records
    /// Returns number of faults processed
    pub fn processFaults(self: *Self) u8 {
        const fsts = self.readFaultStatus();
        if (!fsts.ppf) return 0; // No pending faults

        var processed: u8 = 0;
        var index = fsts.fri;

        while (processed < self.num_fault_records) {
            const frcd_offset = self.fault_record_offset + @as(u32, index) * 16;

            // Read fault record (128 bits = 2 x 64 bits)
            const frcd_lo: regs.FaultRecordLo = @bitCast(self.readReg64(frcd_offset));
            const frcd_hi: regs.FaultRecordHi = @bitCast(self.readReg64(frcd_offset + 8));

            if (!frcd_hi.f) break; // No more valid fault records

            // Log the fault
            const source_id = frcd_hi.sid;
            const fault_addr = frcd_lo.getFaultAddress();
            const is_write = frcd_hi.t2;

            console.err("VT-d FAULT: Device {x:0>4}h addr=0x{x} {s} reason={d}", .{
                source_id,
                fault_addr,
                if (is_write) "WRITE" else "READ",
                frcd_hi.fr,
            });

            // Clear the fault by writing 1 to F bit
            self.writeReg64(frcd_offset + 8, @bitCast(frcd_hi));

            processed += 1;
            index = (index + 1) % self.num_fault_records;
        }

        // Clear primary fault status by writing 1 to PFO
        if (fsts.pfo) {
            self.writeReg32(Offset.FSTS, 1); // Write 1 to bit 0 to clear PFO
        }

        return processed;
    }

    /// Enable fault event interrupts
    pub fn enableFaultInterrupt(self: *Self) void {
        // Clear interrupt mask
        const fectl = regs.FaultEvtCtrlReg{
            .ip = false,
            .im = false,
        };
        self.writeReg32(Offset.FECTL, @bitCast(fectl));
    }

    /// Disable fault event interrupts
    pub fn disableFaultInterrupt(self: *Self) void {
        const fectl = regs.FaultEvtCtrlReg{
            .ip = false,
            .im = true,
        };
        self.writeReg32(Offset.FECTL, @bitCast(fectl));
    }

    /// Wait for a specific status bit to be set
    fn waitForStatus(self: *const Self, comptime status: enum { rtps, tes, ires, qies }) void {
        const max_iterations: u32 = 1_000_000;
        var i: u32 = 0;

        while (i < max_iterations) : (i += 1) {
            const gsts = self.readGlobalStatus();
            const done = switch (status) {
                .rtps => gsts.rtps,
                .tes => gsts.tes,
                .ires => gsts.ires,
                .qies => gsts.qies,
            };
            if (done) return;

            // Small delay
            asm volatile ("pause");
        }

        console.warn("VT-d: Timeout waiting for status {s}", .{@tagName(status)});
    }

    /// Log unit information for debugging
    pub fn logInfo(self: *const Self) void {
        const ver = self.readVersion();
        console.info("VT-d Unit at 0x{x}:", .{self.reg_base_phys});
        console.info("  Version: {d}.{d}", .{ ver.major, ver.minor });
        console.info("  Max domains: {d}", .{self.max_domain_id + 1});
        console.info("  Max guest addr width: {d} bits", .{self.cap.getMaxGuestAddrWidth()});
        console.info("  48-bit GAW: {}, 39-bit GAW: {}", .{ self.cap.supports48BitGaw(), self.cap.supports39BitGaw() });
        console.info("  Write buffer flush required: {}", .{self.cap.rwbf});
        console.info("  Page-selective invalidation: {}", .{self.cap.psi});
        console.info("  Queued invalidation: {}", .{self.ecap.qi});
        console.info("  Interrupt remapping: {}", .{self.ecap.ir});
        console.info("  Fault records: {d} at offset 0x{x}", .{ self.num_fault_records, self.fault_record_offset });
        console.info("  IOTLB offset: 0x{x}", .{self.iotlb_offset});
    }
};

/// Global array of initialized VT-d units
var units: [8]?VtdUnit = [_]?VtdUnit{null} ** 8;
var unit_count: u8 = 0;

/// Register an initialized unit
pub fn registerUnit(unit: VtdUnit) void {
    if (unit_count < units.len) {
        units[unit_count] = unit;
        unit_count += 1;
    }
}

/// Get number of registered units
pub fn getUnitCount() u8 {
    return unit_count;
}

/// Get a unit by index
pub fn getUnit(index: u8) ?*VtdUnit {
    if (index >= unit_count) return null;
    return if (units[index]) |*u| u else null;
}

/// Find the unit responsible for a PCI device
pub fn findUnitForDevice(segment: u16, bus: u8, device: u5, func: u3) ?*VtdUnit {
    // First check units with explicit device scope
    for (0..unit_count) |i| {
        if (units[i]) |*unit| {
            if (unit.segment == segment and !unit.include_all) {
                // Check if device is in this unit's scope
                // For now, return first matching segment non-include-all unit
                // Full implementation would check DRHD device scope list
                _ = bus;
                _ = device;
                _ = func;
            }
        }
    }

    // Fall back to INCLUDE_PCI_ALL unit
    for (0..unit_count) |i| {
        if (units[i]) |*unit| {
            if (unit.segment == segment and unit.include_all) {
                return unit;
            }
        }
    }

    return null;
}
