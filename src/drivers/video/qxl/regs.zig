//! QXL Register/I/O Port Access
//!
//! Provides access to QXL I/O ports (BAR3) for device commands.
//! QXL uses I/O ports for control commands rather than MMIO registers.

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal");
const hw = @import("hardware.zig");

/// I/O port access for QXL device
pub const IoAccess = struct {
    /// Base I/O port address (from BAR3)
    io_base: u16,

    const Self = @This();

    /// Initialize I/O access from BAR3
    pub fn init(bar3_base: u64) ?Self {
        // QXL BAR3 is an I/O port BAR, should be in the first 64KB
        if (bar3_base == 0 or bar3_base > 0xFFFF) {
            return null;
        }

        return Self{
            .io_base = @truncate(bar3_base),
        };
    }

    /// Write to I/O port
    pub fn write(self: Self, offset: u16, value: u32) void {
        if (builtin.cpu.arch != .x86_64) {
            // I/O ports are x86-specific
            return;
        }

        const port = std.math.add(u16, self.io_base, offset) catch return;
        hal.io.outl(port, value);
    }

    /// Read from I/O port
    pub fn read(self: Self, offset: u16) u32 {
        if (builtin.cpu.arch != .x86_64) {
            return 0;
        }

        const port = std.math.add(u16, self.io_base, offset) catch return 0;
        return hal.io.inl(port);
    }

    /// Send RESET command to device
    pub fn reset(self: Self) void {
        self.write(hw.IO_RESET, 0);
        // Wait for reset to complete
        memoryBarrier();
    }

    /// Set display mode by mode ID
    pub fn setMode(self: Self, mode_id: u32) void {
        self.write(hw.IO_SET_MODE, mode_id);
        memoryBarrier();
    }

    /// Create primary surface
    /// The mode parameter should match a valid ROM mode ID
    pub fn createPrimary(self: Self, mode_id: u32) void {
        self.write(hw.IO_CREATE_PRIMARY, mode_id);
        memoryBarrier();
    }

    /// Destroy primary surface
    pub fn destroyPrimary(self: Self) void {
        self.write(hw.IO_DESTROY_PRIMARY, 0);
        memoryBarrier();
    }

    /// Notify device of update to an area
    pub fn updateArea(self: Self) void {
        self.write(hw.IO_UPDATE_AREA, 0);
    }

    /// Notify device of command ring update
    pub fn notifyCmd(self: Self) void {
        self.write(hw.IO_NOTIFY_CMD, 0);
    }

    /// Notify device of cursor update
    pub fn notifyCursor(self: Self) void {
        self.write(hw.IO_NOTIFY_CURSOR, 0);
    }

    /// Add a memory slot
    pub fn addMemslot(self: Self, slot_id: u32) void {
        self.write(hw.IO_MEMSLOT_ADD, slot_id);
        memoryBarrier();
    }

    /// Delete a memory slot
    pub fn delMemslot(self: Self, slot_id: u32) void {
        self.write(hw.IO_MEMSLOT_DEL, slot_id);
        memoryBarrier();
    }

    /// Flush all surfaces
    pub fn flushSurfaces(self: Self) void {
        self.write(hw.IO_FLUSH_SURFACES, 0);
        memoryBarrier();
    }

    /// Destroy all surfaces
    pub fn destroyAllSurfaces(self: Self) void {
        self.write(hw.IO_DESTROY_ALL_SURFACES, 0);
        memoryBarrier();
    }
};

/// Architecture-independent memory barrier for I/O ordering
pub inline fn memoryBarrier() void {
    if (builtin.cpu.arch == .x86_64) {
        // mfence ensures all stores are visible
        asm volatile ("mfence" ::: .{ .memory = true });
    } else if (builtin.cpu.arch == .aarch64) {
        // DMB SY - Data Memory Barrier, full system
        asm volatile ("dmb sy" ::: .{ .memory = true });
    } else {
        @compileError("Unsupported architecture");
    }
}

/// CPU pause hint for polling loops
pub inline fn cpuPause() void {
    if (builtin.cpu.arch == .x86_64) {
        asm volatile ("pause");
    } else if (builtin.cpu.arch == .aarch64) {
        asm volatile ("yield");
    }
}
