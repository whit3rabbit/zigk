// Legacy PCI Configuration Access (Mechanism #1)
//
// Uses I/O ports 0xCF8 (Address) and 0xCFC (Data) to access configuration space.
// This is the fallback mechanism when ECAM (MMIO) is not available.
//
// SECURITY: The address+data port sequence is protected by a spinlock to prevent
// race conditions on SMP systems where concurrent accesses could interleave and
// cause reads/writes to the wrong device.
//
// Limitations:
// - Only supports the first 256 bytes of configuration space per device (Offsets 0x00-0xFF).
// - Supports buses 0-255.
//
// Reference: PCI Local Bus Specification 3.0, Section 3.2.2.3.2

const hal = @import("hal");
const sync = @import("sync");

/// Global spinlock protecting legacy PCI config space access.
/// SECURITY: Prevents race conditions between setAddress() and data port access
/// on SMP systems. Without this lock, CPU A could write an address, then CPU B
/// could overwrite it before CPU A reads/writes the data port.
var legacy_pci_lock: sync.Spinlock = .{};

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
    /// SECURITY: Acquires spinlock to prevent race with other CPUs
    pub fn read8(_: *const Self, bus: u8, device: u5, func: u3, offset: u12) u8 {
        // Legacy PCI only supports offsets 0-255
        if (offset >= 256) return 0xFF;

        const held = legacy_pci_lock.acquire();
        defer held.release();

        setAddress(bus, device, func, @intCast(offset));
        return hal.io.inb(CONFIG_DATA + (@as(u16, @intCast(offset)) & 3));
    }

    /// Read 16-bit value from config space
    /// SECURITY: Acquires spinlock to prevent race with other CPUs
    pub fn read16(_: *const Self, bus: u8, device: u5, func: u3, offset: u12) u16 {
        // Legacy PCI: 256 bytes max. For 16-bit read, last valid offset is 254 (reads 254-255).
        if (offset > 254) return 0xFFFF;

        const held = legacy_pci_lock.acquire();
        defer held.release();

        setAddress(bus, device, func, @intCast(offset));
        return hal.io.inw(CONFIG_DATA + (@as(u16, @intCast(offset)) & 2));
    }

    /// Read 32-bit value from config space
    /// SECURITY: Acquires spinlock to prevent race with other CPUs
    pub fn read32(_: *const Self, bus: u8, device: u5, func: u3, offset: u12) u32 {
        // Legacy PCI: 256 bytes max. For 32-bit read, last valid offset is 252 (reads 252-255).
        if (offset > 252) return 0xFFFFFFFF;

        const held = legacy_pci_lock.acquire();
        defer held.release();

        setAddress(bus, device, func, @intCast(offset));
        return hal.io.inl(CONFIG_DATA);
    }

    /// Write 8-bit value to config space
    /// SECURITY: Acquires spinlock to prevent race with other CPUs
    pub fn write8(_: *const Self, bus: u8, device: u5, func: u3, offset: u12, value: u8) void {
        if (offset >= 256) return;

        const held = legacy_pci_lock.acquire();
        defer held.release();

        setAddress(bus, device, func, @intCast(offset));
        hal.io.outb(CONFIG_DATA + (@as(u16, @intCast(offset)) & 3), value);
    }

    /// Write 16-bit value to config space
    /// SECURITY: Acquires spinlock to prevent race with other CPUs
    pub fn write16(_: *const Self, bus: u8, device: u5, func: u3, offset: u12, value: u16) void {
        // Legacy PCI: 256 bytes max. For 16-bit write, last valid offset is 254 (writes 254-255).
        if (offset > 254) return;

        const held = legacy_pci_lock.acquire();
        defer held.release();

        setAddress(bus, device, func, @intCast(offset));
        hal.io.outw(CONFIG_DATA + (@as(u16, @intCast(offset)) & 2), value);
    }

    /// Write 32-bit value to config space
    /// SECURITY: Acquires spinlock to prevent race with other CPUs
    pub fn write32(_: *const Self, bus: u8, device: u5, func: u3, offset: u12, value: u32) void {
        // Legacy PCI: 256 bytes max. For 32-bit write, last valid offset is 252 (writes 252-255).
        if (offset > 252) return;

        const held = legacy_pci_lock.acquire();
        defer held.release();

        setAddress(bus, device, func, @intCast(offset));
        hal.io.outl(CONFIG_DATA, value);
    }
};
