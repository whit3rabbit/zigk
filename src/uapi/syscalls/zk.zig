// ZK Custom Extensions
//
// These syscalls are unique to ZK and use numbers 1000+.

/// Write debug message to kernel log
pub const SYS_DEBUG_LOG: usize = 1000;
/// Get framebuffer info
pub const SYS_GET_FB_INFO: usize = 1001;
/// Map framebuffer into process address space
pub const SYS_MAP_FB: usize = 1002;
/// Flush framebuffer to display (trigger present)
pub const SYS_FB_FLUSH: usize = 1006;
/// Read raw keyboard scancode (non-blocking)
pub const SYS_READ_SCANCODE: usize = 1003;
/// Read ASCII character from input buffer (blocking)
pub const SYS_GETCHAR: usize = 1004;
/// Write character to console
pub const SYS_PUTCHAR: usize = 1005;

// Input/Mouse Syscalls (1010-1019)
/// Read next input event (non-blocking)
pub const SYS_READ_INPUT_EVENT: usize = 1010;
/// Get current cursor position
pub const SYS_GET_CURSOR_POSITION: usize = 1011;
/// Set cursor bounds (screen dimensions)
pub const SYS_SET_CURSOR_BOUNDS: usize = 1012;
/// Set input mode (relative/absolute/raw)
pub const SYS_SET_INPUT_MODE: usize = 1013;

// IPC & Microkernel Syscalls (1020-1029)
/// Send an IPC message to a process (blocking)
pub const SYS_SEND: usize = 1020;
/// Receive an IPC message (blocking)
pub const SYS_RECV: usize = 1021;
/// Wait for a hardware interrupt (blocking)
pub const SYS_WAIT_INTERRUPT: usize = 1022;
/// Connect kernel logger to IPC backend
pub const SYS_REGISTER_IPC_LOGGER: usize = 1025;
/// Register the current process as a named service
pub const SYS_REGISTER_SERVICE: usize = 1026;
/// Lookup a service PID by name
pub const SYS_LOOKUP_SERVICE: usize = 1027;

// DMA/MMIO Syscalls (1030-1039)
/// Map physical MMIO region into userspace
pub const SYS_MMAP_PHYS: usize = 1030;
/// Allocate DMA-capable memory with known physical address
pub const SYS_ALLOC_DMA: usize = 1031;
/// Free DMA memory previously allocated with SYS_ALLOC_DMA
pub const SYS_FREE_DMA: usize = 1032;
/// Enumerate PCI devices
pub const SYS_PCI_ENUMERATE: usize = 1033;
/// Read PCI configuration space register
pub const SYS_PCI_CONFIG_READ: usize = 1034;
/// Write PCI configuration space register
pub const SYS_PCI_CONFIG_WRITE: usize = 1035;

// Port I/O Syscalls (1036-1037)
/// Write byte to I/O port
pub const SYS_OUTB: usize = 1036;
/// Read byte from I/O port
pub const SYS_INB: usize = 1037;

// Ring Buffer IPC Syscalls (1040-1049)
/// Create a new ring buffer for zero-copy IPC
pub const SYS_RING_CREATE: usize = 1040;
/// Attach to an existing ring as consumer
pub const SYS_RING_ATTACH: usize = 1041;
/// Detach from a ring (producer or consumer)
pub const SYS_RING_DETACH: usize = 1042;
/// Wait for entries to become available (consumer)
pub const SYS_RING_WAIT: usize = 1043;
/// Notify consumer that entries are available (producer)
pub const SYS_RING_NOTIFY: usize = 1044;
/// Wait for entries on any of multiple rings (MPSC consumer)
pub const SYS_RING_WAIT_ANY: usize = 1045;

// IOMMU-protected DMA syscalls (1046-1047)
/// Allocate IOMMU-protected DMA memory for a specific device
pub const SYS_ALLOC_IOMMU_DMA: usize = 1046;
/// Free IOMMU-protected DMA memory
pub const SYS_FREE_IOMMU_DMA: usize = 1047;

// Hypervisor Syscalls (1050-1059)
/// Execute VMware hypercall command (requires CAP_HYPERVISOR)
pub const SYS_VMWARE_HYPERCALL: usize = 1050;
/// Get hypervisor type (returns HypervisorType enum value)
pub const SYS_GET_HYPERVISOR: usize = 1051;

// Network Interface Configuration Syscalls (1060-1069)
/// Configure network interface (requires CAP_NET_CONFIG)
/// arg1: interface index, arg2: command (NetifCmd), arg3: data_ptr, arg4: data_len
pub const SYS_NETIF_CONFIG: usize = 1060;

/// ARP probe for IP conflict detection (RFC 5227)
/// arg1: interface index, arg2: target IP (host order), arg3: timeout_ms
/// Returns: 0 = no conflict (safe), 1 = conflict detected, 2 = timeout (safe)
pub const SYS_ARP_PROBE: usize = 1061;

/// Gratuitous ARP announcement (RFC 5227)
/// arg1: interface index, arg2: IP address to announce (host order)
/// Returns: 0 on success
pub const SYS_ARP_ANNOUNCE: usize = 1062;

/// Network interface configuration commands
pub const NetifCmd = enum(u32) {
    /// Get interface info (MAC, name, link state) -> InterfaceInfo
    GetInfo = 0,
    /// Set IPv4 address, netmask, gateway <- Ipv4Config
    SetIpv4 = 1,
    /// Add/remove IPv6 address <- Ipv6AddrConfig
    SetIpv6Addr = 2,
    /// Set IPv6 default gateway <- [16]u8 address
    SetIpv6Gateway = 3,
    /// Get last Router Advertisement info (for SLAAC) -> RaInfo
    GetRaInfo = 4,
    /// Set interface MTU <- u16
    SetMtu = 5,
    /// Get link up/down state -> bool
    GetLinkState = 6,
};

/// IPv4 configuration structure for SET_IPV4 command
pub const Ipv4Config = extern struct {
    /// IPv4 address in network byte order
    ip_addr: u32,
    /// Subnet mask in network byte order
    netmask: u32,
    /// Gateway address in network byte order
    gateway: u32,

    comptime {
        if (@sizeOf(@This()) != 12) @compileError("Ipv4Config must be 12 bytes");
    }
};

/// IPv6 address configuration for SET_IPV6_ADDR command
pub const Ipv6AddrConfig = extern struct {
    /// IPv6 address (16 bytes)
    addr: [16]u8,
    /// Prefix length (0-128)
    prefix_len: u8,
    /// Address scope: 2=link-local, 5=site-local, 14=global
    scope: u8,
    /// Action: 0=add, 1=remove
    action: u8,
    /// Padding for alignment
    _pad: u8 = 0,

    pub const ACTION_ADD: u8 = 0;
    pub const ACTION_REMOVE: u8 = 1;

    comptime {
        if (@sizeOf(@This()) != 20) @compileError("Ipv6AddrConfig must be 20 bytes");
    }
};

/// Router Advertisement info (from kernel NDP processing)
pub const RaInfo = extern struct {
    /// Router source address
    router_addr: [16]u8,
    /// Prefix from PrefixInfo option
    prefix: [16]u8,
    /// Prefix length
    prefix_len: u8,
    /// RA flags: M (bit 7), O (bit 6), A (bit 5), L (bit 4)
    flags: u8,
    /// Padding
    _pad: [2]u8 = [_]u8{0} ** 2,
    /// Valid lifetime in seconds (0xFFFFFFFF = infinite)
    valid_lifetime: u32,
    /// Preferred lifetime in seconds
    preferred_lifetime: u32,
    /// MTU from RA (0 if not specified)
    mtu: u32,
    /// Kernel tick when RA was received
    timestamp: u64,

    /// Check if M-flag (managed address config) is set
    pub fn isManagedFlag(self: RaInfo) bool {
        return (self.flags & 0x80) != 0;
    }

    /// Check if O-flag (other config) is set
    pub fn isOtherFlag(self: RaInfo) bool {
        return (self.flags & 0x40) != 0;
    }

    /// Check if A-flag (autonomous address config) is set
    pub fn isAutonomousFlag(self: RaInfo) bool {
        return (self.flags & 0x20) != 0;
    }

    comptime {
        if (@sizeOf(@This()) != 56) @compileError("RaInfo must be 56 bytes");
    }
};

// Display Mode Syscalls (1070-1079)
/// Set display resolution (requires DisplayServer capability)
/// arg1: width (u32), arg2: height (u32), arg3: flags (reserved, pass 0)
/// Returns: 0 on success, -errno on failure
pub const SYS_SET_DISPLAY_MODE: usize = 1070;

/// Interface information returned by GET_INFO command
pub const InterfaceInfo = extern struct {
    /// Interface name (null-terminated)
    name: [16]u8,
    /// MAC address
    mac_addr: [6]u8,
    /// Interface is administratively up
    is_up: bool,
    /// Physical link is connected
    link_up: bool,
    /// MTU
    mtu: u16,
    /// Padding
    _pad: [2]u8 = [_]u8{0} ** 2,
    /// IPv4 address (network byte order)
    ipv4_addr: u32,
    /// IPv4 netmask (network byte order)
    ipv4_netmask: u32,
    /// IPv4 gateway (network byte order)
    ipv4_gateway: u32,
    /// Has IPv6 gateway configured
    has_ipv6_gateway: bool,
    /// Padding
    _pad2: [3]u8 = [_]u8{0} ** 3,
    /// IPv6 default gateway
    ipv6_gateway: [16]u8,
    /// Number of IPv6 addresses configured
    ipv6_addr_count: u8,
    /// Padding
    _pad3: [7]u8 = [_]u8{0} ** 7,

    comptime {
        // 16 + 6 + 1 + 1 + 2 + 2 + 4 + 4 + 4 + 1 + 3 + 16 + 1 + 7 = 68 bytes
        if (@sizeOf(@This()) != 68) @compileError("InterfaceInfo must be 68 bytes");
    }
};

// =============================================================================
// Virtual PCI Device Emulation Syscalls (1080-1099)
// =============================================================================
// These syscalls implement the pciem-compatible virtual PCI device framework.
// Requires VirtualPciCapability.

/// Create a new virtual PCI device
/// Returns: device_id on success, -errno on failure
/// Requires: VirtualPciCapability
pub const SYS_VPCI_CREATE: usize = 1080;

/// Add a BAR to a virtual device (before registration)
/// arg1: device_id, arg2: bar_config_ptr (VPciBarConfig)
/// Returns: 0 on success, -errno on failure
pub const SYS_VPCI_ADD_BAR: usize = 1081;

/// Add a capability to a virtual device (MSI, MSI-X, PM, etc.)
/// arg1: device_id, arg2: cap_config_ptr (VPciCapConfig)
/// Returns: capability offset on success, -errno on failure
pub const SYS_VPCI_ADD_CAP: usize = 1082;

/// Set the PCI configuration header (vendor/device ID, class, etc.)
/// arg1: device_id, arg2: config_header_ptr (VPciConfigHeader)
/// Returns: 0 on success, -errno on failure
pub const SYS_VPCI_SET_CONFIG: usize = 1083;

/// Register device with PCI subsystem and create event ring
/// arg1: device_id
/// Returns: ring_id on success (for event ring mapping), -errno on failure
pub const SYS_VPCI_REGISTER: usize = 1084;

/// Inject MSI/MSI-X interrupt
/// arg1: device_id, arg2: irq_config_ptr (VPciIrqConfig)
/// Returns: 0 on success, -errno on failure
pub const SYS_VPCI_INJECT_IRQ: usize = 1085;

/// Perform DMA read/write operation
/// arg1: dma_op_ptr (VPciDmaOp)
/// Returns: bytes transferred on success, -errno on failure
pub const SYS_VPCI_DMA: usize = 1086;

/// Get BAR info (physical address after mapping)
/// arg1: device_id, arg2: bar_index, arg3: bar_info_ptr (VPciBarInfo)
/// Returns: 0 on success, -errno on failure
pub const SYS_VPCI_GET_BAR_INFO: usize = 1087;

/// Unregister and destroy a virtual device
/// arg1: device_id
/// Returns: 0 on success, -errno on failure
pub const SYS_VPCI_DESTROY: usize = 1088;

/// Wait for MMIO event (blocking)
/// arg1: device_id, arg2: timeout_ns (0 = infinite)
/// Returns: number of pending events, -errno on failure
pub const SYS_VPCI_WAIT_EVENT: usize = 1089;

/// Submit response to an MMIO read event
/// arg1: device_id, arg2: response_ptr (VPciResponse)
/// Returns: 0 on success, -errno on failure
pub const SYS_VPCI_RESPOND: usize = 1090;
