//! Cirrus Logic CL-GD5446 VGA Hardware Definitions
//!
//! Register definitions and constants for the Cirrus Logic CL-GD5446 VGA adapter,
//! commonly used in QEMU with -vga cirrus. Based on the Cirrus Logic GD5446 datasheet.
//!
//! Reference: https://wiki.osdev.org/Cirrus_Logic_GD5446

// PCI Identification
pub const PCI_VENDOR_ID_CIRRUS: u16 = 0x1013;
pub const PCI_DEVICE_ID_GD5446: u16 = 0x00B8;

// VGA I/O Ports
pub const VGA_SEQ_INDEX: u16 = 0x3C4;  // Sequencer Index Register
pub const VGA_SEQ_DATA: u16 = 0x3C5;   // Sequencer Data Register
pub const VGA_GFX_INDEX: u16 = 0x3CE;  // Graphics Controller Index Register
pub const VGA_GFX_DATA: u16 = 0x3CF;   // Graphics Controller Data Register
pub const VGA_CRTC_INDEX: u16 = 0x3D4; // CRTC Index Register (color mode)
pub const VGA_CRTC_DATA: u16 = 0x3D5;  // CRTC Data Register (color mode)
pub const VGA_ATTR_INDEX: u16 = 0x3C0; // Attribute Controller Index/Data
pub const VGA_ATTR_DATA_WRITE: u16 = 0x3C0; // Attribute Controller Data Write
pub const VGA_ATTR_DATA_READ: u16 = 0x3C1;  // Attribute Controller Data Read
pub const VGA_MISC_WRITE: u16 = 0x3C2; // Miscellaneous Output Write
pub const VGA_MISC_READ: u16 = 0x3CC;  // Miscellaneous Output Read
pub const VGA_INPUT_STATUS_1: u16 = 0x3DA; // Input Status Register 1 (resets attr flip-flop)
pub const VGA_DAC_WRITE_INDEX: u16 = 0x3C8; // DAC Write Index
pub const VGA_DAC_DATA: u16 = 0x3C9;        // DAC Data (R, G, B sequence)

// Cirrus-specific Extension Registers
pub const CIRRUS_HIDDEN_DAC_INDEX: u16 = 0x3C6; // Hidden DAC register (for 15/16/24bpp)

// Sequencer Registers (indexed via 0x3C4/0x3C5)
pub const SeqReg = enum(u8) {
    RESET = 0x00,           // Reset register
    CLOCKING_MODE = 0x01,   // Clocking mode
    MAP_MASK = 0x02,        // Map mask (plane enable)
    CHAR_MAP = 0x03,        // Character map select
    MEMORY_MODE = 0x04,     // Memory mode
    // Cirrus Extensions (SR7+)
    EXT_SEQ_MODE = 0x07,    // Extended Sequencer Mode (unlock with 0x12)
    DRAM_CONTROL = 0x0F,    // DRAM control
    SCRATCH_1 = 0x10,       // Scratch register 1
    VCLK3_NUM = 0x0E,       // VCLK3 Numerator
    VCLK3_DENOM = 0x1E,     // VCLK3 Denominator
    // Cirrus SR12-SR14: Cursor control (hardware cursor)
    // Note: Cursor registers share indices with scratch registers, accessed via different modes
    CURSOR_X_HI = 0x11,
    CURSOR_Y_LO = 0x13,     // Actual cursor Y low register
    CURSOR_Y_HI = 0x14,     // Cursor Y high
};

// Graphics Controller Registers (indexed via 0x3CE/0x3CF)
pub const GfxReg = enum(u8) {
    SET_RESET = 0x00,
    ENABLE_SET_RESET = 0x01,
    COLOR_COMPARE = 0x02,
    DATA_ROTATE = 0x03,
    READ_MAP_SELECT = 0x04,
    MODE = 0x05,
    MISC = 0x06,
    COLOR_DONT_CARE = 0x07,
    BIT_MASK = 0x08,
    // Cirrus Extensions (GR9+)
    OFFSET0 = 0x09,       // Offset Register 0
    OFFSET1 = 0x0A,       // Offset Register 1
    MODE_EXT = 0x0B,      // Extended Mode (BLT mode, etc.)
    // BLT registers
    BLT_WIDTH_LO = 0x20,
    BLT_WIDTH_HI = 0x21,
    BLT_HEIGHT_LO = 0x22,
    BLT_HEIGHT_HI = 0x23,
    BLT_DEST_PITCH_LO = 0x24,
    BLT_DEST_PITCH_HI = 0x25,
    BLT_SRC_PITCH_LO = 0x26,
    BLT_SRC_PITCH_HI = 0x27,
    BLT_DEST_ADDR0 = 0x28,
    BLT_DEST_ADDR1 = 0x29,
    BLT_DEST_ADDR2 = 0x2A,
    BLT_SRC_ADDR0 = 0x2C,
    BLT_SRC_ADDR1 = 0x2D,
    BLT_SRC_ADDR2 = 0x2E,
    BLT_MODE = 0x30,
    BLT_START = 0x31,
    BLT_ROP = 0x32,
    BLT_MODE_EXT = 0x33,
};

// CRTC Registers (indexed via 0x3D4/0x3D5)
pub const CrtcReg = enum(u8) {
    H_TOTAL = 0x00,
    H_DISP_END = 0x01,
    H_BLANK_START = 0x02,
    H_BLANK_END = 0x03,
    H_SYNC_START = 0x04,
    H_SYNC_END = 0x05,
    V_TOTAL = 0x06,
    OVERFLOW = 0x07,
    PRESET_ROW_SCAN = 0x08,
    MAX_SCAN_LINE = 0x09,
    CURSOR_START = 0x0A,
    CURSOR_END = 0x0B,
    START_ADDR_HI = 0x0C,
    START_ADDR_LO = 0x0D,
    CURSOR_LOC_HI = 0x0E,
    CURSOR_LOC_LO = 0x0F,
    V_SYNC_START = 0x10,
    V_SYNC_END = 0x11,
    V_DISP_END = 0x12,
    OFFSET = 0x13,
    UNDERLINE_LOC = 0x14,
    V_BLANK_START = 0x15,
    V_BLANK_END = 0x16,
    MODE_CONTROL = 0x17,
    LINE_COMPARE = 0x18,
    // Cirrus Extensions (CR1A+)
    INTERLACE_END = 0x19,
    MISC_CONTROL = 0x1A,
    EXT_DISPLAY = 0x1B,  // Extended Display Controls (bit 7: enable extended modes)
    SYNC_ADJUST = 0x1C,
    OVERLAY = 0x1D,
};

// Hidden DAC unlock sequence values
pub const HIDDEN_DAC_UNLOCK_SEQ = [_]u8{ 0, 0, 0, 0 }; // Read 4 times to unlock
pub const HIDDEN_DAC_MODE_8BPP: u8 = 0x00;
pub const HIDDEN_DAC_MODE_15BPP: u8 = 0xC0; // 5-5-5 RGB
pub const HIDDEN_DAC_MODE_16BPP: u8 = 0xC1; // 5-6-5 RGB
pub const HIDDEN_DAC_MODE_24BPP: u8 = 0xC5; // 8-8-8 RGB (packed)
pub const HIDDEN_DAC_MODE_32BPP: u8 = 0xC5; // Same as 24bpp with padding

// Cirrus unlock key for extended registers
pub const CIRRUS_UNLOCK_KEY: u8 = 0x12;

// BAR indices
/// BAR0: MMIO registers (optional, not always present)
pub const BAR_MMIO: u8 = 0;
/// BAR1: Linear Frame Buffer (4MB)
pub const BAR_LFB: u8 = 1;

// Default VRAM sizes for Cirrus variants (QEMU emulates 4MB by default)
pub const DEFAULT_VRAM_SIZE: u32 = 4 * 1024 * 1024; // 4MB
pub const MAX_VRAM_SIZE: u32 = 4 * 1024 * 1024;     // CL-GD5446 max is 4MB

// Resolution and depth limits for CL-GD5446
pub const MAX_WIDTH: u16 = 1600;  // Theoretical max (limited by VRAM)
pub const MAX_HEIGHT: u16 = 1200; // Theoretical max (limited by VRAM)
pub const MIN_WIDTH: u16 = 320;
pub const MIN_HEIGHT: u16 = 200;

// Supported bits per pixel values
pub const BPP_8: u8 = 8;   // 256 color palette mode
pub const BPP_15: u8 = 15; // 5-5-5 RGB (1 bit unused)
pub const BPP_16: u8 = 16; // 5-6-5 RGB
pub const BPP_24: u8 = 24; // 8-8-8 RGB (packed)
pub const BPP_32: u8 = 32; // 8-8-8-X XRGB (4 bytes per pixel)

/// Calculate bytes per pixel from BPP value
pub fn bytesPerPixel(bpp: u8) u8 {
    return switch (bpp) {
        8 => 1,
        15, 16 => 2,
        24 => 3,
        32 => 4,
        else => 4, // Default to 32bpp
    };
}

/// Validate resolution against hardware limits and VRAM
pub fn isValidResolution(width: u16, height: u16, bpp: u8, vram_size: u32) bool {
    if (width < MIN_WIDTH or width > MAX_WIDTH) return false;
    if (height < MIN_HEIGHT or height > MAX_HEIGHT) return false;

    // Check VRAM requirements
    const bpp_bytes: u32 = bytesPerPixel(bpp);
    const fb_size = @as(u32, width) *| @as(u32, height) *| bpp_bytes;
    if (fb_size == 0 or fb_size > vram_size) return false;

    return true;
}

/// Validate bits per pixel value
pub fn isValidBpp(bpp: u8) bool {
    return bpp == BPP_8 or bpp == BPP_15 or bpp == BPP_16 or bpp == BPP_24 or bpp == BPP_32;
}

/// Get Hidden DAC mode value for a given BPP
pub fn getHiddenDacMode(bpp: u8) u8 {
    return switch (bpp) {
        8 => HIDDEN_DAC_MODE_8BPP,
        15 => HIDDEN_DAC_MODE_15BPP,
        16 => HIDDEN_DAC_MODE_16BPP,
        24, 32 => HIDDEN_DAC_MODE_24BPP,
        else => HIDDEN_DAC_MODE_8BPP,
    };
}

/// Standard VGA mode timings for common resolutions
/// CRTC register values based on standard VESA timings
pub const ModeTiming = struct {
    h_total: u16,
    h_disp_end: u16,
    h_blank_start: u16,
    h_blank_end: u16,
    h_sync_start: u16,
    h_sync_end: u16,
    v_total: u16,
    v_disp_end: u16,
    v_blank_start: u16,
    v_blank_end: u16,
    v_sync_start: u16,
    v_sync_end: u16,
    offset: u16,     // Bytes per scanline / 8
    misc_output: u8, // Misc output register value
};

/// Get mode timings for standard resolutions
pub fn getModeTiming(width: u16, height: u16, bpp: u8) ?ModeTiming {
    const offset: u16 = @truncate((@as(u32, width) *| bytesPerPixel(bpp)) / 8);

    return switch (width) {
        640 => switch (height) {
            480 => ModeTiming{
                .h_total = 99,        // (800 / 8) - 1
                .h_disp_end = 79,     // (640 / 8) - 1
                .h_blank_start = 79,
                .h_blank_end = 99,
                .h_sync_start = 83,   // (656 + 8) / 8
                .h_sync_end = 95,
                .v_total = 524,
                .v_disp_end = 479,
                .v_blank_start = 479,
                .v_blank_end = 524,
                .v_sync_start = 489,
                .v_sync_end = 491,
                .offset = offset,
                .misc_output = 0xE3,  // Positive sync, 25MHz clock
            },
            else => null,
        },
        800 => switch (height) {
            600 => ModeTiming{
                .h_total = 131,       // (1056 / 8) - 1
                .h_disp_end = 99,     // (800 / 8) - 1
                .h_blank_start = 99,
                .h_blank_end = 131,
                .h_sync_start = 105,
                .h_sync_end = 121,
                .v_total = 627,
                .v_disp_end = 599,
                .v_blank_start = 599,
                .v_blank_end = 627,
                .v_sync_start = 600,
                .v_sync_end = 604,
                .offset = offset,
                .misc_output = 0x2B,  // 40MHz clock
            },
            else => null,
        },
        1024 => switch (height) {
            768 => ModeTiming{
                .h_total = 167,       // (1344 / 8) - 1
                .h_disp_end = 127,    // (1024 / 8) - 1
                .h_blank_start = 127,
                .h_blank_end = 167,
                .h_sync_start = 131,
                .h_sync_end = 147,
                .v_total = 805,
                .v_disp_end = 767,
                .v_blank_start = 767,
                .v_blank_end = 805,
                .v_sync_start = 770,
                .v_sync_end = 776,
                .offset = offset,
                .misc_output = 0xEF,  // 65MHz clock
            },
            else => null,
        },
        else => null,
    };
}
