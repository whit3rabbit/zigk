const std = @import("std");

pub const InterruptCapability = struct {
    irq: u8,
};

pub const MmioCapability = struct {
    /// Physical address of MMIO region
    phys_addr: u64,
    /// Size of MMIO region in bytes
    size: u64,
};

pub const DmaCapability = struct {
    /// Maximum pages this process can allocate for DMA
    max_pages: u32,
};

/// Capability for IOMMU-protected DMA operations
/// Allows a process to allocate DMA buffers that are IOMMU-isolated
/// to a specific PCI device, preventing the device from accessing
/// memory outside its allocated regions.
pub const IommuDmaCapability = struct {
    /// PCI bus number
    bus: u8,
    /// PCI device number (0-31)
    device: u5,
    /// PCI function number (0-7)
    func: u3,
    /// Maximum total DMA allocation size in bytes
    max_size: u64,
    /// IOMMU domain ID assigned by kernel (0 = not yet assigned)
    domain_id: u16,
    /// If true, IOMMU protection is mandatory - syscall fails if IOVA
    /// allocation fails rather than falling back to raw physical addresses.
    /// SECURITY: Prevents DMA attacks when device isolation is required.
    iommu_required: bool = false,

    /// Create raw BDF encoding
    pub fn toBdf(self: IommuDmaCapability) u16 {
        return (@as(u16, self.bus) << 8) | (@as(u16, self.device) << 3) | @as(u16, self.func);
    }
};

/// Capability for PCI configuration space access.
///
/// SECURITY: By default, writes to security-sensitive registers are blocked:
/// - Command register (0x04): Controls bus mastering, memory/IO enable
/// - BAR registers (0x10-0x24): Control device memory mappings
/// - Expansion ROM (0x30): Could load malicious firmware
/// - Capability pointers that control MSI/MSI-X (interrupt redirection)
///
/// To allow writes to these registers, the capability must have `allow_unsafe=true`,
/// which should only be granted to highly trusted kernel-mode drivers.
pub const PciConfigCapability = struct {
    /// PCI bus number
    bus: u8,
    /// PCI device number (0-31)
    device: u5,
    /// PCI function number (0-7)
    func: u3,
    /// If true, allows writes to ALL registers including dangerous ones.
    /// If false (default), blocks writes to: Command, BARs, ROM, MSI control.
    /// SECURITY: Only set to true for kernel-mode drivers that need full control.
    allow_unsafe: bool = false,

    /// PCI register offsets that are restricted by default
    pub const RESTRICTED_OFFSETS = struct {
        pub const COMMAND: u12 = 0x04; // Bus master, memory/IO enable
        pub const BAR0: u12 = 0x10;
        pub const BAR1: u12 = 0x14;
        pub const BAR2: u12 = 0x18;
        pub const BAR3: u12 = 0x1C;
        pub const BAR4: u12 = 0x20;
        pub const BAR5: u12 = 0x24;
        pub const EXPANSION_ROM: u12 = 0x30;
        // MSI capability register offsets are capability-relative, checked separately
    };

    /// Check if writing to the given offset is allowed
    pub fn allowsWrite(self: PciConfigCapability, offset: u12) bool {
        if (self.allow_unsafe) return true;

        // Block writes to security-sensitive registers
        return switch (offset) {
            RESTRICTED_OFFSETS.COMMAND,
            RESTRICTED_OFFSETS.BAR0,
            RESTRICTED_OFFSETS.BAR1,
            RESTRICTED_OFFSETS.BAR2,
            RESTRICTED_OFFSETS.BAR3,
            RESTRICTED_OFFSETS.BAR4,
            RESTRICTED_OFFSETS.BAR5,
            RESTRICTED_OFFSETS.EXPANSION_ROM,
            => false,
            else => true,
        };
    }
};

/// Capability for file write operations (create, delete, modify)
pub const FileCapability = struct {
    /// Target path prefix (or "*" for any path)
    path: [64]u8,
    /// Length of valid path data
    path_len: usize,
    /// Allowed operations: 1 = write, 2 = delete, 4 = create, 7 = all
    ops: u8,

    pub const WRITE_OP: u8 = 1;
    pub const DELETE_OP: u8 = 2;
    pub const CREATE_OP: u8 = 4;
    pub const ALL_OPS: u8 = 7;

    /// Check if this capability allows the given operation on the given path
    /// Security: Uses strict path boundary checking to prevent prefix bypass attacks
    pub fn allows(self: FileCapability, path: []const u8, op: u8) bool {
        if ((self.ops & op) == 0) return false;

        // Reject empty capability paths (invalid configuration)
        if (self.path_len == 0) return false;

        const cap_path = self.path[0..self.path_len];

        // Wildcard matches any path
        if (self.path_len == 1 and self.path[0] == '*') return true;

        // Must start with capability path
        if (!std.mem.startsWith(u8, path, cap_path)) return false;

        // Exact match is always OK
        if (path.len == self.path_len) return true;

        // Security: Strict directory boundary check
        // Capability for "/data" must NOT match "/data.sensitive" or "/datafile"
        // It SHOULD match "/data/" and "/data/file.txt"

        // If capability path ends with '/', any sub-path is OK
        if (cap_path[self.path_len - 1] == '/') return true;

        // Otherwise, next char in request path MUST be '/' (proper directory boundary)
        // This prevents /data from matching /data.txt or /datafile
        return path[self.path_len] == '/';
    }
};

/// Capability for changing user ID (like Linux CAP_SETUID)
/// Allows a process to:
/// - Make arbitrary changes to process UIDs (setuid, setreuid, setresuid)
/// - Forge UID when passing socket credentials
/// - Set saved set-user-ID when executing setuid programs
pub const SetUidCapability = struct {
    /// Target UID to allow changing to (or 0xFFFFFFFF for any UID)
    target_uid: u32,

    pub const ANY_UID: u32 = 0xFFFFFFFF;

    pub fn allows(self: SetUidCapability, target: u32) bool {
        return self.target_uid == ANY_UID or self.target_uid == target;
    }
};

/// Capability for changing group ID (like Linux CAP_SETGID)
/// Allows a process to:
/// - Make arbitrary changes to process GIDs (setgid, setregid, setresgid)
/// - Forge GID when passing socket credentials
/// - Set supplementary GIDs with setgroups
pub const SetGidCapability = struct {
    /// Target GID to allow changing to (or 0xFFFFFFFF for any GID)
    target_gid: u32,

    pub const ANY_GID: u32 = 0xFFFFFFFF;

    pub fn allows(self: SetGidCapability, target: u32) bool {
        return self.target_gid == ANY_GID or self.target_gid == target;
    }
};

/// Capability for display server access (framebuffer + input routing)
///
/// This capability grants a process the right to:
/// - Map the framebuffer into its address space via sys_map_fb()
/// - Receive routed input events from the kernel input subsystem
/// - Act as the compositor/display server for the system
///
/// Only one process should hold this capability active at a time.
/// The kernel enforces exclusive framebuffer ownership via claimOwnership().
///
/// Architecture: Follows Wayland-like model where the display server owns
/// the framebuffer and GUI applications communicate via IPC.
pub const DisplayServerCapability = struct {
    /// If true, input events (keyboard/mouse) are routed to this process
    receives_input: bool = true,
    /// If true, allows exclusive framebuffer mapping
    owns_framebuffer: bool = true,
};

/// Capability for mounting/unmounting filesystems
pub const MountCapability = struct {
    /// Target mount point path (exact match required, wildcards NOT allowed for security)
    path: [64]u8,
    /// Length of valid path data
    path_len: usize,
    /// Allowed operations: 1 = mount, 2 = unmount, 3 = both
    ops: u8,

    pub const MOUNT_OP: u8 = 1;
    pub const UMOUNT_OP: u8 = 2;
    pub const MOUNT_UMOUNT_OP: u8 = 3;

    /// Check if this capability allows the given operation on the given path
    /// Security: Wildcards are explicitly REJECTED for mount capabilities
    /// to prevent mounting to sensitive paths like /bin, /etc, /
    pub fn allows(self: MountCapability, path: []const u8, op: u8) bool {
        if ((self.ops & op) == 0) return false;

        // Reject empty capability paths
        if (self.path_len == 0) return false;

        const cap_path = self.path[0..self.path_len];

        // Security: REJECT wildcard mount capabilities
        // Allowing "*" for mounts would let processes mount to /bin, /etc, etc.
        if (self.path_len == 1 and self.path[0] == '*') {
            @import("console").warn("MountCapability: Wildcard rejected for security", .{});
            return false;
        }

        // Exact path match only (no prefix matching for mounts)
        return std.mem.eql(u8, cap_path, path);
    }
};

pub const CapabilityType = enum {
    Interrupt,
    IoPort,
    Mmio,
    DmaMemory,
    IommuDma,
    PciConfig,
    InputInjection,
    Mount,
    File,
    SetUid,
    SetGid,
    DisplayServer,
};

pub const Capability = union(CapabilityType) {
    Interrupt: InterruptCapability,
    IoPort: struct { port: u16, len: u16 },
    Mmio: MmioCapability,
    DmaMemory: DmaCapability,
    /// IOMMU-protected DMA for a specific PCI device
    IommuDma: IommuDmaCapability,
    PciConfig: PciConfigCapability,
    /// Allows injecting keyboard/mouse input via IPC to kernel (PID 0)
    InputInjection: void,
    /// Allows mounting/unmounting filesystems
    Mount: MountCapability,
    /// Allows file write operations (create, delete, modify)
    File: FileCapability,
    /// Allows changing user ID (like Linux CAP_SETUID)
    SetUid: SetUidCapability,
    /// Allows changing group ID (like Linux CAP_SETGID)
    SetGid: SetGidCapability,
    /// Allows display server access (framebuffer + input routing)
    DisplayServer: DisplayServerCapability,
};
