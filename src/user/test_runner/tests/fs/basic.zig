const syscall = @import("syscall");

pub fn testInitrdReadFile() !void {
    const fd = try syscall.open("/shell.elf", 0, 0); // O_RDONLY
    defer syscall.close(fd) catch {};

    var buf: [256]u8 = undefined;
    const bytes_read = try syscall.read(fd, &buf, buf.len);

    if (bytes_read < 52) return error.TestFailed;
    // Check ELF magic
    if (buf[0] != 0x7F or buf[1] != 'E' or buf[2] != 'L' or buf[3] != 'F') {
        return error.TestFailed;
    }
}

pub fn testSfsCreateFile() !void {
    const fd = syscall.open("/mnt/test.txt", 0x241, 0o644) catch |err| {  // O_WRONLY|O_CREAT|O_TRUNC
        return if (err == error.ReadOnlyFilesystem or err == error.NoSuchFileOrDirectory) {} else err; // Skip
    };
    defer syscall.close(fd) catch {};

    const data = "Hello, SFS!";
    const written = try syscall.write(fd, data.ptr, data.len);
    if (written != data.len) return error.TestFailed;
}

pub fn testDevfsListDevices() !void {
    const fd = try syscall.open("/dev", 0x10000, 0); // O_RDONLY | O_DIRECTORY
    defer syscall.close(fd) catch {};

    var buf: [4096]u8 = undefined;
    const bytes = try syscall.getdents64(fd, &buf, buf.len);
    if (bytes == 0) return error.TestFailed;
}
