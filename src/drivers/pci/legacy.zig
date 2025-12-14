// Legacy PCI Configuration Access (Mechanism #1)
//
// Uses I/O ports 0xCF8 (Address) and 0xCFC (Data) to access configuration space.
// This is the fallback mechanism when ECAM (MMIO) is not available.
//
// Limitations:
// - Access is serialized via global I/O ports (requires locking if multithreaded, though PCI scan is usually single-threaded at boot).
// - Only supports the first 256 bytes of configuration space per device (Offsets 0x00-0xFF).
// - Supports buses 0-255.
//
// Reference: PCI Local Bus Specification 3.0, Section 3.2.2.3.2

const hal = @import("hal");

pub const Legacy = struct {
    start_bus: u8 = 0,
    end_bus: u8 = 255,

    const CONFIG_ADDRESS = 0xCF8;
    const CONFIG_DATA = 0xCFC;

    const Self = @This();

    /// Initialize Legacy PCI accessor
    pub fn init() Self {
        return Self{};
    }

    /// Write address to CONFIG_ADDRESS port
    /// Address Format:
    /// Bit 31: Enable (1)
    /// Bit 30-24: Reserved (0)
    /// Bit 23-16: Bus Number
    /// Bit 15-11: Device Number
    /// Bit 10-8: Function Number
    /// Bit 7-2: Register Number (DWORD index)
    /// Bit 1-0: 00 (Reserved/Type)
    fn setAddress(bus: u8, device: u5, func: u3, offset: u8) void {
        const address: u32 = 0x80000000 |
            (@as(u32, bus) << 16) |
            (@as(u32, device) << 11) |
            (@as(u32, func) << 8) |
            (@as(u32, offset) & 0xFC);

        hal.io.outl(CONFIG_ADDRESS, address);
    }

    /// Read 8-bit value from config space
    pub fn read8(_: *const Self, bus: u8, device: u5, func: u3, offset: u12) u8 {
        // Legacy PCI only supports offsets 0-255
        if (offset >= 256) return 0xFF;

        setAddress(bus, device, func, @intCast(offset));
        return hal.io.inb(CONFIG_DATA + (@as(u16, @intCast(offset)) & 3));
    }

    /// Read 16-bit value from config space
    pub fn read16(_: *const Self, bus: u8, device: u5, func: u3, offset: u12) u16 {
        if (offset >= 255) return 0xFFFF; // Need 2 bytes

        setAddress(bus, device, func, @intCast(offset));
        return hal.io.inw(CONFIG_DATA + (@as(u16, @intCast(offset)) & 2));
    }

    /// Read 32-bit value from config space
    pub fn read32(_: *const Self, bus: u8, device: u5, func: u3, offset: u12) u32 {
        if (offset >= 253) return 0xFFFFFFFF; // Need 4 bytes

        setAddress(bus, device, func, @intCast(offset));
        return hal.io.inl(CONFIG_DATA);
    }

    /// Write 8-bit value to config space
    pub fn write8(_: *const Self, bus: u8, device: u5, func: u3, offset: u12, value: u8) void {
        if (offset >= 256) return;

        setAddress(bus, device, func, @intCast(offset));
        hal.io.outb(CONFIG_DATA + (@as(u16, @intCast(offset)) & 3), value);
    }

    /// Write 16-bit value to config space
    pub fn write16(_: *const Self, bus: u8, device: u5, func: u3, offset: u12, value: u16) void {
        if (offset >= 255) return;

        setAddress(bus, device, func, @intCast(offset));
        hal.io.outw(CONFIG_DATA + (@as(u16, @intCast(offset)) & 2), value);
    }

    /// Write 32-bit value to config space
    pub fn write32(_: *const Self, bus: u8, device: u5, func: u3, offset: u12, value: u32) void {
        if (offset >= 253) return;

        setAddress(bus, device, func, @intCast(offset));
        hal.io.outl(CONFIG_DATA, value);
    }
};
