// HID Report Descriptor Parser Logic
//
// Reference: Device Class Definition for HID 1.11

const std = @import("std");
const console = @import("console");
const types = @import("types.zig");

// =============================================================================
// HID Report Descriptor Parser Structures
// =============================================================================

/// Global state that persists across items until explicitly changed
pub const ParserGlobalState = struct {
    usage_page: u16 = 0,
    logical_min: i32 = 0,
    logical_max: i32 = 0,
    physical_min: i32 = 0,
    physical_max: i32 = 0,
    unit_exponent: i8 = 0,
    unit: u32 = 0,
    report_size: u8 = 0,
    report_count: u8 = 0,
    report_id: u8 = 0,
};

/// Input field flags from Main Item data
pub const FieldFlags = packed struct {
    constant: bool = false, // bit 0: Data (0) or Constant (1)
    variable: bool = false, // bit 1: Array (0) or Variable (1)
    relative: bool = false, // bit 2: Absolute (0) or Relative (1)
    wrap: bool = false, // bit 3: No Wrap (0) or Wrap (1)
    nonlinear: bool = false, // bit 4: Linear (0) or Non-linear (1)
    no_preferred: bool = false, // bit 5: Preferred (0) or No Preferred (1)
    null_state: bool = false, // bit 6: No Null (0) or Null (1)
    buffered: bool = false, // bit 8: Bit Field (0) or Buffered Bytes (1)
};

/// A single field within an HID report
pub const HidField = struct {
    usage: u32, // Full usage: (page << 16) | id
    bit_offset: u16, // Bit offset within the report
    bit_size: u8, // Size in bits
    logical_min: i32,
    logical_max: i32,
    flags: FieldFlags,
};

/// An HID report (Input, Output, or Feature)
pub const HidReport = struct {
    id: u8 = 0,
    // Security: Zero-initialize to prevent information leaks if field_count
    // is ever corrupted or if parsing logic has a bug that increments count
    // without fully initializing a field.
    fields: [types.MAX_FIELDS]HidField = std.mem.zeroes([types.MAX_FIELDS]HidField),
    field_count: u8 = 0,
    total_bits: u16 = 0,

    pub fn addField(self: *HidReport, field: HidField) void {
        if (self.field_count >= types.MAX_FIELDS) {
            console.debug("HID: Attempted to add field beyond MAX_FIELDS limit", .{});
            return;
        }
        self.fields[self.field_count] = field;
        self.field_count += 1;
    }

    pub fn findFieldByUsage(self: *const HidReport, usage: u32) ?*const HidField {
        for (self.fields[0..self.field_count]) |*field| {
            if (field.usage == usage) return field;
        }
        return null;
    }
};

/// Device capabilities detected from report descriptor
pub const DeviceCapabilities = struct {
    is_absolute: bool = false,
    has_x: bool = false,
    has_y: bool = false,
    has_pressure: bool = false,
    has_tilt: bool = false,
    has_buttons: bool = false,
    x_logical_min: i32 = 0,
    x_logical_max: i32 = 0,
    y_logical_min: i32 = 0,
    y_logical_max: i32 = 0,
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Helper to create full 32-bit usage from page and id
pub fn makeUsage(page: u16, id: u16) u32 {
    return (@as(u32, page) << 16) | @as(u32, id);
}

/// Sign-extend a value based on its original size
pub fn signExtend(value: u32, size: usize) i32 {
    // Cast to signed first, then truncate to preserve sign extension
    const signed_value: i32 = @bitCast(value);
    return switch (size) {
        1 => @as(i32, @as(i8, @truncate(signed_value))),
        2 => @as(i32, @as(i16, @truncate(signed_value))),
        else => signed_value,
    };
}

// =============================================================================
// Parser Logic
// =============================================================================

// This section contains the parsing methods that were originally in HidDriver
// We will move them here but they will need a structure to operate on or be passed a 'Self' equivalent.
// Actually, they were defined as methods on HidDriver. We can either:
// 1. Keep them as methods in driver.zig
// 2. Export them as standalone functions that take a context.

// Let's make them standalone functions for now, and re-integrate into the Driver struct in driver.zig.
// Or we can define a Parser struct.

pub const Parser = struct {
    // These will be used to update the HidDriver's state
    is_keyboard: *bool,
    is_mouse: *bool,
    is_tablet: *bool,
    input_report: *HidReport,
    capabilities: *DeviceCapabilities,
    uses_report_id: *bool,

    pub fn parse(self: Parser, data: []const u8) !void {
        var i: usize = 0;

        // Global state (persists until changed)
        var global = ParserGlobalState{};

        // Global state stack for Push/Pop
        var global_stack: [types.MAX_GLOBAL_STACK]ParserGlobalState = undefined;
        var stack_depth: usize = 0;

        // Local state (resets after each Main item)
        var usages: [types.MAX_USAGES]u32 = undefined;
        var usage_count: usize = 0;
        var usage_min: u32 = 0;
        var usage_max: u32 = 0;

        // Tracking state
        var in_collection = false;
        var collection_depth: u8 = 0;
        var current_bit_offset: u16 = 0;

        console.debug("HID: Parsing {} byte report descriptor", .{data.len});

        while (i < data.len) {
            const header = data[i];
            i += 1;

            // Long item (0xFE prefix)
            if (header == 0xFE) {
                if (i + 2 > data.len) break;
                const len = data[i];
                const skip = std.math.add(usize, 2, len) catch break;
                if (i + skip > data.len) break;
                i += skip;
                continue;
            }

            const tag: u4 = @truncate((header >> 4) & 0x0F);
            const item_type: u2 = @truncate((header >> 2) & 0x03);
            const size_code: u2 = @truncate(header & 0x03);

            const size: usize = switch (size_code) {
                0 => 0,
                1 => 1,
                2 => 2,
                3 => 4,
            };

            if (i + size > data.len) break;

            // Read value (little-endian, potentially signed)
            var value: u32 = 0;
            if (size > 0) {
                value = data[i];
                if (size >= 2) value |= (@as(u32, data[i + 1]) << 8);
                if (size >= 4) value |= (@as(u32, data[i + 2]) << 16) | (@as(u32, data[i + 3]) << 24);
                i += size;
            }

            // Process item based on type
            switch (item_type) {
                @intFromEnum(types.ItemType.global) => {
                    self.processGlobalItem(tag, value, size, &global, &global_stack, &stack_depth);
                },
                @intFromEnum(types.ItemType.local) => {
                    self.processLocalItem(tag, value, global.usage_page, &usages, &usage_count, &usage_min, &usage_max);
                },
                @intFromEnum(types.ItemType.main) => {
                    self.processMainItem(
                        tag,
                        value,
                        &global,
                        &usages,
                        &usage_count,
                        usage_min,
                        usage_max,
                        &in_collection,
                        &collection_depth,
                        &current_bit_offset,
                    );
                    // Reset local state after Main item
                    usage_count = 0;
                    usage_min = 0;
                    usage_max = 0;
                },
                else => {},
            }
        }

        // Analyze parsed fields to determine device capabilities
        self.analyzeCapabilities();
    }

    fn processGlobalItem(
        self: Parser,
        tag: u4,
        value: u32,
        size: usize,
        global: *ParserGlobalState,
        global_stack: *[types.MAX_GLOBAL_STACK]ParserGlobalState,
        stack_depth: *usize,
    ) void {
        _ = self;
        switch (tag) {
            @intFromEnum(types.GlobalItem.usage_page) => {
                global.usage_page = @truncate(value);
            },
            @intFromEnum(types.GlobalItem.logical_min) => {
                global.logical_min = signExtend(value, size);
            },
            @intFromEnum(types.GlobalItem.logical_max) => {
                global.logical_max = signExtend(value, size);
            },
            @intFromEnum(types.GlobalItem.physical_min) => {
                global.physical_min = signExtend(value, size);
            },
            @intFromEnum(types.GlobalItem.physical_max) => {
                global.physical_max = signExtend(value, size);
            },
            @intFromEnum(types.GlobalItem.unit_exponent) => {
                const exp: u4 = @truncate(value);
                global.unit_exponent = if (exp > 7) @as(i8, @intCast(exp)) - 16 else @intCast(exp);
            },
            @intFromEnum(types.GlobalItem.unit) => {
                global.unit = value;
            },
            @intFromEnum(types.GlobalItem.report_size) => {
                global.report_size = @truncate(value);
            },
            @intFromEnum(types.GlobalItem.report_id) => {
                global.report_id = @truncate(value);
            },
            @intFromEnum(types.GlobalItem.report_count) => {
                global.report_count = @truncate(value);
            },
            @intFromEnum(types.GlobalItem.push) => {
                if (stack_depth.* < types.MAX_GLOBAL_STACK) {
                    global_stack[stack_depth.*] = global.*;
                    stack_depth.* += 1;
                }
            },
            @intFromEnum(types.GlobalItem.pop) => {
                if (stack_depth.* > 0) {
                    stack_depth.* -= 1;
                    global.* = global_stack[stack_depth.*];
                }
            },
            else => {},
        }
    }

    fn processLocalItem(
        self: Parser,
        tag: u4,
        value: u32,
        usage_page: u16,
        usages: *[types.MAX_USAGES]u32,
        usage_count: *usize,
        usage_min: *u32,
        usage_max: *u32,
    ) void {
        _ = self;
        switch (tag) {
            @intFromEnum(types.LocalItem.usage) => {
                if (usage_count.* < types.MAX_USAGES) {
                    const full_usage = if (value > 0xFFFF)
                        value
                    else
                        makeUsage(usage_page, @truncate(value));
                    usages[usage_count.*] = full_usage;
                    usage_count.* += 1;
                }
            },
            @intFromEnum(types.LocalItem.usage_min) => {
                usage_min.* = if (value > 0xFFFF) value else makeUsage(usage_page, @truncate(value));
            },
            @intFromEnum(types.LocalItem.usage_max) => {
                usage_max.* = if (value > 0xFFFF) value else makeUsage(usage_page, @truncate(value));
            },
            else => {},
        }
    }

    fn processMainItem(
        self: Parser,
        tag: u4,
        value: u32,
        global: *const ParserGlobalState,
        usages: *[types.MAX_USAGES]u32,
        usage_count: *usize,
        usage_min: u32,
        usage_max: u32,
        in_collection: *bool,
        collection_depth: *u8,
        current_bit_offset: *u16,
    ) void {
        switch (tag) {
            @intFromEnum(types.MainItem.collection) => {
                in_collection.* = true;
                // Security: Prevent collection_depth overflow (Vuln 4)
                if (collection_depth.* >= 255) {
                    console.err("HID: Collection depth overflow - rejecting descriptor", .{});
                    return;
                }
                collection_depth.* += 1;

                if (collection_depth.* == 1 and usage_count.* > 0) {
                    const usage = usages[0];
                    const page: u16 = @truncate(usage >> 16);
                    const id: u16 = @truncate(usage);

                    if (page == types.UsagePage.GENERIC_DESKTOP) {
                        if (id == types.UsageGeneric.KEYBOARD) {
                            self.is_keyboard.* = true;
                            console.info("HID: Detected Keyboard", .{});
                        } else if (id == types.UsageGeneric.MOUSE) {
                            self.is_mouse.* = true;
                            console.info("HID: Detected Mouse", .{});
                        }
                    } else if (page == types.UsagePage.DIGITIZER) {
                        if (id == types.UsageDigitizer.TOUCH_SCREEN or
                            id == types.UsageDigitizer.PEN or
                            id == types.UsageDigitizer.TOUCH_PAD or
                            id == types.UsageDigitizer.DIGITIZER)
                        {
                            self.is_tablet.* = true;
                            console.info("HID: Detected Tablet/Digitizer", .{});
                        }
                    }
                }
            },
            @intFromEnum(types.MainItem.end_collection) => {
                if (collection_depth.* > 0) {
                    collection_depth.* -= 1;
                }
                if (collection_depth.* == 0) {
                    in_collection.* = false;
                }
            },
            @intFromEnum(types.MainItem.input) => {
                if (global.report_id != 0) {
                    self.uses_report_id.* = true;
                    self.input_report.id = global.report_id;
                }

                const flags: FieldFlags = @bitCast(@as(u8, @truncate(value)));
                const count = global.report_count;

                var effective_usages: [types.MAX_USAGES]u32 = undefined;
                var effective_count: usize = 0;

                if (usage_min != 0 and usage_max != 0 and usage_max >= usage_min) {
                    var u = usage_min;
                    while (u <= usage_max and effective_count < types.MAX_USAGES) : (u += 1) {
                        effective_usages[effective_count] = u;
                        effective_count += 1;
                    }
                } else if (usage_count.* > 0) {
                    for (usages[0..usage_count.*], 0..) |usage, idx| {
                        if (idx >= types.MAX_USAGES) break;
                        effective_usages[idx] = usage;
                        effective_count = idx + 1;
                    }
                }

                // Security: Cap field processing to MAX_FIELDS to prevent array overflow
                const max_processable = @min(count, types.MAX_FIELDS);
                if (count > types.MAX_FIELDS) {
                    console.warn("HID: Report descriptor has {} fields, capping to MAX_FIELDS ({})", .{ count, types.MAX_FIELDS });
                }

                var field_idx: usize = 0;
                while (field_idx < max_processable) : (field_idx += 1) {
                    const usage = if (field_idx < effective_count)
                        effective_usages[field_idx]
                    else if (effective_count > 0)
                        effective_usages[effective_count - 1] // Repeat last usage
                    else
                        0;

                    const field = HidField{
                        .usage = usage,
                        .bit_offset = current_bit_offset.*,
                        .bit_size = global.report_size,
                        .logical_min = global.logical_min,
                        .logical_max = global.logical_max,
                        .flags = flags,
                    };

                    self.input_report.addField(field);
                    // Security: Use checked arithmetic to prevent bit_offset overflow (Vuln 1)
                    current_bit_offset.* = std.math.add(u16, current_bit_offset.*, global.report_size) catch {
                        console.err("HID: bit_offset overflow in Input item", .{});
                        return;
                    };
                }

                self.input_report.total_bits = current_bit_offset.*;
            },
            @intFromEnum(types.MainItem.output), @intFromEnum(types.MainItem.feature) => {
                // Security: Use checked arithmetic to prevent bit_offset overflow (Vuln 7)
                const increment = std.math.mul(u16, global.report_size, global.report_count) catch {
                    console.err("HID: bit_offset multiplication overflow in Output/Feature item", .{});
                    return;
                };
                current_bit_offset.* = std.math.add(u16, current_bit_offset.*, increment) catch {
                    console.err("HID: bit_offset overflow in Output/Feature item", .{});
                    return;
                };
            },
            else => {},
        }
    }

    fn analyzeCapabilities(self: Parser) void {
        const x_usage = makeUsage(types.UsagePage.GENERIC_DESKTOP, types.UsageGeneric.X);
        const y_usage = makeUsage(types.UsagePage.GENERIC_DESKTOP, types.UsageGeneric.Y);

        // Security: Defensive bounds validation to prevent panic
        const safe_field_count = @min(self.input_report.field_count, types.MAX_FIELDS);
        if (self.input_report.field_count > types.MAX_FIELDS) {
            console.warn("HID: field_count ({}) exceeds MAX_FIELDS ({}), capping", .{ self.input_report.field_count, types.MAX_FIELDS });
        }

        for (self.input_report.fields[0..safe_field_count]) |*field| {
            if (field.usage == x_usage) {
                self.capabilities.has_x = true;
                self.capabilities.x_logical_min = field.logical_min;
                self.capabilities.x_logical_max = field.logical_max;
                if (!field.flags.relative) {
                    self.capabilities.is_absolute = true;
                }
            } else if (field.usage == y_usage) {
                self.capabilities.has_y = true;
                self.capabilities.y_logical_min = field.logical_min;
                self.capabilities.y_logical_max = field.logical_max;
            } else if (field.usage == makeUsage(types.UsagePage.DIGITIZER, types.UsageDigitizer.TIP_PRESSURE)) {
                self.capabilities.has_pressure = true;
            } else if (field.usage == makeUsage(types.UsagePage.DIGITIZER, types.UsageDigitizer.TILT_X) or
                field.usage == makeUsage(types.UsagePage.DIGITIZER, types.UsageDigitizer.TILT_Y))
            {
                self.capabilities.has_tilt = true;
            } else if ((field.usage >> 16) == types.UsagePage.BUTTON) {
                self.capabilities.has_buttons = true;
            }
        }

        if (self.capabilities.is_absolute and self.capabilities.has_x and self.capabilities.has_y) {
            if (!self.is_keyboard.*) {
                self.is_tablet.* = true;
                self.is_mouse.* = false; 
                console.info("HID: Device has absolute positioning - treating as tablet", .{});
            }
        }

        console.debug("HID: Capabilities - abs={} x={} y={} pressure={} buttons={}", .{
            self.capabilities.is_absolute,
            self.capabilities.has_x,
            self.capabilities.has_y,
            self.capabilities.has_pressure,
            self.capabilities.has_buttons,
        });
    }
};
