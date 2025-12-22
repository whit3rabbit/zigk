pub const Dirent64 = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [0]u8, // Flexible array member
};
