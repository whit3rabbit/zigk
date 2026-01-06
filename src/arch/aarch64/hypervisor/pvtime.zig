//! ARM Paravirtualized Time (pvtime)
//!
//! Provides stolen time tracking under KVM/hypervisors on AArch64.
//! Unlike x86 kvmclock which provides both wall time and TSC conversion,
//! ARM pvtime focuses on stolen time - the time a vCPU was preempted.
//!
//! The ARM Generic Timer (CNTVCT_EL0) already provides accurate monotonic
//! time without paravirtualization, so pvtime supplements it with:
//! - Stolen time accounting for accurate CPU time measurement
//! - Live migration detection
//!
//! Reference:
//! - ARM DEN0057A (SMCCC)
//! - Linux Documentation/virt/kvm/arm/pvtime.rst

const std = @import("std");
const pmm = @import("pmm");
const console = @import("console");
const detect = @import("detect.zig");
const paging = @import("../mm/paging.zig");

// =============================================================================
// SMCCC Function IDs for pvtime
// =============================================================================

/// ARM SMCCC Hypervisor Service Calls
const SMCCC = struct {
    /// PV-Time stolen time (returns physical address of stolen time struct)
    const HV_PV_TIME_ST: u32 = 0xC6000021;
    /// PV-Time features (check what pvtime features are supported)
    const HV_PV_TIME_FEATURES: u32 = 0xC6000020;
};

/// PV-Time feature bits
const PvtimeFeatures = struct {
    /// Stolen time is supported
    const ST_SUPPORTED: u64 = 1 << 0;
};

// =============================================================================
// pvtime Structures (match ARM KVM ABI)
// =============================================================================

/// Per-vCPU stolen time structure
/// Updated by hypervisor to track time the vCPU was preempted
pub const PvtimeStolenTime = extern struct {
    /// Sequence lock - increment before and after updates
    /// Odd value means update in progress
    seq: u32,
    /// Flags (reserved, must be zero)
    flags: u32,
    /// Accumulated stolen time in nanoseconds
    /// This is the total time this vCPU has been preempted
    stolen_time_ns: u64,

    comptime {
        if (@sizeOf(PvtimeStolenTime) != 16) {
            @compileError("PvtimeStolenTime must be exactly 16 bytes");
        }
    }
};

// =============================================================================
// Module State
// =============================================================================

/// Maximum CPUs supported
const MAX_CPUS: usize = 256;

/// Physical address of BSP's stolen time struct (from hypervisor)
var stolen_time_page_phys: u64 = 0;

/// Whether pvtime is available and initialized
var pvtime_available: bool = false;

/// Whether init() has been called
var pvtime_initialized: bool = false;

// =============================================================================
// SMCCC Hypercall
// =============================================================================

/// Execute HVC (Hypervisor Call) instruction for pvtime
/// Returns result in x0
inline fn hvc(func_id: u32, arg1: u64, arg2: u64, arg3: u64) u64 {
    var x0: u64 = undefined;

    // HVC #0 encoded as raw bytes (0xD4000002)
    asm volatile (
        \\.word 0xD4000002
        : [x0] "={x0}" (x0),
        : [func] "{x0}" (func_id),
          [a1] "{x1}" (arg1),
          [a2] "{x2}" (arg2),
          [a3] "{x3}" (arg3),
        : .{ .memory = true });

    return x0;
}

// =============================================================================
// Public API
// =============================================================================

/// Check if pvtime stolen time is supported
pub fn hasPvtime() bool {
    const info = detect.detect();

    // Only supported under KVM
    if (info.hypervisor != .kvm) {
        return false;
    }

    // Query pvtime features via SMCCC
    // This hypercall returns feature bits or NOT_SUPPORTED (-1)
    const features = hvc(SMCCC.HV_PV_TIME_FEATURES, 0, 0, 0);

    // Check for NOT_SUPPORTED return value
    if (features == 0xFFFFFFFF or features == 0xFFFFFFFFFFFFFFFF) {
        return false;
    }

    return (features & PvtimeFeatures.ST_SUPPORTED) != 0;
}

/// Initialize pvtime if running under KVM with support
/// Must be called during BSP boot
///
/// SECURITY NOTE: This code trusts hypervisor-provided physical addresses.
/// The threat model assumes the hypervisor is trusted - if it is compromised,
/// the guest is already fully compromised (hypervisor has complete access to
/// guest memory). We validate alignment to prevent panics from malformed
/// responses, but do not validate RAM bounds since that provides minimal
/// additional protection given the trust model.
pub fn init() void {
    if (pvtime_initialized) {
        return;
    }

    pvtime_initialized = true;

    // Check if pvtime is supported
    if (!hasPvtime()) {
        console.info("pvtime: Not available (not KVM or feature unsupported)", .{});
        return;
    }

    // Query BSP's stolen time structure from hypervisor
    // The HVC returns the physical address of hypervisor's per-vCPU struct
    const hv_st_addr = hvc(SMCCC.HV_PV_TIME_ST, 0, 0, 0);

    // Check for error return
    if (hv_st_addr == 0xFFFFFFFF or hv_st_addr == 0xFFFFFFFFFFFFFFFF or hv_st_addr == 0) {
        console.warn("pvtime: HVC PV_TIME_ST failed (result={x})", .{hv_st_addr});
        return;
    }

    // SECURITY: Validate alignment before cast to prevent panic from @alignCast
    // on misaligned addresses (which would be a hypervisor bug or attack)
    if (hv_st_addr % @alignOf(PvtimeStolenTime) != 0) {
        console.warn("pvtime: Hypervisor returned misaligned address {x}", .{hv_st_addr});
        return;
    }

    // Store the hypervisor-provided address for use in getStolenTimeNs()
    // The hypervisor manages the actual structure, we just read from it
    stolen_time_page_phys = hv_st_addr;

    pvtime_available = true;

    console.info("pvtime: Initialized (hv_addr={x})", .{hv_st_addr});
}

/// Initialize pvtime for an Application Processor
/// Must be called during AP boot sequence
pub fn initAp(cpu_id: usize) void {
    if (!pvtime_available) {
        return;
    }

    if (cpu_id >= MAX_CPUS) {
        console.warn("pvtime: CPU ID {d} exceeds MAX_CPUS {d}", .{ cpu_id, MAX_CPUS });
        return;
    }

    // Each AP needs to query its own stolen time structure from hypervisor
    const hv_st_addr = hvc(SMCCC.HV_PV_TIME_ST, 0, 0, 0);

    if (hv_st_addr == 0xFFFFFFFF or hv_st_addr == 0xFFFFFFFFFFFFFFFF or hv_st_addr == 0) {
        return;
    }

    // The hypervisor returns a per-vCPU address - we could cache it but
    // for simplicity we'll re-query when needed
}

/// Check if pvtime is available and initialized
pub fn isAvailable() bool {
    return pvtime_available;
}

/// Get accumulated stolen time for current CPU in nanoseconds
/// Uses seqlock pattern for TOCTOU safety
///
/// NOTE: The seqlock loop is bounded to 10 attempts. Under adversarial
/// conditions (malicious hypervisor keeping seq odd), this returns null.
/// This is acceptable degradation - stolen time becomes unavailable but
/// the kernel continues to function.
pub fn getStolenTimeNs() ?u64 {
    if (!pvtime_available) return null;

    // Query current vCPU's stolen time structure
    const hv_st_addr = hvc(SMCCC.HV_PV_TIME_ST, 0, 0, 0);
    if (hv_st_addr == 0 or hv_st_addr == 0xFFFFFFFF or hv_st_addr == 0xFFFFFFFFFFFFFFFF) {
        return null;
    }

    // SECURITY: Validate alignment before cast to prevent panic
    if (hv_st_addr % @alignOf(PvtimeStolenTime) != 0) {
        return null;
    }

    const info: *volatile PvtimeStolenTime = @ptrCast(@alignCast(paging.physToVirt(hv_st_addr)));

    // Seqlock read loop (bounded to prevent infinite loop under adversarial hypervisor)
    var attempts: u32 = 0;
    while (attempts < 10) : (attempts += 1) {
        // Read sequence with acquire semantics
        const seq1 = @atomicLoad(u32, &info.seq, .acquire);

        // Odd sequence means update in progress
        if (seq1 & 1 != 0) continue;

        // Read stolen time
        const stolen = info.stolen_time_ns;

        // Compiler barrier
        std.atomic.compilerFence(.seq_cst);

        // Verify sequence hasn't changed
        const seq2 = @atomicLoad(u32, &info.seq, .acquire);
        if (seq1 != seq2) continue;

        return stolen;
    }

    return null;
}

/// Get current monotonic time in nanoseconds, adjusted for stolen time
/// This provides "real" CPU time by subtracting stolen time from wall time
pub fn getAdjustedTimeNs() ?u64 {
    if (!pvtime_available) return null;

    // Read system counter
    const timing = @import("../kernel/timing.zig");
    const counter = timing.rdtsc();
    const freq = timing.getTscFrequency();

    if (freq == 0) return null;

    // Convert counter to nanoseconds
    const wall_ns = @as(u128, counter) * 1_000_000_000 / freq;

    // Get stolen time
    const stolen = getStolenTimeNs() orelse 0;

    // Subtract stolen time to get actual CPU time
    const adjusted = @as(u64, @truncate(wall_ns)) -| stolen;

    return adjusted;
}
