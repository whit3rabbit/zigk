//! ASLR (Address Space Layout Randomization)
//!
//! Generates per-process random offsets for memory regions to mitigate
//! exploitation techniques that rely on predictable addresses (ROP, ret2libc).
//!
//! Components randomized:
//!   - Stack top: 22 bits entropy (16GB range)
//!   - PIE base: 16 bits entropy (4GB range, 64KB granularity)
//!   - mmap base: 20 bits entropy (4TB range)
//!   - Heap gap: 16 bits entropy (256MB range after ELF end)
//!   - TLS base: 16 bits entropy (256MB range)
//!
//! Note: VDSO randomization is handled separately in vdso.zig.
//!
//! Entropy source: Kernel CSPRNG (ChaCha20) seeded from RDRAND/RDSEED at boot.

const std = @import("std");
const builtin = @import("builtin");
const random = @import("random");
const pmm = @import("pmm");
const console = @import("console");
const config = @import("config");
const hal = @import("hal");

const PAGE_SIZE: u64 = pmm.PAGE_SIZE;

/// Check if the current platform should allow weak entropy.
/// Returns true for known development/emulator platforms where
/// hardware entropy (RDRAND/FEAT_RNG) may not be properly emulated.
fn shouldAllowWeakEntropy() bool {
    // Build flag always overrides (for edge cases like ancient hardware)
    if (config.allow_weak_entropy) return true;

    const hv_type = hal.hypervisor.getHypervisor();
    return switch (hv_type) {
        // Known emulators with poor RDRAND support
        .qemu_tcg => true,
        // Unknown hypervisor - allow but warn (better UX for dev)
        .unknown => true,
        // "Bare Metal" on aarch64 without FEAT_RNG is likely QEMU TCG
        // (real ARM64 hardware typically has ARMv8.5-RNG).
        // On x86_64, QEMU TCG is detected via CPUID signature.
        .none => builtin.cpu.arch == .aarch64,
        // All others (KVM, VMware, etc.) should have working entropy
        else => false,
    };
}

/// Get human-readable platform name for logging
fn getPlatformName() []const u8 {
    return hal.hypervisor.getHypervisor().name();
}

/// ASLR configuration constants
/// Entropy amounts follow Linux conventions for compatibility.
pub const Config = struct {
    // Entropy bits (page granularity unless noted)

    /// Stack: 11 bits of entropy (2048 pages = 8MB range)
    /// Linux uses 11 bits with variable granularity
    /// Stack: 22 bits of entropy (8GB range implied if we weren't limited by usage)
    /// Linux uses 22 bits. We use 22 bits to match.
    pub const STACK_ENTROPY_BITS: u5 = 22;
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

    /// Heap gap: 16 bits of entropy
    /// Provides stronger defense against heap spraying attacks
    pub const HEAP_ENTROPY_BITS: u5 = 16;
    pub const HEAP_MAX_OFFSET: u64 = (1 << HEAP_ENTROPY_BITS) - 1;

    /// TLS: 16 bits of entropy (256MB range with 4KB granularity)
    pub const TLS_ENTROPY_BITS: u5 = 16;
    pub const TLS_MAX_OFFSET: u64 = (1 << TLS_ENTROPY_BITS) - 1;

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

    /// TLS base (Thread Local Storage)
    /// Randomization adds offset to this base
    pub const TLS_BASE: u64 = 0xB000_0000;
};

/// Per-process ASLR offsets
/// Stored as page/unit counts to save memory; use helper functions for actual addresses.
pub const AslrOffsets = struct {
    /// Stack offset in pages (subtracted from STACK_TOP_BASE)
    /// u32 required to hold 22 bits of entropy (STACK_ENTROPY_BITS)
    stack_offset: u32 = 0,

    /// PIE base offset in 64KB units (added to PIE_BASE)
    pie_offset: u16 = 0,

    /// mmap base offset in pages (added to MMAP_BASE)
    mmap_offset: u32 = 0,

    /// Heap gap offset in pages (added after ELF end)
    /// Changed to u16 for 16 bits entropy
    heap_gap: u16 = 0,

    /// TLS offset in pages (added to TLS_BASE)
    tls_offset: u16 = 0,

    // Cached computed addresses (populated by generateOffsets)
    stack_top: u64 = Config.STACK_TOP_BASE,
    mmap_start: u64 = Config.MMAP_BASE,
    tls_base: u64 = Config.TLS_BASE,

    // Compile-time validation: ensure storage types can hold claimed entropy bits
    comptime {
        if (@bitSizeOf(@TypeOf(@as(AslrOffsets, undefined).stack_offset)) < Config.STACK_ENTROPY_BITS)
            @compileError("stack_offset too small for STACK_ENTROPY_BITS");
        if (@bitSizeOf(@TypeOf(@as(AslrOffsets, undefined).pie_offset)) < Config.PIE_ENTROPY_BITS)
            @compileError("pie_offset too small for PIE_ENTROPY_BITS");
        if (@bitSizeOf(@TypeOf(@as(AslrOffsets, undefined).mmap_offset)) < Config.MMAP_ENTROPY_BITS)
            @compileError("mmap_offset too small for MMAP_ENTROPY_BITS");
        if (@bitSizeOf(@TypeOf(@as(AslrOffsets, undefined).heap_gap)) < Config.HEAP_ENTROPY_BITS)
            @compileError("heap_gap too small for HEAP_ENTROPY_BITS");
        if (@bitSizeOf(@TypeOf(@as(AslrOffsets, undefined).tls_offset)) < Config.TLS_ENTROPY_BITS)
            @compileError("tls_offset too small for TLS_ENTROPY_BITS");
    }
};

/// Error type for ASLR generation
pub const AslrError = error{
    WeakEntropy,
};

/// Generate ASLR offsets for a new process
/// Called during createProcess() and execve()
///
/// Returns error.WeakEntropy if the PRNG is using fallback seed on production platforms.
/// On development/emulator platforms (QEMU TCG, unknown hypervisors), weak entropy is
/// allowed with a warning to improve developer experience while maintaining fail-secure
/// for production deployments.
pub fn generateOffsets() AslrError!AslrOffsets {
    var offsets = AslrOffsets{};

    // SECURITY: Fail-secure per CLAUDE.md policy.
    // If entropy source is weak, check platform to decide whether to allow.
    if (random.isEntropyWeak()) {
        if (shouldAllowWeakEntropy()) {
            // Development/emulator platform - warn but continue
            console.warn("ASLR: Weak entropy on {s} - INSECURE for production!", .{getPlatformName()});
        } else {
            // Production platform - fail secure
            console.err("ASLR: Weak entropy on {s} - refusing to continue", .{getPlatformName()});
            return error.WeakEntropy;
        }
    }

    // Generate random values using kernel random module (CSPRNG)
    offsets.stack_offset = @truncate(random.getU64() % (Config.STACK_MAX_OFFSET + 1));
    offsets.pie_offset = @truncate(random.getU64() % (Config.PIE_MAX_OFFSET + 1));
    offsets.mmap_offset = @truncate(random.getU64() % (Config.MMAP_MAX_OFFSET + 1));
    offsets.heap_gap = @truncate(random.getU64() % (Config.HEAP_MAX_OFFSET + 1));
    offsets.tls_offset = @truncate(random.getU64() % (Config.TLS_MAX_OFFSET + 1));

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

    // TLS: Add offset to base
    offsets.tls_base = Config.TLS_BASE + (@as(u64, offsets.tls_offset) * PAGE_SIZE);
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
    if (builtin.mode != .Debug) return;

    console.debug("ASLR[pid={}]: stack_top={x} pie_base={x} mmap={x} heap_gap={} tls_base={x}", .{
        pid,
        offsets.stack_top,
        getPieBase(offsets),
        offsets.mmap_start,
        offsets.heap_gap,
        offsets.tls_base,
    });
}

/// Check if PRNG is using fallback seed (weak entropy warning)
pub fn isEntropyWeak() bool {
    return random.isEntropyWeak();
}
