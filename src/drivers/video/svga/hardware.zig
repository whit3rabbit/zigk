//! VMware SVGA II Hardware Definitions
//!
//! Register definitions and constants for the VMware SVGA II virtual graphics adapter.
//! Based on the public "vmware_svga.h" and OSDev documentation.

pub const PCI_VENDOR_ID_VMWARE = 0x15AD;
pub const PCI_DEVICE_ID_VMWARE_SVGA2 = 0x0405;

// Port offsets (relative to Base Port in BAR0)
pub const SVGA_INDEX_PORT = 0x0;
pub const SVGA_VALUE_PORT = 0x1;
pub const SVGA_BIOS_PORT = 0x2;
pub const SVGA_IRQ_PORT = 0x8;

// SVGA Registers
pub const Registers = enum(u32) {
    ID = 0,
    ENABLE = 1,
    WIDTH = 2,
    HEIGHT = 3,
    MAX_WIDTH = 4,
    MAX_HEIGHT = 5,
    DEPTH = 6,
    BPP = 7,         // Bits Per Pixel
    PSEUDOCOLOR = 8,
    RED_MASK = 9,
    GREEN_MASK = 10,
    BLUE_MASK = 11,
    BYTES_PER_LINE = 12, // Pitch
    FB_START = 13,       // Framebuffer start offset
    FB_OFFSET = 14,
    VRAM_SIZE = 15,
    FB_SIZE = 16,
    
    // Capabilities
    CAPABILITIES = 17,
    MEM_START = 18,      // FIFO memory start
    MEM_SIZE = 19,
    CONFIG_DONE = 20,    // Tell host we are done configuring
    SYNC = 21,
    BUSY = 22,
    GUEST_ID = 23,       // Guest OS ID
    CURSOR_ID = 24,      // Cursor ID
    CURSOR_X = 25,
    CURSOR_Y = 26,
    CURSOR_ON = 27,
    
    // FIFO registers
    HOST_BITS_PER_PIXEL = 28,
};

// Magic numbers
pub const SVGA_ID_FLASH = 0x9; // Deprecated
pub const SVGA_ID_0 = 0x90000000;
pub const SVGA_ID_1 = 0x90000001;
pub const SVGA_ID_2 = 0x90000002;
pub const SVGA_ID_INVALID = 0xFFFFFFFF;

// FIFO Constants
pub const FIFO_MIN = 0;
pub const FIFO_MAX = 1;
pub const FIFO_NEXT_CMD = 2;
pub const FIFO_STOP = 3;

// FIFO Commands
pub const Cmd = enum(u32) {
    Invalid = 0,
    Update = 1, // Update a rectangle (x, y, w, h)
    RectCopy = 2,
    RectFill = 3, // Accelerated fill
    DefineCursor = 19,
    DefineAlphaCursor = 22,
};
