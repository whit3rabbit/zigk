// SECURITY AUDIT (2024-12): Verified non-issue.
// Padding fields (__pad0, __unused) are explicitly zero-initialized in all
// stat population paths: sys_fstat (fd.zig:145), sfs/ops.zig:802-803,
// initrd.zig:393-394. Callers MUST use std.mem.zeroes(Stat) before populating.
pub const Stat = extern struct {
    dev: u64,
    ino: u64,
    nlink: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    __pad0: u32, // Padding - must be zero-initialized to prevent info leak
    rdev: u64,
    size: i64,
    blksize: i64,
    blocks: i64,
    atime: i64,
    atime_nsec: i64,
    mtime: i64,
    mtime_nsec: i64,
    ctime: i64,
    ctime_nsec: i64,
    __unused: [3]i64, // Reserved - must be zero-initialized to prevent info leak
};

pub const Fsid = extern struct {
    val: [2]i32,
};

// SECURITY AUDIT (2024-12): Verified non-issue.
// The f_spare padding is correctly zero-initialized in vfs.zig:918-938.
pub const Statfs = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: i64,
    f_bfree: i64,
    f_bavail: i64,
    f_files: i64,
    f_ffree: i64,
    f_fsid: Fsid,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64, // Reserved - zero-initialized in vfs.zig
};
