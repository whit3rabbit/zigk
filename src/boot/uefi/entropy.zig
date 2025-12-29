// UEFI Entropy Acquisition for KASLR
//
// Provides boot-time entropy using UEFI RNG Protocol (EFI_RNG_PROTOCOL).
// Falls back to TSC-based mixing if hardware RNG unavailable.
//
// Must be called BEFORE ExitBootServices since UEFI protocols are unavailable after.

const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;

// EFI_RNG_PROTOCOL GUID: 3152BCA5-EADE-433D-862E-C01CDC291F44
pub const EFI_RNG_PROTOCOL_GUID = uefi.Guid{
    .time_low = 0x3152bca5,
    .time_mid = 0xeade,
    .time_high_and_version = 0x433d,
    .clock_seq_high_and_reserved = 0x86,
    .clock_seq_low = 0x2e,
    .node = [_]u8{ 0xc0, 0x1c, 0xdc, 0x29, 0x1f, 0x44 },
};

// EFI_RNG_PROTOCOL structure
// Zig 0.16 locateProtocol requires Protocol type to have a `guid` field
pub const EfiRngProtocol = extern struct {
    /// GUID for locateProtocol (required by Zig 0.16+ UEFI API)
    pub const guid = EFI_RNG_PROTOCOL_GUID;

    /// Returns information about the RNG algorithms supported by the driver
    getInfo: *const fn (
        self: *EfiRngProtocol,
        rng_algorithm_list_size: *usize,
        rng_algorithm_list: ?*uefi.Guid,
    ) callconv(.c) uefi.Status,

    /// Returns random data from the RNG
    getRng: *const fn (
        self: *EfiRngProtocol,
        rng_algorithm: ?*const uefi.Guid, // NULL = default algorithm
        rng_value_length: usize,
        rng_value: [*]u8,
    ) callconv(.c) uefi.Status,
};

/// Entropy quality indicator
pub const EntropyQuality = enum(u8) {
    hardware = 64, // UEFI RNG Protocol (cryptographic quality)
    weak = 16, // TSC fallback (predictable, use with caution)
    none = 0, // Failed to get any entropy
};

/// Result of entropy acquisition
pub const EntropyResult = struct {
    quality: EntropyQuality,
    bytes_filled: usize,
};

/// Get boot-time entropy for KASLR
/// Must be called before ExitBootServices
pub fn getBootEntropy(bs: *uefi.tables.BootServices, buf: []u8) EntropyResult {
    // Zero-initialize for security (prevents leaking old data on partial fill)
    @memset(buf, 0);

    // Try UEFI RNG Protocol first (Zig 0.16+ API: pass Protocol type, not GUID)
    // locateProtocol returns LocateProtocolError!?*Protocol
    const rng_result = bs.locateProtocol(EfiRngProtocol, null) catch null;
    if (rng_result) |rng| {
        // Use default RNG algorithm (NULL)
        // Function pointer call: first arg is self pointer
        const rng_status = rng.getRng(rng, null, buf.len, buf.ptr);
        if (rng_status == .success) {
            return .{
                .quality = .hardware,
                .bytes_filled = buf.len,
            };
        }
    }

    // Fallback: TSC-based entropy mixing (weak but better than nothing)
    // WARNING: This is NOT cryptographically secure
    return getWeakEntropy(buf);
}

/// Weak entropy fallback using TSC
/// WARNING: Predictable - only use when hardware RNG unavailable
///
/// SECURITY: This fallback provides minimal entropy from TSC timing variance
/// and stack layout. It is NOT cryptographically secure. An attacker with
/// knowledge of boot timing and UEFI memory layout may be able to predict
/// KASLR offsets with reduced effort. Systems requiring strong KASLR should
/// ensure UEFI RNG Protocol (hardware RNG) is available. Consider failing
/// boot entirely in high-security environments when only weak entropy exists.
fn getWeakEntropy(buf: []u8) EntropyResult {
    var state: u64 = readTsc();

    // Mix in stack address for additional (weak) entropy.
    // SECURITY NOTE: We declare stack_addr as undefined but ONLY read its ADDRESS
    // via @intFromPtr, never its VALUE. The undefined contents are never accessed,
    // so there is no information leak. The entropy comes from the stack pointer
    // location (ASLR of UEFI stack), not from residual stack data.
    var stack_addr: u64 = undefined;
    const stack_ptr = @intFromPtr(&stack_addr);
    state ^= stack_ptr;

    // Simple xorshift mixing (NOT cryptographically secure)
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        // Read TSC again for each byte to get timing variance
        const tsc = readTsc();
        state ^= tsc;

        // xorshift64 step
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;

        buf[i] = @truncate(state);
    }

    return .{
        .quality = .weak,
        .bytes_filled = buf.len,
    };
}

/// Read Time/Timestamp Counter (Architecture-specific)
inline fn readTsc() u64 {
    if (comptime builtin.cpu.arch == .x86_64) {
        var lo: u32 = undefined;
        var hi: u32 = undefined;
        asm volatile ("rdtsc"
            : [lo] "={eax}" (lo),
              [hi] "={edx}" (hi),
        );
        return (@as(u64, hi) << 32) | lo;
    } else if (comptime builtin.cpu.arch == .aarch64) {
        var val: u64 = 0;
        asm volatile ("mrs %[ret], cntpct_el0"
            : [ret] "=r" (val),
        );
        return val;
    } else {
        return 0;
    }
}

/// Calculate a random offset from entropy bytes
/// Returns a page-aligned offset within the specified range
pub fn calculateOffset(
    entropy: []const u8,
    entropy_bits: u4, // Number of bits of entropy to use (1-15, 0 returns 0)
    alignment: u64, // Required alignment (e.g., 4096 for page)
) u64 {
    if (entropy.len < 2) return 0;
    if (entropy_bits == 0) return 0;

    // Extract 16 bits from entropy
    const raw: u16 = @as(u16, entropy[0]) | (@as(u16, entropy[1]) << 8);

    // Mask to requested entropy bits
    const mask: u16 = (@as(u16, 1) << entropy_bits) - 1;
    const masked = raw & mask;

    // Scale by alignment
    return @as(u64, masked) * alignment;
}
