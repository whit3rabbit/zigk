const syscall = @import("syscall");

// Helper to compare strings
fn strEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

pub fn testChdirAcceptsDirectories() !void {
    syscall.chdir("/mnt") catch {
        // /mnt may not be mounted, that's OK
        return;
    };
    var buf: [256]u8 = undefined;
    const len = try syscall.getcwd(&buf, buf.len);
    const cwd = buf[0..len];
    if (!strEqual(cwd, "/mnt")) return error.TestFailed;
    try syscall.chdir("/");  // Restore
}

pub fn testChdirRejectsFiles() !void {
    // Test with /shell.elf which should exist in InitRD
    const result = syscall.chdir("/shell.elf");
    if (result) |_| {
        // chdir succeeded on a file - this is wrong
        return error.TestFailed;
    } else |err| {
        // chdir failed - verify it's NotADirectory (errno 20)
        if (err != error.NotADirectory) return error.TestFailed;
    }
}

pub fn testGetcwd() !void {
    var buf: [256]u8 = undefined;
    const len = try syscall.getcwd(&buf, buf.len);
    if (len == 0) return error.TestFailed;
    if (buf[0] != '/') return error.TestFailed;
}

pub fn testGetdentsInitrd() !void {
    const fd = try syscall.open("/", 0x10000, 0); // O_RDONLY | O_DIRECTORY
    defer syscall.close(fd) catch {};

    var buf: [4096]u8 = undefined;
    const bytes_read = try syscall.getdents64(fd, &buf, buf.len);
    if (bytes_read == 0) return error.TestFailed;
}
