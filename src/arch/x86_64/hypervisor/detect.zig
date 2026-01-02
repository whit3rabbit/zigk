//! Hypervisor Detection Module
//!
//! Detects the hypervisor type using CPUID leaves.
//! Reference: Intel SDM Vol 2A, CPUID instruction
//!
//! Detection method:
//! 1. Check CPUID.1:ECX bit 31 (hypervisor present)
//! 2. If set, read CPUID.0x40000000 for vendor signature
//! 3. Signature is 12 bytes in EBX:EDX:ECX order

const std = @import("std");

/// Known hypervisor types
pub const HypervisorType = enum {
    /// No hypervisor detected (bare metal)
    none,
    /// VMware Workstation/ESXi
    vmware,
    /// Oracle VirtualBox
    virtualbox,
    /// Linux KVM
    kvm,
    /// Microsoft Hyper-V
    hyperv,
    /// Xen hypervisor
    xen,
    /// QEMU TCG (software emulation, no KVM)
    qemu_tcg,
    /// Parallels Desktop
    parallels,
    /// ACRN hypervisor
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
    /// (VirtualBox uses VMware backdoor for some features)
    pub fn isVmwareCompatible(self: HypervisorType) bool {
        return self == .vmware or self == .virtualbox;
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
    /// Raw signature string (12 bytes, may contain nulls)
    signature: [12]u8,
    /// Maximum supported hypervisor CPUID leaf
    max_leaf: u32,
};

/// Known hypervisor signatures (12 bytes each)
/// Order: EBX, EDX, ECX (as they appear in registers)
const Signature = struct {
    bytes: [12]u8,
    hypervisor: HypervisorType,
};

const known_signatures = [_]Signature{
    .{ .bytes = "VMwareVMware".*, .hypervisor = .vmware },
    .{ .bytes = "VBoxVBoxVBox".*, .hypervisor = .virtualbox },
    .{ .bytes = "KVMKVMKVM\x00\x00\x00".*, .hypervisor = .kvm },
    .{ .bytes = "Microsoft Hv".*, .hypervisor = .hyperv },
    .{ .bytes = "XenVMMXenVMM".*, .hypervisor = .xen },
    .{ .bytes = "TCGTCGTCGTCG".*, .hypervisor = .qemu_tcg },
    .{ .bytes = " prl hyperv ".*, .hypervisor = .parallels },
    .{ .bytes = " lrpepyh  vr".*, .hypervisor = .parallels }, // Alternative
    .{ .bytes = "ACRNACRNACRN".*, .hypervisor = .acrn },
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

/// Execute CPUID instruction
/// Returns: .{ eax, ebx, ecx, edx }
inline fn cpuid(leaf: u32, subleaf: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
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
          [subleaf] "{ecx}" (subleaf),
    );

    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

/// Check if running under a hypervisor
/// Uses CPUID.1:ECX bit 31
pub fn isVirtualized() bool {
    const result = cpuid(1, 0);
    return (result.ecx & (1 << 31)) != 0;
}

/// Detect hypervisor type and return detailed info
pub fn detect() HypervisorInfo {
    // Return cached result if available
    if (cached_result) |result| {
        return result;
    }

    // Check hypervisor present bit first
    if (!isVirtualized()) {
        const result = HypervisorInfo{
            .hypervisor = .none,
            .signature = [_]u8{0} ** 12,
            .max_leaf = 0,
        };
        cached_result = result;
        return result;
    }

    // Read hypervisor signature from CPUID.0x40000000
    const hv_cpuid = cpuid(0x40000000, 0);

    // Extract signature: EBX, EDX, ECX order (standard for CPUID strings)
    var signature: [12]u8 = undefined;
    @memcpy(signature[0..4], std.mem.asBytes(&hv_cpuid.ebx));
    @memcpy(signature[4..8], std.mem.asBytes(&hv_cpuid.edx));
    @memcpy(signature[8..12], std.mem.asBytes(&hv_cpuid.ecx));

    // Match against known signatures
    var hypervisor: HypervisorType = .unknown;
    for (known_signatures) |known| {
        if (std.mem.eql(u8, &signature, &known.bytes)) {
            hypervisor = known.hypervisor;
            break;
        }
    }

    const result = HypervisorInfo{
        .hypervisor = hypervisor,
        .signature = signature,
        .max_leaf = hv_cpuid.eax,
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
pub fn formatSignature(signature: [12]u8) [12]u8 {
    var result: [12]u8 = undefined;
    for (signature, 0..) |c, i| {
        result[i] = if (c >= 0x20 and c < 0x7F) c else '.';
    }
    return result;
}

// Tests
test "detect returns consistent results" {
    const info1 = detect();
    const info2 = detect();
    try std.testing.expectEqual(info1.hypervisor, info2.hypervisor);
}

test "signature formatting handles non-printable chars" {
    const sig = [12]u8{ 'A', 'B', 0, 'C', 0x1F, 0x7F, 'D', 'E', 'F', 'G', 'H', 'I' };
    const formatted = formatSignature(sig);
    try std.testing.expectEqualStrings("AB.C..DEFGHI", &formatted);
}
