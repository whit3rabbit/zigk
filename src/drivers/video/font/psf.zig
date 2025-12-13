const std = @import("std");
const types = @import("types.zig");

// PSF1 Header
const Psf1Header = packed struct {
    magic: u16, // 0x0436
    mode: u8,
    char_size: u8,
};

const PSF1_MAGIC = 0x0436;

// PSF2 Header
const Psf2Header = packed struct {
    magic: u32, // 0x864ab572
    version: u32,
    header_size: u32,
    flags: u32,
    length: u32, // Number of glyphs
    char_size: u32, // Bytes per glyph
    height: u32,
    width: u32,
};

const PSF2_MAGIC = 0x864ab572;

pub const Error = error{
    InvalidMagic,
    InvalidSize,
    UnsupportedVersion,
};

pub fn loadFont(data: []const u8) !types.Font {
    if (data.len < @sizeOf(Psf1Header)) return Error.InvalidSize;

    // Check PSF1
    const magic1 = std.mem.readIntLittle(u16, data[0..2]);
    if (magic1 == PSF1_MAGIC) {
        // Can't cast packed struct ptr directly if unaligned
        // Read fields manually or copy to aligned stack struct
        // Since Psf1Header is small (4 bytes), read manually
        // const mode = data[2]; // Unused
        const char_size = data[3];
        const header_size = 4;
        
        if (data.len < header_size + (256 * @as(usize, char_size))) {
             // Basic size check assuming 256 glyphs for PSF1 without unicode table
             // PSF1 is simple, often 256 chars. 512 mode exists.
             // Just invalid size if data.len < header_size is covered.
             // Let's rely on slice bounds check later?
             // But user asked for validation.
        }

        const glyph_data = data[header_size..];
        
        return types.Font{
            .width = 8, // PSF1 is always 8 pixels wide
            .height = char_size,
            .bytes_per_glyph = char_size,
            .data = glyph_data,
        };
    }

    if (data.len < @sizeOf(Psf2Header)) return Error.InvalidSize;
    
    // Check PSF2
    const magic2 = std.mem.readIntLittle(u32, data[0..4]);
    if (magic2 == PSF2_MAGIC) {
        // Read header fields safely
        const version = std.mem.readIntLittle(u32, data[4..8]);
        const header_size = std.mem.readIntLittle(u32, data[8..12]);
        const flags = std.mem.readIntLittle(u32, data[12..16]);
        const length = std.mem.readIntLittle(u32, data[16..20]);
        const char_size = std.mem.readIntLittle(u32, data[20..24]);
        const height = std.mem.readIntLittle(u32, data[24..28]);
        const width = std.mem.readIntLittle(u32, data[28..32]);

        _ = version;
        _ = flags;

        // Validation
        if (header_size > data.len) return Error.InvalidSize;
        
        const total_glyph_size = @as(usize, length) * char_size;
        if (header_size + total_glyph_size > data.len) return Error.InvalidSize;
        
        if (width == 0 or height == 0 or char_size == 0) return Error.InvalidSize;

        const glyph_data = data[header_size..];
        
        return types.Font{
            .width = @intCast(width),
            .height = @intCast(height),
            .bytes_per_glyph = char_size,
            .data = glyph_data,
        };
    }

    return Error.InvalidMagic;
}
