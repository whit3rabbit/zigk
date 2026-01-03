//! VMMouse Driver (Absolute Positioning)
//!
//! Uses the VMware hypercall interface to retrieve absolute cursor coordinates.
//! This is supported by VMware Workstation, Fusion, ESXi, and VirtualBox.
//!
//! Protocol:
//! 1. Detect hypercall interface.
//! 2. Enable VMMouse command (0x45414552).
//! 3. Poll for data packets containing X, Y, Z, and Buttons.

const std = @import("std");
const hal = @import("hal");
const vmware = hal.vmware;
const mouse = @import("mouse");

// Magic constants
const VMMOUSE_CMD_READ_ID = 0x45414552; // "REA" (Read / Enable)
const VMMOUSE_CMD_DISABLE = 0x000000f5;
const VMMOUSE_CMD_REQUEST_RELATIVE = 0x4c455252; // "REL"
const VMMOUSE_CMD_REQUEST_ABSOLUTE = 0x53424152; // "ABS"

const VMMOUSE_DATA = 39;
const VMMOUSE_STATUS = 40;
const VMMOUSE_COMMAND = 41;

// Packet format
const VMMOUSE_LEFT_BUTTON = 0x20;
const VMMOUSE_RIGHT_BUTTON = 0x10;
const VMMOUSE_MIDDLE_BUTTON = 0x08;

/// Cursor position callback type for hardware cursor integration
pub const CursorPositionCallback = *const fn (x: u32, y: u32) void;

/// Global cursor position callback (for SVGA hardware cursor integration)
var cursor_callback: ?CursorPositionCallback = null;

/// Register a callback for cursor position updates
/// This is used by the SVGA driver to update hardware cursor position
pub fn registerCursorCallback(callback: CursorPositionCallback) void {
    cursor_callback = callback;
}

/// Unregister cursor callback
pub fn unregisterCursorCallback() void {
    cursor_callback = null;
}

pub const VmMouseDriver = struct {
    enabled: bool = false,

    // Limits (VMware absolute coordinate range)
    max_x: u32 = 65535,
    max_y: u32 = 65535,

    // Screen dimensions for scaling (set by SVGA driver)
    screen_width: u32 = 0,
    screen_height: u32 = 0,

    const Self = @This();

    pub fn init() Self {
        return Self{};
    }

    /// Set screen dimensions for coordinate scaling
    /// Called by init_hw when SVGA driver sets mode
    pub fn setScreenSize(self: *Self, width: u32, height: u32) void {
        self.screen_width = width;
        self.screen_height = height;
    }

    /// Try to enable the VMMouse
    pub fn probe(self: *Self) bool {
        if (!vmware.detect()) return false;

        // Enable VMMouse
        var regs = vmware.Registers{
            .eax = vmware.HYPERCALL_MAGIC,
            .ebx = VMMOUSE_CMD_READ_ID,
            .ecx = 0, // 0 for ID / Enable
            .edx = vmware.HYPERCALL_PORT,
            .esi = 0,
            .edi = 0,
        };
        // Command 41 is generic VMMOUSE_COMMAND
        regs.ebx = VMMOUSE_CMD_READ_ID;
        // Logic: Set EBX to command, ECX to data?
        // Actually, for VMMouse via Backdoor:
        // EAX = 0x564D5868 (Magic)
        // EBX = VMMOUSE_DATA (39) or CMD (41) etc.
        // But the "Enable" sequence is:
        // EAX = Magic
        // EBX = VMMOUSE_COMMAND (41)
        // ECX = VMMOUSE_CMD_READ_ID
        // EDX = Port

        // Correct sequence correction:
        regs.ebx = VMMOUSE_COMMAND;
        regs.ecx = VMMOUSE_CMD_READ_ID;
        vmware.call(&regs);

        // If successful, EAX returns version ID (usually 0x3442554A "JUB4" or similar)
        // And EBX returns 0x4B48584D "MXHK" ?
        // Or simply checking if keys are accepted.

        if (regs.eax == 0xFFFFFFFF) return false; // Failure convention

        self.enabled = true;

        // Disable relative, enable absolute
        self.sendCommand(VMMOUSE_CMD_REQUEST_ABSOLUTE);

        return true;
    }

    fn sendCommand(self: *Self, cmd: u32) void {
        _ = self;
        var regs = vmware.Registers{
            .eax = vmware.HYPERCALL_MAGIC,
            .ebx = VMMOUSE_COMMAND,
            .ecx = cmd,
            .edx = vmware.HYPERCALL_PORT,
        };
        vmware.call(&regs);
    }

    /// Poll for events
    /// Should be called from timer interrupt or input polling loop
    pub fn poll(self: *Self) void {
        if (!self.enabled) return;

        // Check status
        var regs = vmware.Registers{
            .eax = vmware.HYPERCALL_MAGIC,
            .ebx = VMMOUSE_STATUS,
            .ecx = 0,
            .edx = vmware.HYPERCALL_PORT,
        };
        vmware.call(&regs);

        // EAX contains number of words available. Minimum packet is 4 words.
        // 0xFFFF0000 mask checks for error?
        // Lower 16 bits is count.
        var count = regs.eax & 0xFFFF;
        if (count == 0 or count == 0xFFFF) return;

        // Consume packets (4 words each)
        // Packet: Status, X, Y, Z
        while (count >= 4) {
            count -= 4;

            // Get 4 words
            var packet: [4]u32 = .{ 0, 0, 0, 0 };
            for (0..4) |i| {
                regs.eax = vmware.HYPERCALL_MAGIC;
                regs.ebx = VMMOUSE_DATA;
                regs.ecx = 0;
                regs.edx = vmware.HYPERCALL_PORT;
                vmware.call(&regs);
                packet[i] = regs.eax;
            }

            const flags = packet[0];
            const x = packet[1];
            const y = packet[2];
            const z = packet[3];

            _ = z; // Scroll wheel (TODO: handle scroll events)

            const buttons = mouse.Buttons{
                .left = (flags & VMMOUSE_LEFT_BUTTON) != 0,
                .right = (flags & VMMOUSE_RIGHT_BUTTON) != 0,
                .middle = (flags & VMMOUSE_MIDDLE_BUTTON) != 0,
            };

            // Notify hardware cursor callback if registered
            // Scale VMware coordinates (0-65535) to screen coordinates
            if (cursor_callback) |cb| {
                if (self.screen_width > 0 and self.screen_height > 0) {
                    // Scale with overflow-safe arithmetic
                    const scaled_x = std.math.mul(u64, x, self.screen_width) catch 0;
                    const scaled_y = std.math.mul(u64, y, self.screen_height) catch 0;
                    const screen_x: u32 = @intCast(scaled_x / self.max_x);
                    const screen_y: u32 = @intCast(scaled_y / self.max_y);
                    cb(screen_x, screen_y);
                }
            }

            // Inject absolute input to mouse subsystem
            mouse.injectAbsoluteInput(
                0xFFFF, // Virtual device ID
                x,
                y,
                self.max_x,
                self.max_y,
                buttons,
            );
        }
    }
};
