// HID Driver Struct and Lifecycle
//
// Manages the state of an HID device and dispatches HID reports to specific handlers.

const std = @import("std");
const console = @import("console");
const mouse = @import("mouse");
const types = @import("types.zig");
const descriptor = @import("descriptor.zig");
const input = @import("input.zig");

pub const HidDriver = struct {
    is_keyboard: bool = false,
    is_mouse: bool = false,
    is_tablet: bool = false,
    input_device_id: u16 = 0,
    interface_num: u8 = 0,
    in_endpoint: u8 = 0,
    out_endpoint: ?u8 = null,
    packet_size: u16 = 0,

    // Parsed report descriptor data
    input_report: descriptor.HidReport = .{},
    capabilities: descriptor.DeviceCapabilities = .{},
    uses_report_id: bool = false,

    // Keyboard state
    prev_modifiers: u8 = 0,
    prev_keys: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },

    const Self = @This();

    /// Parse HID report descriptor using the modular parser
    pub fn parseReportDescriptor(self: *Self, data: []const u8) !void {
        const parser = descriptor.Parser{
            .is_keyboard = &self.is_keyboard,
            .is_mouse = &self.is_mouse,
            .is_tablet = &self.is_tablet,
            .input_report = &self.input_report,
            .capabilities = &self.capabilities,
            .uses_report_id = &self.uses_report_id,
        };
        try parser.parse(data);
    }

    /// Handle an incoming input report
    /// Routes to appropriate handler based on device type
    pub fn handleInputReport(self: *Self, data: []const u8) void {
        const report_data = if (self.uses_report_id and data.len > 0)
            data[1..]
        else
            data;

        if (self.is_keyboard) {
            self.handleKeyboardReport(report_data);
        } else if (self.is_tablet) {
            self.handleTabletReport(report_data);
        } else if (self.is_mouse) {
            self.handleMouseReport(report_data);
        }
    }

    /// Handle tablet/touchscreen report with absolute positioning
    fn handleTabletReport(self: *Self, data: []const u8) void {
        const x_usage = descriptor.makeUsage(types.UsagePage.GENERIC_DESKTOP, types.UsageGeneric.X);
        const y_usage = descriptor.makeUsage(types.UsagePage.GENERIC_DESKTOP, types.UsageGeneric.Y);
        const tip_switch_usage = descriptor.makeUsage(types.UsagePage.DIGITIZER, types.UsageDigitizer.TIP_SWITCH);

        var x_val: ?i32 = null;
        var y_val: ?i32 = null;
        var tip_pressed = false;
        var buttons_raw: u8 = 0;

        for (self.input_report.fields[0..self.input_report.field_count]) |*field| {
            const val = input.extractFieldValue(data, field);

            if (field.usage == x_usage) {
                x_val = val;
            } else if (field.usage == y_usage) {
                y_val = val;
            } else if (field.usage == tip_switch_usage) {
                tip_pressed = val != 0;
            } else if ((field.usage >> 16) == types.UsagePage.BUTTON) {
                const button_num = @as(u8, @truncate(field.usage)) - 1;
                if (button_num < 8 and val != 0) {
                    buttons_raw |= @as(u8, 1) << @truncate(button_num);
                }
            }
        }

        if (x_val != null and y_val != null) {
            const screen_width: u32 = 1024;
            const screen_height: u32 = 768;

            const screen_x = input.scaleToScreen(
                x_val.?,
                self.capabilities.x_logical_min,
                self.capabilities.x_logical_max,
                screen_width,
            );
            const screen_y = input.scaleToScreen(
                y_val.?,
                self.capabilities.y_logical_min,
                self.capabilities.y_logical_max,
                screen_height,
            );

            const buttons = mouse.Buttons{
                .left = tip_pressed or (buttons_raw & 0x01) != 0,
                .right = (buttons_raw & 0x02) != 0,
                .middle = (buttons_raw & 0x04) != 0,
            };

            mouse.injectAbsoluteInput(
                self.input_device_id,
                @intCast(screen_x),
                @intCast(screen_y),
                screen_width,
                screen_height,
                buttons,
            );
        }
    }

    /// Handle Boot Protocol Keyboard Report
    fn handleKeyboardReport(self: *Self, data: []const u8) void {
        if (data.len < 8) {
            if (data.len != 0) {
                console.debug("HID: Invalid keyboard report size: {} (expected 8)", .{data.len});
            }
            return;
        }

        const modifiers = data[0];
        const keys = data[2..8];

        const mod_diff = modifiers ^ self.prev_modifiers;
        if (mod_diff != 0) {
            if (mod_diff & 0x01 != 0) input.injectMod(0x1D, (modifiers & 0x01) != 0, false);
            if (mod_diff & 0x02 != 0) input.injectMod(0x2A, (modifiers & 0x02) != 0, false);
            if (mod_diff & 0x04 != 0) input.injectMod(0x38, (modifiers & 0x04) != 0, false);
            if (mod_diff & 0x10 != 0) input.injectMod(0x1D, (modifiers & 0x10) != 0, true);
            if (mod_diff & 0x20 != 0) input.injectMod(0x36, (modifiers & 0x20) != 0, false);
            if (mod_diff & 0x40 != 0) input.injectMod(0x38, (modifiers & 0x40) != 0, true);
        }
        self.prev_modifiers = modifiers;

        if (keys[0] == 0x01) return;

        for (self.prev_keys) |prev| {
            if (prev == 0) continue;
            var found = false;
            for (keys) |curr| {
                if (curr == prev) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (input.mapUsbToScancode(prev)) |sc| {
                    if (sc.extended) @import("keyboard").injectScancode(0xE0);
                    @import("keyboard").injectScancode(sc.code | 0x80);
                }
            }
        }

        for (keys) |curr| {
            if (curr == 0) continue;
            var found = false;
            for (self.prev_keys) |prev| {
                if (prev == curr) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (input.mapUsbToScancode(curr)) |sc| {
                    if (sc.extended) @import("keyboard").injectScancode(0xE0);
                    @import("keyboard").injectScancode(sc.code);
                }
            }
        }

        @memcpy(&self.prev_keys, keys);
    }

    /// Handle Boot Protocol Mouse Report
    fn handleMouseReport(self: *Self, data: []const u8) void {
        if (data.len < 3) return;

        const buttons_raw = data[0];
        const x_raw = @as(i8, @bitCast(data[1]));
        const y_raw = @as(i8, @bitCast(data[2]));

        var z_raw: i8 = 0;
        if (data.len >= 4) {
            z_raw = @as(i8, @bitCast(data[3]));
        }

        const buttons = mouse.Buttons{
            .left = (buttons_raw & 0x01) != 0,
            .right = (buttons_raw & 0x02) != 0,
            .middle = (buttons_raw & 0x04) != 0,
        };

        mouse.injectRawInput(self.input_device_id, x_raw, -y_raw, z_raw, buttons);
    }
};
