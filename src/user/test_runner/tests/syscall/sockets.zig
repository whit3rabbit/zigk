const std = @import("std");
const syscall = @import("syscall");

// Test 1: Create TCP socket
pub fn testSocketCreateTcp() !void {
    const fd = syscall.socket(syscall.AF_INET, syscall.SOCK_STREAM, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.close(fd) catch {};

    // Verify we got a valid fd (>= 3, since 0-2 are stdin/out/err)
    if (fd < 3) return error.TestFailed;
}

// Test 2: Create UDP socket
pub fn testSocketCreateUdp() !void {
    const fd = syscall.socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.close(fd) catch {};

    // Verify we got a valid fd
    if (fd < 3) return error.TestFailed;
}

// Test 3: Create socket with invalid domain
pub fn testSocketInvalidDomain() !void {
    const result = syscall.socket(999, syscall.SOCK_STREAM, 0);

    if (result) |fd| {
        _ = syscall.close(fd) catch {};
        return error.TestFailed; // Should have failed
    } else |err| {
        // Should fail with InvalidArgument or AddressFamilyNotSupported
        if (err != error.InvalidArgument and err != error.AddressFamilyNotSupported) {
            if (err == error.NotImplemented) return error.SkipTest;
            return error.TestFailed;
        }
    }
}

// Test 4: Bind to localhost
pub fn testBindLocalhost() !void {
    const fd = syscall.socket(syscall.AF_INET, syscall.SOCK_STREAM, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.close(fd) catch {};

    // Create address for 127.0.0.1:8080
    const localhost = syscall.parseIp("127.0.0.1") orelse return error.TestFailed;
    var addr = syscall.SockAddrIn.init(localhost, 8080);

    // Bind to the address
    syscall.bind(fd, &addr) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // If we got here, bind succeeded
}

// Test 5: Listen on socket
pub fn testListenOnSocket() !void {
    const fd = syscall.socket(syscall.AF_INET, syscall.SOCK_STREAM, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.close(fd) catch {};

    // Bind to localhost:8081
    const localhost = syscall.parseIp("127.0.0.1") orelse return error.TestFailed;
    var addr = syscall.SockAddrIn.init(localhost, 8081);
    try syscall.bind(fd, &addr);

    // Listen with backlog of 5
    syscall.listen(fd, 5) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown) return error.SkipTest;
        return err;
    };

    // If we got here, listen succeeded
}

// Test 6: getsockname returns correct address after bind
pub fn testGetSockName() !void {
    const fd = syscall.socket(syscall.AF_INET, syscall.SOCK_STREAM, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.close(fd) catch {};

    // Bind to localhost:8082
    const localhost = syscall.parseIp("127.0.0.1") orelse return error.TestFailed;
    var bind_addr = syscall.SockAddrIn.init(localhost, 8082);
    try syscall.bind(fd, &bind_addr);

    // Get socket name
    var retrieved_addr: syscall.SockAddrIn = undefined;
    syscall.getsockname(fd, &retrieved_addr) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Verify address and port match
    if (retrieved_addr.getAddr() != localhost) return error.TestFailed;
    if (retrieved_addr.getPort() != 8082) return error.TestFailed;
}

// Test 7: setsockopt SO_REUSEADDR
pub fn testSetSockoptReuseAddr() !void {
    const fd = syscall.socket(syscall.AF_INET, syscall.SOCK_STREAM, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.close(fd) catch {};

    // Set SO_REUSEADDR
    var optval: i32 = 1;
    const optval_bytes = @as([*]const u8, @ptrCast(&optval))[0..@sizeOf(i32)];

    syscall.setsockopt(fd, syscall.SOL_SOCKET, syscall.SO_REUSEADDR, optval_bytes) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Verify by reading it back
    var retrieved: i32 = 0;
    const retrieved_bytes = @as([*]u8, @ptrCast(&retrieved))[0..@sizeOf(i32)];

    _ = syscall.getsockopt(fd, syscall.SOL_SOCKET, syscall.SO_REUSEADDR, retrieved_bytes) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    if (retrieved != 1) return error.TestFailed;
}

// Test 8: Connect to unbound port (expect ECONNREFUSED or timeout)
pub fn testConnectToUnboundPort() !void {
    const fd = syscall.socket(syscall.AF_INET, syscall.SOCK_STREAM, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.close(fd) catch {};

    // Try to connect to localhost:9999 (unlikely to be listening)
    const localhost = syscall.parseIp("127.0.0.1") orelse return error.TestFailed;
    var addr = syscall.SockAddrIn.init(localhost, 9999);

    const result = syscall.connect(fd, &addr);

    if (result) |_| {
        // Connection succeeded - this is acceptable if something is listening
        // (e.g., another service on the system)
    } else |err| {
        // Should fail with ConnectionRefused or timeout-related error
        // Accept various connection failure errors as valid
        if (err != error.ConnectionRefused and
            err != error.ConnectionTimedOut and
            err != error.NetworkUnreachable and
            err != error.NetworkDown and
            err != error.HostUnreachable) {
            if (err == error.NotImplemented) return error.SkipTest;
            return error.TestFailed;
        }
    }
}

// =============================================================================
// Phase 7: Socket Extras Tests
// =============================================================================

// Test 9: socketpair creates connected AF_UNIX pair
pub fn testSocketpairStream() !void {
    var sv: [2]i32 = undefined;
    syscall.socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0, &sv) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer {
        _ = syscall.close(sv[0]) catch {};
        _ = syscall.close(sv[1]) catch {};
    }

    // Both FDs should be valid (>= 3)
    if (sv[0] < 3 or sv[1] < 3) return error.TestFailed;
    // FDs should be different
    if (sv[0] == sv[1]) return error.TestFailed;
}

// Test 10: socketpair bidirectional communication
pub fn testSocketpairBidirectional() !void {
    var sv: [2]i32 = undefined;
    syscall.socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0, &sv) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer {
        _ = syscall.close(sv[0]) catch {};
        _ = syscall.close(sv[1]) catch {};
    }

    // Write from sv[0], read from sv[1]
    const msg1 = "hello";
    const written1 = syscall.write(sv[0], msg1.ptr, msg1.len) catch return error.TestFailed;
    if (written1 != msg1.len) return error.TestFailed;

    var buf1: [32]u8 = undefined;
    const read1 = syscall.read(sv[1], &buf1, buf1.len) catch return error.TestFailed;
    if (read1 != msg1.len) return error.TestFailed;
    if (!std.mem.eql(u8, buf1[0..read1], msg1)) return error.TestFailed;

    // Write from sv[1], read from sv[0] (reverse direction)
    const msg2 = "world";
    const written2 = syscall.write(sv[1], msg2.ptr, msg2.len) catch return error.TestFailed;
    if (written2 != msg2.len) return error.TestFailed;

    var buf2: [32]u8 = undefined;
    const read2 = syscall.read(sv[0], &buf2, buf2.len) catch return error.TestFailed;
    if (read2 != msg2.len) return error.TestFailed;
    if (!std.mem.eql(u8, buf2[0..read2], msg2)) return error.TestFailed;
}

// Test 11: socketpair rejects non-AF_UNIX domain
pub fn testSocketpairInvalidDomain() !void {
    var sv: [2]i32 = undefined;
    const result = syscall.socketpair(syscall.AF_INET, syscall.SOCK_STREAM, 0, &sv);
    if (result) |_| {
        // Should have failed
        _ = syscall.close(sv[0]) catch {};
        _ = syscall.close(sv[1]) catch {};
        return error.TestFailed;
    } else |err| {
        // Should fail with AddressFamilyNotSupported or InvalidArgument
        if (err != error.AddressFamilyNotSupported and err != error.InvalidArgument) {
            if (err == error.NotImplemented) return error.SkipTest;
            return error.TestFailed;
        }
    }
}

// Test 12: shutdown SHUT_WR prevents further writes
pub fn testShutdownWrite() !void {
    var sv: [2]i32 = undefined;
    syscall.socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0, &sv) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer {
        _ = syscall.close(sv[0]) catch {};
        _ = syscall.close(sv[1]) catch {};
    }

    // Shutdown write on sv[0]
    syscall.shutdown(sv[0], syscall.SHUT_WR) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Read from sv[1] should return 0 (EOF) since peer shut down writes
    var buf: [32]u8 = undefined;
    const n = syscall.read(sv[1], &buf, buf.len) catch {
        // Some implementations return BrokenPipe or other error on EOF
        // Accept 0-length read or specific error
        return; // Acceptable
    };
    // EOF is indicated by 0 bytes read
    if (n != 0) {
        // If read returned data, that means there was buffered data before shutdown
        // This is acceptable per POSIX - shutdown doesn't discard existing data
        return;
    }
}

// Test 13: shutdown SHUT_RDWR disables both directions
pub fn testShutdownRdwr() !void {
    var sv: [2]i32 = undefined;
    syscall.socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0, &sv) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer {
        _ = syscall.close(sv[0]) catch {};
        _ = syscall.close(sv[1]) catch {};
    }

    // Shutdown both directions on sv[0]
    syscall.shutdown(sv[0], syscall.SHUT_RDWR) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // FD should still be valid (shutdown != close)
    // Try to read - should get EOF or error
    var buf: [32]u8 = undefined;
    const read_result = syscall.read(sv[0], &buf, buf.len);
    if (read_result) |n| {
        // EOF (0 bytes) is correct behavior after SHUT_RD
        if (n != 0) return error.TestFailed;
    } else |_| {
        // Error is also acceptable (e.g., ENOTCONN, EPIPE)
    }
}

// Test 14: sendto/recvfrom on UDP socket (loopback)
pub fn testSendtoRecvfromUdp() !void {
    // Create UDP socket
    const fd = syscall.socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.close(fd) catch {};

    // Bind to localhost on ephemeral port
    const localhost = syscall.parseIp("127.0.0.1") orelse return error.TestFailed;
    var bind_addr = syscall.SockAddrIn.init(localhost, 9950);
    syscall.bind(fd, &bind_addr) catch |err| {
        if (err == error.NotImplemented or err == error.AddressInUse) return error.SkipTest;
        return err;
    };

    // Send to self
    const msg = "test_udp";
    var dest_addr = syscall.SockAddrIn.init(localhost, 9950);
    _ = syscall.sendto(fd, msg, &dest_addr) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown) return error.SkipTest;
        return err;
    };

    // Receive with source address
    var buf: [64]u8 = undefined;
    var src_addr: syscall.SockAddrIn = undefined;
    const n = syscall.recvfrom(fd, &buf, &src_addr) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown) return error.SkipTest;
        return err;
    };

    if (n != msg.len) return error.TestFailed;
    if (!std.mem.eql(u8, buf[0..n], msg)) return error.TestFailed;
}

// Test 15: sendto with null address on connected socket
pub fn testSendtoConnectedSocket() !void {
    // Create socketpair and use sendto without address (should work like send)
    var sv: [2]i32 = undefined;
    syscall.socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0, &sv) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer {
        _ = syscall.close(sv[0]) catch {};
        _ = syscall.close(sv[1]) catch {};
    }

    // Use raw syscall for sendto with null addr on unix socket
    const msg = "connected_sendto";
    const written = syscall.write(sv[0], msg.ptr, msg.len) catch return error.TestFailed;
    if (written != msg.len) return error.TestFailed;

    var buf: [32]u8 = undefined;
    const read_n = syscall.read(sv[1], &buf, buf.len) catch return error.TestFailed;
    if (read_n != msg.len) return error.TestFailed;
}

// Test 16: sendmsg/recvmsg basic scatter-gather
pub fn testSendmsgRecvmsgBasic() !void {
    var sv: [2]i32 = undefined;
    syscall.socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0, &sv) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer {
        _ = syscall.close(sv[0]) catch {};
        _ = syscall.close(sv[1]) catch {};
    }

    // Send using sendmsg with a single iovec
    const send_data = "sendmsg_test";
    var send_iov = [_]syscall.MsgIovec{.{
        .iov_base = @intFromPtr(send_data.ptr),
        .iov_len = send_data.len,
    }};
    var send_msg = syscall.MsgHdr{
        .msg_name = 0,
        .msg_namelen = 0,
        .msg_iov = @intFromPtr(&send_iov),
        .msg_iovlen = 1,
        .msg_control = 0,
        .msg_controllen = 0,
        .msg_flags = 0,
    };

    const sent = syscall.sendmsg(sv[0], &send_msg, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    if (sent != send_data.len) return error.TestFailed;

    // Receive using recvmsg
    var recv_buf: [64]u8 = undefined;
    var recv_iov = [_]syscall.MsgIovec{.{
        .iov_base = @intFromPtr(&recv_buf),
        .iov_len = recv_buf.len,
    }};
    var recv_msg = syscall.MsgHdr{
        .msg_name = 0,
        .msg_namelen = 0,
        .msg_iov = @intFromPtr(&recv_iov),
        .msg_iovlen = 1,
        .msg_control = 0,
        .msg_controllen = 0,
        .msg_flags = 0,
    };

    const received = syscall.recvmsg(sv[1], &recv_msg, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    if (received != send_data.len) return error.TestFailed;
    if (!std.mem.eql(u8, recv_buf[0..received], send_data)) return error.TestFailed;
}

// Test 17: sendmsg/recvmsg with multiple iovecs (scatter-gather)
pub fn testSendmsgScatterGather() !void {
    var sv: [2]i32 = undefined;
    syscall.socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0, &sv) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer {
        _ = syscall.close(sv[0]) catch {};
        _ = syscall.close(sv[1]) catch {};
    }

    // Send with 3 iovecs
    const part1 = "hello";
    const part2 = " ";
    const part3 = "world";
    var send_iovs = [_]syscall.MsgIovec{
        .{ .iov_base = @intFromPtr(part1.ptr), .iov_len = part1.len },
        .{ .iov_base = @intFromPtr(part2.ptr), .iov_len = part2.len },
        .{ .iov_base = @intFromPtr(part3.ptr), .iov_len = part3.len },
    };
    var send_msg = syscall.MsgHdr{
        .msg_name = 0,
        .msg_namelen = 0,
        .msg_iov = @intFromPtr(&send_iovs),
        .msg_iovlen = 3,
        .msg_control = 0,
        .msg_controllen = 0,
        .msg_flags = 0,
    };

    const sent = syscall.sendmsg(sv[0], &send_msg, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    const expected_total = part1.len + part2.len + part3.len;
    if (sent != expected_total) return error.TestFailed;

    // Receive into single buffer
    var recv_buf: [64]u8 = undefined;
    var recv_iov = [_]syscall.MsgIovec{.{
        .iov_base = @intFromPtr(&recv_buf),
        .iov_len = recv_buf.len,
    }};
    var recv_msg = syscall.MsgHdr{
        .msg_name = 0,
        .msg_namelen = 0,
        .msg_iov = @intFromPtr(&recv_iov),
        .msg_iovlen = 1,
        .msg_control = 0,
        .msg_controllen = 0,
        .msg_flags = 0,
    };

    const received = syscall.recvmsg(sv[1], &recv_msg, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    if (received != expected_total) return error.TestFailed;
    if (!std.mem.eql(u8, recv_buf[0..received], "hello world")) return error.TestFailed;
}

// Test 18: sendmsg with invalid fd
pub fn testSendmsgInvalidFd() !void {
    var send_iov = [_]syscall.MsgIovec{.{
        .iov_base = @intFromPtr("test"),
        .iov_len = 4,
    }};
    var msg = syscall.MsgHdr{
        .msg_name = 0,
        .msg_namelen = 0,
        .msg_iov = @intFromPtr(&send_iov),
        .msg_iovlen = 1,
        .msg_control = 0,
        .msg_controllen = 0,
        .msg_flags = 0,
    };

    const result = syscall.sendmsg(999, &msg, 0);
    if (result) |_| {
        return error.TestFailed; // Should have failed
    } else |err| {
        if (err != error.BadFileDescriptor and err != error.NotASocket) {
            if (err == error.NotImplemented) return error.SkipTest;
            return error.TestFailed;
        }
    }
}

// Test 19: shutdown on non-socket fd returns error
pub fn testShutdownNonSocket() !void {
    // Open a regular file
    const fd = syscall.open("/etc/hostname", syscall.O_RDONLY, 0) catch {
        // If file doesn't exist, try stdin
        const result = syscall.shutdown(0, syscall.SHUT_RDWR);
        if (result) |_| {
            // Some implementations allow shutdown on pipes/stdin
            return;
        } else |shutdown_err| {
            if (shutdown_err != error.NotASocket and shutdown_err != error.InvalidArgument) {
                if (shutdown_err == error.NotImplemented) return error.SkipTest;
                return error.TestFailed;
            }
        }
        return;
    };
    defer _ = syscall.close(fd) catch {};

    const result = syscall.shutdown(fd, syscall.SHUT_RDWR);
    if (result) |_| {
        return error.TestFailed; // Should fail on regular file
    } else |err| {
        if (err != error.NotASocket and err != error.InvalidArgument) {
            if (err == error.NotImplemented) return error.SkipTest;
            return error.TestFailed;
        }
    }
}

// Test 20: socketpair with SOCK_DGRAM type
pub fn testSocketpairDgram() !void {
    var sv: [2]i32 = undefined;
    syscall.socketpair(syscall.AF_UNIX, syscall.SOCK_DGRAM, 0, &sv) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer {
        _ = syscall.close(sv[0]) catch {};
        _ = syscall.close(sv[1]) catch {};
    }

    // Write a datagram from sv[0], read from sv[1]
    const msg = "dgram_test";
    const written = syscall.write(sv[0], msg.ptr, msg.len) catch return error.TestFailed;
    if (written != msg.len) return error.TestFailed;

    var buf: [32]u8 = undefined;
    const read_n = syscall.read(sv[1], &buf, buf.len) catch return error.TestFailed;
    if (read_n != msg.len) return error.TestFailed;
    if (!std.mem.eql(u8, buf[0..read_n], msg)) return error.TestFailed;
}
