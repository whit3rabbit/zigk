//! VMware SVGA II Driver
//!
//! Implements the GraphicsDevice interface for the VMware SVGA II virtual GPU.
//! Supports resolution switching, 2D hardware acceleration, and hardware cursor.
//! Compatible with VMware Workstation, Fusion, and VirtualBox.
//!
//! Architecture support:
//! - x86_64: Uses I/O port space (traditional)
//! - aarch64: Uses MMIO (VMware Fusion on Apple Silicon)

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal");
const pci = @import("pci");
const interface = @import("../interface.zig");
const hw = @import("hardware.zig");
const caps = @import("caps.zig");
const fifo = @import("fifo.zig");
const cursor_mod = @import("cursor.zig");
const regs = @import("regs.zig");
const console = @import("console");

pub const SvgaDriver = struct {
    // Register access abstraction (handles both port I/O and MMIO)
    reg_access: regs.RegisterAccess,
    framebuffer_phys: u64,
    framebuffer_virt: [*]u32,
    framebuffer_size: u32,
    vram_size: u32,

    // FIFO management
    fifo_phys: u64,
    fifo_mgr: fifo.FifoManager,

    // Device capabilities
    capabilities: caps.Capabilities,

    // Hardware cursor
    hw_cursor: cursor_mod.HardwareCursor,

    // Display state
    width: u32 = 0,
    height: u32 = 0,
    bpp: u32 = 32,
    pitch: u32 = 0,

    // PCI device info (for IRQ)
    pci_dev: ?pci.PciDevice = null,

    const Self = @This();

    // Global instance (single GPU assumption)
    var instance: Self = undefined;
    var initialized: bool = false;

    /// Initialize the SVGA driver
    /// Returns pointer to driver instance on success, null on failure
    pub fn init() ?*Self {
        // Prevent double initialization
        if (initialized) return &instance;

        // 1. Find PCI device
        const devices = pci.getDevices() orelse {
            console.warn("SVGA: PCI devices not available", .{});
            return null;
        };

        var svga_dev: ?pci.PciDevice = null;
        for (devices.devices[0..devices.count]) |*dev| {
            if (dev.vendor_id == hw.PCI_VENDOR_ID_VMWARE and
                dev.device_id == hw.PCI_DEVICE_ID_VMWARE_SVGA2)
            {
                svga_dev = dev.*;
                break;
            }
        }

        const dev = svga_dev orelse {
            // Not an error - device simply not present
            return null;
        };

        console.info("SVGA: Found VMware SVGA II device at PCI {x}:{x}.{}", .{
            dev.bus,
            dev.device,
            dev.func,
        });

        // 2. Get Resources from BARs
        // BAR0: Register access (I/O on x86, MMIO on ARM)
        // BAR1: Framebuffer, BAR2: FIFO
        const bar0 = dev.bar[0];
        const bar1 = dev.bar[1];
        const bar2 = dev.bar[2];

        // Determine BAR type and initialize register access
        const bar_type: regs.BarType = if (bar0.bar_type == .io) .io else .memory;
        const reg_access = regs.RegisterAccess.init(bar0.base, bar_type) orelse {
            console.err("SVGA: Failed to initialize register access", .{});
            return null;
        };

        // Log access mode
        if (reg_access.mode == .port_io) {
            console.info("SVGA: Using I/O port access at 0x{x}", .{reg_access.base});
        } else {
            console.info("SVGA: Using MMIO access at 0x{x}", .{reg_access.base});
        }

        // 3. Enable Bus Mastering and IO/Memory
        if (pci.getEcam()) |ecam| {
            const cmd_reg = ecam.read16(dev.bus, dev.device, dev.func, 0x04);
            // Enable IO (bit 0), Memory (bit 1), Bus Master (bit 2)
            ecam.write16(dev.bus, dev.device, dev.func, 0x04, cmd_reg | 0x7);
        }

        instance.reg_access = reg_access;
        instance.pci_dev = dev;

        // 4. Negotiate Version
        writeRegStatic(.ID, hw.SVGA_ID_2);
        const device_id = readRegStatic(.ID);
        if (device_id != hw.SVGA_ID_2) {
            console.warn("SVGA: Version negotiation failed (got 0x{x})", .{device_id});
            return null;
        }

        // 5. Read and parse capabilities
        const raw_caps = readRegStatic(.CAPABILITIES);
        instance.capabilities = caps.parseCapabilities(raw_caps);

        // Log capabilities
        console.info("SVGA: Capabilities: 0x{x}", .{raw_caps});
        if (instance.capabilities.hasRectCopy()) {
            console.info("SVGA: Hardware RectCopy supported", .{});
        }
        if (instance.capabilities.hasHardwareCursor()) {
            console.info("SVGA: Hardware cursor supported", .{});
        }
        if (instance.capabilities.hasAlphaCursor()) {
            console.info("SVGA: Alpha cursor supported", .{});
        }
        if (instance.capabilities.hasSvga3d()) {
            console.info("SVGA: SVGA3D supported", .{});
        }

        // 6. Read memory sizes with validation
        instance.vram_size = readRegStatic(.VRAM_SIZE);
        instance.framebuffer_size = readRegStatic(.FB_SIZE);
        const fifo_size = readRegStatic(.MEM_SIZE);

        // Validate sizes against reasonable maximums
        if (instance.vram_size > hw.MAX_VRAM_SIZE) {
            console.warn("SVGA: VRAM size exceeds limit, clamping", .{});
            instance.vram_size = hw.MAX_VRAM_SIZE;
        }
        if (instance.framebuffer_size > hw.MAX_FB_SIZE) {
            console.warn("SVGA: FB size exceeds limit, clamping", .{});
            instance.framebuffer_size = hw.MAX_FB_SIZE;
        }

        console.info("SVGA: VRAM={} KB, FB={} KB, FIFO={} KB", .{
            instance.vram_size / 1024,
            instance.framebuffer_size / 1024,
            fifo_size / 1024,
        });

        // 7. Map Framebuffer
        instance.framebuffer_phys = bar1.base & 0xFFFFFFF0;
        instance.framebuffer_virt = @ptrFromInt(@intFromPtr(hal.paging.physToVirt(instance.framebuffer_phys)));

        // 8. Map and initialize FIFO
        if (fifo_size > 0 and bar2.base != 0) {
            instance.fifo_phys = bar2.base & 0xFFFFFFF0;
            const fifo_virt: [*]u32 = @ptrFromInt(@intFromPtr(hal.paging.physToVirt(instance.fifo_phys)));

            instance.fifo_mgr = fifo.FifoManager.init(fifo_virt, fifo_size);
            instance.fifo_mgr.initHeader();

            // Tell device about FIFO location
            writeRegStatic(.MEM_START, @intCast(instance.fifo_phys));
            writeRegStatic(.MEM_SIZE, fifo_size);

            // Memory barrier before signaling CONFIG_DONE
            regs.memoryBarrier();

            // Signal that FIFO configuration is complete
            writeRegStatic(.CONFIG_DONE, 1);

            console.info("SVGA: FIFO initialized", .{});
        } else {
            // Initialize with null FIFO
            instance.fifo_mgr = fifo.FifoManager.initEmpty();
            console.info("SVGA: No FIFO available, using legacy mode", .{});
        }

        // 9. Initialize hardware cursor
        instance.hw_cursor = cursor_mod.HardwareCursor.init(
            &writeRegCallback,
            &instance.fifo_mgr,
            instance.capabilities,
        );

        if (instance.hw_cursor.isAvailable()) {
            // Define default arrow cursor
            if (instance.hw_cursor.defineArrowCursor(0)) {
                instance.hw_cursor.setPosition(0, 0);
                console.info("SVGA: Hardware cursor initialized", .{});
            }
        }

        // 10. Set Guest ID
        writeRegStatic(.GUEST_ID, hw.GUEST_OS_OTHER);

        initialized = true;
        console.info("SVGA: Driver initialized successfully", .{});

        return &instance;
    }

    /// Callback for cursor module to write registers
    fn writeRegCallback(reg: hw.Registers, val: u32) void {
        writeRegStatic(reg, val);
    }

    // Static register access (before instance is fully set up)
    fn writeRegStatic(reg: hw.Registers, val: u32) void {
        instance.reg_access.write(reg, val);
    }

    fn readRegStatic(reg: hw.Registers) u32 {
        return instance.reg_access.read(reg);
    }

    // Instance register access
    pub fn writeReg(self: *Self, reg: hw.Registers, val: u32) void {
        self.reg_access.write(reg, val);
    }

    pub fn readReg(self: *Self, reg: hw.Registers) u32 {
        return self.reg_access.read(reg);
    }

    /// Get hardware cursor interface
    pub fn getCursor(self: *Self) *cursor_mod.HardwareCursor {
        return &self.hw_cursor;
    }

    /// Check if SVGA3D is available
    pub fn has3DSupport(self: *const Self) bool {
        return self.capabilities.hasSvga3d();
    }

    /// Get device capabilities
    pub fn getCapabilities(self: *const Self) caps.Capabilities {
        return self.capabilities;
    }

    // GraphicsDevice Interface Implementation
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
        if (w > hw.MAX_WIDTH_LIMIT or h > hw.MAX_HEIGHT_LIMIT) return;

        self.width = w;
        self.height = h;
        self.bpp = bpp;

        self.writeReg(.WIDTH, w);
        self.writeReg(.HEIGHT, h);
        self.writeReg(.BPP, bpp);
        self.writeReg(.ENABLE, 1);

        self.pitch = self.readReg(.BYTES_PER_LINE);

        // Update cursor screen size
        self.hw_cursor.setScreenSize(w, h);

        // Clear screen with overflow-safe calculation
        const total_bytes = std.math.mul(u32, self.pitch, self.height) catch {
            console.err("SVGA: Overflow calculating screen size", .{});
            return;
        };
        const len = total_bytes / 4;

        // Bounds check against actual allocated framebuffer size
        const max_len = self.framebuffer_size / 4;
        const safe_len = if (len > max_len) max_len else len;
        if (safe_len == 0) return;

        @memset(self.framebuffer_virt[0..safe_len], 0);

        console.info("SVGA: Mode set to {}x{}x{} (pitch={})", .{ w, h, bpp, self.pitch });
    }

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

        if (pixel_offset >= self.framebuffer_size / 4) return;

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

        // Try hardware acceleration if available
        if (self.capabilities.rect_copy and self.fifo_mgr.initialized) {
            if (self.fifo_mgr.writeRectFill(pixel_color, x, y, clip_w, clip_h)) {
                return; // Hardware handled it
            }
        }

        // Software fallback
        const stride = self.pitch / 4;
        const max_offset = self.framebuffer_size / 4;

        var row: u32 = 0;
        while (row < clip_h) : (row += 1) {
            const start = std.math.mul(u32, y + row, stride) catch return;
            const offset = std.math.add(u32, start, x) catch return;
            const end = std.math.add(u32, offset, clip_w) catch return;

            if (end > max_offset) return;

            @memset(self.framebuffer_virt[offset..end], pixel_color);
        }

        self.updateRect(x, y, clip_w, clip_h);
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
        const max_offset = self.framebuffer_size / 4;

        var row: u32 = 0;
        while (row < clip_h) : (row += 1) {
            const fb_start = std.math.mul(u32, y + row, stride) catch return;
            const fb_off = std.math.add(u32, fb_start, x) catch return;
            const fb_end = std.math.add(u32, fb_off, clip_w) catch return;

            if (fb_end > max_offset) return;

            const buf_off = row * w;
            @memcpy(self.framebuffer_virt[fb_off..fb_end], buf[buf_off .. buf_off + clip_w]);
        }

        self.updateRect(x, y, clip_w, clip_h);
    }

    fn copyRect(ctx: *anyopaque, src_x: u32, src_y: u32, dst_x: u32, dst_y: u32, w: u32, h: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Bounds checking
        if (src_x >= self.width or src_y >= self.height) return;
        if (dst_x >= self.width or dst_y >= self.height) return;

        const clip_w = @min(w, @min(self.width - src_x, self.width - dst_x));
        const clip_h = @min(h, @min(self.height - src_y, self.height - dst_y));
        if (clip_w == 0 or clip_h == 0) return;

        // Try hardware acceleration if available
        if (self.capabilities.hasRectCopy() and self.fifo_mgr.initialized) {
            if (self.fifo_mgr.writeRectCopy(src_x, src_y, dst_x, dst_y, clip_w, clip_h)) {
                return; // Hardware handled it
            }
        }

        // Software fallback with overlap handling
        const stride = self.pitch / 4;
        const max_offset = self.framebuffer_size / 4;

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

                // Use memmove semantics for overlapping copy
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

        self.updateRect(dst_x, dst_y, clip_w, clip_h);
    }

    fn present(ctx: *anyopaque, dirty_rect: ?interface.Rect) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (dirty_rect) |r| {
            self.updateRect(r.x, r.y, r.width, r.height);
        } else {
            self.updateRect(0, 0, self.width, self.height);
        }
    }

    fn updateRect(self: *Self, x: u32, y: u32, w: u32, h: u32) void {
        // Use FIFO if available
        if (self.fifo_mgr.initialized) {
            if (self.fifo_mgr.writeUpdate(x, y, w, h)) {
                return;
            }
        }

        // Legacy sync fallback
        self.writeReg(.SYNC, 1);
        while (self.readReg(.BUSY) != 0) {
            regs.cpuPause();
        }
    }

    /// Force synchronization (wait for all commands to complete)
    pub fn sync(self: *Self) void {
        self.writeReg(.SYNC, 1);
        while (self.readReg(.BUSY) != 0) {
            regs.cpuPause();
        }
    }
};

// Re-export for convenience
pub const HardwareCursor = cursor_mod.HardwareCursor;
pub const Capabilities = caps.Capabilities;
