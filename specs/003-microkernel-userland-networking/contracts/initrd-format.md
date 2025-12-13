# InitRD Format Contract

**Feature Branch**: `003-microkernel-userland-networking`
**Created**: 2025-12-05

## Overview

This document defines the InitRD (Initial Ramdisk) format used to provide read-only file access to userland applications via Limine Modules.

---

## Format: USTAR TAR Archive

The InitRD uses the USTAR TAR archive format, which is:
- Simple to parse (512-byte headers, sequential layout)
- Well-documented and standard
- Compatible with standard Unix `tar` command

### Why TAR?

- **Simplicity**: 512-byte fixed headers, easy to traverse
- **No metadata overhead**: Unlike FAT/ext2, no separate allocation tables
- **Standard tooling**: Create with `tar cvf initrd.tar file1 file2 ...`
- **Sufficient for MVP**: Read-only, sequential access is all we need

---

## TAR Header Structure (512 bytes)

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 100 | name | Filename (null-padded) |
| 100 | 8 | mode | File mode (octal ASCII) |
| 108 | 8 | uid | Owner user ID (octal ASCII) |
| 116 | 8 | gid | Owner group ID (octal ASCII) |
| 124 | 12 | size | File size in bytes (octal ASCII) |
| 136 | 12 | mtime | Modification time (octal ASCII) |
| 148 | 8 | checksum | Header checksum (octal ASCII) |
| 156 | 1 | typeflag | File type ('0' = regular, '5' = directory) |
| 157 | 100 | linkname | Link target (for symlinks) |
| 257 | 6 | magic | "ustar\0" |
| 263 | 2 | version | "00" |
| 265 | 32 | uname | Owner username |
| 297 | 32 | gname | Owner group name |
| 329 | 8 | devmajor | Device major (for device files) |
| 337 | 8 | devminor | Device minor (for device files) |
| 345 | 155 | prefix | Prefix for long filenames |
| 500 | 12 | padding | Padding to 512 bytes |

### Zig Structure

```zig
pub const TarHeader = packed struct {
    name: [100]u8,
    mode: [8]u8,
    uid: [8]u8,
    gid: [8]u8,
    size: [12]u8,
    mtime: [12]u8,
    checksum: [8]u8,
    typeflag: u8,
    linkname: [100]u8,
    magic: [6]u8,
    version: [2]u8,
    uname: [32]u8,
    gname: [32]u8,
    devmajor: [8]u8,
    devminor: [8]u8,
    prefix: [155]u8,
    _pad: [12]u8,

    comptime {
        if (@sizeOf(@This()) != 512) @compileError("TarHeader must be 512 bytes");
    }

    pub fn isValid(self: *const @This()) bool {
        return std.mem.eql(u8, self.magic[0..5], "ustar");
    }

    pub fn getName(self: *const @This()) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        return self.name[0..end];
    }

    pub fn getSize(self: *const @This()) usize {
        var size: usize = 0;
        for (self.size) |c| {
            if (c == ' ' or c == 0) break;
            if (c < '0' or c > '7') break;
            size = size * 8 + (c - '0');
        }
        return size;
    }

    pub fn isRegularFile(self: *const @This()) bool {
        return self.typeflag == '0' or self.typeflag == 0;
    }
};
```

---

## Archive Layout

```
+-------------------+
| TAR Header (512)  | ← File 1 header
+-------------------+
| File 1 Data       | ← File 1 content
| (rounded to 512)  |
+-------------------+
| TAR Header (512)  | ← File 2 header
+-------------------+
| File 2 Data       | ← File 2 content
| (rounded to 512)  |
+-------------------+
| ...               |
+-------------------+
| Two 512-byte      | ← End of archive marker
| zero blocks       |
+-------------------+
```

### Data Padding

File data is padded to the next 512-byte boundary:
- Actual data size stored in header's `size` field
- Padding bytes (0x00) fill the remainder of the final block
- Next header starts at the next 512-byte boundary

---

## Limine Module Loading

### Limine Configuration

```limine
MODULE_PATH=boot:///initrd.tar
MODULE_CMDLINE=initrd
```

### Kernel Access

```zig
pub export var module_request: limine.ModuleRequest = .{};

pub fn getInitrd() ?[]const u8 {
    const response = module_request.response orelse return null;
    if (response.module_count == 0) return null;

    const module = response.modules[0];
    const ptr: [*]const u8 = @ptrFromInt(module.address);
    return ptr[0..module.size];
}
```

---

## InitRD API

### File Structure

```zig
pub const InitRDFile = struct {
    name: []const u8,
    data: []const u8,
};
```

### Lookup Function

```zig
pub const InitRD = struct {
    data: []const u8,

    pub fn findFile(self: *const @This(), path: []const u8) ?InitRDFile {
        // Normalize path: remove leading '/' if present
        const search_name = if (path.len > 0 and path[0] == '/')
            path[1..]
        else
            path;

        var offset: usize = 0;
        while (offset + 512 <= self.data.len) {
            const header: *const TarHeader = @ptrCast(@alignCast(self.data.ptr + offset));

            // Check for end of archive (two zero blocks)
            if (header.name[0] == 0) break;

            // Validate USTAR magic
            if (!header.isValid()) break;

            const name = header.getName();
            const size = header.getSize();

            if (header.isRegularFile() and std.mem.eql(u8, name, search_name)) {
                return InitRDFile{
                    .name = name,
                    .data = self.data[offset + 512 .. offset + 512 + size],
                };
            }

            // Advance to next header (data + padding to 512)
            const data_blocks = (size + 511) / 512;
            offset += 512 + (data_blocks * 512);
        }
        return null;
    }

    pub fn listFiles(self: *const @This()) FileIterator {
        return FileIterator{ .initrd = self, .offset = 0 };
    }
};

pub const FileIterator = struct {
    initrd: *const InitRD,
    offset: usize,

    pub fn next(self: *@This()) ?InitRDFile {
        while (self.offset + 512 <= self.initrd.data.len) {
            const header: *const TarHeader = @ptrCast(@alignCast(
                self.initrd.data.ptr + self.offset,
            ));

            if (header.name[0] == 0) return null;
            if (!header.isValid()) return null;

            const name = header.getName();
            const size = header.getSize();
            const data_offset = self.offset + 512;

            // Advance to next header
            const data_blocks = (size + 511) / 512;
            self.offset += 512 + (data_blocks * 512);

            if (header.isRegularFile()) {
                return InitRDFile{
                    .name = name,
                    .data = self.initrd.data[data_offset .. data_offset + size],
                };
            }
        }
        return null;
    }
};
```

---

## Creating an InitRD

### Using Standard tar

```bash
# Create initrd with game files
tar cvf initrd.tar doom.wad doom1.wad textures/

# Verify contents
tar tvf initrd.tar

# Add to bootable ISO
cp initrd.tar iso/boot/initrd.tar
```

### Limine Configuration Update

```limine
PROTOCOL=limine

/zscapek
    PROTOCOL=limine
    KERNEL_PATH=boot:///kernel.elf
    MODULE_PATH=boot:///initrd.tar
    MODULE_CMDLINE=initrd
```

---

## Syscall Integration

### sys_open (13)

```zig
fn sysOpen(path_ptr: u64, flags: u32) i32 {
    // Validate path pointer
    const path = validateUserString(path_ptr) orelse return -EFAULT;

    // Only O_RDONLY supported
    if (flags != 0) return -EINVAL;

    // Find file in InitRD
    const file = initrd.findFile(path) orelse return -ENOENT;

    // Allocate file descriptor
    const proc = scheduler.currentProcess();
    const fd = proc.allocFd() orelse return -EMFILE;

    proc.fds[fd] = .{
        .initrd_file = file,
        .position = 0,
        .flags = flags,
    };

    return @intCast(fd);
}
```

### sys_read (15)

```zig
fn sysRead(fd: u32, buf_ptr: u64, count: u64) isize {
    const proc = scheduler.currentProcess();

    // Validate FD
    if (fd >= proc.fds.len) return -EBADF;
    const file_desc = &proc.fds[fd] orelse return -EBADF;

    // Validate buffer
    const buf = validateUserBuffer(buf_ptr, count) orelse return -EFAULT;

    // Read from file
    const file = file_desc.initrd_file;
    const remaining = file.data.len - file_desc.position;
    const to_read = @min(count, remaining);

    @memcpy(buf[0..to_read], file.data[file_desc.position..][0..to_read]);
    file_desc.position += to_read;

    return @intCast(to_read);
}
```

### sys_seek (16)

```zig
fn sysSeek(fd: u32, offset: i64, whence: u32) i64 {
    const proc = scheduler.currentProcess();

    if (fd >= proc.fds.len) return -EBADF;
    const file_desc = &proc.fds[fd] orelse return -EBADF;

    const file_size: i64 = @intCast(file_desc.initrd_file.data.len);
    const current: i64 = @intCast(file_desc.position);

    const new_pos: i64 = switch (whence) {
        0 => offset,                    // SEEK_SET
        1 => current + offset,          // SEEK_CUR
        2 => file_size + offset,        // SEEK_END
        else => return -EINVAL,
    };

    if (new_pos < 0) return -EINVAL;
    if (new_pos > file_size) return -EINVAL;

    file_desc.position = @intCast(new_pos);
    return new_pos;
}
```

---

## Validation Rules

1. **Header Magic**: Must be "ustar\0" for USTAR format
2. **Size Field**: Octal ASCII, max 11 digits (8GB file limit)
3. **Typeflag**: '0' or '\0' for regular files
4. **Filename**: Max 100 characters (255 with prefix)
5. **End Marker**: Two consecutive 512-byte zero blocks

---

## Limitations (MVP)

- **Read-only**: No write operations supported
- **No directories**: Flat namespace (paths with '/' are just filenames)
- **No symlinks**: Typeflag '2' ignored
- **No permissions**: Mode field ignored
- **Single InitRD**: Only first Limine module used
- **Max file size**: 8GB (octal field limit)
- **Max total size**: Limited by available physical memory
