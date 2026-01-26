//! Bochs VGA/BGA (Bochs Graphics Adapter) Hardware Definitions
//!
//! Register definitions and constants for the Bochs VGA adapter, commonly used
//! in QEMU and Bochs emulators. Based on the VBE DISPI interface specification.
//! Reference: https://wiki.osdev.org/Bochs_VBE_Extensions

// PCI Identification
pub const PCI_VENDOR_ID_BOCHS: u16 = 0x1234;
pub const PCI_DEVICE_ID_BGA: u16 = 0x1111;

// Legacy I/O Ports (for older VBE DISPI interface)
pub const VBE_DISPI_IOPORT_INDEX: u16 = 0x01CE;
pub const VBE_DISPI_IOPORT_DATA: u16 = 0x01CF;

// MMIO offset for DISPI registers within BAR2 (when using MMIO mode)
// The DISPI registers are mapped at BAR2 + 0x500
pub const MMIO_DISPI_OFFSET: usize = 0x500;

/// VBE DISPI Register Indices
/// These are written to the index port (or MMIO offset) to select the register,
/// then the data port (or MMIO offset + 1) is used to read/write the value.
pub const Dispi = enum(u16) {
    /// ID register - returns version ID when read
    ID = 0,
    /// Horizontal resolution in pixels
    XRES = 1,
    /// Vertical resolution in pixels
    YRES = 2,
    /// Bits per pixel (8, 15, 16, 24, or 32)
    BPP = 3,
    /// Enable register - controls display mode
    ENABLE = 4,
    /// Memory bank number (for banked modes, largely obsolete)
    BANK = 5,
    /// Virtual width in pixels (for scrolling/panning)
    VIRT_WIDTH = 6,
    /// Virtual height in pixels
    VIRT_HEIGHT = 7,
    /// X offset for display panning
    X_OFFSET = 8,
    /// Y offset for display panning (used for page flipping)
    Y_OFFSET = 9,
};

// Enable register flags
/// Disabled - VGA compatibility mode
pub const VBE_DISPI_DISABLED: u16 = 0x00;
/// Enabled - BGA extended mode active
pub const VBE_DISPI_ENABLED: u16 = 0x01;
/// Use Linear Frame Buffer (LFB) instead of banked mode
pub const VBE_DISPI_LFB_ENABLED: u16 = 0x40;
/// Do not clear video memory on mode switch
pub const VBE_DISPI_NOCLEARMEM: u16 = 0x80;

// Combined enable flags for common configurations
/// Standard LFB mode (enabled + LFB)
pub const VBE_DISPI_ENABLED_LFB: u16 = VBE_DISPI_ENABLED | VBE_DISPI_LFB_ENABLED;
/// LFB mode without clearing memory (for double buffering transitions)
pub const VBE_DISPI_ENABLED_LFB_NOCLEAR: u16 = VBE_DISPI_ENABLED | VBE_DISPI_LFB_ENABLED | VBE_DISPI_NOCLEARMEM;

// Version IDs (returned by ID register)
// Higher versions support more features
pub const VBE_DISPI_ID0: u16 = 0xB0C0; // Original Bochs VBE
pub const VBE_DISPI_ID1: u16 = 0xB0C1; // Added virtual width/height
pub const VBE_DISPI_ID2: u16 = 0xB0C2; // Added 32-bit BPP support
pub const VBE_DISPI_ID3: u16 = 0xB0C3; // Added preserve video memory
pub const VBE_DISPI_ID4: u16 = 0xB0C4; // Added VRAM size query
pub const VBE_DISPI_ID5: u16 = 0xB0C5; // Current version (QEMU default)

// Resolution and depth limits
pub const MAX_WIDTH: u16 = 2560;
pub const MAX_HEIGHT: u16 = 1600;
pub const MIN_WIDTH: u16 = 320;
pub const MIN_HEIGHT: u16 = 200;

// Supported bits per pixel values
pub const BPP_8: u16 = 8; // 256 color palette mode
pub const BPP_15: u16 = 15; // 5-5-5 RGB (1 bit unused)
pub const BPP_16: u16 = 16; // 5-6-5 RGB
pub const BPP_24: u16 = 24; // 8-8-8 RGB (packed)
pub const BPP_32: u16 = 32; // 8-8-8-8 XRGB/ARGB

// Default VRAM size in QEMU (16 MB)
pub const DEFAULT_VRAM_SIZE: usize = 16 * 1024 * 1024;

// BAR indices
/// BAR0: Legacy VGA memory (0xA0000-0xBFFFF mapping)
pub const BAR_VGA_MEMORY: u8 = 0;
/// BAR1: MMIO registers (optional, not always present)
pub const BAR_MMIO: u8 = 1;
/// BAR2: Linear Frame Buffer
pub const BAR_LFB: u8 = 2;

// QEMU-specific extended registers (via MMIO at BAR2 + 0x400)
pub const QEMU_EXTENDED_OFFSET: usize = 0x400;

/// QEMU extended register indices
pub const QemuExt = enum(u16) {
    /// Framebuffer big-endian flag
    BIG_ENDIAN = 0x04,
};

/// Calculate bytes per pixel from BPP value
pub fn bytesPerPixel(bpp: u16) u8 {
    return switch (bpp) {
        8 => 1,
        15, 16 => 2,
        24 => 3,
        32 => 4,
        else => 4, // Default to 32bpp
    };
}

/// Calculate minimum framebuffer size for given resolution and depth
pub fn calculateFramebufferSize(width: u16, height: u16, bpp: u16) usize {
    const bpp_bytes: usize = bytesPerPixel(bpp);
    return @as(usize, width) * @as(usize, height) * bpp_bytes;
}

/// Validate resolution against hardware limits
pub fn isValidResolution(width: u16, height: u16) bool {
    return width >= MIN_WIDTH and width <= MAX_WIDTH and
        height >= MIN_HEIGHT and height <= MAX_HEIGHT;
}

/// Validate bits per pixel value
pub fn isValidBpp(bpp: u16) bool {
    return bpp == BPP_8 or bpp == BPP_15 or bpp == BPP_16 or bpp == BPP_24 or bpp == BPP_32;
}
