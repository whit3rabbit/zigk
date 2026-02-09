const process = @import("process");

pub const IpcPerm = struct {
    key: i32,
    cuid: u32, // Creator UID
    cgid: u32, // Creator GID
    uid: u32, // Owner UID
    gid: u32, // Owner GID
    mode: u16, // Permission bits (lower 9 bits)
    seq: u16, // Sequence number for unique ID generation
};

pub const AccessMode = enum { read, write };

pub fn checkAccess(perm: *const IpcPerm, proc: *const process.Process, mode: AccessMode) bool {
    const euid = proc.euid;
    const egid = proc.egid;
    // Root bypasses all checks
    if (euid == 0) return true;
    // Check owner permissions
    if (euid == perm.uid) {
        const need_bit: u16 = if (mode == .read) 0o400 else 0o200;
        return (perm.mode & need_bit) != 0;
    }
    // Check group permissions
    if (egid == perm.gid) {
        const need_bit: u16 = if (mode == .read) 0o040 else 0o020;
        return (perm.mode & need_bit) != 0;
    }
    // Check other permissions
    const need_bit: u16 = if (mode == .read) 0o004 else 0o002;
    return (perm.mode & need_bit) != 0;
}

pub fn isOwnerOrCreator(perm: *const IpcPerm, euid: u32) bool {
    return euid == 0 or euid == perm.uid or euid == perm.cuid;
}

/// Generate unique IPC ID from slot index and sequence number
/// Format: (index << 16) | seq -- prevents stale ID reuse
pub fn makeId(index: usize, seq: u16) u32 {
    return @as(u32, @intCast(index)) << 16 | @as(u32, seq);
}

/// Extract slot index from IPC ID
pub fn idToIndex(id: u32) usize {
    return @intCast(id >> 16);
}

/// Extract sequence number from IPC ID
pub fn idToSeq(id: u32) u16 {
    return @truncate(id);
}
