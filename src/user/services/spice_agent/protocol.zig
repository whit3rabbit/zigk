//! SPICE VDI Agent Protocol Definitions
//!
//! Implements the VDI (Virtual Desktop Infrastructure) agent protocol
//! as used by SPICE for host-guest communication.
//!
//! Reference: SPICE Protocol 0.12+, spice-protocol/spice/vd_agent.h

const std = @import("std");

/// VDI Agent Protocol version
pub const VD_AGENT_PROTOCOL: u32 = 1;

// ============================================================================
// VDI Agent Message Types
// ============================================================================

/// Mouse state message
pub const VD_AGENT_MOUSE_STATE: u32 = 1;
/// Monitor configuration (host -> guest)
pub const VD_AGENT_MONITORS_CONFIG: u32 = 2;
/// Reply message
pub const VD_AGENT_REPLY: u32 = 3;
/// Clipboard data
pub const VD_AGENT_CLIPBOARD: u32 = 4;
/// Display configuration (guest -> host)
pub const VD_AGENT_DISPLAY_CONFIG: u32 = 5;
/// Announce capabilities (bidirectional)
pub const VD_AGENT_ANNOUNCE_CAPABILITIES: u32 = 6;
/// Clipboard grab
pub const VD_AGENT_CLIPBOARD_GRAB: u32 = 7;
/// Clipboard request
pub const VD_AGENT_CLIPBOARD_REQUEST: u32 = 8;
/// Clipboard release
pub const VD_AGENT_CLIPBOARD_RELEASE: u32 = 9;
/// File transfer start
pub const VD_AGENT_FILE_XFER_START: u32 = 10;
/// File transfer status
pub const VD_AGENT_FILE_XFER_STATUS: u32 = 11;
/// File transfer data
pub const VD_AGENT_FILE_XFER_DATA: u32 = 12;
/// Max clipboard size
pub const VD_AGENT_MAX_CLIPBOARD: u32 = 14;
/// Audio volume sync
pub const VD_AGENT_AUDIO_VOLUME_SYNC: u32 = 15;

// ============================================================================
// VDI Agent Capability Bits
// ============================================================================

/// Guest can handle mouse state messages
pub const VD_AGENT_CAP_MOUSE_STATE: u32 = 0;
/// Guest can handle monitor config messages
pub const VD_AGENT_CAP_MONITORS_CONFIG: u32 = 1;
/// Guest can handle reply messages
pub const VD_AGENT_CAP_REPLY: u32 = 2;
/// Guest supports clipboard
pub const VD_AGENT_CAP_CLIPBOARD: u32 = 3;
/// Guest supports display config
pub const VD_AGENT_CAP_DISPLAY_CONFIG: u32 = 4;
/// Guest can handle clipboard selection
pub const VD_AGENT_CAP_CLIPBOARD_BY_DEMAND: u32 = 5;
/// Guest supports clipboard grab
pub const VD_AGENT_CAP_CLIPBOARD_SELECTION: u32 = 6;
/// Sparse monitors config support
pub const VD_AGENT_CAP_SPARSE_MONITORS_CONFIG: u32 = 7;
/// Guest side disconnect support
pub const VD_AGENT_CAP_GUEST_LINEEND_LF: u32 = 8;
/// Guest can handle max clipboard size
pub const VD_AGENT_CAP_MAX_CLIPBOARD: u32 = 9;
/// Audio volume sync support
pub const VD_AGENT_CAP_AUDIO_VOLUME_SYNC: u32 = 10;
/// Guest supports position configuration
pub const VD_AGENT_CAP_MONITORS_CONFIG_POSITION: u32 = 11;

// ============================================================================
// VDI Chunk Header (VirtIO-serial layer)
// ============================================================================

/// VDI chunk header - wraps agent messages over virtio-serial
/// Total: 8 bytes
pub const VDIChunkHeader = extern struct {
    /// Destination port (usually 1 for vdagent)
    port: u32 align(1),
    /// Size of the payload following this header
    size: u32 align(1),

    pub fn init(payload_size: u32) VDIChunkHeader {
        return .{
            .port = 1, // VDAgent port
            .size = payload_size,
        };
    }
};

comptime {
    if (@sizeOf(VDIChunkHeader) != 8) @compileError("VDIChunkHeader must be 8 bytes");
}

// ============================================================================
// VDI Agent Message Header
// ============================================================================

/// VDI agent message header
/// Total: 20 bytes (but often padded to 24)
pub const VDAgentMessage = extern struct {
    /// Protocol version (always VD_AGENT_PROTOCOL = 1)
    protocol: u32 align(1),
    /// Message type (VD_AGENT_* constants)
    type_: u32 align(1),
    /// Opaque data passed back in reply (usually 0)
    opaque_data: u64 align(1),
    /// Size of message payload (not including this header)
    size: u32 align(1),

    pub fn init(msg_type: u32, payload_size: u32) VDAgentMessage {
        return .{
            .protocol = VD_AGENT_PROTOCOL,
            .type_ = msg_type,
            .opaque_data = 0,
            .size = payload_size,
        };
    }
};

comptime {
    if (@sizeOf(VDAgentMessage) != 20) @compileError("VDAgentMessage must be 20 bytes");
}

// ============================================================================
// Announce Capabilities Message
// ============================================================================

/// Capabilities announcement message payload
pub const VDAgentAnnounceCapabilities = extern struct {
    /// Request capabilities from other side (1 = yes)
    request: u32 align(1),
    /// Capability bitmap (variable length, but we use 1 u32)
    caps: u32 align(1),

    /// Create capabilities message with our supported features
    pub fn init(request_caps: bool) VDAgentAnnounceCapabilities {
        // SECURITY: Only advertise monitor config capability
        // Clipboard is disabled by default for security reasons
        var caps: u32 = 0;
        caps |= (1 << VD_AGENT_CAP_MONITORS_CONFIG);
        caps |= (1 << VD_AGENT_CAP_REPLY);
        caps |= (1 << VD_AGENT_CAP_SPARSE_MONITORS_CONFIG);
        caps |= (1 << VD_AGENT_CAP_MONITORS_CONFIG_POSITION);

        return .{
            .request = if (request_caps) 1 else 0,
            .caps = caps,
        };
    }

    /// Check if a capability is set
    pub fn hasCapability(self: *const VDAgentAnnounceCapabilities, cap: u32) bool {
        return (self.caps & (1 << cap)) != 0;
    }
};

comptime {
    if (@sizeOf(VDAgentAnnounceCapabilities) != 8) @compileError("VDAgentAnnounceCapabilities must be 8 bytes");
}

// ============================================================================
// Monitors Config Message
// ============================================================================

/// Maximum number of monitors supported
pub const VD_AGENT_MAX_MONITORS: usize = 16;

/// Monitor configuration for a single display
pub const VDAgentMonConfig = extern struct {
    /// Monitor height in pixels
    height: u32 align(1),
    /// Monitor width in pixels
    width: u32 align(1),
    /// Monitor depth (bits per pixel)
    depth: u32 align(1),
    /// X position (for multi-monitor)
    x: i32 align(1),
    /// Y position (for multi-monitor)
    y: i32 align(1),
};

comptime {
    if (@sizeOf(VDAgentMonConfig) != 20) @compileError("VDAgentMonConfig must be 20 bytes");
}

/// Monitors configuration message payload
pub const VDAgentMonitorsConfig = extern struct {
    /// Number of monitors in this config
    num_of_monitors: u32 align(1),
    /// Flags (reserved, usually 0)
    flags: u32 align(1),
    // Followed by num_of_monitors VDAgentMonConfig structs

    /// Get the monitor configs following this header
    pub fn getMonitors(self: *const VDAgentMonitorsConfig, data: []const u8) []const VDAgentMonConfig {
        const header_size = @sizeOf(VDAgentMonitorsConfig);
        if (data.len < header_size) return &[_]VDAgentMonConfig{};

        const remaining = data[header_size..];
        // num is capped at VD_AGENT_MAX_MONITORS (16), VDAgentMonConfig is 20 bytes.
        // Maximum value: 16 * 20 = 320, which cannot overflow on any platform.
        const num = @min(self.num_of_monitors, VD_AGENT_MAX_MONITORS);
        const expected_size = num * @sizeOf(VDAgentMonConfig);

        if (remaining.len < expected_size) return &[_]VDAgentMonConfig{};

        const monitors_ptr: [*]const VDAgentMonConfig = @ptrCast(@alignCast(remaining.ptr));
        return monitors_ptr[0..num];
    }
};

comptime {
    if (@sizeOf(VDAgentMonitorsConfig) != 8) @compileError("VDAgentMonitorsConfig must be 8 bytes");
}

// ============================================================================
// Reply Message
// ============================================================================

/// Reply message (sent in response to host messages)
pub const VDAgentReply = extern struct {
    /// Type of message being replied to
    type_: u32 align(1),
    /// Error code (0 = success)
    error_code: u32 align(1),

    pub const VD_AGENT_SUCCESS: u32 = 0;
    pub const VD_AGENT_ERROR: u32 = 1;

    pub fn success(msg_type: u32) VDAgentReply {
        return .{
            .type_ = msg_type,
            .error_code = VD_AGENT_SUCCESS,
        };
    }

    pub fn failure(msg_type: u32) VDAgentReply {
        return .{
            .type_ = msg_type,
            .error_code = VD_AGENT_ERROR,
        };
    }
};

comptime {
    if (@sizeOf(VDAgentReply) != 8) @compileError("VDAgentReply must be 8 bytes");
}

// ============================================================================
// Display Resolution Limits
// ============================================================================

/// Maximum display width (8K)
pub const MAX_DISPLAY_WIDTH: u32 = 8192;
/// Maximum display height (8K)
pub const MAX_DISPLAY_HEIGHT: u32 = 8192;
/// Minimum display width
pub const MIN_DISPLAY_WIDTH: u32 = 640;
/// Minimum display height
pub const MIN_DISPLAY_HEIGHT: u32 = 480;

/// Validate display dimensions
pub fn validateDisplayDimensions(width: u32, height: u32) bool {
    if (width < MIN_DISPLAY_WIDTH or width > MAX_DISPLAY_WIDTH) return false;
    if (height < MIN_DISPLAY_HEIGHT or height > MAX_DISPLAY_HEIGHT) return false;
    return true;
}
