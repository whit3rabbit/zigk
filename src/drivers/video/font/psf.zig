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
    const magic1 = @as(*const u16, @ptrCast(data.ptr)).*;
    if (magic1 == PSF1_MAGIC) {
        const header = @as(*const Psf1Header, @ptrCast(data.ptr));
        const glyph_data = data[@sizeOf(Psf1Header)..];
        
        return types.Font{
            .width = 8, // PSF1 is always 8 pixels wide
            .height = header.char_size,
            .bytes_per_glyph = header.char_size,
            .data = glyph_data,
        };
    }

    if (data.len < @sizeOf(Psf2Header)) return Error.InvalidSize;
    
    // Check PSF2
    const magic2 = @as(*const u32, @ptrCast(data.ptr)).*;
    if (magic2 == PSF2_MAGIC) {
        const header = @as(*const Psf2Header, @ptrCast(data.ptr));
        const glyph_data = data[header.header_size..];
        
        return types.Font{
            .width = @intCast(header.width),
            .height = @intCast(header.height),
            .bytes_per_glyph = header.char_size,
            .data = glyph_data,
        };
    }

    return Error.InvalidMagic;
}
