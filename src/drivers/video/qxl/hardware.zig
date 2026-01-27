//! QXL Hardware Definitions
//!
//! Register definitions and constants for the QXL paravirtualized graphics device.
//! Used in QEMU/KVM with the "-vga qxl" or "-device qxl" option.
//! Reference: QEMU hw/display/qxl.h, spice-protocol/spice/qxl_dev.h

// PCI Identification
pub const PCI_VENDOR_ID_REDHAT: u16 = 0x1B36;
pub const PCI_DEVICE_ID_QXL: u16 = 0x0100;

// BAR indices
/// BAR0: QXL ROM (read-only, contains mode list and device info)
pub const BAR_ROM: u8 = 0;
/// BAR1: VRAM (video memory for framebuffer)
pub const BAR_VRAM: u8 = 1;
/// BAR2: RAM (command rings, surfaces, cursors)
pub const BAR_RAM: u8 = 2;
/// BAR3: I/O ports (commands and status)
pub const BAR_IO: u8 = 3;

// I/O Port Offsets (relative to BAR3 I/O base)
/// Notify the device (write-only, value is ignored)
pub const IO_NOTIFY_CMD: u16 = 0x00;
/// Notify cursor update (write-only)
pub const IO_NOTIFY_CURSOR: u16 = 0x04;
/// Update area notification (write-only)
pub const IO_UPDATE_AREA: u16 = 0x08;
/// Update IRQ (write-only)
pub const IO_UPDATE_IRQ: u16 = 0x0C;
/// Notify OOM (out of memory) condition
pub const IO_NOTIFY_OOM: u16 = 0x10;
/// Reset device (write-only)
pub const IO_RESET: u16 = 0x14;
/// Set mode (write mode number)
pub const IO_SET_MODE: u16 = 0x18;
/// Log message (write-only, debug)
pub const IO_LOG: u16 = 0x1C;
/// Memslot add (write-only)
pub const IO_MEMSLOT_ADD: u16 = 0x20;
/// Memslot delete (write-only)
pub const IO_MEMSLOT_DEL: u16 = 0x24;
/// Create primary surface (write mode number)
pub const IO_CREATE_PRIMARY: u16 = 0x28;
/// Destroy primary surface (write-only)
pub const IO_DESTROY_PRIMARY: u16 = 0x2C;
/// Destroy all surfaces (write-only)
pub const IO_DESTROY_ALL_SURFACES: u16 = 0x30;
/// Flush surfaces (write-only)
pub const IO_FLUSH_SURFACES: u16 = 0x34;
/// Flush release ring (write-only)
pub const IO_FLUSH_RELEASE: u16 = 0x38;

// ROM Header Structure Offsets
/// ROM magic number: "QXRO" (0x4F525851 little-endian)
pub const ROM_MAGIC: u32 = 0x4F525851;
/// Offset to mode count in ROM header
pub const ROM_NUM_MODES_OFFSET: usize = 0x28;
/// Offset to modes array in ROM header
pub const ROM_MODES_OFFSET: usize = 0x2C;

// RAM Header Magic
/// RAM magic number: "QXRA" (0x41525851 little-endian)
pub const RAM_MAGIC: u32 = 0x41525851;

// Surface Types
pub const SURFACE_TYPE_PRIMARY: u32 = 0;

// Resolution limits
pub const MIN_WIDTH: u16 = 320;
pub const MIN_HEIGHT: u16 = 200;
pub const MAX_WIDTH: u16 = 2560;
pub const MAX_HEIGHT: u16 = 1600;

// Supported bits per pixel
pub const BPP_16: u16 = 16;
pub const BPP_24: u16 = 24;
pub const BPP_32: u16 = 32;

// Default VRAM size (QEMU default is 64MB for QXL)
pub const DEFAULT_VRAM_SIZE: usize = 64 * 1024 * 1024;

// Mode flags
pub const MODE_FLAG_VALID: u32 = 1;

/// QXL Mode descriptor from ROM
/// Packed to match hardware layout
pub const QxlMode = extern struct {
    /// Mode ID (for SET_MODE command)
    id: u32,
    /// Horizontal resolution
    x_res: u32,
    /// Vertical resolution
    y_res: u32,
    /// Bits per pixel
    bits: u32,
    /// Bytes per scanline (stride/pitch)
    stride: u32,
    /// X position for display (usually 0)
    x_mili: u32,
    /// Y position for display (usually 0)
    y_mili: u32,
    /// Orientation (0 = landscape)
    orientation: u32,
};

/// QXL Surface Create descriptor
/// Used when creating the primary surface
pub const QxlSurfaceCreate = extern struct {
    width: u32,
    height: u32,
    stride: i32, // Can be negative for bottom-up
    format: u32,
    position: u32,
    mouse_mode: u32,
    flags: u32,
    surface_type: u32, // 0 = primary
    mem: u64, // Physical address of surface memory
};

// Surface formats
pub const SURFACE_FMT_32_xRGB: u32 = 32;
pub const SURFACE_FMT_32_ARGB: u32 = 33;
pub const SURFACE_FMT_16_555: u32 = 16;
pub const SURFACE_FMT_16_565: u32 = 17;

/// Calculate bytes per pixel from BPP value
pub fn bytesPerPixel(bpp: u16) u8 {
    return switch (bpp) {
        16 => 2,
        24 => 3,
        32 => 4,
        else => 4, // Default to 32bpp
    };
}

/// Validate resolution against hardware limits
pub fn isValidResolution(width: u16, height: u16) bool {
    return width >= MIN_WIDTH and width <= MAX_WIDTH and
        height >= MIN_HEIGHT and height <= MAX_HEIGHT;
}

/// Validate bits per pixel value
pub fn isValidBpp(bpp: u16) bool {
    return bpp == BPP_16 or bpp == BPP_24 or bpp == BPP_32;
}

/// Get surface format from BPP
pub fn surfaceFormatFromBpp(bpp: u16) u32 {
    return switch (bpp) {
        16 => SURFACE_FMT_16_565,
        24, 32 => SURFACE_FMT_32_xRGB,
        else => SURFACE_FMT_32_xRGB,
    };
}
