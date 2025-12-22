// OSS / DevFS Sound Constants
//
// Defines constants for the Open Sound System (OSS) API, which is often
// used by legacy applications (like Doom) and /dev/dsp implementations.

pub const SNDCTL_DSP_RESET: u32 = 0x00005000;
pub const SNDCTL_DSP_SYNC: u32 = 0x00005001;
pub const SNDCTL_DSP_SPEED: u32 = 0xC0045002;
pub const SNDCTL_DSP_STEREO: u32 = 0xC0045003;
pub const SNDCTL_DSP_GETBLKSIZE: u32 = 0xC0045004;
pub const SNDCTL_DSP_SETFMT: u32 = 0xC0045005;
pub const SNDCTL_DSP_CHANNELS: u32 = 0xC0045006;
pub const SNDCTL_DSP_GETOSPACE: u32 = 0x800C500C; // _IOR('P', 12, audio_buf_info)
pub const SNDCTL_DSP_GETISPACE: u32 = 0x800C500D; // _IOR('P', 13, audio_buf_info)
// POST: 0x00005008?
// RESET is _IO('P', 0) -> 0x5000 ? 0x00005000. Yes.

// Audio Formats
pub const AFMT_QUERY: u32 = 0x00000000;
pub const AFMT_MU_LAW: u32 = 0x00000001;
pub const AFMT_A_LAW: u32 = 0x00000002;
pub const AFMT_IMA_ADPCM: u32 = 0x00000004;
pub const AFMT_U8: u32 = 0x00000008;
pub const AFMT_S16_LE: u32 = 0x00000010; // Little Endian signed 16-bit
pub const AFMT_S16_BE: u32 = 0x00000020; // Big Endian signed 16-bit
pub const AFMT_S8: u32 = 0x00000040;
pub const AFMT_U16_LE: u32 = 0x00000080;
pub const AFMT_U16_BE: u32 = 0x00000100;
