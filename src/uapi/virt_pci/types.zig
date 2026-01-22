// Virtual PCI Device Types
//
// UAPI types for the pciem-compatible virtual PCI device framework.
// These structures are shared between kernel and userspace.
//
// ABI Compatibility:
//   - All structures use extern for C-compatible layout
//   - Fixed sizes verified at comptime
//   - Cache line alignment where needed for performance

const std = @import("std");

// =============================================================================
// Virtual PCI Configuration Header
// =============================================================================

/// Virtual PCI configuration header structure
/// Matches standard PCI Type 0 configuration space header layout
pub const VPciConfigHeader = extern struct {
    /// Vendor ID
    vendor_id: u16,
    /// Device ID
    device_id: u16,
    /// Command register
    command: u16,
    /// Status register
    status: u16,
    /// Revision ID
    revision_id: u8,
    /// Programming Interface
    prog_if: u8,
    /// Subclass code
    subclass: u8,
    /// Class code
    class_code: u8,
    /// Cache line size
    cache_line_size: u8,
    /// Latency timer
    latency_timer: u8,
    /// Header type (0 for normal devices)
    header_type: u8,
    /// BIST
    bist: u8,
    /// Subsystem vendor ID
    subsystem_vendor_id: u16,
    /// Subsystem ID
    subsystem_id: u16,
    /// Interrupt line
    interrupt_line: u8,
    /// Interrupt pin (0=none, 1=INTA, 2=INTB, etc.)
    interrupt_pin: u8,
    /// Min grant
    min_grant: u8,
    /// Max latency
    max_latency: u8,

    comptime {
        if (@sizeOf(@This()) != 24) @compileError("VPciConfigHeader must be 24 bytes");
    }

    pub fn init() VPciConfigHeader {
        return .{
            .vendor_id = 0xFFFF,
            .device_id = 0xFFFF,
            .command = 0,
            .status = 0x0010, // Capabilities list bit
            .revision_id = 0,
            .prog_if = 0,
            .subclass = 0,
            .class_code = 0,
            .cache_line_size = 0,
            .latency_timer = 0,
            .header_type = 0,
            .bist = 0,
            .subsystem_vendor_id = 0,
            .subsystem_id = 0,
            .interrupt_line = 0,
            .interrupt_pin = 0,
            .min_grant = 0,
            .max_latency = 0,
        };
    }
};

// =============================================================================
// BAR Configuration
// =============================================================================

/// BAR type flags
pub const BarFlags = packed struct(u16) {
    /// MMIO (true) vs I/O port (false)
    is_mmio: bool = true,
    /// 64-bit BAR (consumes two BAR slots)
    is_64bit: bool = false,
    /// Prefetchable memory
    prefetchable: bool = false,
    /// Intercept MMIO accesses (forward to userspace via event ring)
    intercept_mmio: bool = true,
    /// Reserved
    _reserved: u12 = 0,
};

/// Virtual BAR configuration for sys_vpci_add_bar
pub const VPciBarConfig = extern struct {
    /// BAR index (0-5)
    bar_index: u8,
    /// Reserved for alignment
    _reserved: u8 = 0,
    /// BAR flags
    flags: BarFlags,
    /// Reserved for alignment
    _pad: u32 = 0,
    /// BAR size in bytes (must be power of 2, >= 4KB)
    size: u64,

    comptime {
        if (@sizeOf(@This()) != 16) @compileError("VPciBarConfig must be 16 bytes");
    }
};

/// BAR info returned by sys_vpci_get_bar_info
pub const VPciBarInfo = extern struct {
    /// Physical address (set after registration)
    phys_addr: u64,
    /// Kernel virtual address (for backing memory)
    virt_addr: u64,
    /// Size in bytes
    size: u64,
    /// BAR flags
    flags: BarFlags,
    /// Reserved
    _pad: [6]u8 = [_]u8{0} ** 6,

    comptime {
        if (@sizeOf(@This()) != 32) @compileError("VPciBarInfo must be 32 bytes");
    }
};

// =============================================================================
// Capability Configuration
// =============================================================================

/// PCI Capability types supported by virtual devices
pub const VPciCapType = enum(u8) {
    /// Power Management capability
    pm = 0x01,
    /// MSI capability
    msi = 0x05,
    /// MSI-X capability
    msix = 0x11,
    /// PCI Express capability
    pcie = 0x10,
    /// Vendor specific
    vendor = 0x09,
};

/// MSI capability configuration
pub const VPciMsiConfig = extern struct {
    /// Maximum vectors requested (1, 2, 4, 8, 16, or 32)
    max_vectors: u8,
    /// 64-bit address capable
    is_64bit: bool,
    /// Per-vector masking capable
    per_vector_mask: bool,
    /// Reserved
    _reserved: [5]u8 = [_]u8{0} ** 5,

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("VPciMsiConfig must be 8 bytes");
    }
};

/// MSI-X capability configuration
pub const VPciMsixConfig = extern struct {
    /// Number of MSI-X vectors (1-2048)
    table_size: u16,
    /// BAR index for MSI-X table
    table_bar: u8,
    /// BAR index for PBA
    pba_bar: u8,
    /// Offset within table BAR
    table_offset: u32,
    /// Offset within PBA BAR
    pba_offset: u32,
    /// Reserved
    _pad: u32 = 0,

    comptime {
        if (@sizeOf(@This()) != 16) @compileError("VPciMsixConfig must be 16 bytes");
    }
};

/// Power Management capability configuration
pub const VPciPmConfig = extern struct {
    /// PM capabilities (D1/D2 support, aux power, etc.)
    pm_caps: u16,
    /// Reserved
    _reserved: [6]u8 = [_]u8{0} ** 6,

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("VPciPmConfig must be 8 bytes");
    }
};

/// Capability configuration union for sys_vpci_add_cap
pub const VPciCapConfig = extern struct {
    /// Capability type
    cap_type: VPciCapType,
    /// Reserved for alignment
    _reserved: [7]u8 = [_]u8{0} ** 7,
    /// Type-specific configuration (union in C, use bytes here)
    config_data: [16]u8,

    comptime {
        if (@sizeOf(@This()) != 24) @compileError("VPciCapConfig must be 24 bytes");
    }

    pub fn forMsi(cfg: VPciMsiConfig) VPciCapConfig {
        var result = VPciCapConfig{
            .cap_type = .msi,
            .config_data = undefined,
        };
        @memcpy(result.config_data[0..@sizeOf(VPciMsiConfig)], std.mem.asBytes(&cfg));
        @memset(result.config_data[@sizeOf(VPciMsiConfig)..], 0);
        return result;
    }

    pub fn forMsix(cfg: VPciMsixConfig) VPciCapConfig {
        var result = VPciCapConfig{
            .cap_type = .msix,
            .config_data = undefined,
        };
        @memcpy(result.config_data[0..@sizeOf(VPciMsixConfig)], std.mem.asBytes(&cfg));
        return result;
    }

    pub fn forPm(cfg: VPciPmConfig) VPciCapConfig {
        var result = VPciCapConfig{
            .cap_type = .pm,
            .config_data = undefined,
        };
        @memcpy(result.config_data[0..@sizeOf(VPciPmConfig)], std.mem.asBytes(&cfg));
        @memset(result.config_data[@sizeOf(VPciPmConfig)..], 0);
        return result;
    }

    pub fn getMsiConfig(self: *const VPciCapConfig) ?VPciMsiConfig {
        if (self.cap_type != .msi) return null;
        return @bitCast(self.config_data[0..@sizeOf(VPciMsiConfig)].*);
    }

    pub fn getMsixConfig(self: *const VPciCapConfig) ?VPciMsixConfig {
        if (self.cap_type != .msix) return null;
        return @bitCast(self.config_data[0..@sizeOf(VPciMsixConfig)].*);
    }
};

// =============================================================================
// DMA Operations
// =============================================================================

/// DMA operation direction
pub const VPciDmaDir = enum(u8) {
    /// Read from guest memory to device
    to_device = 0,
    /// Write from device to guest memory
    from_device = 1,
};

/// DMA operation request for sys_vpci_dma
pub const VPciDmaOp = extern struct {
    /// Device ID
    device_id: u32,
    /// Direction
    direction: VPciDmaDir,
    /// Reserved
    _reserved: [3]u8 = [_]u8{0} ** 3,
    /// Guest IOVA (I/O Virtual Address)
    iova: u64,
    /// Host buffer pointer (userspace)
    host_buffer: u64,
    /// Transfer length in bytes
    length: u64,

    comptime {
        if (@sizeOf(@This()) != 32) @compileError("VPciDmaOp must be 32 bytes");
    }
};

// =============================================================================
// Interrupt Injection
// =============================================================================

/// Interrupt type for sys_vpci_inject_irq
pub const VPciIrqType = enum(u8) {
    /// Legacy INTx (not recommended)
    intx = 0,
    /// MSI interrupt
    msi = 1,
    /// MSI-X interrupt
    msix = 2,
};

/// Interrupt injection request
pub const VPciIrqConfig = extern struct {
    /// Device ID
    device_id: u32,
    /// Interrupt type
    irq_type: VPciIrqType,
    /// Reserved
    _reserved: [3]u8 = [_]u8{0} ** 3,
    /// Vector number (for MSI/MSI-X)
    vector: u16,
    /// Reserved
    _pad: [6]u8 = [_]u8{0} ** 6,

    comptime {
        if (@sizeOf(@This()) != 16) @compileError("VPciIrqConfig must be 16 bytes");
    }
};

// =============================================================================
// Device State
// =============================================================================

/// Virtual device state
pub const VPciDeviceState = enum(u8) {
    /// Device created, not yet configured
    created = 0,
    /// Device being configured (BARs, capabilities)
    configuring = 1,
    /// Device registered with PCI subsystem
    registered = 2,
    /// Device active and handling MMIO
    active = 3,
    /// Device being torn down
    closing = 4,
};

/// Device info returned by various operations
pub const VPciDeviceInfo = extern struct {
    /// Device ID
    device_id: u32,
    /// Current state
    state: VPciDeviceState,
    /// Number of configured BARs
    bar_count: u8,
    /// Number of configured capabilities
    cap_count: u8,
    /// Reserved
    _reserved: u8 = 0,
    /// Event ring ID (valid after registration)
    ring_id: u32,
    /// Reserved
    _pad: u32 = 0,

    comptime {
        if (@sizeOf(@This()) != 16) @compileError("VPciDeviceInfo must be 16 bytes");
    }
};

// =============================================================================
// Constants
// =============================================================================

/// Maximum virtual PCI devices per process
pub const MAX_DEVICES_PER_PROCESS: u32 = 16;

/// Maximum system-wide virtual PCI devices
pub const MAX_DEVICES: u32 = 256;

/// Maximum BAR size (256 MB)
pub const MAX_BAR_SIZE: u64 = 256 * 1024 * 1024;

/// Minimum BAR size (4 KB)
pub const MIN_BAR_SIZE: u64 = 4096;

/// Maximum MSI-X vectors
pub const MAX_MSIX_VECTORS: u16 = 2048;

/// Virtual PCI bus number for emulated devices
pub const VIRTUAL_BUS_NUMBER: u8 = 0xFE;
