// x86_64 memory helpers backed by assembly implementations.

extern fn zscapek_memcpy(dest: [*]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8;
extern fn zscapek_memset(dest: [*]u8, value: u8, n: usize) callconv(.c) [*]u8;

pub inline fn copy(dest: [*]u8, src: [*]const u8, n: usize) void {
    if (n == 0) return;
    _ = zscapek_memcpy(dest, src, n);
}

pub inline fn fill(dest: [*]u8, value: u8, n: usize) void {
    if (n == 0) return;
    _ = zscapek_memset(dest, value, n);
}
