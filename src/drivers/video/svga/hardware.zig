//! VMware SVGA II Hardware Definitions
//!
//! Register definitions and constants for the VMware SVGA II virtual graphics adapter.
//! Based on the public "vmware_svga.h" and OSDev documentation.

pub const PCI_VENDOR_ID_VMWARE = 0x15AD;
pub const PCI_DEVICE_ID_VMWARE_SVGA2 = 0x0405;

// Port offsets (relative to Base Port in BAR0)
pub const SVGA_INDEX_PORT: u16 = 0x0;
pub const SVGA_VALUE_PORT: u16 = 0x1;
pub const SVGA_BIOS_PORT: u16 = 0x2;
pub const SVGA_IRQ_PORT: u16 = 0x8;

// SVGA Registers
pub const Registers = enum(u32) {
    ID = 0,
    ENABLE = 1,
    WIDTH = 2,
    HEIGHT = 3,
    MAX_WIDTH = 4,
    MAX_HEIGHT = 5,
    DEPTH = 6,
    BPP = 7, // Bits Per Pixel
    PSEUDOCOLOR = 8,
    RED_MASK = 9,
    GREEN_MASK = 10,
    BLUE_MASK = 11,
    BYTES_PER_LINE = 12, // Pitch
    FB_START = 13, // Framebuffer start offset
    FB_OFFSET = 14,
    VRAM_SIZE = 15,
    FB_SIZE = 16,

    // Capabilities
    CAPABILITIES = 17,
    MEM_START = 18, // FIFO memory start
    MEM_SIZE = 19,
    CONFIG_DONE = 20, // Tell host we are done configuring
    SYNC = 21,
    BUSY = 22,
    GUEST_ID = 23, // Guest OS ID
    CURSOR_ID = 24, // Cursor ID
    CURSOR_X = 25,
    CURSOR_Y = 26,
    CURSOR_ON = 27,

    // Extended registers
    HOST_BITS_PER_PIXEL = 28,
    SCRATCH_SIZE = 29, // Scratch register size
    MEM_REGS = 30, // FIFO register count
    NUM_DISPLAYS = 31, // Number of displays
    PITCHLOCK = 32, // Pitch lock register

    // IRQ registers
    IRQMASK = 33, // IRQ mask register
    NUM_GUEST_DISPLAYS = 34,
    CONFIG_PAGES = 35,
    MAX_PRIMARY_BOUNDING_BOX = 36,
    SUGGESTED_GBOBJECT_SIZE = 37,
    DEV_CAP = 38, // Device capabilities
    CMD_SIZE = 39,
    CMD_PROGRESS = 40,
    GUEST_DRIVER_ID = 41,
    GUEST_DRIVER_VERSION1 = 42,
    GUEST_DRIVER_VERSION2 = 43,
    GUEST_DRIVER_VERSION3 = 44,
    MAX = 45,
};

// Magic numbers
pub const SVGA_ID_FLASH = 0x9; // Deprecated
pub const SVGA_ID_0 = 0x90000000;
pub const SVGA_ID_1 = 0x90000001;
pub const SVGA_ID_2 = 0x90000002;
pub const SVGA_ID_INVALID = 0xFFFFFFFF;

// FIFO register indices (word offsets into FIFO memory)
pub const FIFO_MIN = 0;
pub const FIFO_MAX = 1;
pub const FIFO_NEXT_CMD = 2;
pub const FIFO_STOP = 3;

// Extended FIFO registers (when extended_fifo capability is set)
pub const FIFO_CAPABILITIES = 4;
pub const FIFO_FLAGS = 5;
pub const FIFO_FENCE = 6;
pub const FIFO_3D_HWVERSION = 7;
pub const FIFO_PITCHLOCK = 8;
pub const FIFO_CURSOR_ON = 9;
pub const FIFO_CURSOR_X = 10;
pub const FIFO_CURSOR_Y = 11;
pub const FIFO_CURSOR_COUNT = 12;
pub const FIFO_CURSOR_LAST_UPDATED = 13;
pub const FIFO_RESERVED = 14;
pub const FIFO_CURSOR_SCREEN_ID = 15;
pub const FIFO_DEAD = 16;
pub const FIFO_3D_HWVERSION_REVISED = 17;
pub const FIFO_3D_CAPS = 32; // Start of 3D capabilities (256 entries)
pub const FIFO_3D_CAPS_LAST = 287;
pub const FIFO_GUEST_3D_HWVERSION = 288;
pub const FIFO_FENCE_GOAL = 289;
pub const FIFO_BUSY = 290;
pub const FIFO_NUM_REGS = 293;

// FIFO Commands (2D)
pub const Cmd = enum(u32) {
    Invalid = 0,
    Update = 1, // Update a rectangle (x, y, w, h)
    RectCopy = 2, // Copy rectangle (src_x, src_y, dst_x, dst_y, w, h)
    RectFill = 3, // Fill rectangle (color, x, y, w, h)
    RectRopFill = 4, // ROP fill
    RectRopCopy = 5, // ROP copy
    RectRopBltScreenToGmrFb = 6,
    RectRopBltGmrFbToScreen = 7,
    DefineCursor = 19, // Define monochrome cursor
    DefineAlphaCursor = 22, // Define ARGB alpha cursor
    UpdateVerbose = 25, // Verbose update
    FrontRopFill = 29, // Front buffer ROP fill
    Fence = 30, // Fence command for synchronization
    Escape = 33, // Escape command for extensions
    DefineScreen = 34, // Define screen object
    DestroyScreen = 35, // Destroy screen object
    DefineGmrFb = 36, // Define GMR framebuffer
    BlitGmrFbToScreen = 37, // Blit GMR to screen
    BlitScreenToGmrFb = 38, // Blit screen to GMR
    AnnotationFill = 39,
    AnnotationCopy = 40,
    DefineGmr2 = 41, // Define GMR2
    RemapGmr2 = 42, // Remap GMR2
    Max = 43,
};

// SVGA3D Command IDs (for 3D support)
pub const Cmd3d = enum(u32) {
    SurfaceDefine = 1040,
    SurfaceDestroy = 1041,
    SurfaceCopy = 1042,
    SurfaceStretchBlt = 1043,
    SurfaceDMA = 1044,
    ContextDefine = 1045,
    ContextDestroy = 1046,
    SetTransform = 1047,
    SetZRange = 1048,
    SetRenderState = 1049,
    SetRenderTarget = 1050,
    SetTextureState = 1051,
    SetMaterial = 1052,
    SetLightData = 1053,
    SetLightEnabled = 1054,
    SetViewport = 1055,
    SetClipPlane = 1056,
    Clear = 1057,
    Present = 1058, // Present surface to screen
    ShaderDefine = 1059,
    ShaderDestroy = 1060,
    SetShader = 1061,
    SetShaderConst = 1062,
    DrawPrimitives = 1063,
    SetScissorRect = 1064,
    BeginQuery = 1065,
    EndQuery = 1066,
    WaitForQuery = 1067,
    ActivateSurface = 1070,
    DeactivateSurface = 1071,
};

// IRQ flags
pub const IRQ_FENCE_DONE: u32 = 0x01;
pub const IRQ_FIFO_PROGRESS: u32 = 0x02;
pub const IRQ_ANY: u32 = IRQ_FENCE_DONE | IRQ_FIFO_PROGRESS;

// Cursor definitions
pub const MAX_CURSOR_WIDTH: u32 = 64;
pub const MAX_CURSOR_HEIGHT: u32 = 64;

// Guest OS IDs (for GUEST_ID register)
pub const GUEST_OS_LINUX: u32 = 0x5008;
pub const GUEST_OS_OTHER: u32 = 0x500A;

// Maximum safe values for validation
pub const MAX_WIDTH_LIMIT: u32 = 8192;
pub const MAX_HEIGHT_LIMIT: u32 = 8192;
pub const MAX_VRAM_SIZE: u32 = 512 * 1024 * 1024; // 512MB
pub const MAX_FB_SIZE: u32 = 256 * 1024 * 1024; // 256MB

// Command structure sizes (in bytes)
pub const CMD_UPDATE_SIZE: u32 = 5 * @sizeOf(u32); // cmd, x, y, w, h
pub const CMD_RECTFILL_SIZE: u32 = 6 * @sizeOf(u32); // cmd, color, x, y, w, h
pub const CMD_RECTCOPY_SIZE: u32 = 7 * @sizeOf(u32); // cmd, src_x, src_y, dst_x, dst_y, w, h
pub const CMD_FENCE_SIZE: u32 = 2 * @sizeOf(u32); // cmd, fence_id

// Cursor command header size (before pixel data)
pub const CMD_DEFINE_CURSOR_HEADER_SIZE: u32 = 7 * @sizeOf(u32);
pub const CMD_DEFINE_ALPHA_CURSOR_HEADER_SIZE: u32 = 6 * @sizeOf(u32);

// SVGA3D surface flags
pub const SURFACE_FLAG_CUBEMAP: u32 = 0x01;
pub const SURFACE_FLAG_HINT_STATIC: u32 = 0x02;
pub const SURFACE_FLAG_HINT_DYNAMIC: u32 = 0x04;
pub const SURFACE_FLAG_HINT_RENDERTARGET: u32 = 0x08;
pub const SURFACE_FLAG_HINT_DEPTHSTENCIL: u32 = 0x10;
pub const SURFACE_FLAG_HINT_WRITEONLY: u32 = 0x20;
pub const SURFACE_FLAG_HINT_TEXTURE: u32 = 0x40;

// SVGA3D surface formats
pub const SurfaceFormat = enum(u32) {
    Invalid = 0,
    X8R8G8B8 = 1,
    A8R8G8B8 = 2,
    R5G6B5 = 3,
    X1R5G5B5 = 4,
    A1R5G5B5 = 5,
    A4R4G4B4 = 6,
    Z_D32 = 7,
    Z_D16 = 8,
    Z_D24S8 = 9,
    Z_D15S1 = 10,
    LUMINANCE8 = 11,
    LUMINANCE4_ALPHA4 = 12,
    LUMINANCE16 = 13,
    LUMINANCE8_ALPHA8 = 14,
    DXT1 = 15,
    DXT2 = 16,
    DXT3 = 17,
    DXT4 = 18,
    DXT5 = 19,
    BUMPU8V8 = 20,
    BUMPL6V5U5 = 21,
    BUMPX8L8V8U8 = 22,
    BUMPL8V8U8 = 23,
    ARGB_S10E5 = 24,
    ARGB_S23E8 = 25,
    A2R10G10B10 = 26,
    V8U8 = 27,
    Q8W8V8U8 = 28,
    CxV8U8 = 29,
    X8L8V8U8 = 30,
    A2W10V10U10 = 31,
    ALPHA8 = 32,
    R_S10E5 = 33,
    R_S23E8 = 34,
    RG_S10E5 = 35,
    RG_S23E8 = 36,
    BUFFER = 37,
    Z_D24X8 = 38,
    V16U16 = 39,
    G16R16 = 40,
    A16B16G16R16 = 41,
    UYVY = 42,
    YUY2 = 43,
    NV12 = 44,
    AYUV = 45,
    Max = 46,
};
