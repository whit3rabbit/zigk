// AC97 Native Audio Mixer (NAM) Registers (IO Space)
pub const NAM_RESET: u16 = 0x00;
pub const NAM_MASTER_VOL: u16 = 0x02;
pub const NAM_PCM_OUT_VOL: u16 = 0x18;
pub const NAM_EXT_AUDIO_ID: u16 = 0x28;
pub const NAM_EXT_AUDIO_CTRL: u16 = 0x2A;
pub const NAM_PCM_FRONT_DAC_RATE: u16 = 0x2C;
pub const NAM_PCM_SURR_DAC_RATE: u16 = 0x2E;
pub const NAM_PCM_LFE_DAC_RATE: u16 = 0x30;

// AC97 Extended Audio ID/Ctrl Bits
pub const EAI_VRA: u16 = 1 << 0;
pub const EAC_VRA: u16 = 1 << 0;

// AC97 Native Audio Bus Master (NABM) Registers (IO Space)
pub const NABM_PO_BDBAR: u16 = 0x10; // PCM Out Buffer Descriptor Base Address
pub const NABM_PO_CIV: u16 = 0x14;   // Current Index Value
pub const NABM_PO_LVI: u16 = 0x15;   // Last Valid Index
pub const NABM_PO_SR: u16 = 0x16;    // Status Register
pub const NABM_PO_PICB: u16 = 0x18;  // Position In Current Buffer
pub const NABM_PO_CR: u16 = 0x1B;    // Control Register
pub const NABM_GLOB_CNT: u16 = 0x2C; // Global Control
pub const NABM_GLOB_STA: u16 = 0x30; // Global Status

// NABM Status Register Bits
pub const SR_DCH: u16 = 1 << 0;   // DMA Controller Halted
pub const SR_CELV: u16 = 1 << 1;  // Current Equals Last Valid
pub const SR_LVBCI: u16 = 1 << 2; // Last Valid Buffer Completion Interrupt
pub const SR_BCIS: u16 = 1 << 3;  // Buffer Completion Interrupt Status
pub const SR_FIFO: u16 = 1 << 4;  // FIFO Error

// NABM Control Register Bits
pub const CR_RPBM: u8 = 1 << 0;   // Run/Pause Bus Master
pub const CR_RR: u8 = 1 << 1;     // Reset Registers
pub const CR_LVBIE: u8 = 1 << 2;  // Last Valid Buffer Interrupt Enable
pub const CR_FEIE: u8 = 1 << 3;   // FIFO Error Interrupt Enable
pub const CR_IOCE: u8 = 1 << 4;   // Interrupt On Completion Enable
