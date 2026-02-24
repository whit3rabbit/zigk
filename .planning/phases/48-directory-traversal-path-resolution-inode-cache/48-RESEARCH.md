# Phase 48: Directory Traversal, Path Resolution, and Inode Cache - Research

**Researched:** 2026-02-23
**Domain:** ext2 filesystem -- multi-component path resolution, getdents, fast symlinks, stat, statfs, inode LRU cache
**Confidence:** HIGH

## Summary

Phase 48 extends the Phase 47 `lookupInRootDir` single-component stub into a full multi-component path resolver that can navigate arbitrary directory nesting on the ext2 mount. The core algorithms are all direct extensions of code already written: `lookupInRootDir` (inode.zig) performs the same directory block scan that the multi-level resolver needs -- it just needs to be called iteratively for each path component. The data structures (`Inode`, `DirEntry`, `Ext2Fs`, `resolveBlock`, `readInode`) are all in place and working from Phase 47.

Six requirements must be satisfied: DIR-01 (multi-component path traversal), DIR-02 (getdents with correct rec_len stride), DIR-03 (fast symlinks, target in i_block[], up to 60 bytes), DIR-04 (stat returning full metadata), DIR-05 (statfs returning free block and inode counts), and INODE-05 (fixed-size LRU inode cache). The first five are VFS callback implementations. INODE-05 is an internal data structure added to `Ext2Fs` that short-circuits `readInode` disk reads. All six have well-understood implementations with no ambiguous design choices.

The main novel piece is the inode cache (INODE-05). A fixed-size LRU array (16 or 32 entries) stored directly in `Ext2Fs` is the right design for this kernel -- no dynamic allocation, no complex data structures, no locks beyond what Phase 47 already avoids. The cache is validated by implementing directory traversal first (which exercises repeated inode reads on the same directory inodes), so the cache eliminates the redundant reads that traversal naturally generates. The ext2 image needs new content for Phase 48: a nested directory structure `a/b/c/file.txt`, a fast symlink, and enough directory entries to test `getdents` rec_len stride handling (specifically the last entry in a directory block, which uses a padded rec_len to consume remaining block space).

**Primary recommendation:** Implement in this order: (1) generalize `lookupInRootDir` to `lookupInDir(fs, dir_inode, name)`, (2) add `resolvePath(fs, path)` that calls `lookupInDir` iteratively, (3) wire `resolvePath` into `ext2Open`, `ext2StatPath`, and `ext2Readlink`, (4) add `ext2GetdentsFromFd` to the directory FD's FileOps, (5) add `ext2Statfs` to the VFS FileSystem callback, (6) add the LRU cache to `Ext2Fs` and wrap `readInode` calls through it.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| DIR-01 | Kernel traverses nested directories to resolve multi-component paths | Generalize Phase 47 `lookupInRootDir` to `lookupInDir(fs, dir_inode, name)`, then add `resolvePath` loop splitting path by '/'. Each component calls `lookupInDir` on the previous directory inode. Guard against symlink loops and maximum depth. |
| DIR-02 | Kernel lists directory contents via getdents with correct rec_len stride | Wire `getdents` callback into `Ext2Fs.open` for directory FDs. Walk DirEntry records by `rec_len` (never by `name_len+8`). The last entry in a block has `rec_len` padded to the end of the block. Populate ext2 image with a directory containing >= 2 entries to test. |
| DIR-03 | Kernel reads fast symlinks (target in i_block[], <= 60 bytes) | `ext2Readlink` VFS callback: read inode, check `i_size <= 60`, cast `i_block[0..15]` as 60-byte char buffer, copy `i_size` bytes. Do NOT call `readSectors`. Detect fast vs slow by `i_size <= 60 AND i_blocks == 0`. |
| DIR-04 | stat_path returns correct metadata (mode, uid, gid, size, timestamps, nlink) | Phase 47 `ext2StatPath` already does this for root-only paths. Extend to use `resolvePath` for multi-component paths. The `Stat` struct fill in `ext2FileStat` is already complete -- wire the same fill logic into the path-based stat. |
| DIR-05 | statfs returns filesystem-level free block and inode counts | Implement `ext2Statfs(ctx)` reading from `fs.superblock`: `f_blocks = s_blocks_count`, `f_bfree = s_free_blocks_count`, `f_bavail = s_free_blocks_count - s_r_blocks_count`, `f_files = s_inodes_count`, `f_ffree = s_free_inodes_count`. EXT2_SUPER_MAGIC = 0xEF53. |
| INODE-05 | Inode cache (fixed-size LRU) avoids redundant disk reads during path traversal | Fixed array of `InodeCacheEntry { inum: u32, inode: Inode, lru_gen: u64 }` in `Ext2Fs`. Wrap `readInode` behind `getCachedInode(fs, inum)` which probes the array, returns hit without disk read, or evicts oldest entry on miss. No separate locking needed (Phase 48 is read-only, same concurrency model as Phase 47). |
</phase_requirements>

## Standard Stack

### Core

| Component | Location | Purpose | Why Standard |
|-----------|----------|---------|--------------|
| `src/fs/ext2/inode.zig` | Existing | `readInode`, `resolveBlock`, `lookupInRootDir`, `Ext2File`, `ext2_file_ops` | Phase 47 deliverable; Phase 48 extends it |
| `src/fs/ext2/mount.zig` | Existing | `Ext2Fs` state, VFS callbacks (`ext2Open`, `ext2StatPath`) | Add `ext2Statfs`, `ext2Readlink`, `ext2Getdents` callbacks here |
| `src/fs/ext2/types.zig` | Existing | `Inode`, `DirEntry`, `Superblock`, `GroupDescriptor`, all on-disk constants | Already complete and comptime-verified |
| `src/fs/vfs.zig` | Existing | `FileSystem.getdents`, `.statfs`, `.readlink` callback slots (already defined, null in Phase 47) | Phase 48 fills these in; `vfs.FileSystem` struct has all needed fields |
| `src/kernel/fs/fd.zig` | Existing | `FileOps.getdents` callback, `createFd`, `FileDescriptor.position` for dir iteration state | `sfsGetdents` is the reference pattern |
| `src/uapi/fs/stat.zig` | Existing | `Statfs` struct (f_type i64, f_bsize, f_blocks, f_bfree, f_bavail, f_files, f_ffree, f_fsid, f_namelen, f_frsize, f_flags, f_spare[4]) | Must use this exact struct for VFS statfs return |
| `src/uapi/fs/dirent.zig` | Existing | `Dirent64` (d_ino u64, d_off i64, d_reclen u16, d_type u8, d_name [0]u8) | Must match this for getdents output |
| `heap.allocator()` | Existing | Block buffer allocation for directory block reads | 4KB block buffers always on heap (MEMORY.md pattern) |
| `std.math.add/mul` | std lib | Overflow-safe arithmetic | CLAUDE.md rule 5, mandatory |

### New Structures

| Structure | Location | Purpose |
|-----------|----------|---------|
| `InodeCacheEntry` | `inode.zig` or `mount.zig` | `{ inum: u32, inode: types.Inode, lru_gen: u64 }` per slot |
| `INODE_CACHE_SIZE` constant | same file | 16 or 32 entries (see Open Questions) |
| `Ext2DirFd` | `inode.zig` | Private data for directory FDs: `{ fs: *Ext2Fs, dir_inode_num: u32, dir_inode: types.Inode }` |

### Ext2Fs Changes (mount.zig)

Add to the `Ext2Fs` struct:
```zig
// LRU inode cache (INODE-05)
inode_cache: [INODE_CACHE_SIZE]InodeCacheEntry,
inode_cache_gen: u64,  // monotonically increasing counter for LRU eviction
```

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Fixed-size array LRU | HashMap(u32, Inode) | HashMap needs heap allocation, dynamic resize, hash collisions; array is simpler, zero-allocation, correct for small cache sizes (16-32 entries) |
| Fixed-size array LRU | Per-component cache hits only | More complex access pattern; LRU array is simpler to reason about |
| Copying `lookupInRootDir` for each directory | Factoring into `lookupInDir(dir_inode, name)` | Factoring is mandatory; code duplication creates divergence bugs |

## Architecture Patterns

### Recommended Structure

```
src/fs/ext2/
    types.zig       # EXISTING: on-disk structs
    mount.zig       # EXISTING: Ext2Fs (add cache fields), VFS callbacks (add statfs, readlink, getdents)
    inode.zig       # EXISTING: extend with lookupInDir, resolvePath, ext2Dir* ops, cache functions
```

All new code belongs in the existing two files. Do NOT add a third file -- the module is not large enough to justify splitting further.

### Pattern 1: resolvePath -- Multi-Component Path Traversal (DIR-01)

The core algorithm splits the path by '/' and iterates `lookupInDir` on each component:

```zig
// Source: ext2 spec directory structure, Phase 47 lookupInRootDir pattern
pub fn resolvePath(fs: *Ext2Fs, path: []const u8) Ext2Error!u32 {
    // Start from root inode (inode 2)
    var current_inum: u32 = types.ROOT_INODE;

    // Strip leading '/'
    var remaining = path;
    if (remaining.len > 0 and remaining[0] == '/') {
        remaining = remaining[1..];
    }

    // Root itself
    if (remaining.len == 0) return current_inum;

    // Walk each path component
    var it = std.mem.tokenizeScalar(u8, remaining, '/');
    while (it.next()) |component| {
        if (component.len == 0) continue; // Skip empty components (double-slash)
        if (component.len > 255) return error.NotFound; // ext2 name_len is u8

        // Read the current directory inode
        const dir_inode = try getCachedInode(fs, current_inum);

        if (!dir_inode.isDir()) return error.NotFound; // Not a directory

        // Lookup component name in this directory
        current_inum = try lookupInDir(fs, &dir_inode, component);
    }

    return current_inum;
}
```

**Key detail**: Use `std.mem.tokenizeScalar(u8, path, '/')` which skips empty tokens (handles `//` correctly). Do NOT use `splitScalar` which yields empty strings for consecutive delimiters.

**Depth limit**: Limit iterations to prevent infinite loops from circular symlinks. A depth counter of 40 matches Linux's `MAXSYMLINKS`. Since Phase 48 does NOT resolve symlinks during traversal (only `readlink` exposes them), the depth counter here is just a component count safety limit (e.g., 255 max components).

### Pattern 2: lookupInDir -- Generic Directory Scan (factored from lookupInRootDir)

```zig
// Source: Phase 47 lookupInRootDir, generalized to any directory inode
pub fn lookupInDir(fs: *Ext2Fs, dir_inode: *const types.Inode, name: []const u8) Ext2Error!u32 {
    if (!dir_inode.isDir()) return error.NotFound;
    if (name.len == 0 or name.len > 255) return error.NotFound;

    const dir_blocks: u32 = if (dir_inode.i_size == 0)
        0
    else
        (dir_inode.i_size + fs.block_size - 1) / fs.block_size;

    const alloc = heap.allocator();
    const block_buf = alloc.alloc(u8, fs.block_size) catch return error.OutOfMemory;
    defer alloc.free(block_buf);

    var lb: u32 = 0;
    while (lb < dir_blocks) : (lb += 1) {
        const phys_block = try resolveBlock(fs, dir_inode, lb);
        if (phys_block == 0) continue; // sparse

        @memset(block_buf, 0);
        const lba = std.math.mul(u64, @as(u64, phys_block), @as(u64, fs.sectors_per_block))
            catch return error.IOError;
        fs.dev.readSectors(lba, fs.sectors_per_block, block_buf) catch return error.IOError;

        // Walk DirEntry records by rec_len
        var offset: u32 = 0;
        while (offset < fs.block_size) {
            if (offset + @sizeOf(types.DirEntry) > fs.block_size) break;
            const entry: *const types.DirEntry = @ptrCast(@alignCast(block_buf[offset..].ptr));
            if (entry.rec_len == 0) break; // Corrupt or end-of-block sentinel
            if (entry.inode != 0 and entry.name_len > 0) {
                const name_start = offset + @sizeOf(types.DirEntry);
                const name_end = name_start + @as(u32, entry.name_len);
                if (name_end <= fs.block_size) {
                    const entry_name = block_buf[name_start..name_end];
                    if (std.mem.eql(u8, entry_name, name)) {
                        return entry.inode;
                    }
                }
            }
            offset += entry.rec_len;
        }
    }
    return error.NotFound;
}
```

**Critical detail**: The `lookupInRootDir` in Phase 47 ONLY scans direct blocks (comment says "Phase 47: root only"). The generalized `lookupInDir` must use `resolveBlock` for all block levels, so large directories (rare but legal) with more than 12 blocks work.

### Pattern 3: ext2GetdentsFromFd -- Directory Listing (DIR-02)

The directory FD needs its own FileOps vtable with a `getdents` function. The key difference from InitRD getdents is that ext2 directory blocks use `DirEntry.rec_len` as the stride, NOT `align(name_len + 8, 4)`. The `rec_len` field is authoritative -- the last entry in each block uses a padded `rec_len` that covers all remaining block space.

```zig
// Ext2DirFd: private_data for directory FileDescriptors
const Ext2DirFd = struct {
    fs: *Ext2Fs,
    dir_inode_num: u32,
    dir_inode: types.Inode,
};

pub const ext2_dir_ops = fd.FileOps{
    .read = null,
    .write = null,
    .close = ext2DirClose,
    .seek = null,
    .stat = ext2DirStat,
    .ioctl = null,
    .mmap = null,
    .poll = null,
    .truncate = null,
    .getdents = ext2GetdentsFromFd,
    .chown = null,
};

fn ext2GetdentsFromFd(file_desc: *fd.FileDescriptor, dirp: usize, count: usize) isize {
    const dir: *Ext2DirFd = @ptrCast(@alignCast(file_desc.private_data.?));
    const fs = dir.fs;
    const dir_inode = &dir.dir_inode;

    // file_desc.position encodes: (block_index << 32) | byte_offset_in_block
    // Simpler alternative: position = absolute byte offset in directory data
    // Use absolute byte offset -- simpler and matches lseek semantics
    var abs_offset: u64 = file_desc.position;

    const dir_size: u64 = @as(u64, dir_inode.i_size);
    if (abs_offset >= dir_size) return 0; // EOF

    const alloc = heap.allocator();
    const block_buf = alloc.alloc(u8, fs.block_size) catch return -12; // ENOMEM
    defer alloc.free(block_buf);

    const user_buf: [*]volatile u8 = @ptrFromInt(dirp);
    var bytes_written: usize = 0;

    while (abs_offset < dir_size) {
        const logical_block: u32 = @intCast(abs_offset / fs.block_size);
        const byte_in_block: u32 = @intCast(abs_offset % fs.block_size);

        const phys_block = resolveBlock(fs, dir_inode, logical_block) catch return -5; // EIO
        if (phys_block == 0) {
            // Sparse directory block -- advance past it
            abs_offset = (@as(u64, logical_block) + 1) * fs.block_size;
            continue;
        }

        @memset(block_buf, 0);
        const lba = std.math.mul(u64, @as(u64, phys_block), @as(u64, fs.sectors_per_block))
            catch return -5;
        fs.dev.readSectors(lba, fs.sectors_per_block, block_buf) catch return -5;

        // Walk entries in this block starting at byte_in_block
        var block_offset: u32 = byte_in_block;
        while (block_offset < fs.block_size) {
            if (block_offset + @sizeOf(types.DirEntry) > fs.block_size) break;
            const entry: *const types.DirEntry = @ptrCast(@alignCast(block_buf[block_offset..].ptr));
            if (entry.rec_len == 0) break;

            const next_block_offset = block_offset + entry.rec_len;

            if (entry.inode != 0 and entry.name_len > 0) {
                const name_start: u32 = block_offset + @sizeOf(types.DirEntry);
                const name_len: usize = entry.name_len;
                const name_end: u32 = name_start + @intCast(name_len);

                if (name_end <= fs.block_size) {
                    const name = block_buf[name_start..name_end];
                    const d_reclen = @sizeOf(uapi.dirent.Dirent64) + name_len + 1;
                    const aligned_reclen = std.mem.alignForward(usize, d_reclen, 8);

                    if (bytes_written + aligned_reclen > count) {
                        // Buffer full -- stop before this entry
                        file_desc.position = abs_offset + block_offset;
                        return std.math.cast(isize, bytes_written) orelse -75;
                    }

                    // Map ext2 file_type to DT_* constants
                    const d_type: u8 = switch (entry.file_type) {
                        types.FT_REG_FILE => uapi.dirent.DT_REG,
                        types.FT_DIR => uapi.dirent.DT_DIR,
                        types.FT_SYMLINK => uapi.dirent.DT_LNK,
                        types.FT_CHRDEV => uapi.dirent.DT_CHR,
                        types.FT_BLKDEV => uapi.dirent.DT_BLK,
                        else => uapi.dirent.DT_UNKNOWN,
                    };

                    const ent = uapi.dirent.Dirent64{
                        .d_ino = @as(u64, entry.inode),
                        .d_off = @intCast(abs_offset + next_block_offset),
                        .d_reclen = @intCast(aligned_reclen),
                        .d_type = d_type,
                        .d_name = undefined,
                    };

                    // Write struct header
                    const ent_bytes = std.mem.asBytes(&ent);
                    for (ent_bytes, 0..) |byte, j| user_buf[bytes_written + j] = byte;

                    // Write filename
                    const name_offset = bytes_written + @offsetOf(uapi.dirent.Dirent64, "d_name");
                    for (name, 0..) |byte, j| user_buf[name_offset + j] = byte;
                    user_buf[name_offset + name_len] = 0; // null terminator

                    bytes_written += aligned_reclen;
                }
            }

            block_offset = next_block_offset;
        }

        // Advance to next block
        abs_offset = (@as(u64, logical_block) + 1) * fs.block_size;
    }

    file_desc.position = abs_offset;
    return std.math.cast(isize, bytes_written) orelse -75;
}
```

**Critical detail about rec_len**: The last entry in a directory block has `rec_len` padded to fill the rest of the block. For example, if the last entry's name is 4 bytes and block_size is 4096, the entry starts at byte 3848 and `rec_len = 4096 - 3848 = 248`, not `align(8+4, 4) = 12`. Walking by `rec_len` is the only correct traversal -- do NOT re-derive rec_len from name_len.

### Pattern 4: ext2Readlink -- Fast Symlinks (DIR-03)

Fast symlinks in ext2 store their target in `i_block[]` when `i_size <= 60` bytes and `i_blocks == 0` (no allocated disk blocks). The `i_block` array is 15 u32 slots = 60 bytes total, which serves as a char buffer.

```zig
// Source: ext2 spec section on symbolic links
// VFS callback signature: fn(ctx, path, buf) Error!usize
fn ext2Readlink(ctx: ?*anyopaque, path: []const u8, buf: []u8) vfs.Error!usize {
    const fs: *Ext2Fs = @ptrCast(@alignCast(ctx.?));

    // Strip leading '/' from VFS-relative path
    var rel_path = path;
    if (rel_path.len > 0 and rel_path[0] == '/') rel_path = rel_path[1..];

    // Resolve path to inode
    const inum = inode_mod.resolvePath(fs, rel_path) catch |err| {
        return switch (err) {
            error.NotFound => vfs.Error.NotFound,
            else => vfs.Error.IOError,
        };
    };

    const inode = inode_mod.getCachedInode(fs, inum) catch return vfs.Error.IOError;

    if (!inode.isSymlink()) return vfs.Error.NotSupported; // EINVAL: not a symlink

    // Fast symlink: target is in i_block[] as a char buffer
    // Condition: i_size <= 60 (fits in 15 u32 slots) AND i_blocks == 0
    if (inode.i_size > 60 or inode.i_blocks != 0) {
        // Slow symlink (ADV-02, deferred)
        return vfs.Error.NotSupported;
    }

    const target_len = @min(@as(usize, inode.i_size), buf.len);
    if (target_len == 0) return 0;

    // Cast i_block[] as a byte array to extract target
    const i_block_bytes: *const [60]u8 = @ptrCast(&inode.i_block);
    @memcpy(buf[0..target_len], i_block_bytes[0..target_len]);

    return target_len;
}
```

**Critical detail**: The distinction between fast and slow symlinks is `i_blocks == 0`. A symlink with `i_size <= 60` but `i_blocks != 0` has its target in a data block (rare but valid). Phase 48 only handles the fast case.

### Pattern 5: ext2Statfs -- Filesystem Statistics (DIR-05)

```zig
// EXT2_SUPER_MAGIC = 0xEF53
fn ext2Statfs(ctx: ?*anyopaque) vfs.Error!uapi.stat.Statfs {
    const fs: *Ext2Fs = @ptrCast(@alignCast(ctx.?));
    const sb = &fs.superblock;

    // f_bavail excludes reserved blocks (s_r_blocks_count)
    const bavail = if (sb.s_free_blocks_count >= sb.s_r_blocks_count)
        sb.s_free_blocks_count - sb.s_r_blocks_count
    else
        0;

    return uapi.stat.Statfs{
        .f_type = 0xEF53,
        .f_bsize = @as(i64, fs.block_size),
        .f_blocks = @as(i64, sb.s_blocks_count),
        .f_bfree = @as(i64, sb.s_free_blocks_count),
        .f_bavail = @as(i64, bavail),
        .f_files = @as(i64, sb.s_inodes_count),
        .f_ffree = @as(i64, sb.s_free_inodes_count),
        .f_fsid = .{ .val = .{ 0, 0 } },
        .f_namelen = 255, // ext2 max name length
        .f_frsize = @as(i64, fs.block_size), // Fragment size = block size for ext2
        .f_flags = 1, // ST_RDONLY (1)
        .f_spare = [_]i64{0} ** 4,
    };
}
```

**Note**: The `Statfs.f_type` field is `i64` in the project's uapi (not `i32` or `u32`). Cast `0xEF53` accordingly.

### Pattern 6: Inode LRU Cache (INODE-05)

```zig
// INODE_CACHE_SIZE: 16 entries captures a typical path depth of a/b/c/d
// with room for parent directory inodes being re-read during getdents
pub const INODE_CACHE_SIZE: usize = 16;

pub const InodeCacheEntry = struct {
    inum: u32,      // 0 = slot is empty
    inode: types.Inode,
    lru_gen: u64,   // higher = more recently used
};

// Called from readInode -- wraps disk read with cache lookup
pub fn getCachedInode(fs: *Ext2Fs, inum: u32) Ext2Error!types.Inode {
    if (inum == 0) return error.InvalidInode;

    // Probe: linear scan of 16-entry array is O(16) = fast
    var oldest_gen: u64 = std.math.maxInt(u64);
    var oldest_slot: usize = 0;

    for (fs.inode_cache, 0..) |*entry, i| {
        if (entry.inum == inum) {
            // Cache hit
            fs.inode_cache_gen += 1;
            entry.lru_gen = fs.inode_cache_gen;
            return entry.inode;
        }
        if (entry.lru_gen < oldest_gen) {
            oldest_gen = entry.lru_gen;
            oldest_slot = i;
        }
    }

    // Cache miss: read from disk
    const inode = try readInode(fs, inum);

    // Evict oldest entry and insert
    fs.inode_cache_gen += 1;
    fs.inode_cache[oldest_slot] = .{
        .inum = inum,
        .inode = inode,
        .lru_gen = fs.inode_cache_gen,
    };

    return inode;
}
```

**Cache initialization**: `Ext2Fs` must zero-initialize `inode_cache` on mount. In `mount.zig:init()`, add:
```zig
self.inode_cache = [_]InodeCacheEntry{.{ .inum = 0, .inode = undefined, .lru_gen = 0 }} ** INODE_CACHE_SIZE;
self.inode_cache_gen = 0;
```

**Concurrency**: Phase 48 maintains Phase 47's policy -- no per-inode lock on `Ext2Fs` reads. The cache is single-threaded from the perspective of VFS open calls (VFS spinlock serializes concurrent ext2 operations for now). If concurrent ext2 opens are needed in a future phase, a spinlock on the cache will be needed. Document this explicitly but do not add it in Phase 48.

### Anti-Patterns to Avoid

- **Walking directory entries by `name_len` instead of `rec_len`**: The `rec_len` field is the stride. Using `align(8 + entry.name_len, 4)` instead of `entry.rec_len` silently fails to reach the last entry in each block (which has padded `rec_len`). The test for DIR-02 specifically checks the last entry in a block -- this anti-pattern will fail that test.
- **Re-using the Phase 47 `lookupInRootDir` signature**: Phase 48 introduces `lookupInDir(fs, dir_inode, name)` which takes a pre-read inode. Calling `readInode(fs, 2)` inside every directory lookup re-reads the root inode for each path component -- the inode cache exists to avoid exactly this. Factor correctly.
- **Mixing fast and slow symlink detection**: Only `i_blocks == 0` AND `i_size <= 60` is a fast symlink. Some images created with older tools set `i_size <= 60` but still allocate a block (`i_blocks = 8` for one 512-byte block unit). Treating those as fast symlinks corrupts the target string with random `i_block` contents.
- **Stack-allocating the directory block buffer**: Same constraint as Phase 47. Always `heap.allocator().alloc(u8, fs.block_size)`. The ext2GetdentsFromFd is called from a syscall stack frame that may already be several frames deep.
- **Forgetting DT_DIR type in getdents output**: If `file_type == FT_DIR` is mapped to DT_UNKNOWN, `ls` and userspace directory traversal break. The `INCOMPAT_FILETYPE` flag (set by default by mke2fs) guarantees `file_type` is populated in directory entries.
- **statfs f_bavail ignoring reserved blocks**: `f_bavail` is free blocks available to unprivileged users = `s_free_blocks_count - s_r_blocks_count`. Using `f_bfree` for both is wrong. Guard against underflow.
- **inode_cache slot inum=0 collision**: The cache uses `inum == 0` as "empty slot sentinel". Since ext2 inode numbering is 1-based and `getCachedInode` returns `error.InvalidInode` for inum=0, this is safe. Do not allow inum=0 entries.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Path component splitting | Custom loop with index tracking | `std.mem.tokenizeScalar(u8, path, '/')` | Handles empty components (double slashes) correctly; tested stdlib |
| DirEntry alignment | Manual byte pointer arithmetic | `@ptrCast(@alignCast(block_buf[offset..].ptr))` | Same pattern as Phase 47 `lookupInRootDir` -- verified working |
| Dirent64 output | Custom struct packing | Use existing `uapi.dirent.Dirent64` + `@offsetOf(.., "d_name")` pattern from `sfsGetdents` | sfsGetdents pattern is tested and known-correct for Linux ABI |
| LRU eviction logic | Red-black tree, doubly-linked list | Linear scan of 16-entry array comparing `lru_gen` | O(16) is negligible; no dynamic allocation; simpler than pointer-based structures |
| Statfs field computation | Re-reading superblock from disk | Already loaded into `fs.superblock` at mount time | Superblock is in-memory since Phase 46; no disk read needed |

## Common Pitfalls

### Pitfall 1: rec_len Stride vs. Computed Entry Size
**What goes wrong:** Using `align(8 + entry.name_len, 4)` as the stride instead of `entry.rec_len`. The last entry in each 4096-byte directory block has `rec_len` padded to the block boundary (e.g., `rec_len = 4096 - last_entry_start`). Walking by computed size stops before reaching this entry.
**Why it happens:** The confusion arises because for entries that are NOT the last in a block, `rec_len` equals the rounded-up computed size. This makes the bug invisible until a directory has more than one entry and the last entry falls at a non-trivial position.
**How to avoid:** Always use `offset += entry.rec_len`. Never add a computed alternative.
**Warning signs:** `getdents` returns fewer entries than `debugfs ls` shows; specifically the last entry in a directory block is missing.

### Pitfall 2: ext2Open Multi-Level Path Not Updating ext2StatPath
**What goes wrong:** `resolvePath` is wired into `ext2Open` but `ext2StatPath` still calls `lookupInRootDir`. `stat("/mnt2/a/b/c/file.txt")` returns NotFound while `open` succeeds.
**Why it happens:** Two separate code paths exist in `mount.zig`. Easy to update one and forget the other.
**How to avoid:** Both `ext2Open` and `ext2StatPath` must be updated to use `resolvePath`. Add this as an explicit checklist item in the plan.
**Warning signs:** `testExt2StatNestedFile` fails even though `testExt2OpenNestedPath` passes.

### Pitfall 3: Directory FD getdents Position Encoding
**What goes wrong:** Using `file_desc.position` as a block index (u32) instead of an absolute byte offset (u64) breaks when the caller makes multiple `getdents` calls to drain a large directory. The second call starts at the wrong position.
**Why it happens:** InitRD getdents uses position as an iterator offset into tar data; SFS uses position as an entry index. Choosing the wrong encoding for ext2 leads to skipped or repeated entries.
**How to avoid:** Use absolute byte offset in directory data as the position value. This maps directly to `logical_block * block_size + byte_in_block`. The call returns with `position` set to the byte offset of the NEXT unconsumed entry.
**Warning signs:** Second call to getdents on the same directory FD returns duplicate entries or skips entries.

### Pitfall 4: Fast Symlink Detection Using Only i_size
**What goes wrong:** Checking `inode.i_size <= 60` without also checking `inode.i_blocks == 0`. A symlink with a 30-byte target stored in a data block (slow symlink from an older ext2 tool) would pass the size check but contain garbage in `i_block`.
**Why it happens:** The fast symlink heuristic is simple-looking but has two conditions.
**How to avoid:** Always check BOTH conditions: `i_size <= 60 AND i_blocks == 0`.
**Warning signs:** `readlink` returns correct length but wrong bytes on some ext2 images.

### Pitfall 5: inode_cache Uninitialized on Ext2Fs Mount
**What goes wrong:** `Ext2Fs` is `heap.allocator().create(Ext2Fs)` in `mount.zig:init()`, which in `ReleaseFast` gives uninitialized memory (CLAUDE.md security standard: prefer zero-initialized). The `inum` field in uninitialized cache entries could accidentally match real inode numbers, causing stale data returns.
**Why it happens:** `heap.allocator().create()` does not zero-initialize in ReleaseFast mode.
**How to avoid:** Explicitly zero-initialize the cache array in `init()` after `create()`:
```zig
self.inode_cache = [_]InodeCacheEntry{.{ .inum = 0, .inode = undefined, .lru_gen = 0 }} ** INODE_CACHE_SIZE;
self.inode_cache_gen = 0;
```
Or use `@memset(self, 0)` on the whole `Ext2Fs` before field-by-field assignment.
**Warning signs:** Intermittent wrong metadata returns on the first few opens after mount.

### Pitfall 6: openRootDir Still Using dir_ops Tag
**What goes wrong:** Phase 47's `openRootDir` returns a `dir_ops` FD with `initrd_dir_tag` as private_data. `sys_getdents64` in `dir.zig` checks `fd.ops != &fd_mod.dir_ops` for the ENOTDIR guard, then dispatches to `ext2GetdentsFromFd` via `fd.ops.getdents`. If the root dir FD uses `ext2_dir_ops` (with `getdents = ext2GetdentsFromFd`), the flow works. If it still uses `dir_ops` (which has `getdents = null`), getdents falls through to the initrd/devfs tag dispatch and returns wrong results.
**Why it happens:** Phase 47 explicitly deferred directory FD creation for getdents (`openRootDir` returns a dummy tag FD).
**How to avoid:** Phase 48 must replace `openRootDir` with a proper `openDirInode(fs, inum, flags)` that creates an `Ext2DirFd` and uses `ext2_dir_ops`.
**Warning signs:** `getdents("/mnt2")` returns InitRD entries instead of ext2 entries.

### Pitfall 7: Forgetting to Update the VFS FileSystem Struct
**What goes wrong:** New callbacks `ext2Statfs`, `ext2Readlink`, and the `getdents` wiring inside directory FDs are implemented in `inode.zig` but not wired into the `vfs.FileSystem` returned by `mount.zig:init()`. `vfs.statfs("/mnt2")` returns ENOTSUPP.
**Why it happens:** `mount.zig:init()` constructs the `vfs.FileSystem` struct with all fields explicitly listed. Adding new functions without updating this struct leaves them unreachable.
**How to avoid:** Add `statfs = ext2Statfs`, `readlink = ext2Readlink` to the `vfs.FileSystem` initialization in `mount.zig:init()`.

## Code Examples

### Build Step: Populate ext2 Image with Phase 48 Test Content

The Phase 48 success criteria require:
1. `open("/mnt2/a/b/c/file.txt")` to succeed (DIR-01 -- 3-level nesting)
2. `getdents` to list directory entries including the last entry in a block (DIR-02)
3. `readlink` on a fast symlink to return the correct target (DIR-03)

The current `ext2_populate_script` in `build.zig` creates `hello.txt`, `medium.bin`, `large.bin`. Phase 48 adds to this script:

```
# Create nested directory structure: /a/b/c/file.txt
mkdir a
mkdir a/b
mkdir a/b/c
write /tmp/ext2_nested_file.txt a/b/c/file.txt

# Create a fast symlink to hello.txt
symlink /mnt2/hello.txt link_to_hello
```

Using piped debugfs commands (same pattern as Phase 47):
```
printf "mkdir a\nmkdir a/b\nmkdir a/b/c\nwrite /tmp/nested.txt a/b/c/file.txt\nsymlink /mnt2/hello.txt link_to_hello\n" | debugfs -w ext2.img
```

**IMPORTANT**: The stamp file for Phase 48 content additions must be separate from `ext2.img.populated.stamp` to avoid idempotency issues. Use `ext2.img.phase48.stamp` or append the new commands to the existing populate script inside the idempotent block.

The simplest approach: extend the existing `ext2_populate_script` by adding the new debugfs commands inside the same piped block. If `ext2.img.populated.stamp` already exists, the script will skip. To re-run population after adding Phase 48 content, delete the stamp: `rm ext2.img.populated.stamp && zig build`.

### Ext2Fs Struct Extension (mount.zig)

```zig
// Add to Ext2Fs (after existing fields):
inode_cache: [inode_mod.INODE_CACHE_SIZE]inode_mod.InodeCacheEntry,
inode_cache_gen: u64,
```

Initialize in `init()` after `self.* = .{ ... }`:
```zig
// Zero-initialize inode cache (INODE-05)
for (&self.inode_cache) |*slot| {
    slot.inum = 0;
    slot.lru_gen = 0;
    // slot.inode is intentionally left undefined (inum=0 marks it as empty)
}
self.inode_cache_gen = 0;
```

### Test: testExt2GetdentsListsDirectory

```zig
pub fn testExt2GetdentsListsDirectory() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    // Open root directory /mnt2 as a directory FD
    const dir_fd = try syscall.open("/mnt2", 0x10000, 0); // O_RDONLY | O_DIRECTORY
    defer syscall.close(dir_fd) catch {};

    var buf: [4096]u8 = undefined;
    const bytes = try syscall.getdents64(dir_fd, &buf, buf.len);

    // Must list at least one entry (hello.txt)
    if (bytes == 0) return error.TestFailed;

    // Walk entries to verify rec_len stride is correct
    var offset: usize = 0;
    var found_hello = false;
    while (offset < bytes) {
        if (offset + 19 > bytes) break; // minimum Dirent64 header
        const ent: *const syscall.Dirent64 = @ptrCast(@alignCast(buf[offset..].ptr));
        if (ent.d_reclen == 0) break;

        const name_offset = offset + @offsetOf(syscall.Dirent64, "d_name");
        const name_end = std.mem.indexOfScalarPos(u8, &buf, name_offset, 0) orelse (name_offset + 8);
        const name = buf[name_offset..name_end];
        if (std.mem.eql(u8, name, "hello.txt")) found_hello = true;

        offset += ent.d_reclen;
    }

    if (!found_hello) return error.TestFailed;
}
```

### Test: testExt2OpenNestedPath

```zig
pub fn testExt2OpenNestedPath() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    // Phase 48 success criterion 1: open nested path
    const fd = try syscall.open("/mnt2/a/b/c/file.txt", 0, 0);
    defer syscall.close(fd) catch {};

    var buf: [32]u8 = undefined;
    const bytes_read = try syscall.read(fd, &buf, buf.len);
    // file must be non-empty (content written by build step)
    if (bytes_read == 0) return error.TestFailed;
}
```

### Test: testExt2Readlink

```zig
pub fn testExt2Readlink() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    var buf: [256]u8 = undefined;
    const len = try syscall.readlink("/mnt2/link_to_hello", &buf, buf.len);

    // Fast symlink target should be "/mnt2/hello.txt" (15 bytes)
    const expected = "/mnt2/hello.txt";
    if (len != expected.len) return error.TestFailed;
    if (!std.mem.eql(u8, buf[0..len], expected)) return error.TestFailed;
}
```

### Test: testExt2Statfs

```zig
pub fn testExt2Statfs() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    var st = std.mem.zeroes(syscall.Statfs);
    try syscall.statfs("/mnt2", &st);

    // EXT2_SUPER_MAGIC = 0xEF53
    if (st.f_type != 0xEF53) return error.TestFailed;

    // Block size = 4096 (known from image creation)
    if (st.f_bsize != 4096) return error.TestFailed;

    // Free blocks and inodes must be >= 0 and <= total
    if (st.f_bfree < 0 or st.f_bfree > st.f_blocks) return error.TestFailed;
    if (st.f_ffree < 0 or st.f_ffree > st.f_files) return error.TestFailed;
}
```

## State of the Art

| Old Approach | Current Approach | Notes |
|--------------|-----------------|-------|
| Phase 47 `lookupInRootDir` (root only) | Phase 48 `lookupInDir` + `resolvePath` (arbitrary depth) | Factoring required; Phase 47 code becomes a special case |
| Phase 47 `openRootDir` returns dummy `dir_ops` tag FD | Phase 48 opens a real `Ext2DirFd` with `ext2_dir_ops` and `getdents` | Phase 47 explicitly deferred this |
| Phase 47 `statfs = null` in VFS FileSystem | Phase 48 implements `ext2Statfs` | Reads from in-memory `fs.superblock` |
| Phase 47 `readlink = null` | Phase 48 implements `ext2Readlink` (fast path only) | Slow symlinks (ADV-02) deferred |
| Phase 47 direct `readInode` calls | Phase 48 `getCachedInode` wrapping `readInode` | Cache eliminates redundant disk reads during path traversal |

**Deprecated in Phase 48:**
- `lookupInRootDir` as called directly by `ext2Open` -- replaced by `resolvePath` which calls `lookupInDir` iteratively
- `openRootDir` returning `initrd_dir_tag` dummy FD -- replaced by `openDirInode` returning real `Ext2DirFd`

## Open Questions

1. **INODE_CACHE_SIZE: 16 or 32?**
   - What we know: A 3-component path (`a/b/c/file.txt`) reads 4 inodes (root + a + b + c + file = 5 including root). 16 entries handles 16 simultaneously open directory traversals with zero eviction.
   - What's unclear: Whether Phase 49 (block allocation) benefits from a larger cache. For read-only traversal in Phase 48, 16 is more than sufficient.
   - Recommendation: Use 16. It fits in 16 * (4 + 128 + 8) = 2240 bytes of `Ext2Fs`, which is stack-safe. 32 entries doubles this to ~4.5KB -- still acceptable but unnecessary for Phase 48 workloads.

2. **Should resolvePath follow symlinks during traversal?**
   - What we know: POSIX requires that intermediate path components that are symlinks be followed. However, Phase 48's scope says "fast symlink resolution" only for `readlink`, not during path traversal. The success criteria test `readlink` on a symlink, not `open` on a path-through-symlink.
   - What's unclear: Whether any test will call `open("/mnt2/link_to_hello")` and expect it to open the target file.
   - Recommendation: Do NOT follow symlinks in `resolvePath` for Phase 48. Phase 48's `ext2Open` returns `error.NotSupported` (ENOENT or ELOOP) if any component is a symlink. Symlink-following during traversal is a separate feature that Phase 48 does not need to pass its success criteria. The `readlink` syscall works on the symlink inode directly, bypassing traversal.

3. **What should ext2.img.populated.stamp strategy be for Phase 48?**
   - What we know: Phase 47 uses `ext2.img.populated.stamp` to idempotently populate the image. Phase 48 needs additional content (nested dirs, symlink).
   - What's unclear: Whether to use a new `ext2.img.phase48.stamp` or delete and re-run the existing populate script.
   - Recommendation: Add Phase 48 content to the existing populate script body. Delete the old stamp when adding the new debugfs commands. Use a single `ext2.img.populated.stamp` for all content. Document in a comment that deleting the stamp forces re-population.

4. **Does the ext2 directory FD need a separate Spinlock?**
   - What we know: Phase 47's `Ext2File` has no lock (read-only, single-file state). Phase 48's `Ext2DirFd` for getdents uses `file_desc.position` as the directory iteration cursor.
   - What's unclear: Whether multiple threads can call getdents on the same directory FD simultaneously.
   - Recommendation: No separate spinlock needed for Phase 48. The VFS spinlock serializes all ext2 operations. If concurrent getdents on the same FD is ever needed, it can be added later. Match Phase 47's concurrency model exactly.

## Sources

### Primary (HIGH confidence)

- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/ext2/inode.zig` -- Phase 47 implementation: `readInode`, `resolveBlock`, `lookupInRootDir`, `Ext2File`, `ext2_file_ops`, `openInode` -- read directly, verified working
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/ext2/mount.zig` -- `Ext2Fs` struct, `ext2Open`, `ext2StatPath`, `openRootDir` stub, VFS FileSystem struct construction -- read directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/ext2/types.zig` -- `Inode.i_blocks`, `DirEntry` struct (rec_len, name_len, file_type, FT_* constants), `S_IFLNK` -- read directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/vfs.zig` -- `FileSystem` struct with `.getdents`, `.statfs`, `.readlink` callback slots (all null in Phase 47) -- read directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/kernel/fs/fd.zig` -- `FileOps.getdents` signature, `dir_ops` marker, `FileDescriptor.position` field -- read directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/uapi/fs/stat.zig` -- `Statfs` struct (f_type is `i64`, f_spare is `[4]i64`) -- read directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/uapi/fs/dirent.zig` -- `Dirent64` (d_ino u64, d_off i64, d_reclen u16, d_type u8, d_name [0]u8), DT_* constants -- read directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/sfs/ops.zig` -- `sfsGetdents` reference pattern (direct user-space write, position tracking, DT_* mapping), `sfsStatfs` reference pattern -- read directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/kernel/sys/syscall/io/dir.zig` -- `sys_getdents64` dispatch: checks `fd.ops.getdents` first, then falls through to InitRD/DevFS tag dispatch -- read directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/.planning/phases/47-inode-read-indirect-block-resolution/47-01-SUMMARY.md` -- Phase 47 deliverables: what was implemented, what was deferred (getdents, statfs, readlink all explicitly deferred to Phase 48)
- ext2 spec section on directory structure: https://www.nongnu.org/ext2-doc/ext2.html -- rec_len is the stride, last entry in block uses padded rec_len; fast symlinks use i_block[] as char buffer when i_blocks==0 and i_size<=60

### Secondary (MEDIUM confidence)

- `/Users/whit3rabbit/Documents/GitHub/zigk/.planning/STATE.md` -- "Phase 48 combines inode cache with directory traversal"; ext2 at /mnt2; aarch64 ext2 LUN absent (ext2Available() guard applies to all new tests)
- MEMORY.md: "Large Struct Return-by-Value = Stack Overflow on aarch64" -- confirms heap allocation required for 4KB directory block buffers in `ext2GetdentsFromFd`
- CLAUDE.md security rules: DMA hygiene, checked arithmetic, zero-init -- apply to all new buffer reads

### Tertiary (LOW confidence)

- Assumption that debugfs supports `mkdir` with nested paths (`mkdir a/b`) -- this needs verification during build step development. If debugfs requires creating each level separately (`mkdir a; mkdir a/b; mkdir a/b/c`), the populate script must be written accordingly. Phase 47 SUMMARY documents that debugfs piped input works correctly for `write` and basic `mkdir` on macOS Homebrew 1.47.x.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all components verified by reading existing files; no new external libraries required
- Architecture patterns: HIGH -- lookupInDir, resolvePath, getdents, readlink, statfs all have working reference implementations (SFS, InitRD) in the codebase; ext2 specifics (rec_len stride, fast symlink) are well-specified by the ext2 standard
- Pitfalls: HIGH -- rec_len stride bug and openRootDir/dir_ops tag issue are the two non-obvious traps; both identified by code inspection of Phase 47 implementation
- Open questions: MEDIUM -- symlink-follow-during-traversal and cache size are planning decisions, not research gaps; recommendation provided

**Research date:** 2026-02-23
**Valid until:** 2026-03-23 (stable internal codebase; invalidated by Phase 47 changes to Ext2Fs or VFS restructuring, neither of which is planned)
