const std = @import("std");
const testing = std.testing;

pub const Vectors = struct {
    pub const MSI_BASE: u8 = 48;
    pub const MSI_END: u8 = 254;
};

var msi_vector_bitmap: [26]u8 = [_]u8{0} ** 26;

fn resetBitmap() void {
    @memset(&msi_vector_bitmap, 0);
}

// Helper to check if a bit is set
fn isSet(vector: u8) bool {
    if (vector < Vectors.MSI_BASE or vector > Vectors.MSI_END) return false;
    const offset = vector - Vectors.MSI_BASE;
    const byte_idx = offset / 8;
    const bit: u3 = @truncate(offset % 8);
    return (msi_vector_bitmap[byte_idx] & (@as(u8, 1) << bit)) != 0;
}

// Helper to set a bit (manual allocation for testing)
fn setBit(vector: u8) void {
    if (vector < Vectors.MSI_BASE or vector > Vectors.MSI_END) return;
    const offset = vector - Vectors.MSI_BASE;
    const byte_idx = offset / 8;
    const bit: u3 = @truncate(offset % 8);
    msi_vector_bitmap[byte_idx] |= (@as(u8, 1) << bit);
}

// Proposed implementation
pub fn allocateMsiVectors(count: u8) ?u8 {
    if (count == 0) return null;

    // Ensure count is power of 2
    if (!std.math.isPowerOfTwo(count)) return null;

    // Search for contiguous block
    // We iterate through potential start vectors.
    // Start vector must be aligned to count.

    // Iterate from MSI_BASE to MSI_END
    var base: u16 = Vectors.MSI_BASE;

    // Align base to count
    const rem = base % count;
    if (rem != 0) {
        base += (count - rem);
    }

    while (base + count - 1 <= Vectors.MSI_END) : (base += count) {
        // Check if block [base, base + count) is free
        var free = true;
        var i: u16 = 0;
        while (i < count) : (i += 1) {
            const vector = @as(u8, @intCast(base + i));
            const offset = vector - Vectors.MSI_BASE;
            const byte_idx = offset / 8;
            const bit: u3 = @truncate(offset % 8);
            if ((msi_vector_bitmap[byte_idx] & (@as(u8, 1) << bit)) != 0) {
                free = false;
                break;
            }
        }

        if (free) {
            // Allocate it
            i = 0;
            while (i < count) : (i += 1) {
                const vector = @as(u8, @intCast(base + i));
                const offset = vector - Vectors.MSI_BASE;
                const byte_idx = offset / 8;
                const bit: u3 = @truncate(offset % 8);
                msi_vector_bitmap[byte_idx] |= (@as(u8, 1) << bit);
            }
            return @as(u8, @intCast(base));
        }
    }

    return null;
}

test "allocate single vector" {
    resetBitmap();
    const v = allocateMsiVectors(1);
    try testing.expect(v != null);
    try testing.expect(v.? == 48);
    try testing.expect(isSet(48));
    try testing.expect(!isSet(49));
}

test "allocate block of 4" {
    resetBitmap();
    const v = allocateMsiVectors(4);
    try testing.expect(v != null);
    try testing.expect(v.? == 48); // 48 is divisible by 4
    try testing.expect(isSet(48));
    try testing.expect(isSet(49));
    try testing.expect(isSet(50));
    try testing.expect(isSet(51));
    try testing.expect(!isSet(52));
}

test "allocate block with alignment gap" {
    resetBitmap();
    // 48 is divisible by 32? No. 48/32 = 1.5.
    // Next multiple of 32 is 64.
    const v = allocateMsiVectors(32);
    try testing.expect(v != null);
    try testing.expect(v.? == 64);

    // Check bits
    for (0..32) |i| {
        try testing.expect(isSet(@as(u8, @intCast(64 + i))));
    }
    try testing.expect(!isSet(63)); // Gap
    try testing.expect(!isSet(96));
}

test "fragmentation" {
    resetBitmap();
    // Allocate 4 vectors at 48
    setBit(48);

    // Try allocate 4 vectors. Should skip 48..51 because 48 is used.
    // Next base is 48+4 = 52.
    // 52 is divisible by 4.
    // Check 52..55. Free.

    const v = allocateMsiVectors(4);
    try testing.expect(v != null);
    try testing.expect(v.? == 52);
    try testing.expect(isSet(52));
    try testing.expect(isSet(55));
}

test "power of 2 check" {
    resetBitmap();
    const v = allocateMsiVectors(3);
    try testing.expect(v == null);
}

test "out of vectors" {
    resetBitmap();
    // Fill up enough vectors so that 32 block fails
    // 64..95 is the only valid 32-block in 48..254 ?
    // 48..63 (16)
    // 64..95 (32) - Valid
    // 96..127 (32) - Valid
    // 128..159 (32) - Valid
    // 160..191 (32) - Valid
    // 192..223 (32) - Valid
    // 224..255 (32) - 255 is invalid.

    // So if we occupy 64..224, it should fail.

    // Let's set a bit in every 32-aligned block
    setBit(64);
    setBit(96);
    setBit(128);
    setBit(160);
    setBit(192);
    // 224 is valid start, but 224+32-1 = 255 > 254. So loop logic prevents it.

    const v = allocateMsiVectors(32);
    try testing.expect(v == null);
}
