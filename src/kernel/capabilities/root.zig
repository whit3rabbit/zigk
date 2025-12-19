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

pub const PciConfigCapability = struct {
    /// PCI bus number
    bus: u8,
    /// PCI device number (0-31)
    device: u5,
    /// PCI function number (0-7)
    func: u3,
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
    PciConfig,
    InputInjection,
    Mount,
    File,
};

pub const Capability = union(CapabilityType) {
    Interrupt: InterruptCapability,
    IoPort: struct { port: u16, len: u16 },
    Mmio: MmioCapability,
    DmaMemory: DmaCapability,
    PciConfig: PciConfigCapability,
    /// Allows injecting keyboard/mouse input via IPC to kernel (PID 0)
    InputInjection: void,
    /// Allows mounting/unmounting filesystems
    Mount: MountCapability,
    /// Allows file write operations (create, delete, modify)
    File: FileCapability,
};
