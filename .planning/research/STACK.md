# Technology Stack: ext2 Filesystem Implementation

**Project:** zk kernel -- v2.0 ext2 milestone
**Domain:** Kernel filesystem: ext2 on-disk format, block device abstraction, VFS integration
**Researched:** 2026-02-22
**Confidence:** HIGH (specification-grounded) / MEDIUM (Zig-specific patterns)

---

## Executive Summary

The v2.0 milestone adds ext2 filesystem support to replace SFS. The work is purely in-kernel Zig with no new runtime dependencies. What it requires is precise understanding of six things:

1. **The ext2 on-disk format** -- superblock, block groups, inodes, directory entries, block allocation bitmaps.
2. **A block device abstraction layer** -- thin wrapper over the existing file-descriptor-based I/O that SFS already uses, lifted into a reusable interface.
3. **Host tooling for disk image creation** -- `mke2fs` (from `e2fsprogs`, Homebrew keg-only on macOS) replaces the SFS raw `dd`-and-format approach.
4. **QEMU drive configuration** -- the existing `sfs.img` drive attachment in `build.zig` becomes an ext2-formatted image; QEMU does not care which filesystem is inside the raw image.
5. **Zig struct layout rules** -- `extern struct` for on-disk structures, `std.mem.readInt(.little)` for individual fields on big-endian hosts, `@byteSwap` for bulk field conversions; avoid `packed struct` for multi-field disk structures.
6. **VFS interface compatibility** -- ext2 must implement the existing `vfs.FileSystem` interface; no VFS changes are needed.

This milestone does NOT require: journaling (ext3), extents (ext4), new drivers, new lock primitives, or changes to the page cache interface.

---

## Core Technologies

### On-Disk Format Reference

| Resource | Version / Date | Purpose | Why Essential |
|----------|---------------|---------|---------------|
| Linux kernel `fs/ext2/ext2.h` | Linux 6.x (current) | Authoritative C struct definitions for all ext2 on-disk structures | Exact field names, byte offsets, and sizes needed for Zig `extern struct` declarations; the kernel header is the ground truth for the format |
| `docs.kernel.org/filesystems/ext2.html` | Current kernel docs | Feature flag semantics, block group layout, limits | Documents which feature flags to check before mounting, block-to-group formulas, and the reserved inode range |
| `nongnu.org/ext2-doc/ext2.html` | Hurd project ext2 doc | Complete field-by-field superblock / inode / directory entry reference | Most complete public documentation of field semantics; covers fields the Linux header leaves undocumented |
| OSDev Wiki ext2 article | Community-maintained | Worked examples of block addressing, inode lookup, directory traversal | Practical walkthrough of the algorithms needed for implementation |

**Key constants verified from Linux `fs/ext2/ext2.h`:**

```
EXT2_SUPER_MAGIC      = 0xEF53        -- magic in superblock.s_magic (le16)
EXT2_ROOT_INO         = 2             -- root directory inode number
EXT2_GOOD_OLD_FIRST_INO = 11          -- first non-reserved inode
EXT2_GOOD_OLD_INODE_SIZE = 128        -- inode size in bytes (revision 0)
EXT2_MIN_BLOCK_SIZE   = 1024          -- smallest valid block size (1KB)
EXT2_MAX_BLOCK_SIZE   = 4096          -- standard maximum (4KB)
s_first_data_block    = 1 for 1KB blocks, 0 for >= 2KB blocks
```

**Superblock location:** Fixed at byte offset 1024 from device start, size 1024 bytes. Stored in little-endian. The superblock is at block 1 when block size is 1KB, block 0 when block size is 2KB or 4KB.

**Block group layout (per group):**
```
[superblock backup] [group descriptor table backup] [block bitmap] [inode bitmap] [inode table] [data blocks]
```
Superblock and GDT backups appear only in group 0 (always) and in selected groups when `SPARSE_SUPER` feature is set (groups 1 and powers of 3, 5, 7).

**inode block pointer scheme:**
```
i_block[0..11]   -- 12 direct block pointers
i_block[12]      -- single-indirect: points to a block of block numbers
i_block[13]      -- double-indirect
i_block[14]      -- triple-indirect
```
For a 4KB block size: max file reachable via direct pointers = 12 * 4096 = 48KB; via single-indirect = 48KB + 1024*4 = ~4MB. For the MVP, supporting files up to double-indirect (roughly 4GB at 4KB blocks) covers all practical test cases.

---

### Host Tooling

| Tool | Version | Source | Purpose | macOS Install |
|------|---------|--------|---------|--------------|
| `mke2fs` / `mkfs.ext2` | 1.47.3 (current) | e2fsprogs (Homebrew) | Create ext2-formatted raw disk images for QEMU | `brew install e2fsprogs` |
| `e2fsck` | 1.47.3 | e2fsprogs (Homebrew) | Verify created images are valid, debug layout issues | Bundled with e2fsprogs |
| `debugfs` | 1.47.3 | e2fsprogs (Homebrew) | Inspect ext2 image contents interactively (list inodes, dump blocks) | Bundled with e2fsprogs |
| `e2ls` / `e2cp` | current | e2tools (Homebrew) | List and copy files in ext2 images without mounting (useful for CI) | `brew install e2tools` |

**macOS path note:** e2fsprogs is keg-only on Homebrew (does not link into `/opt/homebrew/bin`). The correct path pattern for build scripts and CI:

```bash
$(brew --prefix e2fsprogs)/sbin/mkfs.ext2
$(brew --prefix e2fsprogs)/sbin/mke2fs
$(brew --prefix e2fsprogs)/sbin/e2fsck
$(brew --prefix e2fsprogs)/sbin/debugfs
```

On Apple Silicon this resolves to `/opt/homebrew/opt/e2fsprogs/sbin/mkfs.ext2`. On Intel Mac it resolves to `/usr/local/opt/e2fsprogs/sbin/mkfs.ext2`. Using `brew --prefix` is the correct cross-architecture pattern -- do not hardcode the prefix.

**Creating a test ext2 image (replaces `sfs.img` creation):**

```bash
# Create a 64MB raw ext2 image with 4KB blocks, revision 1, no journaling
# -t ext2: force ext2 (no journal, no extents)
# -b 4096: 4KB block size (simplest for implementation)
# -L zk-ext2: volume label
# -O ^has_journal,^extent,^huge_file,^flex_bg,^metadata_csum: disable ext3/ext4 features
dd if=/dev/zero of=ext2.img bs=1M count=64
$(brew --prefix e2fsprogs)/sbin/mkfs.ext2 -b 4096 -L zk-ext2 \
  -O ^has_journal,^extent,^huge_file,^flex_bg,^metadata_csum \
  -t ext2 ext2.img

# Optionally populate with test files before boot:
$(brew --prefix e2fsprogs)/sbin/debugfs -w ext2.img << 'EOF'
mkdir testdir
write /dev/stdin testdir/hello.txt
EOF
```

**Why 4KB blocks:** Matches the kernel's page size. All block reads and writes align with the existing page cache (4KB pages). A 1KB block size forces multi-block reads for every page cache fill, adding complexity with no benefit in the test environment.

**Why disable ext3/ext4 features explicitly:** Without `-O ^has_journal`, `mke2fs` may default to creating an ext3 filesystem (journal inode 8 allocated). The kernel must refuse to mount if `s_feature_incompat` contains `HAS_JOURNAL (0x0004)` or `EXTENTS (0x0040)` -- features the ext2 driver will not implement. The `-O ^...` flags ensure a clean ext2 image. Validate after creation: `e2fsck -n ext2.img` must report no errors.

---

### QEMU Drive Configuration

The existing `build.zig` already attaches `sfs.img` as a SCSI drive on aarch64 and an AHCI drive on x86_64. Replacing SFS with ext2 requires only renaming the image file and updating the Zig build step that creates it. No QEMU device model changes are needed.

**Current (sfs.img, aarch64):**
```zig
run_cmd.addArgs(&.{
    "-device", "virtio-scsi-pci,id=scsi0",
    "-drive", "file=sfs.img,format=raw,if=none,id=sfsdisk",
    "-device", "scsi-hd,drive=sfsdisk,bus=scsi0.0",
});
```

**New (ext2.img, aarch64) -- no device model change:**
```zig
run_cmd.addArgs(&.{
    "-device", "virtio-scsi-pci,id=scsi0",
    "-drive", "file=ext2.img,format=raw,if=none,id=ext2disk",
    "-device", "scsi-hd,drive=ext2disk,bus=scsi0.0",
});
```

QEMU presents the raw image as a block device to the kernel regardless of its filesystem content. The kernel's VirtIO-SCSI or AHCI driver sees raw sectors; the ext2 driver interprets those sectors according to the ext2 format.

**Build step dependency chain (new):**

```
[dd creates blank ext2.img]
    --> [mke2fs formats it as ext2]
        --> [optional: debugfs/e2cp populates test files]
            --> [zig build run: QEMU attaches ext2.img]
```

This replaces the existing SFS `format()` call at mount time. SFS formatted itself on first boot when no magic was found. ext2 must be pre-formatted on the host because ext2's initialization requires writing the full superblock, block group descriptors, and bitmaps -- a non-trivial operation that is better done once on the host with a verified tool.

---

### Zig Struct Layout for On-Disk Structures

**Rule: use `extern struct` for all ext2 on-disk structures.**

`extern struct` guarantees C-compatible layout: fields in declaration order, no hidden padding, alignment determined by the field's type. This matches how `SFS.Superblock` and `SFS.DirEntry` are already declared. `packed struct` is wrong for multi-field structures because Zig's `packed struct` packs bits, not bytes -- it is for bit-field registers, not disk structures.

```zig
// CORRECT: extern struct for on-disk disk structures
pub const Superblock = extern struct {
    s_inodes_count:      u32,   // little-endian on disk
    s_blocks_count:      u32,
    s_r_blocks_count:    u32,
    s_free_blocks_count: u32,
    s_free_inodes_count: u32,
    s_first_data_block:  u32,
    s_log_block_size:    u32,   // block_size = 1024 << s_log_block_size
    s_log_frag_size:     i32,
    s_blocks_per_group:  u32,
    s_frags_per_group:   u32,
    s_inodes_per_group:  u32,
    s_mtime:             u32,
    s_wtime:             u32,
    s_mnt_count:         u16,
    s_max_mnt_count:     i16,
    s_magic:             u16,   // must equal 0xEF53
    s_state:             u16,
    s_errors:            u16,
    s_minor_rev_level:   u16,
    s_lastcheck:         u32,
    s_checkinterval:     u32,
    s_creator_os:        u32,
    s_rev_level:         u32,
    s_def_resuid:        u16,
    s_def_resgid:        u16,
    // EXT2_DYNAMIC_REV fields (s_rev_level >= 1):
    s_first_ino:         u32,
    s_inode_size:        u16,
    s_block_group_nr:    u16,
    s_feature_compat:    u32,
    s_feature_incompat:  u32,
    s_feature_ro_compat: u32,
    s_uuid:              [16]u8,
    s_volume_name:       [16]u8,
    s_last_mounted:      [64]u8,
    s_algo_bitmap:       u32,
    // Performance hints:
    s_prealloc_blocks:   u8,
    s_prealloc_dir_blocks: u8,
    _pad1:               [2]u8,
    // Journaling (ignore, must be zero for ext2):
    s_journal_uuid:      [16]u8,
    s_journal_inum:      u32,
    s_journal_dev:       u32,
    s_last_orphan:       u32,
    // Hash seed and default hash version:
    s_hash_seed:         [4]u32,
    s_def_hash_version:  u8,
    _pad2:               [3]u8,
    s_default_mount_opts: u32,
    s_first_meta_bg:     u32,
    _pad3:               [760]u8,  // pad to 1024 bytes total
};
comptime { std.debug.assert(@sizeOf(Superblock) == 1024); }
```

**Endianness:** ext2 stores all multi-byte fields in little-endian byte order. On an aarch64 or x86_64 host (both little-endian), a raw `@ptrCast` of a sector buffer to `*const Superblock` reads fields correctly. On a hypothetical big-endian host, each field would need `@byteSwap`. Since zk targets x86_64 and aarch64 (both LE), direct cast is safe, but document the assumption explicitly with a `comptime` assert:

```zig
comptime {
    // ext2 is little-endian on disk; this driver assumes a little-endian host.
    // If aarch64 is ever run in BE mode, add @byteSwap to every field read.
    std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
}
```

**Reading a struct from a sector buffer (safe pattern):**

```zig
var buf: [512]u8 align(4) = undefined;
try readSector(self, lba, &buf);
// Safe: extern struct, LE host, buffer aligned to u32
const sb: *const Superblock = @ptrCast(@alignCast(&buf));
const magic = sb.s_magic;  // reads correctly on LE host
```

This is identical to the existing SFS pattern (`sfs/root.zig:51`).

**Block group descriptor (32 bytes, array immediately after superblock block):**

```zig
pub const GroupDesc = extern struct {
    bg_block_bitmap:      u32,  // block address of block usage bitmap
    bg_inode_bitmap:      u32,  // block address of inode usage bitmap
    bg_inode_table:       u32,  // block address of inode table start
    bg_free_blocks_count: u16,
    bg_free_inodes_count: u16,
    bg_used_dirs_count:   u16,
    bg_pad:               u16,
    bg_reserved:          [3]u32,
};
comptime { std.debug.assert(@sizeOf(GroupDesc) == 32); }
```

**Inode (128 bytes for revision 0; use `s_inode_size` from superblock for revision 1+):**

```zig
pub const Inode = extern struct {
    i_mode:        u16,     // file type (upper 4 bits) + permissions (lower 12)
    i_uid:         u16,     // owner UID (low 16 bits)
    i_size:        u32,     // file size in bytes (low 32 bits; high 32 in i_dir_acl for regular files)
    i_atime:       u32,
    i_ctime:       u32,
    i_mtime:       u32,
    i_dtime:       u32,
    i_gid:         u16,
    i_links_count: u16,
    i_blocks:      u32,     // count of 512-byte sectors allocated (NOT block-size blocks)
    i_flags:       u32,
    i_osd1:        u32,     // OS-specific
    i_block:       [15]u32, // [0..11]=direct, [12]=indirect, [13]=double-indirect, [14]=triple-indirect
    i_generation:  u32,
    i_file_acl:    u32,     // extended attributes block (0 if none)
    i_dir_acl:     u32,     // for regular files: high 32 bits of size (if LARGE_FILE feature)
    i_faddr:       u32,
    i_osd2:        [12]u8,  // OS-specific (12 bytes)
};
comptime { std.debug.assert(@sizeOf(Inode) == 128); }
```

**Directory entry (variable length, 4-byte aligned):**

```zig
pub const DirEntry = extern struct {
    inode:    u32,  // inode number (0 = unused entry)
    rec_len:  u16,  // length of this directory entry (includes header + name)
    name_len: u8,   // length of the name field (NOT null-terminated on disk)
    file_type: u8,  // 0=unknown 1=regular 2=dir 3=chardev 4=blkdev 5=fifo 6=socket 7=symlink
    // name[name_len] follows immediately -- NOT part of the struct, read separately
};
comptime { std.debug.assert(@sizeOf(DirEntry) == 8); }
// name_len <= 255; rec_len >= 8 + name_len, padded to 4-byte boundary
// rec_len of the last entry in a block spans to the end of the block
```

**Directory traversal:** Walk the block's byte slice, reading a `DirEntry` header at each offset, then reading `name_len` bytes immediately after. Advance by `rec_len` (not by header size) to find the next entry. An entry with `inode == 0` is deleted and must be skipped.

---

### Block Device Abstraction Layer

The existing SFS I/O layer (`sfs/io.zig`) already implements the correct pattern: acquire `io_lock`, set `device_fd.position = lba * sector_size`, call `read_fn` or `write_fn`, release lock. ext2 needs this same abstraction lifted into a shared module so the ext2 driver does not duplicate the lock-position-read-unlock boilerplate.

**Proposed interface (`src/fs/block_dev.zig`):**

```zig
pub const BlockDevice = struct {
    device_fd: *fd.FileDescriptor,
    block_size: u32,          // ext2 block size (1024, 2048, or 4096)
    io_lock: sync.Spinlock,

    /// Read a single block by block number into buf.
    /// buf must be exactly block_size bytes.
    pub fn readBlock(self: *BlockDevice, block_num: u32, buf: []u8) !void {
        std.debug.assert(buf.len == self.block_size);
        const byte_offset: u64 = @as(u64, block_num) * self.block_size;
        const held = self.io_lock.acquire();
        defer held.release();
        self.device_fd.position = byte_offset;
        // ... read via ops.read ...
    }

    /// Write a single block.
    pub fn writeBlock(self: *BlockDevice, block_num: u32, buf: []const u8) !void { ... }
};
```

This is ~60 lines of code, not a new library. It replaces the `readSector`/`writeSector` functions in `sfs/io.zig` with a block-size-aware variant. SFS can be migrated to use it later; for now, ext2 is its first consumer.

**Why abstract this now:** SFS reads 512-byte sectors directly. ext2 reads variable-size blocks (1KB, 2KB, or 4KB). The existing SFS functions cannot be reused without modification. A thin `BlockDevice` wrapper avoids duplicating the position-lock-read-unlock pattern.

---

### VFS Integration Points

ext2 must implement the `vfs.FileSystem` interface defined in `src/fs/vfs.zig`. All 17 function pointers in the interface apply. The mapping from ext2 internals to the interface:

| VFS Method | ext2 Implementation |
|------------|-------------------|
| `open` | lookup inode via path, create `FileDescriptor` with ext2 file ops |
| `unlink` | decrement `i_links_count`; if 0, free inode and data blocks |
| `stat_path` | lookup inode, fill `FileMeta` from inode fields |
| `chmod` | update `i_mode` in inode |
| `chown` | update `i_uid`, `i_gid` in inode |
| `statfs` | read superblock, fill `Statfs` with block/inode counts |
| `rename` | update parent directory entries; no data block movement |
| `rename2` | same + RENAME_NOREPLACE / RENAME_EXCHANGE flag checks |
| `truncate` | free data blocks beyond new size; update `i_size` |
| `mkdir` | allocate inode with `S_IFDIR`, create `.` and `..` entries |
| `rmdir` | verify directory is empty; free inode and directory block |
| `getdents` | iterate directory block, emit `linux_dirent64` entries |
| `link` | add entry in target directory pointing to source inode; increment `i_links_count` |
| `symlink` | allocate inode with `S_IFLNK`; write target path to data block (or inline in inode if < 60 bytes) |
| `readlink` | read symlink inode's data block (or inline field) |
| `set_timestamps` | update `i_atime`, `i_mtime` in inode |

**Mount point:** ext2 mounts at `/mnt` (same as SFS today). The mount call in kernel init changes from `sfs.init("/dev/sda")` to `ext2.mount("/dev/sda")`. No other call sites change because the VFS interface abstracts the filesystem.

**FileDescriptor ops for ext2 files:**
```zig
pub const ext2_file_ops = fd.FileOps{
    .read  = ext2Read,
    .write = ext2Write,
    .seek  = ext2Seek,  // or use generic lseek with fd.position
    .stat  = ext2Stat,
    .close = ext2Close,
    .poll  = null,       // regular files: always readable
};
```

**Page cache interaction:** The existing page cache (`src/kernel/fs/page_cache.zig`) uses `file_identifier` from `FileDescriptor` as the cache key. ext2 file descriptors must set a unique `file_identifier` -- use `(mount_idx << 32) | inode_number`. This is the same pattern as SFS. The page cache's `ReadFn` / `WriteFn` interface is satisfied by `ext2Read` / `ext2Write`.

---

## Supporting Libraries

No new libraries are required. All implementation is in-kernel Zig using existing infrastructure.

| Existing Module | How ext2 Uses It |
|----------------|-----------------|
| `sync.Spinlock` | `io_lock` on `BlockDevice`, `alloc_lock` on `Ext2FS` struct |
| `heap.allocator()` | Allocate `Ext2FS` context, inode cache entries |
| `fd.FileDescriptor` + `fd.FileOps` | ext2 file descriptor with read/write/stat/close ops |
| `vfs.FileSystem` | Interface that ext2 implements |
| `page_cache.PageCache` | Cache ext2 data blocks (4KB pages align perfectly with 4KB ext2 blocks) |
| `pmm` | Not needed for ext2 (no DMA buffers; block reads go through fd ops) |

---

## Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| `debugfs` (from e2fsprogs) | Interactive ext2 image inspection: dump superblock (`show_super_stats`), list inode table (`ls -l /`), read raw blocks (`block_dump`) | Essential for debugging -- verifies what the host tool wrote before the kernel reads it |
| `e2fsck -n` | Validate image integrity without modifying it | Run after `mke2fs` in CI to catch image creation failures |
| `hexdump -C ext2.img \| head -100` | Inspect raw bytes at known offsets (superblock at 1024, magic at 1080 = 0x53 0xEF) | Quick sanity check |
| `xxd -s 1024 -l 256 ext2.img` | Read superblock bytes for manual struct comparison | Verifies endianness assumptions |
| `e2ls ext2.img:/` | List root directory of ext2 image | From `e2tools` package; works without mounting |
| `e2cp` | Copy files into ext2 image from host | Populate test files without mounting |

---

## Alternatives Considered

| Category | Recommended | Alternative | Why Not Alternative |
|----------|-------------|-------------|---------------------|
| Block size for test images | 4KB (`-b 4096`) | 1KB (`-b 1024`) | 1KB blocks require reading 4 sectors per page cache page; 4KB blocks align with page size, simplifying cache integration |
| Superblock struct layout | `extern struct` | `packed struct` | `packed struct` packs bits; fields would not be at correct byte offsets. `extern struct` gives C layout guarantees. All existing SFS structs use `extern struct`. |
| Endianness handling | Rely on LE host (aarch64 and x86_64 are both LE) with comptime assert | `std.mem.readInt(.little)` on every field | Per-field `readInt` is correct but verbose for 40+ fields. The LE host assert + direct cast is the same approach SFS uses and is safe for the current target set. |
| Image pre-population | `mke2fs` on host + `e2cp` or `debugfs` | Write files from kernel on first boot | First-boot formatting requires implementing the full block allocator before the VFS layer works; pre-formatted images allow testing read paths before write paths |
| QEMU device model | Reuse existing VirtIO-SCSI (aarch64) / AHCI (x86_64) | Add a virtio-blk device | VirtIO-SCSI and AHCI drivers already expose `/dev/sda`; adding virtio-blk would require a new driver. The existing devices work fine for ext2. |
| ext2 revision | Revision 1 (dynamic, default from `mke2fs`) | Revision 0 (static) | Revision 0 has fixed 128-byte inodes, no feature flags, and a hardcoded first inode of 11. Revision 1 is what `mke2fs` creates by default and is what real-world ext2 tools produce. Implementation must handle both but test with Revision 1 images. |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `packed struct` for multi-field disk structures | Zig `packed struct` packs bits from a backing integer; fields are NOT at C byte offsets | `extern struct` |
| Hardcoded e2fsprogs path (`/opt/homebrew/opt/e2fsprogs/sbin/mke2fs`) | Breaks on Intel Mac and Linux CI | `$(brew --prefix e2fsprogs)/sbin/mke2fs` in shell scripts; detect at configure time in `build.zig` |
| Mounting ext2 images on macOS host | macOS has no native ext2 driver; FUSE-ext2 exists but adds CI complexity | Use `debugfs`/`e2ls`/`e2cp` to inspect and populate images without mounting |
| ext3 or ext4 feature flags in the test image | `HAS_JOURNAL` (0x4), `EXTENTS` (0x40), `HUGE_FILE` (0x8), `META_BG` (0x10) in `s_feature_incompat` require ext3/ext4 kernel code | Explicitly disable with `mke2fs -O ^has_journal,^extent,...` and validate the kernel refuses to mount images with unknown `INCOMPAT` flags |
| Reading the inode table for inode 0 | Inode 0 does not exist in ext2 (inodes are 1-based); inodes 1-10 are reserved | Always subtract 1 from inode number before indexing: `(inode_num - 1) % s_inodes_per_group` |
| Storing the inode number in `DirEntry.inode` using 0 to mean "root" | Inode 0 = deleted/unused entry; root is always inode 2 | Check `DirEntry.inode == 0` means the entry is deleted; root directory is `EXT2_ROOT_INO = 2` |

---

## Stack Patterns by Phase

**Phase: read-only mount (superblock parse, inode lookup, directory traversal):**
- `extern struct Superblock`, `extern struct GroupDesc`, `extern struct Inode`, `extern struct DirEntry` -- verified sizes with `comptime` asserts
- `BlockDevice.readBlock()` -- thin wrapper over existing fd-based I/O
- Path resolution: walk directory entries from inode 2, matching path components
- VFS `open`, `stat_path`, `getdents` -- implement these three first; they are sufficient to pass all existing SFS read tests

**Phase: write support (block/inode allocation, write, create, delete):**
- Bitmap allocation: read block bitmap block, scan for free bit, set bit, write block back
- Inode allocation: read inode bitmap block, scan, set bit, write inode
- Directory entry modification: read directory block, find insertion point, write new `DirEntry`
- Lock ordering: `alloc_lock` (bitmap updates) before `io_lock` (block writes) -- same ordering as SFS

**Phase: build system integration:**
- Add `build.zig` step: run `$(brew --prefix e2fsprogs)/sbin/mke2fs` to create `ext2.img` at build time
- Replace `sfs.img` QEMU argument with `ext2.img`
- Add `build.zig` option `-Dext2-size=64` (MB) for configurable image size
- CI: `apt-get install e2fsprogs` on Linux runners; `brew install e2fsprogs` on macOS runners

---

## Version Compatibility

| Component | Version | Compatibility Notes |
|-----------|---------|---------------------|
| Zig | 0.16.x nightly | `extern struct` behavior is stable since 0.10.x; `@sizeOf` comptime asserts work correctly |
| e2fsprogs / mke2fs | 1.47.3 (Homebrew), >= 1.42 (Linux) | The ext2 on-disk format has been stable since Linux 2.0; any e2fsprogs >= 1.42 produces compatible images |
| QEMU | Current Homebrew | No version-specific dependency; raw file format is stable |
| ext2 format revision | Revision 1 (dynamic) | Revision 0 images can appear on old hardware; code must check `s_rev_level` and handle both |

---

## Sources

- `https://github.com/torvalds/linux/blob/master/fs/ext2/ext2.h` -- authoritative C struct definitions for all ext2 on-disk structures; field names, types, and constants verified directly from kernel source (HIGH confidence)
- `https://docs.kernel.org/filesystems/ext2.html` -- Linux kernel ext2 documentation; feature flag semantics, block group formulas, filesystem limits (HIGH confidence)
- `https://www.nongnu.org/ext2-doc/ext2.html` -- GNU Hurd ext2 specification; most complete field-by-field documentation (HIGH confidence, but slightly behind Linux kernel for edge cases)
- `https://formulae.brew.sh/formula/e2fsprogs` -- confirmed e2fsprogs is keg-only, current version 1.47.3, available via Homebrew (HIGH confidence)
- `https://e2fsprogs.sourceforge.net/` -- upstream e2fsprogs project confirming version 1.47.3 and tool set (HIGH confidence)
- Codebase analysis of `src/fs/sfs/`, `src/fs/vfs.zig`, `src/kernel/fs/page_cache.zig`, `build.zig` -- direct inspection; findings are observable facts, not inferences (HIGH confidence)

---

*Stack research for: zk ext2 filesystem implementation*
*Researched: 2026-02-22*
