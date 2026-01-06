// PCI MSI/MSI-X Configuration
//
// Configures Message Signaled Interrupts for PCI devices.
// MSI/MSI-X deliver interrupts as memory writes rather than using
// dedicated interrupt lines, enabling better interrupt targeting and
// lower latency.
//
// x86_64 MSI Address Format (Intel):
//   Bits 31:20 = 0xFEE (fixed value for local APIC)
//   Bits 19:12 = Destination APIC ID
//   Bit 11     = Redirection Hint (0 for fixed delivery)
//   Bit 10     = Destination Mode (0 = physical, 1 = logical)
//   Bits 9:4   = Reserved
//   Bits 3:2   = Address modification (for Redirectable MSI, 0 for normal)
//   Bits 1:0   = Reserved (must be 0)
//
// x86_64 MSI Data Format:
//   Bits 15:14 = Trigger Mode (0 = edge, 1 = level)
//   Bit 13     = Level for level-triggered (0 = deassert, 1 = assert)
//   Bits 12:11 = Reserved
//   Bits 10:8  = Delivery Mode (000 = fixed, 001 = lowest priority)
//   Bits 7:0   = Vector
//
// Reference: Intel 64 Architecture Manual Vol 3A, Section 10.11

const std = @import("std");
const ecam = @import("ecam.zig");
const device = @import("device.zig");
const capabilities = @import("capabilities.zig");
const vmm = @import("vmm");
const console = @import("console");
const hal = @import("hal");

const Ecam = ecam.Ecam;
const PciDevice = device.PciDevice;
const MsiCapability = capabilities.MsiCapability;
const MsixCapability = capabilities.MsixCapability;
const MsiMessageControl = capabilities.MsiMessageControl;
const MsixMessageControl = capabilities.MsixMessageControl;

fn msixTableWriteFence() void {
    // Ensure MSI-X table updates are visible before vectors are unmasked.
    hal.mmio.writeBarrier();
}

// ============================================================================
// x86_64 MSI Address/Data Building
// ============================================================================

/// Build MSI address value for x86_64
/// Returns the address to be written to MSI Message Address register
pub fn buildMsiAddress(dest_apic_id: u8, dest_mode: DestinationMode, redirection_hint: bool) u64 {
    var addr: u64 = 0xFEE00000; // Fixed prefix for local APIC region

    // Destination APIC ID in bits 19:12
    addr |= (@as(u64, dest_apic_id) << 12);

    // Redirection hint in bit 11
    if (redirection_hint) {
        addr |= (1 << 11);
    }

    // Destination mode in bit 10
    if (dest_mode == .logical) {
        addr |= (1 << 10);
    }

    return addr;
}

/// Build MSI address with default settings (physical mode, no redirection)
pub fn buildMsiAddressSimple(dest_apic_id: u8) u64 {
    return buildMsiAddress(dest_apic_id, .physical, false);
}

/// Build MSI data value for x86_64
/// Returns the value to be written to MSI Message Data register
pub fn buildMsiData(vector: u8, delivery_mode: DeliveryMode, trigger_mode: TriggerMode) u32 {
    var data: u32 = 0;

    // Vector in bits 7:0
    data |= @as(u32, vector);

    // Delivery mode in bits 10:8
    data |= (@as(u32, @intFromEnum(delivery_mode)) << 8);

    // Trigger mode in bit 15 (0 = edge, 1 = level)
    if (trigger_mode == .level) {
        data |= (1 << 15);
        // For level-triggered, also set assert bit (bit 14)
        data |= (1 << 14);
    }

    return data;
}

/// Build MSI data with default settings (edge-triggered, fixed delivery)
pub fn buildMsiDataSimple(vector: u8) u32 {
    return buildMsiData(vector, .fixed, .edge);
}

/// Destination mode for MSI address
pub const DestinationMode = enum(u1) {
    physical = 0,
    logical = 1,
};

/// Delivery mode for MSI data
pub const DeliveryMode = enum(u3) {
    fixed = 0b000, // Deliver to all processors listed in destination
    lowest_priority = 0b001, // Deliver to lowest priority processor
    smi = 0b010, // System Management Interrupt
    nmi = 0b100, // Non-Maskable Interrupt
    init = 0b101, // INIT signal
    extint = 0b111, // External interrupt
};

/// Trigger mode for MSI data
pub const TriggerMode = enum(u1) {
    edge = 0,
    level = 1,
};

// ============================================================================
// MSI Configuration
// ============================================================================

/// MSI register offsets relative to capability start
const MsiRegs = struct {
    const MSG_CTRL: u12 = 2; // Message Control (16-bit)
    const MSG_ADDR_LO: u12 = 4; // Message Address Low (32-bit)
    const MSG_ADDR_HI: u12 = 8; // Message Address High (32-bit, 64-bit capable only)
    const MSG_DATA_32: u12 = 8; // Message Data for 32-bit capable
    const MSG_DATA_64: u12 = 12; // Message Data for 64-bit capable
    const MASK_32: u12 = 12; // Mask bits for 32-bit (if per-vector masking)
    const MASK_64: u12 = 16; // Mask bits for 64-bit (if per-vector masking)
    const PENDING_32: u12 = 16; // Pending bits for 32-bit
    const PENDING_64: u12 = 20; // Pending bits for 64-bit
};

/// Enable MSI for a device
/// Returns true on success
pub fn enableMsi(
    pci_ecam: *const Ecam,
    dev: *const PciDevice,
    msi_cap: *const MsiCapability,
    vector: u8,
    dest_apic_id: u8,
) bool {
    const base: u12 = msi_cap.offset;

    // Build address and data
    const addr = buildMsiAddressSimple(dest_apic_id);
    const data = buildMsiDataSimple(vector);

    // Write message address
    pci_ecam.write32(dev.bus, dev.device, dev.func, base + MsiRegs.MSG_ADDR_LO, @truncate(addr));

    if (msi_cap.is_64bit) {
        pci_ecam.write32(dev.bus, dev.device, dev.func, base + MsiRegs.MSG_ADDR_HI, @truncate(addr >> 32));
        pci_ecam.write16(dev.bus, dev.device, dev.func, base + MsiRegs.MSG_DATA_64, @truncate(data));
    } else {
        pci_ecam.write16(dev.bus, dev.device, dev.func, base + MsiRegs.MSG_DATA_32, @truncate(data));
    }

    // Read current message control
    const msg_ctrl_raw = pci_ecam.read16(dev.bus, dev.device, dev.func, base + MsiRegs.MSG_CTRL);
    var msg_ctrl: MsiMessageControl = @bitCast(msg_ctrl_raw);

    // Request only 1 vector (multiple_message_enable = 0)
    msg_ctrl.multiple_message_enable = 0;

    // Enable MSI
    msg_ctrl.enable = true;

    // Write back message control
    pci_ecam.write16(dev.bus, dev.device, dev.func, base + MsiRegs.MSG_CTRL, @bitCast(msg_ctrl));

    console.info("MSI: Enabled for {x}:{x}.{x} vector={d} dest={d}", .{
        dev.bus, dev.device, dev.func, vector, dest_apic_id,
    });

    return true;
}

/// Disable MSI for a device
pub fn disableMsi(
    pci_ecam: *const Ecam,
    dev: *const PciDevice,
    msi_cap: *const MsiCapability,
) void {
    const base: u12 = msi_cap.offset;

    // Read current message control
    const msg_ctrl_raw = pci_ecam.read16(dev.bus, dev.device, dev.func, base + MsiRegs.MSG_CTRL);
    var msg_ctrl: MsiMessageControl = @bitCast(msg_ctrl_raw);

    // Disable MSI
    msg_ctrl.enable = false;

    // Write back
    pci_ecam.write16(dev.bus, dev.device, dev.func, base + MsiRegs.MSG_CTRL, @bitCast(msg_ctrl));
}

// ============================================================================
// MSI-X Configuration
// ============================================================================

/// MSI-X table entry (16 bytes, in BAR memory)
pub const MsixTableEntry = extern struct {
    msg_addr_lo: u32, // Message Address Low
    msg_addr_hi: u32, // Message Address High
    msg_data: u32, // Message Data
    vector_ctrl: u32, // Vector Control (bit 0 = masked)

    comptime {
        if (@sizeOf(@This()) != 16) @compileError("MsixTableEntry must be 16 bytes");
    }
};

/// MSI-X register offsets relative to capability start
const MsixRegs = struct {
    const MSG_CTRL: u12 = 2; // Message Control (16-bit)
    const TABLE_OFFSET: u12 = 4; // Table offset/BIR (32-bit)
    const PBA_OFFSET: u12 = 8; // PBA offset/BIR (32-bit)
};

/// MSI-X allocation result
pub const MsixAllocation = struct {
    /// Virtual address of MSI-X table
    table_base: u64,
    /// Number of vectors allocated
    vector_count: u16,
    /// Starting vector number
    first_vector: u8,
};

/// Enable MSI-X for a device
/// bar_virt should be the virtual address of the BAR containing the MSI-X table
/// (pass 0 to let this function attempt to map it)
///
/// SECURITY: Validates that table_size does not exceed BAR bounds to prevent
/// malicious devices from causing out-of-bounds memory writes.
pub fn enableMsix(
    pci_ecam: *const Ecam,
    dev: *const PciDevice,
    msix_cap: *const MsixCapability,
    bar_virt: u64,
) ?MsixAllocation {
    var table_base = bar_virt;
    var bar_size: u64 = 0;

    // If caller didn't provide BAR mapping, we need to get BAR address
    if (table_base == 0) {
        const bar_index = msix_cap.table_bir;

        // SECURITY: Validate table_bir is within valid BAR range (0-5).
        // table_bir is a u3 (0-7) but dev.bar is [6]Bar. A malicious device
        // could report table_bir=6 or 7, causing out-of-bounds array access.
        if (bar_index > 5) {
            console.err("MSI-X: SECURITY - Invalid BAR index {d} in capability (max 5)", .{bar_index});
            return null;
        }

        const bar_info = dev.bar[bar_index];

        if (!bar_info.isValid() or !bar_info.is_mmio) {
            console.err("MSI-X: BAR{d} not valid for MSI-X table", .{bar_index});
            return null;
        }

        bar_size = bar_info.size;

        // Map the BAR region
        table_base = vmm.mapMmio(bar_info.base, bar_info.size) catch |err| {
            console.err("MSI-X: Failed to map BAR{d}: {}", .{ bar_index, err });
            return null;
        };
    } else {
        // Caller provided BAR mapping - get size from device
        const bar_index = msix_cap.table_bir;

        // SECURITY: Validate table_bir even when caller provides BAR mapping.
        // Same OOB risk as above.
        if (bar_index > 5) {
            console.err("MSI-X: SECURITY - Invalid BAR index {d} in capability (max 5)", .{bar_index});
            return null;
        }

        bar_size = dev.bar[bar_index].size;
    }

    // SECURITY: Validate table_size against BAR bounds to prevent OOB writes
    // from malicious devices reporting inflated table_size values.
    // Each MSI-X table entry is 16 bytes.
    const table_end_offset = msix_cap.table_offset + (@as(u64, msix_cap.table_size) * 16);
    if (table_end_offset > bar_size) {
        console.err("MSI-X: SECURITY - table extends beyond BAR (offset={x} + size={d}*16 > bar_size={x})", .{
            msix_cap.table_offset,
            msix_cap.table_size,
            bar_size,
        });
        return null;
    }

    // SECURITY: Validate PBA (Pending Bit Array) bounds.
    // The PBA may be in the same BAR as the table or a different BAR.
    // PBA size = ceil(table_size / 64) * 8 bytes (64 bits per QWORD, 8 bytes per QWORD).
    // A malicious device could report pba_bir pointing to an invalid BAR or
    // pba_offset extending beyond the BAR, causing OOB reads when drivers check pending bits.
    {
        const pba_bar_index = msix_cap.pba_bir;
        if (pba_bar_index > 5) {
            console.err("MSI-X: SECURITY - Invalid PBA BAR index {d} (max 5)", .{pba_bar_index});
            return null;
        }

        const pba_bar = dev.bar[pba_bar_index];
        if (!pba_bar.isValid() or !pba_bar.is_mmio) {
            console.err("MSI-X: PBA BAR{d} not valid or not MMIO", .{pba_bar_index});
            return null;
        }

        // PBA size calculation: ceil(table_size / 64) QWORDs, each 8 bytes
        // Equivalent to: ((table_size + 63) / 64) * 8
        const pba_qwords = (@as(u64, msix_cap.table_size) + 63) / 64;
        const pba_size = pba_qwords * 8;
        const pba_end_offset = std.math.add(u64, msix_cap.pba_offset, pba_size) catch {
            console.err("MSI-X: SECURITY - PBA offset overflow", .{});
            return null;
        };

        if (pba_end_offset > pba_bar.size) {
            console.err("MSI-X: SECURITY - PBA extends beyond BAR{d} (offset={x} + size={d} > bar_size={x})", .{
                pba_bar_index,
                msix_cap.pba_offset,
                pba_size,
                pba_bar.size,
            });
            return null;
        }
    }

    // Calculate table address
    const table_addr = table_base + msix_cap.table_offset;

    const base: u12 = msix_cap.offset;

    // First, mask all vectors (set function mask bit)
    const msg_ctrl_raw = pci_ecam.read16(dev.bus, dev.device, dev.func, base + MsixRegs.MSG_CTRL);
    var msg_ctrl: MsixMessageControl = @bitCast(msg_ctrl_raw);

    // Enable function mask first (masks all vectors)
    msg_ctrl.function_mask = true;
    msg_ctrl.enable = true;
    pci_ecam.write16(dev.bus, dev.device, dev.func, base + MsixRegs.MSG_CTRL, @bitCast(msg_ctrl));

    // Mask all individual vectors in the table (bounds already validated above)
    for (0..msix_cap.table_size) |i| {
        const entry_addr = table_addr + (i * 16) + 12; // vector_ctrl offset
        const ptr: *volatile u32 = @ptrFromInt(entry_addr);
        ptr.* = 1; // Set mask bit
    }
    msixTableWriteFence();

    console.info("MSI-X: Enabled for {x}:{x}.{x} table_entries={d} table_addr=0x{x}", .{
        dev.bus, dev.device, dev.func, msix_cap.table_size, table_addr,
    });

    return MsixAllocation{
        .table_base = table_addr,
        .vector_count = msix_cap.table_size,
        .first_vector = 0, // Will be configured by caller
    };
}

/// Configure a single MSI-X table entry
/// Returns false if index is out of bounds
pub fn configureMsixEntry(
    table_base: u64,
    table_size: u16,
    index: u16,
    vector: u8,
    dest_apic_id: u8,
) bool {
    // Bounds check to prevent out-of-bounds memory write
    if (index >= table_size) {
        console.err("MSI-X: Entry index {d} out of bounds (table_size={d})", .{ index, table_size });
        return false;
    }

    const entry_addr = table_base + (@as(u64, index) * 16);

    const addr = buildMsiAddressSimple(dest_apic_id);
    const data = buildMsiDataSimple(vector);

    // Write entry (masked)
    const addr_lo_ptr: *volatile u32 = @ptrFromInt(entry_addr);
    const addr_hi_ptr: *volatile u32 = @ptrFromInt(entry_addr + 4);
    const data_ptr: *volatile u32 = @ptrFromInt(entry_addr + 8);
    const ctrl_ptr: *volatile u32 = @ptrFromInt(entry_addr + 12);

    addr_lo_ptr.* = @truncate(addr);
    addr_hi_ptr.* = @truncate(addr >> 32);
    data_ptr.* = data;
    msixTableWriteFence();
    ctrl_ptr.* = 0; // Unmask this vector
    msixTableWriteFence();
    return true;
}

/// Mask a single MSI-X vector
/// Returns false if index is out of bounds
pub fn maskMsixVector(table_base: u64, table_size: u16, index: u16) bool {
    if (index >= table_size) {
        return false;
    }
    const ctrl_addr = table_base + (@as(u64, index) * 16) + 12;
    const ctrl_ptr: *volatile u32 = @ptrFromInt(ctrl_addr);
    ctrl_ptr.* = 1;
    msixTableWriteFence();
    return true;
}

/// Unmask a single MSI-X vector
/// Returns false if index is out of bounds
pub fn unmaskMsixVector(table_base: u64, table_size: u16, index: u16) bool {
    if (index >= table_size) {
        return false;
    }
    const ctrl_addr = table_base + (@as(u64, index) * 16) + 12;
    const ctrl_ptr: *volatile u32 = @ptrFromInt(ctrl_addr);
    ctrl_ptr.* = 0;
    msixTableWriteFence();
    return true;
}

/// Clear the function mask bit to enable all unmasked vectors
pub fn enableMsixVectors(
    pci_ecam: *const Ecam,
    dev: *const PciDevice,
    msix_cap: *const MsixCapability,
) void {
    const base: u12 = msix_cap.offset;
    const msg_ctrl_raw = pci_ecam.read16(dev.bus, dev.device, dev.func, base + MsixRegs.MSG_CTRL);
    var msg_ctrl: MsixMessageControl = @bitCast(msg_ctrl_raw);

    // Clear function mask to enable all individually unmasked vectors
    msg_ctrl.function_mask = false;
    pci_ecam.write16(dev.bus, dev.device, dev.func, base + MsixRegs.MSG_CTRL, @bitCast(msg_ctrl));
}

/// Disable MSI-X for a device
pub fn disableMsix(
    pci_ecam: *const Ecam,
    dev: *const PciDevice,
    msix_cap: *const MsixCapability,
) void {
    const base: u12 = msix_cap.offset;
    const msg_ctrl_raw = pci_ecam.read16(dev.bus, dev.device, dev.func, base + MsixRegs.MSG_CTRL);
    var msg_ctrl: MsixMessageControl = @bitCast(msg_ctrl_raw);

    msg_ctrl.enable = false;
    pci_ecam.write16(dev.bus, dev.device, dev.func, base + MsixRegs.MSG_CTRL, @bitCast(msg_ctrl));
}

// ============================================================================
// INTx Disable (for switching to MSI/MSI-X)
// ============================================================================

/// Disable legacy INTx interrupts when switching to MSI/MSI-X
pub fn disableIntx(pci_ecam: *const Ecam, dev: *const PciDevice) void {
    const cmd = pci_ecam.read16(dev.bus, dev.device, dev.func, device.ConfigReg.COMMAND);
    pci_ecam.write16(dev.bus, dev.device, dev.func, device.ConfigReg.COMMAND, cmd | device.Command.INTERRUPT_DISABLE);
}

/// Re-enable legacy INTx interrupts
pub fn enableIntx(pci_ecam: *const Ecam, dev: *const PciDevice) void {
    const cmd = pci_ecam.read16(dev.bus, dev.device, dev.func, device.ConfigReg.COMMAND);
    pci_ecam.write16(dev.bus, dev.device, dev.func, device.ConfigReg.COMMAND, cmd & ~device.Command.INTERRUPT_DISABLE);
}
