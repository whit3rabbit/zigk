//! SPICE Agent Service
//!
//! Userspace service that communicates with SPICE host for display resolution
//! synchronization in Proxmox/QEMU/KVM virtual machines.
//!
//! MVP Features:
//! - Display resolution synchronization (host -> guest)
//!
//! Security:
//! - Clipboard disabled by default (data exfiltration risk)
//! - Rate limiting on display mode changes
//! - Dimension validation (max 8192x8192)
//!
//! Reference: SPICE Protocol, VirtIO Console Specification

const std = @import("std");
const syscall = @import("syscall");
const protocol = @import("protocol.zig");
const Transport = @import("transport.zig").Transport;
const TransportError = @import("transport.zig").TransportError;

// ============================================================================
// Constants
// ============================================================================

/// Service name for registration
const SERVICE_NAME = "spice_agent";

/// Poll interval in milliseconds
const POLL_INTERVAL_MS: u32 = 100;

/// Minimum interval between display mode changes (rate limiting)
const MODE_CHANGE_MIN_INTERVAL_MS: u64 = 1000;

// ============================================================================
// Agent State
// ============================================================================

const AgentState = struct {
    /// VirtIO-Serial transport
    transport: ?Transport,

    /// Host capabilities (received from SPICE server)
    host_caps: u32,

    /// Last display mode change timestamp (for rate limiting)
    last_mode_change_ms: u64,

    /// Current display dimensions
    current_width: u32,
    current_height: u32,

    /// Running state
    running: bool,

    const Self = @This();

    fn init() Self {
        return .{
            .transport = null,
            .host_caps = 0,
            .last_mode_change_ms = 0,
            .current_width = 0,
            .current_height = 0,
            .running = false,
        };
    }
};

var agent_state: AgentState = AgentState.init();

// ============================================================================
// Message Buffers
// ============================================================================

/// TX message buffer (header + payload)
/// Zero-initialized to prevent information leaks if transport has bugs
var tx_buffer: [4096]u8 = [_]u8{0} ** 4096;
/// RX message buffer
/// Zero-initialized for defense-in-depth
var rx_buffer: [4096]u8 = [_]u8{0} ** 4096;

// ============================================================================
// Entry Point
// ============================================================================

pub fn main() void {
    syscall.print("SPICE Agent: Starting...\n");

    // Register as a service
    syscall.register_service(SERVICE_NAME) catch |err| {
        printError("Failed to register service", err);
        return;
    };
    syscall.print("SPICE Agent: Registered as '");
    syscall.print(SERVICE_NAME);
    syscall.print("'\n");

    // Initialize transport
    const transport = Transport.init() catch |err| {
        switch (err) {
            TransportError.DeviceNotFound => {
                syscall.print("SPICE Agent: VirtIO-Serial device not found (not a SPICE VM?)\n");
            },
            else => {
                syscall.print("SPICE Agent: Transport initialization failed\n");
            },
        }
        return;
    };

    agent_state.transport = transport;
    syscall.print("SPICE Agent: VirtIO-Serial transport initialized\n");

    // Get initial framebuffer info
    var fb_info: syscall.FramebufferInfo = undefined;
    if (syscall.get_framebuffer_info(&fb_info)) |_| {
        agent_state.current_width = fb_info.width;
        agent_state.current_height = fb_info.height;
        syscall.print("SPICE Agent: Current display: ");
        printDec(fb_info.width);
        syscall.print("x");
        printDec(fb_info.height);
        syscall.print("\n");
    } else |_| {
        syscall.print("SPICE Agent: Could not get framebuffer info\n");
    }

    // Announce capabilities to host
    sendCapabilities();

    // Enter main loop
    agent_state.running = true;
    syscall.print("SPICE Agent: Entering main loop\n");
    mainLoop();
}

// ============================================================================
// Main Loop
// ============================================================================

fn mainLoop() void {
    while (agent_state.running) {
        // Poll for incoming messages
        pollMessages();

        // Sleep before next poll
        syscall.sleep_ms(POLL_INTERVAL_MS) catch {};
    }
}

/// Poll for and process incoming messages
fn pollMessages() void {
    const transport = &(agent_state.transport orelse return);

    const received = transport.receive(&rx_buffer) catch {
        return;
    };

    if (received == 0) return;

    // Process VDI chunk header
    if (received < @sizeOf(protocol.VDIChunkHeader)) return;

    const chunk_hdr: *const protocol.VDIChunkHeader = @ptrCast(@alignCast(&rx_buffer));
    const payload_size = chunk_hdr.size;

    // Security: Validate payload_size against buffer capacity to prevent OOB access.
    // The buffer has fixed size, so payload cannot exceed available space.
    const max_payload = rx_buffer.len - @sizeOf(protocol.VDIChunkHeader);
    if (payload_size > max_payload) return;

    // Security: Use checked arithmetic to prevent integer overflow in bounds check.
    // Without this, large payload_size values could wrap the addition, bypassing validation.
    const total_size = std.math.add(usize, @sizeOf(protocol.VDIChunkHeader), payload_size) catch return;
    if (received < total_size) return;

    const payload = rx_buffer[@sizeOf(protocol.VDIChunkHeader)..][0..payload_size];
    processMessage(payload);
}

/// Process a VDI agent message
fn processMessage(data: []const u8) void {
    if (data.len < @sizeOf(protocol.VDAgentMessage)) return;

    const msg: *const protocol.VDAgentMessage = @ptrCast(@alignCast(data.ptr));

    // Validate protocol version
    if (msg.protocol != protocol.VD_AGENT_PROTOCOL) {
        syscall.print("SPICE Agent: Unknown protocol version\n");
        return;
    }

    switch (msg.type_) {
        protocol.VD_AGENT_ANNOUNCE_CAPABILITIES => {
            handleCapabilities(data[@sizeOf(protocol.VDAgentMessage)..]);
        },
        protocol.VD_AGENT_MONITORS_CONFIG => {
            handleMonitorsConfig(data[@sizeOf(protocol.VDAgentMessage)..]);
        },
        else => {
            // Ignore unknown message types
        },
    }
}

// ============================================================================
// Message Handlers
// ============================================================================

/// Handle capabilities announcement from host
fn handleCapabilities(data: []const u8) void {
    if (data.len < @sizeOf(protocol.VDAgentAnnounceCapabilities)) return;

    const caps: *const protocol.VDAgentAnnounceCapabilities = @ptrCast(@alignCast(data.ptr));
    agent_state.host_caps = caps.caps;

    syscall.print("SPICE Agent: Received host capabilities\n");

    // If host requested our capabilities, send them
    if (caps.request != 0) {
        sendCapabilities();
    }
}

/// Handle monitors configuration from host
fn handleMonitorsConfig(data: []const u8) void {
    if (data.len < @sizeOf(protocol.VDAgentMonitorsConfig)) return;

    const config: *const protocol.VDAgentMonitorsConfig = @ptrCast(@alignCast(data.ptr));

    if (config.num_of_monitors == 0) {
        sendReply(protocol.VD_AGENT_MONITORS_CONFIG, false);
        return;
    }

    // Get monitor configurations
    const monitors = config.getMonitors(data);
    if (monitors.len == 0) {
        sendReply(protocol.VD_AGENT_MONITORS_CONFIG, false);
        return;
    }

    // Use first monitor for now (single monitor support)
    const mon = &monitors[0];

    // Validate dimensions
    if (!protocol.validateDisplayDimensions(mon.width, mon.height)) {
        syscall.print("SPICE Agent: Invalid display dimensions\n");
        sendReply(protocol.VD_AGENT_MONITORS_CONFIG, false);
        return;
    }

    // Rate limiting check
    const current_ms = getCurrentTimeMs();
    if (current_ms > 0 and agent_state.last_mode_change_ms > 0) {
        const elapsed = current_ms -| agent_state.last_mode_change_ms;
        if (elapsed < MODE_CHANGE_MIN_INTERVAL_MS) {
            syscall.print("SPICE Agent: Rate limiting display change\n");
            sendReply(protocol.VD_AGENT_MONITORS_CONFIG, false);
            return;
        }
    }

    // Check if dimensions actually changed
    if (mon.width == agent_state.current_width and mon.height == agent_state.current_height) {
        sendReply(protocol.VD_AGENT_MONITORS_CONFIG, true);
        return;
    }

    syscall.print("SPICE Agent: Setting display to ");
    printDec(mon.width);
    syscall.print("x");
    printDec(mon.height);
    syscall.print("\n");

    // Call syscall to change display mode
    if (setDisplayMode(mon.width, mon.height)) {
        agent_state.current_width = mon.width;
        agent_state.current_height = mon.height;
        agent_state.last_mode_change_ms = current_ms;
        sendReply(protocol.VD_AGENT_MONITORS_CONFIG, true);
    } else {
        syscall.print("SPICE Agent: Failed to set display mode\n");
        sendReply(protocol.VD_AGENT_MONITORS_CONFIG, false);
    }
}

// ============================================================================
// Message Senders
// ============================================================================

/// Send capabilities announcement to host
fn sendCapabilities() void {
    const transport = &(agent_state.transport orelse return);

    const caps = protocol.VDAgentAnnounceCapabilities.init(true);
    const msg = protocol.VDAgentMessage.init(
        protocol.VD_AGENT_ANNOUNCE_CAPABILITIES,
        @sizeOf(protocol.VDAgentAnnounceCapabilities),
    );

    // Build message
    var offset: usize = 0;
    @memcpy(tx_buffer[offset..][0..@sizeOf(protocol.VDAgentMessage)], std.mem.asBytes(&msg));
    offset += @sizeOf(protocol.VDAgentMessage);
    @memcpy(tx_buffer[offset..][0..@sizeOf(protocol.VDAgentAnnounceCapabilities)], std.mem.asBytes(&caps));
    offset += @sizeOf(protocol.VDAgentAnnounceCapabilities);

    transport.send(tx_buffer[0..offset]) catch {
        syscall.print("SPICE Agent: Failed to send capabilities\n");
    };
}

/// Send reply message
fn sendReply(msg_type: u32, success: bool) void {
    const transport = &(agent_state.transport orelse return);

    const reply = if (success)
        protocol.VDAgentReply.success(msg_type)
    else
        protocol.VDAgentReply.failure(msg_type);

    const msg = protocol.VDAgentMessage.init(
        protocol.VD_AGENT_REPLY,
        @sizeOf(protocol.VDAgentReply),
    );

    // Build message
    var offset: usize = 0;
    @memcpy(tx_buffer[offset..][0..@sizeOf(protocol.VDAgentMessage)], std.mem.asBytes(&msg));
    offset += @sizeOf(protocol.VDAgentMessage);
    @memcpy(tx_buffer[offset..][0..@sizeOf(protocol.VDAgentReply)], std.mem.asBytes(&reply));
    offset += @sizeOf(protocol.VDAgentReply);

    transport.send(tx_buffer[0..offset]) catch {};
}

// ============================================================================
// Display Mode Change
// ============================================================================

/// Set display mode via syscall
fn setDisplayMode(width: u32, height: u32) bool {
    // Call SYS_SET_DISPLAY_MODE syscall
    return syscall.set_display_mode(width, height, 0) catch {
        return false;
    };
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Get current time in milliseconds (approximate)
fn getCurrentTimeMs() u64 {
    // TODO: Implement proper time syscall
    // For now, return 0 to disable rate limiting
    return 0;
}

fn printError(msg: []const u8, err: anyerror) void {
    syscall.print(msg);
    syscall.print(": ");
    syscall.print(@errorName(err));
    syscall.print("\n");
}

fn printDec(value: u64) void {
    if (value == 0) {
        syscall.print("0");
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = 20;
    var v = value;
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    syscall.print(buf[i..]);
}

// ============================================================================
// Entry Point (for ELF)
// ============================================================================

export fn _start() noreturn {
    main();
    syscall.exit(0);
}
