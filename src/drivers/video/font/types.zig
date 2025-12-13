
pub const Font = struct {
    width: u8,
    height: u8,
    data: []const u8, // Raw bitmap data
    bytes_per_glyph: u32,
    
    // Default implementation for standard bitmap fonts (row-major, byte-aligned rows)
    pub fn getGlyph(self: Font, char: u8) []const u8 {
        const idx = @as(u32, char);
        const offset = idx * self.bytes_per_glyph;
        if (offset >= self.data.len) return self.data[0..self.bytes_per_glyph]; // Return first glyph (usually empty/null) if OOB
        return self.data[offset .. offset + self.bytes_per_glyph];
    }
};
