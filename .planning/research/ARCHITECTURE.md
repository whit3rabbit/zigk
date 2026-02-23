# Architecture Research: ext2 Filesystem Integration

**Domain:** Hierarchical filesystem implementation integrated into an existing microkernel VFS
**Researched:** 2026-02-22
**Confidence:** HIGH (based on direct source analysis of existing VFS, SFS, partition, and fd subsystems)

---

## Existing Architecture Inventory

This milestone integrates ext2 into a kernel that already has a working, layered filesystem stack. Every architectural decision must fit into what exists.

### Current Filesystem Stack

```
Syscall Layer (sys_open, sys_read, sys_write, sys_mkdir, ...)
         |
         v
VFS Layer (src/fs/vfs.zig)
  - MAX_MOUNTS = 8 slots (spinlock-protected)
  - Longest-prefix path resolution
  - FileSystem interface (vtable of optional function pointers)
  - Dispatches: open, unlink, stat_path, chmod, chown, mkdir, rmdir,
                rename, rename2, getdents, link, symlink, readlink,
                set_timestamps, statfs, truncate
         |
         +-- initrd_fs  mounted at "/"    (read-only USTAR tar)
         +-- dev_fs     mounted at "/dev" (virtual device files)
         +-- SFS        mounted at "/mnt" (flat read-write, /dev/sda)
         |
         v
File Descriptor Layer (src/kernel/fs/fd.zig)
  - FileOps vtable: read, write, close, seek, stat, ioctl, mmap, poll, truncate, getdents, chown
  - FileDescriptor struct: ops, private_data, flags, refcount, position, lock, vfs_mount_idx, ...
  - FdTable per process: MAX_FDS = 256 entries
  - Page cache (src/kernel/fs/page_cache.zig): 256-bucket hash, 1024 pages, keyed by (file_id, page_offset)
         |
         v
Block Device Layer (src/fs/partitions/root.zig)
  - Partition structs registered in DevFS as /dev/sda, /dev/sda1, etc.
  - partition_ops FileOps: position-based byte I/O with LBA arithmetic
  - AHCI, NVMe, VirtIO-SCSI backends (all use same FileOps interface)
         |
         v
Storage Drivers (src/drivers/storage/)
  - AHCI: readSectors/writeSectors via controller singleton
  - NVMe: readBlocks/writeBlocks via controller singleton
  - VirtIO-SCSI: readBlocks/writeBlocks via controller singleton
```

### SFS as the Reference Implementation

SFS is the only writable filesystem and is the direct predecessor ext2 replaces. Its structure is the template:

```
SFS components (src/fs/sfs/):
  root.zig    -- SFS.init() -> returns vfs.FileSystem vtable
  types.zig   -- SFS, SfsFile, Superblock, DirEntry structs; lock declarations
  io.zig      -- readSector/writeSector via device_fd FileOps (driver-portable)
  ops.zig     -- sfsOpen, sfsRead, sfsWrite, sfsClose, sfsMkdir, sfsGetdents, ...
  alloc.zig   -- bitmap-based block allocation
```

SFS directly opens `/dev/sda` via `vfs.Vfs.open()`, stores the resulting `*FileDescriptor` as `device_fd`, then does all I/O by manipulating `device_fd.position` and calling `device_fd.ops.read/write`. This is the established pattern for block device access. Ext2 must use the same approach.

### How SFS is Initialized and Mounted

From `src/kernel/core/init_fs.zig`:
```
initVfs() -- VFS.init(), mounts "/" and "/dev"
initBlockFs() -- SFS.init("/dev/sda") -> vfs.Vfs.mount("/mnt", sfs_instance)
```

Ext2 replaces this: `Ext2.init("/dev/sda1")` (or the partition containing the ext2 image) then `Vfs.mount("/mnt", ext2_instance)`.

### Lock Ordering (Existing)

From CLAUDE.md, the global ordering is:
```
1. process_tree_lock
2. SFS.alloc_lock (Filesystem Allocation)  <-- ext2 equivalent needed here
3. FileDescriptor.lock
4. Scheduler/Runqueue Lock
5-7. Network locks
8. UserVmm.lock
...
```

Ext2 will introduce new locks at positions ~2 and ~2.5:
```
2.   Ext2.group_lock  (block group descriptor access, same level as SFS.alloc_lock)
2.5. Ext2.inode_cache_lock  (inode cache LRU, acquired AFTER group_lock)
3.   FileDescriptor.lock  (existing, unchanged)
```

---

## New Architecture: ext2 Integration

### System Overview After ext2

```
Syscall Layer
         |
         v
VFS Layer (UNCHANGED -- ext2 registers as FileSystem vtable)
  +-- initrd_fs  at "/"
  +-- dev_fs     at "/dev"
  +-- Ext2FS     at "/mnt"  <-- replaces SFS
         |
         v
File Descriptor Layer (UNCHANGED)
  - Ext2File struct stored as FileDescriptor.private_data
  - Ext2FileOps vtable (read, write, close, seek, stat, getdents, ...)
         |
         v
Block Device Abstraction Layer (NEW -- src/fs/block_dev.zig)
  BlockDevice interface:
    readBlocks(lba, count, buf) -> Error!void
    writeBlocks(lba, count, buf) -> Error!void
    block_size: u32
  Backed by partition FileDescriptor (same AHCI/NVMe/VirtIO-SCSI underneath)
         |
         v
Ext2 Core (NEW -- src/fs/ext2/)
  types.zig    -- on-disk structs (Superblock, GroupDesc, Inode, DirEntry2)
  inode.zig    -- inode read/write, indirect block resolution
  dir.zig      -- directory entry parsing, htree lookup
  alloc.zig    -- block/inode bitmap allocation
  io.zig       -- readBlock/writeBlock using BlockDevice
  ops.zig      -- VFS FileSystem interface implementations
  root.zig     -- Ext2.init() -> vfs.FileSystem
  cache.zig    -- Inode cache (fixed-size, LRU eviction)
```

### Component Responsibilities

| Component | Location | Responsibility | New or Modified |
|-----------|----------|----------------|-----------------|
| BlockDevice abstraction | `src/fs/block_dev.zig` | Driver-agnostic block I/O via FileOps | NEW |
| Ext2 on-disk types | `src/fs/ext2/types.zig` | Superblock, GroupDesc, Inode structs | NEW |
| Ext2 inode I/O | `src/fs/ext2/inode.zig` | Read/write inodes, resolve indirect blocks | NEW |
| Ext2 directory ops | `src/fs/ext2/dir.zig` | Walk dir entries, add/remove entries | NEW |
| Ext2 allocation | `src/fs/ext2/alloc.zig` | Block/inode bitmap management | NEW |
| Ext2 block I/O | `src/fs/ext2/io.zig` | readBlock/writeBlock to BlockDevice | NEW |
| Ext2 VFS ops | `src/fs/ext2/ops.zig` | All FileSystem vtable functions | NEW |
| Ext2 inode cache | `src/fs/ext2/cache.zig` | Fixed-size inode cache, LRU | NEW |
| Ext2 init | `src/fs/ext2/root.zig` | Ext2.init() -> vfs.FileSystem | NEW |
| VFS (vfs.zig) | `src/fs/vfs.zig` | No change needed | UNCHANGED |
| FD layer (fd.zig) | `src/kernel/fs/fd.zig` | No change needed | UNCHANGED |
| init_fs.zig | `src/kernel/core/init_fs.zig` | Replace SFS.init with Ext2.init | MODIFIED |
| build.zig | `build.zig` | Add ext2.img creation via mkfs.ext2 | MODIFIED |
| Partition scanning | `src/fs/partitions/root.zig` | No change needed | UNCHANGED |

---

## Recommended File Structure

```
src/fs/
  block_dev.zig           -- BlockDevice interface (new, shared by ext2 and future FSes)
  ext2/
    root.zig              -- Ext2.init(device_path) -> vfs.FileSystem; format detection
    types.zig             -- On-disk structs: Superblock, GroupDesc, Inode, DirEntry2, Extent
    io.zig                -- readBlock(block_num, buf), writeBlock(block_num, buf) via BlockDevice
    inode.zig             -- readInode, writeInode, resolveBlockNum (handles single/double/triple indirect)
    dir.zig               -- readDirEntry, writeDirEntry, lookupName, addEntry, removeEntry
    alloc.zig             -- allocBlock, freeBlock, allocInode, freeInode (bitmap operations)
    cache.zig             -- InodeCache (fixed-size array, LRU via generation counter)
    ops.zig               -- VFS ops: ext2Open, ext2Read, ext2Write, ext2Close, ext2Mkdir, etc.
```

---

## Data Flow: Syscall to Disk

### Read Path (sys_read -> ext2 -> disk)

```
sys_read(fd_num, user_buf, len)
    |
    v
FdTable.get(fd_num) -> *FileDescriptor  [fd.lock briefly held]
    |
    v
FileOps.read(file_desc, kernel_buf)  [ext2Read in ops.zig]
    |
    v
Ext2File.inode_num -> InodeCache.get(inode_num)  [inode_cache_lock]
  if miss: io.readInode(inode_num) -> BlockDevice.readBlocks()
    |
    v
inode.resolveBlockNum(file_offset / block_size)
  -- direct:   inode.block[0..11] (direct blocks)
  -- single:   read indirect block, index into it
  -- double:   read double-indirect, then indirect, then data
  -- triple:   three levels of indirection
    |
    v
io.readBlock(block_num, buf)
    |
    v
BlockDevice.readBlocks(lba_offset + block_num * sectors_per_block, ...)
    |
    v
device_fd.ops.read(device_fd, buf)  [partition_ops / ahci adapter]
    |
    v
AHCI controller.readSectors(port_num, lba, count, buf)
```

### Write Path (sys_write -> ext2 -> disk)

```
sys_write(fd_num, user_buf, len)
    |
    v
ext2Write(file_desc, kernel_buf)
    |
    v
For each 4KB block spanning the write range:
  1. resolveBlockNum(offset) -- if block doesn't exist: alloc.allocBlock()
  2. If partial write: io.readBlock() first (RMW)
  3. Merge data into block buffer
  4. io.writeBlock(block_num, buf)
  5. If file grew: update inode.i_size, alloc.writeBlock for indirect blocks
    |
    v
Update inode timestamps (mtime, ctime)
WriteInode(inode_num, updated_inode)  -- writes back to group's inode table
    |
    v
BlockDevice.writeBlocks(...)
    |
    v
AHCI / NVMe / VirtIO-SCSI driver
```

### Directory Lookup Path (sys_open -> path resolution)

```
sys_open("/mnt/foo/bar/baz.txt", flags)
    |
    v
VFS.open("/mnt/foo/bar/baz.txt", flags)
  -- strips "/mnt" prefix -> "foo/bar/baz.txt"
    |
    v
ext2Open(ctx, "foo/bar/baz.txt", flags)
    |
    v
Start at root inode (inode 2 in ext2)
  For each path component ["foo", "bar", "baz.txt"]:
    dir.lookupName(current_dir_inode, component)
      -> reads directory blocks, scans DirEntry2 records for name match
      -> returns child inode_num
    InodeCache.get(child_inode_num) -> Inode
  On last component: allocate Ext2File, wrap in FileDescriptor
```

---

## Key New Components

### 1. BlockDevice Abstraction (src/fs/block_dev.zig)

SFS does I/O by directly calling `device_fd.ops.read/write` with position manipulation. This works but is fragile (position state shared across callers requires io_lock). Ext2 needs a cleaner interface since it will make many concurrent block reads during path traversal.

```zig
pub const BlockDevice = struct {
    /// Private data (pointer to Partition or similar)
    ctx: *anyopaque,
    /// Block size in bytes (typically 512, may be 4096 for NVMe)
    block_size: u32,
    /// Total block count
    total_blocks: u64,

    readBlocks: *const fn(ctx: *anyopaque, lba: u64, count: u32, buf: []u8) Error!void,
    writeBlocks: *const fn(ctx: *anyopaque, lba: u64, count: u32, buf: []const u8) Error!void,
};
```

This wraps the existing `partition_ops` FileDescriptor into a typed interface. It does NOT replace the partition FD -- it uses the same FD underneath but hides position manipulation behind explicit LBA parameters, eliminating the io_lock contention problem.

The BlockDevice is constructed from the partition FileDescriptor during ext2 init by extracting the Partition struct from `device_fd.private_data`.

### 2. Inode Cache (src/fs/ext2/cache.zig)

Ext2 path traversal requires reading an inode for each path component. Without a cache, opening `/mnt/a/b/c/d/e.txt` requires 5 disk reads just for inodes. A small fixed-size inode cache dramatically improves path traversal performance.

```zig
const INODE_CACHE_SIZE = 64;  // 64 cached inodes

pub const CachedInode = struct {
    inode_num: u32,
    inode: Inode,
    generation: u64,   // LRU counter
    dirty: bool,
};

pub const InodeCache = struct {
    entries: [INODE_CACHE_SIZE]?CachedInode,
    lock: sync.Spinlock,
    lru_clock: u64,
};
```

Lock ordering: `inode_cache_lock` is acquired AFTER `Ext2.group_lock` if both are needed. The inode cache lock is at position 2.5 in the global ordering (after the filesystem allocation lock, before FileDescriptor.lock).

Dirty inodes must be written back to disk before eviction. The `dirty` flag is set on any inode modification (write, truncate, chmod, utimensat). Eviction calls `io.writeInode()`.

### 3. Ext2 File State (Ext2File in types.zig or ops.zig)

```zig
pub const Ext2File = struct {
    fs: *Ext2,
    inode_num: u32,
    inode: Inode,      // cached copy; refresh from disk on size mismatch
    mode: u32,
    uid: u32,
    gid: u32,
};
```

This is stored as `FileDescriptor.private_data`, matching SFS's `SfsFile` pattern.

### 4. On-Disk Structures (src/fs/ext2/types.zig)

All structures must be `extern struct` for correct ABI layout. ext2 uses little-endian byte order (same as x86_64 native, but aarch64 may need `@byteSwap` on big-endian fields -- verify: standard aarch64 is also little-endian, no swapping needed).

```zig
pub const Superblock = extern struct {
    inodes_count: u32,
    blocks_count_lo: u32,
    r_blocks_count_lo: u32,
    free_blocks_count_lo: u32,
    free_inodes_count: u32,
    first_data_block: u32,
    log_block_size: u32,     // block_size = 1024 << log_block_size
    log_frag_size: u32,
    blocks_per_group: u32,
    frags_per_group: u32,
    inodes_per_group: u32,
    mtime: u32,
    wtime: u32,
    mnt_count: u16,
    max_mnt_count: u16,
    magic: u16,              // 0xEF53
    state: u16,
    errors: u16,
    minor_rev_level: u16,
    lastcheck: u32,
    checkinterval: u32,
    creator_os: u32,
    rev_level: u32,          // 0=original, 1=dynamic (inodes can vary in size)
    def_resuid: u16,
    def_resgid: u16,
    // EXT2_DYNAMIC_REV fields (rev_level >= 1):
    first_ino: u32,          // first non-reserved inode (11 in static rev)
    inode_size: u16,         // size of inode structure (128 in static, can be 256)
    block_group_nr: u16,
    feature_compat: u32,
    feature_incompat: u32,
    feature_ro_compat: u32,
    uuid: [16]u8,
    volume_name: [16]u8,
    last_mounted: [64]u8,
    algo_bitmap: u32,
    _pad: [820]u8,           // rest of 1024-byte superblock
};

pub const GroupDesc = extern struct {
    block_bitmap_lo: u32,
    inode_bitmap_lo: u32,
    inode_table_lo: u32,
    free_blocks_count_lo: u16,
    free_inodes_count_lo: u16,
    used_dirs_count_lo: u16,
    flags: u16,
    _reserved: [8]u8,
    // ext4 64-bit extensions omitted (use lo fields only for basic ext2)
};

pub const Inode = extern struct {
    mode: u16,
    uid: u16,
    size_lo: u32,
    atime: u32,
    ctime: u32,
    mtime: u32,
    dtime: u32,
    gid: u16,
    links_count: u16,
    blocks_lo: u32,           // 512-byte blocks used (not fs blocks)
    flags: u32,
    osd1: u32,
    block: [15]u32,           // [0..11]=direct, [12]=indirect, [13]=double, [14]=triple
    generation: u32,
    file_acl_lo: u32,
    size_hi: u32,             // upper 32 bits of file size (ext2 with LARGE_FILE feature)
    obso_faddr: u32,
    osd2: [12]u8,
    // For inode_size > 128 (dynamic rev):
    extra_isize: u16,
    checksum_hi: u16,
    ctime_extra: u32,
    mtime_extra: u32,
    atime_extra: u32,
    crtime: u32,
    crtime_extra: u32,
    version_hi: u32,
    projid: u32,
};

pub const DirEntry2 = extern struct {
    inode: u32,
    rec_len: u16,             // total length of this entry (including name)
    name_len: u8,
    file_type: u8,            // 0=unknown, 1=regular, 2=dir, 7=symlink, ...
    name: [255]u8,            // actual name, NOT null-terminated, only name_len bytes valid
};

pub const EXT2_MAGIC: u16 = 0xEF53;
pub const ROOT_INODE: u32 = 2;
pub const SUPERBLOCK_OFFSET: u64 = 1024;  // bytes from partition start
```

---

## Integration Points with Existing Components

### VFS Integration (Zero changes to vfs.zig)

Ext2 registers a `vfs.FileSystem` struct exactly as SFS does. The VFS interface is complete and requires no modification. Ext2 must implement all vtable fields that SFS implements:

| VFS Function | SFS implementation | Ext2 implementation |
|---|---|---|
| `open` | sfsOpen | ext2Open (path traversal + inode lookup) |
| `unmount` | sfsUnmount | ext2Unmount (flush dirty inodes, free resources) |
| `unlink` | sfsUnlink | ext2Unlink (dec nlink, free blocks if nlink=0) |
| `stat_path` | sfsStatPath | ext2StatPath (lookup inode, return FileMeta) |
| `chmod` | sfsChmod | ext2Chmod (update inode.mode) |
| `chown` | sfsChown | ext2Chown (update inode.uid/gid) |
| `mkdir` | sfsMkdir | ext2Mkdir (alloc inode, create dir entries "." and "..") |
| `rmdir` | sfsRmdir | ext2Rmdir (verify empty, unlink, free inode) |
| `rename` | sfsRename | ext2Rename (update dir entries atomically) |
| `rename2` | sfsRename2 | ext2Rename2 (NOREPLACE, EXCHANGE flags) |
| `getdents` | sfsGetdents | ext2Getdents (walk DirEntry2 chain in directory blocks) |
| `statfs` | sfsStatfs | ext2Statfs (from superblock free counts) |
| `link` | sfsLink | ext2Link (add dir entry, inc inode nlink) |
| `symlink` | sfsSymlink | ext2Symlink (alloc inode, store target in block 0 or fast symlink) |
| `readlink` | sfsReadlink | ext2Readlink (read target from inode data) |
| `set_timestamps` | sfsSetTimestamps | ext2SetTimestamps (update inode atime/mtime) |
| `truncate` | sfsTruncate | ext2Truncate (free excess blocks, update i_size) |

### FileDescriptor Integration (Zero changes to fd.zig)

Ext2 creates FileDescriptors using `fd.createFd()` exactly as SFS does. The FileOps vtable for ext2 files:

```zig
pub const ext2_file_ops = fd.FileOps{
    .read    = ext2Read,
    .write   = ext2Write,
    .close   = ext2Close,
    .seek    = ext2Seek,
    .stat    = ext2Stat,
    .ioctl   = null,
    .mmap    = null,
    .poll    = null,
    .truncate = ext2FdTruncate,
    .getdents = ext2Getdents,
    .chown   = ext2FdChown,
};

pub const ext2_dir_ops = fd.FileOps{
    .read    = null,
    .write   = null,
    .close   = ext2DirClose,
    .seek    = null,
    .stat    = ext2DirStat,
    .ioctl   = null,
    .mmap    = null,
    .poll    = null,
    .truncate = null,
    .getdents = ext2Getdents,
    .chown   = null,
};
```

### Page Cache Integration

The existing page cache in `src/kernel/fs/page_cache.zig` is keyed by `(file_identifier, page_offset)` where `file_identifier` is set by VFS at open time using `(mount_idx << 32) | lower_32_bits_of_private_data_ptr`. Ext2 gets this for free -- VFS sets `file_identifier` in `Vfs.open()` before returning. No changes to page cache needed.

However, ext2 adds an inode cache for path traversal that the page cache does not cover. The inode cache is internal to ext2 and does not use the VFS page cache (inodes are metadata, not file data).

### init_fs.zig Changes

The only kernel core file that changes:

```zig
// Before:
const sfs_instance = fs.sfs.SFS.init("/dev/sda") catch |err| { ... };
fs.vfs.Vfs.mount("/mnt", sfs_instance) catch |err| { ... };

// After:
const ext2_instance = fs.ext2.Ext2.init("/dev/sda1") catch |err| { ... };
fs.vfs.Vfs.mount("/mnt", ext2_instance) catch |err| { ... };
```

Note: `/dev/sda1` (first partition) rather than `/dev/sda` (raw disk). The ext2 image will be in the first partition of the GPT disk, alongside the ESP FAT partition. This matches real-world usage and avoids formatting the raw disk.

### Partition Scanning (Unchanged)

The existing `src/fs/partitions/root.zig` already scans GPT and registers partitions as `/dev/sda`, `/dev/sda1`, `/dev/sda2` in DevFS. Ext2 opens `/dev/sda1` via `vfs.Vfs.open()` -- the partition scanning already creates this device file. Zero changes to partition code.

### Build System Changes

```zig
// In build.zig, add after disk.img creation:

// Create ext2.img using host mkfs.ext2 (available via e2fsprogs on Linux/macOS via homebrew)
const create_ext2 = b.addSystemCommand(&.{
    "mkfs.ext2",
    "-b", "1024",        // 1024-byte blocks (simplest, mkfs.ext2 default)
    "-L", "zk-root",    // volume label
    "-t", "ext2",
    "-r", "1",           // revision 1 (dynamic inodes, needed for features)
    "ext2.img",
});
// Then embed ext2.img as a second partition in the GPT disk
```

Alternatively, build a simple Zig tool (`tools/make_ext2.zig`) that writes the ext2 binary layout directly, removing the mkfs.ext2 host dependency. This is harder but makes the build fully self-contained.

**Recommendation:** Use `mkfs.ext2` from host (e2fsprogs), which is available on macOS via Homebrew (`brew install e2fsprogs`). Add a build-time check with a clear error message if mkfs.ext2 is not found. The ext2.img is pre-formatted with required structure (superblock, group descriptors, inode tables, root directory) but empty of user files.

The QEMU command line already mounts sfs.img as a VirtIO-SCSI disk. Change this to mount ext2.img:
```
# Before:
"-drive", "file=sfs.img,format=raw,if=none,id=sfsdisk",
"-device", "scsi-hd,drive=sfsdisk,bus=scsi0.0",

# After:
"-drive", "file=ext2.img,format=raw,if=none,id=ext2disk",
"-device", "scsi-hd,drive=ext2disk,bus=scsi0.0",
```

---

## Build Order (Dependency Graph)

The features have the following dependency chain. Each phase must pass its tests before the next begins.

```
Phase 1: Block device abstraction (src/fs/block_dev.zig)
  - Driver-portable read/write without position state
  - No filesystem logic, just wraps partition FileDescriptor
  - Zero risk to existing code (no modifications to existing files)
  - Test: read sector 0 via BlockDevice, compare to raw partition read

Phase 2: Ext2 on-disk types + read-only superblock parse (src/fs/ext2/types.zig, root.zig)
  - Parse superblock, validate magic (0xEF53)
  - Compute block_size = 1024 << log_block_size
  - Validate: groups_count, inodes_per_group, etc.
  - NO write support yet -- mount as read-only
  - Test: Ext2.init() succeeds on a pre-formatted ext2.img

Phase 3: Inode read + indirect block resolution (src/fs/ext2/inode.zig, io.zig)
  - readBlock(block_num) via BlockDevice
  - readInode(inode_num): compute group, offset in inode table, read block, extract Inode
  - resolveBlockNum(file_offset): walk direct -> single -> double -> triple indirect
  - Test: read root inode (inode 2), verify it is a directory

Phase 4: Directory traversal + ext2Open (src/fs/ext2/dir.zig, ops.zig partial)
  - readDirEntry: walk DirEntry2 chain in directory block
  - lookupName(dir_inode, name) -> child inode_num
  - ext2Open: full path traversal from root inode
  - ext2Read: read file data blocks via resolveBlockNum
  - ext2StatPath, ext2Stat: return FileMeta from inode fields
  - Register ext2 at /mnt in init_fs.zig (read-only for now)
  - Test: open and read files from pre-populated ext2.img
  - Test: stat files, verify permissions and sizes

Phase 5: Inode cache (src/fs/ext2/cache.zig)
  - Fixed-size 64-entry inode cache with LRU eviction
  - Integrate into ext2Open and stat_path
  - Test: repeated open of same path hits cache (verify with counter)

Phase 6: Directory listing (getdents, mkdir smoke test as read-only verification)
  - ext2Getdents: iterate DirEntry2 for sys_getdents64
  - ext2Mkdir (read path only): verify /mnt nesting works
  - Test: getdents on /mnt lists files correctly

Phase 7: Write support -- block/inode allocation (src/fs/ext2/alloc.zig)
  - allocBlock: scan group block bitmaps, find free bit, set it, update superblock counts
  - freeBlock: clear bitmap bit, update counts
  - allocInode: scan group inode bitmaps
  - freeInode: clear bitmap bit, zero inode, update counts
  - writeBlock, writeInode (io.zig additions)
  - Test: allocate and immediately free a block -- counts unchanged

Phase 8: Write support -- file create/write/truncate
  - ext2Write: extend inode block map if needed, write data blocks
  - ext2Truncate: free excess blocks, update i_size
  - ext2Unlink: dec nlink, free blocks if nlink=0, free inode
  - ext2Link: inc nlink, add dir entry
  - ext2Close: flush dirty inode to disk
  - Test: create, write, read back, unlink files in /mnt

Phase 9: Full directory write support
  - ext2Mkdir: allocate inode, create "." and ".." entries, add entry in parent
  - ext2Rmdir: verify empty, unlink self from parent, free inode
  - ext2Rename/Rename2: update directory entries atomically
  - ext2Symlink: fast symlink (target fits in inode block[]) or data block
  - ext2Readlink: read symlink target
  - Test: mkdir/rmdir/rename/symlink end-to-end

Phase 10: Metadata operations + mount hardening
  - ext2Chmod, ext2Chown, ext2SetTimestamps: update inode fields, write back
  - ext2Statfs: return superblock free counts as Statfs struct
  - ext2Unmount: flush all dirty inodes, flush dirty group descriptors
  - Superblock write-back: update wtime, mnt_count on mount/unmount
  - Test: chmod/chown/utimensat/statfs on ext2 files

Phase 11: Test migration from SFS
  - Move existing SFS-targeted integration tests to use /mnt (ext2) paths
  - Verify all previously-passing filesystem tests pass on ext2
  - Remove sfs.img from QEMU command line after all tests pass
```

---

## Structural Constraints

### Block Size Considerations

ext2 supports 1024, 2048, and 4096 byte blocks (log_block_size = 0, 1, 2). The mkfs.ext2 default is 1024 bytes. Start with 1024-byte blocks because:
- Simpler: one block = two 512-byte sectors
- The existing partition I/O reads 512-byte sectors; 1024-byte ext2 blocks require two sector reads
- 4096-byte blocks would require 8 sector reads per block, but would halve indirect block overhead for large files

The `io.readBlock()` function must handle the mapping from ext2 block numbers to disk LBAs:
```
lba = partition_start_lba + (block_num * (block_size / 512))
```

The superblock is ALWAYS at byte offset 1024 from the partition start (even if block_size > 1024). This means block 0 is the boot block (unused in most systems), and the superblock starts at byte 1024 which is LBA 2 from the partition start for 512-byte sectors.

### inode_size Variants

Static revision (rev_level=0) has fixed 128-byte inodes. Dynamic revision (rev_level=1) has inode_size from the superblock (128 or 256). The `mkfs.ext2` default with `-r 1` creates 128-byte inodes. Use rev_level=1 with inode_size=128 for the initial implementation. This avoids the complexity of parsing the extended inode fields while still getting dynamic features like larger filename support.

### Lock Ordering for ext2

The ext2 internal locks follow the established pattern from SFS:

```
Ext2.group_lock     (position 2 in global ordering, same as SFS.alloc_lock)
  -- acquire when: reading/writing group descriptors, block/inode bitmaps
  -- do NOT hold while doing disk I/O (io.readBlock calls BlockDevice)

Ext2.inode_cache_lock  (position 2.5)
  -- acquire when: looking up or evicting from InodeCache
  -- always acquired AFTER group_lock if both needed
  -- NEVER acquire group_lock while holding inode_cache_lock

FileDescriptor.lock  (position 3, existing)
  -- acquires during read/write on a specific open file
  -- do NOT call alloc or cache functions while holding this
```

The rule from CLAUDE.md applies: "Refresh State Under Lock." When ext2 reads inode data under `inode_cache_lock`, the size/permissions values are authoritative only for that lock hold. If the caller releases and reacquires the lock, re-read the inode.

### Stack Size Warning

The current kernel stack is 192KB (grown from 96KB in v1.4 due to comptime dispatch table expansion). Ext2 adds no new syscall modules, so dispatch table growth is not a concern. However, `io.readBlock()` uses a 1024-byte stack buffer for single-block reads. For multi-level indirect block resolution (triple-indirect), the call stack reads one indirect block per level: 3 stack allocations of 1024 bytes each = 3KB additional stack depth at maximum. This is well within 192KB.

If inode_size is 256 bytes, `readInode()` reads one full 1024-byte block and extracts one inode from it. This is a stack-local buffer -- safe.

Do NOT put full directory blocks (up to 4096 bytes) on the kernel stack. Allocate from `heap.allocator()` for directory block reads, with `defer allocator.free()`.

### aarch64 Compatibility

ext2 on-disk format is little-endian. Both x86_64 and aarch64 in zk run in little-endian mode. No byte swapping is required for field access on either architecture. The `extern struct` layout is identical on both targets.

The inode cache lock and group lock use `sync.Spinlock`, which already works on both architectures.

### TOCTOU Prevention

Following the CLAUDE.md security rules: after acquiring the inode cache lock and reading an inode, do not release the lock and re-read cached values -- re-read from the cache. For the write path, the inode size must be re-verified inside the alloc_lock before extending blocks:

```zig
// CORRECT: re-check size inside lock before extending
const held = self.group_lock.acquire();
defer held.release();
const current_size = try self.readInodeSizeLocked(inode_num);
if (current_size < required_size) {
    // extend block map
}
```

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Storing Inode Copies Outside the Cache

**What people do:** Copy an inode struct into a local variable, release the cache lock, then use the copy for extended processing.

**Why it's wrong:** Another thread can modify the inode between the copy and the use. This causes TOCTOU bugs: stat sees old size, write uses old block pointers.

**Do this instead:** Hold the inode cache lock while accessing inode fields, or re-read from cache each time the lock is acquired. For open file state (Ext2File), store only `inode_num` as the reference, not a copy of the inode struct. Re-fetch from cache on each operation, refreshing if cache miss.

### Anti-Pattern 2: Reading Entire Directory into a Fixed Stack Buffer

**What people do:** `var dir_buf: [4096]u8 = undefined;` to hold a directory block.

**Why it's wrong:** 4096 bytes on the kernel stack is too large for a function that may be called multiple levels deep during path traversal. With triple-indirect block resolution above it and the syscall dispatch frame below, the stack can exceed safe limits.

**Do this instead:** Allocate directory block buffers from `heap.allocator()` with `defer free`. This matches how SFS handles its batch reads in `ops.zig`.

### Anti-Pattern 3: Writing Superblock on Every Block Allocation

**What people do:** Update `superblock.free_blocks_count_lo` and immediately write the superblock to disk after each `allocBlock()`.

**Why it's wrong:** The superblock is at a fixed location and is written synchronously. Writing it on every block allocation (e.g., during a large file write) causes 100+ synchronous disk writes for a single sys_write call. This is catastrophic for write throughput.

**Do this instead:** Keep the superblock in-memory (in the Ext2 struct). Mark it dirty. Flush to disk only on `ext2Unmount()` and periodically (e.g., every N writes or on `sys_sync`). The group descriptors follow the same pattern.

### Anti-Pattern 4: Using device_fd.position for Multi-Block Reads

**What people do:** Set `device_fd.position = lba * 512` and call `read_fn(device_fd, buf)`, similar to how SFS does it.

**Why it's wrong:** SFS serializes this with `io_lock` because concurrent callers would race on the position field. Ext2 makes far more concurrent block reads during path traversal. Holding `io_lock` for every block read serializes all I/O across all concurrent ext2 operations.

**Do this instead:** Use the `BlockDevice` abstraction (Phase 1) which takes an explicit LBA parameter. Underneath, implement it using the partition FileDescriptor but with local position tracking -- acquire `device_fd.lock`, set position, read, restore position, release lock -- all in one atomic operation. This is still serialized but the critical section is shorter than holding the lock across multiple reads.

### Anti-Pattern 5: Importing SFS into ext2 Code

**What people do:** Reuse SFS alloc.zig or io.zig from ext2 to avoid duplication.

**Why it's wrong:** SFS uses 512-byte sectors as its block unit and has an SFS-specific superblock format. Sharing code between SFS and ext2 creates coupling that makes it harder to deprecate SFS later.

**Do this instead:** Ext2 has its own io.zig, alloc.zig, and types.zig. If shared abstractions are needed (e.g., bitmap manipulation), create a generic `src/lib/bitmap.zig` utility that both can import independently.

---

## Migration Path (ext2 alongside SFS)

The PROJECT.md specifies "incremental migration path (ext2 alongside SFS, tests migrate over time)." This means both filesystems coexist during development:

- **Phase 1-6 (read-only ext2):** SFS remains at `/mnt`, ext2 at `/mnt2` (or test mount). Existing tests continue using SFS.
- **Phase 7-10 (writable ext2):** Both mounted simultaneously. New tests target ext2 paths. SFS tests continue passing.
- **Phase 11 (migration complete):** ext2 takes `/mnt`, SFS unmounted. SFS tests repointed to ext2 paths.

VFS supports 8 mount slots. Adding ext2 at `/mnt2` consumes one slot (currently: `/`, `/dev`, `/mnt` = 3 used, 5 free). This is not a constraint.

---

## Sources

- Direct source analysis: `src/fs/vfs.zig`, `src/fs/sfs/` (all files), `src/fs/partitions/root.zig`, `src/kernel/fs/fd.zig`, `src/kernel/core/init_fs.zig`, `src/kernel/fs/page_cache.zig`
- ext2 specification: https://www.nongnu.org/ext2-docs/ (The Second Extended File System, Remy Card et al.)
- Linux kernel ext2 source reference (via knowledge): `fs/ext2/` in Linux 6.x
- CLAUDE.md project constraints: lock ordering, security patterns, Zig 0.16.x compat

---

*Architecture research for: ext2 filesystem integration in zk microkernel*
*Researched: 2026-02-22*
