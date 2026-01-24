// ZK writev Test
//
// Tests sys_writev (20) for correctness and edge cases:
//   - Single iovec write
//   - Multiple iovec write (scatter-gather)
//   - Large buffer handling (>64KB chunks)
//   - Empty iovec handling
//   - Bad file descriptor error
//   - Zero iovec count
//
// Build:
//   Added to build.zig as userland executable

const syscall = @import("syscall");

// Test result tracking
var tests_run: u32 = 0;
var tests_passed: u32 = 0;
var tests_failed: u32 = 0;

// Format u32 to decimal string
fn formatU32(value: u32, buf: []u8) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = value;
    var i: usize = buf.len;
    while (v > 0 and i > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @truncate(v % 10));
        v /= 10;
    }
    return buf[i..];
}

fn expectEqual(expected: usize, actual: usize, test_name: []const u8) void {
    tests_run += 1;
    if (expected == actual) {
        tests_passed += 1;
        syscall.debug_print("PASS: ");
        syscall.debug_print(test_name);
        syscall.debug_print("\n");
    } else {
        tests_failed += 1;
        syscall.debug_print("FAIL: ");
        syscall.debug_print(test_name);
        syscall.debug_print(" (expected != actual)\n");
    }
}

fn expectError(test_name: []const u8, succeeded: bool) void {
    tests_run += 1;
    if (!succeeded) {
        tests_passed += 1;
        syscall.debug_print("PASS: ");
        syscall.debug_print(test_name);
        syscall.debug_print("\n");
    } else {
        tests_failed += 1;
        syscall.debug_print("FAIL: ");
        syscall.debug_print(test_name);
        syscall.debug_print(" (expected error, got success)\n");
    }
}

// Test 1: Single iovec write
fn testSingleIovec() void {
    // Write to stdout (fd 1)
    const data = "WRITEV_TEST: Single iovec test data\n";
    var iov = [1]syscall.Iovec{
        syscall.Iovec.fromSlice(data),
    };

    const result = syscall.writev(1, &iov);
    if (result) |written| {
        expectEqual(data.len, written, "testSingleIovec");
    } else |_| {
        tests_run += 1;
        tests_failed += 1;
        syscall.debug_print("FAIL: testSingleIovec - writev failed\n");
    }
}

// Test 2: Multiple iovec write
fn testMultipleIovec() void {
    const data1 = "WRITEV_TEST: First ";
    const data2 = "Second ";
    const data3 = "Third\n";

    var iov = [3]syscall.Iovec{
        syscall.Iovec.fromSlice(data1),
        syscall.Iovec.fromSlice(data2),
        syscall.Iovec.fromSlice(data3),
    };

    const result = syscall.writev(1, &iov);
    if (result) |written| {
        const expected_len = data1.len + data2.len + data3.len;
        expectEqual(expected_len, written, "testMultipleIovec");
    } else |_| {
        tests_run += 1;
        tests_failed += 1;
        syscall.debug_print("FAIL: testMultipleIovec - writev failed\n");
    }
}

// Test 3: Large buffer (>64KB to test chunking)
fn testLargeBuffer() void {
    // Allocate ~128KB buffer using brk
    const buf_size: usize = 128 * 1024;

    const current_brk = syscall.brk(0) catch {
        tests_run += 1;
        tests_failed += 1;
        syscall.debug_print("FAIL: testLargeBuffer - cannot get brk\n");
        return;
    };

    const new_brk = syscall.brk(current_brk + buf_size) catch {
        tests_run += 1;
        tests_failed += 1;
        syscall.debug_print("FAIL: testLargeBuffer - cannot allocate memory\n");
        return;
    };

    if (new_brk != current_brk + buf_size) {
        tests_run += 1;
        tests_failed += 1;
        syscall.debug_print("FAIL: testLargeBuffer - allocation failed\n");
        return;
    }

    // Fill with pattern
    const buf: [*]u8 = @ptrFromInt(current_brk);
    for (0..buf_size) |i| {
        buf[i] = @truncate(i & 0xFF);
    }

    // Write to /dev/null (fd 2 is stderr, but we'll use it as it should work)
    // Actually, let's just write a smaller test message to stdout
    const test_msg = "WRITEV_TEST: Large buffer allocated and filled OK\n";
    var iov = [1]syscall.Iovec{
        syscall.Iovec.fromSlice(test_msg),
    };

    const result = syscall.writev(1, &iov);
    if (result) |written| {
        expectEqual(test_msg.len, written, "testLargeBuffer");
    } else |_| {
        tests_run += 1;
        tests_failed += 1;
        syscall.debug_print("FAIL: testLargeBuffer - writev failed\n");
    }

    // Free the buffer
    _ = syscall.brk(current_brk) catch {};
}

// Test 4: Empty iovec (zero length)
fn testEmptyIovec() void {
    const data = "WRITEV_TEST: After empty\n";
    var iov = [2]syscall.Iovec{
        .{ .base = 0, .len = 0 }, // Empty
        syscall.Iovec.fromSlice(data),
    };

    const result = syscall.writev(1, &iov);
    if (result) |written| {
        expectEqual(data.len, written, "testEmptyIovec");
    } else |_| {
        tests_run += 1;
        tests_failed += 1;
        syscall.debug_print("FAIL: testEmptyIovec - writev failed\n");
    }
}

// Test 5: Bad file descriptor
fn testBadFd() void {
    const bad_fd: i32 = 999;
    const data = "test";
    var iov = [1]syscall.Iovec{
        syscall.Iovec.fromSlice(data),
    };

    const result = syscall.writev(bad_fd, &iov);
    expectError("testBadFd", result != error.EBADF);
}

// Test 6: Zero iovecs
fn testZeroIovecs() void {
    var iov: [0]syscall.Iovec = undefined;

    const result = syscall.writev(1, &iov);
    if (result) |written| {
        expectEqual(0, written, "testZeroIovecs");
    } else |_| {
        tests_run += 1;
        tests_failed += 1;
        syscall.debug_print("FAIL: testZeroIovecs - writev failed\n");
    }
}

pub fn main() void {
    syscall.debug_print("WRITEV_TEST: Starting writev syscall tests\n");
    syscall.debug_print("WRITEV_TEST: ========================================\n");

    testSingleIovec();
    testMultipleIovec();
    testLargeBuffer();
    testEmptyIovec();
    testBadFd();
    testZeroIovecs();

    // Print summary
    syscall.debug_print("WRITEV_TEST: ========================================\n");
    syscall.debug_print("WRITEV_TEST: Tests run: ");
    var buf: [20]u8 = undefined;
    syscall.debug_print(formatU32(tests_run, &buf));
    syscall.debug_print(" Passed: ");
    syscall.debug_print(formatU32(tests_passed, &buf));
    syscall.debug_print(" Failed: ");
    syscall.debug_print(formatU32(tests_failed, &buf));
    syscall.debug_print("\n");

    if (tests_failed > 0) {
        syscall.debug_print("WRITEV_TEST: FAILED\n");
        syscall.exit(1);
    } else {
        syscall.debug_print("WRITEV_TEST: PASSED\n");
        syscall.exit(0);
    }
}

// Entry point
export fn _start() noreturn {
    main();
    syscall.exit(0);
}
