// PCI Device Structure and Types
//
// Defines the PCI device representation and BAR (Base Address Register) handling.
// Used by enumeration and drivers to work with discovered PCI devices.
//
// Reference: PCI Local Bus Specification 3.0

/// PCI Vendor IDs for common devices
pub const VendorId = struct {
    pub const INTEL: u16 = 0x8086;
    pub const AMD: u16 = 0x1022;
    pub const NVIDIA: u16 = 0x10DE;
    pub const QEMU: u16 = 0x1234;
    pub const VIRTIO: u16 = 0x1AF4;
    pub const REALTEK: u16 = 0x10EC;
};

/// Intel Network Device IDs
pub const IntelDeviceId = struct {
    // E1000 family (legacy)
    pub const E1000_82540EM: u16 = 0x100E; // QEMU e1000
    pub const E1000_82545EM: u16 = 0x100F;

    // E1000e family (82574L - our target)
    pub const E1000E_82574L: u16 = 0x10D3;
    pub const E1000E_82574L_2: u16 = 0x10F6;
    pub const E1000E_82583V: u16 = 0x150C;
};

/// PCI Class Codes
pub const ClassCode = struct {
    pub const UNCLASSIFIED: u8 = 0x00;
    pub const MASS_STORAGE: u8 = 0x01;
    pub const NETWORK: u8 = 0x02;
    pub const DISPLAY: u8 = 0x03;
    pub const MULTIMEDIA: u8 = 0x04;
    pub const MEMORY: u8 = 0x05;
    pub const BRIDGE: u8 = 0x06;
    pub const SIMPLE_COMM: u8 = 0x07;
    pub const BASE_PERIPHERAL: u8 = 0x08;
    pub const INPUT: u8 = 0x09;
    pub const DOCKING: u8 = 0x0A;
    pub const PROCESSOR: u8 = 0x0B;
    pub const SERIAL_BUS: u8 = 0x0C;
    pub const WIRELESS: u8 = 0x0D;
    pub const INTELLIGENT_IO: u8 = 0x0E;
    pub const SATELLITE: u8 = 0x0F;
    pub const ENCRYPTION: u8 = 0x10;
    pub const SIGNAL_PROCESSING: u8 = 0x11;
};

/// Network Controller Subclass Codes
pub const NetworkSubclass = struct {
    pub const ETHERNET: u8 = 0x00;
    pub const TOKEN_RING: u8 = 0x01;
    pub const FDDI: u8 = 0x02;
    pub const ATM: u8 = 0x03;
    pub const ISDN: u8 = 0x04;
    pub const WORLDFIP: u8 = 0x05;
    pub const PICMG: u8 = 0x06;
    pub const INFINIBAND: u8 = 0x07;
    pub const FABRIC: u8 = 0x08;
    pub const OTHER: u8 = 0x80;
};

/// PCI Configuration Space Register Offsets
pub const ConfigReg = struct {
    pub const VENDOR_ID: u12 = 0x00;
    pub const DEVICE_ID: u12 = 0x02;
    pub const COMMAND: u12 = 0x04;
    pub const STATUS: u12 = 0x06;
    pub const REVISION_ID: u12 = 0x08;
    pub const PROG_IF: u12 = 0x09;
    pub const SUBCLASS: u12 = 0x0A;
    pub const CLASS_CODE: u12 = 0x0B;
    pub const CACHE_LINE_SIZE: u12 = 0x0C;
    pub const LATENCY_TIMER: u12 = 0x0D;
    pub const HEADER_TYPE: u12 = 0x0E;
    pub const BIST: u12 = 0x0F;
    pub const BAR0: u12 = 0x10;
    pub const BAR1: u12 = 0x14;
    pub const BAR2: u12 = 0x18;
    pub const BAR3: u12 = 0x1C;
    pub const BAR4: u12 = 0x20;
    pub const BAR5: u12 = 0x24;
    pub const CARDBUS_CIS: u12 = 0x28;
    pub const SUBSYSTEM_VENDOR: u12 = 0x2C;
    pub const SUBSYSTEM_ID: u12 = 0x2E;
    pub const EXPANSION_ROM: u12 = 0x30;
    pub const CAPABILITIES: u12 = 0x34;
    pub const INTERRUPT_LINE: u12 = 0x3C;
    pub const INTERRUPT_PIN: u12 = 0x3D;
    pub const MIN_GRANT: u12 = 0x3E;
    pub const MAX_LATENCY: u12 = 0x3F;
};

/// PCI Command Register bits
pub const Command = struct {
    pub const IO_SPACE: u16 = 1 << 0;
    pub const MEMORY_SPACE: u16 = 1 << 1;
    pub const BUS_MASTER: u16 = 1 << 2;
    pub const SPECIAL_CYCLES: u16 = 1 << 3;
    pub const MWI_ENABLE: u16 = 1 << 4;
    pub const VGA_SNOOP: u16 = 1 << 5;
    pub const PARITY_ERROR_RESP: u16 = 1 << 6;
    pub const SERR_ENABLE: u16 = 1 << 8;
    pub const FAST_B2B_ENABLE: u16 = 1 << 9;
    pub const INTERRUPT_DISABLE: u16 = 1 << 10;
};

/// Base Address Register (BAR) representation
pub const Bar = struct {
    /// Physical base address (aligned)
    base: u64,
    /// Size of the BAR region in bytes
    size: u64,
    /// True if memory-mapped, false if I/O port
    is_mmio: bool,
    /// True if this is a 64-bit BAR (consumes two BAR slots)
    is_64bit: bool,
    /// True if memory is prefetchable (MMIO only)
    prefetchable: bool,
    /// BAR type for debug purposes
    bar_type: BarType,

    pub const BarType = enum {
        unused,
        io,
        mmio_32bit,
        mmio_64bit,
    };

    /// Create an unused BAR entry
    pub fn unused() Bar {
        return Bar{
            .base = 0,
            .size = 0,
            .is_mmio = false,
            .is_64bit = false,
            .prefetchable = false,
            .bar_type = .unused,
        };
    }

    /// Check if BAR is valid (non-zero size)
    pub fn isValid(self: Bar) bool {
        return self.size > 0;
    }
};

/// PCI Device structure
pub const PciDevice = struct {
    /// Bus number (0-255)
    bus: u8,
    /// Device number (0-31)
    device: u5,
    /// Function number (0-7)
    func: u3,

    /// Vendor ID
    vendor_id: u16,
    /// Device ID
    device_id: u16,

    /// Revision ID
    revision: u8,
    /// Programming Interface
    prog_if: u8,
    /// Subclass code
    subclass: u8,
    /// Class code
    class_code: u8,

    /// Header type (0=normal, 1=bridge, 2=cardbus)
    header_type: u8,

    /// Base Address Registers (up to 6 for type 0 headers)
    bar: [6]Bar,

    /// Interrupt line (IRQ number)
    irq_line: u8,
    /// Interrupt pin (0=none, 1=INTA, 2=INTB, etc.)
    irq_pin: u8,

    /// Subsystem vendor ID
    subsystem_vendor: u16,
    /// Subsystem ID
    subsystem_id: u16,

    const Self = @This();

    /// Check if device is an Intel E1000e (82574L)
    pub fn isE1000e(self: *const Self) bool {
        return self.vendor_id == VendorId.INTEL and
            (self.device_id == IntelDeviceId.E1000E_82574L or
            self.device_id == IntelDeviceId.E1000E_82574L_2);
    }

    /// Check if device is any Intel E1000 variant
    pub fn isE1000(self: *const Self) bool {
        return self.vendor_id == VendorId.INTEL and
            (self.device_id == IntelDeviceId.E1000_82540EM or
            self.device_id == IntelDeviceId.E1000_82545EM or
            self.isE1000e());
    }

    /// Check if device is a network controller
    pub fn isNetworkController(self: *const Self) bool {
        return self.class_code == ClassCode.NETWORK;
    }

    /// Check if device is an Ethernet controller
    pub fn isEthernetController(self: *const Self) bool {
        return self.class_code == ClassCode.NETWORK and
            self.subclass == NetworkSubclass.ETHERNET;
    }

    /// Get the first valid MMIO BAR (for NIC drivers)
    pub fn getMmioBar(self: *const Self) ?Bar {
        for (self.bar) |b| {
            if (b.isValid() and b.is_mmio) {
                return b;
            }
        }
        return null;
    }

    /// Get BDF (Bus:Device.Function) as a single value
    pub fn getBdf(self: *const Self) u16 {
        return (@as(u16, self.bus) << 8) |
            (@as(u16, self.device) << 3) |
            @as(u16, self.func);
    }

    /// Create an empty/invalid device
    pub fn empty() Self {
        return Self{
            .bus = 0,
            .device = 0,
            .func = 0,
            .vendor_id = 0xFFFF,
            .device_id = 0xFFFF,
            .revision = 0,
            .prog_if = 0,
            .subclass = 0,
            .class_code = 0,
            .header_type = 0,
            .bar = [_]Bar{Bar.unused()} ** 6,
            .irq_line = 0,
            .irq_pin = 0,
            .subsystem_vendor = 0,
            .subsystem_id = 0,
        };
    }

    /// Check if device is valid (not 0xFFFF vendor)
    pub fn isValid(self: *const Self) bool {
        return self.vendor_id != 0xFFFF;
    }
};

/// Device list for storing discovered devices
pub const DeviceList = struct {
    devices: [MAX_DEVICES]PciDevice,
    count: usize,

    pub const MAX_DEVICES = 64;

    pub fn init() DeviceList {
        return DeviceList{
            .devices = [_]PciDevice{PciDevice.empty()} ** MAX_DEVICES,
            .count = 0,
        };
    }

    pub fn add(self: *DeviceList, device: PciDevice) bool {
        if (self.count >= MAX_DEVICES) {
            return false;
        }
        self.devices[self.count] = device;
        self.count += 1;
        return true;
    }

    pub fn get(self: *const DeviceList, index: usize) ?*const PciDevice {
        if (index >= self.count) {
            return null;
        }
        return &self.devices[index];
    }

    /// Find first device matching vendor/device ID
    pub fn findDevice(self: *const DeviceList, vendor_id: u16, device_id: u16) ?*const PciDevice {
        for (self.devices[0..self.count]) |*dev| {
            if (dev.vendor_id == vendor_id and dev.device_id == device_id) {
                return dev;
            }
        }
        return null;
    }

    /// Find first Ethernet controller
    pub fn findEthernetController(self: *const DeviceList) ?*const PciDevice {
        for (self.devices[0..self.count]) |*dev| {
            if (dev.isEthernetController()) {
                return dev;
            }
        }
        return null;
    }

    /// Find first E1000/E1000e NIC
    pub fn findE1000(self: *const DeviceList) ?*const PciDevice {
        for (self.devices[0..self.count]) |*dev| {
            if (dev.isE1000()) {
                return dev;
            }
        }
        return null;
    }
};
