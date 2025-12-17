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

const pmm = @import("pmm");
const vmm = @import("vmm");
const hal = @import("hal");
const console = @import("console");
const user_vmm = @import("user_vmm");

pub fn init() !void {
    if (vvar_page != null) return;

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
    @memcpy(vdso_page.?[0..copy_len], vdso_blob.vdso_image[0..copy_len]);

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

    // Seqlock write
    _ = @atomicRmw(u32, &v.sequence, .Add, 1, .monotonic);
    std.atomic.spinLoopHint(); // Barrier

    // Update time
    // For MVP, just updating last_tsc.
    // Ideally we sync with wall clock.
    const freq = v.tsc_frequency_hz;
    if (freq > 0) {
        v.last_tsc = hal.timing.rdtsc();
    }

    std.atomic.spinLoopHint(); // Barrier
    _ = @atomicRmw(u32, &v.sequence, .Add, 1, .release);
}

// Update with explicit time (called from timekeeper)
pub fn updateTime(sec: u64, nsec: u64) void {
    const v = vvar_page orelse return;

    // Sequence begin
    _ = @atomicRmw(u32, &v.sequence, .Add, 1, .monotonic);
    std.atomic.spinLoopHint(); 
    
    v.base_sec = sec;
    v.base_nsec = nsec;
    v.last_tsc = hal.timing.rdtsc();
    // Refresh freq just in case
    v.tsc_frequency_hz = hal.timing.getTscFrequency();
    
    std.atomic.spinLoopHint();
    // Sequence end
    _ = @atomicRmw(u32, &v.sequence, .Add, 1, .release);
}

// VDSO placement
//
// SECURITY TODO: Implement ASLR for VDSO/VVAR addresses.
//
// Currently the VDSO and VVAR pages are mapped at fixed addresses, making them
// predictable targets for exploitation:
// - Information disclosure: Attacker knows exactly where timing data is located
// - ROP gadget hunting: Fixed VDSO code location simplifies Return-Oriented
//   Programming attacks by providing reliable gadget addresses
// - ASLR bypass: Known VDSO address can be used to calculate other addresses
//   via relative offsets if any info leak exists
//
// Recommended fix:
// 1. Add a per-process random offset (e.g., 12-16 bits of entropy)
// 2. Calculate VDSO base as: BASE - (random_offset * PAGE_SIZE)
// 3. Store the actual VDSO address in the process struct for AT_SYSINFO_EHDR
// 4. Ensure VVAR immediately precedes VDSO at (vdso_base - PAGE_SIZE)
//
// Linux randomizes VDSO within a ~1MB range for 8 bits of entropy.
pub const VDSO_BASE_ADDR: u64 = 0x7FFF_E000_0000;
const VVAR_BASE_ADDR: u64 = VDSO_BASE_ADDR - 4096;

pub fn mapToPml4(pml4: u64) !u64 {
    if (vvar_phys == 0) return 0; // Not initialized

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
    try map_fn(pml4, VVAR_BASE_ADDR, vvar_phys, false, false);
    
    // Map VDSO pages (Read/Exec)
    // We map 2 pages (8KB) to cover potential spillover
    try map_fn(pml4, VDSO_BASE_ADDR, vdso_phys, false, true);
    try map_fn(pml4, VDSO_BASE_ADDR + 4096, vdso_phys + 4096, false, true);

    return VDSO_BASE_ADDR;
}

pub fn map(proc_opaque: *anyopaque) !u64 {
    const Process = @import("process").Process;
    const proc: *Process = @ptrCast(@alignCast(proc_opaque));
    return mapToPml4(proc.cr3);
}
