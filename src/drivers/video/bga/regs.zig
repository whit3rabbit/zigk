//! Bochs VGA Register Access Abstraction
//!
//! Provides architecture-independent register access for the BGA device.
//! - x86_64: Uses legacy I/O port space (ports 0x01CE/0x01CF)
//! - aarch64: Uses MMIO (BAR2 base + 0x500)
//!
//! BGA uses an indexed register scheme:
//! 1. Write register index to INDEX location
//! 2. Read/write 16-bit value from/to DATA location

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal");
const hw = @import("hardware.zig");

/// Register access backend
pub const AccessMode = enum {
    /// x86 I/O port access (legacy VBE DISPI interface)
    port_io,
    /// Memory-mapped I/O access (modern interface via BAR2)
    mmio,
};

/// Register access abstraction for BGA
pub const RegisterAccess = struct {
    /// For port_io: unused (ports are fixed)
    /// For mmio: virtual address of DISPI register region (BAR2 + 0x500)
    base: usize,

    /// Access mode determined at init time
    mode: AccessMode,

    const Self = @This();

    /// Initialize register access
    /// For x86_64: Can use port I/O (pass bar_base=0, use_mmio=false)
    /// For MMIO: Pass the BAR2 physical address
    pub fn init(bar2_phys: u64, use_mmio: bool) ?Self {
        if (use_mmio) {
            // MMIO mode: map BAR2 + DISPI offset to virtual address
            if (bar2_phys == 0) return null;

            const dispi_phys = bar2_phys + hw.MMIO_DISPI_OFFSET;
            const virt = hal.paging.physToVirt(dispi_phys);
            return Self{
                .base = @intFromPtr(virt),
                .mode = .mmio,
            };
        } else {
            // Port I/O mode (x86_64 only)
            if (builtin.cpu.arch != .x86_64) {
                // I/O ports not supported on ARM
                return null;
            }
            return Self{
                .base = 0, // Unused for port I/O - ports are fixed
                .mode = .port_io,
            };
        }
    }

    /// Initialize with automatic mode selection based on architecture
    /// - x86_64: prefers port I/O (simpler, always works)
    /// - aarch64: requires MMIO
    pub fn initAuto(bar2_phys: u64) ?Self {
        if (builtin.cpu.arch == .x86_64) {
            // x86_64: prefer port I/O for simplicity
            return Self{
                .base = 0,
                .mode = .port_io,
            };
        } else {
            // ARM64: must use MMIO
            return init(bar2_phys, true);
        }
    }

    /// Write to a BGA DISPI register
    pub fn write(self: Self, reg: hw.Dispi, value: u16) void {
        switch (self.mode) {
            .port_io => {
                if (builtin.cpu.arch == .x86_64) {
                    // Write index to 0x01CE, data to 0x01CF
                    hal.io.outw(hw.VBE_DISPI_IOPORT_INDEX, @intFromEnum(reg));
                    hal.io.outw(hw.VBE_DISPI_IOPORT_DATA, value);
                }
            },
            .mmio => {
                // MMIO layout: index at offset 0, data at offset 2 (16-bit registers)
                const index_ptr: *volatile u16 = @ptrFromInt(self.base);
                const data_ptr: *volatile u16 = @ptrFromInt(self.base + 2);
                index_ptr.* = @intFromEnum(reg);
                memoryBarrier();
                data_ptr.* = value;
            },
        }
    }

    /// Read from a BGA DISPI register
    pub fn read(self: Self, reg: hw.Dispi) u16 {
        switch (self.mode) {
            .port_io => {
                if (builtin.cpu.arch == .x86_64) {
                    // Write index to 0x01CE, read data from 0x01CF
                    hal.io.outw(hw.VBE_DISPI_IOPORT_INDEX, @intFromEnum(reg));
                    return hal.io.inw(hw.VBE_DISPI_IOPORT_DATA);
                }
                return 0;
            },
            .mmio => {
                // MMIO layout: index at offset 0, data at offset 2
                const index_ptr: *volatile u16 = @ptrFromInt(self.base);
                const data_ptr: *volatile u16 = @ptrFromInt(self.base + 2);
                index_ptr.* = @intFromEnum(reg);
                memoryBarrier();
                return data_ptr.*;
            },
        }
    }

    /// Check if the BGA device is present by reading the ID register
    /// Returns the version ID if present, null if not responding
    pub fn detectVersion(self: Self) ?u16 {
        // Write a known version ID to ID register
        self.write(.ID, hw.VBE_DISPI_ID5);

        // Read it back - device should return the highest version it supports
        const id = self.read(.ID);

        // Valid BGA IDs are in range 0xB0C0-0xB0C5
        if (id >= hw.VBE_DISPI_ID0 and id <= hw.VBE_DISPI_ID5) {
            return id;
        }
        return null;
    }
};

/// Architecture-independent memory barrier for MMIO ordering
pub inline fn memoryBarrier() void {
    if (builtin.cpu.arch == .x86_64) {
        // x86 has strong memory ordering, but mfence ensures visibility
        asm volatile ("mfence" ::: "memory");
    } else if (builtin.cpu.arch == .aarch64) {
        // DMB SY - Data Memory Barrier, full system
        asm volatile ("dmb sy" ::: "memory");
    } else {
        @compileError("Unsupported architecture");
    }
}

/// Architecture-independent CPU pause/yield hint
/// Useful for polling loops to reduce power and avoid pipeline stalls
pub inline fn cpuPause() void {
    if (builtin.cpu.arch == .x86_64) {
        asm volatile ("pause");
    } else if (builtin.cpu.arch == .aarch64) {
        // YIELD instruction - hint to give up CPU slice
        asm volatile ("yield");
    } else {
        @compileError("Unsupported architecture");
    }
}
