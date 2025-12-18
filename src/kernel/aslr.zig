//! ASLR (Address Space Layout Randomization)
//!
//! Generates per-process random offsets for memory regions to mitigate
//! exploitation techniques that rely on predictable addresses (ROP, ret2libc).
//!
//! Components randomized:
//!   - Stack top: 11 bits entropy (8MB range)
//!   - PIE base: 16 bits entropy (4GB range, 64KB granularity)
//!   - mmap base: 20 bits entropy (4TB range)
//!   - Heap gap: 8 bits entropy (1MB range after ELF end)
//!
//! Note: VDSO randomization is handled separately in vdso.zig (already implemented).
//!
//! Entropy source: Kernel PRNG (xoroshiro128+) seeded from RDRAND/RDSEED at boot.

const std = @import("std");
const prng = @import("prng");
const pmm = @import("pmm");
const console = @import("console");

const PAGE_SIZE: u64 = pmm.PAGE_SIZE;

/// ASLR configuration constants
/// Entropy amounts follow Linux conventions for compatibility.
pub const Config = struct {
    // Entropy bits (page granularity unless noted)

    /// Stack: 11 bits of entropy (2048 pages = 8MB range)
    /// Linux uses 11 bits with variable granularity
    pub const STACK_ENTROPY_BITS: u5 = 11;
    pub const STACK_MAX_OFFSET: u64 = (1 << STACK_ENTROPY_BITS) - 1;

    /// PIE: 16 bits of entropy in 64KB units (4GB range)
    /// 64KB granularity matches common ELF alignment requirements
    pub const PIE_ENTROPY_BITS: u5 = 16;
    pub const PIE_MAX_OFFSET: u64 = (1 << PIE_ENTROPY_BITS) - 1;
    pub const PIE_GRANULARITY: u64 = 64 * 1024; // 64KB alignment

    /// mmap: 20 bits of entropy (1M pages = ~4TB range)
    /// Linux uses up to 28 bits; we use 20 for practical VM limits
    pub const MMAP_ENTROPY_BITS: u5 = 20;
    pub const MMAP_MAX_OFFSET: u64 = (1 << MMAP_ENTROPY_BITS) - 1;

    /// Heap gap: 8 bits of entropy (256 pages = 1MB range)
    /// Provides defense against heap spraying attacks
    pub const HEAP_ENTROPY_BITS: u5 = 8;
    pub const HEAP_MAX_OFFSET: u64 = (1 << HEAP_ENTROPY_BITS) - 1;

    // Base addresses (before randomization)

    /// Stack grows downward from near top of user space
    /// Randomization subtracts offset from this base
    pub const STACK_TOP_BASE: u64 = 0x7FFF_FFFF_F000;

    /// PIE executables load here (higher than traditional 0x400000)
    /// Randomization adds offset to this base
    pub const PIE_BASE: u64 = 0x5555_5000_0000;

    /// mmap region starts here (16TB mark)
    /// Randomization adds offset to this base
    pub const MMAP_BASE: u64 = 0x0000_1000_0000_0000;
};

/// Per-process ASLR offsets
/// Stored as page/unit counts to save memory; use helper functions for actual addresses.
pub const AslrOffsets = struct {
    /// Stack offset in pages (subtracted from STACK_TOP_BASE)
    stack_offset: u16 = 0,

    /// PIE base offset in 64KB units (added to PIE_BASE)
    pie_offset: u16 = 0,

    /// mmap base offset in pages (added to MMAP_BASE)
    mmap_offset: u32 = 0,

    /// Heap gap offset in pages (added after ELF end)
    heap_gap: u8 = 0,

    // Cached computed addresses (populated by generateOffsets)
    stack_top: u64 = Config.STACK_TOP_BASE,
    mmap_start: u64 = Config.MMAP_BASE,
};

/// Generate ASLR offsets for a new process
/// Called during createProcess() and execve()
pub fn generateOffsets() AslrOffsets {
    var offsets = AslrOffsets{};

    // Generate random values using kernel PRNG
    // prng.range() uses rejection sampling to avoid modulo bias
    offsets.stack_offset = @truncate(prng.range(Config.STACK_MAX_OFFSET + 1));
    offsets.pie_offset = @truncate(prng.range(Config.PIE_MAX_OFFSET + 1));
    offsets.mmap_offset = @truncate(prng.range(Config.MMAP_MAX_OFFSET + 1));
    offsets.heap_gap = @truncate(prng.range(Config.HEAP_MAX_OFFSET + 1));

    // Compute cached addresses
    computeAddresses(&offsets);

    return offsets;
}

/// Compute cached addresses from offsets
fn computeAddresses(offsets: *AslrOffsets) void {
    // Stack: Subtract offset from base (grows downward in high memory)
    offsets.stack_top = Config.STACK_TOP_BASE - (@as(u64, offsets.stack_offset) * PAGE_SIZE);

    // mmap: Add offset to base (grows upward)
    offsets.mmap_start = Config.MMAP_BASE + (@as(u64, offsets.mmap_offset) * PAGE_SIZE);
}

/// Get PIE load base for a process
/// Returns randomized base address for position-independent executables
pub fn getPieBase(offsets: *const AslrOffsets) u64 {
    return Config.PIE_BASE + (@as(u64, offsets.pie_offset) * Config.PIE_GRANULARITY);
}

/// Get heap start with randomized gap
/// The gap provides defense against heap spraying by making heap base unpredictable
pub fn getHeapStart(elf_end: u64, offsets: *const AslrOffsets) u64 {
    const aligned_end = std.mem.alignForward(u64, elf_end, PAGE_SIZE);
    return aligned_end + (@as(u64, offsets.heap_gap) * PAGE_SIZE);
}

/// Log ASLR configuration for debugging
pub fn logOffsets(offsets: *const AslrOffsets, pid: u32) void {
    console.debug("ASLR[pid={}]: stack_top={x} pie_base={x} mmap={x} heap_gap={}", .{
        pid,
        offsets.stack_top,
        getPieBase(offsets),
        offsets.mmap_start,
        offsets.heap_gap,
    });
}

/// Check if PRNG is using fallback seed (weak entropy warning)
pub fn isEntropyWeak() bool {
    return prng.isUsingFallbackSeed();
}
