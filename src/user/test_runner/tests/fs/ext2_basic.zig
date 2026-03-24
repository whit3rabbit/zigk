//! ext2 filesystem integration tests (Phase 47 + Phase 48).
//!
//! Tests verify inode read and block resolution at all indirection levels
//! through the VFS open path on /mnt2.
//!
//! All tests skip gracefully when /mnt2 is not mounted (aarch64: ext2 LUN
//! absent due to QEMU 10.x HVF VirtIO-SCSI BAD_TARGET for target 1).
//!
//! Requirements verified:
//!   INODE-01: readInode(2) returns valid directory inode
//!   INODE-02: hello.txt reads back "Hello, ext2!\n" via direct blocks
//!   INODE-03: medium.bin (100KB) reads correctly via single-indirect blocks
//!   INODE-04: large.bin (5MB) reads correctly via double-indirect blocks
//!   DIR-01: open nested path /mnt2/a/b/c/file.txt
//!   DIR-02: getdents on /mnt2 lists entries with correct rec_len stride
//!   DIR-03: readlink on /mnt2/link_to_hello returns fast symlink target
//!   DIR-04: stat on nested file and directory returns correct metadata
//!   DIR-05: statfs on /mnt2 returns EXT2_SUPER_MAGIC and valid counts
//!   INODE-05: inode cache exercised by all path resolution tests

const std = @import("std");
const syscall = @import("syscall");

// Minimal Dirent64 layout for parsing getdents64 output.
// Must match uapi.dirent.Dirent64 (d_ino u64, d_off i64, d_reclen u16, d_type u8).
// d_name starts at byte offset 19 (NOT @sizeOf which pads to 24 for alignment).
const DirentHeader = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    // d_name follows immediately at offset 19. @sizeOf gives 24 due to padding.
    // Use DIRENT_NAME_OFFSET to get the correct name start within a buffer.
};

// Byte offset of d_name within a Dirent64 record.
// d_ino (8) + d_off (8) + d_reclen (2) + d_type (1) = 19.
const DIRENT_NAME_OFFSET: usize = 19;

// DT_* constants for d_type.
const DT_DIR: u8 = 4;
const DT_REG: u8 = 8;
const DT_LNK: u8 = 10;

/// SEEK_SET whence for lseek.
const SEEK_SET: i32 = 0;

/// Check whether /mnt2 is accessible (ext2 mounted).
///
/// Returns false on aarch64 where the ext2 LUN is absent, or when ext2
/// has not been mounted for any other reason.
fn ext2Available() bool {
    // Try to open the root directory of /mnt2.
    // 0x10000 = O_RDONLY | O_DIRECTORY
    const fd = syscall.open("/mnt2", 0x10000, 0) catch return false;
    syscall.close(fd) catch {};
    return true;
}

/// Verify that /mnt2 (the ext2 root directory) can be opened as a directory.
///
/// Validates INODE-01: inode 2 is readable and is a directory.
pub fn testExt2ReadRootInode() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    const fd = try syscall.open("/mnt2", 0x10000, 0);
    defer syscall.close(fd) catch {};

    if (fd < 0) return error.TestFailed;
}

/// Verify that /mnt2/hello.txt reads back exactly "Hello, ext2!\n" (13 bytes).
///
/// Validates INODE-02: file data via direct blocks only.
///
/// hello.txt content (hex): 48 65 6c 6c 6f 2c 20 65 78 74 32 21 0a
pub fn testExt2ReadDirectBlocks() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    const fd = try syscall.open("/mnt2/hello.txt", 0, 0);
    defer syscall.close(fd) catch {};

    var buf: [64]u8 = undefined;
    const bytes_read = try syscall.read(fd, &buf, buf.len);

    // Expect exactly 13 bytes.
    if (bytes_read != 13) {
        return error.TestFailed;
    }

    // Verify exact content: "Hello, ext2!\n"
    const expected = [_]u8{ 'H', 'e', 'l', 'l', 'o', ',', ' ', 'e', 'x', 't', '2', '!', '\n' };
    if (!std.mem.eql(u8, buf[0..13], &expected)) {
        return error.TestFailed;
    }

    // Second read should return 0 (EOF).
    const bytes_read2 = try syscall.read(fd, &buf, buf.len);
    if (bytes_read2 != 0) return error.TestFailed;
}

/// Verify that /mnt2/medium.bin (100KB) reads back with the correct pattern
/// via single-indirect block resolution.
///
/// Validates INODE-03: file data via single-indirect blocks.
///
/// medium.bin content: repeating bytes 0x00..0xFF.
/// At byte offset N, the byte value is @intCast(u8, N % 256).
pub fn testExt2ReadSingleIndirect() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    const fd = try syscall.open("/mnt2/medium.bin", 0, 0);
    defer syscall.close(fd) catch {};

    const EXPECTED_SIZE: usize = 102400; // 100KB
    const CHUNK_SIZE: usize = 4096; // 4KB read buffer

    var buf: [CHUNK_SIZE]u8 = undefined;
    var total_read: usize = 0;

    while (total_read < EXPECTED_SIZE) {
        const to_read = @min(CHUNK_SIZE, EXPECTED_SIZE - total_read);
        const bytes_read = try syscall.read(fd, &buf, to_read);
        if (bytes_read == 0) break; // Unexpected EOF before EXPECTED_SIZE

        // Verify byte pattern: byte at absolute offset N = N % 256.
        var i: usize = 0;
        while (i < bytes_read) : (i += 1) {
            const expected_byte: u8 = @intCast((total_read + i) % 256);
            if (buf[i] != expected_byte) {
                return error.TestFailed;
            }
        }

        total_read += bytes_read;
    }

    if (total_read != EXPECTED_SIZE) return error.TestFailed;

    // Next read should return 0 (EOF).
    const eof_read = try syscall.read(fd, &buf, 1);
    if (eof_read != 0) return error.TestFailed;
}

/// Verify that /mnt2/large.bin reads correctly at a double-indirect block offset.
///
/// Validates INODE-04: file data via double-indirect blocks.
///
/// large.bin is 5MB (5242880 bytes) with the same repeating 0x00..0xFF pattern.
/// We seek to an offset in the double-indirect range:
///   - Direct blocks cover logical 0..11 = bytes 0..49151
///   - Single-indirect covers logical 12..1035 = bytes 49152..4243455
///   - Double-indirect starts at logical 1036 = byte 4243456
///
/// We seek to logical block 1040 = byte 4259840, which is 4 blocks into
/// double-indirect territory (1040 - 1036 = 4).
pub fn testExt2ReadDoubleIndirect() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    const fd = try syscall.open("/mnt2/large.bin", 0, 0);
    defer syscall.close(fd) catch {};

    // Seek to logical block 1040 (double-indirect: block 1036+).
    // 1040 * 4096 = 4259840
    const seek_offset: isize = 1040 * 4096;
    const new_pos = try syscall.lseek(fd, seek_offset, SEEK_SET);
    const expected_pos: usize = @intCast(seek_offset);
    if (new_pos != expected_pos) return error.TestFailed;

    // Read 256 bytes and verify the repeating pattern.
    var buf: [256]u8 = undefined;
    const bytes_read = try syscall.read(fd, &buf, 256);
    if (bytes_read != 256) return error.TestFailed;

    // Verify pattern: byte at absolute offset (seek_offset + i) = (seek_offset + i) % 256.
    const base: usize = @intCast(seek_offset);
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const expected_byte: u8 = @intCast((base + i) % 256);
        if (buf[i] != expected_byte) {
            return error.TestFailed;
        }
    }
}

/// Verify seek + partial block read on /mnt2/medium.bin.
///
/// Validates that ext2FileSeek and ext2FileRead correctly handle
/// reading from a non-block-aligned file position (into single-indirect range).
pub fn testExt2SeekAndRead() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    const fd = try syscall.open("/mnt2/medium.bin", 0, 0);
    defer syscall.close(fd) catch {};

    // Seek to byte 50000 (block 12 + byte 1808 within block = single-indirect range).
    const seek_offset: isize = 50000;
    const new_pos = try syscall.lseek(fd, seek_offset, SEEK_SET);
    const expected_pos: usize = @intCast(seek_offset);
    if (new_pos != expected_pos) return error.TestFailed;

    // Read 100 bytes from that position and verify pattern.
    var buf: [100]u8 = undefined;
    const bytes_read = try syscall.read(fd, &buf, 100);
    if (bytes_read != 100) return error.TestFailed;

    const base: usize = @intCast(seek_offset);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const expected_byte: u8 = @intCast((base + i) % 256);
        if (buf[i] != expected_byte) {
            return error.TestFailed;
        }
    }
}

/// Verify stat metadata for /mnt2/hello.txt.
///
/// Validates ext2FileStat/ext2StatPath: size, mode (S_IFREG), permissions.
pub fn testExt2StatFile() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    var st = std.mem.zeroes(syscall.Stat);
    try syscall.stat("/mnt2/hello.txt", &st);

    // Size must be exactly 13 bytes.
    if (st.size != 13) return error.TestFailed;

    // Mode must have S_IFREG (0o100000) set.
    const S_IFREG: u32 = 0o100000;
    if ((st.mode & S_IFREG) == 0) return error.TestFailed;

    // Must have at least read permission for owner (S_IRUSR = 0o400).
    const S_IRUSR: u32 = 0o400;
    if ((st.mode & S_IRUSR) == 0) return error.TestFailed;
}

// ============================================================================
// Phase 48 tests: directory traversal, getdents, readlink, stat, statfs
// ============================================================================

/// Open a nested path /mnt2/a/b/c/file.txt and verify its content (DIR-01).
///
/// Validates resolvePath with 4-component path (a -> b -> c -> file.txt).
/// The file content is "nested ext2 file\n" (17 bytes) written by build.zig.
pub fn testExt2OpenNestedPath() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    const fd = try syscall.open("/mnt2/a/b/c/file.txt", 0, 0);
    defer syscall.close(fd) catch {};

    var buf: [64]u8 = undefined;
    const bytes_read = try syscall.read(fd, &buf, buf.len);

    // Expect exactly 17 bytes: "nested ext2 file\n"
    if (bytes_read != 17) return error.TestFailed;

    const expected = "nested ext2 file\n";
    if (!std.mem.eql(u8, buf[0..17], expected)) return error.TestFailed;
}

/// List directory contents of /mnt2 via getdents and verify entries (DIR-02).
///
/// Validates ext2GetdentsFromFd: correct rec_len stride, DT_* type mapping.
/// Must find "hello.txt" (DT_REG) and "a" (DT_DIR) in the directory listing.
pub fn testExt2GetdentsListsDirectory() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    // Open /mnt2 as a directory FD.
    const dir_fd = try syscall.open("/mnt2", 0x10000, 0); // O_RDONLY | O_DIRECTORY
    defer syscall.close(dir_fd) catch {};

    var buf: [4096]u8 = undefined;
    const bytes = try syscall.getdents64(dir_fd, &buf, buf.len);

    if (bytes == 0) return error.TestFailed;

    // Walk entries by d_reclen and look for expected entries.
    var offset: usize = 0;
    var found_hello = false;
    var found_a_dir = false;

    while (offset < bytes) {
        if (offset + DIRENT_NAME_OFFSET > bytes) break;
        const hdr: *align(1) const DirentHeader = @ptrCast(&buf[offset]);
        if (hdr.d_reclen == 0) break;

        // Name starts at DIRENT_NAME_OFFSET (19 bytes into the entry).
        // NOTE: @sizeOf(DirentHeader) = 24 due to alignment padding, but name
        // is at the actual field offset of 19. Use DIRENT_NAME_OFFSET here.
        const name_start = offset + DIRENT_NAME_OFFSET;
        // Find null terminator (name is null-terminated per Dirent64 layout).
        var name_end = name_start;
        while (name_end < offset + hdr.d_reclen and name_end < bytes and buf[name_end] != 0) : (name_end += 1) {}
        const name = buf[name_start..name_end];

        if (std.mem.eql(u8, name, "hello.txt")) {
            found_hello = true;
        }
        if (std.mem.eql(u8, name, "a") and hdr.d_type == DT_DIR) {
            found_a_dir = true;
        }

        offset += hdr.d_reclen;
    }

    if (!found_hello) return error.TestFailed;
    if (!found_a_dir) return error.TestFailed;
}

/// List subdirectory /mnt2/a via getdents and verify entry "b" (DIR-02, nested).
///
/// Validates that multi-component path open works for directory FDs, and that
/// getdents on a nested directory returns correct entries.
pub fn testExt2GetdentsSubdir() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    // Open /mnt2/a as a directory FD.
    const dir_fd = try syscall.open("/mnt2/a", 0x10000, 0); // O_RDONLY | O_DIRECTORY
    defer syscall.close(dir_fd) catch {};

    var buf: [4096]u8 = undefined;
    const bytes = try syscall.getdents64(dir_fd, &buf, buf.len);

    if (bytes == 0) return error.TestFailed;

    // Walk entries looking for "b" with DT_DIR.
    var offset: usize = 0;
    var found_b = false;

    while (offset < bytes) {
        if (offset + DIRENT_NAME_OFFSET > bytes) break;
        const hdr: *align(1) const DirentHeader = @ptrCast(&buf[offset]);
        if (hdr.d_reclen == 0) break;

        const name_start = offset + DIRENT_NAME_OFFSET;
        var name_end = name_start;
        while (name_end < offset + hdr.d_reclen and name_end < bytes and buf[name_end] != 0) : (name_end += 1) {}
        const name = buf[name_start..name_end];

        if (std.mem.eql(u8, name, "b") and hdr.d_type == DT_DIR) {
            found_b = true;
        }

        offset += hdr.d_reclen;
    }

    if (!found_b) return error.TestFailed;
}

/// Read the target of fast symlink /mnt2/link_to_hello (DIR-03).
///
/// Validates ext2Readlink: fast symlink target stored in i_block[].
/// The symlink was created with: debugfs symlink link_to_hello /mnt2/hello.txt
/// Target must be "/mnt2/hello.txt" (15 bytes).
pub fn testExt2Readlink() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    var buf: [256]u8 = undefined;
    const len = try syscall.readlink("/mnt2/link_to_hello", &buf, buf.len);

    // debugfs symlink stores the exact string passed as the target.
    const expected = "/mnt2/hello.txt";
    if (len != expected.len) return error.TestFailed;
    if (!std.mem.eql(u8, buf[0..len], expected)) return error.TestFailed;
}

/// stat /mnt2/a/b/c/file.txt and verify metadata (DIR-04).
///
/// Validates ext2StatPath with multi-component path: size, S_IFREG mode bit.
pub fn testExt2StatNestedFile() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    var st = std.mem.zeroes(syscall.Stat);
    try syscall.stat("/mnt2/a/b/c/file.txt", &st);

    // Size must be exactly 17 bytes ("nested ext2 file\n").
    if (st.size != 17) return error.TestFailed;

    // Mode must have S_IFREG (0o100000) set.
    const S_IFREG: u32 = 0o100000;
    if ((st.mode & S_IFREG) == 0) return error.TestFailed;

    // Must have at least read permission for owner (S_IRUSR = 0o400).
    const S_IRUSR: u32 = 0o400;
    if ((st.mode & S_IRUSR) == 0) return error.TestFailed;
}

/// stat /mnt2/a and verify it is a directory with nlink >= 2 (DIR-04).
///
/// Validates ext2StatPath for directories: S_IFDIR mode bit, nlink count.
pub fn testExt2StatDirectory() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    var st = std.mem.zeroes(syscall.Stat);
    try syscall.stat("/mnt2/a", &st);

    // Mode must have S_IFDIR (0o040000) set.
    const S_IFDIR: u32 = 0o040000;
    if ((st.mode & S_IFDIR) == 0) return error.TestFailed;

    // Directories have at least 2 hard links: the parent entry + self "." entry.
    if (st.nlink < 2) return error.TestFailed;
}

/// Call statfs on /mnt2 and verify EXT2_SUPER_MAGIC and valid counts (DIR-05).
///
/// Validates ext2Statfs: f_type=0xEF53, f_bsize=4096, free counts within bounds.
pub fn testExt2Statfs() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    var st = std.mem.zeroes(syscall.Statfs);
    try syscall.statfs("/mnt2", &st);

    // EXT2_SUPER_MAGIC = 0xEF53.
    if (st.f_type != 0xEF53) return error.TestFailed;

    // Block size must be 4096 (matches mke2fs -b 4096 in build.zig).
    if (st.f_bsize != 4096) return error.TestFailed;

    // Free block and inode counts must be non-negative and within total counts.
    if (st.f_bfree < 0 or st.f_bfree > st.f_blocks) return error.TestFailed;
    if (st.f_ffree < 0 or st.f_ffree > st.f_files) return error.TestFailed;

    // Name length must be 255 (EXT2_NAME_LEN).
    if (st.f_namelen != 255) return error.TestFailed;
}
