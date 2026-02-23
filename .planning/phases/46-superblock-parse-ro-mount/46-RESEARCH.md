# Phase 46: Superblock Parse and Read-Only Mount - Research

**Researched:** 2026-02-23
**Domain:** ext2 filesystem -- superblock parsing, feature flag validation, VFS registration
**Confidence:** HIGH

## Summary

Phase 46 implements the first runtime ext2 milestone: reading the superblock from the ext2.img block device, validating it, computing geometry, and registering a read-only filesystem with VFS at `/mnt2`. All on-disk types are already defined in `src/fs/ext2/types.zig` with comptime size assertions from Phase 45-02. The `BlockDevice` vtable is also complete. What is missing is: the filesystem state struct (`Ext2Fs`), the superblock read function, the INCOMPAT check, the block group descriptor table read, and the VFS adapter wiring.

The primary design constraint is that Phase 45-02 deliberately chose `SUPPORTED_INCOMPAT = INCOMPAT_FILETYPE` only. Any other INCOMPAT bit set in a freshly-created image (e.g., INCOMPAT_RECOVER from ext3 journaling) must cause a mount refusal with a clear log message. The `mke2fs` command from Phase 45-01 creates images with `INCOMPAT_FILETYPE` only -- this is the happy path.

The VFS integration pattern is already established by SFS (`src/fs/sfs/root.zig`) and InitRD (`src/fs/vfs.zig`). Phase 46 fills only optional fields (set `mkdir`, `rmdir`, `write`, `unlink`, etc. to `null` since this is read-only). The `open` callback returns `error.NotSupported` or `error.AccessDenied` for any write-mode flag.

The critical sequencing decision: the BlockDevice for the ext2 disk must be obtained from the VirtIO-SCSI controller before `initBlockFs()` can call the ext2 mount. Phase 45 decided aarch64 uses the second LUN (LUN index 1) on the existing scsi0 controller, and x86_64 uses a separate scsi0 controller. Both configurations end up with a `BlockDevice` that wraps the LUN -- this wiring is NOT yet written and is a deliverable of Phase 46.

**Primary recommendation:** Create `src/fs/ext2/mount.zig` with `Ext2Fs` struct and `init(dev: BlockDevice) !vfs.FileSystem`, add `initExt2Fs()` to `init_fs.zig`, wire BlockDevice acquisition into `init_hw.zig` or pass it through a global, and register with VFS at `/mnt2`.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| MOUNT-01 | Kernel parses ext2 superblock, validates magic (0xEF53), and derives block size | Superblock struct at `types.zig:101`, `blockSize()` helper at line 165, read via `BlockDevice.readSectors` at LBA 2 (2 sectors = 1024 bytes) |
| MOUNT-02 | Kernel reads block group descriptor table and validates group counts | `GroupDescriptor` at `types.zig:181`, group count from `Superblock.groupCount()` at line 170, BGDT starts at first block after superblock |
| MOUNT-03 | Kernel checks INCOMPAT feature flags and refuses to mount unsupported features | `SUPPORTED_INCOMPAT = INCOMPAT_FILETYPE` at `types.zig:49`, check `sb.s_feature_incompat & ~SUPPORTED_INCOMPAT != 0` |
| MOUNT-04 | ext2 filesystem registers with VFS and mounts at a writable mount point | VFS pattern from `vfs.zig:136`, mount at `/mnt2` per STATE.md decision, FileSystem vtable with all write ops null |
</phase_requirements>

## Standard Stack

### Core

| Component | Version/Location | Purpose | Why Standard |
|-----------|-----------------|---------|--------------|
| `src/fs/ext2/types.zig` | Existing (Phase 45-02) | All on-disk structs | Already written, comptime-verified sizes |
| `src/fs/block_device.zig` | Existing (Phase 45-02) | LBA-based block reads | Stateless, bounds-checked, driver-portable |
| `src/fs/vfs.zig` | Existing | VFS mount table | Required entry point per architecture |
| `src/kernel/core/init_fs.zig` | Existing | Boot filesystem init | Where initBlockFs() already lives |
| `src/kernel/core/init_hw.zig` | Existing | Hardware init | VirtIO-SCSI controller is found here |
| `heap.allocator()` | Existing | Heap allocation for Ext2Fs state | Standard kernel allocator |
| `console.info/err/warn` | Existing | Boot logging | Required for success criteria log messages |

### New Files to Create

| File | Purpose |
|------|---------|
| `src/fs/ext2/mount.zig` | `Ext2Fs` struct, `init(dev: BlockDevice)`, superblock read, INCOMPAT check, BGDT read, VFS adapter callbacks |

### Supporting

| Component | Purpose | When to Use |
|-----------|---------|-------------|
| `std.math.add/mul` | Overflow-safe arithmetic | All block address calculations per CLAUDE.md rule 5 |
| `@as(*const Superblock, @ptrCast(@alignCast(...)))` | Cast raw sector buffer to Superblock | After reading 1024 bytes into an `align(4)` buffer |
| `sync.Spinlock` | Protect Ext2Fs state if needed | Only needed if multiple threads could read simultaneously; for Phase 46 read-only, a single-writer lock may not be needed at mount time |

## Architecture Patterns

### Recommended Structure

```
src/fs/ext2/
    types.zig        # EXISTING: on-disk structs (Phase 45-02)
    mount.zig        # NEW: Ext2Fs state, init(), VFS adapter callbacks
```

`src/fs/root.zig` needs `ext2` re-export expanded from `types.zig` to the new `mount.zig`, or both can be re-exported. The simplest approach: add `pub const ext2_mount = @import("ext2/mount.zig");` to `src/fs/root.zig`.

### Pattern 1: Superblock Read at LBA 2

The ext2 superblock is always at byte offset 1024, which is LBA 2 (two 512-byte sectors from the start). The superblock is 1024 bytes = exactly 2 sectors.

```zig
// Source: ext2 spec section 3.1, types.zig SUPERBLOCK_LBA = 2
var sb_buf: [1024]u8 align(4) = @splat(0);
try dev.readSectors(types.SUPERBLOCK_LBA, 2, &sb_buf);
const sb: types.Superblock = @as(*const types.Superblock, @ptrCast(@alignCast(&sb_buf))).*;
```

Two sectors (1024 bytes) fit in the `readSectors` buffer. The `BlockDevice.readSectors` validates `buf.len >= count * 512` -- passing `&sb_buf` (1024 bytes) with count=2 satisfies this.

Note: `SUPERBLOCK_LBA` is already defined as `2` in `types.zig`. Do not define it again.

### Pattern 2: INCOMPAT Flag Check

```zig
// Source: CLAUDE.md / STATE.md decision: SUPPORTED_INCOMPAT = INCOMPAT_FILETYPE only
const unsupported = sb.s_feature_incompat & ~types.SUPPORTED_INCOMPAT;
if (unsupported != 0) {
    console.err("ext2: unsupported INCOMPAT features: 0x{x} -- refusing to mount", .{unsupported});
    return error.NotSupported;
}
```

This check must happen BEFORE allocating Ext2Fs heap state to avoid leaks.

### Pattern 3: Block Group Descriptor Table Location

The BGDT immediately follows the superblock in the filesystem. For a 4KB block size image (which all Phase 45 images use), block 0 is unused (ext2 reserves it for boot sector), block 1 is the superblock... actually wait: for 4KB block size, `s_first_data_block = 0` (superblock is within block 0 but offset 1024 into it). The BGDT starts at block 1.

For 1KB block size: `s_first_data_block = 1`, superblock is block 1, BGDT is block 2.

The general formula: BGDT block = `sb.s_first_data_block + 1`.

Converting block number to LBA:
```zig
const block_size = sb.blockSize();     // e.g., 4096
const sectors_per_block = block_size / types.SECTOR_SIZE;  // e.g., 8
const bgdt_block = sb.s_first_data_block + 1;
const bgdt_lba = bgdt_block * sectors_per_block;
```

Reading the BGDT:
```zig
const group_count = sb.groupCount();
const bgdt_bytes = group_count * @sizeOf(types.GroupDescriptor);
// Round up to full sectors
const bgdt_sectors = (bgdt_bytes + types.SECTOR_SIZE - 1) / types.SECTOR_SIZE;
// Allocate aligned buffer
const buf = try heap.allocator().alignedAlloc(u8, 4, bgdt_sectors * types.SECTOR_SIZE);
try dev.readSectors(bgdt_lba, bgdt_sectors, buf);
```

For Phase 46 this can be read but the BGDT does not need to be permanently cached -- just read, validate group_count, and log. The BGDT cache will be a Phase 47/48 concern.

### Pattern 4: VFS FileSystem Adapter for Read-Only ext2

Based on SFS pattern in `src/fs/sfs/root.zig` and InitRD adapter in `src/fs/vfs.zig`:

```zig
pub const Ext2Fs = struct {
    dev: BlockDevice,
    superblock: types.Superblock,
    // block_groups allocated on heap, freed in unmount
    block_groups: []types.GroupDescriptor,
};

fn ext2Open(ctx: ?*anyopaque, path: []const u8, flags: u32) vfs.Error!*fd.FileDescriptor {
    _ = ctx;
    _ = path;
    // Phase 46: read-only stub -- no inode traversal yet
    if (flags & fd.O_ACCMODE != fd.O_RDONLY) return error.NotSupported;
    return error.NotFound; // No file resolution until Phase 47
}

fn ext2StatPath(ctx: ?*anyopaque, path: []const u8) ?vfs.FileMeta {
    _ = ctx;
    _ = path;
    return null; // No inode lookup until Phase 47
}

fn ext2Unmount(ctx: ?*anyopaque) void {
    const self: *Ext2Fs = @ptrCast(@alignCast(ctx));
    heap.allocator().free(self.block_groups);
    heap.allocator().destroy(self);
}

pub fn init(dev: BlockDevice) !vfs.FileSystem {
    // 1. Read and validate superblock
    // 2. Check INCOMPAT flags
    // 3. Read BGDT
    // 4. Log success
    // 5. Return FileSystem vtable
    const self = try heap.allocator().create(Ext2Fs);
    errdefer heap.allocator().destroy(self);
    // ...
    return vfs.FileSystem{
        .context = self,
        .open = ext2Open,
        .unmount = ext2Unmount,
        .unlink = null,
        .stat_path = ext2StatPath,
        // All write ops null for read-only
        .chmod = null, .chown = null, .mkdir = null, .rmdir = null,
        .rename = null, .rename2 = null, .truncate = null,
        .link = null, .symlink = null, .readlink = null,
        .set_timestamps = null, .getdents = null,
    };
}
```

### Pattern 5: BlockDevice Acquisition from VirtIO-SCSI

The VirtIO-SCSI controller stores LUNs in `controller.luns[i]`. Phase 45 decided:
- aarch64: ext2 disk is LUN index 1 on the existing scsi0 controller
- x86_64: ext2 disk is a separate scsi0 controller (but in practice for QEMU test images, it may also be LUN index 1 on the same controller, or a separate controller if two VirtIO-SCSI controllers are present)

A `BlockDevice` wrapping a VirtIO-SCSI LUN needs a context struct and read function. The adapter does NOT yet exist -- `src/drivers/virtio/scsi/adapter.zig` wraps reads via `FileDescriptor` position-based I/O (for devfs/SFS), not `BlockDevice` vtable.

**Key gap**: Phase 46 must create a `BlockDevice` adapter for VirtIO-SCSI LUN. This means implementing:
```zig
fn scsiReadSectors(ctx: *anyopaque, lba: u64, count: u32, buf: []u8) BlockDeviceError!void {
    const lun_ctx: *ScsiLunCtx = @ptrCast(@alignCast(ctx));
    const bytes = lun_ctx.controller.readBlocks(lun_ctx.lun_idx, lba, count, buf) catch
        return error.IOError;
    _ = bytes;
}
```

And a corresponding write wrapper. This adapter needs to live either in `src/drivers/virtio/scsi/` (as `block_adapter.zig`) or in `src/fs/ext2/mount.zig` as a local helper.

**Recommendation**: Put it in `src/drivers/virtio/scsi/block_adapter.zig` to keep the driver layer clean and reusable for future filesystems.

The global `ext2_block_dev: ?BlockDevice` can be stored in `init_hw.zig` (alongside the existing `pub var net_interface`, `pub var pci_devices` pattern). Then `initBlockFs()` in `init_fs.zig` reads it.

### Pattern 6: Wiring in init_fs.zig

```zig
pub fn initExt2Fs() void {
    const init_hw = @import("init_hw.zig");
    const dev = init_hw.ext2_block_dev orelse {
        console.warn("ext2: no block device found -- skipping /mnt2 mount", .{});
        return;
    };
    const ext2_fs = @import("fs").ext2_mount.init(dev) catch |err| {
        console.err("ext2: mount failed: {}", .{err});
        return;
    };
    @import("fs").vfs.Vfs.mount("/mnt2", ext2_fs) catch |err| {
        console.err("ext2: VFS mount at /mnt2 failed: {}", .{err});
    };
    console.info("ext2: mounted at /mnt2", .{});
}
```

This follows the exact same structure as `initBlockFs()` for SFS.

### Anti-Patterns to Avoid

- **Caching BGDT in a fixed-size array**: Group count varies per image; use `heap.allocator().alloc(GroupDescriptor, group_count)` and free in `unmount`. Do not use a fixed array -- group count for a 50MB image at 4KB blocks is typically 7 groups, but must be dynamic.
- **Casting without `align(4)` buffer**: `@ptrCast` to `*const Superblock` requires the source buffer to be at least 4-byte aligned. Use `[1024]u8 align(4)` or `@alignCast`.
- **Checking INCOMPAT after heap allocation**: Check INCOMPAT early, before allocating `Ext2Fs`, to avoid the `errdefer`-destroy pattern being needed for two objects simultaneously.
- **Using SFS-style device_fd pattern**: SFS opens `/dev/sda` via VFS and reads via position-based fd I/O. ext2 should use the `BlockDevice` vtable directly (that is the entire point of Phase 45-02). Do not replicate the SFS approach.
- **Using i32 for sector calculations**: `block_size / SECTOR_SIZE` can be u32; LBA arithmetic must be u64. Do not let implicit casts silently truncate.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Superblock struct parsing | Custom byte-offset reader | `@ptrCast` to `*const types.Superblock` | Struct already comptime-verified at 1024 bytes exact |
| Block size computation | Shift math inline | `sb.blockSize()` | Already implemented in types.zig line 165 |
| Group count | Division inline | `sb.groupCount()` | Already implemented in types.zig line 170 |
| Overflow-safe arithmetic | Unchecked `*` and `+` | `std.math.mul/add` | CLAUDE.md rule 5 -- integer safety is mandatory |
| VFS mount table | Custom mount list | `vfs.Vfs.mount()` | Already at `vfs.zig:136`, thread-safe spinlock included |

## Common Pitfalls

### Pitfall 1: Superblock Buffer Alignment
**What goes wrong:** `@ptrCast(@alignCast(&sb_buf))` fails or produces UB at runtime if `sb_buf` is not 4-byte aligned.
**Why it happens:** Stack arrays have default `u8` alignment. `Superblock` fields include `u32` at offset 0, requiring 4-byte alignment for direct cast.
**How to avoid:** Declare `var sb_buf: [1024]u8 align(4) = @splat(0);`. The `align(4)` annotation ensures `@alignCast` succeeds.
**Warning signs:** Runtime alignment panic or Zig comptime error "pointer alignment mismatch" at the cast site.

### Pitfall 2: INCOMPAT Check Ordering
**What goes wrong:** Allocating `Ext2Fs` heap memory before checking INCOMPAT flags, then returning an error that leaks memory.
**Why it happens:** Natural to "init the struct then validate" like SFS does, but SFS doesn't have unsupported-feature early exits.
**How to avoid:** Perform all validation (magic check, INCOMPAT check) on stack-allocated superblock before calling `heap.allocator().create(Ext2Fs)`.
**Warning signs:** Test with a manually crafted ext2 image with unknown INCOMPAT bits and verify no memory leak.

### Pitfall 3: Block Group Descriptor Table Location for 4KB Blocks
**What goes wrong:** Assuming BGDT is always at LBA 4 (byte 2048), which is true for 1KB blocks but wrong for 4KB blocks.
**Why it happens:** The ext2 spec says BGDT follows the superblock in block numbering, but the block size changes everything.
**How to avoid:** Always compute: `bgdt_block = sb.s_first_data_block + 1`, then convert to LBA using `bgdt_block * (sb.blockSize() / SECTOR_SIZE)`. For 4KB blocks: `s_first_data_block = 0`, so BGDT is at block 1 = LBA 8 (block 1 * 8 sectors/block).
**Warning signs:** BGDT group descriptors read as all-zeros or garbage, group count check fails.

### Pitfall 4: s_feature_incompat vs s_feature_ro_compat
**What goes wrong:** Checking `s_feature_ro_compat` bits as hard mount failures.
**Why it happens:** Confusing the two feature sets; ro_compat features only block write mounts, not read-only mounts.
**How to avoid:** For Phase 46 (read-only), only check `s_feature_incompat`. Log but do NOT reject for unknown `s_feature_ro_compat` bits since we are read-only. Formally: `INCOMPAT` = must support to mount at all; `RO_COMPAT` = must support for write access only.
**Warning signs:** Mount failures on images with dir_nlink or large_file RO_COMPAT bits set.

### Pitfall 5: BlockDevice for ext2 Not Registered Before initExt2Fs()
**What goes wrong:** `init_hw.ext2_block_dev` is `null` when `initExt2Fs()` runs because the second LUN was not detected/registered.
**Why it happens:** VirtIO-SCSI LUN discovery is sequential; if the ext2 disk is LUN 1 but only one disk was detected (or QEMU args are wrong), the global stays null.
**How to avoid:** `initExt2Fs()` must gracefully handle `null` with a warning, not a panic. The test QEMU command must include the ext2 disk attachment. Verify by checking LUN count in boot log.
**Warning signs:** "ext2: no block device found -- skipping /mnt2 mount" in test output.

### Pitfall 6: VFS MAX_MOUNTS Capacity
**What goes wrong:** `mount("/mnt2", ...)` returns `error.MountPointFull`.
**Why it happens:** `vfs.zig:MAX_MOUNTS = 8`. Current mounts: `/` (InitRD), `/dev` (DevFS), `/mnt` (SFS) = 3 used. Adding `/mnt2` = 4. No issue currently.
**How to avoid:** No action needed for Phase 46. Document the count to prevent surprises in Phase 53 when test mounts may be added.
**Warning signs:** Would be a compile-time or runtime warning, not a silent failure.

## Code Examples

### Full Superblock Read and Validate

```zig
// Source: ext2 spec + types.zig constants
pub fn parseSuperblock(dev: BlockDevice) !types.Superblock {
    var sb_buf: [1024]u8 align(4) = @splat(0);
    // types.SUPERBLOCK_LBA = 2, count = 2 sectors = 1024 bytes
    try dev.readSectors(types.SUPERBLOCK_LBA, 2, &sb_buf);

    const sb: types.Superblock = @as(*const types.Superblock, @ptrCast(@alignCast(&sb_buf))).*;

    if (sb.s_magic != types.EXT2_MAGIC) {
        console.err("ext2: bad magic 0x{x} (expected 0x{x})", .{ sb.s_magic, types.EXT2_MAGIC });
        return error.InvalidSuperblock;
    }

    const unsupported_incompat = sb.s_feature_incompat & ~types.SUPPORTED_INCOMPAT;
    if (unsupported_incompat != 0) {
        console.err("ext2: unsupported INCOMPAT features 0x{x} -- refusing to mount", .{unsupported_incompat});
        return error.NotSupported;
    }

    console.info("ext2: magic OK, block_size={d}, block_count={d}, group_count={d}", .{
        sb.blockSize(), sb.s_blocks_count, sb.groupCount(),
    });

    return sb;
}
```

### BGDT Read

```zig
// Source: ext2 spec section 3.3
pub fn readBgdt(dev: BlockDevice, sb: types.Superblock, allocator: std.mem.Allocator) ![]types.GroupDescriptor {
    const group_count = sb.groupCount();
    if (group_count == 0) return error.InvalidSuperblock;

    const block_size = sb.blockSize();
    const sectors_per_block = block_size / types.SECTOR_SIZE;

    // BGDT is in the block immediately after the superblock block
    const bgdt_block = std.math.add(u32, sb.s_first_data_block, 1) catch return error.InvalidSuperblock;
    const bgdt_lba = std.math.mul(u64, @as(u64, bgdt_block), @as(u64, sectors_per_block)) catch return error.InvalidSuperblock;

    // Compute buffer size: round up to sector boundary
    const bgdt_bytes = std.math.mul(usize, group_count, @sizeOf(types.GroupDescriptor)) catch return error.InvalidSuperblock;
    const bgdt_sectors = (bgdt_bytes + types.SECTOR_SIZE - 1) / types.SECTOR_SIZE;
    const buf_size = std.math.mul(usize, bgdt_sectors, types.SECTOR_SIZE) catch return error.InvalidSuperblock;

    const raw_buf = try allocator.alignedAlloc(u8, 4, buf_size);
    errdefer allocator.free(raw_buf);

    try dev.readSectors(bgdt_lba, @intCast(bgdt_sectors), raw_buf);

    // Carve out the GroupDescriptor slice from the raw buffer
    const gd_slice = std.mem.bytesAsSlice(types.GroupDescriptor, raw_buf[0..bgdt_bytes]);
    // gd_slice points into raw_buf -- caller must free raw_buf, not gd_slice directly
    // Simpler: allocate the GroupDescriptor slice separately and copy
    const groups = try allocator.alloc(types.GroupDescriptor, group_count);
    errdefer allocator.free(groups);
    @memcpy(groups, gd_slice);
    allocator.free(raw_buf);

    console.info("ext2: BGDT read OK, {d} groups, first group inode_table=block {d}", .{
        group_count, groups[0].bg_inode_table,
    });

    return groups;
}
```

### BlockDevice from VirtIO-SCSI LUN

```zig
// To be placed in src/drivers/virtio/scsi/block_adapter.zig
const fs = @import("fs");
const BlockDevice = fs.block_device.BlockDevice;
const BlockDeviceError = fs.block_device.BlockDeviceError;
const SECTOR_SIZE = fs.block_device.SECTOR_SIZE;

const ScsiLunCtx = struct {
    controller: *VirtioScsiController,
    lun_idx: u8,
    total_blocks: u64,
};

fn scsiReadSectors(ctx: *anyopaque, lba: u64, count: u32, buf: []u8) BlockDeviceError!void {
    const lun_ctx: *ScsiLunCtx = @ptrCast(@alignCast(ctx));
    _ = lun_ctx.controller.readBlocks(lun_ctx.lun_idx, lba, count, buf) catch
        return error.IOError;
}

fn scsiWriteSectors(ctx: *anyopaque, lba: u64, count: u32, buf: []const u8) BlockDeviceError!void {
    const lun_ctx: *ScsiLunCtx = @ptrCast(@alignCast(ctx));
    _ = lun_ctx.controller.writeBlocks(lun_ctx.lun_idx, lba, count, buf) catch
        return error.IOError;
}

pub fn asBlockDevice(controller: *VirtioScsiController, lun_idx: u8) !BlockDevice {
    const lun_info = controller.getLun(lun_idx) orelse return error.LunNotFound;
    const ctx = try heap.allocator().create(ScsiLunCtx);
    ctx.* = .{
        .controller = controller,
        .lun_idx = lun_idx,
        .total_blocks = lun_info.total_blocks,
    };
    return BlockDevice{
        .ctx = ctx,
        .readSectorsFn = scsiReadSectors,
        .writeSectorsFn = scsiWriteSectors,
        .sector_count = lun_info.total_blocks,
        .sector_size = @intCast(lun_info.block_size),
    };
}
```

### init_hw.zig Global and Registration Point

```zig
// In init_hw.zig (near other pub var declarations):
pub var ext2_block_dev: ?BlockDevice = null;

// In initStorage(), after VirtIO-SCSI controller loop, after LUN enumeration:
if (found_virtio_scsi) {
    if (virtio_scsi.getController()) |ctrl| {
        // LUN 1 is the ext2 disk (LUN 0 = SFS disk /dev/sda)
        if (ctrl.getLunCount() > 1) {
            ext2_block_dev = virtio_scsi.block_adapter.asBlockDevice(ctrl, 1) catch |err| blk: {
                console.warn("ext2: failed to create BlockDevice for LUN 1: {}", .{err});
                break :blk null;
            };
        }
    }
}
```

### init_fs.zig: initExt2Fs()

```zig
pub fn initExt2Fs() void {
    const init_hw = @import("init_hw.zig");
    const dev = init_hw.ext2_block_dev orelse {
        console.warn("ext2: no block device -- skipping /mnt2", .{});
        return;
    };

    const ext2_fs = @import("fs").ext2_mount.init(dev) catch |err| {
        console.err("ext2: init failed: {}", .{err});
        return;
    };

    @import("fs").vfs.Vfs.mount("/mnt2", ext2_fs) catch |err| {
        console.err("ext2: mount at /mnt2 failed: {}", .{err});
        return;
    };

    console.info("ext2: mounted at /mnt2 (read-only)", .{});
}
```

### main.zig call site

```zig
// After init_fs.initBlockFs() call (line 443 of main.zig):
init_fs.initExt2Fs();
```

## State of the Art

| Old Approach | Current Approach | Notes |
|--------------|-----------------|-------|
| SFS: open `/dev/sda` via VFS fd | ext2: use `BlockDevice` vtable directly | BlockDevice is stateless, no position races |
| SFS: reads via position-based `read_fn(fd, &buf)` | ext2: `dev.readSectors(lba, count, buf)` | Correct LBA semantics for filesystem layer |
| SFS: formats if magic not found | ext2: refuses mount if magic wrong | ext2.img is pre-formatted; no in-kernel mkfs |
| SFS: single superblock in sector 0 | ext2: superblock at byte 1024 (LBA 2) | ext2 spec always reserves first 1024 bytes for boot sector |

## Open Questions

1. **LUN index for ext2 disk on x86_64**
   - What we know: Phase 45-01 STATE.md says "x86_64: new scsi0 controller for ext2disk". In QEMU, this means TWO VirtIO-SCSI PCI devices.
   - What's unclear: The `initStorage()` loop breaks after the first VirtIO-SCSI controller (`break; // Only initialize first controller`). If ext2 is on a SECOND controller, it will not be found.
   - Recommendation: Two options: (a) modify `initStorage()` to initialize all VirtIO-SCSI controllers and store both, or (b) make x86_64 also use LUN 1 on the same controller (simpler, matches aarch64). This decision should be confirmed before planning tasks. The STATE.md note says "new scsi0 controller" which implies option (a). However if QEMU puts both disks on one VirtIO-SCSI controller as separate LUNs, option (b) works. Inspect the QEMU command generated by Phase 45-01's build.zig to determine actual topology.

2. **BlockDevice context lifetime**
   - What we know: `ScsiLunCtx` is heap-allocated in `asBlockDevice()`. The `BlockDevice` struct stores a pointer to it.
   - What's unclear: If the VirtIO-SCSI controller is ever destroyed (e.g., hot-unplug, which is not currently supported), the `ScsiLunCtx` pointer becomes dangling.
   - Recommendation: For Phase 46, treat the controller as permanent (kernel lifetime). Document this assumption. Phase 46 should not add hot-unplug support.

3. **Block group count validation bounds**
   - What we know: `sb.groupCount()` is computed as `(s_blocks_count + s_blocks_per_group - 1) / s_blocks_per_group`. For a corrupted superblock with `s_blocks_per_group = 0`, this divides by zero.
   - What's unclear: Is division-by-zero caught by Zig's runtime checks in ReleaseSafe/Debug? In ReleaseFast, this would be UB.
   - Recommendation: Add `if (sb.s_blocks_per_group == 0) return error.InvalidSuperblock;` before calling `sb.groupCount()`. Similarly for `s_inodes_per_group`. The `groupCount()` method itself could be hardened, but the caller should validate inputs per security standards.

## Sources

### Primary (HIGH confidence)

- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/ext2/types.zig` -- all on-disk struct definitions, constants, helper methods; read directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/block_device.zig` -- BlockDevice vtable API; read directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/vfs.zig` -- VFS FileSystem vtable, mount() API; read directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/sfs/root.zig` -- canonical pattern for init() returning vfs.FileSystem; read directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/kernel/core/init_fs.zig` -- boot sequence for filesystem init; read directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/kernel/core/init_hw.zig` -- VirtIO-SCSI controller wiring; read directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/.planning/STATE.md` -- Phase 45-02 decisions: SUPPORTED_INCOMPAT, SECTOR_SIZE, LUN topology
- `/Users/whit3rabbit/Documents/GitHub/zigk/.planning/REQUIREMENTS.md` -- MOUNT-01 through MOUNT-04 definitions
- ext2 specification: https://www.nongnu.org/ext2-doc/ext2.html (cited in types.zig header; not fetched, but types.zig was written from it)

### Secondary (MEDIUM confidence)

- ext2 superblock layout at SUPERBLOCK_OFFSET=1024: established convention, matches types.zig constants; HIGH
- BGDT location formula `s_first_data_block + 1`: standard ext2 layout for both 1KB and 4KB block sizes; verified against types.zig field `s_first_data_block` comment "0 for 4KB blocks, 1 for 1KB"

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all components are existing codebase files, read and verified
- Architecture patterns: HIGH -- superblock layout and VFS adapter pattern derived directly from existing codebase
- Pitfalls: HIGH -- alignment, INCOMPAT ordering, BGDT location are mechanical derivations from the spec and Zig semantics; LUN topology open question is MEDIUM (requires verifying build.zig QEMU args)
- BlockDevice adapter: HIGH -- API is fully specified in block_device.zig and VirtIO-SCSI controller methods are readable in root.zig

**Research date:** 2026-02-23
**Valid until:** 2026-03-23 (stable internal codebase; only invalidated by Phase 45 changes or VFS restructuring)
