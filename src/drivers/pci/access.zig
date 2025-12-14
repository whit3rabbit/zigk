const ecam = @import("ecam.zig");
const legacy = @import("legacy.zig");

pub const Ecam = ecam.Ecam;
pub const Legacy = legacy.Legacy;

pub const PciAccess = union(enum) {
    ecam: Ecam,
    legacy: Legacy,

    const Self = @This();

    pub fn startBus(self: Self) u8 {
        switch (self) {
            .ecam => |e| return e.start_bus,
            .legacy => |l| return l.start_bus,
        }
    }

    pub fn endBus(self: Self) u8 {
        switch (self) {
            .ecam => |e| return e.end_bus,
            .legacy => |l| return l.end_bus,
        }
    }

    pub fn read8(self: Self, bus: u8, dev: u5, func: u3, offset: u12) u8 {
        switch (self) {
            .ecam => |e| return e.read8(bus, dev, func, offset),
            .legacy => |l| return l.read8(bus, dev, func, offset),
        }
    }

    pub fn read16(self: Self, bus: u8, dev: u5, func: u3, offset: u12) u16 {
        switch (self) {
            .ecam => |e| return e.read16(bus, dev, func, offset),
            .legacy => |l| return l.read16(bus, dev, func, offset),
        }
    }

    pub fn read32(self: Self, bus: u8, dev: u5, func: u3, offset: u12) u32 {
        switch (self) {
            .ecam => |e| return e.read32(bus, dev, func, offset),
            .legacy => |l| return l.read32(bus, dev, func, offset),
        }
    }

    pub fn write8(self: Self, bus: u8, dev: u5, func: u3, offset: u12, value: u8) void {
        switch (self) {
            .ecam => |e| return e.write8(bus, dev, func, offset, value),
            .legacy => |l| return l.write8(bus, dev, func, offset, value),
        }
    }

    pub fn write16(self: Self, bus: u8, dev: u5, func: u3, offset: u12, value: u16) void {
        switch (self) {
            .ecam => |e| return e.write16(bus, dev, func, offset, value),
            .legacy => |l| return l.write16(bus, dev, func, offset, value),
        }
    }

    pub fn write32(self: Self, bus: u8, dev: u5, func: u3, offset: u12, value: u32) void {
        switch (self) {
            .ecam => |e| return e.write32(bus, dev, func, offset, value),
            .legacy => |l| return l.write32(bus, dev, func, offset, value),
        }
    }

    // High-level helpers

    pub fn deviceExists(self: Self, bus: u8, dev: u5, func: u3) bool {
        const vendor = self.read16(bus, dev, func, 0x00);
        return vendor != 0xFFFF;
    }

    pub fn readVendorId(self: Self, bus: u8, dev: u5, func: u3) u16 {
        return self.read16(bus, dev, func, 0x00);
    }

    pub fn readDeviceId(self: Self, bus: u8, dev: u5, func: u3) u16 {
        return self.read16(bus, dev, func, 0x02);
    }

    pub fn readHeaderType(self: Self, bus: u8, dev: u5, func: u3) u8 {
        return self.read8(bus, dev, func, 0x0E);
    }

    pub fn readClassCode(self: Self, bus: u8, dev: u5, func: u3) u8 {
        return self.read8(bus, dev, func, 0x0B);
    }

    pub fn readSubclass(self: Self, bus: u8, dev: u5, func: u3) u8 {
        return self.read8(bus, dev, func, 0x0A);
    }

    pub fn readCommand(self: Self, bus: u8, dev: u5, func: u3) u16 {
        return self.read16(bus, dev, func, 0x04);
    }

    pub fn writeCommand(self: Self, bus: u8, dev: u5, func: u3, value: u16) void {
        self.write16(bus, dev, func, 0x04, value);
    }

    pub fn enableBusMaster(self: Self, bus: u8, dev: u5, func: u3) void {
        const cmd = self.readCommand(bus, dev, func);
        self.writeCommand(bus, dev, func, cmd | 0x04);
    }

    pub fn enableMemorySpace(self: Self, bus: u8, dev: u5, func: u3) void {
        const cmd = self.readCommand(bus, dev, func);
        self.writeCommand(bus, dev, func, cmd | 0x02);
    }

    pub fn readBar(self: Self, bus: u8, dev: u5, func: u3, bar_index: u3) u32 {
        const offset: u12 = 0x10 + @as(u12, bar_index) * 4;
        return self.read32(bus, dev, func, offset);
    }

    pub fn writeBar(self: Self, bus: u8, dev: u5, func: u3, bar_index: u3, value: u32) void {
        const offset: u12 = 0x10 + @as(u12, bar_index) * 4;
        self.write32(bus, dev, func, offset, value);
    }

    pub fn readIrqLine(self: Self, bus: u8, dev: u5, func: u3) u8 {
        return self.read8(bus, dev, func, 0x3C);
    }

    pub fn readIrqPin(self: Self, bus: u8, dev: u5, func: u3) u8 {
        return self.read8(bus, dev, func, 0x3D);
    }
};
