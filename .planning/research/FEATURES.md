# Feature Research

**Domain:** ext2 Filesystem Implementation -- Microkernel (zk)
**Researched:** 2026-02-22
**Confidence:** HIGH (ext2 is a stable, fully-specified format; OSDev Wiki + Linux kernel docs + e2fsprogs source are authoritative)

## Context: What Already Exists

The zk kernel has a working VFS layer with a well-defined `FileSystem` interface that every filesystem must implement:

```
open, unmount, unlink, stat_path, chmod, chown, statfs, rename, rename2,
truncate, mkdir, rmdir, getdents, link, symlink, readlink, set_timestamps
```

Block device I/O already works: SFS reads/writes sectors by seeking a `FileDescriptor` to `lba * 512` and calling `ops.read`/`ops.write`. This FD-based block I/O pattern is driver-agnostic (works for AHCI, NVMe, VirtIO-SCSI). ext2 will reuse the exact same pattern.

SFS limitations that ext2 replaces:
- Flat filesystem (no nested directories), artificial to all tests
- 64 file maximum (hard on-disk limit)
- 32-character filename limit (POSIX allows 255)
- Known close deadlock after many operations
- 512-byte block size (suboptimal for large files)

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features that POSIX programs assume work on any writable filesystem. Missing any of these means tools like `ls`, `cp`, `mkdir`, `rm`, `find`, `shell scripts`, and compilers fail in ways that are hard to diagnose.

| Feature | Why Expected | Complexity | VFS Hook | Notes |
|---------|--------------|------------|----------|-------|
| Superblock parse and mount | Every ext2 operation starts here; without it, nothing else works | LOW | `FileSystem` init | Read 1024-byte superblock at byte offset 1024. Validate magic 0xEF53. Check `s_rev_level` (0=static, 1=dynamic inode sizes). Derive `block_size = 1024 << s_log_block_size`. Compute block group count from `s_blocks_count` and `s_blocks_per_group`. |
| Block group descriptor table parse | Required before any inode or block can be located | LOW | `FileSystem` init | BG descriptor table starts at block 1 (1KB block size) or block 2 (4KB block size) -- the block after the superblock. Each entry is 32 bytes. `bg_inode_table`, `bg_block_bitmap`, `bg_inode_bitmap` are the critical fields. |
| Inode read | Every file/directory/symlink is accessed through its inode | LOW | `open`, `stat_path` | Inode number is 1-based. `inode_group = (inode_num - 1) / s_inodes_per_group`. `inode_index = (inode_num - 1) % s_inodes_per_group`. Byte offset = `bg_inode_table * block_size + inode_index * inode_size`. Read 128 bytes (or `s_inode_size` if rev 1+). |
| Direct block reads (i_block[0..11]) | Covers files up to 12 * block_size (48KB at 4KB blocks). Most config files, scripts, source files fit here. | LOW | `FileDescriptor.ops.read` | 12 direct pointers. Each is a 32-bit block number. Block 0 means sparse hole -- return zeroes without I/O. |
| Singly indirect block reads (i_block[12]) | Files up to 12 + block_size/4 blocks. At 4KB blocks: up to 12 + 1024 = 1036 blocks = ~4MB. Covers most user-space binaries. | LOW | `FileDescriptor.ops.read` | Read the indirect block, then read the data block. Two I/Os per block beyond direct range. Already implemented in Linux as a standard pattern. |
| Doubly indirect block reads (i_block[13]) | Files up to ~4GB at 4KB block size. Covers all typical application files. | MEDIUM | `FileDescriptor.ops.read` | Two levels of indirection. Three I/Os per data block in worst case. Max file at 4KB blocks: 12 + 1024 + 1024^2 = ~4GB. This is the practical upper bound for most workloads. |
| Directory entry parsing | Path resolution (open, stat, readdir) requires walking directory entries | LOW | `open`, `stat_path`, `getdents` | Variable-length entries: `u32 inode`, `u16 rec_len`, `u8 name_len`, `u8 file_type` (if FILETYPE feature), `u8[] name` (not null-terminated). Entries are 4-byte aligned. Deleted entries have `inode = 0` but `rec_len` spans to next entry (deleted entries are coalesced into next entry's `rec_len`). |
| Nested directory traversal | Any path deeper than one level requires recursive directory reads. `ls /a/b/c` needs this. | LOW | `open`, `stat_path` | Split path on `/`. For each component, open the parent directory inode, scan entries for the component name, get child inode number, repeat. VFS already passes absolute paths stripped of mount prefix. |
| `statfs` (df, free space) | Tools like `df`, applications checking available disk space, and test infrastructure use this. | LOW | `statfs` | Return `s_blocks_count`, `s_free_blocks_count`, `s_inodes_count`, `s_free_inodes_count`, `s_log_block_size`. f_type for ext2 = 0xEF53. |
| `stat_path` (metadata lookup) | stat/fstat/lstat/access all require per-file metadata. Permission checks before open depend on this. | LOW | `stat_path` | Read inode, return: `i_mode` (type + perms), `i_uid`, `i_gid`, `i_size`, `i_atime`, `i_mtime`, `i_ctime`, `i_links_count` (nlink), inode number. |
| File create (inode + dir entry allocation) | Every `open(O_CREAT)`, `cp`, `touch`, `compiler output` creates a new file | HIGH | `open` (O_CREAT path) | Allocate a free inode from the inode bitmap in the same block group as the parent directory. Allocate a data block from the block bitmap. Write inode. Add directory entry to parent. Update bitmaps and superblock free counts. All must be atomic enough to avoid orphaned inodes on crash (ext2 is not journaled). |
| File write | cp, cat, compilers, shell redirect all write file content | HIGH | `FileDescriptor.ops.write` | If file offset exceeds current block allocation, allocate new blocks. Update `i_size` in inode if write extends file. Write data to block. Mark dirty. No journal -- writes must happen in safe order: data before metadata. |
| File truncate | `rm` (via unlink), `open(O_TRUNC)`, and `truncate()` syscall all use this | MEDIUM | `truncate`, `unlink` | Update `i_size`. Free blocks beyond new size by zeroing their entries in `i_block[]` and indirect blocks, then updating block bitmap. For unlink: set `i_links_count -= 1`, set `i_dtime` when nlink hits 0, free all blocks. |
| Directory create (mkdir) | Every directory creation: `mkdir`, build systems creating output dirs | MEDIUM | `mkdir` | Allocate inode (S_IFDIR mode). Allocate one block for directory data. Write `.` and `..` entries. Add entry to parent directory. Increment parent `i_links_count` (for `..'s back-link). Update bitmaps. |
| Directory remove (rmdir) | `rm -r`, cleanup operations | MEDIUM | `rmdir` | Verify directory is empty (scan entries, only `.` and `..`). Free directory blocks. Free inode. Remove entry from parent. Decrement parent nlink. |
| File unlink (delete) | `rm`, `unlink()` syscall | MEDIUM | `unlink` | Decrement `i_links_count`. If hits 0: set `i_dtime`, free all data blocks (direct + indirect), free inode. Remove directory entry by setting `inode = 0` and merging `rec_len` into previous entry. |
| Rename (same filesystem) | `mv`, `rename()` syscall -- compilers and build tools use this for atomic file replacement | MEDIUM | `rename` | Find source entry in old parent directory. Add entry to new parent directory. Remove entry from old parent. Update `i_ctime`. Handle special case: rename to existing file (unlink old target first). |
| Hard links | `ln` creates hard links. `nlink` tracking is required for correct `rm` behavior | MEDIUM | `link` | Add new directory entry pointing to same inode. Increment `i_links_count`. Stat must reflect updated nlink. |
| Symbolic links (fast path) | `ln -s`, many system layouts use symlinks (e.g., `/usr/lib` -> `/usr/lib64`). Fast symlinks are the common case. | LOW | `symlink`, `readlink` | If symlink target < 60 bytes: store target string directly in `i_block[0..14]` (60 bytes total). Set `i_size` to target length. No data block allocated. `readlink` reads from the inode directly. |
| File permissions and ownership | chmod, chown, POSIX mode bits. Test infrastructure verifies these. | LOW | `chmod`, `chown` | Write `i_mode`, `i_uid`, `i_gid` fields in inode. Update `i_ctime`. The VFS already tracks these via `FileMeta`; ext2 just needs to persist them. |
| Timestamps | POSIX requires atime, mtime, ctime. Test suite already validates timestamps via `utimensat`. | LOW | `set_timestamps` | Write `i_atime`, `i_mtime`, `i_ctime` in inode. All are 32-bit Unix timestamps in base ext2. The 2038 overflow is a known ext2 limitation (ext2 was deprecated in Linux 6.9 partly for this reason). Acceptable for a microkernel research OS. |
| Build system image creation | Without a way to create a test ext2 image, the implementation cannot be tested | LOW | `build.zig` + host script | Use `dd` to create a blank file, then `mke2fs`/`mkfs.ext2` on the host to format it. Add a Zig build step that checks if the image exists and creates it if not. This is a host-side operation, not a kernel feature, but it is a hard prerequisite for testing. |
| VirtIO-BLK or AHCI disk image in QEMU | ext2 must be on a disk that QEMU presents to the kernel | LOW | `build.zig` QEMU args | Pass `-drive file=ext2.img,format=raw,if=virtio` or `-drive file=ext2.img,format=raw,if=none,id=d0 -device ahci,id=ahci0 -device ide-hd,drive=d0,bus=ahci0.0`. AHCI is already working in zk. VirtIO-BLK requires the userspace `virtio_blk` driver already present. |
| VFS mount at `/mnt` | ext2 must be registered with the VFS to serve requests. Current `/mnt` is SFS. | LOW | VFS mount infrastructure | Initialize ext2 struct from device FD. Call `vfs.Vfs.mount("/mnt", ext2_filesystem)`. The VFS mount infrastructure is already in place and supports 8 simultaneous mounts. |

### Differentiators (Valuable but Not Required for Basic Functionality)

Features that make the ext2 implementation more complete and better suited for running real POSIX workloads, but are not needed to pass the basic test suite or replace SFS.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Triply indirect block reads (i_block[14]) | Files larger than ~4GB at 4KB blocks. Only needed for very large file tests. Real workloads on this microkernel are unlikely to exceed 4GB. | LOW | `FileDescriptor.ops.read` | Third level of indirection. Follows the same pattern as double indirect. At 4KB blocks, max file size without this is ~4GB; with it ~16TB. Implement for completeness, very low incremental effort once double-indirect is done. |
| Sparse file support (holes) | Programs that create sparse files (databases, VM images, `dd if=/dev/zero seek=X`) expect reads from unallocated regions to return zeros | LOW | `FileDescriptor.ops.read` | `i_block[n] == 0` means a sparse hole. Return zeroes for that block's range without doing I/O. Already documented in the block read path -- a block pointer of 0 means "hole, not allocated". |
| Symbolic links (slow path) | Symlinks longer than 60 bytes need a data block. Rare but POSIX-required. | LOW | `symlink` slow path | Allocate a data block. Write target string. `i_size` = target length. `readlink` reads the block and returns the string. Same as a file read but for the symlink data. |
| `getdents` with large directories | Directories with many entries (hundreds of files) span multiple blocks. `ls` on a large directory requires this. | LOW | `getdents` | The `getdents` VFS hook already receives an offset. For multi-block directories, advance offset through all directory blocks. Standard linear scan. |
| Block allocation locality (same group as inode) | Reduces fragmentation. Linux ext2 places new file blocks in the same block group as the inode. Irrelevant for small test images but important for correctness of the allocation algorithm. | MEDIUM | block alloc | When allocating data blocks for a new file, start the bitmap search in the inode's block group. Fall back to adjacent groups if full. The inode allocator also prefers the parent directory's group. |
| Superblock free count cache updates | `s_free_blocks_count` and `s_free_inodes_count` must be kept accurate or `statfs` returns stale data | LOW | alloc/free operations | After each block/inode alloc or free, decrement/increment the superblock counters and write the superblock block. SFS already does this pattern. |
| Superblock mount state tracking | `s_state` field (1=clean, 2=errors). At mount, set dirty. At unmount, set clean. Allows e2fsck to detect unclean mounts. | LOW | mount/unmount | Write `s_state = EXT2_ERROR_FS (2)` at mount time, `s_state = EXT2_VALID_FS (1)` at clean unmount. Also update `s_mnt_count` and compare to `s_max_mnt_count`. Not required for correctness, but good hygiene. |
| FILETYPE feature in directory entries | The `EXT2_FEATURE_INCOMPAT_FILETYPE` flag means directory entries carry a `file_type` byte encoding the inode type (regular, dir, symlink, etc.). This avoids an inode read during directory listing. `getdents64` returns file type in `d_type`; without FILETYPE, `DT_UNKNOWN` must be returned. | LOW | `getdents` | `mkfs.ext2` enables FILETYPE by default. The kernel must check `s_feature_incompat & EXT2_FEATURE_INCOMPAT_FILETYPE` and read the byte at offset 7 in each directory entry if set. Type values: 1=regular, 2=dir, 3=chardev, 4=blkdev, 5=FIFO, 6=socket, 7=symlink. |
| `inotify` hook integration | VFS inotify hooks already exist and fire on open, unlink, create, rename, attrib. ext2 should trigger them consistently. | LOW | All write operations | The VFS layer already has `inotify_event_hook`. As long as ext2 operations go through the VFS dispatch (which they will), the hooks fire automatically. No ext2-specific work needed here. |
| Test migration: replace SFS tests with ext2 | Existing test suite tests filesystem operations against SFS at `/mnt`. Migrating them to ext2 validates the implementation under the full test harness. | MEDIUM | test infra | Update `tests/fs/basic.zig` and related tests to target `/mnt` on ext2 instead of SFS. Keep SFS mounted at a separate path during transition (`/mnt/sfs`) or remove it after ext2 is verified. The test harness already handles both architectures. |

### Anti-Features (Commonly Considered, Should Be Deferred or Rejected)

| Feature | Why Considered | Why Problematic or Unnecessary | Alternative |
|---------|---------------|-------------------------------|-------------|
| journaling (ext3/ext4 journal) | Crash safety is important; ext2 has no journal so a crash mid-write can corrupt the filesystem | Implementing a journal (ext3/ext4 style) requires redesigning the entire write path around transaction semantics. This doubles the scope of the milestone. ext2 without a journal is well-understood and historically acceptable for research/embedded use. | Write in safe order: data blocks before metadata. On mount, check `s_state` and warn if unclean. In QEMU testing, unclean mounts are prevented by clean shutdown. Journal is a separate future milestone (ext4 upgrade path). |
| HTree indexed directories (dx_dir) | Large directories (thousands of entries) are O(n) to search with linear scan; HTree makes them O(log n) | HTree (`EXT2_FEATURE_COMPAT_DIR_INDEX`) is an optional compat feature. mkfs.ext2 creates HTree-capable filesystems by default in modern e2fsprogs. However, a kernel that does not support HTree can still read/write the filesystem correctly because HTree is COMPAT (not INCOMPAT). The kernel must not corrupt the index when writing new entries, but it can treat HTree directories as regular linear-scan directories safely. | Mount read-write but do not enable HTree when creating. When writing to a directory that has an HTree index, scan and write entries in the linear portion (block 0 contains real entries). The HTree index will become stale but e2fsck can rebuild it. This is acceptable for a research OS. |
| 64-bit block numbers (ext4 INCOMPAT_64BIT) | Large filesystems (>8TB with 4KB blocks) need 64-bit block numbers | This is an ext4-only feature. Pure ext2 uses 32-bit block numbers. The zk test image will be small (tens of MB). Do not implement 64-bit block numbers as part of this milestone. | Hard limit: ext2 supports up to 4TB at 4KB block size (2^32 blocks). More than sufficient. |
| Online resize / `resize2fs` support | Allows growing the filesystem while mounted | Requires writing a new block group descriptor table and updating the superblock. Complex and untestable in QEMU without specific resize tooling. | Fixed-size image created at build time. Size is chosen at image creation. |
| Extended attributes (xattr) | Security models, SELinux, file capabilities use xattrs | xattr support is listed as "Out of Scope" in PROJECT.md. ext2 has a block-based xattr format but it is optional (COMPAT flag). | Return ENOTSUP from setxattr/getxattr. The VFS does not currently have xattr hooks. |
| ACLs (POSIX access control lists) | Fine-grained permission control beyond rwxrwxrwx | Implemented via xattr internally. Deferred along with xattr. | Standard Unix mode bits (i_mode) are sufficient for all current tests and syscalls. |
| Compression (EXT2_FEATURE_INCOMPAT_COMPRESSION) | Transparent file compression | This is INCOMPAT -- refusing to mount is correct if the flag is set. For images created by standard mkfs.ext2 without compression, this flag is not set. | Fail mount with a clear error if this INCOMPAT flag is present. Do not attempt to implement compression. |
| Hash tree directory creation | When creating new directories, populate an HTree index | Even if mkfs.ext2 created an HTree-indexed root, a kernel that writes in linear mode will produce directories that still work -- the HTree becomes stale but e2fsck fixes it. Do not create new directories with HTree indexes. | Write `.` and `..` entries only in a new directory block. Linear scan for lookup. |
| Atomic write ordering with barriers | Correct crash recovery requires write ordering: data before indirect blocks before direct pointers before directory entries | ext2 by design has no crash-safe atomicity. The best available mitigation is write ordering. This is not a feature to add -- it is a correctness discipline to apply throughout the write path. | Documented write order in PITFALLS.md. Enforce in code review. No special hardware or kernel feature required. |

---

## Feature Dependencies

```
[Superblock parse]
    required-by: [Block group descriptor parse]
    required-by: [Block size derivation]
    required-by: [Inode read]

[Block group descriptor parse]
    required-by: [Inode read]
    required-by: [Block bitmap access]
    required-by: [Inode bitmap access]

[Inode read]
    required-by: [Direct block reads]
    required-by: [Singly indirect reads]
    required-by: [Doubly indirect reads]
    required-by: [Directory entry parsing]
    required-by: [stat_path]
    required-by: [File permissions]
    required-by: [Timestamps]

[Direct block reads]
    required-by: [File write]
    required-by: [Directory create]
    required-by: [Directory entry parsing]

[Singly indirect reads]
    required-by: [Doubly indirect reads]

[Doubly indirect reads]
    required-by: [Triply indirect reads] (differentiator)

[Directory entry parsing]
    required-by: [Nested directory traversal]
    required-by: [getdents]
    required-by: [Hard links]
    required-by: [Rename]

[Block bitmap access]
    required-by: [File create]
    required-by: [File write] (block extension)
    required-by: [File truncate]
    required-by: [File unlink]
    required-by: [Directory create]
    required-by: [Directory remove]

[Inode bitmap access]
    required-by: [File create]
    required-by: [File unlink] (inode free)
    required-by: [Directory create]
    required-by: [Directory remove]

[File create]
    required-by: [File write] (creates file before writing)
    required-by: [Directory create] (same inode alloc path)
    required-by: [Symbolic links]
    required-by: [Hard links]

[Build system image creation]
    required-by: [VirtIO-BLK / AHCI disk in QEMU]
    required-by: [VFS mount at /mnt]
    -- these three are the testing infrastructure prerequisite chain

[VFS mount at /mnt]
    required-by: All filesystem operations (kernel cannot call ext2 ops without a mount)
```

### Dependency Notes

- **Inode read is the universal dependency.** Every single ext2 operation touches at least one inode. The inode-read routine must be correct, handle both revision 0 (fixed 128-byte inodes) and revision 1 (variable inode size from `s_inode_size`), and be efficient. SFS has a parallel: `DirEntry` is read by index; ext2's inode is read by group + offset calculation.

- **Block bitmap and inode bitmap share the same locking concern as SFS's `alloc_lock`.** All bitmap mutations (alloc and free) must be serialized. The same two-phase approach used in SFS (scan/mark under lock, write I/O outside lock) applies here. The close deadlock in SFS was caused by violating this ordering.

- **Read path is completely independent of write path.** Implementing read-only ext2 first (superblock + block groups + inode + direct/indirect reads + directory traversal) provides a testable milestone before any write operations are added. This is the recommended phase structure.

- **The FILETYPE feature flag is almost certain to be set** in any ext2 image created by modern `mke2fs`. The kernel must handle both cases (with and without FILETYPE), but in practice all test images will have it. If FILETYPE is set, directory entries have a valid `file_type` byte at offset 7. If not set, `file_type` must be treated as 0 and inode must be read to determine type.

- **Sparse superblock (SPARSE_SUPER) is an RO_COMPAT flag.** Its presence means backup superblocks exist only in block groups 0, 1, and powers of 3, 5, 7. The kernel does not need to read backup superblocks during normal operation -- only the primary at offset 1024 is used. SPARSE_SUPER affects `fsck` tools, not the kernel's operational read path. However, a mount check should refuse to write if unknown RO_COMPAT flags are present.

---

## MVP Definition

The milestone has two natural phases: read-only first, then read-write.

### Phase 1: Read-Only Mount (MVP for Basic Validation)

Sufficient to validate the on-disk format parsing and prove the implementation is correct before touching write paths.

- [ ] Superblock parse, magic check, block size derivation -- prerequisite for all else
- [ ] Block group descriptor table parse -- needed for inode and bitmap locations
- [ ] Inode read routine (both rev 0 and rev 1) -- universal dependency
- [ ] Direct block reads (i_block[0..11]) -- covers files up to 48KB at 4KB blocks
- [ ] Singly indirect block reads (i_block[12]) -- covers files up to ~4MB
- [ ] Doubly indirect block reads (i_block[13]) -- covers files up to ~4GB
- [ ] Directory entry parsing (linear scan, handle deleted entries via rec_len) -- path resolution
- [ ] Nested directory traversal (multi-component path splitting) -- any real path
- [ ] `stat_path` returning FileMeta from inode -- permission checks and stat syscalls
- [ ] `statfs` returning block/inode counts -- df/fstatfs work
- [ ] `getdents` linear scan including FILETYPE flag handling -- ls works
- [ ] Fast symlink read (target stored in i_block[]) -- readlink for short symlinks
- [ ] Feature flag checks: refuse to mount if unknown INCOMPAT flags set; refuse to write if unknown RO_COMPAT flags set
- [ ] Build system ext2 image creation (dd + mke2fs in build step) -- testing infrastructure
- [ ] VFS mount registration at `/mnt` replacing SFS -- ties it all together
- [ ] `open` for read-only access -- basic file reads work

### Phase 2: Read-Write Operations (Full Replacement of SFS)

Required to fully replace SFS and pass the existing test suite.

- [ ] Block bitmap alloc/free (scan, mark, write back) -- foundation of all write ops
- [ ] Inode bitmap alloc/free (scan, mark, write back) -- foundation of all create/delete ops
- [ ] Inode write (persist inode fields back to disk) -- needed after any metadata change
- [ ] File create via `open(O_CREAT)` (alloc inode + data block, add dir entry) -- touch, cp, etc.
- [ ] File write (write data, extend blocks on boundary crossing, update i_size) -- all write ops
- [ ] File truncate (update i_size, free orphaned blocks) -- ftruncate, open(O_TRUNC)
- [ ] File unlink (remove dir entry, decrement nlink, free inode + blocks when nlink == 0) -- rm
- [ ] Directory create / mkdir (alloc inode + block, write . and .. entries, add to parent) -- mkdir
- [ ] Directory remove / rmdir (verify empty, free, remove parent entry) -- rmdir
- [ ] Rename within same filesystem (move dir entry, update ctime) -- mv
- [ ] Hard link (add dir entry, increment nlink) -- ln
- [ ] Symbolic link fast path write (store in inode i_block area) -- ln -s (short paths)
- [ ] chmod / chown (write i_mode, i_uid, i_gid, update ctime) -- chmod, chown
- [ ] set_timestamps (write i_atime, i_mtime to inode) -- utimensat
- [ ] Superblock dirty/clean state tracking (s_state field) -- clean unmount hygiene

### Future Consideration (Post-Milestone)

- [ ] Triply indirect block support (files > 4GB) -- no current test requires this
- [ ] Slow symlink path (symlink target > 60 bytes, requires data block) -- rare in practice
- [ ] Symbolic link resolution in VFS path walker (currently VFS does not follow symlinks during open) -- broader VFS redesign needed
- [ ] Block allocation locality optimization (prefer parent group) -- performance, not correctness
- [ ] HTree directory support (read HTree-indexed dirs without corrupting index) -- needed if `find` on large dirs is slow
- [ ] ext4 migration path (64-bit block numbers, extent trees) -- separate project

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Superblock + block group parse | HIGH | LOW | P1 |
| Inode read routine | HIGH | LOW | P1 |
| Direct + singly indirect reads | HIGH | LOW | P1 |
| Directory entry parsing + traversal | HIGH | LOW | P1 |
| Build system image creation | HIGH | LOW | P1 |
| VFS mount at /mnt | HIGH | LOW | P1 |
| stat_path, statfs, getdents | HIGH | LOW | P1 |
| Doubly indirect reads | HIGH | LOW | P1 |
| Feature flag checks (INCOMPAT/RO_COMPAT) | HIGH | LOW | P1 |
| Block bitmap alloc/free | HIGH | MEDIUM | P1 |
| Inode bitmap alloc/free | HIGH | MEDIUM | P1 |
| File create + inode write | HIGH | HIGH | P1 |
| File write (data + block extension) | HIGH | HIGH | P1 |
| File unlink + block free | HIGH | MEDIUM | P1 |
| Directory create (mkdir) | HIGH | MEDIUM | P1 |
| Directory remove (rmdir) | MEDIUM | MEDIUM | P1 |
| Rename | MEDIUM | MEDIUM | P1 |
| chmod, chown, set_timestamps | MEDIUM | LOW | P1 |
| Hard links | MEDIUM | LOW | P2 |
| Fast symlink read | MEDIUM | LOW | P2 |
| Fast symlink write | MEDIUM | LOW | P2 |
| FILETYPE feature flag in getdents | MEDIUM | LOW | P2 |
| Superblock mount state tracking | LOW | LOW | P2 |
| Block allocation locality | LOW | MEDIUM | P3 |
| Triply indirect reads | LOW | LOW | P3 |
| Slow symlink path | LOW | LOW | P3 |
| Symlink follow in VFS open | LOW | HIGH | P3 |

**Priority key:**
- P1: Required for a working, testable implementation that replaces SFS
- P2: Required for full POSIX compliance and test suite coverage
- P3: Defer, not needed for this milestone

---

## ext2 On-Disk Format Reference (Implementation Cheatsheet)

### Superblock (at byte offset 1024, size 1024 bytes)

| Offset | Field | Size | Description |
|--------|-------|------|-------------|
| 0 | s_inodes_count | u32 | Total inode count |
| 4 | s_blocks_count | u32 | Total block count |
| 12 | s_free_blocks_count | u32 | Free block count |
| 16 | s_free_inodes_count | u32 | Free inode count |
| 20 | s_first_data_block | u32 | First data block (0 for 4KB blocks, 1 for 1KB blocks) |
| 24 | s_log_block_size | u32 | block_size = 1024 << s_log_block_size |
| 32 | s_blocks_per_group | u32 | Blocks per block group |
| 40 | s_inodes_per_group | u32 | Inodes per block group |
| 48 | s_mtime | u32 | Last mount time (Unix timestamp) |
| 52 | s_wtime | u32 | Last write time (Unix timestamp) |
| 56 | s_mnt_count | u16 | Mount count since last fsck |
| 58 | s_max_mnt_count | u16 | Max mounts before forced fsck |
| 56 | s_state | u16 | FS state: 1=clean, 2=errors |
| 76 | s_rev_level | u32 | 0=original, 1=dynamic (variable inode size) |
| 92 | s_first_ino | u32 | First non-reserved inode (rev 1+; fixed 11 in rev 0) |
| 88 | s_inode_size | u16 | Inode size in bytes (rev 1+; fixed 128 in rev 0) |
| 96 | s_feature_compat | u32 | Compatible feature flags |
| 100 | s_feature_incompat | u32 | Incompatible feature flags |
| 104 | s_feature_ro_compat | u32 | Read-only compatible feature flags |
| 56 | s_magic | u16 | Magic: 0xEF53 (at offset 56 in superblock = byte 1080 from device start) |

Note: all fields are little-endian. Magic 0xEF53 is at superblock offset 0x38 (56 decimal).

### Feature Flags (critical for mount decisions)

**INCOMPAT flags (refuse to mount if unknown flag set):**
- `EXT2_FEATURE_INCOMPAT_COMPRESSION = 0x0001` -- reject, not implemented
- `EXT2_FEATURE_INCOMPAT_FILETYPE = 0x0002` -- handle: directory entries have type byte
- `EXT2_FEATURE_INCOMPAT_RECOVER = 0x0004` -- reject (ext3 journal recovery in progress)
- `EXT2_FEATURE_INCOMPAT_JOURNAL_DEV = 0x0008` -- reject (ext3 journal device)
- `EXT2_FEATURE_INCOMPAT_META_BG = 0x0010` -- reject (meta block groups, ext4)

Known safe INCOMPAT mask: `0x0002` (FILETYPE only). Any other INCOMPAT bit set = refuse mount.

**RO_COMPAT flags (refuse to write if unknown flag set, but can mount read-only):**
- `EXT2_FEATURE_RO_COMPAT_SPARSE_SUPER = 0x0001` -- handle: backup superblocks only at 0, 1, 3^n, 5^n, 7^n
- `EXT2_FEATURE_RO_COMPAT_LARGE_FILE = 0x0002` -- handle: i_size_high field exists for files > 2GB
- `EXT2_FEATURE_RO_COMPAT_BTREE_DIR = 0x0004` -- allow read-only (treat as linear dir)

**COMPAT flags (safe to ignore):**
- `EXT2_FEATURE_COMPAT_DIR_PREALLOC = 0x0001` -- block prealloc for dirs (ignore)
- `EXT2_FEATURE_COMPAT_IMAGIC_INODES = 0x0002` -- AFS (ignore)
- `EXT3_FEATURE_COMPAT_HAS_JOURNAL = 0x0004` -- ext3 journal file exists (ignore; we don't use it)
- `EXT2_FEATURE_COMPAT_DIR_INDEX = 0x0020` -- HTree directory index (ignore; treat dirs as linear)

### Block Group Descriptor (32 bytes per entry)

| Offset | Field | Size | Description |
|--------|-------|------|-------------|
| 0 | bg_block_bitmap | u32 | Block number of block bitmap |
| 4 | bg_inode_bitmap | u32 | Block number of inode bitmap |
| 8 | bg_inode_table | u32 | Block number of first inode table block |
| 12 | bg_free_blocks_count | u16 | Free block count in group |
| 14 | bg_free_inodes_count | u16 | Free inode count in group |
| 16 | bg_used_dirs_count | u16 | Directory count in group |

BG descriptor table is located in the block immediately following the superblock block.
- 1KB blocks: superblock in block 1, BG table starts in block 2
- 4KB blocks: superblock in block 0 (padded after byte 1024), BG table starts in block 1

### Inode Structure (128 bytes base, rev 0; s_inode_size bytes, rev 1)

| Offset | Field | Size | Description |
|--------|-------|------|-------------|
| 0 | i_mode | u16 | File type + permissions (e.g., 0o100644 = regular file rw-r--r--) |
| 2 | i_uid | u16 | Lower 16 bits of owner UID |
| 4 | i_size | u32 | File size in bytes (lower 32 bits for regular files) |
| 8 | i_atime | u32 | Access time (Unix timestamp, 32-bit, 2038 problem) |
| 12 | i_ctime | u32 | Inode change time |
| 16 | i_mtime | u32 | Data modification time |
| 20 | i_dtime | u32 | Deletion time (set when unlinked, 0 if active) |
| 24 | i_gid | u16 | Lower 16 bits of owner GID |
| 26 | i_links_count | u16 | Hard link count (0 = inode is free and dtime is set) |
| 28 | i_blocks | u32 | Count of 512-byte blocks allocated (NOT block_size blocks) |
| 32 | i_flags | u32 | Inode flags (e.g., EXT2_SECRM_FL, EXT2_APPEND_FL) |
| 40 | i_block[15] | u32[15] | Block pointers: [0..11]=direct, [12]=indirect, [13]=double, [14]=triple |
| 104 | i_generation | u32 | NFS file version counter |
| 116 | i_uid_high | u16 | Upper 16 bits of UID (rev 1+) |
| 118 | i_gid_high | u16 | Upper 16 bits of GID (rev 1+) |

i_mode type bits: `0o140000`=socket, `0o120000`=symlink, `0o100000`=regular, `0o060000`=block device, `0o040000`=directory, `0o020000`=char device, `0o010000`=FIFO.

For symlinks with target <= 60 bytes: `i_block[0..14]` stores the target string directly (fast symlink). `i_size` = target length. `i_blocks = 0`. No data block allocated.

### Directory Entry Structure

```
struct ext2_dir_entry {
    inode:    u32,  // Inode number (0 = unused/deleted entry)
    rec_len:  u16,  // Distance to next entry in bytes (must be 4-byte aligned)
    name_len: u8,   // Length of name in bytes (not including null terminator)
    file_type: u8,  // Only valid if FILETYPE feature is set:
                    //   0=unknown, 1=regular, 2=dir, 3=chardev, 4=blkdev, 5=FIFO, 6=socket, 7=symlink
    name[]:   u8,   // File name (NOT null-terminated; use name_len)
};
```

Last entry in a directory block: `rec_len` extends to the end of the block (not the actual name length). This is how deleted entries are "merged" -- the previous entry's `rec_len` is extended to skip over the deleted entry.

New entry insertion: scan for an entry whose `rec_len` is larger than its minimum size (`8 + name_len` rounded up to 4). Split that entry: shrink the existing entry's `rec_len` to its minimum, place new entry in the gap. If no gap found, allocate a new directory block.

---

## Comparison to SFS (What ext2 Gives That SFS Cannot)

| Capability | SFS | ext2 |
|------------|-----|------|
| Max files | 64 (hard on-disk limit) | 2^32 - 1 (limited by inode count) |
| Max filename length | 32 chars | 255 chars |
| Nested directories | No (flat only) | Unlimited depth |
| Max file size | ~8MB (16384 blocks * 512 bytes) | ~4TB at 4KB blocks |
| Block size | 512 bytes (sector-aligned) | 1KB, 2KB, or 4KB (configurable) |
| Close deadlock | Yes (known bug, partially fixed) | No (different locking model) |
| Sparse files | No | Yes (i_block[n] == 0 = hole) |
| Hard links | Yes (added in v1.1) | Yes (native inode sharing) |
| Symbolic links | Yes (added in v1.1) | Yes (fast path native) |
| Timestamps | u32 seconds (2038 problem shared) | u32 seconds (same 2038 problem) |
| fsck support | No external tool | e2fsck (e2fsprogs) |
| Image creation | Custom SFS format tool | Standard mke2fs/mkfs.ext2 |
| POSIX compliance | Partial | Close (no journal, no ACLs) |

---

## Sources

- [Ext2 -- OSDev Wiki](https://wiki.osdev.org/Ext2) -- comprehensive implementation reference with all structure offsets (HIGH confidence)
- [The Second Extended Filesystem -- Linux Kernel Documentation](https://docs.kernel.org/filesystems/ext2.html) -- official kernel docs (HIGH confidence)
- [Design and Implementation of the Second Extended Filesystem](https://e2fsprogs.sourceforge.net/ext2intro.html) -- original design paper by Remy Card, Theodore Ts'o, Stephen Tweedie (HIGH confidence)
- [The Second Extended File System -- Nongnu](https://www.nongnu.org/ext2-doc/ext2.html) -- complete field-level specification (HIGH confidence)
- [Ext2 Feature Flags -- Kernel Documentation](https://www.kernel.org/doc/Documentation/filesystems/ext2.txt) -- COMPAT/INCOMPAT/RO_COMPAT flag values (HIGH confidence)
- [inode pointer structure -- Wikipedia](https://en.wikipedia.org/wiki/Inode_pointer_structure) -- indirect block addressing (MEDIUM confidence, consistent with authoritative sources)
- [ext2 deprecation in Linux 6.9](https://en.wikipedia.org/wiki/Ext2) -- 32-bit timestamp issue, deprecation status (HIGH confidence)
- Code audit: `src/fs/sfs/io.zig` -- FD-based block I/O pattern for reuse in ext2
- Code audit: `src/fs/vfs.zig` -- complete VFS FileSystem interface ext2 must implement
- Code audit: `src/fs/sfs/types.zig` -- existing superblock/bitmap pattern ext2 parallels
- Code audit: `src/fs/meta.zig` -- FileMeta structure ext2 stat_path must fill

---
*Feature research for: ext2 Filesystem Implementation -- zk Microkernel*
*Researched: 2026-02-22*
