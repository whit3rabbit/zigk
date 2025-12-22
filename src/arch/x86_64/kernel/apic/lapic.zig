// Local APIC (Advanced Programmable Interrupt Controller) Driver
//
// The Local APIC handles interrupts local to each CPU, including:
// - Inter-processor interrupts (IPIs)
// - Local timer interrupts
// - Performance monitoring interrupts
// - Thermal interrupts
// - Error interrupts
//
// Supports both xAPIC (MMIO) and x2APIC (MSR) access modes.
// x2APIC is preferred when available as it's faster and supports >255 APIC IDs.
//
// Reference: Intel SDM Vol. 3A, Chapter 10 (APIC)

const hal = @import("../../root.zig");
const console = @import("console");

// Use relative imports within the arch module
const cpu = @import("../cpu.zig");
const mmio = @import("../../mm/mmio.zig");
const paging = @import("../../mm/paging.zig");
const timing = @import("../timing.zig");

// ============================================================================
// MSR addresses for x2APIC mode (APIC registers mapped to MSRs 0x800-0x8FF)
// ============================================================================

/// IA32_APIC_BASE MSR - contains LAPIC base address and enable bits
pub const IA32_APIC_BASE: u32 = 0x1B;

/// x2APIC MSR base (registers at 0x800 + (offset >> 4))
const X2APIC_MSR_BASE: u32 = 0x800;

/// x2APIC MSR addresses
const X2APIC = struct {
    pub const APICID: u32 = 0x802;
    pub const VERSION: u32 = 0x803;
    pub const TPR: u32 = 0x808;
    pub const PPR: u32 = 0x80A;
    pub const EOI: u32 = 0x80B;
    pub const LDR: u32 = 0x80D;
    pub const SIVR: u32 = 0x80F;
    pub const ISR0: u32 = 0x810;
    pub const TMR0: u32 = 0x818;
    pub const IRR0: u32 = 0x820;
    pub const ESR: u32 = 0x828;
    pub const LVT_CMCI: u32 = 0x82F;
    pub const ICR: u32 = 0x830;
    pub const LVT_TIMER: u32 = 0x832;
    pub const LVT_THERMAL: u32 = 0x833;
    pub const LVT_PERFMON: u32 = 0x834;
    pub const LVT_LINT0: u32 = 0x835;
    pub const LVT_LINT1: u32 = 0x836;
    pub const LVT_ERROR: u32 = 0x837;
    pub const TIMER_INIT: u32 = 0x838;
    pub const TIMER_CUR: u32 = 0x839;
    pub const TIMER_DCR: u32 = 0x83E;
    pub const SELF_IPI: u32 = 0x83F;
};

// ============================================================================
// MMIO offsets for xAPIC mode (registers at LAPIC_BASE + offset)
// ============================================================================

const XAPIC = struct {
    pub const APICID: u64 = 0x020;
    pub const VERSION: u64 = 0x030;
    pub const TPR: u64 = 0x080;
    pub const APR: u64 = 0x090;
    pub const PPR: u64 = 0x0A0;
    pub const EOI: u64 = 0x0B0;
    pub const RRD: u64 = 0x0C0;
    pub const LDR: u64 = 0x0D0;
    pub const DFR: u64 = 0x0E0;
    pub const SIVR: u64 = 0x0F0;
    pub const ISR0: u64 = 0x100;
    pub const TMR0: u64 = 0x180;
    pub const IRR0: u64 = 0x200;
    pub const ESR: u64 = 0x280;
    pub const LVT_CMCI: u64 = 0x2F0;
    pub const ICR_LOW: u64 = 0x300;
    pub const ICR_HIGH: u64 = 0x310;
    pub const LVT_TIMER: u64 = 0x320;
    pub const LVT_THERMAL: u64 = 0x330;
    pub const LVT_PERFMON: u64 = 0x340;
    pub const LVT_LINT0: u64 = 0x350;
    pub const LVT_LINT1: u64 = 0x360;
    pub const LVT_ERROR: u64 = 0x370;
    pub const TIMER_INIT: u64 = 0x380;
    pub const TIMER_CUR: u64 = 0x390;
    pub const TIMER_DCR: u64 = 0x3E0;
};

// ============================================================================
// Register bit definitions
// ============================================================================

/// IA32_APIC_BASE MSR bits
pub const ApicBaseMsr = packed struct(u64) {
    _reserved0: u8 = 0,
    bsp: bool,                // Bit 8: Bootstrap Processor
    _reserved1: u1 = 0,
    x2apic_enable: bool,      // Bit 10: x2APIC mode enable
    global_enable: bool,      // Bit 11: APIC global enable
    base_addr: u24,           // Bits 12-35: Physical base address >> 12
    _reserved2: u28 = 0,

    pub fn getBaseAddress(self: ApicBaseMsr) u64 {
        return @as(u64, self.base_addr) << 12;
    }
};

/// Spurious Interrupt Vector Register
pub const SivrReg = packed struct(u32) {
    vector: u8,               // Spurious interrupt vector
    apic_enable: bool,        // Bit 8: APIC software enable
    focus_checking: bool,     // Bit 9: Focus processor checking
    eoi_broadcast_suppress: bool, // Bit 12: EOI-Broadcast suppression
    _reserved: u21 = 0,
};

/// LVT Timer entry
pub const LvtTimer = packed struct(u32) {
    vector: u8,               // Interrupt vector
    _reserved0: u4 = 0,
    delivery_status: bool,    // Read-only
    _reserved1: u3 = 0,
    mask: bool,               // Bit 16: Masked
    timer_mode: TimerMode,    // Bits 17-18
    _reserved2: u13 = 0,
};

/// Timer modes
pub const TimerMode = enum(u2) {
    one_shot = 0,
    periodic = 1,
    tsc_deadline = 2,
    _reserved = 3,
};

/// LVT entry for LINT0/LINT1/Error/etc
pub const LvtEntry = packed struct(u32) {
    vector: u8,
    delivery_mode: DeliveryMode,
    _reserved0: u1 = 0,
    delivery_status: bool,    // Read-only
    polarity: Polarity,
    remote_irr: bool,         // Read-only
    trigger_mode: TriggerMode,
    mask: bool,
    _reserved1: u15 = 0,
};

/// Delivery modes for LVT and ICR
pub const DeliveryMode = enum(u3) {
    fixed = 0,
    _reserved1 = 1,
    smi = 2,
    _reserved2 = 3,
    nmi = 4,
    init = 5,
    startup = 6,
    ext_int = 7,
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

/// ICR (Interrupt Command Register) for IPIs
pub const IcrLow = packed struct(u32) {
    vector: u8,
    delivery_mode: DeliveryMode,
    dest_mode: DestMode,
    delivery_status: bool,    // Read-only
    _reserved0: u1 = 0,
    level: Level,
    trigger_mode: TriggerMode,
    _reserved1: u2 = 0,
    dest_shorthand: DestShorthand,
    _reserved2: u12 = 0,
};

/// Destination mode
pub const DestMode = enum(u1) {
    physical = 0,
    logical = 1,
};

/// Level for IPIs
pub const Level = enum(u1) {
    de_assert = 0,
    assert = 1,
};

/// Destination shorthand
pub const DestShorthand = enum(u2) {
    none = 0,              // Use destination field
    self = 1,              // Send to self
    all_including_self = 2,
    all_excluding_self = 3,
};

/// Timer Divide Configuration
pub const TimerDivide = enum(u4) {
    div_2 = 0b0000,
    div_4 = 0b0001,
    div_8 = 0b0010,
    div_16 = 0b0011,
    div_32 = 0b1000,
    div_64 = 0b1001,
    div_128 = 0b1010,
    div_1 = 0b1011,
};

// ============================================================================
// Module state
// ============================================================================

/// LAPIC virtual base address (for xAPIC MMIO mode)
var lapic_base: u64 = 0;

/// Whether x2APIC mode is enabled
var x2apic_enabled: bool = false;

/// Whether LAPIC is initialized
var initialized: bool = false;

/// Spurious interrupt vector (typically 0xFF)
pub const SPURIOUS_VECTOR: u8 = 0xFF;

/// LAPIC Timer Vector (48 - just after IRQs)
pub const TIMER_VECTOR: u8 = 0x30;

/// Calibrated timer ticks per millisecond (with div 16)
var timer_ticks_per_ms: u32 = 0;

// ============================================================================
// Public API
// ============================================================================

/// Initialize the Local APIC
/// lapic_phys_addr: Physical address from MADT (or 0xFEE00000 default)
pub fn init(lapic_phys_addr: u64) void {
    // Check if already initialized
    if (initialized) {
        console.warn("LAPIC: Already initialized", .{});
        return;
    }

    // Read current APIC_BASE MSR
    const apic_base_msr: ApicBaseMsr = @bitCast(cpu.readMsr(IA32_APIC_BASE));

    // Use address from MADT, fallback to MSR value or default
    const base_addr = if (lapic_phys_addr != 0)
        lapic_phys_addr
    else if (apic_base_msr.getBaseAddress() != 0)
        apic_base_msr.getBaseAddress()
    else
        0xFEE00000; // Default x86 LAPIC address

    // Check x2APIC support via CPUID
    const cpuid_result = cpuid(1);
    const x2apic_supported = (cpuid_result.ecx & (1 << 21)) != 0;

    if (x2apic_supported) {
        // Enable x2APIC mode
        enableX2Apic();
        x2apic_enabled = true;
        console.info("LAPIC: x2APIC mode enabled", .{});
    } else {
        // Use xAPIC (MMIO) mode
        // Map LAPIC MMIO region to virtual address
        // For now, use identity-mapped HHDM
        lapic_base = @intFromPtr(paging.physToVirt(base_addr));

        // Enable APIC via MSR
        var new_msr = apic_base_msr;
        new_msr.global_enable = true;
        new_msr.x2apic_enable = false;
        cpu.writeMsr(IA32_APIC_BASE, @bitCast(new_msr));

        console.info("LAPIC: xAPIC mode at 0x{x}", .{base_addr});
    }

    // Set up spurious interrupt vector and enable APIC
    const sivr = SivrReg{
        .vector = SPURIOUS_VECTOR,
        .apic_enable = true,
        .focus_checking = false,
        .eoi_broadcast_suppress = false,
    };
    writeRegister(.sivr, @bitCast(sivr));

    // Clear error status register (write twice to clear)
    writeRegister(.esr, 0);
    writeRegister(.esr, 0);

    // Mask all LVT entries initially
    maskLvtEntry(.timer);
    maskLvtEntry(.lint0);
    maskLvtEntry(.lint1);
    maskLvtEntry(.lvt_error);
    maskLvtEntry(.perfmon);
    maskLvtEntry(.thermal);

    // Set Task Priority to 0 (accept all interrupts)
    writeRegister(.tpr, 0);

    initialized = true;

    const id = getId();
    console.info("LAPIC: Initialized, APIC ID = {d}", .{id});
}

/// Initialize LAPIC for Application Processor (AP)
/// This is a lightweight init that assumes BSP has already set up global state.
/// Each AP needs to enable its own LAPIC and set up SVR/TPR.
pub fn initAp() void {
    // For x2APIC mode, each AP needs to enable x2APIC in its own MSR
    if (x2apic_enabled) {
        enableX2Apic();
    } else {
        // xAPIC mode: enable APIC via MSR
        const apic_base_msr: ApicBaseMsr = @bitCast(cpu.readMsr(IA32_APIC_BASE));
        var new_msr = apic_base_msr;
        new_msr.global_enable = true;
        cpu.writeMsr(IA32_APIC_BASE, @bitCast(new_msr));
    }

    // Set up spurious interrupt vector and enable APIC
    const sivr = SivrReg{
        .vector = SPURIOUS_VECTOR,
        .apic_enable = true,
        .focus_checking = false,
        .eoi_broadcast_suppress = false,
    };
    writeRegister(.sivr, @bitCast(sivr));

    // Clear error status register
    writeRegister(.esr, 0);
    writeRegister(.esr, 0);

    // Mask all LVT entries initially
    maskLvtEntry(.timer);
    maskLvtEntry(.lint0);
    maskLvtEntry(.lint1);
    maskLvtEntry(.lvt_error);
    maskLvtEntry(.perfmon);
    maskLvtEntry(.thermal);

    // Set Task Priority to 0 (accept all interrupts)
    writeRegister(.tpr, 0);

    // const id = getId();
    // console.debug("LAPIC: AP {d} initialized", .{id});
}

/// Send End-Of-Interrupt signal
/// Must be called at the end of every interrupt handler
pub inline fn sendEoi() void {
    writeRegister(.eoi, 0);
}

/// Get the current CPU's APIC ID
pub fn getId() u32 {
    const id_reg = readRegister(.apicid);
    if (x2apic_enabled) {
        // x2APIC: full 32-bit ID
        return id_reg;
    } else {
        // xAPIC: ID is in bits 24-31
        return id_reg >> 24;
    }
}

/// Get LAPIC version information
pub fn getVersion() u8 {
    return @truncate(readRegister(.version) & 0xFF);
}

/// Get maximum LVT entries
pub fn getMaxLvt() u8 {
    const ver = readRegister(.version);
    return @truncate((ver >> 16) & 0xFF);
}

/// Configure the LAPIC timer
/// vector: Interrupt vector to deliver
/// mode: One-shot, periodic, or TSC deadline
/// initial_count: Initial counter value (0 to stop)
/// divide: Clock divider
pub fn configureTimer(
    vector: u8,
    mode: TimerMode,
    initial_count: u32,
    divide: TimerDivide,
) void {
    // Set divide configuration
    writeRegister(.timer_dcr, @intFromEnum(divide));

    // Configure LVT timer entry
    const lvt = LvtTimer{
        .vector = vector,
        .delivery_status = false,
        .mask = false,
        .timer_mode = mode,
    };
    writeRegister(.lvt_timer, @bitCast(lvt));

    // Set initial count (starts the timer)
    writeRegister(.timer_init, initial_count);
}

/// Stop the LAPIC timer
pub fn stopTimer() void {
    writeRegister(.timer_init, 0);
    maskLvtEntry(.timer);
}

/// Calibrate LAPIC timer using the calibrated TSC/PIT
/// Must be called after timing.calibrate() and before enabling the scheduler
pub fn calibrateTimer() void {
    if (!timing.isCalibrated()) {
        console.warn("LAPIC: Timing not calibrated, skipping LAPIC timer calibration", .{});
        return;
    }

    // Configure LVT Timer: Masked, One-Shot
    const lvt = LvtTimer{
        .vector = 0,
        .delivery_status = false,
        .mask = true,
        .timer_mode = .one_shot,
    };
    writeRegister(.lvt_timer, @bitCast(lvt));

    // Set divider to 16
    writeRegister(.timer_dcr, 0b0011);

    // Set initial count to max
    const initial: u32 = 0xFFFFFFFF;
    writeRegister(.timer_init, initial);

    // Wait 10ms
    timing.delayMs(10);

    // Read current count
    const current = readRegister(.timer_cur);

    // Stop timer
    writeRegister(.timer_init, 0);

    // Calculate ticks elapsed in 10ms
    if (current > initial) {
        // Should not happen unless wrapped, but with div 16 and 10ms it shouldn't wrap
        // (Max 32-bit is ~4 billion. 10ms at 5GHz div 16 is ~3 million)
        console.warn("LAPIC: Timer wrapped during calibration!", .{});
        return;
    }
    const elapsed = initial - current;

    // Ticks per ms
    timer_ticks_per_ms = elapsed / 10;

    console.info("LAPIC: Timer calibrated: {d} ticks/ms (div 16)", .{timer_ticks_per_ms});
}

/// Enable periodic timer interrupt
/// freq_hz: Desired frequency in Hz
/// vector: Interrupt vector to use
pub fn enablePeriodicTimer(freq_hz: u32, vector: u8) void {
    if (timer_ticks_per_ms == 0) {
        console.warn("LAPIC: Timer not calibrated, cannot enable periodic mode", .{});
        return;
    }

    // Calculate count for desired frequency
    // ticks/sec = ticks/ms * 1000
    // count = ticks/sec / freq_hz
    const count = (timer_ticks_per_ms * 1000) / freq_hz;

    // Set divider 16
    writeRegister(.timer_dcr, 0b0011);

    // Configure LVT Timer: Unmasked, Periodic, Vector
    const lvt = LvtTimer{
        .vector = vector,
        .delivery_status = false,
        .mask = false,
        .timer_mode = .periodic,
    };
    writeRegister(.lvt_timer, @bitCast(lvt));

    // Start timer
    writeRegister(.timer_init, count);
}

/// Get current timer count
pub fn getTimerCount() u32 {
    return readRegister(.timer_cur);
}

/// Send an Inter-Processor Interrupt (IPI)
/// dest_apic_id: Target APIC ID (ignored if shorthand != none)
/// vector: Interrupt vector
/// delivery_mode: How to deliver the interrupt
/// shorthand: Destination shorthand
pub fn sendIpi(
    dest_apic_id: u32,
    vector: u8,
    delivery_mode: DeliveryMode,
    shorthand: DestShorthand,
) void {
    if (x2apic_enabled) {
        // x2APIC: single 64-bit ICR write
        const icr_low: u32 = @bitCast(IcrLow{
            .vector = vector,
            .delivery_mode = delivery_mode,
            .dest_mode = .physical,
            .delivery_status = false,
            .level = .assert,
            .trigger_mode = .edge,
            .dest_shorthand = shorthand,
        });
        const icr: u64 = (@as(u64, dest_apic_id) << 32) | @as(u64, icr_low);
        cpu.writeMsr(X2APIC.ICR, icr);
    } else {
        // xAPIC: write ICR_HIGH first, then ICR_LOW
        writeRegister(.icr_high, dest_apic_id << 24);
        writeRegister(.icr_low, @bitCast(IcrLow{
            .vector = vector,
            .delivery_mode = delivery_mode,
            .dest_mode = .physical,
            .delivery_status = false,
            .level = .assert,
            .trigger_mode = .edge,
            .dest_shorthand = shorthand,
        }));
    }

    // Wait for IPI to be sent (delivery status clear)
    waitForIpiDelivery();
}

/// Send IPI to self
pub fn sendSelfIpi(vector: u8) void {
    if (x2apic_enabled) {
        // x2APIC has dedicated self-IPI register
        cpu.writeMsr(X2APIC.SELF_IPI, vector);
    } else {
        sendIpi(0, vector, .fixed, .self);
    }
}

/// Send INIT IPI to a processor
pub fn sendInitIpi(dest_apic_id: u32) void {
    sendIpi(dest_apic_id, 0, .init, .none);
}

/// Send SIPI (Startup IPI) to a processor
/// vector: Page number of startup code (real mode address / 4096)
pub fn sendStartupIpi(dest_apic_id: u32, vector: u8) void {
    sendIpi(dest_apic_id, vector, .startup, .none);
}

/// Configure LINT0/LINT1 pins
pub fn configureLint(lint: Lint, entry: LvtEntry) void {
    const reg: Register = switch (lint) {
        .lint0 => .lvt_lint0,
        .lint1 => .lvt_lint1,
    };
    writeRegister(reg, @bitCast(entry));
}

pub const Lint = enum { lint0, lint1 };

/// Mask an LVT entry
pub fn maskLvtEntry(lvt: LvtType) void {
    const reg = lvtToRegister(lvt);
    var value = readRegister(reg);
    value |= (1 << 16); // Set mask bit
    writeRegister(reg, value);
}

/// Unmask an LVT entry
pub fn unmaskLvtEntry(lvt: LvtType) void {
    const reg = lvtToRegister(lvt);
    var value = readRegister(reg);
    value &= ~@as(u32, 1 << 16); // Clear mask bit
    writeRegister(reg, value);
}

pub const LvtType = enum {
    timer,
    lint0,
    lint1,
    lvt_error,
    perfmon,
    thermal,
    cmci,
};

/// Check if LAPIC is enabled
pub fn isEnabled() bool {
    return initialized;
}

/// Check if x2APIC mode is active
pub fn isX2ApicMode() bool {
    return x2apic_enabled;
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Register identifiers for unified access
const Register = enum {
    apicid,
    version,
    tpr,
    ppr,
    eoi,
    ldr,
    sivr,
    isr0,
    tmr0,
    irr0,
    esr,
    lvt_cmci,
    icr_low,
    icr_high,
    lvt_timer,
    lvt_thermal,
    lvt_perfmon,
    lvt_lint0,
    lvt_lint1,
    lvt_error,
    timer_init,
    timer_cur,
    timer_dcr,
};

/// Read a LAPIC register (handles x2APIC vs xAPIC)
fn readRegister(reg: Register) u32 {
    if (x2apic_enabled) {
        return @truncate(cpu.readMsr(registerToX2ApicMsr(reg)));
    } else {
        return mmio.read32(lapic_base + registerToXApicOffset(reg));
    }
}

/// Write a LAPIC register (handles x2APIC vs xAPIC)
fn writeRegister(reg: Register, value: u32) void {
    if (x2apic_enabled) {
        cpu.writeMsr(registerToX2ApicMsr(reg), value);
    } else {
        mmio.write32(lapic_base + registerToXApicOffset(reg), value);
    }
}

/// Convert register enum to x2APIC MSR address
fn registerToX2ApicMsr(reg: Register) u32 {
    return switch (reg) {
        .apicid => X2APIC.APICID,
        .version => X2APIC.VERSION,
        .tpr => X2APIC.TPR,
        .ppr => X2APIC.PPR,
        .eoi => X2APIC.EOI,
        .ldr => X2APIC.LDR,
        .sivr => X2APIC.SIVR,
        .isr0 => X2APIC.ISR0,
        .tmr0 => X2APIC.TMR0,
        .irr0 => X2APIC.IRR0,
        .esr => X2APIC.ESR,
        .lvt_cmci => X2APIC.LVT_CMCI,
        .icr_low => X2APIC.ICR,
        .icr_high => X2APIC.ICR, // x2APIC uses single 64-bit ICR
        .lvt_timer => X2APIC.LVT_TIMER,
        .lvt_thermal => X2APIC.LVT_THERMAL,
        .lvt_perfmon => X2APIC.LVT_PERFMON,
        .lvt_lint0 => X2APIC.LVT_LINT0,
        .lvt_lint1 => X2APIC.LVT_LINT1,
        .lvt_error => X2APIC.LVT_ERROR,
        .timer_init => X2APIC.TIMER_INIT,
        .timer_cur => X2APIC.TIMER_CUR,
        .timer_dcr => X2APIC.TIMER_DCR,
    };
}

/// Convert register enum to xAPIC MMIO offset
fn registerToXApicOffset(reg: Register) u64 {
    return switch (reg) {
        .apicid => XAPIC.APICID,
        .version => XAPIC.VERSION,
        .tpr => XAPIC.TPR,
        .ppr => XAPIC.PPR,
        .eoi => XAPIC.EOI,
        .ldr => XAPIC.LDR,
        .sivr => XAPIC.SIVR,
        .isr0 => XAPIC.ISR0,
        .tmr0 => XAPIC.TMR0,
        .irr0 => XAPIC.IRR0,
        .esr => XAPIC.ESR,
        .lvt_cmci => XAPIC.LVT_CMCI,
        .icr_low => XAPIC.ICR_LOW,
        .icr_high => XAPIC.ICR_HIGH,
        .lvt_timer => XAPIC.LVT_TIMER,
        .lvt_thermal => XAPIC.LVT_THERMAL,
        .lvt_perfmon => XAPIC.LVT_PERFMON,
        .lvt_lint0 => XAPIC.LVT_LINT0,
        .lvt_lint1 => XAPIC.LVT_LINT1,
        .lvt_error => XAPIC.LVT_ERROR,
        .timer_init => XAPIC.TIMER_INIT,
        .timer_cur => XAPIC.TIMER_CUR,
        .timer_dcr => XAPIC.TIMER_DCR,
    };
}

/// Convert LVT type to register
fn lvtToRegister(lvt: LvtType) Register {
    return switch (lvt) {
        .timer => .lvt_timer,
        .lint0 => .lvt_lint0,
        .lint1 => .lvt_lint1,
        .lvt_error => .lvt_error,
        .perfmon => .lvt_perfmon,
        .thermal => .lvt_thermal,
        .cmci => .lvt_cmci,
    };
}

/// Enable x2APIC mode
fn enableX2Apic() void {
    var msr = cpu.readMsr(IA32_APIC_BASE);
    // Must enable xAPIC first (bit 11), then x2APIC (bit 10)
    msr |= (1 << 11); // Global enable
    cpu.writeMsr(IA32_APIC_BASE, msr);
    msr |= (1 << 10); // x2APIC enable
    cpu.writeMsr(IA32_APIC_BASE, msr);
}

/// Wait for IPI delivery to complete
fn waitForIpiDelivery() void {
    // Only needed for xAPIC mode
    if (!x2apic_enabled) {
        // Poll delivery status bit
        var timeout: u32 = 100000;
        while (timeout > 0) : (timeout -= 1) {
            const icr = readRegister(.icr_low);
            if ((icr & (1 << 12)) == 0) {
                return; // Delivery complete
            }
            cpu.pause();
        }
        console.warn("LAPIC: IPI delivery timeout", .{});
    }
}

/// Execute CPUID instruction
fn cpuid(leaf: u32) CpuidResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (@as(u32, 0)),
    );

    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

const CpuidResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};
