//! Bochs VGA (BGA) Driver
//!
//! Implements the GraphicsDevice interface for the Bochs Graphics Adapter,
//! commonly used in QEMU and Bochs emulators. Supports VBE DISPI extensions
//! for resolution switching and linear framebuffer access.
//!
//! Architecture support:
//! - x86_64: Uses I/O port space (legacy VBE DISPI interface)
//! - aarch64: Uses MMIO (BAR2 + 0x500 offset)

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal");
const pci = @import("pci");
const interface = @import("../interface.zig");
const hw = @import("hardware.zig");
const regs = @import("regs.zig");
const console = @import("console");

pub const BgaDriver = struct {
    /// Register access abstraction (handles both port I/O and MMIO)
    reg_access: regs.RegisterAccess,

    /// Framebuffer physical address (BAR2)
    framebuffer_phys: u64,

    /// Framebuffer virtual address (mapped via HHDM)
    framebuffer_virt: [*]u32,

    /// Total VRAM size in bytes
    vram_size: u32,

    /// BGA version ID (0xB0C0-0xB0C5)
    version: u16,

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

    /// Initialize the BGA driver
    /// Returns pointer to driver instance on success, null on failure
    pub fn init() ?*Self {
        // Prevent double initialization
        if (initialized) return &instance;

        // 1. Find PCI device
        const devices = pci.getDevices() orelse {
            console.warn("BGA: PCI devices not available", .{});
            return null;
        };

        var bga_dev: ?pci.PciDevice = null;
        for (devices.devices[0..devices.count]) |*dev| {
            if (dev.vendor_id == hw.PCI_VENDOR_ID_BOCHS and
                dev.device_id == hw.PCI_DEVICE_ID_BGA)
            {
                bga_dev = dev.*;
                break;
            }
        }

        const dev = bga_dev orelse {
            // Not an error - device simply not present
            return null;
        };

        console.info("BGA: Found Bochs VGA device at PCI {x}:{x}.{}", .{
            dev.bus,
            dev.device,
            dev.func,
        });

        // 2. Get BAR2 for framebuffer
        const bar2 = dev.bar[hw.BAR_LFB];
        if (bar2.base == 0) {
            console.err("BGA: BAR2 (framebuffer) not configured", .{});
            return null;
        }

        // 3. Enable Bus Mastering and Memory Space access
        if (pci.getEcam()) |ecam| {
            const cmd_reg = ecam.read16(dev.bus, dev.device, dev.func, 0x04);
            // Enable Memory (bit 1), Bus Master (bit 2)
            ecam.write16(dev.bus, dev.device, dev.func, 0x04, cmd_reg | 0x6);
        }

        // 4. Initialize register access (auto-select mode based on architecture)
        const reg_access = regs.RegisterAccess.initAuto(bar2.base) orelse {
            console.err("BGA: Failed to initialize register access", .{});
            return null;
        };

        // Log access mode
        if (reg_access.mode == .port_io) {
            console.info("BGA: Using I/O port access (0x{x}/0x{x})", .{
                hw.VBE_DISPI_IOPORT_INDEX,
                hw.VBE_DISPI_IOPORT_DATA,
            });
        } else {
            console.info("BGA: Using MMIO access at 0x{x}", .{reg_access.base});
        }

        instance.reg_access = reg_access;
        instance.pci_dev = dev;

        // 5. Detect and negotiate version
        const version = instance.reg_access.detectVersion() orelse {
            console.err("BGA: Device not responding (ID register check failed)", .{});
            return null;
        };

        instance.version = version;
        console.info("BGA: Detected version 0x{x}", .{version});

        // 6. Map framebuffer
        instance.framebuffer_phys = bar2.base & 0xFFFFFFF0;
        instance.framebuffer_virt = @ptrFromInt(@intFromPtr(hal.paging.physToVirt(instance.framebuffer_phys)));

        // 7. Estimate VRAM size (QEMU default is 16MB)
        // In version 0xB0C4+, we could query VRAM size, but for now use default
        instance.vram_size = @truncate(hw.DEFAULT_VRAM_SIZE);

        console.info("BGA: Framebuffer at phys 0x{x}, VRAM={} KB", .{
            instance.framebuffer_phys,
            instance.vram_size / 1024,
        });

        initialized = true;
        console.info("BGA: Driver initialized successfully", .{});

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
            console.err("BGA: Overflow calculating row size", .{});
            return;
        };
        const fb_size = std.math.mul(u32, row_size, h) catch {
            console.err("BGA: Overflow calculating framebuffer size", .{});
            return;
        };

        // Check against available VRAM
        if (fb_size > self.vram_size) {
            console.err("BGA: Requested mode exceeds VRAM ({} > {})", .{ fb_size, self.vram_size });
            return;
        }

        // Disable display while changing mode
        self.reg_access.write(.ENABLE, hw.VBE_DISPI_DISABLED);

        // Set resolution and depth
        self.reg_access.write(.XRES, @intCast(w));
        self.reg_access.write(.YRES, @intCast(h));
        self.reg_access.write(.BPP, @intCast(bpp));

        // Set virtual dimensions to match physical (no panning)
        self.reg_access.write(.VIRT_WIDTH, @intCast(w));
        self.reg_access.write(.VIRT_HEIGHT, @intCast(h));

        // Reset offsets
        self.reg_access.write(.X_OFFSET, 0);
        self.reg_access.write(.Y_OFFSET, 0);

        // Enable display with linear framebuffer mode
        self.reg_access.write(.ENABLE, hw.VBE_DISPI_ENABLED_LFB);

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

        console.info("BGA: Mode set to {}x{}x{} (pitch={})", .{ w, h, bpp, self.pitch });
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
        // BGA does not require explicit presentation - framebuffer writes
        // are immediately visible. This is a no-op but kept for interface
        // compatibility.
        _ = ctx;
        _ = dirty_rect;
    }

    /// Get BGA version string for logging
    pub fn getVersionString(self: *const Self) []const u8 {
        return switch (self.version) {
            hw.VBE_DISPI_ID0 => "VBE DISPI 0 (original)",
            hw.VBE_DISPI_ID1 => "VBE DISPI 1 (virtual width/height)",
            hw.VBE_DISPI_ID2 => "VBE DISPI 2 (32-bit BPP)",
            hw.VBE_DISPI_ID3 => "VBE DISPI 3 (preserve memory)",
            hw.VBE_DISPI_ID4 => "VBE DISPI 4 (VRAM query)",
            hw.VBE_DISPI_ID5 => "VBE DISPI 5 (current)",
            else => "unknown",
        };
    }
};
