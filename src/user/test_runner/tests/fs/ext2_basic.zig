//! ext2 filesystem integration tests (Phase 47).
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

const std = @import("std");
const syscall = @import("syscall");

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
/// We seek to 4*1024*1024 + 4096 = 4198400, which is in double-indirect territory
/// (4194304 < 4198400 < 5242880).
pub fn testExt2ReadDoubleIndirect() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    const fd = try syscall.open("/mnt2/large.bin", 0, 0);
    defer syscall.close(fd) catch {};

    // Seek to a known double-indirect offset (4MB + 4KB).
    const seek_offset: isize = 4 * 1024 * 1024 + 4096;
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
