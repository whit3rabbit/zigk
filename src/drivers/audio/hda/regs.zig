// Intel High Definition Audio (HDA) Register Definitions
// Reference: Intel High Definition Audio Specification 1.0

// Global Capabilities
pub const GCAP: u16 = 0x00;
pub const VMIN: u16 = 0x02;
pub const VMAJ: u16 = 0x03;
pub const OUTPAY: u16 = 0x04;
pub const INPAY: u16 = 0x06;
pub const GCTL: u16 = 0x08; // Global Control
pub const WAKEEN: u16 = 0x0C;
pub const STATESTS: u16 = 0x0E;
pub const GSTS: u16 = 0x10;
pub const INTCTL: u16 = 0x20; // Interrupt Control
pub const INTSTS: u16 = 0x24; // Interrupt Status
pub const WALCLK: u16 = 0x30; // Wall Clock (counter)
pub const SSYNC: u16 = 0x38;

// CORB (Command Outbound Ring Buffer) Registers
pub const CORBLBASE: u16 = 0x40;
pub const CORBUBASE: u16 = 0x44;
pub const CORBWP: u16 = 0x48;
pub const CORBRP: u16 = 0x4A;
pub const CORBCTL: u16 = 0x4C;
pub const CORBSTS: u16 = 0x4D;
pub const CORBSIZE: u16 = 0x4E;

// RIRB (Response Inbound Ring Buffer) Registers
pub const RIRBLBASE: u16 = 0x50;
pub const RIRBUBASE: u16 = 0x54;
pub const RIRBWP: u16 = 0x58;
pub const RIRBRP: u16 = 0x5A; // Note: Not in HW, maintained by SW for RIRB but HW has RIRBWP
pub const RIRBCTL: u16 = 0x5C;
pub const RIRBSTS: u16 = 0x5D;
pub const RIRBSIZE: u16 = 0x5E;

// Immediate Command Interface
pub const ICOI: u16 = 0x60;
pub const ICII: u16 = 0x64;
pub const ICIS: u16 = 0x68;

// Stream Descriptor Offsets (Input, Output, Bidirectional)
pub const SD_BASE: u16 = 0x80;
pub const SD_STRIDE: u16 = 0x20;

// Stream Descriptor Registers
pub const SD_CTL: u16 = 0x00; // Control (3 bytes: 0-2)
pub const SD_STS: u16 = 0x03; // Status (1 byte)
pub const SD_LPIB: u16 = 0x04; // Link Position in Buffer
pub const SD_CBL: u16 = 0x08; // Cyclic Buffer Length
pub const SD_LVI: u16 = 0x0C; // Last Valid Index
pub const SD_FMT: u16 = 0x12; // Stream Format
pub const SD_BDLPL: u16 = 0x18; // BDL Pointer Lower
pub const SD_BDLPU: u16 = 0x1C; // BDL Pointer Upper

// Bit Masks
pub const GCTL_CRST: u32 = 1 << 0; // Controller Reset
pub const CORBCTL_DMA_RUN: u8 = 1 << 1;
pub const CORBCTL_INT_EN: u8 = 1 << 0;
pub const RIRBCTL_DMA_RUN: u8 = 1 << 1;
pub const RIRBCTL_INT_EN: u8 = 1 << 0;
pub const RIRBSTS_INT: u8 = 1 << 0;

// Codec Command Verbs (4-bit node ID handled in logic)
pub const VERB_GET_PARAM: u32 = 0xF0000;
pub const VERB_SET_CONN_SELECT: u32 = 0x70100;
pub const VERB_GET_CONN_LIST: u32 = 0xF0200;
pub const VERB_SET_AMP_GAIN_MUTE: u32 = 0x30000;
