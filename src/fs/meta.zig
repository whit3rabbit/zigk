//! File Metadata for Permission Checking
//!
//! Lightweight structure for file ownership and mode information.
//! Used by VFS permission checks before opening files.

/// File metadata for permission checking
pub const FileMeta = struct {
    /// File mode (S_IFREG | permissions)
    mode: u32,
    /// Owner user ID
    uid: u32,
    /// Owner group ID
    gid: u32,
    /// True if file exists
    exists: bool = true,
    /// True if filesystem is read-only
    readonly: bool = false,
};

// File type masks
pub const S_IFMT: u32 = 0o170000; // File type mask
pub const S_IFREG: u32 = 0o100000; // Regular file
pub const S_IFDIR: u32 = 0o040000; // Directory
pub const S_IFLNK: u32 = 0o120000; // Symbolic link
pub const S_IFCHR: u32 = 0o020000; // Character device
pub const S_IFBLK: u32 = 0o060000; // Block device
pub const S_IFIFO: u32 = 0o010000; // FIFO (named pipe)
pub const S_IFSOCK: u32 = 0o140000; // Socket

// Owner permission bits
pub const S_IRWXU: u32 = 0o0700; // Owner rwx
pub const S_IRUSR: u32 = 0o0400; // Owner read
pub const S_IWUSR: u32 = 0o0200; // Owner write
pub const S_IXUSR: u32 = 0o0100; // Owner execute

// Group permission bits
pub const S_IRWXG: u32 = 0o0070; // Group rwx
pub const S_IRGRP: u32 = 0o0040; // Group read
pub const S_IWGRP: u32 = 0o0020; // Group write
pub const S_IXGRP: u32 = 0o0010; // Group execute

// Other permission bits
pub const S_IRWXO: u32 = 0o0007; // Other rwx
pub const S_IROTH: u32 = 0o0004; // Other read
pub const S_IWOTH: u32 = 0o0002; // Other write
pub const S_IXOTH: u32 = 0o0001; // Other execute

// Special bits
pub const S_ISUID: u32 = 0o4000; // Set-user-ID
pub const S_ISGID: u32 = 0o2000; // Set-group-ID
pub const S_ISVTX: u32 = 0o1000; // Sticky bit

/// Check if mode represents a regular file
pub fn isRegular(mode: u32) bool {
    return (mode & S_IFMT) == S_IFREG;
}

/// Check if mode represents a directory
pub fn isDirectory(mode: u32) bool {
    return (mode & S_IFMT) == S_IFDIR;
}

/// Check if mode represents a symbolic link
pub fn isSymlink(mode: u32) bool {
    return (mode & S_IFMT) == S_IFLNK;
}

/// Extract just the permission bits (lower 12 bits)
pub fn permissionBits(mode: u32) u32 {
    return mode & 0o7777;
}

/// Parse an octal string (e.g., from TAR header) into u32
/// Returns 0 if parsing fails
pub fn parseOctal(buf: []const u8) u32 {
    var result: u32 = 0;
    for (buf) |c| {
        if (c == ' ' or c == 0) break;
        if (c < '0' or c > '7') break;
        // Checked multiplication to prevent overflow
        const mul_result = @mulWithOverflow(result, 8);
        if (mul_result[1] != 0) return 0;
        const add_result = @addWithOverflow(mul_result[0], c - '0');
        if (add_result[1] != 0) return 0;
        result = add_result[0];
    }
    return result;
}
