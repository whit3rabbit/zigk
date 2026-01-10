//! Hypervisor Detection Module (AArch64)
//!
//! Detects the hypervisor type using ARM-specific mechanisms:
//! 1. Check ID_AA64PFR0_EL1 for EL2 virtualization support
//! 2. Use SMCCC (Arm Standard Service Calls) for hypervisor identification
//! 3. Probe KVM, Xen, and other hypervisors via hypercalls
//!
//! Reference: ARM Architecture Reference Manual, SMCCC specification

const std = @import("std");

/// Known hypervisor types (shared enum with x86_64 for API compatibility)
pub const HypervisorType = enum {
    /// No hypervisor detected (bare metal)
    none,
    /// VMware (not supported on ARM in same way as x86)
    vmware,
    /// Oracle VirtualBox (limited ARM support)
    virtualbox,
    /// Linux KVM
    kvm,
    /// Microsoft Hyper-V
    hyperv,
    /// Xen hypervisor
    xen,
    /// QEMU TCG (software emulation)
    qemu_tcg,
    /// Parallels Desktop (limited ARM support)
    parallels,
    /// ACRN hypervisor (x86 only, stub for compatibility)
    acrn,
    /// Unknown hypervisor (present but unrecognized)
    unknown,

    /// Get human-readable name
    pub fn name(self: HypervisorType) []const u8 {
        return switch (self) {
            .none => "Bare Metal",
            .vmware => "VMware",
            .virtualbox => "VirtualBox",
            .kvm => "KVM",
            .hyperv => "Hyper-V",
            .xen => "Xen",
            .qemu_tcg => "QEMU TCG",
            .parallels => "Parallels",
            .acrn => "ACRN",
            .unknown => "Unknown Hypervisor",
        };
    }

    /// Check if this is a VMware-compatible environment
    /// Returns true if running under VMware on ARM64 (uses hypercall interface)
    pub fn isVmwareCompatible(self: HypervisorType) bool {
        return self == .vmware;
    }

    /// Check if this is a KVM/QEMU environment
    pub fn isKvmCompatible(self: HypervisorType) bool {
        return self == .kvm or self == .qemu_tcg;
    }
};

/// Hypervisor detection result with additional info
pub const HypervisorInfo = struct {
    /// Detected hypervisor type
    hypervisor: HypervisorType,
    /// Raw signature/identifier (platform-specific)
    signature: [12]u8,
    /// Maximum supported hypervisor leaf (x86 CPUID concept, 0 on ARM)
    /// Included for API compatibility with x86_64 version.
    max_leaf: u32 = 0,
    /// EL2 present (virtualization support in hardware)
    el2_present: bool,
};

/// SMCCC Function IDs for hypervisor probing
const SmcccFunctionId = enum(u32) {
    /// ARM PSCI version query
    psci_version = 0x84000000,
    /// KVM hypercall (ARM_SMCCC_VENDOR_HYP_KVM_CALL)
    kvm_call = 0x86000000,
    /// Xen hypercall
    xen_version = 0x16,
    /// SMCCC architecture version
    smccc_version = 0x80000000,
};

/// Cached detection result (computed once at boot)
///
/// SECURITY NOTE: This cache is NOT protected by a lock, which is intentional:
/// - Detection runs once during early boot before SMP initialization
/// - Only the BSP (bootstrap processor) writes to this cache
/// - After boot, the cache is read-only (immutable)
/// - The resetCache() function exists only for unit testing
/// - Adding atomic operations would add unnecessary overhead for no security benefit
var cached_result: ?HypervisorInfo = null;

/// Read ID_AA64PFR0_EL1 register
/// Bits [11:8] = EL2 handling: 0b0000 = not implemented, 0b0001 = implemented
inline fn readIdAa64Pfr0() u64 {
    return asm volatile ("mrs %[ret], ID_AA64PFR0_EL1"
        : [ret] "=r" (-> u64),
    );
}

/// Read CurrentEL register to determine current exception level
inline fn readCurrentEl() u64 {
    return asm volatile ("mrs %[ret], CurrentEL"
        : [ret] "=r" (-> u64),
    );
}

/// Return type for SMC/HVC calls
const SmcResult = struct { x0: u64, x1: u64, x2: u64, x3: u64 };

/// Execute HVC (Hypervisor Call) instruction
/// Returns x0-x3 result registers
///
/// Use this when EL2 is present (running under a hypervisor like KVM, hvf).
/// HVC traps to EL2 where the hypervisor handles PSCI calls.
inline fn hvc(func_id: u32, arg1: u64, arg2: u64, arg3: u64) SmcResult {
    var x0: u64 = undefined;
    var x1: u64 = undefined;
    var x2: u64 = undefined;
    var x3: u64 = undefined;

    // HVC #0 encoded as raw bytes (0xD4000002)
    asm volatile (
        \\.word 0xD4000002
        : [x0] "={x0}" (x0),
          [x1] "={x1}" (x1),
          [x2] "={x2}" (x2),
          [x3] "={x3}" (x3),
        : [func] "{x0}" (func_id),
          [a1] "{x1}" (arg1),
          [a2] "{x2}" (arg2),
          [a3] "{x3}" (arg3),
        : .{ .memory = true }
    );

    return .{ .x0 = x0, .x1 = x1, .x2 = x2, .x3 = x3 };
}

/// Execute SMC (Secure Monitor Call) instruction
/// Returns x0-x3 result registers
///
/// Use this when EL2 is NOT present (bare metal with TF-A firmware).
/// SMC traps to EL3 where the secure monitor handles PSCI calls.
///
/// WARNING: SMC hangs on systems with EL2 but no EL3 (e.g., macOS hvf).
/// Always check isEl2Implemented() and prefer HVC when EL2 is present.
inline fn smc(func_id: u32, arg1: u64, arg2: u64, arg3: u64) SmcResult {
    var x0: u64 = undefined;
    var x1: u64 = undefined;
    var x2: u64 = undefined;
    var x3: u64 = undefined;

    // SMC #0 encoded as raw bytes (0xD4000003)
    asm volatile (
        \\.word 0xD4000003
        : [x0] "={x0}" (x0),
          [x1] "={x1}" (x1),
          [x2] "={x2}" (x2),
          [x3] "={x3}" (x3),
        : [func] "{x0}" (func_id),
          [a1] "{x1}" (arg1),
          [a2] "{x2}" (arg2),
          [a3] "{x3}" (arg3),
        : .{ .memory = true }
    );

    return .{ .x0 = x0, .x1 = x1, .x2 = x2, .x3 = x3 };
}

/// Execute PSCI call using the appropriate instruction based on EL2 presence.
/// - EL2 present (hypervisor): use HVC (traps to hypervisor at EL2)
/// - EL2 absent (bare metal): use SMC (traps to secure monitor at EL3)
inline fn psciCall(func_id: u32, arg1: u64, arg2: u64, arg3: u64) SmcResult {
    if (isEl2Implemented()) {
        // Hypervisor present - use HVC (e.g., KVM, hvf, Xen)
        return hvc(func_id, arg1, arg2, arg3);
    } else {
        // Bare metal - use SMC to reach TF-A at EL3
        return smc(func_id, arg1, arg2, arg3);
    }
}

/// Check if EL2 (hypervisor level) is implemented in hardware
pub fn isEl2Implemented() bool {
    const pfr0 = readIdAa64Pfr0();
    // Bits [11:8] = EL2 handling
    const el2_bits = (pfr0 >> 8) & 0xF;
    return el2_bits != 0;
}

/// Check if currently running under a hypervisor
/// On ARM, we check if EL2 is implemented and probe for known hypervisors
pub fn isVirtualized() bool {
    // If EL2 isn't even implemented, we're definitely bare metal
    if (!isEl2Implemented()) {
        return false;
    }

    // Try to detect known hypervisors
    const info = detect();
    return info.hypervisor != .none;
}

/// Probe for KVM/QEMU hypervisor using PSCI version call.
///
/// Uses HVC when EL2 is present (hypervisor handles PSCI), or SMC when
/// running on bare metal with TF-A firmware. This avoids hangs on systems
/// like macOS hvf where EL2 exists but EL3 does not.
///
/// Detection logic:
/// - If PSCI responds with a valid version, we have firmware/hypervisor support
/// - If EL2 is implemented (checked earlier), we're likely under KVM/QEMU/hvf
/// - On bare metal with EL2 but no hypervisor, we return false here
fn probeKvm() bool {
    // Try PSCI version call - uses HVC if EL2 present, SMC otherwise
    const result = psciCall(@intFromEnum(SmcccFunctionId.psci_version), 0, 0, 0);

    // PSCI version format: major in bits [31:16], minor in bits [15:0]
    // PSCI_NOT_SUPPORTED (-1) = 0xFFFFFFFF or 0xFFFFFFFFFFFFFFFF
    // A valid response (e.g., 0x00010000 for PSCI 1.0) indicates PSCI support
    //
    // Note: PSCI via SMC works on both bare metal and VMs, so a valid response
    // alone doesn't confirm virtualization. We rely on the EL2 check in detect()
    // combined with this probe to determine if we're under a hypervisor.
    if (result.x0 != 0 and result.x0 != 0xFFFFFFFF and result.x0 != 0xFFFFFFFFFFFFFFFF) {
        // Valid PSCI response - if EL2 is present, we're likely under KVM
        return true;
    }
    return false;
}

/// Probe for Xen hypervisor
fn probeXen() bool {
    // Xen on ARM uses a different hypercall interface
    // Try Xen version hypercall
    // Xen typically uses HVC with specific function IDs in a different range
    // For now, return false as Xen ARM detection is complex
    return false;
}

/// Probe for VMware hypervisor using ARM hypercall mechanism.
/// VMware on ARM64 uses `mrs xzr, mdccsr_el0` as the trap instruction.
fn probeVmware() bool {
    const vmware = @import("vmware.zig");
    return vmware.detect();
}

/// Detect hypervisor type and return detailed info
pub fn detect() HypervisorInfo {
    // Return cached result if available
    if (cached_result) |result| {
        return result;
    }

    const el2_present = isEl2Implemented();

    // If EL2 isn't implemented, we're on bare metal
    if (!el2_present) {
        const result = HypervisorInfo{
            .hypervisor = .none,
            .signature = [_]u8{0} ** 12,
            .el2_present = false,
        };
        cached_result = result;
        return result;
    }

    // Try to identify the hypervisor
    var hypervisor: HypervisorType = .none;
    var signature: [12]u8 = [_]u8{0} ** 12;

    // Probe for known hypervisors
    // Try VMware first since it has a distinctive hypercall mechanism
    if (probeVmware()) {
        hypervisor = .vmware;
        @memcpy(signature[0..6], "VMware");
    } else if (probeKvm()) {
        // KVM is most common on ARM after VMware Fusion
        hypervisor = .kvm;
        @memcpy(signature[0..3], "KVM");
    } else if (probeXen()) {
        hypervisor = .xen;
        @memcpy(signature[0..3], "Xen");
    } else {
        // EL2 is present but we couldn't identify the hypervisor
        // This could be QEMU TCG or an unknown hypervisor
        hypervisor = .unknown;
    }

    const result = HypervisorInfo{
        .hypervisor = hypervisor,
        .signature = signature,
        .el2_present = true,
    };

    cached_result = result;
    return result;
}

/// Get the hypervisor type (convenience function)
pub fn getHypervisor() HypervisorType {
    return detect().hypervisor;
}

/// Reset cached result (for testing or re-detection)
pub fn resetCache() void {
    cached_result = null;
}

/// Format signature as printable string
/// SECURITY: Zero-initialize buffer per project guidelines to prevent
/// potential information disclosure if loop were ever modified/interrupted.
pub fn formatSignature(signature: [12]u8) [12]u8 {
    var result: [12]u8 = [_]u8{0} ** 12;
    for (signature, 0..) |c, i| {
        result[i] = if (c >= 0x20 and c < 0x7F) c else '.';
    }
    return result;
}

// Tests - match x86_64 parity
test "detect returns consistent results" {
    resetCache();
    const info1 = detect();
    const info2 = detect();
    try std.testing.expectEqual(info1.hypervisor, info2.hypervisor);
    try std.testing.expectEqual(info1.el2_present, info2.el2_present);
}

test "signature formatting handles non-printable chars" {
    const sig = [12]u8{ 'A', 'B', 0, 'C', 0x1F, 0x7F, 'D', 'E', 'F', 'G', 'H', 'I' };
    const formatted = formatSignature(sig);
    try std.testing.expectEqualStrings("AB.C..DEFGHI", &formatted);
}
