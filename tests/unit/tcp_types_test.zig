const std = @import("std");
const testing = std.testing;

// Copy of TcpHeader from types.zig to test structure layout and alignment
// We will test both the current (buggy) definition and the fixed (packed/aligned) approach in this test file
// to demonstrate the fix.

const TcpHeaderOriginal = extern struct {
    src_port: u16,
    dst_port: u16,
    seq_num: u32,
    ack_num: u32,
    data_offset_flags: u16,
    window: u16,
    checksum: u16,
    urgent_ptr: u16,
};

const TcpHeaderPacked = packed struct {
    src_port: u16,
    dst_port: u16,
    seq_num: u32,
    ack_num: u32,
    data_offset_flags: u16,
    window: u16,
    checksum: u16,
    urgent_ptr: u16,
};

test "TcpHeader alignment safety" {
    // Create a byte buffer
    var buffer: [64]u8 = undefined;
    @memset(&buffer, 0);

    // Create an unaligned pointer (offset 1)
    const unaligned_ptr = &buffer[1];
    
    // Check alignment of the pointer
    const addr = @intFromPtr(unaligned_ptr);
    try testing.expect(addr % 4 != 0); // Should not be 4-byte aligned
    
    // Attempting to cast to *TcpHeaderOriginal (which has u32 fields) 
    // requires 4-byte alignment implies @alignCast which would panic.
    // We can't strictly test "panic happens" easily in Zig test without crashing the runner,
    // but we can verify that *align(1) TcpHeaderPacked works.
    
    const packed_hdr: *align(1) TcpHeaderPacked = @ptrCast(unaligned_ptr);
    
    // Write some values
    packed_hdr.src_port = 1234;
    packed_hdr.seq_num = 0xAABBCCDD;
    
    // Verify writes
    try testing.expectEqual(@as(u16, 1234), packed_hdr.src_port);
    try testing.expectEqual(@as(u32, 0xAABBCCDD), packed_hdr.seq_num);
}
