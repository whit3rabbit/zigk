const std = @import("std");
const syscall = @import("syscall");

// AT constants
const AT_FDCWD: i32 = -100;
const AT_REMOVEDIR: i32 = 0x200;

// S_IFMT and mode bit constants
const S_IFMT: u32 = 0o170000;
const S_IFREG: u32 = 0o100000;
const S_IFDIR: u32 = 0o040000;

// Test 1: fstatat(AT_FDCWD, path) works like stat
pub fn testFstatatBasic() !void {
    var st: syscall.Stat = std.mem.zeroes(syscall.Stat);
    try syscall.fstatat(AT_FDCWD, "/shell.elf", &st, 0);

    if (st.size <= 0) return error.TestFailed;
    if (st.mode & S_IFMT != S_IFREG) return error.TestFailed;
}

// Test 2: mkdirat(AT_FDCWD, name, mode) creates directory
pub fn testMkdiratBasic() !void {
    const path = "/mnt/test_mkdirat_dir";

    try syscall.mkdirat(AT_FDCWD, path, 0o755);

    // Verify it exists and is a directory
    var st: syscall.Stat = std.mem.zeroes(syscall.Stat);
    try syscall.fstatat(AT_FDCWD, path, &st, 0);

    if (st.mode & S_IFMT != S_IFDIR) {
        syscall.rmdir(path) catch {};
        return error.TestFailed;
    }

    // Cleanup
    syscall.rmdir(path) catch {};
}

// Test 3: unlinkat(AT_FDCWD, name, 0) removes file
pub fn testUnlinkatFile() !void {
    const path = "/mnt/test_unlinkat.txt";

    // Create file
    const fd = try syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644);
    try syscall.close(fd);

    // Remove with unlinkat
    try syscall.unlinkat(AT_FDCWD, path, 0);

    // Verify it's gone from directory
    const result = syscall.access(path, 0);
    if (result) |_| {
        return error.TestFailed;
    } else |_| {
        // Expected
    }
}

// Test 4: unlinkat(AT_FDCWD, name, AT_REMOVEDIR) removes directory
pub fn testUnlinkatDir() !void {
    const path = "/mnt/test_unlnkdir";

    // Create directory
    try syscall.mkdir(path, 0o755);

    // Remove directory using unlinkat
    try syscall.unlinkat(AT_FDCWD, path, AT_REMOVEDIR);

    // Verify directory no longer exists
    var st: syscall.Stat = std.mem.zeroes(syscall.Stat);
    const result = syscall.stat(path, &st);
    if (result) |_| {
        return error.TestFailed; // Directory should not exist
    } else |err| {
        if (err != error.NoSuchFileOrDirectory) return error.TestFailed;
    }
}

// Test 5: renameat(AT_FDCWD, old, AT_FDCWD, new)
pub fn testRenameatBasic() !void {
    const old_path = "/mnt/test_renat_src.txt";
    const new_path = "/mnt/test_renat_dst.txt";

    // Create source file
    const fd = try syscall.open(old_path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644);
    const data = "renameat test";
    _ = try syscall.write(fd, data.ptr, data.len);
    try syscall.close(fd);

    // Rename using renameat
    try syscall.renameat(AT_FDCWD, old_path, AT_FDCWD, new_path);

    // Verify old path no longer exists
    const old_result = syscall.open(old_path, syscall.O_RDONLY, 0);
    if (old_result) |_| {
        return error.TestFailed; // Old path should not exist
    } else |err| {
        if (err != error.NoSuchFileOrDirectory) return error.TestFailed;
    }

    // Verify new path exists
    const new_fd = try syscall.open(new_path, syscall.O_RDONLY, 0);
    defer syscall.close(new_fd) catch {};

    var buf: [32]u8 = undefined;
    const read_len = try syscall.read(new_fd, &buf, buf.len);
    if (read_len != data.len) return error.TestFailed;
    if (!std.mem.eql(u8, buf[0..read_len], data)) return error.TestFailed;
}

// Test 6: fchmodat changes permissions on an SFS file
pub fn testFchmodatBasic() !void {
    const path = "/mnt/test_fchmodat.txt";

    // Create file
    const fd = try syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644);
    try syscall.close(fd);

    // Change permissions with fchmodat
    try syscall.fchmodat(AT_FDCWD, path, 0o755, 0);

    // Verify mode changed
    var st: syscall.Stat = std.mem.zeroes(syscall.Stat);
    try syscall.stat(path, &st);

    if (st.mode & 0o7777 != 0o755) return error.TestFailed;
}
