//! VMware SVGA II Register Access Abstraction
//!
//! Provides architecture-independent register access for the SVGA II device.
//! - x86_64: Uses I/O port space (BAR0 is I/O BAR)
//! - aarch64: Uses MMIO (BAR0 is memory BAR with indexed register access)
//!
//! On both architectures, SVGA uses an indexed register scheme:
//! 1. Write register index to INDEX location
//! 2. Read/write value from/to VALUE location

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal");
const hw = @import("hardware.zig");

/// Register access backend
pub const RegisterAccess = struct {
    /// On x86_64: I/O port base address
    /// On aarch64: Virtual address of MMIO register region
    base: usize,

    /// Access mode determined at init time
    mode: AccessMode,

    const Self = @This();

    pub const AccessMode = enum {
        /// x86 I/O port access
        port_io,
        /// Memory-mapped I/O access (ARM64 or x86 with MMIO BAR)
        mmio,
    };

    /// Initialize register access from PCI BAR0
    /// Returns null if BAR is invalid
    pub fn init(bar_base: u64, bar_type: BarType) ?Self {
        return switch (bar_type) {
            .io => blk: {
                // x86 I/O port - base is port number
                if (builtin.cpu.arch != .x86_64) {
                    // I/O ports not supported on ARM
                    break :blk null;
                }
                break :blk Self{
                    .base = @intCast(bar_base & 0xFFFC),
                    .mode = .port_io,
                };
            },
            .memory => blk: {
                // MMIO - map to virtual address
                const phys = bar_base & 0xFFFFFFF0;
                const virt = hal.paging.physToVirt(phys);
                break :blk Self{
                    .base = @intFromPtr(virt),
                    .mode = .mmio,
                };
            },
        };
    }

    /// Write to an SVGA register
    pub fn write(self: Self, reg: hw.Registers, value: u32) void {
        switch (self.mode) {
            .port_io => {
                // x86 indexed I/O port access
                if (builtin.cpu.arch == .x86_64) {
                    const port: u16 = @intCast(self.base);
                    hal.io.outl(port + hw.SVGA_INDEX_PORT, @intFromEnum(reg));
                    hal.io.outl(port + hw.SVGA_VALUE_PORT, value);
                }
            },
            .mmio => {
                // ARM64 indexed MMIO access
                // Register layout: INDEX at offset 0, VALUE at offset 4
                const index_ptr: *volatile u32 = @ptrFromInt(self.base);
                const value_ptr: *volatile u32 = @ptrFromInt(self.base + 4);
                index_ptr.* = @intFromEnum(reg);
                memoryBarrier();
                value_ptr.* = value;
            },
        }
    }

    /// Read from an SVGA register
    pub fn read(self: Self, reg: hw.Registers) u32 {
        switch (self.mode) {
            .port_io => {
                // x86 indexed I/O port access
                if (builtin.cpu.arch == .x86_64) {
                    const port: u16 = @intCast(self.base);
                    hal.io.outl(port + hw.SVGA_INDEX_PORT, @intFromEnum(reg));
                    return hal.io.inl(port + hw.SVGA_VALUE_PORT);
                }
                return 0;
            },
            .mmio => {
                // ARM64 indexed MMIO access
                const index_ptr: *volatile u32 = @ptrFromInt(self.base);
                const value_ptr: *volatile u32 = @ptrFromInt(self.base + 4);
                index_ptr.* = @intFromEnum(reg);
                memoryBarrier();
                return value_ptr.*;
            },
        }
    }
};

/// PCI BAR type (simplified for this module)
pub const BarType = enum {
    io,
    memory,
};

/// Architecture-independent memory barrier
pub inline fn memoryBarrier() void {
    if (builtin.cpu.arch == .x86_64) {
        asm volatile ("mfence" ::: .{ .memory = true });
    } else if (builtin.cpu.arch == .aarch64) {
        // DMB SY - Data Memory Barrier, full system
        asm volatile ("dmb sy" ::: .{ .memory = true });
    } else {
        @compileError("Unsupported architecture");
    }
}

/// Architecture-independent CPU pause/yield hint
pub inline fn cpuPause() void {
    if (builtin.cpu.arch == .x86_64) {
        asm volatile ("pause" ::: .{});
    } else if (builtin.cpu.arch == .aarch64) {
        // YIELD instruction - hint to give up CPU slice
        asm volatile ("yield" ::: .{});
    } else {
        @compileError("Unsupported architecture");
    }
}
