const std = @import("std");
const syscall = @import("syscall");

// S_IFMT and mode bit constants
const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;
const S_IFREG: u32 = 0o100000;

// Access mode constants
const F_OK: i32 = 0;

// Test 1: stat on a known file returns valid mode and size
pub fn testStatBasicFile() !void {
    var st: syscall.Stat = std.mem.zeroes(syscall.Stat);
    try syscall.stat("/shell.elf", &st);

    // Size should be positive (shell.elf is a real binary)
    if (st.size <= 0) return error.TestFailed;

    // Mode should indicate regular file
    if (st.mode & S_IFMT != S_IFREG) return error.TestFailed;
}

// Test 2: fstat on an open fd returns valid info
pub fn testFstatOpenFile() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    var st: syscall.Stat = std.mem.zeroes(syscall.Stat);
    try syscall.fstat(fd, &st);

    // Size should be positive
    if (st.size <= 0) return error.TestFailed;

    // Mode should indicate regular file
    if (st.mode & S_IFMT != S_IFREG) return error.TestFailed;
}

// Test 3: stat and fstat agree on file size (InitRD file)
pub fn testStatSize() !void {
    // Use an InitRD file to avoid SFS close/fstat deadlocks
    var st1: syscall.Stat = std.mem.zeroes(syscall.Stat);
    try syscall.stat("/shell.elf", &st1);

    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    var st2: syscall.Stat = std.mem.zeroes(syscall.Stat);
    try syscall.fstat(fd, &st2);

    // Both should report the same positive size
    if (st1.size <= 0 or st2.size <= 0) return error.TestFailed;
    if (st1.size != st2.size) return error.TestFailed;
}

// Test 4: stat on directory has S_IFDIR bit set
pub fn testStatModeDirectory() !void {
    var st: syscall.Stat = std.mem.zeroes(syscall.Stat);
    try syscall.stat("/mnt", &st);

    if (st.mode & S_IFMT != S_IFDIR) return error.TestFailed;
}

// Test 5: ftruncate reduces file size
pub fn testFtruncateFile() !void {
    const path = "/mnt/test_ftrunc.txt";

    // Create file with initial content
    const fd = try syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644);
    defer syscall.close(fd) catch {};

    // Write 20 bytes
    const data = "12345678901234567890";
    const written = try syscall.write(fd, data.ptr, data.len);
    if (written != 20) return error.TestFailed;

    // Truncate to 10 bytes
    try syscall.ftruncate(fd, 10);

    // Verify new size via fstat
    var st: syscall.Stat = std.mem.zeroes(syscall.Stat);
    try syscall.fstat(fd, &st);
    if (st.size != 10) return error.TestFailed;
}

// Test 6: rename moves a file, old name is gone
pub fn testRenameFile() !void {
    const old_path = "/mnt/test_rename_src.txt";
    const new_path = "/mnt/test_rename_dst.txt";

    // Create source file
    const fd = try syscall.open(old_path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644);
    const data = "rename test data";
    _ = try syscall.write(fd, data.ptr, data.len);
    try syscall.close(fd);

    // Rename the file
    try syscall.rename(old_path, new_path);

    // Verify old path no longer exists
    const old_result = syscall.open(old_path, syscall.O_RDONLY, 0);
    if (old_result) |_| {
        return error.TestFailed; // Old path should not exist
    } else |err| {
        if (err != error.NoSuchFileOrDirectory) return error.TestFailed;
    }

    // Verify new path exists and has correct content
    const new_fd = try syscall.open(new_path, syscall.O_RDONLY, 0);
    defer syscall.close(new_fd) catch {};

    var buf: [32]u8 = undefined;
    const read_len = try syscall.read(new_fd, &buf, buf.len);
    if (read_len != data.len) return error.TestFailed;
    if (!std.mem.eql(u8, buf[0..read_len], data)) return error.TestFailed;
}

// Test 7: chmod changes mode bits
pub fn testChmodFile() !void {
    const path = "/mnt/test_chmod.txt";

    // Create file
    const fd = try syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644);
    try syscall.close(fd);

    // Change permissions
    try syscall.chmod(path, 0o755);

    // Verify mode changed
    var st: syscall.Stat = std.mem.zeroes(syscall.Stat);
    try syscall.stat(path, &st);

    if (st.mode & 0o7777 != 0o755) return error.TestFailed;
}

// Test 8: unlink removes a file
pub fn testUnlinkFile() !void {
    const path = "/mnt/test_unlink.txt";

    // Create file
    const fd = try syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644);
    try syscall.close(fd);

    // Unlink the file
    try syscall.unlink(path);

    // Verify file no longer exists
    const result = syscall.open(path, syscall.O_RDONLY, 0);
    if (result) |_| {
        return error.TestFailed; // File should not exist
    } else |err| {
        if (err != error.NoSuchFileOrDirectory) return error.TestFailed;
    }
}

// Test 9: rmdir removes an empty directory
pub fn testRmdirDirectory() !void {
    const path = "/mnt/test_rmdir_dir";

    // Create directory
    try syscall.mkdir(path, 0o755);

    // Remove directory
    try syscall.rmdir(path);

    // Verify directory no longer exists
    var st: syscall.Stat = std.mem.zeroes(syscall.Stat);
    const result = syscall.stat(path, &st);
    if (result) |_| {
        return error.TestFailed; // Directory should not exist
    } else |err| {
        if (err != error.NoSuchFileOrDirectory) return error.TestFailed;
    }
}

// Test 10: access(path, F_OK) for existing file
pub fn testAccessExists() !void {
    try syscall.access("/shell.elf", F_OK);
}

// Test 11: access on missing file returns error
pub fn testAccessNonexistent() !void {
    const result = syscall.access("/nonexistent_file_xyz", F_OK);
    if (result) |_| {
        return error.TestFailed; // Should have failed
    } else |err| {
        if (err != error.NoSuchFileOrDirectory) return error.TestFailed;
    }
}

// Test 12: lstat works (same as stat for non-symlinks)
pub fn testLstatBasic() !void {
    var st: syscall.Stat = std.mem.zeroes(syscall.Stat);
    try syscall.lstat("/shell.elf", &st);

    if (st.size <= 0) return error.TestFailed;
    if (st.mode & S_IFMT != S_IFREG) return error.TestFailed;
}

// Test 13: statfs on InitRD root returns valid filesystem info
pub fn testStatfsInitRD() !void {
    var buf: syscall.Statfs = undefined;
    try syscall.statfs("/", &buf);

    // Verify non-zero filesystem type (RAMFS_MAGIC or similar)
    if (buf.f_type == 0) return error.TestFailed;

    // Verify block size is set
    if (buf.f_bsize == 0) return error.TestFailed;

    // Verify total blocks is non-zero (InitRD has files)
    if (buf.f_blocks == 0) return error.TestFailed;
}

// Test 14: statfs on DevFS returns expected values
pub fn testStatfsDevFS() !void {
    var buf: syscall.Statfs = undefined;
    try syscall.statfs("/dev", &buf);

    // DevFS should have DEVFS_MAGIC (0x1373)
    if (buf.f_type != 0x1373) return error.TestFailed;

    // DevFS is virtual, so blocks should be zero
    if (buf.f_blocks != 0) return error.TestFailed;
}

// Test 15: statfs on SFS returns filesystem stats
pub fn testStatfsSFS() !void {
    var buf: syscall.Statfs = undefined;
    try syscall.statfs("/mnt", &buf);

    // SFS should have SFS_MAGIC (0x5346532f)
    if (buf.f_type != 0x5346532f) return error.TestFailed;

    // SFS should have blocks and files
    if (buf.f_bsize != 512) return error.TestFailed;
    if (buf.f_blocks == 0) return error.TestFailed;

    // File limit should be 64
    if (buf.f_files != 64) return error.TestFailed;
}

// Test 16: fstatfs on open fd returns same info as statfs
pub fn testFstatfsSFS() !void {
    // Open a file on SFS
    const fd = try syscall.open("/mnt", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    var buf_statfs: syscall.Statfs = undefined;
    try syscall.statfs("/mnt", &buf_statfs);

    var buf_fstatfs: syscall.Statfs = undefined;
    try syscall.fstatfs(fd, &buf_fstatfs);

    // Both should return same filesystem type
    if (buf_statfs.f_type != buf_fstatfs.f_type) return error.TestFailed;
    if (buf_fstatfs.f_type != 0x5346532f) return error.TestFailed;
}
