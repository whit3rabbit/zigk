// VirtIO-Sound Device Configuration
//
// Device configuration structures and constants per VirtIO Specification 1.2+ Section 5.14
//
// Reference: https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html

const std = @import("std");

// =============================================================================
// PCI Device Identification
// =============================================================================

/// VirtIO vendor ID
pub const PCI_VENDOR_VIRTIO: u16 = 0x1AF4;

/// VirtIO-Sound modern device ID (VirtIO 1.0+)
/// Formula: 0x1040 + device_type, where device_type = 25 for sound
pub const PCI_DEVICE_SOUND_MODERN: u16 = 0x1059;

/// VirtIO-Sound legacy device ID
pub const PCI_DEVICE_SOUND_LEGACY: u16 = 0x1019;

// =============================================================================
// VirtIO-Sound Feature Bits
// =============================================================================

/// Feature flags for VirtIO-Sound devices (Section 5.14.3)
pub const Features = struct {
    /// Device supports control elements (jacks, volumes)
    pub const CTLS: u64 = 1 << 0;
};

// =============================================================================
// VirtIO-Sound Configuration Space
// =============================================================================

/// VirtIO-Sound device configuration (Section 5.14.4)
/// This structure is read from the device-specific configuration space
pub const VirtioSoundConfig = extern struct {
    /// Number of available jacks
    jacks: u32 align(1),
    /// Number of available PCM streams
    streams: u32 align(1),
    /// Number of available channel maps
    chmaps: u32 align(1),

    pub fn size() usize {
        return @sizeOf(VirtioSoundConfig);
    }
};

// Compile-time verification of config structure size
comptime {
    if (@sizeOf(VirtioSoundConfig) != 12) {
        @compileError("VirtioSoundConfig size mismatch - expected 12 bytes");
    }
}

// =============================================================================
// VirtIO Queue Indices
// =============================================================================

/// VirtIO-Sound virtqueue indices
pub const QueueIndex = struct {
    /// Control virtqueue (configuration requests)
    pub const CONTROL: u16 = 0;
    /// Event virtqueue (async notifications)
    pub const EVENT: u16 = 1;
    /// First TX virtqueue (PCM playback)
    pub const TX_BASE: u16 = 2;
    /// First RX virtqueue (PCM capture)
    pub const RX_BASE: u16 = 3;
};

// =============================================================================
// Control Request Codes (Section 5.14.6.1)
// =============================================================================

/// Control request types
pub const ControlCode = struct {
    // Jack control requests
    pub const JACK_INFO: u32 = 1;
    pub const JACK_REMAP: u32 = 2;

    // PCM control requests
    pub const PCM_INFO: u32 = 0x0100;
    pub const PCM_SET_PARAMS: u32 = 0x0101;
    pub const PCM_PREPARE: u32 = 0x0102;
    pub const PCM_RELEASE: u32 = 0x0103;
    pub const PCM_START: u32 = 0x0104;
    pub const PCM_STOP: u32 = 0x0105;

    // Channel map control requests
    pub const CHMAP_INFO: u32 = 0x0200;
};

// =============================================================================
// Status Codes (Section 5.14.6.1)
// =============================================================================

/// Response status codes
pub const Status = struct {
    /// Operation completed successfully
    pub const OK: u32 = 0x8000;
    /// Unknown or unsupported request
    pub const BAD_MSG: u32 = 0x8001;
    /// Operation not supported
    pub const NOT_SUPP: u32 = 0x8002;
    /// I/O error during operation
    pub const IO_ERR: u32 = 0x8003;
};

// =============================================================================
// PCM Stream Direction
// =============================================================================

/// Stream direction (Section 5.14.6.6.1)
pub const StreamDirection = struct {
    /// Playback (host -> guest speakers)
    pub const OUTPUT: u8 = 0;
    /// Capture (microphone -> host)
    pub const INPUT: u8 = 1;
};

// =============================================================================
// PCM Format Bits (Section 5.14.6.6.2)
// =============================================================================

/// Supported PCM formats (bitmask in stream info)
pub const PcmFormat = struct {
    pub const IMA_ADPCM: u64 = 1 << 0;
    pub const MU_LAW: u64 = 1 << 1;
    pub const A_LAW: u64 = 1 << 2;
    pub const S8: u64 = 1 << 3;
    pub const U8: u64 = 1 << 4;
    pub const S16: u64 = 1 << 5;
    pub const U16: u64 = 1 << 6;
    pub const S18_3: u64 = 1 << 7;
    pub const U18_3: u64 = 1 << 8;
    pub const S20_3: u64 = 1 << 9;
    pub const U20_3: u64 = 1 << 10;
    pub const S24_3: u64 = 1 << 11;
    pub const U24_3: u64 = 1 << 12;
    pub const S20: u64 = 1 << 13;
    pub const U20: u64 = 1 << 14;
    pub const S24: u64 = 1 << 15;
    pub const U24: u64 = 1 << 16;
    pub const S32: u64 = 1 << 17;
    pub const U32: u64 = 1 << 18;
    pub const FLOAT: u64 = 1 << 19;
    pub const FLOAT64: u64 = 1 << 20;

    /// Get format index from bitmask (for PCM_SET_PARAMS)
    pub fn toIndex(format: u64) ?u8 {
        if (format == 0) return null;
        var idx: u8 = 0;
        var f = format;
        while (f > 1) : (idx += 1) {
            f >>= 1;
        }
        return idx;
    }
};

// =============================================================================
// PCM Rate Bits (Section 5.14.6.6.2)
// =============================================================================

/// Supported sample rates (bitmask in stream info)
pub const PcmRate = struct {
    pub const R5512: u64 = 1 << 0;
    pub const R8000: u64 = 1 << 1;
    pub const R11025: u64 = 1 << 2;
    pub const R16000: u64 = 1 << 3;
    pub const R22050: u64 = 1 << 4;
    pub const R32000: u64 = 1 << 5;
    pub const R44100: u64 = 1 << 6;
    pub const R48000: u64 = 1 << 7;
    pub const R64000: u64 = 1 << 8;
    pub const R88200: u64 = 1 << 9;
    pub const R96000: u64 = 1 << 10;
    pub const R176400: u64 = 1 << 11;
    pub const R192000: u64 = 1 << 12;
    pub const R384000: u64 = 1 << 13;

    /// Get rate index from bitmask (for PCM_SET_PARAMS)
    pub fn toIndex(rate: u64) ?u8 {
        if (rate == 0) return null;
        var idx: u8 = 0;
        var r = rate;
        while (r > 1) : (idx += 1) {
            r >>= 1;
        }
        return idx;
    }

    /// Convert sample rate in Hz to rate bitmask
    pub fn fromHz(hz: u32) ?u64 {
        return switch (hz) {
            5512 => R5512,
            8000 => R8000,
            11025 => R11025,
            16000 => R16000,
            22050 => R22050,
            32000 => R32000,
            44100 => R44100,
            48000 => R48000,
            64000 => R64000,
            88200 => R88200,
            96000 => R96000,
            176400 => R176400,
            192000 => R192000,
            384000 => R384000,
            else => null,
        };
    }

    /// Convert rate bitmask to Hz
    pub fn toHz(rate: u64) ?u32 {
        return switch (rate) {
            R5512 => 5512,
            R8000 => 8000,
            R11025 => 11025,
            R16000 => 16000,
            R22050 => 22050,
            R32000 => 32000,
            R44100 => 44100,
            R48000 => 48000,
            R64000 => 64000,
            R88200 => 88200,
            R96000 => 96000,
            R176400 => 176400,
            R192000 => 192000,
            R384000 => 384000,
            else => null,
        };
    }
};

// =============================================================================
// Driver Limits
// =============================================================================

/// Driver-imposed limits
pub const Limits = struct {
    /// Maximum PCM streams we support
    pub const MAX_STREAMS: usize = 8;
    /// Maximum TX queues (playback)
    pub const MAX_TX_QUEUES: usize = 4;
    /// Maximum RX queues (capture)
    pub const MAX_RX_QUEUES: usize = 4;
    /// Maximum pending buffers per queue
    pub const MAX_PENDING_PER_QUEUE: usize = 32;
    /// Default queue size
    pub const DEFAULT_QUEUE_SIZE: u16 = 64;
    /// Audio buffer size (4KB, matches AC97)
    pub const BUFFER_SIZE: usize = 4096;
    /// Number of audio buffers for double-buffering
    pub const NUM_BUFFERS: usize = 4;
    /// Total buffer pool size
    pub const BUFFER_POOL_SIZE: usize = BUFFER_SIZE * NUM_BUFFERS;
};

// =============================================================================
// OSS Format Mapping
// =============================================================================

/// Map OSS format to VirtIO-Sound format
pub fn ossToVirtioFormat(oss_format: u32) ?u64 {
    const sound = @import("uapi").sound;
    return switch (oss_format) {
        sound.AFMT_U8 => PcmFormat.U8,
        sound.AFMT_S8 => PcmFormat.S8,
        sound.AFMT_S16_LE => PcmFormat.S16,
        sound.AFMT_U16_LE => PcmFormat.U16,
        sound.AFMT_MU_LAW => PcmFormat.MU_LAW,
        sound.AFMT_A_LAW => PcmFormat.A_LAW,
        else => null,
    };
}

/// Map VirtIO-Sound format to OSS format
pub fn virtioToOssFormat(virtio_format: u64) ?u32 {
    const sound = @import("uapi").sound;
    return switch (virtio_format) {
        PcmFormat.U8 => sound.AFMT_U8,
        PcmFormat.S8 => sound.AFMT_S8,
        PcmFormat.S16 => sound.AFMT_S16_LE,
        PcmFormat.U16 => sound.AFMT_U16_LE,
        PcmFormat.MU_LAW => sound.AFMT_MU_LAW,
        PcmFormat.A_LAW => sound.AFMT_A_LAW,
        else => null,
    };
}

// =============================================================================
// Unit Tests
// =============================================================================

test "VirtioSoundConfig size" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(VirtioSoundConfig));
}

test "PcmFormat.toIndex" {
    try std.testing.expectEqual(@as(?u8, 5), PcmFormat.toIndex(PcmFormat.S16));
    try std.testing.expectEqual(@as(?u8, 4), PcmFormat.toIndex(PcmFormat.U8));
    try std.testing.expectEqual(@as(?u8, null), PcmFormat.toIndex(0));
}

test "PcmRate.fromHz" {
    try std.testing.expectEqual(@as(?u64, PcmRate.R48000), PcmRate.fromHz(48000));
    try std.testing.expectEqual(@as(?u64, PcmRate.R44100), PcmRate.fromHz(44100));
    try std.testing.expectEqual(@as(?u64, null), PcmRate.fromHz(12345));
}

test "PcmRate.toHz" {
    try std.testing.expectEqual(@as(?u32, 48000), PcmRate.toHz(PcmRate.R48000));
    try std.testing.expectEqual(@as(?u32, 44100), PcmRate.toHz(PcmRate.R44100));
}
