// I/O APIC (Input/Output Advanced Programmable Interrupt Controller) Driver
//
// The I/O APIC routes external interrupts (PCI, legacy devices) to Local APICs.
// It replaces the functionality of the 8259 PIC for interrupt routing.
//
// Features:
// - 24 redirection entries (IRQ inputs) per I/O APIC
// - Programmable routing to any CPU
// - Level or edge triggered modes
// - Active high or low polarity
//
// Access is via indirect addressing: write register index to IOREGSEL,
// then read/write data via IOWIN.
//
// Reference: Intel 82093AA I/O APIC Datasheet

const std = @import("std");
const console = @import("console");

// Use relative imports within the arch module
const mmio = @import("../mmio.zig");
const paging = @import("../paging.zig");
const cpu = @import("../cpu.zig");

// SECURITY: Simple spinlock to protect IOAPIC indirect register access from concurrent corruption.
// IOAPIC uses two-step access (write index to IOREGSEL, then read/write IOWIN).
// Without locking, concurrent access can cause one CPU to overwrite another's index,
// leading to incorrect register reads/writes and potential interrupt misrouting.
// Using local implementation since sync module is not available in HAL layer.
const IoApicLock = struct {
    locked: std.atomic.Value(u32) = .{ .raw = 0 },

    const Held = struct {
        lock: *IoApicLock,
        irq_state: bool,

        pub fn release(self: Held) void {
            self.lock.locked.store(0, .release);
            if (self.irq_state) {
                cpu.enableInterrupts();
            }
        }
    };

    pub fn acquire(self: *IoApicLock) Held {
        const irq_was_enabled = cpu.interruptsEnabled();
        cpu.disableInterrupts();

        while (true) {
            const prev = self.locked.cmpxchgWeak(0, 1, .acquire, .monotonic);
            if (prev == null) break;
            asm volatile ("pause" : : : .{ .memory = true });
        }

        return .{ .lock = self, .irq_state = irq_was_enabled };
    }
};

var ioapic_lock: IoApicLock = .{};

// ============================================================================
// Types for APIC initialization (decoupled from ACPI module)
// ============================================================================

/// Maximum I/O APICs to track
pub const MAX_IOAPICS: usize = 8;

/// I/O APIC information (from MADT)
pub const IoApicInfo = struct {
    id: u8,
    addr: u64, // Physical address
    gsi_base: u32,
};

/// Interrupt source override (from MADT)
pub const InterruptOverride = struct {
    source_irq: u8, // Original ISA IRQ
    gsi: u32, // Mapped GSI
    polarity: OverridePolarity,
    trigger_mode: OverrideTriggerMode,
};

/// MADT polarity (2-bit field)
pub const OverridePolarity = enum(u2) {
    conform = 0, // Conforms to bus specifications
    active_high = 1,
    reserved = 2,
    active_low = 3,
};

/// MADT trigger mode (2-bit field)
pub const OverrideTriggerMode = enum(u2) {
    conform = 0, // Conforms to bus specifications
    edge = 1,
    reserved = 2,
    level = 3,
};

// ============================================================================
// Register offsets (relative to IOAPIC base address)
// ============================================================================

/// I/O Register Select (write register index here)
const IOREGSEL: u64 = 0x00;

/// I/O Window (read/write data here)
const IOWIN: u64 = 0x10;

// ============================================================================
// Register indices (written to IOREGSEL)
// ============================================================================

/// I/O APIC ID
const IOAPICID: u8 = 0x00;

/// I/O APIC Version
const IOAPICVER: u8 = 0x01;

/// I/O APIC Arbitration ID
const IOAPICARB: u8 = 0x02;

/// First Redirection Table Entry (low 32 bits)
/// Each entry is 64 bits, spanning two consecutive indices
/// Entry N: index 0x10 + 2*N (low), 0x10 + 2*N + 1 (high)
const IOREDTBL_BASE: u8 = 0x10;

// ============================================================================
// Register structures
// ============================================================================

/// I/O APIC Version Register
pub const VersionReg = packed struct(u32) {
    version: u8,              // APIC version
    _reserved0: u8 = 0,
    max_redirection: u8,      // Maximum redirection entry index (0-based)
    _reserved1: u8 = 0,
};

/// Redirection Table Entry (64 bits)
pub const RedirectionEntry = packed struct(u64) {
    vector: u8,               // Interrupt vector (32-255)
    delivery_mode: DeliveryMode,
    dest_mode: DestMode,
    delivery_status: bool,    // Read-only: pending delivery
    polarity: Polarity,
    remote_irr: bool,         // Read-only: for level-triggered
    trigger_mode: TriggerMode,
    mask: bool,               // 1 = masked (disabled)
    _reserved: u39 = 0,
    destination: u8,          // APIC ID (physical) or logical ID (logical)
};

/// Delivery mode for redirection entries
pub const DeliveryMode = enum(u3) {
    fixed = 0,                // Deliver to specified CPUs
    lowest_priority = 1,      // Deliver to lowest priority CPU
    smi = 2,                  // System Management Interrupt
    _reserved = 3,
    nmi = 4,                  // Non-Maskable Interrupt
    init = 5,                 // INIT signal
    _reserved2 = 6,
    ext_int = 7,              // External interrupt (8259 mode)
};

/// Destination mode
pub const DestMode = enum(u1) {
    physical = 0,             // destination = APIC ID
    logical = 1,              // destination = logical address
};

/// Polarity
pub const Polarity = enum(u1) {
    active_high = 0,
    active_low = 1,
};

/// Trigger mode
pub const TriggerMode = enum(u1) {
    edge = 0,
    level = 1,
};

// ============================================================================
// Module state
// ============================================================================

/// Per-IOAPIC state
pub const IoApic = struct {
    /// Virtual base address of IOAPIC registers
    base: u64,
    /// I/O APIC ID from MADT
    id: u8,
    /// First GSI handled by this IOAPIC
    gsi_base: u32,
    /// Number of redirection entries (IRQ inputs)
    max_entries: u8,
    /// Initialized flag
    initialized: bool,
};

/// All registered I/O APICs
var ioapics: [MAX_IOAPICS]IoApic = undefined;
var ioapic_count: u8 = 0;

// ============================================================================
// Public API
// ============================================================================

/// Initialize an I/O APIC from MADT info
pub fn init(info: *const IoApicInfo) void {
    if (ioapic_count >= MAX_IOAPICS) {
        console.warn("IOAPIC: Maximum I/O APICs reached", .{});
        return;
    }

    // Map IOAPIC registers to virtual address
    const virt: u64 = @intFromPtr(paging.physToVirt(info.addr));

    // Read version to get max redirection entries
    const version: VersionReg = @bitCast(readReg(virt, IOAPICVER));

    const index = ioapic_count;
    ioapics[index] = .{
        .base = virt,
        .id = info.id,
        .gsi_base = info.gsi_base,
        .max_entries = version.max_redirection + 1,
        .initialized = true,
    };
    ioapic_count += 1;

    console.info("IOAPIC: id={d} base=0x{x} gsi_base={d} entries={d}", .{
        info.id,
        info.addr,
        info.gsi_base,
        version.max_redirection + 1,
    });

    // Mask all entries by default
    for (0..@as(usize, version.max_redirection + 1)) |i| {
        maskGsi(info.gsi_base + @as(u32, @intCast(i)));
    }
}

/// Route a Global System Interrupt (GSI) to a CPU
pub fn routeGsi(
    gsi: u32,
    vector: u8,
    dest_apic_id: u8,
    trigger: TriggerMode,
    polarity: Polarity,
) void {
    const ioapic = findIoApicForGsi(gsi) orelse {
        console.warn("IOAPIC: No I/O APIC for GSI {d}", .{gsi});
        return;
    };

    const pin = gsi - ioapic.gsi_base;
    if (pin >= ioapic.max_entries) {
        console.warn("IOAPIC: GSI {d} out of range for IOAPIC {d}", .{ gsi, ioapic.id });
        return;
    }

    const entry = RedirectionEntry{
        .vector = vector,
        .delivery_mode = .fixed,
        .dest_mode = .physical,
        .delivery_status = false,
        .polarity = polarity,
        .remote_irr = false,
        .trigger_mode = trigger,
        .mask = false, // Unmask
        .destination = dest_apic_id,
    };

    writeRedirectionEntry(ioapic.base, @intCast(pin), entry);
}

/// Route a legacy ISA IRQ with optional override information
/// If override is null, uses ISA defaults (edge-triggered, active-high)
pub fn routeIsaIrq(
    _: u8, // irq (unused, GSI is used instead)
    vector: u8,
    dest_apic_id: u8,
    gsi: u32,
    override: ?*const InterruptOverride,
) void {
    // Determine trigger/polarity from override or ISA defaults
    var trigger: TriggerMode = .edge;
    var polarity: Polarity = .active_high;

    if (override) |ovr| {
        // Use MADT override settings
        polarity = switch (ovr.polarity) {
            .active_high => .active_high,
            .active_low => .active_low,
            .conform => .active_high, // ISA default
            .reserved => .active_high,
        };
        trigger = switch (ovr.trigger_mode) {
            .edge => .edge,
            .level => .level,
            .conform => .edge, // ISA default
            .reserved => .edge,
        };
    }

    routeGsi(gsi, vector, dest_apic_id, trigger, polarity);
}

/// Mask (disable) a GSI
pub fn maskGsi(gsi: u32) void {
    const ioapic = findIoApicForGsi(gsi) orelse return;
    const pin = gsi - ioapic.gsi_base;
    if (pin >= ioapic.max_entries) return;

    var entry = readRedirectionEntry(ioapic.base, @intCast(pin));
    entry.mask = true;
    writeRedirectionEntry(ioapic.base, @intCast(pin), entry);
}

/// Unmask (enable) a GSI
pub fn unmaskGsi(gsi: u32) void {
    const ioapic = findIoApicForGsi(gsi) orelse return;
    const pin = gsi - ioapic.gsi_base;
    if (pin >= ioapic.max_entries) return;

    var entry = readRedirectionEntry(ioapic.base, @intCast(pin));
    entry.mask = false;
    writeRedirectionEntry(ioapic.base, @intCast(pin), entry);
}

/// Set the vector for an existing GSI route
pub fn setGsiVector(gsi: u32, vector: u8) void {
    const ioapic = findIoApicForGsi(gsi) orelse return;
    const pin = gsi - ioapic.gsi_base;
    if (pin >= ioapic.max_entries) return;

    var entry = readRedirectionEntry(ioapic.base, @intCast(pin));
    entry.vector = vector;
    writeRedirectionEntry(ioapic.base, @intCast(pin), entry);
}

/// Get the current configuration for a GSI
pub fn getGsiConfig(gsi: u32) ?RedirectionEntry {
    const ioapic = findIoApicForGsi(gsi) orelse return null;
    const pin = gsi - ioapic.gsi_base;
    if (pin >= ioapic.max_entries) return null;

    return readRedirectionEntry(ioapic.base, @intCast(pin));
}

/// Get number of initialized I/O APICs
pub fn getCount() u8 {
    return ioapic_count;
}

/// Get information about an I/O APIC by index
pub fn getInfo(index: u8) ?*const IoApic {
    if (index >= ioapic_count) return null;
    return &ioapics[index];
}

/// Find the I/O APIC that handles a given GSI
pub fn findIoApicForGsi(gsi: u32) ?*const IoApic {
    for (ioapics[0..ioapic_count]) |*ioapic| {
        if (!ioapic.initialized) continue;
        const end_gsi = ioapic.gsi_base + ioapic.max_entries;
        if (gsi >= ioapic.gsi_base and gsi < end_gsi) {
            return ioapic;
        }
    }
    return null;
}

// ============================================================================
// Low-level register access
// ============================================================================

/// Memory barrier (mfence) for ordering MMIO operations
inline fn memoryBarrier() void {
    asm volatile ("mfence"
        :
        :
        : .{ .memory = true }
    );
}

/// Read an I/O APIC register (indirect access)
/// SECURITY: Protected by spinlock to prevent concurrent register corruption
fn readReg(base: u64, index: u8) u32 {
    const held = ioapic_lock.acquire();
    defer held.release();

    // Write register index to IOREGSEL
    mmio.write32(base + IOREGSEL, index);
    // Memory barrier ensures index write completes before data read
    memoryBarrier();
    // Read data from IOWIN
    return mmio.read32(base + IOWIN);
}

/// Write an I/O APIC register (indirect access)
/// SECURITY: Protected by spinlock to prevent concurrent register corruption
fn writeReg(base: u64, index: u8, value: u32) void {
    const held = ioapic_lock.acquire();
    defer held.release();

    // Write register index to IOREGSEL
    mmio.write32(base + IOREGSEL, index);
    // Memory barrier ensures index write completes before data write
    memoryBarrier();
    // Write data to IOWIN
    mmio.write32(base + IOWIN, value);
}

/// Read a redirection table entry
fn readRedirectionEntry(base: u64, pin: u8) RedirectionEntry {
    const index = IOREDTBL_BASE + (pin * 2);
    const low = readReg(base, index);
    const high = readReg(base, index + 1);
    return @bitCast((@as(u64, high) << 32) | low);
}

/// Write a redirection table entry
fn writeRedirectionEntry(base: u64, pin: u8, entry: RedirectionEntry) void {
    const value: u64 = @bitCast(entry);
    const index = IOREDTBL_BASE + (pin * 2);
    writeReg(base, index, @truncate(value));
    writeReg(base, index + 1, @truncate(value >> 32));
}
