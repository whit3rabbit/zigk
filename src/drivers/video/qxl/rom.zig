//! QXL ROM Parser
//!
//! Parses the QXL ROM (BAR0) to enumerate available display modes.
//! The ROM is read-only and contains device capabilities and mode list.

const std = @import("std");
const hal = @import("hal");
const hw = @import("hardware.zig");
const console = @import("console");

/// Maximum number of modes to enumerate
pub const MAX_MODES: usize = 64;

/// Parsed mode information (simplified for driver use)
pub const ModeInfo = struct {
    /// Mode ID (for SET_MODE I/O command)
    id: u32,
    /// Width in pixels
    width: u32,
    /// Height in pixels
    height: u32,
    /// Bits per pixel
    bpp: u32,
    /// Bytes per scanline
    stride: u32,
};

/// ROM parser state
pub const RomParser = struct {
    /// Virtual address of ROM base (HHDM-mapped from BAR0)
    rom_base: [*]const volatile u8,

    /// ROM size (from BAR0 size)
    rom_size: usize,

    /// Cached mode list
    modes: [MAX_MODES]ModeInfo = undefined,
    mode_count: usize = 0,

    /// Whether ROM was successfully validated
    valid: bool = false,

    const Self = @This();

    /// Initialize ROM parser from physical BAR0 address
    pub fn init(bar0_phys: u64, bar0_size: usize) ?Self {
        if (bar0_phys == 0) {
            console.err("QXL ROM: BAR0 physical address is 0", .{});
            return null;
        }

        // Map ROM via HHDM
        const virt = hal.paging.physToVirt(bar0_phys);
        const rom_ptr: [*]const volatile u8 = @ptrCast(virt);

        var parser = Self{
            .rom_base = rom_ptr,
            .rom_size = bar0_size,
        };

        // Validate ROM magic
        if (!parser.validateMagic()) {
            console.err("QXL ROM: Invalid magic (expected 0x{x})", .{hw.ROM_MAGIC});
            return null;
        }

        parser.valid = true;

        // Parse mode list
        parser.parseModes();

        return parser;
    }

    /// Validate ROM magic number
    fn validateMagic(self: *Self) bool {
        if (self.rom_size < 4) return false;

        // Read magic as little-endian u32
        const magic = self.readU32(0);
        return magic == hw.ROM_MAGIC;
    }

    /// Read u32 from ROM at given byte offset
    fn readU32(self: *const Self, offset: usize) u32 {
        if (offset + 4 > self.rom_size) return 0;

        const ptr: *align(1) const volatile u32 = @ptrCast(self.rom_base + offset);
        return ptr.*;
    }

    /// Parse mode list from ROM
    fn parseModes(self: *Self) void {
        // Read number of modes
        const num_modes = self.readU32(hw.ROM_NUM_MODES_OFFSET);

        if (num_modes == 0 or num_modes > MAX_MODES) {
            console.warn("QXL ROM: Invalid mode count: {d}", .{num_modes});
            return;
        }

        // Check if modes array fits within ROM
        const modes_end = std.math.mul(usize, num_modes, @sizeOf(hw.QxlMode)) catch {
            console.warn("QXL ROM: Mode array size overflow", .{});
            return;
        };
        const total_size = std.math.add(usize, hw.ROM_MODES_OFFSET, modes_end) catch {
            console.warn("QXL ROM: Total size overflow", .{});
            return;
        };

        if (total_size > self.rom_size) {
            console.warn("QXL ROM: Mode array exceeds ROM size", .{});
            return;
        }

        // Parse each mode
        var valid_count: usize = 0;
        for (0..num_modes) |i| {
            const mode_offset = std.math.mul(usize, i, @sizeOf(hw.QxlMode)) catch continue;
            const offset = std.math.add(usize, hw.ROM_MODES_OFFSET, mode_offset) catch continue;

            const mode = self.parseMode(offset) orelse continue;

            // Validate mode parameters
            if (mode.width < hw.MIN_WIDTH or mode.width > hw.MAX_WIDTH) continue;
            if (mode.height < hw.MIN_HEIGHT or mode.height > hw.MAX_HEIGHT) continue;
            if (!hw.isValidBpp(@intCast(mode.bpp))) continue;

            // Store valid mode
            if (valid_count < MAX_MODES) {
                self.modes[valid_count] = mode;
                valid_count += 1;
            }
        }

        self.mode_count = valid_count;
        console.info("QXL ROM: Found {d} valid modes", .{valid_count});
    }

    /// Parse a single mode entry from ROM
    fn parseMode(self: *const Self, offset: usize) ?ModeInfo {
        if (offset + @sizeOf(hw.QxlMode) > self.rom_size) return null;

        const mode_ptr: *align(1) const volatile hw.QxlMode = @ptrCast(self.rom_base + offset);

        return ModeInfo{
            .id = mode_ptr.id,
            .width = mode_ptr.x_res,
            .height = mode_ptr.y_res,
            .bpp = mode_ptr.bits,
            .stride = mode_ptr.stride,
        };
    }

    /// Find a mode matching the requested resolution and depth
    /// Returns the mode ID if found, null otherwise
    pub fn findMode(self: *const Self, width: u32, height: u32, bpp: u32) ?u32 {
        for (self.modes[0..self.mode_count]) |mode| {
            if (mode.width == width and mode.height == height and mode.bpp == bpp) {
                return mode.id;
            }
        }

        // If exact match not found, try to find matching resolution with 32bpp
        if (bpp != 32) {
            for (self.modes[0..self.mode_count]) |mode| {
                if (mode.width == width and mode.height == height and mode.bpp == 32) {
                    return mode.id;
                }
            }
        }

        return null;
    }

    /// Find the best mode for given resolution (any bpp)
    pub fn findBestMode(self: *const Self, width: u32, height: u32) ?ModeInfo {
        var best: ?ModeInfo = null;
        var best_bpp: u32 = 0;

        for (self.modes[0..self.mode_count]) |mode| {
            if (mode.width == width and mode.height == height) {
                // Prefer higher bpp
                if (mode.bpp > best_bpp) {
                    best = mode;
                    best_bpp = mode.bpp;
                }
            }
        }

        return best;
    }

    /// Get mode by index (for enumeration)
    pub fn getMode(self: *const Self, index: usize) ?ModeInfo {
        if (index >= self.mode_count) return null;
        return self.modes[index];
    }

    /// Get total number of valid modes
    pub fn getModeCount(self: *const Self) usize {
        return self.mode_count;
    }

    /// Find default mode (typically 1024x768x32)
    pub fn findDefaultMode(self: *const Self) ?ModeInfo {
        // Try common default resolutions in order of preference
        const defaults = [_]struct { w: u32, h: u32 }{
            .{ .w = 1024, .h = 768 },
            .{ .w = 800, .h = 600 },
            .{ .w = 1280, .h = 1024 },
            .{ .w = 1920, .h = 1080 },
            .{ .w = 640, .h = 480 },
        };

        for (defaults) |res| {
            if (self.findBestMode(res.w, res.h)) |mode| {
                return mode;
            }
        }

        // Fall back to first available mode
        if (self.mode_count > 0) {
            return self.modes[0];
        }

        return null;
    }

    /// Log all available modes (for debugging)
    pub fn logModes(self: *const Self) void {
        console.info("QXL ROM: Available modes:", .{});
        for (self.modes[0..self.mode_count], 0..) |mode, i| {
            console.info("  [{d}] id={d}: {d}x{d}x{d} (stride={d})", .{
                i, mode.id, mode.width, mode.height, mode.bpp, mode.stride,
            });
        }
    }
};
