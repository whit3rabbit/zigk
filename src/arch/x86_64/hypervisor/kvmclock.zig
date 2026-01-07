//! KVM Paravirtualized Clock (kvmclock)
//!
//! Provides stable timekeeping under KVM/QEMU hypervisors. Uses shared memory
//! structures updated by the hypervisor to provide accurate monotonic and
//! wall-clock time without expensive VM exits.
//!
//! Reference: Linux kernel Documentation/virt/kvm/x86/msr.rst
//!
//! Key benefits:
//! - Stable TSC across VM migration (no recalibration needed)
//! - Accurate time even when TSC frequency varies
//! - Lower overhead than PIT-based calibration

const std = @import("std");
const cpu = @import("../kernel/cpu.zig");
const paging = @import("../mm/paging.zig");
const pmm = @import("pmm");
const console = @import("console");
const detect = @import("detect.zig");
const gdt = @import("../kernel/gdt.zig");
const apic = @import("../kernel/apic/root.zig");

// =============================================================================
// KVM MSR Addresses
// =============================================================================

/// MSR for wall clock time structure physical address
const MSR_KVM_WALL_CLOCK_NEW: u32 = 0x4b564d00;

/// MSR for system time structure physical address (bit 0 = enabled)
const MSR_KVM_SYSTEM_TIME_NEW: u32 = 0x4b564d01;

// =============================================================================
// pvclock Flags
// =============================================================================

/// TSC is stable across all vCPUs - can skip seqlock in fast path
pub const PVCLOCK_TSC_STABLE_BIT: u8 = 1 << 0;

/// Guest was stopped (migration/suspend) - time may have jumped
pub const PVCLOCK_GUEST_STOPPED: u8 = 1 << 1;

// =============================================================================
// pvclock Structures (match KVM ABI exactly)
// =============================================================================

/// Wall clock structure - provides epoch-based wall time
/// Updated by hypervisor when guest registers MSR_KVM_WALL_CLOCK_NEW
pub const PvclockWallClock = extern struct {
    /// Version counter - odd value means update in progress
    version: u32,
    /// Seconds since Unix epoch
    sec: u32,
    /// Nanoseconds component (0-999999999)
    nsec: u32,

    comptime {
        if (@sizeOf(PvclockWallClock) != 12) {
            @compileError("PvclockWallClock must be exactly 12 bytes");
        }
    }
};

/// Per-vCPU time info structure - used for monotonic time calculation
/// Each vCPU has its own copy, updated by hypervisor on VM entry
pub const PvclockVcpuTimeInfo = extern struct {
    /// Version counter - odd value means update in progress
    version: u32,
    /// Padding for alignment
    pad0: u32,
    /// TSC value at time of last update
    tsc_timestamp: u64,
    /// System time in nanoseconds at tsc_timestamp
    system_time: u64,
    /// Multiplier for TSC-to-nanoseconds conversion
    tsc_to_system_mul: u32,
    /// Shift for TSC-to-nanoseconds conversion (can be negative)
    tsc_shift: i8,
    /// Flags (PVCLOCK_TSC_STABLE_BIT, PVCLOCK_GUEST_STOPPED)
    flags: u8,
    /// Padding
    pad: [2]u8,

    comptime {
        if (@sizeOf(PvclockVcpuTimeInfo) != 32) {
            @compileError("PvclockVcpuTimeInfo must be exactly 32 bytes");
        }
    }
};

// =============================================================================
// Module State
// =============================================================================

/// Maximum CPUs supported (must match gdt.MAX_CPUS)
const MAX_CPUS: usize = gdt.MAX_CPUS;

/// Physical address of wall clock page
var wall_clock_page_phys: u64 = 0;

/// Virtual pointer to wall clock structure
var wall_clock: ?*volatile PvclockWallClock = null;

/// Physical address of per-vCPU time info page(s)
var vcpu_time_info_page_phys: u64 = 0;

/// Virtual pointer to per-vCPU time info array
var vcpu_time_info: ?[*]volatile PvclockVcpuTimeInfo = null;

/// Whether kvmclock is available and initialized
var kvmclock_available: bool = false;

/// Whether init() has been called
var kvmclock_initialized: bool = false;

/// Cached wall clock base time (seconds since epoch at boot)
var wall_clock_base_sec: u64 = 0;

/// Cached wall clock base time (nanoseconds component)
var wall_clock_base_nsec: u32 = 0;

// =============================================================================
// Public API
// =============================================================================

/// Initialize kvmclock if running under KVM with support
/// Must be called during BSP boot, before SMP initialization
pub fn init() void {
    // Check if kvmclock is supported
    if (!detect.hasKvmclock()) {
        console.info("kvmclock: Not available (not KVM or feature unsupported)", .{});
        return;
    }

    // Allocate physical page for wall clock (shared by all CPUs)
    const wc_page = pmm.allocZeroedPages(1) orelse {
        console.warn("kvmclock: Failed to allocate wall clock page", .{});
        return;
    };
    wall_clock_page_phys = wc_page;

    // Allocate physical page(s) for per-vCPU time info
    // Each entry is 32 bytes, so MAX_CPUS * 32 bytes needed
    // For MAX_CPUS=64, that's 2KB (fits in one 4KB page)
    // Note: These are comptime calculations, so overflow is caught at compile time.
    // We add explicit comptime checks for documentation and to fail clearly if MAX_CPUS grows.
    const bytes_needed = comptime blk: {
        const size = std.math.mul(usize, MAX_CPUS, @sizeOf(PvclockVcpuTimeInfo)) catch
            @compileError("MAX_CPUS * sizeof(PvclockVcpuTimeInfo) overflows usize");
        break :blk size;
    };
    const pages_needed = comptime blk: {
        const val = std.math.add(usize, bytes_needed, 4095) catch
            @compileError("bytes_needed + 4095 overflows usize");
        break :blk val / 4096;
    };
    const vcpu_page = pmm.allocZeroedPages(pages_needed) orelse {
        console.warn("kvmclock: Failed to allocate vcpu time info page", .{});
        // Free wall clock page on failure
        pmm.freePages(wall_clock_page_phys, 1);
        wall_clock_page_phys = 0;
        return;
    };
    vcpu_time_info_page_phys = vcpu_page;

    // Map to kernel virtual via HHDM
    wall_clock = @ptrCast(@alignCast(paging.physToVirt(wall_clock_page_phys)));
    vcpu_time_info = @ptrCast(@alignCast(paging.physToVirt(vcpu_time_info_page_phys)));

    // Register wall clock page with KVM (one-time setup)
    cpu.writeMsr(MSR_KVM_WALL_CLOCK_NEW, wall_clock_page_phys);

    // Read and cache wall clock base time
    if (readWallClockRaw()) |wc| {
        wall_clock_base_sec = wc.sec;
        wall_clock_base_nsec = wc.nsec;
    }

    // Register BSP's system time page with KVM (bit 0 = enable)
    // BSP uses index 0 in the vcpu_time_info array
    cpu.writeMsr(MSR_KVM_SYSTEM_TIME_NEW, vcpu_time_info_page_phys | 1);

    kvmclock_available = true;
    kvmclock_initialized = true;

    console.info("kvmclock: Initialized (wall={x}, vcpu={x})", .{
        wall_clock_page_phys,
        vcpu_time_info_page_phys,
    });
}

/// Initialize kvmclock for an Application Processor
/// Must be called during AP boot sequence
pub fn initAp(cpu_id: usize) void {
    if (!kvmclock_initialized) {
        return;
    }

    if (cpu_id >= MAX_CPUS) {
        console.warn("kvmclock: CPU ID {d} exceeds MAX_CPUS {d}", .{ cpu_id, MAX_CPUS });
        return;
    }

    // Calculate physical address of this CPU's time info slot
    const offset = cpu_id * @sizeOf(PvclockVcpuTimeInfo);
    const ap_time_info_phys = vcpu_time_info_page_phys + offset;

    // Register with KVM (bit 0 = enable)
    cpu.writeMsr(MSR_KVM_SYSTEM_TIME_NEW, ap_time_info_phys | 1);
}

/// Check if kvmclock is available and initialized
pub fn isAvailable() bool {
    return kvmclock_available;
}

/// Get monotonic time in nanoseconds since boot
/// Uses seqlock pattern for TOCTOU safety
pub fn getSystemTimeNs() ?u64 {
    if (!kvmclock_available) return null;

    const cpu_id = getCurrentCpuId();
    if (cpu_id >= MAX_CPUS) return null;

    // Explicit null check for defensive programming
    const vcpu_info = vcpu_time_info orelse return null;
    const info: *volatile PvclockVcpuTimeInfo = &vcpu_info[cpu_id];

    // Seqlock read loop
    var attempts: u32 = 0;
    while (attempts < 10) : (attempts += 1) {
        // Read version with acquire semantics
        const v1 = @atomicLoad(u32, &info.version, .acquire);

        // Odd version means update in progress, retry
        if (v1 & 1 != 0) continue;

        // Read data while version is even (stable)
        const tsc_timestamp = info.tsc_timestamp;
        const system_time = info.system_time;
        const mul = info.tsc_to_system_mul;
        const shift = info.tsc_shift;

        // Compiler barrier before version recheck
        // Compiler fence to prevent reordering (Zig 0.16.x: std.atomic.compilerFence removed)
        asm volatile ("" ::: "memory");

        // Verify version hasn't changed
        const v2 = @atomicLoad(u32, &info.version, .acquire);
        if (v1 != v2) continue;

        // Calculate current time using formula:
        // time_ns = system_time + ((tsc - tsc_timestamp) * mul) >> (32 - shift)
        const tsc_now = cpu.rdtsc();

        // Handle TSC wraparound (unlikely but possible)
        const tsc_delta = tsc_now -% tsc_timestamp;

        // Calculate effective shift (handles negative tsc_shift)
        // If shift >= 0: effective_shift = 32 - shift
        // If shift < 0: effective_shift = 32 + (-shift) = 32 - shift
        const effective_shift: u6 = blk: {
            const shift_i32: i32 = shift;
            const result = 32 - shift_i32;
            if (result < 0 or result > 63) {
                // Invalid shift, return system_time as fallback
                return system_time;
            }
            break :blk @intCast(result);
        };

        // Use u128 for intermediate calculation to avoid overflow
        const ns_delta_128 = (@as(u128, tsc_delta) * mul) >> effective_shift;

        // Truncate to u64 (safe since result should fit)
        const ns_delta: u64 = @truncate(ns_delta_128);

        return system_time +% ns_delta;
    }

    // Failed after max attempts
    return null;
}

/// Get wall clock time (seconds and nanoseconds since Unix epoch)
/// Combines cached base time with monotonic time for accuracy
pub fn getWallClockTime() ?struct { sec: u64, nsec: u32 } {
    if (!kvmclock_available) return null;

    // Get current monotonic time
    const mono_ns = getSystemTimeNs() orelse return null;

    // Combine with cached wall clock base
    // Use u64 for intermediate calculation to prevent overflow:
    // wall_clock_base_nsec (u32) + mono_ns_part (u32) can exceed u32 max (~2B)
    const mono_ns_part: u64 = mono_ns % 1_000_000_000;
    const total_ns: u64 = @as(u64, wall_clock_base_nsec) + mono_ns_part;
    const carry: u64 = total_ns / 1_000_000_000;
    const nsec: u32 = @truncate(total_ns % 1_000_000_000);

    const sec = wall_clock_base_sec + (mono_ns / 1_000_000_000) + carry;

    return .{ .sec = sec, .nsec = nsec };
}

/// Check if TSC is stable (can optimize seqlock reads)
pub fn isTscStable() bool {
    if (!kvmclock_available) return false;

    const cpu_id = getCurrentCpuId();
    if (cpu_id >= MAX_CPUS) return false;

    const vcpu_info = vcpu_time_info orelse return false;
    return (vcpu_info[cpu_id].flags & PVCLOCK_TSC_STABLE_BIT) != 0;
}

/// Check if guest was stopped (migration/suspend occurred)
pub fn wasGuestStopped() bool {
    if (!kvmclock_available) return false;

    const cpu_id = getCurrentCpuId();
    if (cpu_id >= MAX_CPUS) return false;

    const vcpu_info = vcpu_time_info orelse return false;
    return (vcpu_info[cpu_id].flags & PVCLOCK_GUEST_STOPPED) != 0;
}

// =============================================================================
// Internal Helpers
// =============================================================================

/// Read wall clock directly from shared structure
fn readWallClockRaw() ?struct { sec: u32, nsec: u32 } {
    const wc = wall_clock orelse return null;

    // Seqlock read
    var attempts: u32 = 0;
    while (attempts < 10) : (attempts += 1) {
        const v1 = @atomicLoad(u32, &wc.version, .acquire);
        if (v1 & 1 != 0) continue;

        const sec = wc.sec;
        const nsec = wc.nsec;

        // Compiler fence to prevent reordering (Zig 0.16.x: std.atomic.compilerFence removed)
        asm volatile ("" ::: "memory");

        const v2 = @atomicLoad(u32, &wc.version, .acquire);
        if (v1 != v2) continue;

        return .{ .sec = sec, .nsec = nsec };
    }

    return null;
}

/// Get current CPU ID
/// Uses LAPIC ID if APIC is enabled, otherwise returns 0 (BSP)
fn getCurrentCpuId() usize {
    if (apic.lapic.isEnabled()) {
        return apic.lapic.getId();
    }
    return 0;
}
