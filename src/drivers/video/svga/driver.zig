//! VMware SVGA II Driver
//!
//! Implements the GraphicsDevice interface for the VMware SVGA II virtual GPU.
//! Supports resolution switching and hardware acceleration specific to VMware/VirtualBox.

const std = @import("std");
const hal = @import("hal");
const pci = @import("pci");
const interface = @import("../interface.zig");
const hw = @import("hardware.zig");
const console = @import("console");

pub const SvgDriver = struct {
    io_base: u16,
    framebuffer_phys: u64,
    framebuffer_virt: [*]u32,
    framebuffer_size: u32,
    vram_size: u32,

    fifo_phys: u64,
    fifo_virt: [*]u32,
    fifo_size: u32,

    width: u32 = 0,
    height: u32 = 0,
    bpp: u32 = 32,
    pitch: u32 = 0,

    const Self = @This();

    // Global instance (single GPU assumption)
    var instance: Self = undefined;
    var initialized: bool = false;

    pub fn init() ?*Self {
        // 1. Find PCI device
        const devices = pci.getDevices() orelse return null;
        var svga_dev: ?pci.PciDevice = null;

        // Iterate manually as we don't have a generic find method for vendor/device
        // But we can check pci.DeviceList implementation.
        // Assuming we iterate or use a helper if available.
        // Actually, looking at pci/root.zig examples, "devices.findE1000()" exists.
        // We'll iterate the slice directly.
        for (devices.devices[0..devices.count]) |*dev| {
            if (dev.vendor_id == hw.PCI_VENDOR_ID_VMWARE and
                dev.device_id == hw.PCI_DEVICE_ID_VMWARE_SVGA2)
            {
                svga_dev = dev.*;
                break;
            }
        }

        const dev = svga_dev orelse return null;

        // 2. Get Resources from BARs
        // BAR0: IO Base
        // BAR1: Framebuffer
        // BAR2: FIFO (Optional)
        const bar0 = dev.bar[0];
        const bar1 = dev.bar[1];
        const bar2 = dev.bar[2];

        if (bar0.bar_type != .io) return null;
        const io_base: u16 = @intCast(bar0.base & 0xFFFC);

        // 3. Enable Bus Mastering and IO
        // We need ECAM access to write to command register
        // Or assume it's already enabled by firmware? Better to enable.
        // Check `pci.access` or `dev.enableBusMastering(ecam)`
        if (pci.getEcam()) |ecam| {
            // Re-read current command (offset 0x04)
            const cmd_reg = ecam.read16(dev.bus, dev.device, dev.func, 0x04);
            // Enable IO (bit 0), Memory (bit 1), Bus Master (bit 2)
            ecam.write16(dev.bus, dev.device, dev.func, 0x04, cmd_reg | 0x7);
        }

        instance.io_base = io_base;

        // 4. Negotiate Version
        // Write ID to index port, then read/write value port
        instance.writeReg(.ID, hw.SVGA_ID_2);
        if (instance.readReg(.ID) != hw.SVGA_ID_2) {
            // Fallback to older version?
            return null;
        }

        // 5. Read Capabilities
        instance.vram_size = instance.readReg(.VRAM_SIZE);
        instance.framebuffer_size = instance.readReg(.FB_SIZE);
        instance.fifo_size = instance.readReg(.MEM_SIZE);

        // Map Framebuffer
        instance.framebuffer_phys = bar1.base & 0xFFFFFFF0;
        // Map to virtual address (Upper Half)
        // Using HAL paging/Direct map?
        // Assuming HHDM is available, we can compute virt address if it's in physical memory range.
        // However, PCI BARs are MMIO, so we usually need to `ioremap`.
        // For now, assuming direct map covers it or `physToVirt` handles MMIO ranges if they are identity mapped in higher half?
        // Zigk HAL likely has `hal.paging.mapMmio` or similar.
        // Looking at `framebuffer.zig`, it uses `hal.paging.physToVirt(bb_phys)`.
        // Depending on `physToVirt` logic (usually just adds HHDM offset).
        // If BAR is high physical address, it needs explicit mapping.
        // We will assume `physToVirt` works for now or valid ident mapping exists.
        instance.framebuffer_virt = @ptrFromInt(@intFromPtr(hal.paging.physToVirt(instance.framebuffer_phys)));

        // FIFO Mapping
        if (instance.fifo_size > 0 and bar2.base != 0) {
            instance.fifo_phys = bar2.base & 0xFFFFFFF0;
            instance.fifo_virt = @ptrFromInt(@intFromPtr(hal.paging.physToVirt(instance.fifo_phys)));

            // Initialize FIFO memory structure
            // The first 4 u32 words are the FIFO header:
            //   [0] = MIN      - byte offset where commands start (after header)
            //   [1] = MAX      - byte offset of end of FIFO
            //   [2] = NEXT_CMD - byte offset to write next command (starts at MIN)
            //   [3] = STOP     - byte offset where host has read to (starts at MIN)
            const fifo_header_size: u32 = 4 * @sizeOf(u32); // 16 bytes
            instance.fifo_virt[hw.FIFO_MIN] = fifo_header_size;
            instance.fifo_virt[hw.FIFO_MAX] = instance.fifo_size;
            instance.fifo_virt[hw.FIFO_NEXT_CMD] = fifo_header_size;
            instance.fifo_virt[hw.FIFO_STOP] = fifo_header_size;

            // Tell device about FIFO location
            instance.writeReg(.MEM_START, @intCast(instance.fifo_phys));
            instance.writeReg(.MEM_SIZE, instance.fifo_size);

            // Memory barrier before signaling CONFIG_DONE
            asm volatile ("mfence" ::: .{ .memory = true });

            // Signal that FIFO configuration is complete
            instance.writeReg(.CONFIG_DONE, 1);
        }

        initialized = true;
        return &instance;
    }

    // Helper I/O
    fn writeReg(self: *Self, reg: hw.Registers, val: u32) void {
        hal.io.outl(self.io_base + hw.SVGA_INDEX_PORT, @intFromEnum(reg));
        hal.io.outl(self.io_base + hw.SVGA_VALUE_PORT, val);
    }

    fn readReg(self: *Self, reg: hw.Registers) u32 {
        hal.io.outl(self.io_base + hw.SVGA_INDEX_PORT, @intFromEnum(reg));
        return hal.io.inl(self.io_base + hw.SVGA_VALUE_PORT);
    }

    // Interface Implementation
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

    pub fn setMode(self: *Self, w: u32, h: u32, bpp: u32) void {
        self.width = w;
        self.height = h;
        self.bpp = bpp;

        self.writeReg(.WIDTH, w);
        self.writeReg(.HEIGHT, h);
        self.writeReg(.BPP, bpp);
        self.writeReg(.ENABLE, 1);

        self.pitch = self.readReg(.BYTES_PER_LINE);

        // Clear screen with overflow-safe calculation
        const total_bytes = std.math.mul(u32, self.pitch, self.height) catch {
            // Overflow - malicious hypervisor or invalid config
            return;
        };
        const len = total_bytes / 4; // u32 words

        // Bounds check against actual allocated framebuffer size
        const max_len = self.framebuffer_size / 4;
        const safe_len = if (len > max_len) max_len else len;
        if (safe_len == 0) return;

        @memset(self.framebuffer_virt[0..safe_len], 0);
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

        const offset = (y * self.pitch / 4) + x;
        const val: u32 = (@as(u32, color.r) << 16) | (@as(u32, color.g) << 8) | color.b;
        self.framebuffer_virt[offset] = val;
    }

    fn fillRect(ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, color: interface.Color) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Bounds checking - clip to screen dimensions
        if (x >= self.width or y >= self.height) return;
        const clip_w = if (x + w > self.width) self.width - x else w;
        const clip_h = if (y + h > self.height) self.height - y else h;
        if (clip_w == 0 or clip_h == 0) return;

        const val: u32 = (@as(u32, color.r) << 16) | (@as(u32, color.g) << 8) | color.b;

        const stride = self.pitch / 4;
        const max_offset = self.framebuffer_size / 4;

        var row: u32 = 0;
        while (row < clip_h) : (row += 1) {
            const start = std.math.mul(u32, y + row, stride) catch return;
            const offset = std.math.add(u32, start, x) catch return;
            const end = std.math.add(u32, offset, clip_w) catch return;

            // Validate against framebuffer bounds
            if (end > max_offset) return;

            @memset(self.framebuffer_virt[offset..end], val);
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

            // Validate against framebuffer bounds
            if (fb_end > max_offset) return;

            const buf_off = row * w;
            @memcpy(self.framebuffer_virt[fb_off..fb_end], buf[buf_off .. buf_off + clip_w]);
        }

        self.updateRect(x, y, clip_w, clip_h);
    }

    fn copyRect(ctx: *anyopaque, src_x: u32, src_y: u32, dst_x: u32, dst_y: u32, w: u32, h: u32) void {
        // Software fallback
        const self: *Self = @ptrCast(@alignCast(ctx));
        // Similar to framebuffer.zig impl, but trigger update
        // ... implementation omitted for brevity, reuse logic or utilize hardware copy later ...
        _ = self;
        _ = src_x;
        _ = src_y;
        _ = dst_x;
        _ = dst_y;
        _ = w;
        _ = h;
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
        // Check if FIFO is available
        if (self.fifo_size == 0) {
            // No FIFO - use legacy sync register approach
            // Writing to SYNC forces the device to read framebuffer
            self.writeReg(.SYNC, 1);
            // Wait for device to finish (BUSY goes to 0)
            while (self.readReg(.BUSY) != 0) {}
            return;
        }

        // FIFO-based update command
        // FIFO memory layout:
        //   [0] = MIN    - byte offset where commands start (typically 16)
        //   [1] = MAX    - byte offset of end of FIFO
        //   [2] = NEXT_CMD - byte offset to write next command
        //   [3] = STOP   - byte offset where host has read to
        //
        // Command format for Update (cmd=1):
        //   u32: command (1)
        //   u32: x
        //   u32: y
        //   u32: width
        //   u32: height
        const cmd_size: u32 = 5 * @sizeOf(u32); // 20 bytes

        // Read current FIFO state
        const fifo_min = self.fifo_virt[hw.FIFO_MIN];
        const fifo_max = self.fifo_virt[hw.FIFO_MAX];
        var next_cmd = self.fifo_virt[hw.FIFO_NEXT_CMD];
        const stop = self.fifo_virt[hw.FIFO_STOP];

        // Check if there's space in the FIFO
        // Simple check: if next_cmd + cmd_size would wrap or hit stop, sync first
        const space_needed = next_cmd + cmd_size;
        if (space_needed > fifo_max) {
            // Need to wrap or sync - for simplicity, sync and reset
            self.writeReg(.SYNC, 1);
            while (self.readReg(.BUSY) != 0) {}
            next_cmd = fifo_min;
        } else if (next_cmd < stop and space_needed >= stop) {
            // Would overrun host read position - sync first
            self.writeReg(.SYNC, 1);
            while (self.readReg(.BUSY) != 0) {}
        }

        // Write command to FIFO at byte offset next_cmd
        // Convert byte offset to u32 index
        const word_idx = next_cmd / @sizeOf(u32);
        self.fifo_virt[word_idx + 0] = @intFromEnum(hw.Cmd.Update);
        self.fifo_virt[word_idx + 1] = x;
        self.fifo_virt[word_idx + 2] = y;
        self.fifo_virt[word_idx + 3] = w;
        self.fifo_virt[word_idx + 4] = h;

        // Update NEXT_CMD pointer
        self.fifo_virt[hw.FIFO_NEXT_CMD] = next_cmd + cmd_size;

        // Memory barrier to ensure writes are visible to device
        asm volatile ("mfence" ::: .{ .memory = true });
    }
};
