// VirtIO-Sound Request/Response Wire Format
//
// Defines the structures used for communication over VirtIO queues.
// All structures match VirtIO Specification 1.2+ Section 5.14.6
//
// Reference: https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html

const std = @import("std");
const config = @import("config.zig");

// =============================================================================
// Control Request Header (Section 5.14.6.1)
// =============================================================================

/// Common header for all control requests
pub const CtlHdr = extern struct {
    /// Request type code (see config.ControlCode)
    code: u32 align(1),

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("CtlHdr must be 4 bytes");
    }
};

/// Common status response for control requests
pub const CtlStatus = extern struct {
    /// Status code (see config.Status)
    status: u32 align(1),

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("CtlStatus must be 4 bytes");
    }

    pub fn isOk(self: CtlStatus) bool {
        return self.status == config.Status.OK;
    }
};

// =============================================================================
// Jack Requests (Section 5.14.6.3)
// =============================================================================

/// Query jack information
pub const JackInfoRequest = extern struct {
    hdr: CtlHdr,
    /// First jack ID to query
    start_id: u32 align(1),
    /// Number of jacks to query
    count: u32 align(1),

    comptime {
        if (@sizeOf(@This()) != 12) @compileError("JackInfoRequest must be 12 bytes");
    }
};

/// Jack information response (per jack)
pub const JackInfo = extern struct {
    /// Header field
    hdr_pad: u32 align(1),
    /// Connected device features
    features: u32 align(1),
    /// HDA pin configuration default
    hda_reg_defconf: u32 align(1),
    /// HDA pin capabilities
    hda_reg_caps: u32 align(1),
    /// Current connection status (1 = connected)
    connected: u8,
    /// Padding
    _padding: [7]u8,

    comptime {
        if (@sizeOf(@This()) != 24) @compileError("JackInfo must be 24 bytes");
    }
};

// =============================================================================
// PCM Requests (Section 5.14.6.6)
// =============================================================================

/// Query PCM stream information
pub const PcmInfoRequest = extern struct {
    hdr: CtlHdr,
    /// First stream ID to query
    start_id: u32 align(1),
    /// Number of streams to query
    count: u32 align(1),

    comptime {
        if (@sizeOf(@This()) != 12) @compileError("PcmInfoRequest must be 12 bytes");
    }
};

/// PCM stream information response (per stream)
pub const PcmInfo = extern struct {
    /// Header pad (direction flags in older versions)
    hdr_pad: u32 align(1),
    /// Stream features (reserved, must be 0)
    features: u32 align(1),
    /// Supported formats bitmask (see config.PcmFormat)
    formats: u64 align(1),
    /// Supported sample rates bitmask (see config.PcmRate)
    rates: u64 align(1),
    /// Stream direction (0 = output, 1 = input)
    direction: u8,
    /// Minimum number of channels
    channels_min: u8,
    /// Maximum number of channels
    channels_max: u8,
    /// Padding
    _padding: [5]u8,

    comptime {
        if (@sizeOf(@This()) != 32) @compileError("PcmInfo must be 32 bytes");
    }

    pub fn isOutput(self: PcmInfo) bool {
        return self.direction == config.StreamDirection.OUTPUT;
    }

    pub fn isInput(self: PcmInfo) bool {
        return self.direction == config.StreamDirection.INPUT;
    }

    pub fn supportsFormat(self: PcmInfo, format: u64) bool {
        return (self.formats & format) != 0;
    }

    pub fn supportsRate(self: PcmInfo, rate: u64) bool {
        return (self.rates & rate) != 0;
    }
};

/// PCM set parameters request
pub const PcmSetParams = extern struct {
    hdr: CtlHdr,
    /// Stream ID to operate on
    stream_id: u32 align(1),
    /// Total buffer size in bytes
    buffer_bytes: u32 align(1),
    /// Period size in bytes (interrupt interval)
    period_bytes: u32 align(1),
    /// Stream features (reserved)
    features: u32 align(1),
    /// Number of channels (1 = mono, 2 = stereo, etc.)
    channels: u8,
    /// Format index (log2 of format bitmask)
    format: u8,
    /// Rate index (log2 of rate bitmask)
    rate: u8,
    /// Padding
    _padding: u8,

    comptime {
        if (@sizeOf(@This()) != 24) @compileError("PcmSetParams must be 24 bytes");
    }

    /// Create a PcmSetParams for common configurations
    pub fn init(
        stream_id: u32,
        channels: u8,
        format: u64,
        rate: u64,
        buffer_bytes: u32,
        period_bytes: u32,
    ) ?PcmSetParams {
        const format_idx = config.PcmFormat.toIndex(format) orelse return null;
        const rate_idx = config.PcmRate.toIndex(rate) orelse return null;

        return PcmSetParams{
            .hdr = .{ .code = config.ControlCode.PCM_SET_PARAMS },
            .stream_id = stream_id,
            .buffer_bytes = buffer_bytes,
            .period_bytes = period_bytes,
            .features = 0,
            .channels = channels,
            .format = format_idx,
            .rate = rate_idx,
            ._padding = 0,
        };
    }
};

/// Generic PCM control request (PREPARE, RELEASE, START, STOP)
pub const PcmRequest = extern struct {
    hdr: CtlHdr,
    /// Stream ID to operate on
    stream_id: u32 align(1),

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("PcmRequest must be 8 bytes");
    }

    pub fn prepare(stream_id: u32) PcmRequest {
        return .{
            .hdr = .{ .code = config.ControlCode.PCM_PREPARE },
            .stream_id = stream_id,
        };
    }

    pub fn release(stream_id: u32) PcmRequest {
        return .{
            .hdr = .{ .code = config.ControlCode.PCM_RELEASE },
            .stream_id = stream_id,
        };
    }

    pub fn start(stream_id: u32) PcmRequest {
        return .{
            .hdr = .{ .code = config.ControlCode.PCM_START },
            .stream_id = stream_id,
        };
    }

    pub fn stop(stream_id: u32) PcmRequest {
        return .{
            .hdr = .{ .code = config.ControlCode.PCM_STOP },
            .stream_id = stream_id,
        };
    }
};

// =============================================================================
// PCM Data Transfer (Section 5.14.6.8)
// =============================================================================

/// PCM transfer header (prepended to audio data)
pub const PcmXferHdr = extern struct {
    /// Stream ID for this transfer
    stream_id: u32 align(1),

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("PcmXferHdr must be 4 bytes");
    }
};

/// PCM transfer status (appended after audio data in response)
pub const PcmXferStatus = extern struct {
    /// Transfer status (see config.Status)
    status: u32 align(1),
    /// Latency in bytes (how much data is buffered)
    latency_bytes: u32 align(1),

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("PcmXferStatus must be 8 bytes");
    }

    pub fn isOk(self: PcmXferStatus) bool {
        return self.status == config.Status.OK;
    }
};

// =============================================================================
// Channel Map Requests (Section 5.14.6.9)
// =============================================================================

/// Query channel map information
pub const ChmapInfoRequest = extern struct {
    hdr: CtlHdr,
    /// First channel map ID to query
    start_id: u32 align(1),
    /// Number of channel maps to query
    count: u32 align(1),

    comptime {
        if (@sizeOf(@This()) != 12) @compileError("ChmapInfoRequest must be 12 bytes");
    }
};

/// Channel map information response
pub const ChmapInfo = extern struct {
    /// Header pad
    hdr_pad: u32 align(1),
    /// Stream direction
    direction: u8,
    /// Number of channels in map
    channels: u8,
    /// Padding
    _padding: [2]u8,
    /// Channel positions (up to 18 channels supported)
    positions: [18]u8,

    comptime {
        if (@sizeOf(@This()) != 26) @compileError("ChmapInfo must be 26 bytes");
    }
};

/// Channel position constants
pub const ChmapPosition = struct {
    pub const NONE: u8 = 0;
    pub const NA: u8 = 1;
    pub const MONO: u8 = 2;
    pub const FL: u8 = 3; // Front Left
    pub const FR: u8 = 4; // Front Right
    pub const RL: u8 = 5; // Rear Left
    pub const RR: u8 = 6; // Rear Right
    pub const FC: u8 = 7; // Front Center
    pub const LFE: u8 = 8; // Low Frequency Effects
    pub const SL: u8 = 9; // Side Left
    pub const SR: u8 = 10; // Side Right
    pub const RC: u8 = 11; // Rear Center
    pub const FLC: u8 = 12; // Front Left Center
    pub const FRC: u8 = 13; // Front Right Center
    pub const RLC: u8 = 14; // Rear Left Center
    pub const RRC: u8 = 15; // Rear Right Center
    pub const FLW: u8 = 16; // Front Left Wide
    pub const FRW: u8 = 17; // Front Right Wide
    pub const FLH: u8 = 18; // Front Left High
    pub const FCH: u8 = 19; // Front Center High
    pub const FRH: u8 = 20; // Front Right High
    pub const TC: u8 = 21; // Top Center
    pub const TFL: u8 = 22; // Top Front Left
    pub const TFR: u8 = 23; // Top Front Right
    pub const TFC: u8 = 24; // Top Front Center
    pub const TRL: u8 = 25; // Top Rear Left
    pub const TRR: u8 = 26; // Top Rear Right
    pub const TRC: u8 = 27; // Top Rear Center
};

// =============================================================================
// Event Notification (Section 5.14.6.10)
// =============================================================================

/// Event types for event virtqueue
pub const EventType = struct {
    /// PCM period elapsed
    pub const PCM_PERIOD_ELAPSED: u32 = 0x0100;
    /// PCM stream stopped due to underflow
    pub const PCM_XRUN: u32 = 0x0101;
    /// Jack connection status changed
    pub const JACK_CONNECTED: u32 = 0x0001;
    /// Jack disconnected
    pub const JACK_DISCONNECTED: u32 = 0x0002;
};

/// Event notification from device
pub const Event = extern struct {
    /// Event type
    event_type: u32 align(1),
    /// Resource ID (stream or jack ID)
    resource_id: u32 align(1),

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("Event must be 8 bytes");
    }
};

// =============================================================================
// Unit Tests
// =============================================================================

test "CtlHdr size" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(CtlHdr));
}

test "CtlStatus size" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(CtlStatus));
}

test "PcmInfo size" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(PcmInfo));
}

test "PcmSetParams size" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(PcmSetParams));
}

test "PcmXferHdr size" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(PcmXferHdr));
}

test "PcmXferStatus size" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(PcmXferStatus));
}

test "Event size" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Event));
}

test "PcmSetParams.init" {
    const params = PcmSetParams.init(
        0,
        2,
        config.PcmFormat.S16,
        config.PcmRate.R48000,
        16384,
        4096,
    );
    try std.testing.expect(params != null);
    try std.testing.expectEqual(@as(u8, 2), params.?.channels);
    try std.testing.expectEqual(@as(u8, 5), params.?.format); // S16 is bit 5
    try std.testing.expectEqual(@as(u8, 7), params.?.rate); // 48000 is bit 7
}
