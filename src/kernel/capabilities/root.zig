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
    SetUid,
    SetGid,
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
    /// Allows changing user ID (like Linux CAP_SETUID)
    SetUid: SetUidCapability,
    /// Allows changing group ID (like Linux CAP_SETGID)
    SetGid: SetGidCapability,
};
