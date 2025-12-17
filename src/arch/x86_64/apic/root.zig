// APIC Subsystem Root Module
//
// Coordinates Local APIC and I/O APIC initialization, providing a unified
// interface for the kernel's interrupt infrastructure.
//
// Initialization sequence:
// 1. Receive parsed MADT info from kernel
// 2. Disable legacy 8259 PIC
// 3. Initialize Local APIC
// 4. Initialize all I/O APICs
// 5. Route legacy ISA IRQs through I/O APIC
//
// After initialization, use lapic.sendEoi() instead of pic.sendEoi()
// for interrupt acknowledgment.

const std = @import("std");
const console = @import("console");

// Use relative imports within the arch module
const pic = @import("../pic.zig");

pub const lapic = @import("lapic.zig");
pub const ioapic = @import("ioapic.zig");
pub const ipi = @import("ipi.zig");

// Re-export types from ioapic for convenience
pub const IoApicInfo = ioapic.IoApicInfo;
pub const InterruptOverride = ioapic.InterruptOverride;
pub const OverridePolarity = ioapic.OverridePolarity;
pub const OverrideTriggerMode = ioapic.OverrideTriggerMode;

/// APIC initialization info (populated from MADT by kernel)
pub const ApicInitInfo = struct {
    /// Local APIC physical address
    local_apic_addr: u64,

    /// I/O APICs from MADT
    io_apics: []const IoApicInfo,

    /// Interrupt source overrides (ISA IRQ remapping)
    /// Index by ISA IRQ number (0-15), null if no override
    overrides: *const [16]?InterruptOverride,

    /// Whether dual 8259 PICs are installed (should be disabled)
    pcat_compat: bool,

    /// Local APIC IDs for enabled processors (from MADT)
    lapic_ids: []const u8,

    /// Get the GSI for a legacy ISA IRQ, applying any overrides
    pub fn getGsiForIrq(self: *const ApicInitInfo, irq: u8) u32 {
        if (irq < 16) {
            if (self.overrides[irq]) |override| {
                return override.gsi;
            }
        }
        // Identity mapping if no override
        return irq;
    }

    /// Get override info for an IRQ
    pub fn getOverridePtr(self: *const ApicInitInfo, irq: u8) ?*const InterruptOverride {
        if (irq < 16) {
            if (self.overrides[irq]) |*override| {
                return override;
            }
        }
        return null;
    }
};

/// Interrupt controller mode
/// Tracks which interrupt controller is active for proper EOI handling
pub const InterruptMode = enum {
    /// Initial state - no interrupt controller configured
    None,
    /// Legacy 8259 PIC mode (fallback if APIC not available)
    LegacyPic,
    /// APIC mode (Local APIC + I/O APIC)
    Apic,
};

/// Current interrupt controller mode
var interrupt_mode: InterruptMode = .None;

/// Cached init information
var cached_init_info: ?ApicInitInfo = null;

/// Standard vector assignments for legacy IRQs
pub const Vectors = struct {
    /// PIT Timer (IRQ0)
    pub const TIMER: u8 = 32;
    /// PS/2 Keyboard (IRQ1)
    pub const KEYBOARD: u8 = 33;
    /// Cascade (IRQ2) - not used in APIC mode
    pub const CASCADE: u8 = 34;
    /// COM2/COM4 (IRQ3)
    pub const COM2: u8 = 35;
    /// COM1/COM3 (IRQ4)
    pub const COM1: u8 = 36;
    /// LPT2 (IRQ5)
    pub const LPT2: u8 = 37;
    /// Floppy (IRQ6)
    pub const FLOPPY: u8 = 38;
    /// LPT1 / Spurious (IRQ7)
    pub const LPT1: u8 = 39;
    /// RTC (IRQ8)
    pub const RTC: u8 = 40;
    /// Available (IRQ9)
    pub const IRQ9: u8 = 41;
    /// Available (IRQ10)
    pub const IRQ10: u8 = 42;
    /// Available (IRQ11)
    pub const IRQ11: u8 = 43;
    /// PS/2 Mouse (IRQ12)
    pub const MOUSE: u8 = 44;
    /// FPU (IRQ13)
    pub const FPU: u8 = 45;
    /// Primary ATA (IRQ14)
    pub const ATA_PRIMARY: u8 = 46;
    /// Secondary ATA (IRQ15)
    pub const ATA_SECONDARY: u8 = 47;

    /// First available vector for MSI/dynamic allocation
    pub const MSI_BASE: u8 = 48;
    /// Last usable vector (0xFE, 0xFF reserved)
    pub const MSI_END: u8 = 254;

    /// LAPIC spurious interrupt
    pub const SPURIOUS: u8 = lapic.SPURIOUS_VECTOR;
};

/// Initialize the APIC subsystem
/// info: Pre-parsed MADT info from kernel
pub fn init(info: *const ApicInitInfo) void {
    if (interrupt_mode == .Apic) {
        console.warn("APIC: Already initialized", .{});
        return;
    }

    console.info("APIC: Initializing...", .{});

    // Cache the init info
    cached_init_info = info.*;

    // 1. Disable legacy 8259 PIC
    // This masks all PIC interrupts and prevents spurious interrupts
    if (info.pcat_compat) {
        pic.disable();
        console.info("APIC: Legacy PIC disabled", .{});
    }

    // 2. Initialize Local APIC
    lapic.init(info.local_apic_addr);

    // 3. Initialize all I/O APICs
    for (info.io_apics) |*ioapic_info| {
        ioapic.init(ioapic_info);
    }

    if (info.io_apics.len == 0) {
        console.warn("APIC: No I/O APICs found in MADT", .{});
        // Can still use LAPIC timer and IPIs, but no external interrupts
    }

    // 4. Route legacy ISA IRQs through I/O APIC
    // Only route the IRQs we actually use
    const bsp_id: u8 = @truncate(lapic.getId());

    // Timer (IRQ0 -> vector 32)
    // NOTE: If using LAPIC timer, we might mask this later, but routing it is fine for now
    const timer_gsi = info.getGsiForIrq(0);
    ioapic.routeIsaIrq(0, Vectors.TIMER, bsp_id, timer_gsi, info.getOverridePtr(0));

    // Keyboard (IRQ1 -> vector 33)
    const kbd_gsi = info.getGsiForIrq(1);
    ioapic.routeIsaIrq(1, Vectors.KEYBOARD, bsp_id, kbd_gsi, info.getOverridePtr(1));

    // Verify keyboard IRQ1 routing for diagnostics
    if (ioapic.getGsiConfig(kbd_gsi)) |entry| {
        console.info("IOAPIC: IRQ1 -> vec={d} mask={} dest={d}", .{
            entry.vector, entry.mask, entry.destination,
        });
    } else {
        console.warn("IOAPIC: Failed to read IRQ1 config!", .{});
    }

    // Note: Other IRQs can be routed on-demand by drivers

    interrupt_mode = .Apic;
    console.info("APIC: Initialization complete (APIC mode active)", .{});
}

/// Initialize the LAPIC timer for scheduling
/// This should be called after APIC init and TSC calibration
pub fn initTimer() void {
    if (interrupt_mode != .Apic) {
        console.warn("APIC: Cannot init timer, APIC not active", .{});
        return;
    }

    console.info("APIC: Calibrating Local APIC timer...", .{});

    // Calibrate LAPIC timer against PIT/TSC
    lapic.calibrateTimer();

    // Enable periodic timer at 100Hz (same as PIT)
    // We use the dedicated TIMER_VECTOR (48)
    lapic.enablePeriodicTimer(100, lapic.TIMER_VECTOR);

    // Mask the legacy PIT IRQ (IRQ0) since we are using LAPIC timer
    disableIrq(0);

    console.info("APIC: LAPIC timer enabled at 100Hz (Vector {d})", .{lapic.TIMER_VECTOR});
}

/// Check if APIC mode is active
pub fn isActive() bool {
    return interrupt_mode == .Apic;
}

/// Get current interrupt mode
pub fn getInterruptMode() InterruptMode {
    return interrupt_mode;
}

/// Set interrupt mode to legacy PIC (used when APIC init fails)
pub fn setLegacyPicMode() void {
    if (interrupt_mode == .None) {
        interrupt_mode = .LegacyPic;
        console.info("APIC: Falling back to legacy PIC mode", .{});
    }
}

/// Get cached APIC init information
pub fn getInitInfo() ?*const ApicInitInfo {
    if (cached_init_info) |*info| {
        return info;
    }
    return null;
}

/// Send End-Of-Interrupt (use this instead of pic.sendEoi)
/// Handles both APIC and legacy PIC modes automatically
pub inline fn sendEoi() void {
    switch (interrupt_mode) {
        .Apic => lapic.sendEoi(),
        .LegacyPic => pic.sendEoi(0), // Send EOI to master PIC
        .None => {
            // No interrupt controller configured - this is a bug
            console.warn("APIC: sendEoi called with no interrupt controller!", .{});
        },
    }
}

/// Send EOI for a specific IRQ (handles slave PIC if needed)
pub inline fn sendEoiForIrq(irq: u8) void {
    switch (interrupt_mode) {
        .Apic => lapic.sendEoi(),
        .LegacyPic => pic.sendEoi(irq),
        .None => {},
    }
}

/// Route an IRQ to a specific vector and CPU
/// irq: Legacy ISA IRQ number (0-15)
/// vector: Interrupt vector to deliver
/// cpu_id: Target APIC ID (or 0 for BSP)
pub fn routeIrq(irq: u8, vector: u8, cpu_id: u8) void {
    if (interrupt_mode != .Apic) {
        console.warn("APIC: Not in APIC mode, cannot route IRQ", .{});
        return;
    }

    const info = cached_init_info orelse return;
    const target = if (cpu_id == 0) @as(u8, @truncate(lapic.getId())) else cpu_id;
    const gsi = info.getGsiForIrq(irq);
    ioapic.routeIsaIrq(irq, vector, target, gsi, info.getOverridePtr(irq));
}

/// Enable (unmask) an IRQ
pub fn enableIrq(irq: u8) void {
    if (interrupt_mode != .Apic) return;
    const info = cached_init_info orelse return;
    const gsi = info.getGsiForIrq(irq);
    ioapic.unmaskGsi(gsi);
}

/// Disable (mask) an IRQ
pub fn disableIrq(irq: u8) void {
    if (interrupt_mode != .Apic) return;
    const info = cached_init_info orelse return;
    const gsi = info.getGsiForIrq(irq);
    ioapic.maskGsi(gsi);
}

// ============================================================================
// MSI Vector Allocation
// ============================================================================

/// Bitmap for allocated MSI vectors (vectors 48-254)
var msi_vector_bitmap: [26]u8 = [_]u8{0} ** 26; // (254-48+1)/8 rounded up

/// Allocate an MSI vector
pub fn allocateMsiVector() ?u8 {
    for (0..msi_vector_bitmap.len) |byte_idx| {
        if (msi_vector_bitmap[byte_idx] != 0xFF) {
            // Find first free bit
            const byte = msi_vector_bitmap[byte_idx];
            var bit: u3 = 0;
            while (bit < 8) : (bit += 1) {
                if ((byte & (@as(u8, 1) << bit)) == 0) {
                    const vector = Vectors.MSI_BASE + @as(u8, @intCast(byte_idx * 8)) + bit;
                    if (vector <= Vectors.MSI_END) {
                        msi_vector_bitmap[byte_idx] |= (@as(u8, 1) << bit);
                        return vector;
                    }
                }
            }
        }
    }
    return null;
}

/// Free an MSI vector
pub fn freeMsiVector(vector: u8) void {
    if (vector < Vectors.MSI_BASE or vector > Vectors.MSI_END) return;

    const offset = vector - Vectors.MSI_BASE;
    const byte_idx = offset / 8;
    const bit: u3 = @truncate(offset % 8);

    msi_vector_bitmap[byte_idx] &= ~(@as(u8, 1) << bit);
}

/// Allocate multiple contiguous MSI vectors (for MSI-X or MSI multi-message)
/// Returns the base vector of the allocated block.
/// The block is guaranteed to be aligned to `count` (power of 2).
pub fn allocateMsiVectors(count: u8) ?u8 {
    if (count == 0) return null;
    if (!std.math.isPowerOfTwo(count)) return null;

    var base: u16 = Vectors.MSI_BASE;

    // Align base to count
    const rem = base % count;
    if (rem != 0) {
        base += (count - rem);
    }

    while (base + count - 1 <= Vectors.MSI_END) : (base += count) {
        var free = true;
        var i: u16 = 0;
        while (i < count) : (i += 1) {
            const vector = @as(u8, @intCast(base + i));
            const offset = vector - Vectors.MSI_BASE;
            const byte_idx = offset / 8;
            const bit: u3 = @truncate(offset % 8);
            if ((msi_vector_bitmap[byte_idx] & (@as(u8, 1) << bit)) != 0) {
                free = false;
                break;
            }
        }

        if (free) {
            i = 0;
            while (i < count) : (i += 1) {
                const vector = @as(u8, @intCast(base + i));
                const offset = vector - Vectors.MSI_BASE;
                const byte_idx = offset / 8;
                const bit: u3 = @truncate(offset % 8);
                msi_vector_bitmap[byte_idx] |= (@as(u8, 1) << bit);
            }
            return @as(u8, @intCast(base));
        }
    }
    return null;
}

/// Free multiple contiguous MSI vectors
pub fn freeMsiVectors(base: u8, count: u8) void {
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        freeMsiVector(@as(u8, @intCast(base + i)));
    }
}

// ============================================================================
// Error types
// ============================================================================

pub const ApicError = error{
    MadtNotFound,
    NoIoApic,
    InitFailed,
};
