//! VMware SVGA FIFO Management
//!
//! Provides safe abstraction over the SVGA command FIFO ring buffer.
//! Handles space reservation, wraparound, and synchronization.

const std = @import("std");
const hw = @import("hardware.zig");
const regs = @import("regs.zig");

/// FIFO management errors
pub const FifoError = error{
    /// Not enough space in FIFO for command
    FifoFull,
    /// FIFO not initialized
    NotInitialized,
    /// Invalid command size
    InvalidSize,
    /// Timeout waiting for FIFO space
    Timeout,
};

/// FIFO manager for SVGA command submission
pub const FifoManager = struct {
    /// Pointer to FIFO memory (volatile for hardware access), null if disabled
    virt: ?[*]volatile u32,
    /// Total FIFO memory size in bytes
    size: u32,
    /// Whether FIFO is properly initialized
    initialized: bool,

    const Self = @This();

    /// Initialize FIFO manager with mapped memory
    pub fn init(virt_addr: [*]u32, fifo_size: u32) Self {
        return .{
            .virt = @ptrCast(virt_addr),
            .size = fifo_size,
            .initialized = false,
        };
    }

    /// Initialize an empty/disabled FIFO manager
    pub fn initEmpty() Self {
        return .{
            .virt = null,
            .size = 0,
            .initialized = false,
        };
    }

    /// Initialize FIFO header structure
    /// Must be called before any commands can be submitted
    pub fn initHeader(self: *Self) void {
        const virt = self.virt orelse return; // Can't init without valid pointer

        // FIFO header is 4 u32 words = 16 bytes
        const fifo_header_size: u32 = 4 * @sizeOf(u32);

        // MIN: byte offset where commands start (after header)
        virt[hw.FIFO_MIN] = fifo_header_size;

        // MAX: byte offset of end of FIFO
        virt[hw.FIFO_MAX] = self.size;

        // NEXT_CMD: byte offset to write next command (starts at MIN)
        virt[hw.FIFO_NEXT_CMD] = fifo_header_size;

        // STOP: byte offset where host has read to (starts at MIN)
        virt[hw.FIFO_STOP] = fifo_header_size;

        self.initialized = true;
    }

    /// Get available space in FIFO (in bytes)
    pub fn availableSpace(self: *const Self) u32 {
        const virt = self.virt orelse return 0;

        const min = virt[hw.FIFO_MIN];
        const max = virt[hw.FIFO_MAX];
        const next_cmd = virt[hw.FIFO_NEXT_CMD];
        const stop = virt[hw.FIFO_STOP];

        if (next_cmd >= stop) {
            // next_cmd is ahead of stop: available = (max - next_cmd) + (stop - min)
            return (max - next_cmd) + (stop - min);
        } else {
            // stop is ahead: available = stop - next_cmd
            return stop - next_cmd;
        }
    }

    /// Check if FIFO has enough space for a command
    pub fn hasSpace(self: *const Self, cmd_size_bytes: u32) bool {
        // Need extra word for potential NOP on wraparound
        const needed = std.math.add(u32, cmd_size_bytes, 4) catch return false;
        return self.availableSpace() >= needed;
    }

    /// Reserve space in FIFO for a command
    /// Returns slice to write command data, or error if insufficient space
    pub fn reserve(self: *Self, cmd_size_bytes: u32) FifoError![]volatile u32 {
        if (!self.initialized) return error.NotInitialized;
        if (cmd_size_bytes == 0) return error.InvalidSize;

        const virt = self.virt orelse return error.NotInitialized;

        // Validate command size is word-aligned
        if (cmd_size_bytes % 4 != 0) return error.InvalidSize;

        const min = virt[hw.FIFO_MIN];
        const max = virt[hw.FIFO_MAX];
        var next_cmd = virt[hw.FIFO_NEXT_CMD];
        const stop = virt[hw.FIFO_STOP];

        // Calculate available space
        const available = if (next_cmd >= stop)
            (max - next_cmd) + (stop - min)
        else
            stop - next_cmd;

        // Need space for command plus potential wraparound
        if (available < cmd_size_bytes) return error.FifoFull;

        // Check if we need to wrap around
        if (next_cmd + cmd_size_bytes > max) {
            // Not enough contiguous space at end - check if we can wrap
            if (stop - min < cmd_size_bytes) return error.FifoFull;

            // Fill remaining space with NOP/padding and wrap
            // Write remaining bytes as zeros (acts as padding)
            const remaining_words = (max - next_cmd) / 4;
            var i: u32 = 0;
            while (i < remaining_words) : (i += 1) {
                const idx = (next_cmd / 4) + i;
                virt[idx] = 0;
            }

            // Wrap to beginning
            next_cmd = min;
            virt[hw.FIFO_NEXT_CMD] = next_cmd;
        }

        // Return slice at current position
        const word_offset = next_cmd / 4;
        const word_count = cmd_size_bytes / 4;

        // Bounds check
        if (word_offset + word_count > self.size / 4) return error.InvalidSize;

        return virt[word_offset .. word_offset + word_count];
    }

    /// Commit command after writing to reserved space
    /// new_offset is the byte offset after the command
    pub fn commit(self: *Self, cmd_size_bytes: u32) void {
        const virt = self.virt orelse return;

        const next_cmd = virt[hw.FIFO_NEXT_CMD];
        const max = virt[hw.FIFO_MAX];
        const min = virt[hw.FIFO_MIN];

        var new_next = std.math.add(u32, next_cmd, cmd_size_bytes) catch {
            // Overflow - this shouldn't happen if reserve was called correctly
            return;
        };

        // Handle wraparound
        if (new_next >= max) {
            new_next = min + (new_next - max);
        }

        // Update NEXT_CMD pointer
        virt[hw.FIFO_NEXT_CMD] = new_next;

        // Memory barrier to ensure writes are visible to device
        regs.memoryBarrier();
    }

    /// Write a complete command to FIFO
    /// Returns true on success, false if FIFO is full
    pub fn writeCommand(self: *Self, cmd_data: []const u32) bool {
        const cmd_size = std.math.mul(u32, @intCast(cmd_data.len), 4) catch return false;

        const slice = self.reserve(cmd_size) catch return false;

        // Copy command data
        for (cmd_data, 0..) |word, i| {
            slice[i] = word;
        }

        self.commit(cmd_size);
        return true;
    }

    /// Write Update command (notify host of dirty rectangle)
    pub fn writeUpdate(self: *Self, x: u32, y: u32, w: u32, h: u32) bool {
        const cmd = [_]u32{
            @intFromEnum(hw.Cmd.Update),
            x,
            y,
            w,
            h,
        };
        return self.writeCommand(&cmd);
    }

    /// Write RectFill command (hardware-accelerated fill)
    pub fn writeRectFill(self: *Self, color: u32, x: u32, y: u32, w: u32, h: u32) bool {
        const cmd = [_]u32{
            @intFromEnum(hw.Cmd.RectFill),
            color,
            x,
            y,
            w,
            h,
        };
        return self.writeCommand(&cmd);
    }

    /// Write RectCopy command (hardware-accelerated copy)
    pub fn writeRectCopy(
        self: *Self,
        src_x: u32,
        src_y: u32,
        dst_x: u32,
        dst_y: u32,
        w: u32,
        h: u32,
    ) bool {
        const cmd = [_]u32{
            @intFromEnum(hw.Cmd.RectCopy),
            src_x,
            src_y,
            dst_x,
            dst_y,
            w,
            h,
        };
        return self.writeCommand(&cmd);
    }

    /// Write Fence command for synchronization
    pub fn writeFence(self: *Self, fence_id: u32) bool {
        const cmd = [_]u32{
            @intFromEnum(hw.Cmd.Fence),
            fence_id,
        };
        return self.writeCommand(&cmd);
    }

    /// Write DefineAlphaCursor command
    /// pixels must be ARGB8888 format, length = width * height
    pub fn writeDefineAlphaCursor(
        self: *Self,
        id: u32,
        hotspot_x: u32,
        hotspot_y: u32,
        width: u32,
        height: u32,
        pixels: []const u32,
    ) bool {
        // Validate dimensions
        if (width > hw.MAX_CURSOR_WIDTH or height > hw.MAX_CURSOR_HEIGHT) return false;

        const pixel_count = std.math.mul(u32, width, height) catch return false;
        if (pixels.len < pixel_count) return false;

        // Calculate total command size
        const header_size = hw.CMD_DEFINE_ALPHA_CURSOR_HEADER_SIZE;
        const data_size = std.math.mul(u32, pixel_count, 4) catch return false;
        const total_size = std.math.add(u32, header_size, data_size) catch return false;

        // Reserve space
        const slice = self.reserve(total_size) catch return false;

        // Write header
        slice[0] = @intFromEnum(hw.Cmd.DefineAlphaCursor);
        slice[1] = id;
        slice[2] = hotspot_x;
        slice[3] = hotspot_y;
        slice[4] = width;
        slice[5] = height;

        // Write pixel data
        for (pixels[0..pixel_count], 0..) |pixel, i| {
            slice[6 + i] = pixel;
        }

        self.commit(total_size);
        return true;
    }

    /// Check if host is currently processing commands
    pub fn isBusy(self: *const Self) bool {
        const virt = self.virt orelse return false;
        const next_cmd = virt[hw.FIFO_NEXT_CMD];
        const stop = virt[hw.FIFO_STOP];
        return next_cmd != stop;
    }

    /// Wait for all commands to complete (blocking)
    /// Returns false if timeout exceeded
    pub fn waitForIdle(self: *const Self, max_iterations: u32) bool {
        var i: u32 = 0;
        while (i < max_iterations) : (i += 1) {
            if (!self.isBusy()) return true;
            // Brief pause (prevents tight spin)
            regs.cpuPause();
        }
        return false;
    }
};

// Unit tests
test "fifo space calculation" {
    // Create a mock FIFO buffer
    var buffer: [256]u32 = undefined;
    var fifo = FifoManager.init(&buffer, 256 * 4);
    fifo.initHeader();

    // Initial state: all space available except header
    const header_size: u32 = 16;
    const expected_space = (256 * 4) - header_size;
    try std.testing.expect(fifo.availableSpace() >= expected_space - 4);
}
