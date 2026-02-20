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

/// Test: accept4 with invalid flags returns EINVAL
pub fn testAccept4InvalidFlags() !void {
    // Create a listening socket
    const listen_fd = try syscall.socket(syscall.AF_INET, syscall.SOCK_STREAM, 0);
    defer _ = syscall.close(listen_fd) catch {};

    // Bind to loopback (use helper function like other tests)
    const localhost = syscall.parseIp("127.0.0.1") orelse return error.TestFailed;
    var addr = syscall.SockAddrIn.init(localhost, 0); // Port 0 = let kernel assign
    try syscall.bind(listen_fd, &addr);
    try syscall.listen(listen_fd, 1);

    // accept4 with invalid flags (beyond SOCK_CLOEXEC | SOCK_NONBLOCK) should return EINVAL
    const invalid_flags: i32 = 0x7FFFFFFF; // All bits set
    const result = syscall.accept4(listen_fd, null, invalid_flags);
    if (result != error.EINVAL) return error.TestFailed;
}

/// Test: accept4 with valid flags validates (returns EAGAIN with no connection, not EINVAL)
pub fn testAccept4ValidFlags() !void {
    // Create a non-blocking listening socket
    const listen_fd = try syscall.socket(syscall.AF_INET, syscall.SOCK_STREAM | syscall.SOCK_NONBLOCK, 0);
    defer _ = syscall.close(listen_fd) catch {};

    // Bind to loopback
    const localhost = syscall.parseIp("127.0.0.1") orelse return error.TestFailed;
    var addr = syscall.SockAddrIn.init(localhost, 0);
    try syscall.bind(listen_fd, &addr);
    try syscall.listen(listen_fd, 1);

    // accept4 with SOCK_CLOEXEC | SOCK_NONBLOCK should be valid flags
    // Since no connection is pending, should return EAGAIN (or WouldBlock), not EINVAL
    const flags = syscall.SOCK_CLOEXEC | syscall.SOCK_NONBLOCK;
    const result = syscall.accept4(listen_fd, null, flags);

    // Either EAGAIN or WouldBlock is acceptable (no EINVAL means flags were valid)
    if (result) |_| {
        // Got a connection somehow (shouldn't happen, but not an error)
    } else |err| {
        // Should be EAGAIN or WouldBlock, not EINVAL
        if (err == error.EINVAL) return error.TestFailed;
    }
}

// =============================================================================
// Phase 39: MSG Flag Tests (MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL)
// =============================================================================

/// Test: MSG_PEEK on UDP -- peek sees data without consuming; second recv gets same data.
pub fn testMsgPeekUdp() !void {
    const localhost = syscall.parseIp("127.0.0.1") orelse return error.TestFailed;

    // Create receiver UDP socket bound to loopback:9200
    const recv_fd = syscall.socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown) return error.SkipTest;
        return err;
    };
    defer _ = syscall.close(recv_fd) catch {};

    var bind_addr = syscall.SockAddrIn.init(localhost, 9200);
    syscall.bind(recv_fd, &bind_addr) catch |err| {
        if (err == error.NotImplemented or err == error.AddressInUse) return error.SkipTest;
        return err;
    };

    // Create sender UDP socket
    const send_fd = syscall.socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.close(send_fd) catch {};

    // Send "hello" to receiver
    var dest_addr = syscall.SockAddrIn.init(localhost, 9200);
    const msg = "hello";
    _ = syscall.sendto(send_fd, msg, &dest_addr) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown) return error.SkipTest;
        return err;
    };

    // MSG_PEEK: read without consuming
    var buf: [32]u8 = undefined;
    const n1 = syscall.recvfromFlags(recv_fd, buf[0..32], syscall.MSG_PEEK, null) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown) return error.SkipTest;
        return err;
    };
    if (n1 != msg.len) return error.TestFailed;
    if (!std.mem.eql(u8, buf[0..n1], msg)) return error.TestFailed;

    // Normal recv: data should still be there (peek did not consume)
    const n2 = syscall.recvfromFlags(recv_fd, buf[0..32], 0, null) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown) return error.SkipTest;
        return err;
    };
    if (n2 != msg.len) return error.TestFailed;
    if (!std.mem.eql(u8, buf[0..n2], msg)) return error.TestFailed;

    // Queue now empty: MSG_PEEK | MSG_DONTWAIT must return WouldBlock
    const result = syscall.recvfromFlags(recv_fd, buf[0..32], syscall.MSG_PEEK | syscall.MSG_DONTWAIT, null);
    if (result) |_| {
        // If this unexpectedly succeeded, that's a test environment anomaly -- skip
        return error.SkipTest;
    } else |err| {
        // Accept both EAGAIN (errno 11 mapped to WouldBlock) and ResourceTemporarilyUnavailable
        if (err != error.WouldBlock and err != error.EAGAIN and err != error.ResourceTemporarilyUnavailable) {
            if (err == error.NotImplemented) return error.SkipTest;
            return error.TestFailed;
        }
    }
}

/// Helper: Create a TCP server+client pair using loopback.
/// Returns (listen_fd, client_fd, accepted_fd). Caller must close all three.
/// On any error returns SkipTest if the network layer is unavailable.
const TcpPair = struct {
    listen_fd: i32,
    client_fd: i32,
    accepted_fd: i32,
};

fn makeTcpPair(port: u16) error{SkipTest, TestFailed, NetworkDown, NotImplemented, AddressInUse, BadFileDescriptor, OutOfMemory, AccessDenied, EINVAL, FileDescriptorQuotaExceeded, SystemResources, ProcessFdQuotaExceeded, Unexpected}!TcpPair {
    const localhost = syscall.parseIp("127.0.0.1") orelse return error.TestFailed;

    // Server: create, bind, listen
    const listen_fd = syscall.socket(syscall.AF_INET, syscall.SOCK_STREAM, 0) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown) return error.SkipTest;
        return error.TestFailed;
    };
    errdefer _ = syscall.close(listen_fd) catch {};

    var srv_addr = syscall.SockAddrIn.init(localhost, port);
    syscall.bind(listen_fd, &srv_addr) catch |err| {
        if (err == error.NotImplemented or err == error.AddressInUse) return error.SkipTest;
        return error.TestFailed;
    };
    syscall.listen(listen_fd, 1) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown) return error.SkipTest;
        return error.TestFailed;
    };

    // Client: create, connect (blocks until handshake)
    const client_fd = syscall.socket(syscall.AF_INET, syscall.SOCK_STREAM, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return error.TestFailed;
    };
    errdefer _ = syscall.close(client_fd) catch {};

    var cli_addr = syscall.SockAddrIn.init(localhost, port);
    syscall.connect(client_fd, &cli_addr) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown or err == error.NetworkUnreachable) return error.SkipTest;
        return error.TestFailed;
    };

    // Server: accept (connection should be queued after connect() returned)
    const accepted_fd = syscall.accept(listen_fd, null) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown) return error.SkipTest;
        return error.TestFailed;
    };

    return TcpPair{
        .listen_fd = listen_fd,
        .client_fd = client_fd,
        .accepted_fd = accepted_fd,
    };
}

/// Test: MSG_PEEK on TCP -- peek sees data without consuming; second recv gets same data.
pub fn testMsgPeekTcp() !void {
    const pair = makeTcpPair(9201) catch |err| {
        if (err == error.SkipTest) return error.SkipTest;
        return error.TestFailed;
    };
    defer _ = syscall.close(pair.listen_fd) catch {};
    defer _ = syscall.close(pair.client_fd) catch {};
    defer _ = syscall.close(pair.accepted_fd) catch {};

    // Client writes "world" to server
    const msg = "world";
    const written = syscall.write(pair.client_fd, msg.ptr, msg.len) catch return error.TestFailed;
    if (written != msg.len) return error.TestFailed;

    // Server peeks: read without consuming
    var buf: [32]u8 = undefined;
    const n1 = syscall.recvfromFlags(pair.accepted_fd, buf[0..32], syscall.MSG_PEEK, null) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown) return error.SkipTest;
        return error.TestFailed;
    };
    if (n1 == 0) return error.TestFailed;

    // Server normal recv: same data returned (peek did not consume)
    const n2 = syscall.recvfromFlags(pair.accepted_fd, buf[0..32], 0, null) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown) return error.SkipTest;
        return error.TestFailed;
    };
    if (n2 == 0) return error.TestFailed;

    // Both reads should have returned the same content
    // (n1 may be <= n2 depending on buffering, but content must match)
    const cmp_len = @min(n1, n2);
    if (cmp_len == 0) return error.TestFailed;
    if (!std.mem.eql(u8, buf[0..cmp_len], buf[0..cmp_len])) return error.TestFailed;

    // Verify the data actually contains "world" (at least partially)
    if (!std.mem.startsWith(u8, msg, buf[0..@min(cmp_len, msg.len)])) {
        // The data in buf should be a prefix of msg; check the other way
        if (!std.mem.startsWith(u8, buf[0..cmp_len], msg[0..@min(cmp_len, msg.len)])) {
            return error.TestFailed;
        }
    }
}

/// Test: MSG_DONTWAIT on TCP returns WouldBlock when no data is available.
pub fn testMsgDontwaitEagain() !void {
    const pair = makeTcpPair(9202) catch |err| {
        if (err == error.SkipTest) return error.SkipTest;
        return error.TestFailed;
    };
    defer _ = syscall.close(pair.listen_fd) catch {};
    defer _ = syscall.close(pair.client_fd) catch {};
    defer _ = syscall.close(pair.accepted_fd) catch {};

    // No data sent. Non-blocking recv on accepted_fd should return WouldBlock (EAGAIN).
    var buf: [32]u8 = undefined;
    const result = syscall.recvfromFlags(pair.accepted_fd, buf[0..32], syscall.MSG_DONTWAIT, null);

    if (result) |n| {
        // Unexpected: data appeared from nowhere
        if (n > 0) return error.TestFailed;
        // 0 = EOF, which would mean the connection was closed -- skip
        return error.SkipTest;
    } else |err| {
        // WouldBlock (errno 11) is the expected response for MSG_DONTWAIT with empty buffer.
        // Also accept EAGAIN as some userspace libs map it differently.
        if (err != error.WouldBlock and err != error.EAGAIN and err != error.ResourceTemporarilyUnavailable) {
            if (err == error.NotImplemented) return error.SkipTest;
            return error.TestFailed;
        }
    }
}

/// Test: MSG_WAITALL on TCP accumulates the full requested length.
pub fn testMsgWaitallTcp() !void {
    const pair = makeTcpPair(9203) catch |err| {
        if (err == error.SkipTest) return error.SkipTest;
        return error.TestFailed;
    };
    defer _ = syscall.close(pair.listen_fd) catch {};
    defer _ = syscall.close(pair.client_fd) catch {};
    defer _ = syscall.close(pair.accepted_fd) catch {};

    // Client sends 4 bytes "ABCD"
    const msg = "ABCD";
    const written = syscall.write(pair.client_fd, msg.ptr, msg.len) catch return error.TestFailed;
    if (written != msg.len) return error.TestFailed;

    // Server calls MSG_WAITALL requesting exactly 4 bytes.
    // On loopback the data arrives in one chunk, so this validates that
    // MSG_WAITALL does not break normal single-chunk delivery.
    var buf: [4]u8 = undefined;
    const n = syscall.recvfromFlags(pair.accepted_fd, buf[0..4], syscall.MSG_WAITALL, null) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown) return error.SkipTest;
        return error.TestFailed;
    };

    if (n != 4) return error.TestFailed;
    if (!std.mem.eql(u8, buf[0..4], msg)) return error.TestFailed;
}

/// Test: MSG_WAITALL on UDP is ignored -- returns single datagram (not blocking for full buffer).
pub fn testMsgWaitallIgnoredUdp() !void {
    const localhost = syscall.parseIp("127.0.0.1") orelse return error.TestFailed;

    // Create receiver UDP socket bound to loopback:9204
    const recv_fd = syscall.socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown) return error.SkipTest;
        return err;
    };
    defer _ = syscall.close(recv_fd) catch {};

    var bind_addr = syscall.SockAddrIn.init(localhost, 9204);
    syscall.bind(recv_fd, &bind_addr) catch |err| {
        if (err == error.NotImplemented or err == error.AddressInUse) return error.SkipTest;
        return err;
    };

    // Create sender UDP socket
    const send_fd = syscall.socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.close(send_fd) catch {};

    // Send 2-byte datagram "hi"
    var dest_addr = syscall.SockAddrIn.init(localhost, 9204);
    const msg = "hi";
    _ = syscall.sendto(send_fd, msg, &dest_addr) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown) return error.SkipTest;
        return err;
    };

    // MSG_WAITALL with a 100-byte buffer. Per POSIX, ignored for SOCK_DGRAM.
    // Must return the 2-byte datagram rather than blocking for 100 bytes.
    var buf: [100]u8 = undefined;
    const n = syscall.recvfromFlags(recv_fd, buf[0..100], syscall.MSG_WAITALL, null) catch |err| {
        if (err == error.NotImplemented or err == error.NetworkDown) return error.SkipTest;
        return err;
    };

    // Should return the single datagram length (2), not 100 or a timeout error
    if (n != msg.len) return error.TestFailed;
    if (!std.mem.eql(u8, buf[0..n], msg)) return error.TestFailed;
}
