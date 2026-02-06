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
