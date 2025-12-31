// CMOS Real-Time Clock (RTC) Driver
//
// Provides read/write access to the MC146818A RTC chip via CMOS ports.
// The RTC maintains wall-clock time and supports alarms and periodic interrupts.
//
// Hardware Details:
// - Ports: 0x70 (address + NMI mask), 0x71 (data)
// - IRQ8 for alarms/periodic (vector 40 in APIC mode)
// - Battery-backed CMOS RAM for persistent storage
//
// Security: writeDateTime is privileged - caller must verify permissions

const std = @import("std");
const io = @import("../lib/io.zig");
const apic = @import("apic/root.zig");
const pic = @import("pic.zig");
const interrupts = @import("interrupts/root.zig");
const sync = @import("sync");
const console = @import("console");

// CMOS I/O Ports
const CMOS_ADDR: u16 = 0x70;
const CMOS_DATA: u16 = 0x71;

// RTC Register Addresses
const REG_SECONDS: u8 = 0x00;
const REG_SECONDS_ALARM: u8 = 0x01;
const REG_MINUTES: u8 = 0x02;
const REG_MINUTES_ALARM: u8 = 0x03;
const REG_HOURS: u8 = 0x04;
const REG_HOURS_ALARM: u8 = 0x05;
const REG_DAY_OF_WEEK: u8 = 0x06;
const REG_DAY_OF_MONTH: u8 = 0x07;
const REG_MONTH: u8 = 0x08;
const REG_YEAR: u8 = 0x09;
const REG_STATUS_A: u8 = 0x0A;
const REG_STATUS_B: u8 = 0x0B;
const REG_STATUS_C: u8 = 0x0C; // Read to acknowledge interrupt
const REG_STATUS_D: u8 = 0x0D;
const REG_CENTURY: u8 = 0x32; // Common location (ACPI FADT provides this)

/// Status Register A (read/write)
/// Controls update cycle and periodic interrupt rate
pub const StatusA = packed struct(u8) {
    rate_select: u4, // Bits 0-3: Periodic interrupt rate (0=off, 3-15 valid)
    divider: u3, // Bits 4-6: Divider chain (010 = 32.768 kHz crystal)
    update_in_progress: u1, // Bit 7: 1 = update cycle in progress (read-only)
};

/// Status Register B (read/write)
/// Controls data format and interrupt enables
pub const StatusB = packed struct(u8) {
    daylight_savings: u1, // Bit 0: DST enable (not commonly used)
    hour_format: u1, // Bit 1: 0 = 12-hour, 1 = 24-hour
    binary_mode: u1, // Bit 2: 0 = BCD, 1 = binary
    square_wave: u1, // Bit 3: Enable square wave output (pin SQWE)
    update_ended_int: u1, // Bit 4: Enable update-ended interrupt
    alarm_int: u1, // Bit 5: Enable alarm interrupt
    periodic_int: u1, // Bit 6: Enable periodic interrupt
    update_inhibit: u1, // Bit 7: 1 = inhibit updates (for safe writes)
};

/// Status Register C (read-only)
/// Read to acknowledge interrupts - reading clears flags
pub const StatusC = packed struct(u8) {
    _reserved: u4, // Bits 0-3: Reserved
    update_ended: u1, // Bit 4: Update cycle ended
    alarm: u1, // Bit 5: Alarm occurred
    periodic: u1, // Bit 6: Periodic interrupt
    interrupt_request: u1, // Bit 7: IRQ pending (OR of bits 4-6)
};

/// Status Register D (read-only)
pub const StatusD = packed struct(u8) {
    _reserved: u7, // Bits 0-6: Reserved
    valid_ram: u1, // Bit 7: 1 = CMOS RAM has valid data (battery OK)
};

/// Date/Time structure (always in 24-hour binary format internally)
pub const DateTime = struct {
    year: u16, // Full year (e.g., 2025)
    month: u8, // 1-12
    day: u8, // 1-31
    hour: u8, // 0-23 (24-hour format)
    minute: u8, // 0-59
    second: u8, // 0-59
    day_of_week: u8, // 1-7 (Sunday = 1)

    /// Convert to Unix timestamp (seconds since 1970-01-01 00:00:00 UTC)
    /// Note: Does not account for leap seconds
    pub fn toUnixTimestamp(self: *const DateTime) i64 {
        // Algorithm from Howard Hinnant's date library
        var y = @as(i32, @intCast(self.year));
        var m = @as(i32, @intCast(self.month));

        // Adjust for months before March (makes Feb the last month of prev year)
        if (m <= 2) {
            y -= 1;
            m += 12;
        }

        // Days since epoch
        const era = @divFloor(if (y >= 0) y else y - 399, 400);
        const yoe = y - era * 400;
        const doy = @divFloor((153 * (m - 3) + 2), 5) + @as(i32, @intCast(self.day)) - 1;
        const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        const days = era * 146097 + doe - 719468;

        return @as(i64, days) * 86400 +
            @as(i64, self.hour) * 3600 +
            @as(i64, self.minute) * 60 +
            @as(i64, self.second);
    }

    /// Create DateTime from Unix timestamp
    pub fn fromUnixTimestamp(timestamp: i64) DateTime {
        var secs = timestamp;
        var days = @divFloor(secs, 86400);
        secs = @mod(secs, 86400);
        if (secs < 0) {
            secs += 86400;
            days -= 1;
        }

        const hour: u8 = @intCast(@divFloor(secs, 3600));
        secs = @mod(secs, 3600);
        const minute: u8 = @intCast(@divFloor(secs, 60));
        const second: u8 = @intCast(@mod(secs, 60));

        // Civil date from days since epoch
        const z = days + 719468;
        const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
        const doe = z - era * 146097;
        const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        const y = yoe + era * 400;
        const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp = @divFloor(5 * doy + 2, 153);
        const day: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
        const month: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
        const year: u16 = @intCast(y + @as(i64, if (month <= 2) 1 else 0));

        // Day of week (0 = Sunday for Unix epoch, 1 = Sunday for RTC)
        const dow: u8 = @intCast(@mod(days + 4, 7) + 1);

        return .{
            .year = year,
            .month = month,
            .day = day,
            .hour = hour,
            .minute = minute,
            .second = second,
            .day_of_week = if (dow == 0) 7 else dow,
        };
    }
};

/// Spinlock for CMOS access (prevents concurrent reads/writes)
var cmos_lock: sync.Spinlock = .{};

/// Cached Status B for format detection
var status_b_cache: ?StatusB = null;

/// Alarm callback type
pub const AlarmCallback = *const fn () void;
var alarm_callback: ?AlarmCallback = null;

/// Periodic interrupt callback type
pub const PeriodicCallback = *const fn () void;
var periodic_callback: ?PeriodicCallback = null;

/// Whether RTC has been initialized
var initialized: bool = false;

// ============================================================================
// Low-Level CMOS Access
// ============================================================================

/// Read a CMOS register (preserves NMI mask bit)
fn readCmos(reg: u8) u8 {
    // Preserve NMI disable bit (bit 7 of address port)
    const nmi_disable = io.inb(CMOS_ADDR) & 0x80;
    io.outb(CMOS_ADDR, nmi_disable | (reg & 0x7F));
    io.ioWait(); // Some chipsets need a small delay
    return io.inb(CMOS_DATA);
}

/// Write a CMOS register (preserves NMI mask bit)
fn writeCmos(reg: u8, value: u8) void {
    const nmi_disable = io.inb(CMOS_ADDR) & 0x80;
    io.outb(CMOS_ADDR, nmi_disable | (reg & 0x7F));
    io.ioWait();
    io.outb(CMOS_DATA, value);
}

/// Wait for update cycle to complete (prevents reading during update)
/// Returns true if ready, false on timeout (should not happen on real hardware)
fn waitForUpdate() bool {
    var timeout: u32 = 10000;
    while (timeout > 0) : (timeout -= 1) {
        const status_a: StatusA = @bitCast(readCmos(REG_STATUS_A));
        if (status_a.update_in_progress == 0) {
            return true;
        }
    }
    return false;
}

/// Convert BCD to binary
fn bcdToBinary(bcd: u8) u8 {
    return (bcd & 0x0F) + ((bcd >> 4) * 10);
}

/// Convert binary to BCD
fn binaryToBcd(bin: u8) u8 {
    return ((bin / 10) << 4) | (bin % 10);
}

// ============================================================================
// Time Reading
// ============================================================================

/// Read current date/time from RTC
/// Uses double-read to ensure consistency (avoids reading during update)
pub fn readDateTime() DateTime {
    const held = cmos_lock.acquire();
    defer held.release();

    // Read Status B to determine format (if not cached)
    const status_b: StatusB = status_b_cache orelse @bitCast(readCmos(REG_STATUS_B));

    // Double-read until we get consistent values
    var dt1: DateTime = undefined;
    var dt2: DateTime = undefined;

    var attempts: u32 = 0;
    while (attempts < 10) : (attempts += 1) {
        _ = waitForUpdate();
        dt1 = readRawDateTime(status_b);
        _ = waitForUpdate();
        dt2 = readRawDateTime(status_b);

        // Compare all fields
        if (dt1.year == dt2.year and
            dt1.month == dt2.month and
            dt1.day == dt2.day and
            dt1.hour == dt2.hour and
            dt1.minute == dt2.minute and
            dt1.second == dt2.second)
        {
            return dt1;
        }
    }

    // Fallback to last read if consistency check keeps failing
    return dt2;
}

/// Internal read without locking (caller must hold lock)
fn readRawDateTime(status_b: StatusB) DateTime {
    var second = readCmos(REG_SECONDS);
    var minute = readCmos(REG_MINUTES);
    var hour = readCmos(REG_HOURS);
    var day = readCmos(REG_DAY_OF_MONTH);
    var month = readCmos(REG_MONTH);
    var year = readCmos(REG_YEAR);
    var century = readCmos(REG_CENTURY);
    const dow = readCmos(REG_DAY_OF_WEEK);

    // Convert BCD to binary if needed
    if (status_b.binary_mode == 0) {
        second = bcdToBinary(second);
        minute = bcdToBinary(minute);
        // Preserve PM bit for 12-hour format, convert rest
        hour = bcdToBinary(hour & 0x7F) | (hour & 0x80);
        day = bcdToBinary(day);
        month = bcdToBinary(month);
        year = bcdToBinary(year);
        century = bcdToBinary(century);
    }

    // Handle 12-hour format
    if (status_b.hour_format == 0) {
        const pm = (hour & 0x80) != 0;
        hour = hour & 0x7F;
        if (pm and hour != 12) {
            hour += 12;
        } else if (!pm and hour == 12) {
            hour = 0;
        }
    }

    // Combine century and year
    const full_year = @as(u16, century) * 100 + year;

    return .{
        .year = full_year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
        .day_of_week = dow,
    };
}

/// Get current Unix timestamp (seconds since epoch)
pub fn getUnixTimestamp() i64 {
    const dt = readDateTime();
    return dt.toUnixTimestamp();
}

// ============================================================================
// Time Writing
// ============================================================================

/// Write date/time to RTC
/// SECURITY: This is a privileged operation - caller must verify CAP_SYS_TIME
pub fn writeDateTime(dt: *const DateTime) void {
    const held = cmos_lock.acquire();
    defer held.release();

    // Get current format settings
    var status_b: StatusB = @bitCast(readCmos(REG_STATUS_B));

    // Inhibit updates during write
    status_b.update_inhibit = 1;
    writeCmos(REG_STATUS_B, @bitCast(status_b));

    // Prepare values
    var second = dt.second;
    var minute = dt.minute;
    var hour = dt.hour;
    var day = dt.day;
    var month = dt.month;
    var year: u8 = @truncate(dt.year % 100);
    var century: u8 = @truncate(dt.year / 100);

    // Handle 12-hour format if RTC is configured that way
    if (status_b.hour_format == 0) {
        var pm: u8 = 0;
        if (hour >= 12) {
            pm = 0x80;
            if (hour > 12) hour -= 12;
        } else if (hour == 0) {
            hour = 12;
        }
        hour |= pm;
    }

    // Convert to BCD if RTC expects it
    if (status_b.binary_mode == 0) {
        second = binaryToBcd(second);
        minute = binaryToBcd(minute);
        hour = binaryToBcd(hour & 0x7F) | (hour & 0x80);
        day = binaryToBcd(day);
        month = binaryToBcd(month);
        year = binaryToBcd(year);
        century = binaryToBcd(century);
    }

    // Write values
    writeCmos(REG_SECONDS, second);
    writeCmos(REG_MINUTES, minute);
    writeCmos(REG_HOURS, hour);
    writeCmos(REG_DAY_OF_MONTH, day);
    writeCmos(REG_MONTH, month);
    writeCmos(REG_YEAR, year);
    writeCmos(REG_CENTURY, century);
    writeCmos(REG_DAY_OF_WEEK, dt.day_of_week);

    // Re-enable updates
    status_b.update_inhibit = 0;
    writeCmos(REG_STATUS_B, @bitCast(status_b));
}

// ============================================================================
// Alarm and Periodic Interrupt Support
// ============================================================================

/// IRQ8 handler for RTC interrupts
fn rtcIrqHandler(_: u8) void {
    // Read Status C to acknowledge interrupt and determine source
    // Reading clears the interrupt flags
    const status_c: StatusC = @bitCast(readCmos(REG_STATUS_C));

    if (status_c.alarm == 1) {
        if (alarm_callback) |cb| {
            cb();
        }
    }

    if (status_c.periodic == 1) {
        if (periodic_callback) |cb| {
            cb();
        }
    }

    // Note: EOI is sent by the generic IRQ dispatcher
}

/// Set an alarm for a specific time
/// Use 0xFF for "don't care" fields (wildcard - alarm triggers every hour/minute/second)
/// Example: setAlarm(12, 0xFF, 0xFF, cb) triggers every minute at noon (12:xx:xx)
pub fn setAlarm(hour: u8, minute: u8, second: u8, callback: AlarmCallback) void {
    const held = cmos_lock.acquire();
    defer held.release();

    alarm_callback = callback;

    // Get current format
    var status_b: StatusB = @bitCast(readCmos(REG_STATUS_B));

    // Prepare alarm values (0xFF = wildcard, don't convert)
    var h = hour;
    var m = minute;
    var s = second;

    if (status_b.binary_mode == 0) {
        // Convert to BCD unless wildcard
        if (s != 0xFF) s = binaryToBcd(s);
        if (m != 0xFF) m = binaryToBcd(m);
        if (h != 0xFF) h = binaryToBcd(h);
    }

    // Write alarm registers
    writeCmos(REG_SECONDS_ALARM, s);
    writeCmos(REG_MINUTES_ALARM, m);
    writeCmos(REG_HOURS_ALARM, h);

    // Enable alarm interrupt
    status_b.alarm_int = 1;
    writeCmos(REG_STATUS_B, @bitCast(status_b));

    // Clear any pending interrupt
    _ = readCmos(REG_STATUS_C);
}

/// Disable alarm interrupt
pub fn disableAlarm() void {
    const held = cmos_lock.acquire();
    defer held.release();

    var status_b: StatusB = @bitCast(readCmos(REG_STATUS_B));
    status_b.alarm_int = 0;
    writeCmos(REG_STATUS_B, @bitCast(status_b));
    alarm_callback = null;
}

/// Periodic interrupt rates (register A rate_select field)
/// Frequency = 32768 >> (rate - 1)
pub const PeriodicRate = enum(u4) {
    off = 0, // Disabled
    // Rates 1-2 are invalid/reserved
    rate_122us = 3, // 8192 Hz (122.070 us period)
    rate_244us = 4, // 4096 Hz
    rate_488us = 5, // 2048 Hz
    rate_976us = 6, // 1024 Hz (976.562 us period)
    rate_1953us = 7, // 512 Hz
    rate_3906us = 8, // 256 Hz
    rate_7812us = 9, // 128 Hz
    rate_15625us = 10, // 64 Hz (15.625 ms period)
    rate_31250us = 11, // 32 Hz
    rate_62500us = 12, // 16 Hz
    rate_125ms = 13, // 8 Hz
    rate_250ms = 14, // 4 Hz
    rate_500ms = 15, // 2 Hz (500 ms period)
};

/// Enable periodic interrupts at specified rate
pub fn enablePeriodicInterrupt(rate: PeriodicRate, callback: PeriodicCallback) void {
    if (rate == .off or @intFromEnum(rate) < 3) return; // Invalid rates

    const held = cmos_lock.acquire();
    defer held.release();

    periodic_callback = callback;

    // Set rate in Status A
    var status_a: StatusA = @bitCast(readCmos(REG_STATUS_A));
    status_a.rate_select = @intFromEnum(rate);
    writeCmos(REG_STATUS_A, @bitCast(status_a));

    // Enable periodic interrupt in Status B
    var status_b: StatusB = @bitCast(readCmos(REG_STATUS_B));
    status_b.periodic_int = 1;
    writeCmos(REG_STATUS_B, @bitCast(status_b));

    // Clear any pending interrupt
    _ = readCmos(REG_STATUS_C);
}

/// Disable periodic interrupts
pub fn disablePeriodicInterrupt() void {
    const held = cmos_lock.acquire();
    defer held.release();

    var status_b: StatusB = @bitCast(readCmos(REG_STATUS_B));
    status_b.periodic_int = 0;
    writeCmos(REG_STATUS_B, @bitCast(status_b));

    var status_a: StatusA = @bitCast(readCmos(REG_STATUS_A));
    status_a.rate_select = 0;
    writeCmos(REG_STATUS_A, @bitCast(status_a));

    periodic_callback = null;
}

// ============================================================================
// Initialization
// ============================================================================

/// Initialize the RTC driver
/// - Reads initial Status B to cache format settings
/// - Registers IRQ8 handler
/// - Routes IRQ8 via APIC if available
pub fn init() void {
    console.info("RTC: Initializing CMOS Real-Time Clock...", .{});

    // Read and cache Status B (format detection)
    status_b_cache = @bitCast(readCmos(REG_STATUS_B));

    // Check battery status
    const status_d: StatusD = @bitCast(readCmos(REG_STATUS_D));
    if (status_d.valid_ram == 0) {
        console.warn("RTC: CMOS battery may be dead - time may be incorrect", .{});
    }

    // Read current time for sanity check/logging
    const dt = readDateTime();
    console.info("RTC: Current time: {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        dt.year,
        dt.month,
        dt.day,
        dt.hour,
        dt.minute,
        dt.second,
    });

    // Clear any pending interrupts (read Status C)
    _ = readCmos(REG_STATUS_C);

    // Register IRQ8 handler
    interrupts.setGenericIrqHandler(8, rtcIrqHandler);

    // Route IRQ8 via APIC if active, otherwise use PIC
    if (apic.isActive()) {
        const bsp_id: u8 = @truncate(apic.lapic.getId());
        apic.routeIrq(8, apic.Vectors.RTC, bsp_id);
        apic.enableIrq(8);
    } else {
        pic.enableIrq(8);
    }

    initialized = true;
    console.info("RTC: Initialization complete", .{});
}

/// Check if RTC has been initialized
pub fn isInitialized() bool {
    return initialized;
}

/// Read CMOS RAM byte at specified offset (0-127)
/// Note: Registers 0x00-0x0F are reserved for RTC; 0x10+ is general CMOS RAM
pub fn readCmosRam(offset: u8) u8 {
    if (offset >= 128) return 0;
    const held = cmos_lock.acquire();
    defer held.release();
    return readCmos(offset);
}

/// Write CMOS RAM byte at specified offset (use with caution)
/// Note: Writing to RTC registers (0x00-0x0F) may cause issues
pub fn writeCmosRam(offset: u8, value: u8) void {
    if (offset >= 128) return;
    if (offset <= 0x0F) return; // Don't allow direct RTC register writes
    const held = cmos_lock.acquire();
    defer held.release();
    writeCmos(offset, value);
}
