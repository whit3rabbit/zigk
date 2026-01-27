//! Cirrus Logic CL-GD5446 VGA Driver
//!
//! Implements the GraphicsDevice interface for the Cirrus Logic CL-GD5446 VGA adapter,
//! commonly used in QEMU with -vga cirrus. Supports SVGA modes with linear framebuffer.
//!
//! Features:
//! - Linear framebuffer via PCI BAR1
//! - Mode switching (640x480, 800x600, 1024x768)
//! - 16/24/32-bit color depth support
//! - Software rendering (no hardware acceleration in this version)

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal");
const pci = @import("pci");
const interface = @import("../interface.zig");
const hw = @import("hardware.zig");
const regs = @import("regs.zig");
const console = @import("console");

pub const CirrusDriver = struct {
    /// Framebuffer physical address (BAR1)
    framebuffer_phys: u64,

    /// Framebuffer virtual address (mapped via HHDM)
    framebuffer_virt: [*]u32,

    /// Total VRAM size in bytes (4MB for GD5446)
    vram_size: u32,

    /// Current display state
    width: u32 = 0,
    height: u32 = 0,
    bpp: u32 = 32,
    pitch: u32 = 0,

    /// PCI device info (for reference)
    pci_dev: ?pci.PciDevice = null,

    const Self = @This();

    // Global instance (single GPU assumption)
    var instance: Self = undefined;
    var initialized: bool = false;

    /// Initialize the Cirrus VGA driver
    /// Returns pointer to driver instance on success, null on failure
    pub fn init() ?*Self {
        // Prevent double initialization
        if (initialized) return &instance;

        // Cirrus uses VGA I/O ports, only supported on x86_64
        if (builtin.cpu.arch != .x86_64) {
            return null;
        }

        // 1. Find PCI device
        const devices = pci.getDevices() orelse {
            console.warn("Cirrus: PCI devices not available", .{});
            return null;
        };

        var cirrus_dev: ?pci.PciDevice = null;
        for (devices.devices[0..devices.count]) |*dev| {
            if (dev.vendor_id == hw.PCI_VENDOR_ID_CIRRUS and
                dev.device_id == hw.PCI_DEVICE_ID_GD5446)
            {
                cirrus_dev = dev.*;
                break;
            }
        }

        const dev = cirrus_dev orelse {
            // Not an error - device simply not present
            return null;
        };

        console.info("Cirrus: Found CL-GD5446 at PCI {x}:{x}.{}", .{
            dev.bus,
            dev.device,
            dev.func,
        });

        // 2. Verify Cirrus chip responds correctly
        if (!regs.RegisterAccess.detectCirrus()) {
            console.err("Cirrus: Chip detection failed (SR7 unlock test)", .{});
            return null;
        }

        // 3. Get BAR1 for linear framebuffer
        const bar1 = dev.bar[hw.BAR_LFB];
        if (bar1.base == 0) {
            console.err("Cirrus: BAR1 (framebuffer) not configured", .{});
            return null;
        }

        // 4. Enable Bus Mastering and Memory Space access
        if (pci.getEcam()) |ecam| {
            const cmd_reg = ecam.read16(dev.bus, dev.device, dev.func, 0x04);
            // Enable Memory (bit 1), Bus Master (bit 2)
            ecam.write16(dev.bus, dev.device, dev.func, 0x04, cmd_reg | 0x6);
        }

        // 5. Map framebuffer
        instance.framebuffer_phys = bar1.base & 0xFFFFFFF0;
        instance.framebuffer_virt = @ptrFromInt(@intFromPtr(hal.paging.physToVirt(instance.framebuffer_phys)));
        instance.pci_dev = dev;

        // 6. Set VRAM size (GD5446 has 4MB)
        instance.vram_size = hw.DEFAULT_VRAM_SIZE;

        console.info("Cirrus: Framebuffer at phys 0x{x}, VRAM={} KB", .{
            instance.framebuffer_phys,
            instance.vram_size / 1024,
        });

        // 7. Unlock Cirrus extended registers
        regs.RegisterAccess.unlockCirrus();

        initialized = true;
        console.info("Cirrus: Driver initialized successfully", .{});

        return &instance;
    }

    /// Get GraphicsDevice interface
    pub fn device(self: *Self) interface.GraphicsDevice {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = interface.GraphicsDevice.VTable{
        .getMode = getMode,
        .putPixel = putPixel,
        .fillRect = fillRect,
        .drawBuffer = drawBuffer,
        .copyRect = copyRect,
        .present = present,
    };

    /// Set display mode
    pub fn setMode(self: *Self, w: u32, h: u32, bpp: u32) void {
        // Validate dimensions
        if (w == 0 or h == 0) return;
        if (w < hw.MIN_WIDTH or w > hw.MAX_WIDTH) return;
        if (h < hw.MIN_HEIGHT or h > hw.MAX_HEIGHT) return;
        if (!hw.isValidBpp(@intCast(bpp))) return;

        // Calculate required framebuffer size with overflow protection
        const bytes_per_pixel: u32 = hw.bytesPerPixel(@intCast(bpp));
        const row_size = std.math.mul(u32, w, bytes_per_pixel) catch {
            console.err("Cirrus: Overflow calculating row size", .{});
            return;
        };
        const fb_size = std.math.mul(u32, row_size, h) catch {
            console.err("Cirrus: Overflow calculating framebuffer size", .{});
            return;
        };

        // Check against available VRAM
        if (fb_size > self.vram_size) {
            console.err("Cirrus: Requested mode exceeds VRAM ({} > {})", .{ fb_size, self.vram_size });
            return;
        }

        // Get timing for this mode
        const timing = hw.getModeTiming(@intCast(w), @intCast(h), @intCast(bpp)) orelse {
            console.err("Cirrus: Unsupported mode {}x{}", .{ w, h });
            return;
        };

        // Unlock Cirrus extensions
        regs.RegisterAccess.unlockCirrus();

        // Unlock CRTC for programming
        regs.RegisterAccess.unlockCrtc();

        // Disable video during mode switch
        regs.RegisterAccess.disableVideo();

        // Set Sequencer registers for graphics mode
        regs.RegisterAccess.writeSeq(.RESET, 0x01);        // Async reset
        regs.RegisterAccess.writeSeq(.CLOCKING_MODE, 0x01); // 8-dot clocks
        regs.RegisterAccess.writeSeq(.MAP_MASK, 0x0F);      // Enable all planes
        regs.RegisterAccess.writeSeq(.CHAR_MAP, 0x00);      // No character map
        regs.RegisterAccess.writeSeq(.MEMORY_MODE, 0x06);   // Chain 4, extended memory

        // Enable linear framebuffer
        regs.RegisterAccess.enableLinearFramebuffer();

        // Set Hidden DAC mode for color depth
        regs.RegisterAccess.writeHiddenDacMode(hw.getHiddenDacMode(@intCast(bpp)));

        // Program CRTC timing
        regs.RegisterAccess.programTiming(timing);

        // Clear reset
        regs.RegisterAccess.writeSeq(.RESET, 0x03);

        // Enable video output
        regs.RegisterAccess.enableVideo();

        // Update driver state
        self.width = w;
        self.height = h;
        self.bpp = bpp;
        self.pitch = row_size;

        // Clear screen
        const total_pixels = std.math.mul(u32, w, h) catch return;
        const max_pixels = self.vram_size / 4;
        const safe_pixels = @min(total_pixels, max_pixels);

        if (safe_pixels > 0) {
            @memset(self.framebuffer_virt[0..safe_pixels], 0);
        }

        console.info("Cirrus: Mode set to {}x{}x{} (pitch={})", .{ w, h, bpp, self.pitch });
    }

    // GraphicsDevice interface implementations

    fn getMode(ctx: *anyopaque) interface.VideoMode {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return .{
            .width = self.width,
            .height = self.height,
            .pitch = self.pitch,
            .bpp = @intCast(self.bpp),
            .addr = @intFromPtr(self.framebuffer_virt),
        };
    }

    fn putPixel(ctx: *anyopaque, x: u32, y: u32, color: interface.Color) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (x >= self.width or y >= self.height) return;

        const stride = self.pitch / 4;
        const offset = std.math.mul(u32, y, stride) catch return;
        const pixel_offset = std.math.add(u32, offset, x) catch return;

        const max_offset = self.vram_size / 4;
        if (pixel_offset >= max_offset) return;

        const val: u32 = (@as(u32, color.r) << 16) | (@as(u32, color.g) << 8) | color.b;
        self.framebuffer_virt[pixel_offset] = val;
    }

    fn fillRect(ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, color: interface.Color) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Bounds checking - clip to screen dimensions
        if (x >= self.width or y >= self.height) return;
        const clip_w = if (x + w > self.width) self.width - x else w;
        const clip_h = if (y + h > self.height) self.height - y else h;
        if (clip_w == 0 or clip_h == 0) return;

        const pixel_color: u32 = (@as(u32, color.r) << 16) | (@as(u32, color.g) << 8) | color.b;

        const stride = self.pitch / 4;
        const max_offset = self.vram_size / 4;

        var row: u32 = 0;
        while (row < clip_h) : (row += 1) {
            const start = std.math.mul(u32, y + row, stride) catch return;
            const offset = std.math.add(u32, start, x) catch return;
            const end = std.math.add(u32, offset, clip_w) catch return;

            if (end > max_offset) return;

            @memset(self.framebuffer_virt[offset..end], pixel_color);
        }
    }

    fn drawBuffer(ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, buf: []const u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Bounds checking - clip to screen dimensions
        if (x >= self.width or y >= self.height) return;
        const clip_w = if (x + w > self.width) self.width - x else w;
        const clip_h = if (y + h > self.height) self.height - y else h;
        if (clip_w == 0 or clip_h == 0) return;

        // Validate source buffer size
        const required_buf_size = std.math.mul(u32, h, w) catch return;
        if (buf.len < required_buf_size) return;

        const stride = self.pitch / 4;
        const max_offset = self.vram_size / 4;

        var row: u32 = 0;
        while (row < clip_h) : (row += 1) {
            const fb_start = std.math.mul(u32, y + row, stride) catch return;
            const fb_off = std.math.add(u32, fb_start, x) catch return;
            const fb_end = std.math.add(u32, fb_off, clip_w) catch return;

            if (fb_end > max_offset) return;

            const buf_off = row * w;
            @memcpy(self.framebuffer_virt[fb_off..fb_end], buf[buf_off .. buf_off + clip_w]);
        }
    }

    fn copyRect(ctx: *anyopaque, src_x: u32, src_y: u32, dst_x: u32, dst_y: u32, w: u32, h: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Bounds checking
        if (src_x >= self.width or src_y >= self.height) return;
        if (dst_x >= self.width or dst_y >= self.height) return;

        const clip_w = @min(w, @min(self.width - src_x, self.width - dst_x));
        const clip_h = @min(h, @min(self.height - src_y, self.height - dst_y));
        if (clip_w == 0 or clip_h == 0) return;

        const stride = self.pitch / 4;
        const max_offset = self.vram_size / 4;

        // Determine copy direction to handle overlapping regions
        const copy_forward = (dst_y < src_y) or (dst_y == src_y and dst_x <= src_x);

        if (copy_forward) {
            var row: u32 = 0;
            while (row < clip_h) : (row += 1) {
                const src_start = std.math.mul(u32, src_y + row, stride) catch return;
                const src_off = std.math.add(u32, src_start, src_x) catch return;
                const dst_start = std.math.mul(u32, dst_y + row, stride) catch return;
                const dst_off = std.math.add(u32, dst_start, dst_x) catch return;

                if (src_off + clip_w > max_offset or dst_off + clip_w > max_offset) return;

                // Manual copy for overlapping support
                const src_slice = self.framebuffer_virt[src_off .. src_off + clip_w];
                const dst_slice = self.framebuffer_virt[dst_off .. dst_off + clip_w];

                var i: u32 = 0;
                while (i < clip_w) : (i += 1) {
                    dst_slice[i] = src_slice[i];
                }
            }
        } else {
            // Copy backward (from last row to first)
            var row: u32 = clip_h;
            while (row > 0) {
                row -= 1;
                const src_start = std.math.mul(u32, src_y + row, stride) catch return;
                const src_off = std.math.add(u32, src_start, src_x) catch return;
                const dst_start = std.math.mul(u32, dst_y + row, stride) catch return;
                const dst_off = std.math.add(u32, dst_start, dst_x) catch return;

                if (src_off + clip_w > max_offset or dst_off + clip_w > max_offset) return;

                // Copy backward within row
                var i: u32 = clip_w;
                while (i > 0) {
                    i -= 1;
                    self.framebuffer_virt[dst_off + i] = self.framebuffer_virt[src_off + i];
                }
            }
        }
    }

    fn present(ctx: *anyopaque, dirty_rect: ?interface.Rect) void {
        // Cirrus does not require explicit presentation - framebuffer writes
        // are immediately visible. This is a no-op but kept for interface
        // compatibility.
        _ = ctx;
        _ = dirty_rect;
    }
};
