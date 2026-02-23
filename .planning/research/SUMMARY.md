# Project Research Summary

**Project:** zk kernel -- v2.0 ext2 milestone
**Domain:** Kernel filesystem: ext2 on-disk format, block device abstraction, VFS integration
**Researched:** 2026-02-22
**Confidence:** HIGH

## Executive Summary

The v2.0 milestone replaces SFS with ext2 as the writable filesystem mounted at `/mnt`. ext2 is a stable, fully-specified format with authoritative sources (Linux kernel headers, e2fsprogs documentation, Hurd specification), so the research confidence is high across all areas. The recommended approach is a phased incremental migration: implement read-only ext2 first, validate it against the existing VFS interface without touching write paths, then add write support, and finally migrate the SFS test suite to target ext2. The VFS interface (`vfs.zig`) requires zero changes; ext2 registers as a `vfs.FileSystem` vtable exactly as SFS does today.

The dominant risk is not format complexity -- ext2 is well understood -- but implementation discipline in three areas: lock ordering (the same deadlock SFS suffered at v1.1 is easy to recreate in ext2's more complex allocation path), block-number-to-LBA conversion (passing ext2 logical block numbers directly as 512-byte sector LBAs silently reads from wrong disk offsets and is hard to diagnose), and page cache `file_identifier` assignment (must use inode number, not heap pointer, to avoid stale cache hits after file deletion and recreation). Each of these has a documented fix pattern derived from how SFS was corrected.

The build system work is a prerequisite blocker that must happen before any kernel code can be tested: `mke2fs` (from e2fsprogs, Homebrew keg-only on macOS) must format `ext2.img` as a build step, and the QEMU invocation must attach that image. Without this, all ext2 integration tests return ENOENT and look like implementation bugs rather than missing infrastructure.

---

## Key Findings

### Recommended Stack

No new runtime dependencies are required. The implementation is pure in-kernel Zig using existing infrastructure (spinlocks, heap allocator, fd layer, VFS interface, page cache). The only new host-side tooling is `e2fsprogs` (`brew install e2fsprogs`), which provides `mke2fs`, `e2fsck`, and `debugfs` for creating, validating, and inspecting ext2 disk images. The e2fsprogs binaries are keg-only on Homebrew; build scripts must use `$(brew --prefix e2fsprogs)/sbin/mke2fs` rather than a hardcoded path, since the prefix differs between Apple Silicon (`/opt/homebrew`) and Intel Mac (`/usr/local`).

Use 4KB block size (`mke2fs -b 4096`) for all test images. This aligns ext2 blocks with the page cache's 4KB pages, avoiding multi-sector reads per cache fill. Create revision 1 (dynamic) ext2 images with journaling and extent features explicitly disabled (`-O ^has_journal,^extent,^huge_file,^flex_bg,^metadata_csum`) to ensure a clean ext2 format that the kernel can refuse to mount if unknown INCOMPAT flags appear.

**Core technologies:**
- `extern struct` for all on-disk types (Superblock, GroupDesc, Inode, DirEntry2) -- guarantees C-compatible layout with no hidden padding; `comptime` size assertions (`@sizeOf(Superblock) == 1024`) catch mistakes at compile time
- `mke2fs` / `e2fsprogs` (Homebrew keg-only) -- host-side image creation; `debugfs` for inspection; `e2fsck -n` for post-test validation without modifying the image
- Existing `sync.Spinlock`, `heap.allocator()`, `fd.FileDescriptor`, `vfs.FileSystem`, `page_cache.PageCache` -- all reused unchanged; no new kernel primitives required
- QEMU raw drive attachment -- no QEMU device model changes needed; rename `sfs.img` to `ext2.img`, same VirtIO-SCSI (aarch64) / AHCI (x86_64) device already in use

### Expected Features

The feature set splits cleanly into two phases with a hard dependency boundary: the entire read path must work before any write path begins. Both phases are required for fully replacing SFS. The only genuinely deferrable items are triply-indirect blocks (files > 4GB), slow symlinks (target > 60 bytes), and symlink following in the VFS path walker (a broader VFS redesign).

**Must have -- Phase 1 (read-only, enables testing):**
- Superblock parse, magic check (0xEF53), block size derivation, INCOMPAT/RO_COMPAT feature flag gating
- Block group descriptor table parse (locates bitmaps and inode tables)
- Inode read routine (revision 0 and revision 1; handles variable `s_inode_size`)
- Direct + singly + doubly indirect block reads (covers files up to ~4GB at 4KB blocks)
- Directory entry parsing using `rec_len` as stride (not `name_len`), with FILETYPE feature flag handling
- Nested directory traversal via `std.mem.tokenizeScalar` (not `split`) to skip leading-slash empty component
- `stat_path`, `statfs`, `getdents` -- minimum viable VFS operations for ls, stat, df
- Fast symlink read (target stored inline in `i_block[]`, no data block allocated)
- Build system: `mke2fs` step in `build.zig` + `ext2.img` attached in QEMU args
- VFS mount registration at `/mnt` (or `/mnt2` during development alongside SFS)

**Must have -- Phase 2 (read-write, full SFS replacement):**
- Block bitmap alloc/free and inode bitmap alloc/free (two-phase pattern: scan under lock, I/O outside lock)
- File create (`open(O_CREAT)`), write (block extension on boundary crossing), truncate, unlink
- Directory create (`mkdir`) and remove (`rmdir`)
- Rename, hard link, fast symlink write
- `chmod`, `chown`, `set_timestamps`, superblock state tracking (`s_state` dirty/clean on mount/unmount)

**Defer to post-milestone:**
- Triply indirect block reads (files > 4GB; no current test requires this)
- Slow symlinks (target > 60 bytes; rare in practice)
- Symlink following in VFS `open` (requires broader VFS path-walker redesign)
- HTree directory indexing (treat all directories as linear scan; HTree is COMPAT, not INCOMPAT -- safe to ignore)

### Architecture Approach

ext2 integrates as a new `vfs.FileSystem` implementation under the existing layered stack: syscalls -> VFS -> FileDescriptor -> block device -> storage driver. No layer in this stack changes. The new code lives entirely in `src/fs/ext2/` (eight files: `root.zig`, `types.zig`, `io.zig`, `inode.zig`, `dir.zig`, `alloc.zig`, `cache.zig`, `ops.zig`) plus a new shared `src/fs/block_dev.zig` abstraction. Only two existing files are modified: `src/kernel/core/init_fs.zig` (replace `SFS.init` with `Ext2.init`) and `build.zig` (add `mke2fs` step and rename drive).

The inode cache (`cache.zig`, fixed 64-entry array with LRU eviction) is the one architectural addition beyond what SFS has. Path traversal requires an inode read per path component; without a cache, opening `/mnt/a/b/c/d/e.txt` requires 5+ disk reads just for inodes. The cache uses `inode_cache_lock` at position 2.5 in the global lock ordering (after `group_lock` at 2.0, before `FileDescriptor.lock` at 3). The `file_identifier` for the page cache must be set to `(mount_idx << 32) | inode_num` after VFS assigns the pointer-based default.

**Major components:**
1. `src/fs/block_dev.zig` -- driver-agnostic block I/O with explicit LBA parameters; eliminates the position-state race that makes SFS require `io_lock` around every block read
2. `src/fs/ext2/types.zig` + `inode.zig` -- on-disk structures and indirect block resolution (direct/single/double/triple), all verified with `comptime` size assertions
3. `src/fs/ext2/alloc.zig` -- block and inode bitmap allocation using the two-phase lock pattern from `sfs/alloc.zig`; group descriptor and superblock flushed after every alloc/free
4. `src/fs/ext2/dir.zig` + `ops.zig` -- directory entry traversal with `rec_len` as stride, VFS vtable implementations (all 16 functions)
5. `src/fs/ext2/cache.zig` -- 64-entry fixed inode cache with dirty writeback on eviction; mandatory for acceptable path traversal performance

### Critical Pitfalls

1. **Block I/O inside allocation lock (deadlock)** -- SFS suffered this at v1.1 (close deadlock after ~50 operations). ext2 has more allocation touchpoints (bitmap write + group descriptor write + superblock write per alloc/free). Prevention: two-phase pattern from `sfs/alloc.zig` -- scan and mark bitmap under `alloc_lock`, release lock, then do all disk writes. Never call `readBlock`/`writeBlock` while holding `alloc_lock` or `group_lock`. Warning sign: QEMU hangs at 90-second test timeout with no panic.

2. **Block number used directly as 512-byte LBA** -- ext2 logical block numbers are not sector numbers. For 4KB blocks, logical block 1 is at LBA 8 (not LBA 1). Passing block numbers to `readSector(lba)` reads from the wrong disk offset. The superblock is at byte offset 1024 = LBA 2; if this is misread, no other operation can work. Prevention: always compute `lba = block_num * (block_size / 512)` via a single dedicated `ext2BlockToLba` function. Warning sign: superblock magic check (0xEF53) fails on a correctly formatted image.

3. **Inode table 0-based indexing** -- ext2 inodes are 1-based (root = inode 2). The table index is `(inode_num - 1) % inodes_per_group`. Using `inode_num` directly causes every inode read to access the wrong slot. The bug is subtle because freshly-formatted small images may have valid-looking data at the wrong offset, making it pass initial tests. Prevention: single helper function `inodeTableIndex(inode_num)` with a debug-build panic on `inode_num == 0`. Warning sign: `stat /mnt` returns ENOENT.

4. **Directory scan using `name_len` as stride instead of `rec_len`** -- the last directory entry in a block has `rec_len` padded to fill the remaining space to end-of-block. Computing stride as `(8 + name_len + 3) & ~3` desynchronizes the scanner for that last entry. Prevention: always `offset += entry.rec_len`; validate `rec_len >= 8`, `rec_len % 4 == 0`, `offset + rec_len <= block_size`. Warning sign: `getdents` consistently misses the last file in a directory block.

5. **Page cache `file_identifier` uses heap pointer instead of inode number** -- VFS assigns `file_identifier` as a pointer-based hash. After a file is deleted and a new file is created (potentially at the same heap address), reads of the new file hit the old file's cache pages. Prevention: immediately after VFS assigns the FD, override `file_identifier = (mount_idx << 32) | inode_num`. Warning sign: reading a newly-created file returns data from a previously-deleted file with the same name.

---

## Implications for Roadmap

Based on the feature dependency graph and the pitfall-to-phase mapping, the build order naturally splits into 11 phases. The first three phases are infrastructure and must be complete before any filesystem logic is testable. Phases 4-6 deliver read-only ext2. Phases 7-10 deliver read-write ext2. Phase 11 migrates the test suite and completes the milestone.

### Phase 1: Build System and Block Device Foundation
**Rationale:** Without a pre-formatted ext2 disk image and QEMU drive attachment, no kernel code can be tested. A missing disk image makes every subsequent bug look like a kernel bug rather than a missing-infrastructure problem. The `BlockDevice` abstraction must exist before ext2 I/O code is written, because it eliminates the position-state race that would otherwise require `io_lock` around every block read.
**Delivers:** `ext2.img` created at build time via `mke2fs`; second QEMU drive attached as VirtIO-SCSI/AHCI; `src/fs/block_dev.zig` wrapping the partition FileDescriptor with explicit LBA parameters; `extern struct` on-disk types in `types.zig` with `comptime` size assertions.
**Addresses:** Build system image creation, QEMU disk image setup, aarch64 struct alignment safety.
**Avoids:** Pitfall 10 (missing QEMU disk image causes silent ENOENT), Pitfall 2 (block/LBA mismatch fixed once in `ext2BlockToLba`), Pitfall 1 (lock ordering established before allocation code exists), Pitfall 11 (aarch64 alignment: `extern struct` and `comptime` size assertions from the start).

### Phase 2: Superblock Parse and Read-Only Mount
**Rationale:** Superblock parsing is the universal dependency -- nothing else can proceed without knowing block size, inode count, group count, and feature flags. Feature flag validation (refuse mount on unknown INCOMPAT flags) must be in place before any further parsing code is written.
**Delivers:** `Ext2.init()` succeeds on a pre-formatted image; block size derived from `s_log_block_size`; group count computed; INCOMPAT flags validated; `s_rev_level` stored for `i_size_high` semantics; read-only VFS mount at `/mnt2` (alongside SFS at `/mnt` during development).
**Addresses:** Superblock parse, feature flag checks, VFS mount registration.
**Avoids:** Pitfall 2 (block size derived from spec, not assumed), Pitfall 12 (`s_rev_level` read on mount).

### Phase 3: Inode Read and Indirect Block Resolution
**Rationale:** Inode read is the universal dependency for every file operation. All four block indirection levels (direct/single/double/triple) must be implemented together before any I/O test is written. Implementing only direct + single-indirect causes silent truncation that is hard to diagnose after higher-level code is in place.
**Delivers:** `readInode(inode_num)` correct for both rev0 and rev1; `getBlockForLogicalIndex` resolves all four indirection levels; reading root inode (inode 2) returns a valid directory inode.
**Addresses:** Inode read routine, direct + singly + doubly indirect block reads.
**Avoids:** Pitfall 3 (inode 1-based indexing: `(inode_num - 1) % inodes_per_group`), Pitfall 5 (incomplete indirect block chain), Pitfall 12 (`i_size_high` handled for rev1 regular files).

### Phase 4: Directory Traversal and Path Resolution
**Rationale:** Path resolution is the entry point for every user-visible operation. Directory traversal and multi-component path splitting must be correct before any VFS operation can be tested end-to-end. This phase also establishes the correct `file_identifier` override to prevent page cache collisions.
**Delivers:** `lookupName(dir_inode, component)` correct; `ext2Open` resolves multi-level paths from root inode 2; `ext2StatPath` and `ext2Stat` return correct `FileMeta`; `ext2Getdents` lists directory contents; `file_identifier = (mount_idx << 32) | inode_num` set on open.
**Addresses:** Directory entry parsing, nested directory traversal, `stat_path`, `statfs`, `getdents`.
**Avoids:** Pitfall 4 (`rec_len` as stride, validated bounds), Pitfall 7 (VFS relative path: `tokenizeScalar` skips empty leading-slash component), Pitfall 8 (`file_desc.position` not used as block index), Pitfall 9 (`file_identifier` uses inode number).

### Phase 5: Inode Cache
**Rationale:** Path traversal without a cache requires one disk read per path component per `open` call. The 64-entry LRU inode cache reduces I/O dramatically for repeated access to the same directories. Placed after Phase 4 so the cache can be validated against working directory traversal code.
**Delivers:** `InodeCache` with fixed 64-entry array and LRU eviction via generation counter; dirty inode writeback on eviction; `inode_cache_lock` at position 2.5 in global lock ordering.
**Addresses:** Inode cache for path traversal performance.

### Phase 6: Fast Symlink Read and Read-Only Validation
**Rationale:** Completes the read-only feature set before writing a single byte to disk. Fast symlinks (target <= 60 bytes, stored inline in `i_block[]`) are the common case and require no block allocation. This phase closes out the Phase 1 MVP definition and validates the read path against pre-populated test images.
**Delivers:** `readlink` for fast symlinks; complete read-only VFS surface (open, stat_path, statfs, getdents, readlink); all existing SFS read tests pass when targeted at a pre-populated ext2 image.
**Addresses:** Fast symlink read.

### Phase 7: Block and Inode Bitmap Allocation
**Rationale:** All write operations share the same allocation primitives. Getting the two-phase lock pattern right once here prevents the SFS deadlock from recurring. This is the single most critical correctness requirement for the write path and must be validated independently before being used inside higher-level operations.
**Delivers:** `allocBlock`, `freeBlock`, `allocInode`, `freeInode` using the two-phase pattern (scan + mark under `alloc_lock`, disk writes outside lock); group descriptor and superblock counters updated atomically after every alloc/free; new blocks zeroed with `@memset(block_buf, 0)` before use.
**Addresses:** Block bitmap alloc/free, inode bitmap alloc/free.
**Avoids:** Pitfall 1 (deadlock from I/O inside alloc lock), Pitfall 6 (bitmap written without flushing group descriptor), Pitfall 14 (newly allocated blocks not zeroed, leaking prior file data).

### Phase 8: File Create, Write, Truncate, and Unlink
**Rationale:** These four operations form the core write path and share block extension logic. Implementing them together ensures the block map update code is written once and tested under all conditions (new file, extending write, truncate, unlink with nlink accounting).
**Delivers:** `open(O_CREAT)` allocates inode and directory entry; `write` extends block map on boundary crossing and updates `i_size`; `truncate` frees excess blocks; `unlink` decrements nlink and frees all blocks and inode when nlink reaches 0.
**Addresses:** File create, file write, file truncate, file unlink.

### Phase 9: Directory Write Operations
**Rationale:** Directory writes depend on both the allocation machinery from Phase 7 and the directory entry manipulation from Phase 4. Rename is the most complex single operation -- it must update two directory blocks atomically enough to avoid orphaned entries and must handle the case where the target already exists.
**Delivers:** `mkdir` (alloc inode + block, write `.` and `..`, add to parent, update parent nlink); `rmdir` (verify empty, free, remove parent entry, decrement parent nlink); `rename`/`rename2` (update directory entries, handle existing target); fast symlink write; hard link.
**Addresses:** Directory create, directory remove, rename, hard link, fast symlink write.
**Avoids:** Pitfall 13 (parent directory `i_mtime`/`i_ctime` updated after every directory-modifying operation).

### Phase 10: Metadata Operations and Mount Hardening
**Rationale:** `chmod`, `chown`, `set_timestamps`, `statfs`, and clean unmount complete the VFS interface. Superblock `s_state` tracking enables `e2fsck` to detect unclean mounts. This phase also establishes the deferred-flush optimization for superblock and group descriptor writes (batch on unmount or fsync, not per-alloc).
**Delivers:** All 16 VFS interface functions implemented; clean unmount with dirty inode writeback; `s_state` field maintained (dirty on mount, clean on unmount); `e2fsck` reports zero errors after a full test run.
**Addresses:** chmod, chown, set_timestamps, statfs, superblock mount state tracking.

### Phase 11: Test Migration from SFS
**Rationale:** ext2 takes `/mnt`, SFS is unmounted. All existing filesystem integration tests are retargeted to ext2 paths. This is the completion gate for the v2.0 milestone.
**Delivers:** ext2 mounted at `/mnt` (replaces SFS); `sfs.img` removed from QEMU args; all 186 test suite tests pass (with the same 20 skips as before, none of which are ext2-specific).
**Addresses:** Test migration.

### Phase Ordering Rationale

- Build system (Phase 1) comes first because every subsequent phase requires a testable disk image. A missing image produces ENOENT that is indistinguishable from a kernel bug -- this is documented in Pitfall 10 as the most disorienting failure mode.
- Read path (Phases 2-6) comes before write path (Phases 7-10). Read-only code has no allocation, no bitmap mutation, and no dirty-write ordering concerns. Bugs in the read path are isolated to parsing logic; bugs in the write path can corrupt the filesystem image and require reformatting to recover.
- Allocation (Phase 7) is isolated from file create/write (Phase 8). The two-phase lock pattern must be validated independently before it is embedded inside higher-level operations that are harder to bisect.
- SFS remains mounted at `/mnt` throughout Phases 1-10, so the 186-test suite continues passing throughout development. Only Phase 11 switches the mount point.
- All 11 phases exactly match the pitfall-to-phase mapping in PITFALLS.md and the feature dependency graph in FEATURES.md.

### Research Flags

Phases needing deeper research or explicit planning before coding:
- **Phase 7 (Bitmap Allocation):** The two-phase lock pattern is documented in principle from SFS, but the interaction between `alloc_lock`, `group_lock`, and `io_lock` when falling back to adjacent block groups (current group full) needs to be worked out explicitly before implementation. Plan this interaction before writing `alloc.zig`.
- **Phase 9 (Directory Rename):** Atomic rename across two directory blocks with correct `RENAME_NOREPLACE` and `RENAME_EXCHANGE` semantics is the most complex single operation in the milestone. The directory entry split/merge algorithm when inserting into an entry with excess `rec_len` needs explicit design before coding.
- **Phase 11 (Test Migration):** Some SFS tests depend on SFS-specific behaviors (flat directory, 32-char filename limit, known skip conditions). These tests require adjustment beyond simple path remapping. Audit the test list before assuming migration is mechanical.

Phases with standard well-documented patterns (skip additional research):
- **Phase 2 (Superblock Parse):** Completely specified in ext2 documentation; `extern struct` layout is identical to the existing SFS pattern. No unknowns.
- **Phase 3 (Inode Read):** All four indirection levels are textbook ext2 implementation; the algorithm is fully specified in the OSDev Wiki and Linux kernel source.
- **Phase 5 (Inode Cache):** Fixed-size LRU with generation counter is a standard pattern; implementation is approximately 100 lines.

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | ext2 on-disk format has been stable since Linux 2.0. All struct sizes and field offsets verified against Linux kernel `fs/ext2/ext2.h`. Host tooling (`e2fsprogs` 1.47.3) is mature. Zig `extern struct` behavior is stable since 0.10.x. macOS Homebrew keg-only path pattern is documented and tested. |
| Features | HIGH | Feature table derived from Linux kernel documentation and OSDev Wiki, cross-referenced with the existing VFS interface in `src/fs/vfs.zig`. The INCOMPAT/RO_COMPAT flag table is authoritative from Linux kernel headers. MVP boundaries are clear: read-only first, then read-write; deferred features are genuinely deferrable with no current test dependency. |
| Architecture | HIGH | Based on direct codebase analysis of `src/fs/sfs/` (all files), `src/fs/vfs.zig`, `src/kernel/fs/fd.zig`, `src/kernel/core/init_fs.zig`, `src/kernel/fs/page_cache.zig`. Integration points are fully mapped. The lock ordering fits the existing global hierarchy from CLAUDE.md without conflicts. Only two existing files need modification. |
| Pitfalls | HIGH | All critical pitfalls are derived from either: (a) documented SFS bugs in `PROJECT.md` and `MEMORY.md` that ext2 can recreate (close deadlock, aarch64 alignment), or (b) well-known ext2 implementation mistakes with documented warning signs and recovery paths. The aarch64 alignment pitfall has a direct precedent in the `socklen_t` bug documented in MEMORY.md. |

**Overall confidence:** HIGH

### Gaps to Address

- **Block size choice for test images:** STACK.md recommends 4KB blocks for page cache alignment; ARCHITECTURE.md notes the `mkfs.ext2` default is 1024 bytes and mentions starting with 1024-byte blocks. Make this choice explicit in Phase 1 and document it in a build comment. Recommendation: 4KB blocks for the initial test image; the implementation must handle any valid block size, but testing with 4KB aligns with the page cache and reduces multi-sector read complexity.

- **Partition device path vs raw disk:** SFS uses `/dev/sda` (raw disk). ARCHITECTURE.md suggests ext2 should use `/dev/sda1` (first GPT partition) for correctness. However, if the QEMU `ext2.img` is a flat raw ext2 image with no GPT partition table, the kernel reads it as `/dev/sdb` (or `/dev/sda` if it replaces the current SFS disk). This must be resolved in Phase 1 when the QEMU drive attachment is added, because the device path assumption in `init_fs.zig` must match the QEMU configuration.

- **Migration timing for `init_fs.zig`:** During Phases 1-10, ext2 should mount at `/mnt2` alongside SFS at `/mnt`. The exact commit that switches `init_fs.zig` to mount ext2 at `/mnt` (Phase 11) needs coordination with the CI pipeline to avoid breaking the test suite between the switch and the test migration. Plan this as a single atomic change.

---

## Sources

### Primary (HIGH confidence)
- `https://github.com/torvalds/linux/blob/master/fs/ext2/ext2.h` -- authoritative C struct definitions; all field offsets, sizes, and constants verified directly from kernel source
- `https://docs.kernel.org/filesystems/ext2.html` -- Linux kernel ext2 documentation; feature flag semantics, block group formulas, filesystem limits
- `https://www.nongnu.org/ext2-doc/ext2.html` -- GNU Hurd ext2 specification; most complete field-level documentation for all on-disk structures
- `https://wiki.osdev.org/Ext2` -- comprehensive implementation reference with worked examples and algorithm walkthroughs
- `https://formulae.brew.sh/formula/e2fsprogs` -- confirmed keg-only status, current version 1.47.3, available via Homebrew
- Direct codebase analysis: `src/fs/sfs/` (all files), `src/fs/vfs.zig`, `src/kernel/fs/fd.zig`, `src/kernel/core/init_fs.zig`, `src/kernel/fs/page_cache.zig`, `src/fs/partitions/root.zig` -- findings are observable facts from the codebase, not inferences

### Secondary (MEDIUM confidence)
- `https://en.wikipedia.org/wiki/Inode_pointer_structure` -- indirect block addressing overview (consistent with authoritative sources above)
- `MEMORY.md` (project memory file) -- SFS close deadlock pattern and aarch64 `socklen_t` alignment bug; both directly inform pitfall prevention strategies

### Tertiary (reference)
- `https://e2fsprogs.sourceforge.net/ext2intro.html` -- original ext2 design paper by Remy Card, Theodore Ts'o, Stephen Tweedie
- Linux kernel `fs/ext2/` source (balloc.c, ialloc.c, inode.c, dir.c) -- reference implementation patterns for allocation and directory operations

---
*Research completed: 2026-02-22*
*Ready for roadmap: yes*
