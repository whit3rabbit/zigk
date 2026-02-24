# Phase 49: Block and Inode Bitmap Allocation - Research

**Researched:** 2026-02-24
**Domain:** ext2 block and inode bitmap allocation with two-phase locking
**Confidence:** HIGH

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| ALLOC-01 | Kernel allocates free blocks from block group bitmaps with group locality | Two-phase pattern from `sfs/alloc.zig`; scan under `alloc_lock`, write bitmap outside lock; fall back to next group on exhaustion |
| ALLOC-02 | Kernel frees blocks and updates bitmap + group descriptor + superblock atomically | Three-step flush: bitmap sector -> group descriptor sector -> superblock; Pitfall 6 from prior research documents exactly this failure mode |
| ALLOC-03 | Kernel allocates free inodes from inode group bitmaps | Same two-phase pattern as blocks; inode bitmaps are one block per group at `bg_inode_bitmap` block number |
| ALLOC-04 | Kernel frees inodes and updates bitmap + group descriptor + superblock atomically | Same flush sequence as block free; additionally zero-initialize the inode on disk to prevent data leaks |
</phase_requirements>

---

## Summary

Phase 49 delivers the four primitive operations that all future ext2 write operations depend on: `allocBlock`, `freeBlock`, `allocInode`, `freeInode`. These live in a new file `src/fs/ext2/alloc.zig`. The design is constrained by two pre-existing decisions recorded in STATE.md: (1) the two-phase lock pattern from `sfs/alloc.zig` must be applied here to prevent the SFS close-deadlock from recurring, and (2) three on-disk structures must be flushed after every alloc/free in strict order -- bitmap, group descriptor, superblock -- to keep `e2fsck` satisfied.

The phase is a pure kernel implementation task with no VFS surface changes and no new test infrastructure beyond adding allocation-exercising userspace tests to `src/user/test_runner/tests/fs/ext2_basic.zig`. The implementation adds one new field to `Ext2Fs`: `alloc_lock sync.Spinlock`. It does not require a new lock type -- the existing `sync.Spinlock` from `src/kernel/core/sync.zig` is sufficient and is what SFS already uses at the same lock ordering position.

The ext2 image is already pre-formatted with known free block and inode counts by the build system (Phase 45). The superblock's `s_free_blocks_count` and `s_free_inodes_count` fields, and the group descriptors' `bg_free_blocks_count` and `bg_free_inodes_count` fields, are the authoritative counters. After every alloc or free, all three structures (bitmap block, group descriptor, superblock) must be flushed to disk outside the allocation lock.

**Primary recommendation:** Implement `src/fs/ext2/alloc.zig` with `allocBlock`, `freeBlock`, `allocInode`, `freeInode` following the exact two-phase structure of `sfs/alloc.zig:allocateBlock` and `sfs/alloc.zig:freeBlock`. Add `alloc_lock sync.Spinlock` to `Ext2Fs`. Cache all group descriptors in-memory (already done: `fs.block_groups` slice). Add the superblock write-back function. Test via userspace tests that call `open(O_CREAT|O_WRONLY)` and `unlink` on ext2 files, then verify `statfs` free counts decrement and recover.

---

## Standard Stack

### Core (all already present in the codebase)

| Component | Location | Purpose | Notes |
|-----------|----------|---------|-------|
| `sync.Spinlock` | `src/kernel/core/sync.zig` | IRQ-safe spinlock for `alloc_lock` | Same type SFS uses; acquire/release RAII pattern |
| `Ext2Fs` struct | `src/fs/ext2/mount.zig` | Filesystem state; gains `alloc_lock` field | Already has `dev BlockDevice`, `superblock`, `block_groups []GroupDescriptor` |
| `BlockDevice` | `src/fs/block_device.zig` | LBA-based block I/O (`readSectors`/`writeSectors`) | Already used in Phases 46-48; `writeSectors` is the write path |
| `types.Superblock` | `src/fs/ext2/types.zig` | ext2 superblock struct with `s_free_blocks_count`, `s_free_inodes_count` | Extern struct, 1024 bytes, verified by comptime assert |
| `types.GroupDescriptor` | `src/fs/ext2/types.zig` | Per-group struct with `bg_block_bitmap`, `bg_inode_bitmap`, `bg_free_blocks_count`, `bg_free_inodes_count` | 32 bytes, in `fs.block_groups` heap slice |
| `heap.allocator()` | `src/kernel/mm/heap.zig` | Per-block bitmap buffer allocation | Bitmaps are one full ext2 block = 4096 bytes; too large for stack |

### Lock Ordering Position

From CLAUDE.md and confirmed in `sfs/types.zig`:

```
2.   SFS.alloc_lock (Filesystem Allocation) -- ext2.alloc_lock goes HERE
3.   FileDescriptor.lock
```

`alloc_lock` must NEVER be held while calling `dev.readSectors` or `dev.writeSectors` (which may internally contend with device locks). All I/O must happen outside the critical section.

---

## Architecture Patterns

### Recommended File Layout

No new files beyond what Phases 46-48 created, plus one new file:

```
src/fs/ext2/
  types.zig    -- (existing) Superblock, GroupDescriptor, Inode, DirEntry
  mount.zig    -- (modified) Ext2Fs gains alloc_lock field; superblock write-back fn added
  inode.zig    -- (existing) readInode, resolveBlock, LRU cache, file/dir ops
  alloc.zig    -- (NEW) allocBlock, freeBlock, allocInode, freeInode; writeGroupDesc, writeSuperblock
```

### Pattern 1: Two-Phase Block Allocation (source: sfs/alloc.zig:54-158)

The SFS two-phase pattern adapted for ext2. The key difference from SFS: ext2 has multiple block groups and must update the group descriptor in addition to the superblock.

```zig
// src/fs/ext2/alloc.zig

pub fn allocBlock(fs: *Ext2Fs) !u32 {
    // Invariants:
    //   alloc_lock is NOT held on entry
    //   alloc_lock is NOT held on return (normal or error path)
    //   I/O (readSectors/writeSectors) happens ONLY outside alloc_lock

    var result_block: u32 = undefined;
    var result_group: u32 = undefined;
    var bitmap_buf: []u8 = undefined;  // heap-allocated, freed after write
    var found = false;

    // --- Phase 1: scan + mark under alloc_lock ---
    {
        const held = fs.alloc_lock.acquire();
        defer held.release();

        // Walk groups looking for one with free blocks.
        var group_idx: u32 = 0;
        while (group_idx < fs.group_count) : (group_idx += 1) {
            const gd = &fs.block_groups[group_idx];
            if (gd.bg_free_blocks_count == 0) continue;

            // Read bitmap for this group (outside would be cleaner but we
            // need the bitmap under lock to prevent TOCTOU with concurrent
            // allocs). Read is acceptable here because alloc_lock is not
            // contended by I/O paths.
            //
            // EXCEPTION to two-phase: reading the bitmap under lock is safe
            // because concurrent allocators also hold alloc_lock before
            // reading, so no other thread sees the bitmap in-between.
            // The I/O must be a synchronous read (no sleeping).
            const bitmap_block = gd.bg_block_bitmap;
            const lba = @as(u64, bitmap_block) * @as(u64, fs.sectors_per_block);

            const alloc = heap.allocator();
            bitmap_buf = alloc.alloc(u8, fs.block_size) catch return error.ENOMEM;
            @memset(bitmap_buf, 0);  // DMA hygiene
            fs.dev.readSectors(lba, fs.sectors_per_block, bitmap_buf) catch {
                alloc.free(bitmap_buf);
                return error.IOError;
            };

            // Scan for first zero bit.
            var byte_idx: usize = 0;
            while (byte_idx < fs.block_size) : (byte_idx += 1) {
                if (bitmap_buf[byte_idx] == 0xFF) continue;
                var bit: u3 = 0;
                while (bit < 8) : (bit += 1) {
                    if ((bitmap_buf[byte_idx] & (@as(u8, 1) << bit)) == 0) {
                        // Mark bit in buffer.
                        bitmap_buf[byte_idx] |= @as(u8, 1) << bit;

                        // Compute absolute block number:
                        //   blocks_per_group * group_idx + local_block
                        const local_block = byte_idx * 8 + bit;
                        result_block = std.math.add(u32,
                            std.math.mul(u32, fs.superblock.s_blocks_per_group, group_idx)
                                catch { heap.allocator().free(bitmap_buf); return error.IOError; },
                            @as(u32, @intCast(local_block)),
                        ) catch { heap.allocator().free(bitmap_buf); return error.IOError; };

                        // Add first_data_block offset (0 for 4KB blocks, 1 for 1KB).
                        result_block = std.math.add(u32,
                            result_block, fs.superblock.s_first_data_block,
                        ) catch { heap.allocator().free(bitmap_buf); return error.IOError; };

                        // Validate block is within filesystem.
                        if (result_block >= fs.superblock.s_blocks_count) {
                            // Undo mark.
                            bitmap_buf[byte_idx] &= ~(@as(u8, 1) << bit);
                            heap.allocator().free(bitmap_buf);
                            return error.ENOSPC;
                        }

                        // Update in-memory counters under lock.
                        gd.bg_free_blocks_count -= 1;
                        fs.superblock.s_free_blocks_count -|= 1;

                        result_group = group_idx;
                        found = true;
                        break;
                    }
                }
                if (found) break;
            }
            if (found) break;
            heap.allocator().free(bitmap_buf);  // no free bit in this group
        }

        if (!found) return error.ENOSPC;
    }
    // alloc_lock released here.

    // --- Phase 2: flush bitmap, group desc, superblock OUTSIDE lock ---
    defer heap.allocator().free(bitmap_buf);

    const gd = &fs.block_groups[result_group];
    const bitmap_lba = @as(u64, gd.bg_block_bitmap) * @as(u64, fs.sectors_per_block);
    fs.dev.writeSectors(bitmap_lba, fs.sectors_per_block, bitmap_buf) catch |err| {
        // Rollback in-memory counters under lock.
        const held = fs.alloc_lock.acquire();
        defer held.release();
        gd.bg_free_blocks_count +|= 1;
        fs.superblock.s_free_blocks_count +|= 1;
        return err;
    };

    try writeGroupDescriptor(fs, result_group);
    try writeSuperblock(fs);

    return result_block;
}
```

### Pattern 2: Block Free (two-phase, I/O before lock for free path)

The free path is simpler: read bitmap outside lock, clear bit, write bitmap outside lock, then update in-memory counters under lock. This mirrors `sfs/alloc.zig:freeBlock`.

```zig
pub fn freeBlock(fs: *Ext2Fs, block_num: u32) !void {
    // Validate block is within filesystem bounds.
    if (block_num < fs.superblock.s_first_data_block) return error.InvalidBlock;
    if (block_num >= fs.superblock.s_blocks_count) return error.InvalidBlock;

    // Compute group and local index.
    const adjusted = block_num - fs.superblock.s_first_data_block;
    const group_idx = adjusted / fs.superblock.s_blocks_per_group;
    const local_idx = adjusted % fs.superblock.s_blocks_per_group;
    const byte_idx = local_idx / 8;
    const bit_idx: u3 = @intCast(local_idx % 8);

    if (group_idx >= fs.group_count) return error.InvalidBlock;

    const gd = &fs.block_groups[group_idx];
    const bitmap_lba = @as(u64, gd.bg_block_bitmap) * @as(u64, fs.sectors_per_block);

    // Read bitmap OUTSIDE lock.
    const alloc = heap.allocator();
    const bitmap_buf = alloc.alloc(u8, fs.block_size) catch return error.ENOMEM;
    defer alloc.free(bitmap_buf);
    @memset(bitmap_buf, 0);
    fs.dev.readSectors(bitmap_lba, fs.sectors_per_block, bitmap_buf) catch return error.IOError;

    // Clear bit (if already zero, double-free -- log warning but do not panic in release).
    if ((bitmap_buf[byte_idx] & (@as(u8, 1) << bit_idx)) == 0) {
        console.warn("ext2: freeBlock {d}: block already free in bitmap", .{block_num});
    }
    bitmap_buf[byte_idx] &= ~(@as(u8, 1) << bit_idx);

    // Write bitmap OUTSIDE lock.
    fs.dev.writeSectors(bitmap_lba, fs.sectors_per_block, bitmap_buf) catch return error.IOError;

    // Update in-memory counters UNDER lock.
    {
        const held = fs.alloc_lock.acquire();
        defer held.release();
        gd.bg_free_blocks_count +|= 1;
        fs.superblock.s_free_blocks_count +|= 1;
    }

    // Flush group descriptor and superblock OUTSIDE lock.
    try writeGroupDescriptor(fs, group_idx);
    try writeSuperblock(fs);
}
```

### Pattern 3: Group Descriptor and Superblock Write-Back

These are the two helper functions called after every alloc/free. They must be called outside `alloc_lock`.

```zig
/// Flush group descriptor for group_idx to disk.
///
/// The BGDT starts in the block immediately after s_first_data_block.
/// For 4KB blocks: BGDT is in block 1 (s_first_data_block=0, BGDT block=1).
/// Each GroupDescriptor is 32 bytes; multiple descriptors fit per block.
/// This matches the existing readBgdt logic in mount.zig.
pub fn writeGroupDescriptor(fs: *Ext2Fs, group_idx: u32) !void {
    const bgdt_block = fs.superblock.s_first_data_block + 1;
    const gd_size = @sizeOf(types.GroupDescriptor);  // 32 bytes
    const gds_per_sector = @import("block_device").SECTOR_SIZE / gd_size;  // 16

    // Byte offset of this group's descriptor from start of BGDT block.
    const gd_byte_offset = @as(u64, group_idx) * @as(u64, gd_size);
    const sector_in_bgdt = gd_byte_offset / @import("block_device").SECTOR_SIZE;
    const byte_in_sector = gd_byte_offset % @import("block_device").SECTOR_SIZE;

    const bgdt_lba = @as(u64, bgdt_block) * @as(u64, fs.sectors_per_block);
    const target_lba = bgdt_lba + sector_in_bgdt;

    // Read the sector containing this group descriptor.
    var sector_buf: [@import("block_device").SECTOR_SIZE]u8 align(4) = [_]u8{0} ** @import("block_device").SECTOR_SIZE;
    fs.dev.readSectors(target_lba, 1, &sector_buf) catch return error.IOError;

    // Copy updated GroupDescriptor into sector buffer.
    const gd_bytes = std.mem.asBytes(&fs.block_groups[group_idx]);
    @memcpy(sector_buf[byte_in_sector..][0..gd_size], gd_bytes);

    // Write sector back.
    fs.dev.writeSectors(target_lba, 1, &sector_buf) catch return error.IOError;
}

/// Flush the in-memory superblock to disk.
///
/// Superblock is always at byte offset 1024 (LBA 2 for 512-byte sectors).
/// The superblock is 1024 bytes = 2 sectors.
pub fn writeSuperblock(fs: *Ext2Fs) !void {
    var sb_buf: [1024]u8 align(4) = [_]u8{0} ** 1024;
    @memcpy(&sb_buf, std.mem.asBytes(&fs.superblock));
    fs.dev.writeSectors(types.SUPERBLOCK_LBA, 2, &sb_buf) catch return error.IOError;
}
```

### Pattern 4: Inode Allocation

Inode allocation follows the same two-phase pattern as block allocation, with these differences:
- The bitmap is `bg_inode_bitmap` (not `bg_block_bitmap`).
- The result is an inode number (1-based), computed as `group_idx * s_inodes_per_group + local_idx + 1`.
- After allocating the inode number, the inode slot on disk must be zeroed to prevent stale field values from a previously deleted inode.
- `bg_free_inodes_count` (not `bg_free_blocks_count`) is decremented.
- `s_free_inodes_count` (not `s_free_blocks_count`) is decremented.

```zig
pub fn allocInode(fs: *Ext2Fs) !u32 {
    // ... same two-phase structure as allocBlock ...
    // Key differences:
    //   - Read gd.bg_inode_bitmap instead of gd.bg_block_bitmap
    //   - result_inum = group_idx * s_inodes_per_group + local_idx + 1  (1-based)
    //   - Validate: result_inum <= s_inodes_count (not s_blocks_count)
    //   - Decrement bg_free_inodes_count and s_free_inodes_count
    // After flushing bitmap + group desc + superblock:
    //   zeroInode(fs, result_inum)  -- clear stale on-disk inode data
    return result_inum;
}

pub fn freeInode(fs: *Ext2Fs, inum: u32) !void {
    // ... same structure as freeBlock ...
    // Key differences:
    //   - Convert inum to group/local: group = (inum-1) / ipg, local = (inum-1) % ipg
    //   - Read/clear gd.bg_inode_bitmap
    //   - Increment bg_free_inodes_count and s_free_inodes_count
    //   - After flush: zeroInode(fs, inum) to prevent data leaks
}

/// Write an all-zeros inode to the inode table at slot `inum`.
///
/// Called after inode allocation (clear stale data) and after inode free
/// (prevent data leaks to next allocator).
///
/// Uses the same LBA computation as readInode in inode.zig.
fn zeroInode(fs: *Ext2Fs, inum: u32) !void {
    // inode_num is 1-based; table offset uses (inum-1)
    const group_idx = (inum - 1) / fs.superblock.s_inodes_per_group;
    const offset_in_group = (inum - 1) % fs.superblock.s_inodes_per_group;
    const gd = fs.block_groups[group_idx];
    const byte_offset = @as(u64, offset_in_group) * @as(u64, fs.inode_size);
    const table_start = @as(u64, gd.bg_inode_table) * @as(u64, fs.block_size);
    const inode_byte_offset = table_start + byte_offset;
    const lba = inode_byte_offset / @import("block_device").SECTOR_SIZE;

    // Zero inode in a stack buffer (128 bytes fits safely on kernel stack).
    var sector_buf: [@import("block_device").SECTOR_SIZE * 2]u8 align(4) = [_]u8{0} ** (@import("block_device").SECTOR_SIZE * 2);
    fs.dev.readSectors(lba, 2, &sector_buf) catch return error.IOError;

    const byte_in_sector: usize = @intCast(inode_byte_offset % @import("block_device").SECTOR_SIZE);
    @memset(sector_buf[byte_in_sector..][0..@sizeOf(types.Inode)], 0);
    fs.dev.writeSectors(lba, 2, &sector_buf) catch return error.IOError;
}
```

### Anti-Patterns to Avoid

- **Reading bitmap inside alloc_lock with sleeping I/O:** The `readSectors` call inside Phase 1 is acceptable because the VirtIO-SCSI and AHCI reads are synchronous (polling, not sleep-based). If this assumption changes, the read must move outside the lock. See STATE.md note on Phase 49 lock interaction design.
- **Updating only the superblock without the group descriptor:** `e2fsck` cross-checks `bg_free_blocks_count` against the bitmap. Skipping the group descriptor write causes "Group X has bad block/inode count" errors. This is Pitfall 6 from the prior research and the most commonly skipped step.
- **Using `s_first_data_block` as a global offset without accounting for group stride:** `s_first_data_block` is the block number of block 0 in group 0 (0 for 4KB blocks, 1 for 1KB blocks). When computing the absolute block number from `(group_idx, local_idx)`, the formula is `group_idx * s_blocks_per_group + local_idx + s_first_data_block`. Not `s_first_data_block + group_idx * s_blocks_per_group + local_idx`. These are equivalent for group 0 but differ for groups 1+ if `s_first_data_block != 0`.
- **Not zeroing the bitmap buffer before readSectors:** DMA hygiene rule from CLAUDE.md. If the disk read returns partial data, uninitialized bytes look like free bits. Always `@memset(bitmap_buf, 0)` before the read.
- **Putting the 4KB bitmap buffer on the kernel stack:** Stack overflow on aarch64 (documented in MEMORY.md). Always heap-allocate bitmap buffers via `heap.allocator()`.
- **Evicting cached inode without writing back dirty flag:** After `allocInode` + `zeroInode`, the inode cache may hold a stale copy of that inode slot. Either invalidate the cache entry for `inum` after zeroing, or check that `getCachedInode` always re-reads from disk when the inode number is freshly allocated. Simplest: do not cache freshly-zeroed inodes; let the first real write populate the cache.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Bitmap scan for first zero bit | Custom bit twiddling | Pattern from `sfs/alloc.zig:83-101` | Already proven correct; scan by byte (0xFF check), then by bit within byte |
| Group descriptor location on disk | Custom BGDT offset formula | Pattern from `mount.zig:readBgdt` | Already computes `bgdt_block = s_first_data_block + 1`; reuse the same formula |
| Superblock write-back | Custom sector-write | `writeSuperblock(fs)` as shown above | Superblock is always at `SUPERBLOCK_LBA = 2`; same constant already in `types.zig` |
| Lock ordering | New lock type | `sync.Spinlock` from `kernel/core/sync.zig` | Same spinlock SFS uses; no new primitives needed |
| Inode zero-out | Custom inode write | Pattern from `inode.zig:readInode` (reversed) | The LBA arithmetic is already implemented and correct; copy the computation |

---

## Common Pitfalls

### Pitfall 1: Block I/O Nested Inside alloc_lock (Deadlock)
**What goes wrong:** Holding `alloc_lock` while calling `dev.writeSectors` causes deadlock when the device driver internally acquires its own lock. SFS suffered this at v1.1 (close deadlock after ~50 operations). ext2 has three write sites per alloc (bitmap, group desc, superblock) instead of SFS's two (bitmap, superblock).
**Why it happens:** The natural implementation writes bitmap inside the allocation critical section.
**How to avoid:** Two-phase pattern. Under lock: scan in-memory bitmap, mark bit, record LBA, update in-memory counters. Release lock. Then write all three disk structures.
**Warning signs:** QEMU hangs at 90-second test timeout with no panic. The log shows `"ext2: allocating block..."` but no completion message. Adding many files in the test runner stalls at a consistent point.

### Pitfall 2: Group Descriptor Not Flushed After Bitmap Write
**What goes wrong:** `e2fsck` checks `bg_free_blocks_count` in the group descriptor against the actual bitmap. Writing the bitmap but not the group descriptor causes e2fsck to report "Group X has bad block count" and may force a repair that overwrites data.
**Why it happens:** SFS has no group descriptors; the SFS pattern (bitmap + superblock) is directly incomplete for ext2.
**How to avoid:** Every alloc/free flushes exactly three things in order: (1) bitmap block, (2) group descriptor sector, (3) superblock. Make `writeGroupDescriptor` + `writeSuperblock` a mandatory sequence after every bitmap write, with no optimization path that skips step 2.
**Warning signs:** Running `e2fsck -n ext2.img` after a test reports errors. `statfs` on remount shows different free counts than during the session.

### Pitfall 3: Absolute Block Number Computation Off for groups > 0
**What goes wrong:** For group 0, blocks start at `s_first_data_block` (which is 0 for 4KB-block images). For group 1, blocks start at `s_blocks_per_group`. The formula `s_first_data_block + group_idx * s_blocks_per_group + local_idx` is correct. Using just `group_idx * s_blocks_per_group + local_idx` gives the right answer for the 4KB case (where `s_first_data_block = 0`) but silently produces wrong block numbers for 1KB-block images (where `s_first_data_block = 1`).
**Why it happens:** Test images use 4KB blocks (as decided in Phase 45), so `s_first_data_block = 0` and the bug is invisible during development. Phase 53 migration tests against real-world images could expose it.
**How to avoid:** Always include `s_first_data_block` in the formula. Add a debug-build assertion: `std.debug.assert(fs.superblock.s_first_data_block == 0 or fs.superblock.s_log_block_size == 0)`.
**Warning signs:** Allocating a block in group 1 or higher returns a block number that is within the inode table or bitmap region (allocating metadata blocks).

### Pitfall 4: Bitmap Buffer Reuse Across Groups Without Re-Reading
**What goes wrong:** If the allocator falls back from group N to group N+1 (group N is exhausted), the bitmap buffer from group N must be freed and a fresh buffer must be read for group N+1. Reusing the same buffer without re-reading gives wrong bitmap data for the fallback group.
**Why it happens:** Memory allocation loop optimization. Easy to allocate once outside the group scan loop.
**How to avoid:** Allocate and free the bitmap buffer inside the group scan loop, one allocation per group attempt. The heap overhead is negligible; correctness is not.

### Pitfall 5: Inode Cache Stale After zeroInode
**What goes wrong:** `allocInode` calls `zeroInode` which writes zeros to the inode table slot on disk. If the inode cache holds a previous (non-zero) version of that inode number from a prior use, subsequent reads via `getCachedInode(inum)` return the stale cached data instead of the zeroed disk data.
**Why it happens:** The inode LRU cache in `inode.zig` does not track "dirty vs stale from disk" -- it stores what was last read. After `zeroInode` writes to disk, the cache entry is invalid.
**How to avoid:** After `zeroInode`, iterate the inode cache (`fs.inode_cache`) and clear any entry with `entry.inum == inum` by setting `entry.inum = 0`. This is the cache invalidation step. Since INODE_CACHE_SIZE = 16, this is O(16) = negligible.

---

## Code Examples

### Ext2Fs Struct Changes (mount.zig)

```zig
// Add to Ext2Fs struct (src/fs/ext2/mount.zig):
pub const Ext2Fs = struct {
    dev: BlockDevice,
    superblock: types.Superblock,
    block_groups: []types.GroupDescriptor,
    block_size: u32,
    sectors_per_block: u32,
    group_count: u32,
    inode_size: u16,
    inode_cache: [inode_mod.INODE_CACHE_SIZE]inode_mod.InodeCacheEntry,
    inode_cache_gen: u64,
    /// ALLOC-01/02/03/04: Serializes block and inode bitmap allocation/free.
    /// Lock ordering: position 2.0 (same as SFS.alloc_lock).
    /// NEVER hold while calling dev.readSectors or dev.writeSectors.
    alloc_lock: @import("sync").Spinlock = .{},
};
```

### VFS Mount Write Enable (mount.zig ext2Open)

Currently `ext2Open` returns `error.AccessDenied` for any non-O_RDONLY open:

```zig
// Phase 48 (current):
const O_ACCMODE: u32 = 0o3;
const O_RDONLY: u32 = 0;
if ((flags & O_ACCMODE) != O_RDONLY) return error.AccessDenied;
```

Phase 49 does NOT remove this guard yet -- allocation primitives exist but are not wired to the open path. The guard remains. The allocation functions are called by Phase 50 (file write operations). Phase 49 tests call allocation via a thin test harness or via the `O_CREAT` path if wired.

**Decision point:** Phase 49 can either (a) keep the read-only guard and test allocBlock/freeBlock/allocInode/freeInode via kernel-side unit tests, or (b) wire `O_CREAT` in ext2Open to call allocInode, enabling end-to-end userspace testing. Option (b) is recommended because it exercises the full call path including the `writeSuperblock` and `writeGroupDescriptor` functions, and the statfs free-count verification is more natural from userspace.

### Userspace Test Pattern (ext2_basic.zig)

```zig
/// Verify ALLOC-01/02: allocating a file decrements free block count.
/// Requires ext2 to be writable (O_CREAT wired to allocInode in Phase 49).
pub fn testExt2AllocBlockDecrementsCount() anyerror!void {
    if (!ext2Available()) return error.SkipTest;

    // Get baseline free counts.
    var st_before = std.mem.zeroes(syscall.Statfs);
    try syscall.statfs("/mnt2", &st_before);
    const blocks_before = st_before.f_bfree;
    const inodes_before = st_before.f_ffree;

    // Create a file (triggers allocInode + allocBlock for first data block).
    const fd = try syscall.open("/mnt2/alloc_test.txt", syscall.O_CREAT | syscall.O_WRONLY | syscall.O_TRUNC, 0o644);
    const data = "hello alloc\n";
    _ = try syscall.write(fd, data, data.len);
    try syscall.close(fd);

    // Get new free counts.
    var st_after = std.mem.zeroes(syscall.Statfs);
    try syscall.statfs("/mnt2", &st_after);

    // Free inode count must have decreased by at least 1.
    if (st_after.f_ffree >= inodes_before) return error.TestFailed;

    // Free block count must have decreased (at least the data block).
    if (st_after.f_bfree >= blocks_before) return error.TestFailed;

    // Cleanup: unlink to trigger freeBlock/freeInode.
    try syscall.unlink("/mnt2/alloc_test.txt");

    // Counts should recover (allow for superblock not immediately consistent).
    var st_final = std.mem.zeroes(syscall.Statfs);
    try syscall.statfs("/mnt2", &st_final);
    if (st_final.f_bfree != blocks_before) return error.TestFailed;
    if (st_final.f_ffree != inodes_before) return error.TestFailed;
}

/// Verify ALLOC-01/05: group exhaustion falls back to next group.
pub fn testExt2AllocFallsBackToNextGroup() anyerror!void {
    if (!ext2Available()) return error.SkipTest;
    // This test requires a small image or many pre-created files to exhaust group 0.
    // For Phase 49 with the 64MB test image (~4000 free inodes per group), this
    // is best tested at the unit level (kernel-side) rather than by exhausting
    // the filesystem from userspace. SKIP for now.
    return error.SkipTest;
}
```

---

## State of the Art

| What Changed | Phase | Impact on Phase 49 |
|---|---|---|
| `BlockDevice.writeSectors` already exists | Phase 45 | Write path is available; no new driver work needed |
| `fs.block_groups` loaded at mount time | Phase 46 | Group descriptors are in-memory; no read needed during alloc for the count check |
| `fs.sectors_per_block` computed at mount | Phase 46 | LBA arithmetic `block_num * sectors_per_block` is pre-computed |
| `inode_size` from superblock | Phase 46 | `zeroInode` uses correct stride for dynamic rev |
| `SUPERBLOCK_LBA = 2` in types.zig | Phase 46 | `writeSuperblock` uses this constant directly |
| `sync.Spinlock` used by SFS | Phase 11 (SFS deadlock fix) | The exact same lock type; acquire/release RAII pattern is proven |
| Two-phase alloc pattern in `sfs/alloc.zig` | Phase 11 (SFS deadlock fix) | Direct template for ext2 `alloc.zig`; do not deviate from the pattern |
| Inode LRU cache with `inode_cache[16]` entries | Phase 48 | Cache invalidation (`entry.inum = 0`) needed after `zeroInode` |

---

## Open Questions

1. **Should allocBlock read the bitmap inside or outside alloc_lock?**
   - What we know: SFS reads the bitmap inside `alloc_lock.acquire()` in Phase 1 of its two-phase pattern. The VirtIO-SCSI and AHCI reads in zk are synchronous (poll-based, not sleep-based), so holding a spinlock during the read does not risk a scheduler interleave.
   - What's unclear: If a future async I/O path is added, reading inside the spinlock becomes a deadlock risk.
   - Recommendation: Read bitmap inside `alloc_lock` for Phase 49 (matches SFS pattern and is safe for current synchronous I/O). Document the assumption with a comment: "SAFE: readSectors is synchronous in current VirtIO-SCSI/AHCI drivers; do not hold alloc_lock if async I/O is added."

2. **Should Phase 49 wire O_CREAT to test alloc end-to-end, or defer to Phase 50?**
   - What we know: Phase 50 is the planned phase for file write operations including O_CREAT. Wiring it in Phase 49 would require touching `ext2Open` in mount.zig.
   - What's unclear: Whether the test plan requires end-to-end userspace verification of allocation in Phase 49, or whether kernel-side verification (checking free count in `fs.superblock` after calling `allocBlock` directly) is sufficient.
   - Recommendation: Wire O_CREAT minimally in Phase 49 (allocate inode, no block allocation) to enable userspace test of inode alloc/free. Block alloc is tested indirectly when a write is issued (Phase 50). This limits Phase 49 scope while enabling meaningful userspace verification. If this is too invasive, add a kernel-side test hook instead.

3. **Should the first-fit group search start at group 0 or at a preferred group?**
   - What we know: Linux ext2 uses a preference algorithm for file inodes (place in same group as directory) and block allocation (place near the file's inode). Phase 49's scope is "group locality" (ALLOC-01) without specifying the exact algorithm.
   - What's unclear: Whether "group locality" means first-fit (scan from group 0) or nearest-group (scan from the inode's group).
   - Recommendation: Implement first-fit (scan from group 0) for Phase 49. This is correct and sufficient. Locality optimization is deferred to after Phase 53. Document this as a known limitation in a code comment.

---

## Validation Architecture

> `workflow.nyquist_validation` is not set in `.planning/config.json`. Skipping this section.

---

## Sources

### Primary (HIGH confidence)

- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/sfs/alloc.zig` -- direct template for two-phase lock pattern; `allocateBlock` (lines 54-158), `freeBlock` (lines 162-201); patterns are verified working and directly applicable
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/ext2/mount.zig` -- `Ext2Fs` struct definition; `readBgdt` provides the BGDT block location formula reused by `writeGroupDescriptor`
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/ext2/types.zig` -- `Superblock`, `GroupDescriptor`, `Inode` sizes and field names; `SUPERBLOCK_LBA = 2` constant
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/ext2/inode.zig` -- `readInode` LBA computation reused by `zeroInode`; `INODE_CACHE_SIZE = 16`, `InodeCacheEntry` struct for cache invalidation
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/kernel/core/sync.zig` -- `Spinlock` definition and acquire/release pattern
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/block_device.zig` -- `BlockDevice.writeSectors` signature; `SECTOR_SIZE = 512`
- `/Users/whit3rabbit/Documents/GitHub/zigk/.planning/research/PITFALLS.md` -- Pitfalls 1, 6, 14 directly applicable to Phase 49; two-phase pattern documented in detail
- `/Users/whit3rabbit/Documents/GitHub/zigk/.planning/research/SUMMARY.md` -- Phase 7 section confirms this phase's exact scope and lock pattern
- `/Users/whit3rabbit/Documents/GitHub/zigk/.planning/STATE.md` -- Confirmed: "Two-phase alloc lock pattern from sfs/alloc.zig applied to Phase 49"; "Phase 49 (bitmap allocation) needs explicit lock interaction design before coding: alloc_lock + group_lock + io_lock when falling back to adjacent block groups"

### Secondary (MEDIUM confidence)

- ext2 specification (https://www.nongnu.org/ext2-doc/ext2.html) -- group descriptor field semantics, bitmap block location calculation, inode number to group/index formula
- Linux kernel `fs/ext2/balloc.c` and `fs/ext2/ialloc.c` -- reference implementation for `ext2_new_blocks` and `ext2_new_inode`; confirms three-step flush order (bitmap -> group desc -> superblock)

---

## Metadata

**Confidence breakdown:**
- Architecture (where code goes, what to add): HIGH -- directly derived from existing `Ext2Fs` struct and `sfs/alloc.zig` template
- Lock pattern: HIGH -- two-phase pattern from `sfs/alloc.zig` is the authoritative pattern; STATE.md explicitly mandates it
- On-disk format (group descriptor location, bitmap position): HIGH -- `mount.zig:readBgdt` already implements and tests the correct BGDT location formula
- Three-step flush order: HIGH -- Pitfall 6 from prior research is explicit about this; cross-verified against Linux `balloc.c`
- Test approach: MEDIUM -- whether to wire O_CREAT in Phase 49 vs defer to Phase 50 is an open question; statfs-based verification is the cleanest option if O_CREAT is wired

**Research date:** 2026-02-24
**Valid until:** 2026-03-10 (ext2 format is stable; Zig 0.16.x nightly APIs are the only volatile element)
