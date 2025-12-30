const std = @import("std");

pub const Font = struct {
    width: u8,
    height: u8,
    data: []const u8, // Raw bitmap data
    bytes_per_glyph: u32,

    // Empty glyph fallback for error cases
    const empty_glyph: [32]u8 = [_]u8{0} ** 32;

    // Default implementation for standard bitmap fonts (row-major, byte-aligned rows)
    pub fn getGlyph(self: Font, char: u8) []const u8 {
        const idx = @as(u32, char);

        // Use checked arithmetic to prevent overflow
        const offset = std.math.mul(u32, idx, self.bytes_per_glyph) catch {
            return self.safeFirstGlyph();
        };
        const end = std.math.add(u32, offset, self.bytes_per_glyph) catch {
            return self.safeFirstGlyph();
        };

        // Bounds check the entire glyph range, not just offset
        if (end > self.data.len) {
            return self.safeFirstGlyph();
        }

        return self.data[offset..end];
    }

    // Safely return first glyph or empty fallback
    fn safeFirstGlyph(self: Font) []const u8 {
        if (self.bytes_per_glyph <= self.data.len and self.bytes_per_glyph <= 32) {
            return self.data[0..self.bytes_per_glyph];
        }
        // Font data is corrupt/truncated - return empty glyph
        const safe_len = @min(self.bytes_per_glyph, 32);
        return empty_glyph[0..safe_len];
    }
};
