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

    // Audio Devices
    pub const AC97_82801AA: u16 = 0x2415; // Intel 82801AA AC'97 Audio Controller
    pub const HDA_ICH6: u16 = 0x2668;     // Intel ICH6 (82801FB) HDA Controller
    pub const HDA_ICH7: u16 = 0x27D8;     // Intel ICH7 (82801GB) HDA Controller
};

/// VirtIO Device IDs (non-transitional, modern)
pub const VirtioDeviceId = struct {
    // Modern (non-transitional) device IDs (0x1040 + device_type)
    pub const GPU: u16 = 0x1050; // 0x1040 + 16 (GPU device type)
    pub const INPUT: u16 = 0x1052; // 0x1040 + 18 (input device type)
    pub const NETWORK: u16 = 0x1041; // 0x1040 + 1
    pub const BLOCK: u16 = 0x1042; // 0x1040 + 2
    pub const CONSOLE: u16 = 0x1043; // 0x1040 + 3
    pub const RNG: u16 = 0x1044; // 0x1040 + 4
    pub const BALLOON: u16 = 0x1045; // 0x1040 + 5

    // Legacy (transitional) device IDs
    pub const LEGACY_NETWORK: u16 = 0x1000;
    pub const LEGACY_BLOCK: u16 = 0x1001;
    pub const LEGACY_BALLOON: u16 = 0x1002;
    pub const LEGACY_CONSOLE: u16 = 0x1003;
    pub const LEGACY_RNG: u16 = 0x1005;
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

/// Serial Bus Controller Subclass Codes (Class 0x0C)
pub const SerialBusSubclass = struct {
    pub const FIREWIRE: u8 = 0x00;
    pub const ACCESS_BUS: u8 = 0x01;
    pub const SSA: u8 = 0x02;
    pub const USB: u8 = 0x03;
    pub const FIBRE_CHANNEL: u8 = 0x04;
    pub const SMBUS: u8 = 0x05;
    pub const INFINIBAND: u8 = 0x06;
    pub const IPMI: u8 = 0x07;
    pub const SERCOS: u8 = 0x08;
    pub const CANBUS: u8 = 0x09;
};

/// USB Controller Programming Interface (ProgIF) values
/// These identify the specific USB host controller type
pub const UsbProgIf = struct {
    pub const UHCI: u8 = 0x00; // Universal Host Controller Interface (USB 1.1, Intel)
    pub const OHCI: u8 = 0x10; // Open Host Controller Interface (USB 1.1, others)
    pub const EHCI: u8 = 0x20; // Enhanced Host Controller Interface (USB 2.0)
    pub const XHCI: u8 = 0x30; // Extensible Host Controller Interface (USB 3.x)
    pub const UNSPECIFIED: u8 = 0x80;
    pub const USB_DEVICE: u8 = 0xFE; // USB device (not host controller)
};

/// PCI Capability IDs
pub const CapabilityId = struct {
    pub const PM: u8 = 0x01; // Power Management
    pub const AGP: u8 = 0x02; // AGP
    pub const VPD: u8 = 0x03; // Vital Product Data
    pub const SLOT_ID: u8 = 0x04; // Slot Identification
    pub const MSI: u8 = 0x05; // Message Signaled Interrupts
    pub const COMPACT_PCI: u8 = 0x06; // CompactPCI Hot Swap
    pub const PCIX: u8 = 0x07; // PCI-X
    pub const HYPERTRANSPORT: u8 = 0x08; // HyperTransport
    pub const VENDOR: u8 = 0x09; // Vendor Specific
    pub const DEBUG: u8 = 0x0A; // Debug Port
    pub const RESOURCE_CTRL: u8 = 0x0B; // CompactPCI Central Resource Control
    pub const HOT_PLUG: u8 = 0x0C; // PCI Hot-Plug
    pub const BRIDGE_SUBSYS_VID: u8 = 0x0D; // Bridge Subsystem Vendor ID
    pub const AGP8X: u8 = 0x0E; // AGP 8x
    pub const SECURE: u8 = 0x0F; // Secure Device
    pub const PCIE: u8 = 0x10; // PCI Express
    pub const MSIX: u8 = 0x11; // MSI-X
    pub const SATA: u8 = 0x12; // SATA Data/Index Configuration
    pub const ADVANCED_FEATURES: u8 = 0x13; // Advanced Features
    pub const ENHANCED_ALLOC: u8 = 0x14; // Enhanced Allocation
    pub const FLATTENING_PORTAL: u8 = 0x15; // Flattening Portal Bridge
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

    /// Global System Interrupt (GSI)
    gsi: u32,

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

    /// Check if device is a USB controller (any type)
    pub fn isUsbController(self: *const Self) bool {
        return self.class_code == ClassCode.SERIAL_BUS and
            self.subclass == SerialBusSubclass.USB;
    }

    /// Check if device is an XHCI (USB 3.x) controller
    pub fn isXhciController(self: *const Self) bool {
        return self.isUsbController() and self.prog_if == UsbProgIf.XHCI;
    }

    /// Check if device is an EHCI (USB 2.0) controller
    pub fn isEhciController(self: *const Self) bool {
        return self.isUsbController() and self.prog_if == UsbProgIf.EHCI;
    }

    /// Check if device is a UHCI (USB 1.1 Intel) controller
    pub fn isUhciController(self: *const Self) bool {
        return self.isUsbController() and self.prog_if == UsbProgIf.UHCI;
    }

    /// Check if device is an OHCI (USB 1.1 Open) controller
    pub fn isOhciController(self: *const Self) bool {
        return self.isUsbController() and self.prog_if == UsbProgIf.OHCI;
    }

    /// Check if device is a VirtIO device
    pub fn isVirtio(self: *const Self) bool {
        return self.vendor_id == VendorId.VIRTIO;
    }

    /// Check if device is a VirtIO-GPU
    pub fn isVirtioGpu(self: *const Self) bool {
        return self.vendor_id == VendorId.VIRTIO and
            self.device_id == VirtioDeviceId.GPU;
    }

    /// Check if device is a display controller
    pub fn isDisplayController(self: *const Self) bool {
        return self.class_code == ClassCode.DISPLAY;
    }

    /// Check if device is an AC97 controller
    pub fn isAc97Controller(self: *const Self) bool {
        return self.vendor_id == VendorId.INTEL and self.device_id == IntelDeviceId.AC97_82801AA;
    }

    /// Check if device is an Intel HDA controller
    pub fn isHdaController(self: *const Self) bool {
        return self.vendor_id == VendorId.INTEL and
            (self.device_id == IntelDeviceId.HDA_ICH6 or
             self.device_id == IntelDeviceId.HDA_ICH7);
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
            .gsi = 0,
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

    /// Find first E1000e (PCIe) NIC (82574L, etc.)
    pub fn findE1000e(self: *const DeviceList) ?*const PciDevice {
        for (self.devices[0..self.count]) |*dev| {
            if (dev.isE1000e()) {
                return dev;
            }
        }
        return null;
    }

    /// Find first AC97 controller
    pub fn findAc97Controller(self: *const DeviceList) ?*const PciDevice {
        return self.findDevice(VendorId.INTEL, IntelDeviceId.AC97_82801AA);
    }

    /// Find first Intel HDA controller
    pub fn findHdaController(self: *const DeviceList) ?*const PciDevice {
        if (self.findDevice(VendorId.INTEL, IntelDeviceId.HDA_ICH6)) |dev| return dev;
        return self.findDevice(VendorId.INTEL, IntelDeviceId.HDA_ICH7);
    }

    /// Find first USB controller of a specific type by ProgIF
    pub fn findUsbController(self: *const DeviceList, prog_if: u8) ?*const PciDevice {
        for (self.devices[0..self.count]) |*dev| {
            if (dev.isUsbController() and dev.prog_if == prog_if) {
                return dev;
            }
        }
        return null;
    }

    /// Find first XHCI (USB 3.x) controller
    pub fn findXhciController(self: *const DeviceList) ?*const PciDevice {
        return self.findUsbController(UsbProgIf.XHCI);
    }

    /// Find first EHCI (USB 2.0) controller
    pub fn findEhciController(self: *const DeviceList) ?*const PciDevice {
        return self.findUsbController(UsbProgIf.EHCI);
    }

    /// Find first UHCI (USB 1.1 Intel) controller
    pub fn findUhciController(self: *const DeviceList) ?*const PciDevice {
        return self.findUsbController(UsbProgIf.UHCI);
    }

    /// Find first OHCI (USB 1.1 Open) controller
    pub fn findOhciController(self: *const DeviceList) ?*const PciDevice {
        return self.findUsbController(UsbProgIf.OHCI);
    }

    /// Find any USB controller (returns first found, prefers XHCI > EHCI > UHCI > OHCI)
    pub fn findAnyUsbController(self: *const DeviceList) ?*const PciDevice {
        if (self.findXhciController()) |dev| return dev;
        if (self.findEhciController()) |dev| return dev;
        if (self.findUhciController()) |dev| return dev;
        if (self.findOhciController()) |dev| return dev;
        return null;
    }

    /// Find device by class, subclass, and optionally prog_if
    pub fn findByClass(self: *const DeviceList, class_code: u8, subclass: u8, prog_if: ?u8) ?*const PciDevice {
        for (self.devices[0..self.count]) |*dev| {
            if (dev.class_code == class_code and dev.subclass == subclass) {
                if (prog_if) |pif| {
                    if (dev.prog_if == pif) return dev;
                } else {
                    return dev;
                }
            }
        }
        return null;
    }
};
