// USB HID Class Driver
//
// Implements support for Human Interface Devices (HID) class 0x03.
// Handles parsing of HID descriptors and mapping input events to
// the kernel's input subsystem (keyboard/mouse).
//
// Reference: Device Class Definition for HID 1.11

const std = @import("std");
const console = @import("console");
const usb = @import("../root.zig");
const keyboard = @import("keyboard");
const mouse = @import("mouse");

// =============================================================================
// HID Descriptors
// =============================================================================

/// HID Descriptor (after Interface Descriptor)
pub const HidDescriptor = packed struct {
    b_length: u8,
    b_descriptor_type: u8, // 0x21
    bcd_hid: u16,
    b_country_code: u8,
    b_num_descriptors: u8,
    b_class_descriptor_type: u8, // 0x22 (Report)
    w_class_descriptor_length: u16,

    // Note: There can be more descriptor type/length pairs if b_num_descriptors > 1
    // but the struct is fixed size here for the common case.

    comptime {
        if (@sizeOf(@This()) != 9) @compileError("HidDescriptor must be 9 bytes");
    }
};

// =============================================================================
// HID Request Codes
// =============================================================================

pub const Request = struct {
    pub const GET_REPORT: u8 = 0x01;
    pub const GET_IDLE: u8 = 0x02;
    pub const GET_PROTOCOL: u8 = 0x03;
    pub const SET_REPORT: u8 = 0x09;
    pub const SET_IDLE: u8 = 0x0A;
    pub const SET_PROTOCOL: u8 = 0x0B;
};

pub const Protocol = struct {
    pub const BOOT: u8 = 0;
    pub const REPORT: u8 = 1;
};

// =============================================================================
// HID Report Item Tags
// =============================================================================

const ItemType = enum(u2) {
    main = 0,
    global = 1,
    local = 2,
    reserved = 3,
};

const MainItem = enum(u4) {
    input = 0x8,
    output = 0x9,
    feature = 0xB,
    collection = 0xA,
    end_collection = 0xC,
};

const GlobalItem = enum(u4) {
    usage_page = 0x0,
    logical_min = 0x1,
    logical_max = 0x2,
    physical_min = 0x3,
    physical_max = 0x4,
    unit_exponent = 0x5,
    unit = 0x6,
    report_size = 0x7,
    report_id = 0x8,
    report_count = 0x9,
    push = 0xA,
    pop = 0xB,
};

const LocalItem = enum(u4) {
    usage = 0x0,
    usage_min = 0x1,
    usage_max = 0x2,
    designator_index = 0x3,
    designator_min = 0x4,
    designator_max = 0x5,
    string_index = 0x7,
    string_min = 0x8,
    string_max = 0x9,
    delimiter = 0xA,
};

// =============================================================================
// Usage Pages and IDs
// =============================================================================

const UsagePage = struct {
    pub const GENERIC_DESKTOP: u16 = 0x01;
    pub const KEYBOARD: u16 = 0x07;
    pub const LEDS: u16 = 0x08;
    pub const BUTTON: u16 = 0x09;
    pub const DIGITIZER: u16 = 0x0D;
};

const UsageDigitizer = struct {
    pub const DIGITIZER: u16 = 0x01;
    pub const PEN: u16 = 0x02;
    pub const TOUCH_SCREEN: u16 = 0x04;
    pub const TOUCH_PAD: u16 = 0x05;
    pub const FINGER: u16 = 0x22;
    pub const TIP_PRESSURE: u16 = 0x30;
    pub const IN_RANGE: u16 = 0x32;
    pub const TOUCH: u16 = 0x33;
    pub const TIP_SWITCH: u16 = 0x42;
    pub const BARREL_SWITCH: u16 = 0x44;
    pub const ERASER: u16 = 0x45;
    pub const CONFIDENCE: u16 = 0x47;
    pub const CONTACT_ID: u16 = 0x51;
    pub const CONTACT_COUNT: u16 = 0x54;
    pub const TILT_X: u16 = 0x3D;
    pub const TILT_Y: u16 = 0x3E;
};

const UsageGeneric = struct {
    pub const POINTER: u16 = 0x01;
    pub const MOUSE: u16 = 0x02;
    pub const JOYSTICK: u16 = 0x04;
    pub const GAMEPAD: u16 = 0x05;
    pub const KEYBOARD: u16 = 0x06;
    pub const KEYPAD: u16 = 0x07;
    pub const X: u16 = 0x30;
    pub const Y: u16 = 0x31;
    pub const Z: u16 = 0x32;
    pub const WHEEL: u16 = 0x38;
};

// =============================================================================
// HID Report Descriptor Parser Structures
// =============================================================================

const MAX_FIELDS: usize = 32;
const MAX_USAGES: usize = 64;
const MAX_GLOBAL_STACK: usize = 4;
const MAX_REPORTS: usize = 4;

/// Global state that persists across items until explicitly changed
const ParserGlobalState = struct {
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
const FieldFlags = packed struct {
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
const HidField = struct {
    usage: u32, // Full usage: (page << 16) | id
    bit_offset: u16, // Bit offset within the report
    bit_size: u8, // Size in bits
    logical_min: i32,
    logical_max: i32,
    flags: FieldFlags,
};

/// An HID report (Input, Output, or Feature)
const HidReport = struct {
    id: u8 = 0,
    fields: [MAX_FIELDS]HidField = undefined,
    field_count: u8 = 0,
    total_bits: u16 = 0,

    fn addField(self: *HidReport, field: HidField) void {
        if (self.field_count < MAX_FIELDS) {
            self.fields[self.field_count] = field;
            self.field_count += 1;
        }
    }

    fn findFieldByUsage(self: *const HidReport, usage: u32) ?*const HidField {
        for (self.fields[0..self.field_count]) |*field| {
            if (field.usage == usage) return field;
        }
        return null;
    }
};

/// Device capabilities detected from report descriptor
const DeviceCapabilities = struct {
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

/// Helper to create full 32-bit usage from page and id
fn makeUsage(page: u16, id: u16) u32 {
    return (@as(u32, page) << 16) | @as(u32, id);
}

/// Sign-extend a value based on its original size
fn signExtend(value: u32, size: usize) i32 {
    // Cast to signed first, then truncate to preserve sign extension
    const signed_value: i32 = @bitCast(value);
    return switch (size) {
        1 => @as(i32, @as(i8, @truncate(signed_value))),
        2 => @as(i32, @as(i16, @truncate(signed_value))),
        else => signed_value,
    };
}

/// Extract a field value from a report buffer at bit-level precision
/// Security: Validates bit_offset and bit_size from untrusted device data
/// to prevent out-of-bounds reads and integer overflows.
fn extractFieldValue(data: []const u8, field: *const HidField) i32 {
    // Security: Validate bit_size is reasonable (max 32 bits for u32)
    if (field.bit_size == 0 or field.bit_size > 32) return 0;

    // Security: Use safe cast for byte offset calculation
    const byte_offset = std.math.cast(usize, field.bit_offset / 8) orelse return 0;
    const bit_shift: u5 = @truncate(field.bit_offset % 8);

    if (byte_offset >= data.len) return 0;

    // Calculate bytes needed to cover the field
    const bits_in_first_byte = 8 - @as(u8, bit_shift);
    const remaining_bits = if (field.bit_size > bits_in_first_byte)
        field.bit_size - bits_in_first_byte
    else
        0;
    const bytes_needed = 1 + (remaining_bits + 7) / 8;

    // Security: Limit bytes_needed to prevent reading too far
    const safe_bytes_needed = @min(bytes_needed, 4); // Max 4 bytes for u32

    // Read bytes (little-endian)
    var raw: u32 = 0;
    var byte_idx: usize = 0;
    while (byte_idx < safe_bytes_needed) : (byte_idx += 1) {
        // Security: Check bounds before each access
        const access_offset = std.math.add(usize, byte_offset, byte_idx) catch break;
        if (access_offset >= data.len) break;
        raw |= @as(u32, data[access_offset]) << @intCast(byte_idx * 8);
    }

    // Shift and mask to extract the field
    raw >>= bit_shift;
    const mask: u32 = if (field.bit_size >= 32) 0xFFFFFFFF else (@as(u32, 1) << @intCast(field.bit_size)) - 1;
    raw &= mask;

    // Sign-extend if logical_min is negative (indicating signed values)
    if (field.logical_min < 0 and field.bit_size > 0 and field.bit_size < 32) {
        const sign_bit: u32 = @as(u32, 1) << @intCast(field.bit_size - 1);
        if (raw & sign_bit != 0) {
            raw |= ~mask; // Sign extend
        }
    }

    return @bitCast(raw);
}

/// Scale a value from logical range to screen coordinates
fn scaleToScreen(value: i32, logical_min: i32, logical_max: i32, screen_size: u32) u32 {
    const range = logical_max - logical_min;
    if (range <= 0) return 0;

    const normalized = value - logical_min;
    if (normalized < 0) return 0;

    const scaled = @as(u64, @intCast(normalized)) * @as(u64, screen_size) / @as(u64, @intCast(range));
    return @intCast(@min(scaled, screen_size - 1));
}

// =============================================================================
// HID Driver Logic
// =============================================================================

pub const HidDriver = struct {
    is_keyboard: bool = false,
    is_mouse: bool = false,
    is_tablet: bool = false,
    interface_num: u8 = 0,
    in_endpoint: u8 = 0,
    out_endpoint: ?u8 = null,
    packet_size: u16 = 0,

    // Parsed report descriptor data
    input_report: HidReport = .{},
    capabilities: DeviceCapabilities = .{},
    uses_report_id: bool = false,

    // Keyboard state
    prev_modifiers: u8 = 0,
    prev_keys: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },

    const Self = @This();

    /// Parse HID report descriptor with full state machine
    /// Security: Validates all length fields from untrusted device data
    /// to prevent out-of-bounds reads.
    pub fn parseReportDescriptor(self: *Self, data: []const u8) !void {
        var i: usize = 0;

        // Global state (persists until changed)
        var global = ParserGlobalState{};

        // Global state stack for Push/Pop
        var global_stack: [MAX_GLOBAL_STACK]ParserGlobalState = undefined;
        var stack_depth: usize = 0;

        // Local state (resets after each Main item)
        var usages: [MAX_USAGES]u32 = undefined;
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
                // Security: Long item format is: 0xFE, bDataSize, bLongItemTag, data[bDataSize]
                // Need at least 2 more bytes for size and tag
                if (i + 2 > data.len) break;
                const len = data[i];
                // Security: Use checked arithmetic to prevent overflow
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
                @intFromEnum(ItemType.global) => {
                    self.processGlobalItem(tag, value, size, &global, &global_stack, &stack_depth);
                },
                @intFromEnum(ItemType.local) => {
                    self.processLocalItem(tag, value, global.usage_page, &usages, &usage_count, &usage_min, &usage_max);
                },
                @intFromEnum(ItemType.main) => {
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
        self: *Self,
        tag: u4,
        value: u32,
        size: usize,
        global: *ParserGlobalState,
        global_stack: *[MAX_GLOBAL_STACK]ParserGlobalState,
        stack_depth: *usize,
    ) void {
        _ = self;
        switch (tag) {
            @intFromEnum(GlobalItem.usage_page) => {
                global.usage_page = @truncate(value);
            },
            @intFromEnum(GlobalItem.logical_min) => {
                // Sign-extend if needed based on size
                global.logical_min = signExtend(value, size);
            },
            @intFromEnum(GlobalItem.logical_max) => {
                global.logical_max = signExtend(value, size);
            },
            @intFromEnum(GlobalItem.physical_min) => {
                global.physical_min = signExtend(value, size);
            },
            @intFromEnum(GlobalItem.physical_max) => {
                global.physical_max = signExtend(value, size);
            },
            @intFromEnum(GlobalItem.unit_exponent) => {
                // Unit exponent is 4-bit signed nibble
                const exp: u4 = @truncate(value);
                global.unit_exponent = if (exp > 7) @as(i8, @intCast(exp)) - 16 else @intCast(exp);
            },
            @intFromEnum(GlobalItem.unit) => {
                global.unit = value;
            },
            @intFromEnum(GlobalItem.report_size) => {
                global.report_size = @truncate(value);
            },
            @intFromEnum(GlobalItem.report_id) => {
                global.report_id = @truncate(value);
            },
            @intFromEnum(GlobalItem.report_count) => {
                global.report_count = @truncate(value);
            },
            @intFromEnum(GlobalItem.push) => {
                if (stack_depth.* < MAX_GLOBAL_STACK) {
                    global_stack[stack_depth.*] = global.*;
                    stack_depth.* += 1;
                }
            },
            @intFromEnum(GlobalItem.pop) => {
                if (stack_depth.* > 0) {
                    stack_depth.* -= 1;
                    global.* = global_stack[stack_depth.*];
                }
            },
            else => {},
        }
    }

    fn processLocalItem(
        self: *Self,
        tag: u4,
        value: u32,
        usage_page: u16,
        usages: *[MAX_USAGES]u32,
        usage_count: *usize,
        usage_min: *u32,
        usage_max: *u32,
    ) void {
        _ = self;
        switch (tag) {
            @intFromEnum(LocalItem.usage) => {
                if (usage_count.* < MAX_USAGES) {
                    // If value is 16-bit, it's just usage ID; if 32-bit, it includes page
                    const full_usage = if (value > 0xFFFF)
                        value
                    else
                        makeUsage(usage_page, @truncate(value));
                    usages[usage_count.*] = full_usage;
                    usage_count.* += 1;
                }
            },
            @intFromEnum(LocalItem.usage_min) => {
                usage_min.* = if (value > 0xFFFF) value else makeUsage(usage_page, @truncate(value));
            },
            @intFromEnum(LocalItem.usage_max) => {
                usage_max.* = if (value > 0xFFFF) value else makeUsage(usage_page, @truncate(value));
            },
            else => {},
        }
    }

    fn processMainItem(
        self: *Self,
        tag: u4,
        value: u32,
        global: *const ParserGlobalState,
        usages: *[MAX_USAGES]u32,
        usage_count: *usize,
        usage_min: u32,
        usage_max: u32,
        in_collection: *bool,
        collection_depth: *u8,
        current_bit_offset: *u16,
    ) void {
        switch (tag) {
            @intFromEnum(MainItem.collection) => {
                in_collection.* = true;
                collection_depth.* += 1;

                // Check top-level collection usage for device type detection
                if (collection_depth.* == 1 and usage_count.* > 0) {
                    const usage = usages[0];
                    const page: u16 = @truncate(usage >> 16);
                    const id: u16 = @truncate(usage);

                    if (page == UsagePage.GENERIC_DESKTOP) {
                        if (id == UsageGeneric.KEYBOARD) {
                            self.is_keyboard = true;
                            console.info("HID: Detected Keyboard", .{});
                        } else if (id == UsageGeneric.MOUSE) {
                            self.is_mouse = true;
                            console.info("HID: Detected Mouse", .{});
                        }
                    } else if (page == UsagePage.DIGITIZER) {
                        if (id == UsageDigitizer.TOUCH_SCREEN or
                            id == UsageDigitizer.PEN or
                            id == UsageDigitizer.TOUCH_PAD or
                            id == UsageDigitizer.DIGITIZER)
                        {
                            self.is_tablet = true;
                            console.info("HID: Detected Tablet/Digitizer", .{});
                        }
                    }
                }
            },
            @intFromEnum(MainItem.end_collection) => {
                if (collection_depth.* > 0) {
                    collection_depth.* -= 1;
                }
                if (collection_depth.* == 0) {
                    in_collection.* = false;
                }
            },
            @intFromEnum(MainItem.input) => {
                // Track report ID usage
                if (global.report_id != 0) {
                    self.uses_report_id = true;
                    self.input_report.id = global.report_id;
                }

                // Create fields for this input item
                const flags: FieldFlags = @bitCast(@as(u8, @truncate(value)));

                // Determine how many fields to create
                const count = global.report_count;

                // If we have usage range, expand it
                var effective_usages: [MAX_USAGES]u32 = undefined;
                var effective_count: usize = 0;

                if (usage_min != 0 and usage_max != 0 and usage_max >= usage_min) {
                    // Expand usage range
                    var u = usage_min;
                    while (u <= usage_max and effective_count < MAX_USAGES) : (u += 1) {
                        effective_usages[effective_count] = u;
                        effective_count += 1;
                    }
                } else if (usage_count.* > 0) {
                    // Use explicit usages
                    for (usages[0..usage_count.*], 0..) |usage, idx| {
                        if (idx >= MAX_USAGES) break;
                        effective_usages[idx] = usage;
                        effective_count = idx + 1;
                    }
                }

                // Create fields
                var field_idx: usize = 0;
                while (field_idx < count) : (field_idx += 1) {
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
                    current_bit_offset.* += global.report_size;
                }

                self.input_report.total_bits = current_bit_offset.*;
            },
            @intFromEnum(MainItem.output), @intFromEnum(MainItem.feature) => {
                // Skip output/feature reports but account for their bit size
                current_bit_offset.* += @as(u16, global.report_size) * @as(u16, global.report_count);
            },
            else => {},
        }
    }

    /// Analyze parsed fields to determine device capabilities
    fn analyzeCapabilities(self: *Self) void {
        const x_usage = makeUsage(UsagePage.GENERIC_DESKTOP, UsageGeneric.X);
        const y_usage = makeUsage(UsagePage.GENERIC_DESKTOP, UsageGeneric.Y);

        for (self.input_report.fields[0..self.input_report.field_count]) |*field| {
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
            } else if (field.usage == makeUsage(UsagePage.DIGITIZER, UsageDigitizer.TIP_PRESSURE)) {
                self.capabilities.has_pressure = true;
            } else if (field.usage == makeUsage(UsagePage.DIGITIZER, UsageDigitizer.TILT_X) or
                field.usage == makeUsage(UsagePage.DIGITIZER, UsageDigitizer.TILT_Y))
            {
                self.capabilities.has_tilt = true;
            } else if ((field.usage >> 16) == UsagePage.BUTTON) {
                self.capabilities.has_buttons = true;
            }
        }

        // If we have absolute X/Y and detected as tablet, confirm tablet mode
        if (self.capabilities.is_absolute and self.capabilities.has_x and self.capabilities.has_y) {
            if (!self.is_keyboard) {
                self.is_tablet = true;
                self.is_mouse = false; // Override mouse detection
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

    /// Handle an incoming input report
    /// Routes to appropriate handler based on device type
    pub fn handleInputReport(self: *Self, data: []const u8) void {
        // Skip report ID byte if device uses report IDs
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
        const x_usage = makeUsage(UsagePage.GENERIC_DESKTOP, UsageGeneric.X);
        const y_usage = makeUsage(UsagePage.GENERIC_DESKTOP, UsageGeneric.Y);
        const tip_switch_usage = makeUsage(UsagePage.DIGITIZER, UsageDigitizer.TIP_SWITCH);

        var x_val: ?i32 = null;
        var y_val: ?i32 = null;
        var tip_pressed = false;
        var buttons_raw: u8 = 0;

        // Extract values from parsed fields
        for (self.input_report.fields[0..self.input_report.field_count]) |*field| {
            const val = extractFieldValue(data, field);

            if (field.usage == x_usage) {
                x_val = val;
            } else if (field.usage == y_usage) {
                y_val = val;
            } else if (field.usage == tip_switch_usage) {
                tip_pressed = val != 0;
            } else if ((field.usage >> 16) == UsagePage.BUTTON) {
                // Button usages are 0x09xxxx where xx is button number (1-based)
                const button_num = @as(u8, @truncate(field.usage)) - 1;
                if (button_num < 8 and val != 0) {
                    buttons_raw |= @as(u8, 1) << @truncate(button_num);
                }
            }
        }

        // If we have valid coordinates, update cursor position
        if (x_val != null and y_val != null) {
            // Get screen dimensions (use reasonable defaults)
            // In a real implementation, these would come from the video driver
            const screen_width: u32 = 1024;
            const screen_height: u32 = 768;

            const screen_x = scaleToScreen(
                x_val.?,
                self.capabilities.x_logical_min,
                self.capabilities.x_logical_max,
                screen_width,
            );
            const screen_y = scaleToScreen(
                y_val.?,
                self.capabilities.y_logical_min,
                self.capabilities.y_logical_max,
                screen_height,
            );

            // Use the mouse driver's absolute positioning if available
            // For now, inject as relative movement from current position
            // This is a simplified approach - ideally we'd have cursor.setAbsolute()
            const buttons = mouse.Buttons{
                .left = tip_pressed or (buttons_raw & 0x01) != 0,
                .right = (buttons_raw & 0x02) != 0,
                .middle = (buttons_raw & 0x04) != 0,
            };

            // Inject absolute position as raw input
            // The mouse driver will need to handle this appropriately
            mouse.injectAbsoluteInput(
                @intCast(screen_x),
                @intCast(screen_y),
                screen_width,
                screen_height,
                buttons,
            );
        }
    }

    /// Handle Boot Protocol Keyboard Report
    /// Format: [Mods, Reserved, Key1, Key2, Key3, Key4, Key5, Key6]
    fn handleKeyboardReport(self: *Self, data: []const u8) void {
        if (data.len < 8) return;

        const modifiers = data[0];
        // data[1] is reserved
        const keys = data[2..8];

        // 1. Handle Modifier changes
        // Modifiers are handled by the keyboard driver via scancodes usually,
        // but here we get a bitmask.
        // We can simulate scancodes for modifiers.
        // Left Ctrl: 0x01 -> Scancode 0x1D
        // Left Shift: 0x02 -> Scancode 0x2A
        // Left Alt: 0x04 -> Scancode 0x38
        // Left GUI: 0x08 -> Scancode 0xE0 0x5B (Windows)
        // Right Ctrl: 0x10 -> Scancode 0xE0 0x1D
        // Right Shift: 0x20 -> Scancode 0x36
        // Right Alt: 0x40 -> Scancode 0xE0 0x38
        // Right GUI: 0x80 -> Scancode 0xE0 0x5C

        const mod_diff = modifiers ^ self.prev_modifiers;
        if (mod_diff != 0) {
            if (mod_diff & 0x01 != 0) injectMod(0x1D, (modifiers & 0x01) != 0, false);
            if (mod_diff & 0x02 != 0) injectMod(0x2A, (modifiers & 0x02) != 0, false);
            if (mod_diff & 0x04 != 0) injectMod(0x38, (modifiers & 0x04) != 0, false);
            // GUI keys skipped for simplicity or need extended
            if (mod_diff & 0x10 != 0) injectMod(0x1D, (modifiers & 0x10) != 0, true);
            if (mod_diff & 0x20 != 0) injectMod(0x36, (modifiers & 0x20) != 0, false);
            if (mod_diff & 0x40 != 0) injectMod(0x38, (modifiers & 0x40) != 0, true);
        }
        self.prev_modifiers = modifiers;

        // 2. Handle Key presses/releases
        // We compare current keys against previous keys
        // Simple approach: Check what's new (pressed) and what's gone (released)

        // Check for Rollover error (all 1s)
        if (keys[0] == 0x01) return;

        // Check for releases
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
                // Key released
                if (mapUsbToScancode(prev)) |sc| {
                    if (sc.extended) keyboard.injectScancode(0xE0);
                    keyboard.injectScancode(sc.code | 0x80); // Break code
                }
            }
        }

        // Check for presses
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
                // Key pressed
                if (mapUsbToScancode(curr)) |sc| {
                    if (sc.extended) keyboard.injectScancode(0xE0);
                    keyboard.injectScancode(sc.code);
                }
            }
        }

        @memcpy(&self.prev_keys, keys);
    }

    /// Handle Boot Protocol Mouse Report
    /// Format: [Buttons, X, Y, (Optional Wheel)]
    fn handleMouseReport(self: *Self, data: []const u8) void {
        _ = self;
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

        // USB coordinates: Right positive, Down positive.
        // PS/2 coordinates: Right positive, Up positive.
        // Mouse driver expects: Positive = Up (standard convention logic in driver).
        // Wait, mouse.zig says:
        // "Y is inverted so positive = up (standard convention)"
        // "dy: i16 = if ((flags & 0x20) != 0) 256 - packet[2] else -packet[2]"
        // The driver flips PS/2 Y.
        // Here we just pass raw delta. If USB gives Down positive, and we want Up positive, we negate Y.

        mouse.injectRawInput(x_raw, -y_raw, z_raw, buttons);
    }
};

fn injectMod(scancode: u8, pressed: bool, extended: bool) void {
    if (extended) keyboard.injectScancode(0xE0);
    keyboard.injectScancode(if (pressed) scancode else scancode | 0x80);
}

const Scancode = struct {
    code: u8,
    extended: bool = false,
};

/// Map USB Usage ID to PS/2 Scancode (Set 1)
/// Only covers common keys
fn mapUsbToScancode(usage: u8) ?Scancode {
    return switch (usage) {
        0x04 => .{ .code = 0x1E }, // A
        0x05 => .{ .code = 0x30 }, // B
        0x06 => .{ .code = 0x2E }, // C
        0x07 => .{ .code = 0x20 }, // D
        0x08 => .{ .code = 0x12 }, // E
        0x09 => .{ .code = 0x21 }, // F
        0x0A => .{ .code = 0x22 }, // G
        0x0B => .{ .code = 0x23 }, // H
        0x0C => .{ .code = 0x17 }, // I
        0x0D => .{ .code = 0x24 }, // J
        0x0E => .{ .code = 0x25 }, // K
        0x0F => .{ .code = 0x26 }, // L
        0x10 => .{ .code = 0x32 }, // M
        0x11 => .{ .code = 0x31 }, // N
        0x12 => .{ .code = 0x18 }, // O
        0x13 => .{ .code = 0x19 }, // P
        0x14 => .{ .code = 0x10 }, // Q
        0x15 => .{ .code = 0x13 }, // R
        0x16 => .{ .code = 0x1F }, // S
        0x17 => .{ .code = 0x14 }, // T
        0x18 => .{ .code = 0x16 }, // U
        0x19 => .{ .code = 0x2F }, // V
        0x1A => .{ .code = 0x11 }, // W
        0x1B => .{ .code = 0x2D }, // X
        0x1C => .{ .code = 0x15 }, // Y
        0x1D => .{ .code = 0x2C }, // Z

        0x1E => .{ .code = 0x02 }, // 1
        0x1F => .{ .code = 0x03 }, // 2
        0x20 => .{ .code = 0x04 }, // 3
        0x21 => .{ .code = 0x05 }, // 4
        0x22 => .{ .code = 0x06 }, // 5
        0x23 => .{ .code = 0x07 }, // 6
        0x24 => .{ .code = 0x08 }, // 7
        0x25 => .{ .code = 0x09 }, // 8
        0x26 => .{ .code = 0x0A }, // 9
        0x27 => .{ .code = 0x0B }, // 0

        0x28 => .{ .code = 0x1C }, // Enter
        0x29 => .{ .code = 0x01 }, // Esc
        0x2A => .{ .code = 0x0E }, // Backspace
        0x2B => .{ .code = 0x0F }, // Tab
        0x2C => .{ .code = 0x39 }, // Space

        0x2D => .{ .code = 0x0C }, // -
        0x2E => .{ .code = 0x0D }, // =
        0x2F => .{ .code = 0x1A }, // [
        0x30 => .{ .code = 0x1B }, // ]
        0x31 => .{ .code = 0x2B }, // \
        0x33 => .{ .code = 0x27 }, // ;
        0x34 => .{ .code = 0x28 }, // '
        0x35 => .{ .code = 0x29 }, // `
        0x36 => .{ .code = 0x33 }, // ,
        0x37 => .{ .code = 0x34 }, // .
        0x38 => .{ .code = 0x35 }, // /

        0x39 => .{ .code = 0x3A }, // CapsLock

        0x3A => .{ .code = 0x3B }, // F1
        0x3B => .{ .code = 0x3C }, // F2
        0x3C => .{ .code = 0x3D }, // F3
        0x3D => .{ .code = 0x3E }, // F4
        0x3E => .{ .code = 0x3F }, // F5
        0x3F => .{ .code = 0x40 }, // F6
        0x40 => .{ .code = 0x41 }, // F7
        0x41 => .{ .code = 0x42 }, // F8
        0x42 => .{ .code = 0x43 }, // F9
        0x43 => .{ .code = 0x44 }, // F10
        0x44 => .{ .code = 0x57 }, // F11
        0x45 => .{ .code = 0x58 }, // F12

        0x49 => .{ .code = 0x52, .extended = true }, // Insert
        0x4A => .{ .code = 0x47, .extended = true }, // Home
        0x4B => .{ .code = 0x49, .extended = true }, // PageUp
        0x4C => .{ .code = 0x53, .extended = true }, // Delete
        0x4D => .{ .code = 0x4F, .extended = true }, // End
        0x4E => .{ .code = 0x51, .extended = true }, // PageDown
        0x4F => .{ .code = 0x4D, .extended = true }, // Right
        0x50 => .{ .code = 0x4B, .extended = true }, // Left
        0x51 => .{ .code = 0x50, .extended = true }, // Down
        0x52 => .{ .code = 0x48, .extended = true }, // Up

        else => null,
    };
}
