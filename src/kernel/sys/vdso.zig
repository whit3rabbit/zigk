const std = @import("std");
const page_size = 4096;

// Vvar layout
pub const Vvar = extern struct {
    sequence: u32,
    _pad1: u32,
    base_sec: u64,
    base_nsec: u64,
    tsc_frequency_hz: u64,
    last_tsc: u64,
    coarse_sec: u64,
    coarse_nsec: u64,
};

const vdso_blob = @import("vdso_blob.zig");

// Global pointers to the mapped pages (in kernel space)
var vvar_page: ?*Vvar = null;
var vdso_page: ?[*]u8 = null;
var vvar_phys: u64 = 0;
var vdso_phys: u64 = 0;

// Atomic guard for SMP-safe initialization (prevents double-init race)
var init_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

const pmm = @import("pmm");
const vmm = @import("vmm");
const hal = @import("hal");
const console = @import("console");
const user_vmm = @import("user_vmm");

pub fn init() !void {
    // Atomic CAS ensures only one CPU wins the init race on SMP
    if (init_done.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
        return; // Another CPU already initialized
    }

    // Allocate Vvar page
    const vvar_p = pmm.allocZeroedPage() orelse return error.OutOfMemory;
    vvar_phys = vvar_p;
    vvar_page = @ptrCast(@alignCast(hal.paging.physToVirt(vvar_p)));

    // Allocate VDSO pages (2 pages / 8KB to cover full image + potential BSS/headers)
    const vdso_page_count = 2;
    const vdso_p = pmm.allocZeroedPages(vdso_page_count) orelse return error.OutOfMemory;
    vdso_phys = vdso_p;
    vdso_page = @ptrCast(hal.paging.physToVirt(vdso_p));

    if (vdso_blob.vdso_image.len > vdso_page_count * page_size) {
        console.warn("VDSO: Image size {} > 8192! Truncated or buggy.", .{vdso_blob.vdso_image.len});
    }

    // Copy blob
    const copy_len = @min(vdso_blob.vdso_image.len, vdso_page_count * page_size);
    hal.mem.copy(vdso_page.?[0..copy_len].ptr, vdso_blob.vdso_image[0..copy_len].ptr, copy_len);

    console.info("VDSO: Initialized (phys={x}, size={})", .{vdso_phys, copy_len});
    
    // Init Vvar data
    const freq = hal.timing.getTscFrequency();
    vvar_page.?.tsc_frequency_hz = freq;
    vvar_page.?.sequence = 0;
    
    // Initial update
    updateTime(0, 0);
}

pub fn update() void {
    const v = vvar_page orelse return;

    // Seqlock write-begin: increment to odd
    // seq_cst provides full barrier - prevents reordering of data writes before this
    _ = @atomicRmw(u32, &v.sequence, .Add, 1, .seq_cst);

    // Update time - use atomic stores to prevent torn reads by userspace
    const freq = @atomicLoad(u64, &v.tsc_frequency_hz, .monotonic);
    if (freq > 0) {
        @atomicStore(u64, &v.last_tsc, hal.timing.rdtsc(), .monotonic);
    }

    // Seqlock write-end: increment to even
    // release ensures all prior data writes are visible before sequence update
    _ = @atomicRmw(u32, &v.sequence, .Add, 1, .release);
}

// Update with explicit time (called from timekeeper)
pub fn updateTime(sec: u64, nsec: u64) void {
    const v = vvar_page orelse return;

    // Seqlock write-begin: increment to odd
    // seq_cst provides full barrier - prevents reordering of data writes before this
    _ = @atomicRmw(u32, &v.sequence, .Add, 1, .seq_cst);

    // All data writes use atomic stores to prevent torn reads
    @atomicStore(u64, &v.base_sec, sec, .monotonic);
    @atomicStore(u64, &v.base_nsec, nsec, .monotonic);
    @atomicStore(u64, &v.last_tsc, hal.timing.rdtsc(), .monotonic);
    @atomicStore(u64, &v.tsc_frequency_hz, hal.timing.getTscFrequency(), .monotonic);

    // Seqlock write-end: increment to even
    // release ensures all prior data writes are visible before sequence update
    _ = @atomicRmw(u32, &v.sequence, .Add, 1, .release);
}

/// Update VDSO time from kvmclock if available (x86_64 only)
/// Provides higher-accuracy time when running under KVM hypervisor
pub fn updateFromKvmclock() void {
    // Only available on x86_64
    if (comptime @import("builtin").cpu.arch != .x86_64) {
        return;
    }

    const kvmclock = hal.hypervisor.kvmclock;
    if (!kvmclock.isAvailable()) {
        return;
    }

    // Get current time from kvmclock
    if (kvmclock.getSystemTimeNs()) |ns| {
        const sec = ns / 1_000_000_000;
        const nsec_part = ns % 1_000_000_000;
        updateTime(sec, nsec_part);
    }
}

/// Update VDSO time from paravirtualized clock source
/// - x86_64: Uses kvmclock for wall time
/// - aarch64: Uses Generic Timer (pvtime provides stolen time, not wall time)
///
/// Note: On aarch64, the Generic Timer (CNTVCT_EL0) is already virtualized
/// by the hypervisor, providing accurate time without special handling.
/// pvtime supplements this with stolen time tracking, not wall time.
pub fn updateFromHypervisor() void {
    const arch = @import("builtin").cpu.arch;

    if (comptime arch == .x86_64) {
        updateFromKvmclock();
    } else if (comptime arch == .aarch64) {
        // On aarch64, the Generic Timer is already virtualized by the hypervisor.
        // Just use the standard update() which reads the Generic Timer.
        // pvtime provides stolen time for CPU accounting, not wall time.
        update();
    }
}

// VDSO placement
//
// WE use ASLR for VDSO/VVAR addresses to mitigate ROP and info leaks.
// Base range: 0x7FFF_E000_0000 (high memory)
// Window: 256MB (65536 pages)
//
// Linux randomizes VDSO within a ~1MB range for 8 bits of entropy.
// We provide 16 bits (65536 locations) for increased security.
const VDSO_HIGH_BASE: u64 = 0x7FFF_E000_0000;

/// Generate a random base address for the VDSO
/// Uses the kernel PRNG to select a random page offset within the ASLR window.
/// Returns a page-aligned virtual address.
pub fn generateBase() u64 {
    const prng = @import("prng");
    // 65536 possible locations (256MB range / 4KB page)
    const random_offset = prng.range(65536);
    return VDSO_HIGH_BASE - (random_offset * page_size);
}

// Public constant removed - address is now per-process
// pub const VDSO_BASE_ADDR: u64 = ...;

pub fn mapToPml4(pml4: u64, vdso_base: u64) !void {
    if (vvar_phys == 0) return; // Not initialized

    // VVAR is always immediately preceding VDSO
    const vvar_base = vdso_base - 4096;

    // Helper to map a page if not already mapped
    const map_fn = struct {
        fn map(pml4_phys: u64, virt: u64, phys: u64, writable: bool, executable: bool) !void {
            const flags = vmm.PageFlags{
                .writable = writable,
                .user = true,
                .no_execute = !executable,
            };
            // Use generic mapPage from VMM
            try vmm.mapPage(pml4_phys, virt, phys, flags);
        }
    }.map;

    // Map VVAR (Read-only for user)
    try map_fn(pml4, vvar_base, vvar_phys, false, false);
    
    // Map VDSO pages (Read/Exec)
    // We map 2 pages (8KB) to cover potential spillover
    try map_fn(pml4, vdso_base, vdso_phys, false, true);
    try map_fn(pml4, vdso_base + 4096, vdso_phys + 4096, false, true);
}

/// Map VDSO into a process address space
/// Generates a random base address, stores it in the process struct, and maps the pages.
/// Returns the chosen VDSO base address.
pub fn map(proc_opaque: *anyopaque) !u64 {
    const Process = @import("process").Process;
    const proc: *Process = @ptrCast(@alignCast(proc_opaque));
    
    // Generate random base
    const base = generateBase();
    
    // Store in process struct for AT_SYSINFO_EHDR
    proc.vdso_base = base;

    // Map using the generated base
    try mapToPml4(proc.cr3, base);

    return base;
}
