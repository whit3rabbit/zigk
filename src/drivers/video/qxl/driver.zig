//! QXL Graphics Driver
//!
//! Implements the GraphicsDevice interface for the QXL paravirtualized GPU.
//! Used in QEMU/KVM with "-vga qxl" or "-device qxl" options.
//!
//! Phase 1 Implementation: Framebuffer-only mode
//! - Uses ROM for mode enumeration
//! - Uses I/O ports for mode setting
//! - Direct framebuffer access (no command rings yet)
//!
//! Future phases would add:
//! - Command ring for 2D acceleration
//! - Cursor support
//! - Multiple surfaces

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal");
const pci = @import("pci");
const interface = @import("../interface.zig");
const hw = @import("hardware.zig");
const rom = @import("rom.zig");
const regs = @import("regs.zig");
const ram = @import("ram.zig");
const drawable = @import("drawable.zig");
const commands = @import("commands.zig");
const console = @import("console");

pub const QxlDriver = struct {
    /// I/O port access
    io: regs.IoAccess,

    /// ROM parser (for mode enumeration)
    rom_parser: rom.RomParser,

    /// Framebuffer physical address (BAR1)
    framebuffer_phys: u64,

    /// Framebuffer virtual address (mapped via HHDM)
    framebuffer_virt: [*]u32,

    /// Total VRAM size in bytes
    vram_size: u32,

    /// Current display state
    width: u32 = 0,
    height: u32 = 0,
    bpp: u32 = 32,
    pitch: u32 = 0,
    current_mode_id: u32 = 0,

    /// PCI device info (for reference)
    pci_dev: ?pci.PciDevice = null,

    /// RAM manager for 2D acceleration command rings
    ram_manager: ?ram.RamManager = null,

    /// Pool of pre-allocated drawable structures
    drawable_pool: ?drawable.DrawablePool = null,

    /// Whether 2D acceleration is enabled
    accel_enabled: bool = false,

    /// Release ID counter for tracking command completion
    release_id_counter: u64 = 0,

    const Self = @This();

    // Global instance (single GPU assumption)
    var instance: Self = undefined;
    var initialized: bool = false;

    /// Initialize the QXL driver
    /// Returns pointer to driver instance on success, null on failure
    pub fn init() ?*Self {
        // Prevent double initialization
        if (initialized) return &instance;

        // QXL uses I/O ports, only supported on x86_64
        if (builtin.cpu.arch != .x86_64) {
            console.debug("QXL: Not supported on this architecture", .{});
            return null;
        }

        // 1. Find PCI device
        const devices = pci.getDevices() orelse {
            console.debug("QXL: PCI devices not available", .{});
            return null;
        };

        var qxl_dev: ?pci.PciDevice = null;
        for (devices.devices[0..devices.count]) |*dev| {
            if (dev.vendor_id == hw.PCI_VENDOR_ID_REDHAT and
                dev.device_id == hw.PCI_DEVICE_ID_QXL)
            {
                qxl_dev = dev.*;
                break;
            }
        }

        const dev = qxl_dev orelse {
            // Not an error - device simply not present
            return null;
        };

        console.info("QXL: Found device at PCI {x}:{x}.{}", .{
            dev.bus,
            dev.device,
            dev.func,
        });

        // 2. Get BAR addresses
        const bar0 = dev.bar[hw.BAR_ROM]; // ROM
        const bar1 = dev.bar[hw.BAR_VRAM]; // VRAM
        const bar3 = dev.bar[hw.BAR_IO]; // I/O ports

        if (bar0.base == 0) {
            console.err("QXL: BAR0 (ROM) not configured", .{});
            return null;
        }
        if (bar1.base == 0) {
            console.err("QXL: BAR1 (VRAM) not configured", .{});
            return null;
        }
        if (bar3.base == 0 or bar3.is_mmio) {
            console.err("QXL: BAR3 (I/O) not configured or not I/O space", .{});
            return null;
        }

        // 3. Enable Bus Mastering and Memory/IO Space access
        if (pci.getEcam()) |ecam| {
            const cmd_reg = ecam.read16(dev.bus, dev.device, dev.func, 0x04);
            // Enable I/O (bit 0), Memory (bit 1), Bus Master (bit 2)
            ecam.write16(dev.bus, dev.device, dev.func, 0x04, cmd_reg | 0x7);
        }

        // 4. Initialize I/O port access
        const io = regs.IoAccess.init(bar3.base) orelse {
            console.err("QXL: Failed to initialize I/O access", .{});
            return null;
        };

        console.info("QXL: I/O base at 0x{x}", .{io.io_base});

        // 5. Parse ROM for mode list
        const rom_parser = rom.RomParser.init(bar0.base, bar0.size) orelse {
            console.err("QXL: Failed to parse ROM", .{});
            return null;
        };

        if (rom_parser.mode_count == 0) {
            console.err("QXL: No valid modes found in ROM", .{});
            return null;
        }

        // 6. Map framebuffer (BAR1)
        const fb_phys = bar1.base & 0xFFFFFFF0;
        const fb_virt: [*]u32 = @ptrCast(@alignCast(hal.paging.physToVirt(fb_phys)));

        // 7. Estimate VRAM size
        const vram_size: u32 = if (bar1.size > 0)
            @truncate(bar1.size)
        else
            @truncate(hw.DEFAULT_VRAM_SIZE);

        console.info("QXL: VRAM at phys 0x{x}, size={} KB", .{
            fb_phys,
            vram_size / 1024,
        });

        // 8. Reset device
        io.reset();

        // 9. Initialize 2D acceleration (optional - driver works without it)
        var ram_manager: ?ram.RamManager = null;
        var drawable_pool: ?drawable.DrawablePool = null;
        var accel_enabled = false;

        // Get BAR2 (RAM) for command rings
        const bar2 = dev.bar[hw.BAR_RAM];
        if (bar2.base != 0 and bar2.size > 0) {
            const bar2_phys = bar2.base & 0xFFFFFFF0;

            // Initialize RAM manager
            if (ram.RamManager.init(bar2_phys, bar2.size)) |rm| {
                ram_manager = rm;
                console.info("QXL: RAM manager initialized at 0x{x}", .{bar2_phys});

                // Initialize drawable pool
                if (drawable.DrawablePool.init()) |dp| {
                    drawable_pool = dp;
                    console.info("QXL: Drawable pool initialized with {} slots", .{
                        drawable.DrawablePool.POOL_SIZE,
                    });

                    // Setup memory slot 0 for drawable pool
                    if (ram_manager.?.setupMemSlot(0, dp.phys_base, drawable.DrawablePool.POOL_SIZE * @sizeOf(drawable.QxlDrawable))) {
                        // Tell device about the memory slot
                        io.addMemslot(0);
                        accel_enabled = true;
                        console.info("QXL: 2D acceleration enabled", .{});
                    } else {
                        console.warn("QXL: Failed to setup memory slot, acceleration disabled", .{});
                    }
                } else {
                    console.warn("QXL: Failed to allocate drawable pool, acceleration disabled", .{});
                }
            } else {
                console.warn("QXL: Failed to initialize RAM manager, acceleration disabled", .{});
            }
        } else {
            console.debug("QXL: BAR2 (RAM) not available, acceleration disabled", .{});
        }

        // Store instance
        instance = Self{
            .io = io,
            .rom_parser = rom_parser,
            .framebuffer_phys = fb_phys,
            .framebuffer_virt = fb_virt,
            .vram_size = vram_size,
            .pci_dev = dev,
            .ram_manager = ram_manager,
            .drawable_pool = drawable_pool,
            .accel_enabled = accel_enabled,
        };

        initialized = true;

        // Log available modes
        instance.rom_parser.logModes();

        console.info("QXL: Driver initialized successfully (accel={})", .{accel_enabled});

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

        // Find matching mode in ROM
        const mode_id = self.rom_parser.findMode(w, h, bpp) orelse {
            console.warn("QXL: Mode {}x{}x{} not found in ROM", .{ w, h, bpp });
            // Try to find any mode with matching resolution
            const best = self.rom_parser.findBestMode(w, h) orelse {
                console.err("QXL: No compatible mode found", .{});
                return;
            };
            self.setModeById(best.id, best.width, best.height, best.bpp, best.stride);
            return;
        };

        // Calculate stride
        const bytes_per_pixel: u32 = hw.bytesPerPixel(@intCast(bpp));
        const stride = std.math.mul(u32, w, bytes_per_pixel) catch {
            console.err("QXL: Overflow calculating stride", .{});
            return;
        };

        self.setModeById(mode_id, w, h, bpp, stride);
    }

    /// Set mode by ROM mode ID
    fn setModeById(self: *Self, mode_id: u32, w: u32, h: u32, bpp: u32, stride: u32) void {
        // Calculate required framebuffer size with overflow protection
        const fb_size = std.math.mul(u32, stride, h) catch {
            console.err("QXL: Overflow calculating framebuffer size", .{});
            return;
        };

        // Check against available VRAM
        if (fb_size > self.vram_size) {
            console.err("QXL: Requested mode exceeds VRAM ({} > {})", .{ fb_size, self.vram_size });
            return;
        }

        // Destroy existing primary surface if any
        if (self.current_mode_id != 0) {
            self.io.destroyPrimary();
        }

        // Set mode via I/O port
        self.io.setMode(mode_id);

        // Create primary surface
        self.io.createPrimary(mode_id);

        // Update driver state
        self.width = w;
        self.height = h;
        self.bpp = bpp;
        self.pitch = stride;
        self.current_mode_id = mode_id;

        // Clear screen
        const total_pixels = std.math.mul(u32, w, h) catch return;
        const max_pixels = self.vram_size / 4;
        const safe_pixels = @min(total_pixels, max_pixels);

        if (safe_pixels > 0) {
            @memset(self.framebuffer_virt[0..safe_pixels], 0);
        }

        console.info("QXL: Mode set to {}x{}x{} (id={}, pitch={})", .{
            w, h, bpp, mode_id, stride,
        });
    }

    /// Set default mode (typically 1024x768x32)
    pub fn setDefaultMode(self: *Self) void {
        const default = self.rom_parser.findDefaultMode() orelse {
            console.err("QXL: No default mode available", .{});
            return;
        };

        self.setModeById(default.id, default.width, default.height, default.bpp, default.stride);
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

    /// Attempt accelerated fill rectangle using QXL 2D command ring
    /// Returns true if acceleration was used, false to fall back to software
    fn fillRectAccel(self: *Self, x: u32, y: u32, w: u32, h: u32, color: u32) bool {
        // Check if acceleration is available
        if (!self.accel_enabled) return false;

        var rm = &(self.ram_manager orelse return false);
        var dp = &(self.drawable_pool orelse return false);

        // Process any completed commands (free drawables back to pool)
        while (rm.popRelease()) |release_addr| {
            // Convert physical address back to drawable pointer
            // The release ring gives us the physical address of the completed drawable
            const pool_base = dp.phys_base;
            if (release_addr >= pool_base) {
                const offset = release_addr - pool_base;
                const index = offset / @sizeOf(drawable.QxlDrawable);
                if (index < drawable.DrawablePool.POOL_SIZE) {
                    const drawable_ptr = &dp.virt_base[index];
                    dp.free(drawable_ptr);
                }
            }
        }

        // Get next release ID
        const release_id = self.release_id_counter;
        self.release_id_counter +%= 1;

        // Build the fill command
        const draw = commands.buildFill(
            dp,
            @intCast(x),
            @intCast(y),
            w,
            h,
            color,
            release_id,
        ) orelse return false;

        // Get physical address for command submission
        const phys_addr = dp.toPhysical(draw) orelse {
            dp.free(draw);
            return false;
        };

        // Push command to ring
        if (!rm.pushCommand(phys_addr, hw.CmdType.draw)) {
            dp.free(draw);
            return false;
        }

        // Notify device of new command
        self.io.notifyCmd();

        return true;
    }

    fn fillRect(ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, color: interface.Color) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Bounds checking - clip to screen dimensions
        if (x >= self.width or y >= self.height) return;
        const clip_w = if (x + w > self.width) self.width - x else w;
        const clip_h = if (y + h > self.height) self.height - y else h;
        if (clip_w == 0 or clip_h == 0) return;

        const pixel_color: u32 = (@as(u32, color.r) << 16) | (@as(u32, color.g) << 8) | color.b;

        // Try hardware-accelerated path first
        if (self.fillRectAccel(x, y, clip_w, clip_h, pixel_color)) {
            return;
        }

        // Fall back to software path
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
        // Phase 1: Direct framebuffer mode, no presentation required
        // In Phase 2 with command rings, this would notify the device
        // of updated regions
        _ = ctx;
        _ = dirty_rect;
    }

    /// Get number of available modes
    pub fn getModeCount(self: *const Self) usize {
        return self.rom_parser.getModeCount();
    }

    /// Get mode info by index
    pub fn getModeInfo(self: *const Self, index: usize) ?rom.ModeInfo {
        return self.rom_parser.getMode(index);
    }
};
