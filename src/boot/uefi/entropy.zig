// UEFI Entropy Acquisition for KASLR
//
// Provides boot-time entropy using UEFI RNG Protocol (EFI_RNG_PROTOCOL).
// Falls back to TSC-based mixing if hardware RNG unavailable.
//
// Must be called BEFORE ExitBootServices since UEFI protocols are unavailable after.

const std = @import("std");
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
fn getWeakEntropy(buf: []u8) EntropyResult {
    var state: u64 = readTsc();

    // Mix in stack address for additional (weak) entropy
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

/// Read Time Stamp Counter
inline fn readTsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// Calculate a random offset from entropy bytes
/// Returns a page-aligned offset within the specified range
pub fn calculateOffset(
    entropy: []const u8,
    entropy_bits: u5, // Number of bits of entropy to use (max 16)
    alignment: u64, // Required alignment (e.g., 4096 for page)
) u64 {
    if (entropy.len < 2) return 0;

    // Extract 16 bits from entropy
    const raw: u16 = @as(u16, entropy[0]) | (@as(u16, entropy[1]) << 8);

    // Mask to requested entropy bits (cast u5 to u4 for shift, max value is 16 which fits)
    const shift_amount: u4 = @intCast(entropy_bits);
    const mask: u16 = (@as(u16, 1) << shift_amount) - 1;
    const masked = raw & mask;

    // Scale by alignment
    return @as(u64, masked) * alignment;
}

// Tests (run on host, not during boot)
test "calculateOffset" {
    const entropy = [_]u8{ 0xFF, 0x0F }; // 0x0FFF = 4095
    const offset = calculateOffset(&entropy, 12, 4096); // 12 bits, page aligned
    try std.testing.expectEqual(@as(u64, 4095 * 4096), offset);
}

test "calculateOffset with masking" {
    const entropy = [_]u8{ 0xFF, 0xFF }; // 0xFFFF
    const offset = calculateOffset(&entropy, 8, 4096); // 8 bits only
    try std.testing.expectEqual(@as(u64, 255 * 4096), offset);
}
