//! VMware SVGA II Capability Parsing
//!
//! Parses the CAPABILITIES register to determine available hardware features.
//! Feature gates allow safe fallback when capabilities are not present.

const std = @import("std");

/// SVGA Capability bits from the CAPABILITIES register (reg 17)
/// Based on VMware SVGA specification
pub const Capabilities = packed struct(u32) {
    /// SVGA_CAP_RECT_COPY - Hardware rectangle copy support
    rect_copy: bool,
    /// SVGA_CAP_CURSOR - Basic hardware cursor support
    cursor: bool,
    /// SVGA_CAP_CURSOR_BYPASS - Cursor bypass mode
    cursor_bypass: bool,
    /// SVGA_CAP_CURSOR_BYPASS_2 - Enhanced cursor bypass
    cursor_bypass_2: bool,
    /// SVGA_CAP_8BIT_EMULATION - 8-bit emulation support
    emulation_8bit: bool,
    /// SVGA_CAP_ALPHA_BLEND - Alpha blending support
    alpha_blend: bool,
    /// SVGA_CAP_3D - SVGA3D command support (deprecated, use svga3d)
    legacy_3d: bool,
    /// SVGA_CAP_EXTENDED_FIFO - Extended FIFO registers
    extended_fifo: bool,
    /// SVGA_CAP_MULTIMON - Multiple monitor support
    multimon: bool,
    /// SVGA_CAP_PITCHLOCK - Pitch lock capability
    pitchlock: bool,
    /// SVGA_CAP_IRQMASK - IRQ mask support
    irqmask: bool,
    /// SVGA_CAP_DISPLAY_TOPOLOGY - Display topology support
    display_topology: bool,
    /// SVGA_CAP_GMR - Guest Memory Region support
    gmr: bool,
    /// SVGA_CAP_TRACES - Trace support
    traces: bool,
    /// SVGA_CAP_GMR2 - GMR2 support
    gmr2: bool,
    /// SVGA_CAP_SCREEN_OBJECT_2 - Screen object v2 support
    screen_object_2: bool,
    /// SVGA_CAP_COMMAND_BUFFERS - Command buffer support
    command_buffers: bool,
    /// SVGA_CAP_DEAD1 - Dead capability
    dead1: bool,
    /// SVGA_CAP_CMD_BUFFERS_2 - Command buffers v2
    cmd_buffers_2: bool,
    /// SVGA_CAP_GBOBJECTS - Guest-backed objects
    gbobjects: bool,
    /// SVGA_CAP_DX - DirectX 10/11 support
    dx: bool,
    /// SVGA_CAP_HP_CMD_QUEUE - High priority command queue
    hp_cmd_queue: bool,
    /// SVGA_CAP_NO_BB_RESTRICTION - No bounding box restriction
    no_bb_restriction: bool,
    /// SVGA_CAP_CAP2_REGISTER - CAP2 register available
    cap2_register: bool,
    /// SVGA_CAP_ALPHA_CURSOR - ARGB alpha cursor support
    alpha_cursor: bool,
    /// Reserved bits
    _reserved: u7,

    /// Check if SVGA3D is available (either legacy or modern)
    pub fn hasSvga3d(self: Capabilities) bool {
        return self.legacy_3d or self.gbobjects or self.dx;
    }

    /// Check if hardware cursor is available
    pub fn hasHardwareCursor(self: Capabilities) bool {
        return self.cursor;
    }

    /// Check if alpha cursor (ARGB) is available
    pub fn hasAlphaCursor(self: Capabilities) bool {
        return self.alpha_cursor;
    }

    /// Check if hardware rectangle copy is available
    pub fn hasRectCopy(self: Capabilities) bool {
        return self.rect_copy;
    }

    /// Check if extended FIFO features are available
    pub fn hasExtendedFifo(self: Capabilities) bool {
        return self.extended_fifo;
    }

    /// Check if IRQ support is available
    pub fn hasIrqSupport(self: Capabilities) bool {
        return self.irqmask;
    }

    /// Check if Guest Memory Regions are available
    pub fn hasGmr(self: Capabilities) bool {
        return self.gmr or self.gmr2;
    }

    /// Check if screen objects are available
    pub fn hasScreenObjects(self: Capabilities) bool {
        return self.screen_object_2;
    }
};

/// Extended FIFO capabilities (from FIFO register space)
pub const FifoCapabilities = packed struct(u32) {
    /// SVGA_FIFO_CAP_FENCE - Fence synchronization
    fence: bool,
    /// SVGA_FIFO_CAP_ACCELFRONT - Accelerated front buffer
    accelfront: bool,
    /// SVGA_FIFO_CAP_PITCHLOCK - Pitch lock in FIFO
    pitchlock: bool,
    /// SVGA_FIFO_CAP_VIDEO - Video overlay support
    video: bool,
    /// SVGA_FIFO_CAP_CURSOR_BYPASS_3 - Cursor bypass v3
    cursor_bypass_3: bool,
    /// SVGA_FIFO_CAP_ESCAPE - Escape command support
    escape: bool,
    /// SVGA_FIFO_CAP_RESERVE - Reserve command support
    reserve: bool,
    /// SVGA_FIFO_CAP_SCREEN_OBJECT - Screen object support
    screen_object: bool,
    /// SVGA_FIFO_CAP_GMR2 - GMR2 support
    gmr2: bool,
    /// SVGA_FIFO_CAP_3D_HWVERSION_REVISED - Revised 3D hardware version
    hwversion_revised_3d: bool,
    /// SVGA_FIFO_CAP_SCREEN_OBJECT_2 - Screen object v2
    screen_object_2: bool,
    /// SVGA_FIFO_CAP_DEAD - Dead capability
    dead: bool,
    /// Reserved bits
    _reserved: u20,
};

/// Parse raw capability register value into structured form
pub fn parseCapabilities(raw: u32) Capabilities {
    return @bitCast(raw);
}

/// Parse raw FIFO capability value into structured form
pub fn parseFifoCapabilities(raw: u32) FifoCapabilities {
    return @bitCast(raw);
}

/// SVGA3D Hardware Version information
pub const Svga3dHwVersion = struct {
    major: u16,
    minor: u16,

    pub fn fromRaw(raw: u32) Svga3dHwVersion {
        return .{
            .major = @truncate(raw >> 16),
            .minor = @truncate(raw & 0xFFFF),
        };
    }

    /// Check if version meets minimum requirements
    pub fn meetsMinimum(self: Svga3dHwVersion, min_major: u16, min_minor: u16) bool {
        if (self.major > min_major) return true;
        if (self.major == min_major and self.minor >= min_minor) return true;
        return false;
    }
};

/// Capability summary for logging
pub fn logCapabilities(caps: Capabilities) void {
    const console = @import("console");
    console.info("SVGA Capabilities:", .{});
    if (caps.rect_copy) console.info("  - RectCopy", .{});
    if (caps.cursor) console.info("  - Cursor", .{});
    if (caps.alpha_cursor) console.info("  - Alpha Cursor", .{});
    if (caps.extended_fifo) console.info("  - Extended FIFO", .{});
    if (caps.irqmask) console.info("  - IRQ Support", .{});
    if (caps.hasSvga3d()) console.info("  - SVGA3D", .{});
    if (caps.gmr) console.info("  - GMR", .{});
    if (caps.gmr2) console.info("  - GMR2", .{});
    if (caps.screen_object_2) console.info("  - Screen Objects", .{});
    if (caps.multimon) console.info("  - Multi-Monitor", .{});
}

// Unit tests
test "capability parsing" {
    // Test with known capability value
    const raw: u32 = 0x01000003; // rect_copy + cursor + alpha_cursor
    const caps = parseCapabilities(raw);

    try std.testing.expect(caps.rect_copy);
    try std.testing.expect(caps.cursor);
    try std.testing.expect(caps.hasAlphaCursor());
    try std.testing.expect(!caps.legacy_3d);
}

test "svga3d version parsing" {
    const raw: u32 = 0x00020005; // Major 2, Minor 5
    const ver = Svga3dHwVersion.fromRaw(raw);

    try std.testing.expectEqual(@as(u16, 2), ver.major);
    try std.testing.expectEqual(@as(u16, 5), ver.minor);
    try std.testing.expect(ver.meetsMinimum(2, 0));
    try std.testing.expect(!ver.meetsMinimum(3, 0));
}
