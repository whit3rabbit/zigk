# Pitfalls Research

**Domain:** ext2 filesystem implementation in an existing Zig microkernel (zk)
**Researched:** 2026-02-22
**Confidence:** HIGH (based on direct codebase analysis + ext2 specification knowledge)

---

## Context: What the Existing Code Looks Like

Before reading the pitfalls, understand these fixed points in the current design:

- SFS uses 512-byte "sectors" as its block unit; `readSector`/`writeSector` in `sfs/io.zig` operate on exactly 512 bytes. ext2 uses 1024, 2048, or 4096-byte logical blocks that map to multiple 512-byte sectors.
- The VFS `open()` callback receives a **relative path with leading slash** -- for a mount at `/mnt`, the path `/mnt/foo/bar` becomes `/foo/bar`. ext2 must parse this starting from the root inode (inode 2), not search for a string `"/foo/bar"`.
- SFS allocates files contiguously from `start_block`. ext2 inode block pointers (`i_block[0..14]`) are not contiguous and require translation through direct/indirect tables for every block access.
- The kernel has documented lock ordering (CLAUDE.md): `alloc_lock` (2) before `io_lock` (2.5). SFS fixed a close deadlock in v1.1 by restructuring bitmap I/O outside the allocation lock. ext2 has the same vulnerability with more places where I/O can nest inside allocation locks.
- The page cache uses `FileDescriptor.file_identifier` as its cache key. SFS computes this as a pointer-based hash. ext2 must use a stable identifier -- inode numbers are the right choice.
- `initBlockFs()` in `init_fs.zig` opens `/dev/sda` to mount SFS. There is currently no build step that produces a pre-formatted ext2 image or adds a second drive to the QEMU invocation for ext2 testing.

---

## Critical Pitfalls

### Pitfall 1: Locking Deadlock From Block I/O Called Inside an Allocation Lock

**What goes wrong:**
ext2 block and inode allocation read bitmaps and group descriptors from disk. If these disk reads happen while the allocation lock is held, and the disk I/O path internally acquires `io_lock`, the kernel deadlocks. This is the exact bug SFS suffered before the v1.1 fix (`sfs/alloc.zig` restructuring: bitmap scan under lock, I/O outside lock).

ext2 has more allocation touchpoints than SFS:
- Block allocation reads the block bitmap, then writes it, then writes the group descriptor, then writes the superblock
- Inode allocation reads the inode bitmap, then writes it, then writes the group descriptor, then initializes the inode block
- Any of these disk reads nested inside a held allocation lock re-creates the deadlock

**Why it happens:**
The natural implementation reads the bitmap inside the allocation function, which is called inside an allocation lock. SFS started with the same pattern and deadlocked after ~50 operations. ext2 has a more complex allocation path with more I/O sites.

**How to avoid:**
Follow the two-phase pattern from `sfs/alloc.zig`:
1. Under `alloc_lock`: scan in-memory bitmap cache, mark the bit, record the LBA to write
2. Release `alloc_lock`
3. Write dirty bitmap sector to disk (this internally uses `io_lock`)
4. Write group descriptor update to disk
5. Write superblock update to disk
6. Re-acquire `alloc_lock` only to update in-memory counters on rollback

Define a lock hierarchy for ext2 and document it in the struct definition:
```
ext2.alloc_lock      (position 2.0 -- bitmap and inode allocation)
ext2.group_lock      (position 2.25 -- group descriptor updates, acquired under alloc_lock)
ext2.inode_lock      (position 2.5 -- per-inode metadata, replaces SFS io_lock role)
```
Never hold a higher-numbered lock while acquiring a lower-numbered one.

**Warning signs:**
- QEMU hangs with no kernel panic after creating several files in ext2
- The test runner reaches the 90-second timeout instead of a test failure message
- `console.info("ext2: allocating block...")` appears but the completion log never follows

**Phase to address:** Block device abstraction and ext2 allocation (Phase 1).

---

### Pitfall 2: Using ext2 Block Number as a 512-Byte LBA Causes Silent Data Corruption

**What goes wrong:**
ext2 block numbers are logical block numbers, not 512-byte sector numbers. For a 1024-byte ext2 block, logical block 1 is at byte offset 1024 = LBA 2. For 4096-byte blocks, logical block 1 is at byte offset 4096 = LBA 8. Passing an ext2 block number directly to `readSector(lba)` reads from the wrong disk location. The superblock is always at byte 1024 (not at LBA 1) -- this is the first thing to break.

**Why it happens:**
SFS conflates "block" with "512-byte sector". The entire SFS I/O layer passes sector numbers. ext2 has a `s_log_block_size` field in the superblock: `block_size = 1024 << s_log_block_size`. An implementation that copies the SFS pattern and passes ext2 block numbers to `readSector` has a factor-of-`sectors_per_block` error in every disk access.

**How to avoid:**
Create a block conversion function used by all ext2 I/O:
```zig
fn ext2BlockToLba(block_num: u32, block_size: u32) u64 {
    const sectors_per_block = block_size / 512;  // 2 for 1KB, 8 for 4KB
    return @as(u64, block_num) * sectors_per_block;
}
```
Standardize on 4096-byte blocks for all ext2 images created with `mkfs.ext2`. This simplifies the conversion to `lba = block_num * 8`. Validate `s_log_block_size` on mount and refuse to mount if block_size > 4096 or < 1024.

**Warning signs:**
- Superblock magic check (`0xEF53`) fails even on a correctly formatted image
- Reading the root inode (inode 2) returns a struct with `i_mode = 0` or garbage type bits
- `statfs` reports `total_blocks` equal to `disk_sectors / block_size` but the value is off by the `sectors_per_block` factor

**Phase to address:** ext2 superblock parsing and block I/O layer (Phase 1).

---

### Pitfall 3: Inode Number Off-by-One Corrupts All Inode Table Accesses

**What goes wrong:**
ext2 inode numbers are 1-based (root directory = inode 2; the first allocatable inode is 11 by convention for rev1 filesystems). If the implementation treats inode numbers as 0-based when computing the inode table offset, every single inode access is off by one entry, reading the wrong inode for every operation.

**Why it happens:**
Zig arrays are 0-indexed. The natural implementation:
```zig
const inode_idx = inode_num;  // WRONG: inode 2 -> index 2 (third entry, not second)
```
The correct formula:
```zig
const local_inode_idx = (inode_num - 1) % inodes_per_group;
```
The off-by-one is subtle because inode 2 (root) read at index 2 instead of index 1 may happen to contain valid-looking data in a freshly formatted small filesystem, causing the bug to pass initial tests and only manifest with larger directory trees or specific inode layouts.

**How to avoid:**
Always subtract 1 when converting inode number to table index:
```zig
fn inodeTableIndex(inode_num: u32, inodes_per_group: u32) u32 {
    // inode_num is 1-based; table is 0-indexed
    return (inode_num - 1) % inodes_per_group;
}
```
Add a comptime assertion or runtime panic in debug builds: `if (inode_num == 0) @panic("ext2: inode 0 is reserved and invalid")`.

**Warning signs:**
- Root directory (`/mnt`) always returns ENOENT on a freshly formatted image
- `readdir` returns entries but the inode numbers in each `dirent` do not match the expected file
- `stat` on a regular file returns `st_mode` with directory bits set

**Phase to address:** Inode read/write implementation (Phase 2).

---

### Pitfall 4: Directory Entry Scan Uses name_len Instead of rec_len as Stride

**What goes wrong:**
ext2 directory entries have variable length. The `rec_len` field of each entry is the actual offset to the next entry. The last entry in a block has `rec_len` set to fill the remaining space to end-of-block. If the implementation uses `name_len` rounded up to 4 bytes as the stride instead of `rec_len`, it desynchronizes from the directory layout and misreads all subsequent entries.

**Why it happens:**
The minimum size of a directory entry is `8 + name_len` bytes rounded to a 4-byte boundary. This equals `rec_len` for all entries except the last, where the last entry's `rec_len` covers all unused space to end-of-block. A naive implementation computes stride as `(8 + name_len + 3) & ~3` which equals `rec_len` for all entries except the last one, causing it to walk off into unused space at the end of the block.

**How to avoid:**
Always use `rec_len` as the stride, never compute stride from `name_len`:
```zig
var offset: usize = 0;
while (offset + 8 <= block_size) {
    const entry = parseEntry(block_data[offset..]);
    if (entry.rec_len < 8 or entry.rec_len % 4 != 0 or offset + entry.rec_len > block_size) {
        // Corrupt directory block
        return error.IOError;
    }
    if (entry.inode != 0) {
        // Valid entry -- process it
    }
    offset += entry.rec_len;  // NOT: (8 + entry.name_len + 3) & ~3
}
```

**Warning signs:**
- `getdents64` returns an incomplete file list from a directory
- The last file alphabetically in a directory block is always missing
- Directory iteration loops indefinitely (offset wraps around inside the block)

**Phase to address:** Directory entry iteration and `getdents` implementation (Phase 3).

---

### Pitfall 5: Indirect Block Chain Not Fully Implemented Causes Silent Truncation

**What goes wrong:**
ext2 inodes have 12 direct block pointers (`i_block[0..11]`), one single-indirect (`i_block[12]`), one double-indirect (`i_block[13]`), and one triple-indirect (`i_block[14]`). An implementation that handles only direct and single-indirect blocks silently truncates reads and writes for files larger than `(12 + block_size/4) * block_size` bytes. For 4096-byte blocks this is `(12 + 1024) * 4096 = 4,243,456` bytes (~4MB). For 1024-byte blocks it is only `(12 + 256) * 1024 = 274,432` bytes (~268KB). Tests with small files pass; large file tests silently return short reads.

**Why it happens:**
Single-indirect support is enough to pass a majority of unit tests with small files. Double and triple indirect blocks are easy to defer. The failure is silent: a 10MB file write succeeds (the write loop returns the correct count) but subsequent reads stop at the single-indirect boundary with no error.

**How to avoid:**
Implement all four indirection levels before writing any I/O test. Structure the block resolution as a single function covering all levels:
```zig
fn getBlockForLogicalIndex(inode: *Ext2Inode, block_idx: u32, fs: *Ext2Fs) !u32 {
    const ptrs_per_block = fs.block_size / 4;
    if (block_idx < 12) return inode.i_block[block_idx];
    const idx = block_idx - 12;
    if (idx < ptrs_per_block) return resolveIndirect(inode.i_block[12], idx, fs);
    // double indirect
    const idx2 = idx - ptrs_per_block;
    if (idx2 < ptrs_per_block * ptrs_per_block) return resolveDoubleIndirect(...);
    // triple indirect
    return resolveTripleIndirect(...);
}
```

**Warning signs:**
- Write of 5MB succeeds, subsequent read returns only 4MB with no error
- `stat` shows `st_size` = 5MB but `read()` loop terminates early
- Large file stress test hangs or returns ENOSPC at a suspiciously round size

**Phase to address:** ext2 file I/O with block mapping (Phase 2 or 3).

---

### Pitfall 6: Bitmap Written Without Flushing Group Descriptor Creates Filesystem Inconsistency

**What goes wrong:**
After allocating a block or inode, three structures must be updated on disk in order: (1) the bitmap, (2) the group descriptor (`bg_free_blocks_count` or `bg_free_inodes_count`), and (3) the superblock (`s_free_blocks_count`). Skipping step 2 leaves the bitmap and superblock in agreement but the group descriptor wrong. After QEMU restart, `e2fsck` reports "Group descriptor X has bad block count" and either refuses to mount or repairs by recomputing from the bitmap -- overwriting the "correct" count with something that may disagree.

**Why it happens:**
SFS has no group descriptors. The SFS pattern is: write bitmap, write superblock. ext2 requires the intermediate group descriptor write. The group descriptor step is the most commonly skipped because it is easy to forget it exists.

**How to avoid:**
After every bitmap modification, write three sectors in order:
1. Block or inode bitmap (marks the allocation)
2. Group descriptor sector (updates free count for the block group)
3. Superblock sector (updates global free count and `s_wtime`)

Make the three-step flush a single function that cannot be called partially. Do not make step 2 optional or "optimize" it away.

**Warning signs:**
- Running `e2fsck` on the QEMU disk image after a test run reports errors in group descriptors
- After kernel restart (new QEMU session), `statfs` shows different free block count than during the previous session
- `df` inside the kernel shows wrong available space after many file creates and deletes

**Phase to address:** Block and inode allocation (Phase 2).

---

### Pitfall 7: VFS Relative Path Parsing Logic Does Not Handle Multi-Level Paths Correctly

**What goes wrong:**
The VFS `open()` strips the mount prefix and passes a leading-slash relative path to the filesystem callback (e.g., `/mnt/foo/bar` becomes `/foo/bar`). An ext2 implementation that splits this on `/` must handle the empty component from the leading slash correctly. If the split logic includes an empty leading component and starts searching from inode 2 for a file named `""`, the first lookup fails and the entire path resolution returns ENOENT.

**Why it happens:**
`std.mem.split(u8, "/foo/bar", "/")` produces `["", "foo", "bar"]`. The first component is an empty string. An implementation that calls `lookupName(current_dir_inode, "")` will not find `""` in the directory entries and returns ENOENT. The simple fix (skip empty components) must also correctly handle `/` (root), `//`, and paths with trailing slashes.

**How to avoid:**
Use a tokenizer that skips empty components:
```zig
var it = std.mem.tokenizeScalar(u8, rel_path, '/');
var current_inode: u32 = ROOT_INODE;  // inode 2
while (it.next()) |component| {
    if (component.len == 0) continue;
    current_inode = try lookupDirEntry(current_inode, component, fs);
}
```
Test the VFS integration with: root open (`/`), one level (`/file`), two levels (`/dir/file`), three levels (`/a/b/c`), and paths with trailing slashes (`/dir/`).

**Warning signs:**
- Opening `/mnt` (the mount point itself) succeeds but opening any path under `/mnt` returns ENOENT
- Files at the top level of the ext2 root directory cannot be found, but `getdents` lists them
- Paths with exactly two levels work; paths with three or more levels always fail

**Phase to address:** ext2 path resolution and directory lookup (Phase 3).

---

### Pitfall 8: FileDescriptor.position Cannot Substitute for ext2 Block Offset Resolution

**What goes wrong:**
SFS reads file data as `phys_sector = start_block + (file_desc.position / 512)`. This works because SFS allocates files contiguously. ext2 does not guarantee contiguous block allocation. Using `file_desc.position / block_size` as a direct inode block index is correct only when the file has never been written out of order and the filesystem has never been fragmented. After any file deletion and re-use of freed blocks, block allocation is non-contiguous and this calculation returns the wrong physical block.

**Why it happens:**
The SFS pattern is deeply ingrained. If `sfsRead` is copied as a starting point for `ext2Read`, the `start_block + offset/512` line is the first thing to copy and the last thing to audit. The bug is invisible for freshly formatted images where files are created in order.

**How to avoid:**
ext2 read/write must call `getBlockForLogicalIndex(inode, position / block_size, fs)` for every block access. There is no shortcut. The inode's `i_block[15]` array is the only valid source of block numbers:
```zig
const block_idx: u32 = @intCast(file_desc.position / fs.block_size);
const phys_block = try getBlockForLogicalIndex(inode, block_idx, fs);
const lba = ext2BlockToLba(phys_block, fs.block_size);
try readBlock(fs, lba, sector_buf[0..fs.block_size]);
```

**Warning signs:**
- Read/write works on freshly created files but fails after delete + recreate on the same filesystem
- Data read from a fragmented file contains blocks from previously deleted files
- Writes to a file that was truncated then extended return garbage in the re-extended region

**Phase to address:** ext2 file I/O (Phase 3).

---

### Pitfall 9: Page Cache file_identifier Collision With SFS or Between ext2 Files

**What goes wrong:**
The page cache uses `FileDescriptor.file_identifier` to key cached pages. The VFS assigns this as `(mount_idx << 32) | (ptr & 0xFFFFFFFF)` where `ptr` is the lower 32 bits of the `private_data` pointer. If ext2 uses the same pointer-based scheme, and the heap allocator reuses a pointer that was previously associated with a different file, the page cache returns stale data from the old file for the new file's reads.

**Why it happens:**
The current VFS code in `vfs.zig:269-273` computes `file_identifier` from the private_data pointer for all filesystems. SFS works with this because SFS files are long-lived objects tied to fixed disk positions. ext2 files may be opened and closed repeatedly, with `private_data` pointers being reused by the heap allocator. Two different ext2 files at different times could get the same `file_identifier` if they share a recycled pointer.

**How to avoid:**
ext2 must override `file_identifier` after the VFS assigns it, using the stable inode number:
```zig
// After VFS.open() returns the FileDescriptor:
file_desc.file_identifier = (@as(u64, file_desc.vfs_mount_idx) << 32) | @as(u64, inode_num);
```
Inode numbers are unique and stable within a mounted filesystem, making this collision-free as long as the mount point is consistent.

**Warning signs:**
- `splice` or `sendfile` between two ext2 files returns data from the wrong file
- After deleting a file and creating a new one with the same name, reads of the new file return data from the old file
- Page cache hit rate is unexpectedly high for newly created files (hitting old entries)

**Phase to address:** ext2 VFS integration and file open path (Phase 3).

---

### Pitfall 10: QEMU Disk Image Setup Is Missing -- All ext2 Tests Silently Return ENOENT

**What goes wrong:**
`initBlockFs()` fails silently if `/dev/sda` does not contain a valid ext2 filesystem -- it logs a warning and returns without mounting `/mnt`. If the QEMU invocation for ext2 testing does not include a pre-formatted ext2 image as a drive, the kernel runs without `/mnt` mounted and every ext2 integration test returns ENOENT. This looks like ext2 implementation bugs rather than a missing disk image, causing significant debugging confusion.

**Why it happens:**
The current build system creates `disk.img` only for the UEFI ESP boot partition. There is no build step to create an ext2 data partition image or add a second drive to the QEMU command. The `mkfs.ext2` tool is also not available by default on macOS -- it requires Homebrew `e2fsprogs`.

**How to avoid:**
Add a host-side build step in `build.zig` that creates a pre-formatted ext2 image:
```bash
# Requires: brew install e2fsprogs
dd if=/dev/zero of=ext2_data.img bs=1M count=64
/opt/homebrew/opt/e2fsprogs/bin/mkfs.ext2 -b 4096 -L "zk-data" ext2_data.img
```
Add this image to the QEMU invocation as a second drive:
```
-drive if=none,format=raw,id=ext2disk,file=ext2_data.img
-device virtio-blk-pci,drive=ext2disk
```
This appears as `/dev/sdb` (AHCI port 1) or the VirtIO block device. Update `initBlockFs()` to try both `/dev/sda` and `/dev/sdb`, or make the device path configurable. Add a check in the build step that fails with a clear message if `mkfs.ext2` is not found rather than producing an unformatted image.

**Warning signs:**
- All ext2 integration tests return ENOENT with no other error
- The kernel boot log shows `"SFS: Failed to initialize on /dev/sda"` but no ext2 init messages
- `statfs("/mnt")` returns ENOENT

**Phase to address:** Build system and QEMU disk image setup (Phase 1, prerequisite to all other phases).

---

## Moderate Pitfalls

### Pitfall 11: aarch64 Struct Alignment Faults on Packed ext2 On-Disk Structures

**What goes wrong:**
ext2 on-disk structures contain u16 fields at byte offsets that are not 4-byte aligned (e.g., `bg_free_blocks_count` in the group descriptor is at offset 12, which is 4-byte aligned, but other fields like `bg_used_dirs_count` at offset 16 and various u16 fields in directory entries are packed without natural alignment). On aarch64, accessing a u32 at a non-4-byte-aligned virtual address causes an alignment fault (`DataAlignmentFault`) that the x86_64 hardware handles transparently.

**Why it happens:**
The project already has a documented instance of this: `socklen_t` reads as `u32` instead of `usize` after the kernel read 8 bytes from a 4-byte stack variable on aarch64. ext2 on-disk structures have the same property: they are defined by the spec with specific byte offsets, not by Zig's natural alignment rules. Using `extern struct` with `@sizeOf` assertions is the correct pattern (matching CLAUDE.md's `extern struct` for hardware structures rule), but it is easy to miss individual fields.

**How to avoid:**
Use `extern struct` for all ext2 on-disk types and add comptime size assertions for each:
```zig
pub const Ext2Superblock = extern struct {
    s_inodes_count: u32,
    s_blocks_count: u32,
    // ... all 204 bytes
};
comptime { std.debug.assert(@sizeOf(Ext2Superblock) == 1024); }

pub const Ext2GroupDesc = extern struct {
    bg_block_bitmap: u32,
    bg_inode_bitmap: u32,
    bg_inode_table: u32,
    bg_free_blocks_count: u16,
    bg_free_inodes_count: u16,
    bg_used_dirs_count: u16,
    bg_pad: u16,
    bg_reserved: [3]u32,
};
comptime { std.debug.assert(@sizeOf(Ext2GroupDesc) == 32); }
```
For directory entries with variable-length `name` fields, use `std.mem.readInt(u16, entry_bytes[6..8], .little)` for `rec_len` rather than struct field access to avoid alignment issues at arbitrary offsets within a directory block.

**Warning signs:**
- Tests pass on x86_64 but produce `DataAlignmentFault` or wrong field values on aarch64
- Superblock magic check passes on x86_64 but fails on aarch64 on the same image
- Group descriptor free block count is 0 on aarch64 but correct on x86_64

**Phase to address:** ext2 on-disk type definitions (Phase 1).

---

### Pitfall 12: inode.i_size_high Is Ignored, Causing Wrong st_size for Rev1 Filesystems

**What goes wrong:**
`mkfs.ext2` creates rev1 filesystems by default. In rev1, the `i_dir_acl` field in the inode is repurposed as `i_size_high` for regular files -- the upper 32 bits of a 64-bit file size. An implementation that reads only `i_size` (the lower 32 bits) correctly reports file sizes up to 4GB but silently returns wrong sizes for files that have `i_size_high != 0`, and also misinterprets the field for directories (where `i_dir_acl` retains its original meaning).

**Why it happens:**
Most ext2 documentation focuses on rev0 where `i_size` is the only size field. The rev1 extension is a footnote. Since test files are small, `i_size_high` is always 0 and the bug is invisible. However, the rev1 flag must still be checked because the field interpretation depends on it.

**How to avoid:**
On mount, read `s_rev_level` from the superblock. Store it in the ext2 mount instance. When computing file size:
```zig
fn getInodeSize(inode: *Ext2Inode, rev: u32) u64 {
    const lower: u64 = inode.i_size;
    if (rev >= 1 and isRegularFile(inode.i_mode)) {
        return ((@as(u64, inode.i_dir_acl) << 32) | lower);
    }
    return lower;
}
```
`mkfs.ext2` on modern Linux creates `s_rev_level = 1` with `s_first_ino = 11`. The test image will be rev1.

**Warning signs:**
- `stat` returns `st_size = 0` even for files the kernel just wrote with verified content
- Large file write returns correct byte count but `fstat` shows wrong `st_size`
- `s_rev_level` from the superblock is 1 but the code path for rev0 is used

**Phase to address:** Inode structure definition and size computation (Phase 2).

---

### Pitfall 13: Parent Directory mtime/ctime Not Updated After File Create or Delete

**What goes wrong:**
When a file is created or deleted inside a directory, the parent directory inode's `i_mtime` (modification time) and `i_ctime` (change time) must be updated and written back to disk. SFS stores mtime only in the `DirEntry` for the file itself, not on the directory. ext2 directory inodes have their own full inode with timestamps. Skipping the parent inode timestamp update causes `stat` on the directory to show stale timestamps, breaking tests that check directory mtime after file operations and breaking the existing inotify hooks that read mtime.

**Why it happens:**
SFS has no directory inode concept -- directories are flat tables. Copying the SFS pattern for ext2 means implementing file inode updates but forgetting that the parent directory is also an inode that needs updating. This is invisible until a test explicitly checks the parent directory's mtime.

**How to avoid:**
After writing a directory entry (create or delete marker), immediately read the parent directory's inode, update `i_mtime = current_time`, `i_ctime = current_time`, and write it back to disk. Factor this into a helper called from every directory-modifying operation: `create`, `unlink`, `rename`, `mkdir`, `rmdir`.

**Warning signs:**
- `stat` on a directory shows `st_mtime` unchanged after creating a file inside it
- inotify tests that watch a directory for IN_CREATE see the event but subsequent stat shows old mtime
- `ls -la` on the directory always shows the same timestamp regardless of file creates/deletes

**Phase to address:** Directory modification operations (Phase 3).

---

### Pitfall 14: Newly Allocated Blocks Not Zeroed Before User Data Is Written

**What goes wrong:**
When ext2 allocates a new block for a file or directory, the physical disk sectors at that location may contain data from a previously deleted file. If the implementation writes user data into the new block starting at offset 0 but does not zero the rest of the block, the unwritten portion of the last block leaks data from deleted files to the new file owner.

For directory blocks, the uninitialized portion will contain garbage `rec_len` values that cause the directory scanner to walk off into garbage data.

**Why it happens:**
SFS sequential allocation starts fresh data at the end of the allocated region so prior content is only accessible before the file's `size` and is bounded by the read path. ext2 block allocation can return any free block, including one from a recently deleted large file.

**How to avoid:**
CLAUDE.md rule: "Zero-initialize destination buffers before initiating DMA or hardware reads." Extend this to block allocation: `@memset(block_buf, 0)` before writing any new block, including directory blocks. The DMA hygiene principle applies here.

**Warning signs:**
- `getdents64` on a newly created directory returns garbage entries after the `.` and `..` entries
- Files read beyond their EOF position return non-zero bytes
- `e2fsck` reports "directory entry has non-zero name_len but inode 0" in newly created directories

**Phase to address:** Block allocation and initial block write (Phase 2).

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Only direct + single-indirect blocks | Simpler initial code, passes small-file tests | Silent truncation for files > 4MB; must fix before large-file tests | Only if explicitly tracked and deferred |
| Skip group descriptor flush | Fewer I/O operations | `e2fsck` errors after restart; bitmap/descriptor inconsistency | Never -- corrupts on-disk state |
| Read `i_size` (32-bit) only, ignore `i_size_high` | Simpler inode code | Wrong `st_size` for files > 4GB; rev1 filesystem may behave incorrectly | Only if rev0 image explicitly forced |
| Hardcode 4096-byte block size | No block-size conversion code needed | Cannot mount ext2 images with 1024-byte blocks | Acceptable for v2.0 if documented in mount error message |
| Pointer-based `file_identifier` (copied from SFS) | No change to VFS integration | Stale page cache hits after pointer reuse | Never -- inode number is the correct key |
| In-memory inode cache with no eviction | Faster repeated lookups | Memory grows unbounded; kernel heap exhausted in long test runs | Acceptable for v2.0 only if bounded by a fixed array size |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| VFS `open` callback | Treating `rel_path` as already-stripped mount prefix when it still has a leading `/` | VFS strips mount prefix but preserves leading slash; parse `/foo/bar` starting from root inode 2 |
| VFS `getdents` callback | Using `file_desc.position` as a directory block offset directly | Store block index and intra-block offset in ext2 private_data; `position` is a byte offset into the logical directory stream |
| VFS `stat_path` callback | Returning `FileMeta.ino = 0` | Set `ino = inode_num`; the field exists in `FileMeta` for TOCTOU detection |
| page cache `file_identifier` | Inheriting the SFS pointer-based ID | Override after VFS assigns it: `(mount_idx << 32) | inode_num` |
| SFS I/O pattern | Calling `readBlock` inside an allocation lock | Two-phase pattern: compute LBA under lock, do I/O outside lock |
| `initBlockFs()` device path | Hardcoding `/dev/sda` for ext2 | Use `/dev/sdb` if ext2 is a second drive, or make device path configurable via build option |
| `FileOps.truncate` | Not zeroing extended blocks on `ftruncate` growth | Zero-fill all newly allocated blocks; prevents data leak from freed blocks |
| inotify hooks | Calling `vfs_event_hook` inside a filesystem lock | The VFS calls hooks after filesystem operations return; do not call from inside ext2 functions |
| `FileOps.getdents` | Storing directory scan state only in `file_desc.position` | ext2 directory iteration requires both a block index and an intra-block offset; use private_data for state |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| One `readSector` call per 512-byte chunk of a block | Extremely slow directory traversal and inode reads | Batch reads using `readSectorsAsync` for multi-sector blocks; `sectors_per_block` reads at once | Immediately visible in stress tests (100 files) |
| Re-reading group descriptor from disk for every alloc | Allocation collapse under create-heavy workload | Cache all group descriptors in memory in a fixed array at mount time | Any test creating > 10 files |
| No in-memory inode cache | Each `stat` or `open` requires 2-3 disk reads | Cache a bounded set of recently used inodes by inode number | Stress tests with 100 files |
| Byte-by-byte copy in directory entry scan | `getdents` is slow for directories with many entries | Read full directory block into a heap buffer, scan in memory | Directories with > 20 entries |
| Writing group descriptor + superblock on every write call | Write throughput collapses for small sequential writes | Defer group descriptor / superblock flush to explicit `fsync` or periodic writeback | Write-heavy benchmarks |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Trusting `s_blocks_count` from disk without bounds checking | Malicious image causes OOB block reads; arbitrary kernel memory read | Validate: `s_blocks_count <= device_capacity_in_blocks`; panic or ENODEV if not |
| Trusting `rec_len` in directory entries without bounds check | Crafted image causes infinite loop or OOB read in directory scan | Require `rec_len >= 8`, `rec_len % 4 == 0`, and `offset + rec_len <= block_size` |
| Trusting inode `i_block` pointers without range check | Indirect block pointer outside filesystem reads arbitrary disk sectors | After resolving each block pointer, verify `0 < block_num < s_blocks_count` |
| Not zeroing newly allocated blocks | Data from previously freed files leaks to new file owner | `@memset(block_buf, 0)` before writing new block; matches CLAUDE.md DMA hygiene rule |
| Not validating `i_mode` file type before operations | Directory inode opened as regular file; type confusion exploits | Check `i_mode & S_IFMT` matches expected type at the start of every `open` |
| Path component traversal via `..` | Access to parent directory outside mount point | Validate each path component is not `..`; or implement POSIX `..` resolution bounded to mount root |

---

## "Looks Done But Isn't" Checklist

- [ ] **Block number conversion**: `LBA = block_num * (block_size / 512)`, not `block_num` directly -- verify by reading the ext2 superblock at LBA 2 (byte offset 1024)
- [ ] **Inode 1-based indexing**: All table offset calculations use `inode_num - 1` -- verify root directory (inode 2) resolves to the correct inode table entry
- [ ] **Block allocation flush order**: Superblock AND group descriptor BOTH written after every alloc/free -- verify with `e2fsck` after a test run
- [ ] **Indirect blocks**: All three levels (single/double/triple) implemented -- verify with a file larger than 1MB
- [ ] **Directory entry stride**: `rec_len` used as stride (not computed from `name_len`) -- verify with `hexdump` showing last entry fills block
- [ ] **64-bit file size**: `i_size_high` combined with `i_size` for regular files on rev1 -- verify `stat` returns correct `st_size` for files the kernel just wrote
- [ ] **Parent directory timestamps**: `i_mtime` updated on parent dir inode after create/delete -- verify `stat` on the directory shows updated mtime
- [ ] **aarch64 alignment**: All struct fields verified with comptime size assertions -- verify by running full test suite on aarch64 with no `DataAlignmentFault`
- [ ] **Page cache file_identifier**: Uses inode number not pointer -- verify delete + recreate same-named file shows no stale page cache hits
- [ ] **QEMU disk image in build**: `mkfs.ext2` step in `build.zig` and second drive in QEMU args -- verify kernel log shows successful ext2 mount
- [ ] **Newly allocated blocks zeroed**: New file and directory blocks start as all zeros -- verify freshly created directory has no garbage entries after `.` and `..`

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Deadlock from wrong lock ordering | MEDIUM | Restructure allocation into two phases (compute under lock, I/O outside); pattern is established in `sfs/alloc.zig` |
| Block size mismatch discovered after implementation | HIGH | Add `sectors_per_block` multiplier to every LBA computation; requires auditing all I/O call sites in ext2 |
| Inode off-by-one discovered after implementation | MEDIUM | Add `-1` to all inode table index computations; ~5-10 sites; comptime assert catches it early |
| Directory stride wrong | LOW | Single function change in `getdents` iterator |
| Bitmap without group descriptor flush | MEDIUM | Add group descriptor write after every bitmap write; 2-4 new write sites |
| Missing QEMU disk image | LOW | Add `mkfs.ext2` build step, update QEMU args; one-time change |
| Stale page cache from pointer-based ID | MEDIUM | Override `file_identifier` in ext2 `open` path; one function change |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Lock ordering deadlock | Phase 1: Block abstraction layer | No QEMU hangs under file-create stress; lock ordering documented in ext2 struct definition |
| Block size mismatch | Phase 1: Superblock parsing | `e2fsck` on image after test run reports zero errors; LBA of superblock is 2 (not 1) |
| Inode off-by-one | Phase 2: Inode read/write | Root directory (inode 2) resolves correctly; `stat /mnt` succeeds |
| Directory rec_len stride | Phase 3: Directory lookup | `getdents` returns all files; last file in a block is visible |
| Indirect blocks incomplete | Phase 2/3: File I/O | 2MB write/read round-trip passes; large-file stress test passes |
| Bitmap without group desc flush | Phase 2: Allocation | `e2fsck` after test run reports zero errors; remount shows correct free count |
| VFS relative path parsing | Phase 3: VFS integration | Three-level nested path resolves correctly; root open works |
| file_desc.position vs block mapping | Phase 3: File I/O | Fragmented file read-after-write succeeds; `lseek` + partial read is correct |
| Page cache ID collision | Phase 3: VFS integration | Delete + recreate file; no stale cache hits |
| Missing QEMU disk image | Phase 1: Build system | QEMU boot log shows ext2 mount success; kernel log has no ENOENT for `/dev/sda` |
| aarch64 struct alignment | Phase 1: Type definitions | All tests pass on aarch64; no `DataAlignmentFault` |
| i_size_high | Phase 2: Inode types | `stat` on written file returns correct size; rev1 flag checked on mount |
| Parent dir timestamp update | Phase 3: Directory modification | `stat` on parent dir after file create shows updated mtime |
| Newly allocated block not zeroed | Phase 2: Block allocation | New file read contains no garbage data from prior filesystem content |

---

## Sources

- Direct codebase analysis: `src/fs/sfs/` (all files), `src/fs/vfs.zig`, `src/kernel/fs/fd.zig`, `src/kernel/fs/page_cache.zig`, `src/drivers/storage/ahci/root.zig`, `src/kernel/core/init_fs.zig`
- Existing locking fix: SFS close deadlock resolution documented in `PROJECT.md` (v1.1) and `MEMORY.md`
- Kernel memory file: `MEMORY.md` -- SFS Close Deadlock, socklen_t aarch64 alignment bug patterns
- CLAUDE.md: Lock ordering table, security standards (DMA hygiene, integer safety), SFS filesystem layout
- ext2 specification: "The Second Extended Filesystem" (rev0 and rev1 on-disk format)
- Linux kernel source: `fs/ext2/` (inode.c, dir.c, balloc.c, ialloc.c) for reference implementation patterns

---
*Pitfalls research for: ext2 filesystem implementation in zk microkernel*
*Researched: 2026-02-22*
