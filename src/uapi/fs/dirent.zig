// SECURITY AUDIT (2024-12): Verified non-issue.
// The d_name flexible array member is NOT copied via struct assignment.
// In sys_getdents64 (dir.zig), the struct header is copied separately from
// the name bytes, preventing any stack leak from the zero-length array.
// Callers must copy header fields individually, then memcpy the name.
pub const Dirent64 = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [0]u8, // Flexible array member - see security note above
};
