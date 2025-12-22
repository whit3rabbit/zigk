// ACPI MADT (Multiple APIC Description Table) Parser
//
// Parses the MADT table (signature "APIC") to discover:
// - Local APIC base address
// - I/O APIC entries with GSI base
// - Interrupt Source Overrides for ISA IRQ remapping
// - Local APIC entries for each processor
//
// Reference: ACPI Specification 6.4, Section 5.2.12

const std = @import("std");
const hal = @import("hal");
const console = @import("console");

// Use local imports within the acpi module
const rsdp = @import("rsdp.zig");

const paging = hal.paging;
const SdtHeader = rsdp.SdtHeader;

/// MADT table signature
pub const MADT_SIGNATURE: [4]u8 = "APIC".*;

/// Maximum number of I/O APICs to track
pub const MAX_IO_APICS: usize = 8;

/// Maximum number of CPUs (Local APICs) to track
pub const MAX_CPUS: usize = 256;

/// MADT Entry Type IDs (ACPI 6.4 Table 5-44)
pub const EntryType = enum(u8) {
    processor_local_apic = 0,
    io_apic = 1,
    interrupt_source_override = 2,
    nmi_source = 3,
    local_apic_nmi = 4,
    local_apic_address_override = 5,
    io_sapic = 6,
    local_sapic = 7,
    platform_interrupt_sources = 8,
    processor_local_x2apic = 9,
    local_x2apic_nmi = 10,
    gic_cpu_interface = 11,
    gic_distributor = 12,
    gic_msi_frame = 13,
    gic_redistributor = 14,
    gic_its = 15,
    multiprocessor_wakeup = 16,
    _,
};

/// Polarity for interrupt source overrides
pub const Polarity = enum(u2) {
    conform = 0,      // Conforms to bus specifications
    active_high = 1,
    reserved = 2,
    active_low = 3,
};

/// Trigger mode for interrupt source overrides
pub const TriggerMode = enum(u2) {
    conform = 0,      // Conforms to bus specifications
    edge = 1,
    reserved = 2,
    level = 3,
};

/// MADT Header (fixed part after SdtHeader)
pub const MadtHeader = extern struct {
    header: SdtHeader,
    local_apic_addr: u32,      // Physical address of Local APIC
    flags: MadtFlags,          // MADT flags

    comptime {
        if (@sizeOf(@This()) != 44) @compileError("MadtHeader must be 44 bytes");
    }
};

/// MADT flags
pub const MadtFlags = packed struct(u32) {
    pcat_compat: bool,        // Bit 0: Dual 8259 PICs installed
    _reserved: u31 = 0,
};

/// Common entry header for all MADT entries
pub const EntryHeader = extern struct {
    entry_type: u8,
    length: u8,

    comptime {
        if (@sizeOf(@This()) != 2) @compileError("EntryHeader must be 2 bytes");
    }
};

/// Processor Local APIC entry (type 0)
pub const ProcessorLocalApicEntry = extern struct {
    header: EntryHeader,
    acpi_processor_uid: u8,    // ACPI Processor UID
    apic_id: u8,               // Processor's local APIC ID
    flags: LocalApicFlags,     // Flags

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("ProcessorLocalApicEntry must be 8 bytes");
    }
};

/// Local APIC flags
pub const LocalApicFlags = packed struct(u32) {
    enabled: bool,             // Bit 0: Processor is usable
    online_capable: bool,      // Bit 1: Processor can be enabled at runtime
    _reserved: u30 = 0,
};

/// I/O APIC entry (type 1)
pub const IoApicEntry = extern struct {
    header: EntryHeader,
    io_apic_id: u8,
    reserved: u8,
    io_apic_addr: u32,         // Physical address of I/O APIC registers
    gsi_base: u32,             // Global System Interrupt base

    comptime {
        if (@sizeOf(@This()) != 12) @compileError("IoApicEntry must be 12 bytes");
    }
};

/// Interrupt Source Override entry (type 2)
/// Maps ISA IRQs to Global System Interrupts
pub const InterruptSourceOverrideEntry = extern struct {
    header: EntryHeader,
    bus: u8,                   // 0 = ISA
    source: u8,                // Bus-relative IRQ (ISA IRQ number)
    gsi: u32 align(1),         // Global System Interrupt this maps to
    flags: IntiFlags align(1), // Polarity and trigger mode

    comptime {
        if (@sizeOf(@This()) != 10) @compileError("InterruptSourceOverrideEntry must be 10 bytes");
    }
};

/// INTI (Interrupt Input) flags for polarity and trigger mode
pub const IntiFlags = packed struct(u16) {
    polarity: Polarity,        // Bits 0-1
    trigger_mode: TriggerMode, // Bits 2-3
    _reserved: u12 = 0,
};

/// NMI Source entry (type 3)
pub const NmiSourceEntry = extern struct {
    header: EntryHeader,
    flags: IntiFlags,
    gsi: u32,                  // GSI that NMI is connected to

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("NmiSourceEntry must be 8 bytes");
    }
};

/// Local APIC NMI entry (type 4)
pub const LocalApicNmiEntry = extern struct {
    header: EntryHeader,
    acpi_processor_uid: u8,    // 0xFF means all processors
    flags: IntiFlags align(1),
    local_apic_lint: u8,       // LINT# (0 or 1)

    comptime {
        if (@sizeOf(@This()) != 6) @compileError("LocalApicNmiEntry must be 6 bytes");
    }
};

/// Local APIC Address Override entry (type 5)
/// Overrides the 32-bit address in MADT header with 64-bit address
pub const LocalApicAddressOverrideEntry = extern struct {
    header: EntryHeader,
    reserved: u16,
    local_apic_addr: u64 align(1),  // 64-bit physical address

    comptime {
        if (@sizeOf(@This()) != 12) @compileError("LocalApicAddressOverrideEntry must be 12 bytes");
    }
};

/// Processor Local x2APIC entry (type 9)
pub const ProcessorLocalX2ApicEntry = extern struct {
    header: EntryHeader,
    reserved: u16,
    x2apic_id: u32,            // Processor's x2APIC ID
    flags: LocalApicFlags,     // Same flags as type 0
    acpi_processor_uid: u32,   // ACPI Processor UID

    comptime {
        if (@sizeOf(@This()) != 16) @compileError("ProcessorLocalX2ApicEntry must be 16 bytes");
    }
};

/// Parsed I/O APIC information
pub const IoApicInfo = struct {
    id: u8,
    addr: u64,                 // Physical address
    gsi_base: u32,
};

/// Parsed interrupt source override
pub const InterruptOverride = struct {
    source_irq: u8,            // Original ISA IRQ
    gsi: u32,                  // Mapped GSI
    polarity: Polarity,
    trigger_mode: TriggerMode,
};

/// Parsed Local APIC NMI configuration
pub const LocalApicNmi = struct {
    processor_uid: u8,         // 0xFF = all processors
    lint: u8,                  // LINT pin (0 or 1)
    polarity: Polarity,
    trigger_mode: TriggerMode,
};

/// Complete parsed MADT information
pub const MadtInfo = struct {
    /// Local APIC physical address (may be overridden by type 5 entry)
    local_apic_addr: u64,

    /// Dual 8259 PICs are installed (should be disabled when using APIC)
    pcat_compat: bool,

    /// I/O APICs
    io_apics: [MAX_IO_APICS]IoApicInfo,
    io_apic_count: u8,

    /// Interrupt source overrides (ISA IRQ remapping)
    /// Index by ISA IRQ number (0-15)
    overrides: [16]?InterruptOverride,

    /// Local APIC IDs for enabled processors
    lapic_ids: [MAX_CPUS]u8,
    lapic_count: u16,

    /// Local APIC NMI configuration
    lapic_nmis: [8]LocalApicNmi,
    lapic_nmi_count: u8,

    /// x2APIC IDs (if present, for systems with >255 CPUs)
    x2apic_ids: [MAX_CPUS]u32,
    x2apic_count: u16,

    /// Get the GSI for a legacy ISA IRQ, applying any overrides
    pub fn getGsiForIrq(self: *const MadtInfo, irq: u8) u32 {
        if (irq < 16) {
            if (self.overrides[irq]) |override| {
                return override.gsi;
            }
        }
        // Identity mapping if no override
        return irq;
    }

    /// Get override info for an IRQ (polarity/trigger mode)
    pub fn getOverrideInfo(self: *const MadtInfo, irq: u8) ?InterruptOverride {
        if (irq < 16) {
            return self.overrides[irq];
        }
        return null;
    }

    /// Find which I/O APIC handles a given GSI
    pub fn findIoApicForGsi(self: *const MadtInfo, gsi: u32) ?*const IoApicInfo {
        for (self.io_apics[0..self.io_apic_count]) |*ioapic| {
            // Each I/O APIC handles 24 GSIs starting at gsi_base
            // (actual count comes from I/O APIC version register)
            if (gsi >= ioapic.gsi_base and gsi < ioapic.gsi_base + 24) {
                return ioapic;
            }
        }
        return null;
    }
};

/// Parse MADT table from RSDP
pub fn parse(rsdp_ptr: *align(1) const rsdp.Rsdp) ?MadtInfo {
    const madt_header = rsdp.findTable(rsdp_ptr, MADT_SIGNATURE) orelse {
        console.warn("MADT: Table not found", .{});
        return null;
    };

    return parseFromHeader(madt_header);
}

/// Parse MADT from a direct table pointer
pub fn parseFromHeader(header: *align(1) const SdtHeader) ?MadtInfo {
    if (!header.hasSignature(MADT_SIGNATURE)) {
        console.warn("MADT: Invalid signature", .{});
        return null;
    }

    if (!header.validateChecksum()) {
        console.warn("MADT: Checksum validation failed", .{});
        return null;
    }

    const madt: *align(1) const MadtHeader = @ptrCast(header);

    var info = MadtInfo{
        .local_apic_addr = madt.local_apic_addr,
        .pcat_compat = madt.flags.pcat_compat,
        .io_apics = undefined,
        .io_apic_count = 0,
        .overrides = [_]?InterruptOverride{null} ** 16,
        .lapic_ids = undefined,
        .lapic_count = 0,
        .lapic_nmis = undefined,
        .lapic_nmi_count = 0,
        .x2apic_ids = undefined,
        .x2apic_count = 0,
    };

    // Get the entry data (after fixed header)
    const entry_data = getEntryData(madt);
    if (entry_data.len == 0) {
        console.warn("MADT: No entries found", .{});
        return info;
    }

    // Iterate through all entries
    var offset: usize = 0;
    while (offset + @sizeOf(EntryHeader) <= entry_data.len) {
        const entry_ptr: *align(1) const EntryHeader = @ptrCast(&entry_data[offset]);

        // Validate entry length
        if (entry_ptr.length < @sizeOf(EntryHeader) or
            offset + entry_ptr.length > entry_data.len)
        {
            console.warn("MADT: Invalid entry length at offset {d}", .{offset});
            break;
        }

        // Process entry based on type
        const entry_type: EntryType = @enumFromInt(entry_ptr.entry_type);
        switch (entry_type) {
            .processor_local_apic => {
                if (entry_ptr.length >= @sizeOf(ProcessorLocalApicEntry)) {
                    const entry: *align(1) const ProcessorLocalApicEntry = @ptrCast(entry_ptr);
                    if (entry.flags.enabled and info.lapic_count < MAX_CPUS) {
                        info.lapic_ids[info.lapic_count] = entry.apic_id;
                        info.lapic_count += 1;
                    }
                }
            },
            .io_apic => {
                if (entry_ptr.length >= @sizeOf(IoApicEntry)) {
                    const entry: *align(1) const IoApicEntry = @ptrCast(entry_ptr);
                    if (info.io_apic_count < MAX_IO_APICS) {
                        info.io_apics[info.io_apic_count] = .{
                            .id = entry.io_apic_id,
                            .addr = entry.io_apic_addr,
                            .gsi_base = entry.gsi_base,
                        };
                        info.io_apic_count += 1;
                    }
                }
            },
            .interrupt_source_override => {
                if (entry_ptr.length >= @sizeOf(InterruptSourceOverrideEntry)) {
                    const entry: *align(1) const InterruptSourceOverrideEntry = @ptrCast(entry_ptr);
                    if (entry.bus == 0 and entry.source < 16) {
                        info.overrides[entry.source] = .{
                            .source_irq = entry.source,
                            .gsi = entry.gsi,
                            .polarity = entry.flags.polarity,
                            .trigger_mode = entry.flags.trigger_mode,
                        };
                    }
                }
            },
            .local_apic_nmi => {
                if (entry_ptr.length >= @sizeOf(LocalApicNmiEntry)) {
                    const entry: *align(1) const LocalApicNmiEntry = @ptrCast(entry_ptr);
                    if (info.lapic_nmi_count < 8) {
                        info.lapic_nmis[info.lapic_nmi_count] = .{
                            .processor_uid = entry.acpi_processor_uid,
                            .lint = entry.local_apic_lint,
                            .polarity = entry.flags.polarity,
                            .trigger_mode = entry.flags.trigger_mode,
                        };
                        info.lapic_nmi_count += 1;
                    }
                }
            },
            .local_apic_address_override => {
                if (entry_ptr.length >= @sizeOf(LocalApicAddressOverrideEntry)) {
                    const entry: *align(1) const LocalApicAddressOverrideEntry = @ptrCast(entry_ptr);
                    info.local_apic_addr = entry.local_apic_addr;
                }
            },
            .processor_local_x2apic => {
                if (entry_ptr.length >= @sizeOf(ProcessorLocalX2ApicEntry)) {
                    const entry: *align(1) const ProcessorLocalX2ApicEntry = @ptrCast(entry_ptr);
                    if (entry.flags.enabled and info.x2apic_count < MAX_CPUS) {
                        info.x2apic_ids[info.x2apic_count] = entry.x2apic_id;
                        info.x2apic_count += 1;
                    }
                }
            },
            else => {
                // Ignore unknown/unsupported entry types
            },
        }

        offset += entry_ptr.length;
    }

    return info;
}

/// Get entry data slice (bytes after the fixed MADT header)
fn getEntryData(madt: *align(1) const MadtHeader) []const u8 {
    const total_len = madt.header.length;
    const header_size: u32 = @sizeOf(MadtHeader);

    if (total_len <= header_size) {
        return &[_]u8{};
    }

    const data_len = total_len - header_size;
    const base: [*]const u8 = @ptrCast(madt);
    return base[header_size..][0..data_len];
}

/// Log parsed MADT information for debugging
pub fn logMadtInfo(info: *const MadtInfo) void {
    console.info("MADT: Local APIC at 0x{x}", .{info.local_apic_addr});
    console.info("MADT: PCAT compatible: {}", .{info.pcat_compat});
    console.info("MADT: {d} I/O APIC(s), {d} CPU(s)", .{ info.io_apic_count, info.lapic_count });

    for (info.io_apics[0..info.io_apic_count], 0..) |ioapic, i| {
        console.info("  I/O APIC {d}: id={d} addr=0x{x} gsi_base={d}", .{
            i,
            ioapic.id,
            ioapic.addr,
            ioapic.gsi_base,
        });
    }

    // Log interrupt source overrides
    for (info.overrides, 0..) |maybe_override, irq| {
        if (maybe_override) |override| {
            console.info("  IRQ{d} -> GSI{d} (pol={s}, trig={s})", .{
                irq,
                override.gsi,
                @tagName(override.polarity),
                @tagName(override.trigger_mode),
            });
        }
    }

    if (info.lapic_nmi_count > 0) {
        for (info.lapic_nmis[0..info.lapic_nmi_count]) |nmi| {
            console.info("  LAPIC NMI: uid={d} lint={d}", .{ nmi.processor_uid, nmi.lint });
        }
    }
}
