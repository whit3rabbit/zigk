---
phase: 46-superblock-parse-ro-mount
plan: 01
subsystem: filesystem
tags: [ext2, virtio-scsi, block-device, vfs, superblock]

# Dependency graph
requires:
  - phase: 45-build-infrastructure
    provides: BlockDevice vtable (block_device.zig), ext2 on-disk types (types.zig), VirtIO-SCSI controller with readBlocks/writeBlocks
provides:
  - VirtIO-SCSI to BlockDevice adapter (block_adapter.zig) bridging LBA sector reads to SCSI block I/O
  - ext2 superblock parsing with magic and INCOMPAT feature validation
  - ext2 BGDT read with overflow-safe sector arithmetic
  - VFS FileSystem adapter (Phase 46 read-only stubs) for ext2
affects: [46-02, phase-47-inode-traversal, phase-48-inode-cache]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - ScsiLunCtx heap-allocated adapter context for BlockDevice vtable bridging
    - ext2 superblock read into align(4) stack buffer with @ptrCast/@alignCast copy
    - BGDT alignedAlloc raw buffer + bytesAsSlice + @memcpy into typed group slice
    - Phase-gated VFS stubs: open returns NotFound until inode resolution lands in Phase 47

key-files:
  created:
    - src/drivers/virtio/scsi/block_adapter.zig
    - src/fs/ext2/mount.zig
  modified:
    - src/drivers/virtio/scsi/root.zig
    - src/fs/root.zig

key-decisions:
  - "block_adapter.zig is separate from adapter.zig: adapter.zig is a FileOps (fd-based devfs) adapter; block_adapter.zig is a BlockDevice vtable adapter for the VFS filesystem layer"
  - "LBA conversion: if lun block_size == 512, pass through; if larger, native_lba = lba*512/bsz, native_count = ceil(count*512/bsz) using overflow-safe arithmetic"
  - "Phase 46 ext2Open returns NotFound for all reads (no inode resolution yet); write flags return AccessDenied; all write vtable slots null"
  - "parseSuperblock uses [_]u8{0} ** 1024 zero-init (not @splat) matching codebase convention"

patterns-established:
  - "BlockDevice adapter: heap-allocate Ctx struct, fill vtable with fn pointers, return BlockDevice by value"
  - "ext2 superblock read: 1024-byte align(4) stack buffer, readSectors(SUPERBLOCK_LBA, 2, &buf), @ptrCast copy"
  - "BGDT read: alignedAlloc raw buffer, readSectors, bytesAsSlice typed view, @memcpy to groups slice, free raw"

requirements-completed: [MOUNT-01, MOUNT-02, MOUNT-03]

# Metrics
duration: 3min
completed: 2026-02-23
---

# Phase 46 Plan 01: Superblock Parse and RO Mount Summary

**VirtIO-SCSI to BlockDevice adapter and ext2 mount module with superblock validation (magic + INCOMPAT), BGDT read, and read-only VFS FileSystem stubs**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-23T12:17:00Z
- **Completed:** 2026-02-23T12:20:00Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- VirtIO-SCSI BlockDevice adapter: ScsiLunCtx, scsiReadSectors/scsiWriteSectors with LBA/block-size conversion, asBlockDevice() heap-allocates context and returns populated vtable
- ext2 parseSuperblock: reads 1024 bytes at LBA 2, validates magic 0xEF53, rejects zero blocks/inodes_per_group, rejects unsupported INCOMPAT features
- ext2 readBgdt: overflow-safe block/sector arithmetic, alignedAlloc raw buffer, bytesAsSlice typed view, @memcpy to typed GroupDescriptor slice
- Phase-gated VFS FileSystem adapter: all write vtable slots null, open returns NotFound (no inode resolution), unmount frees block_groups and destroys Ext2Fs

## Task Commits

Each task was committed atomically:

1. **Task 1: Create VirtIO-SCSI BlockDevice adapter** - `4cc4849` (feat)
2. **Task 2: Create ext2 mount module with superblock parse, BGDT read, VFS adapter** - `dc4c057` (feat)

## Files Created/Modified
- `src/drivers/virtio/scsi/block_adapter.zig` - BlockDevice vtable adapter bridging to VirtioScsiController.readBlocks/writeBlocks
- `src/fs/ext2/mount.zig` - Ext2Fs struct, parseSuperblock, readBgdt, init() returning vfs.FileSystem
- `src/drivers/virtio/scsi/root.zig` - Added `pub const block_adapter = @import("block_adapter.zig")`
- `src/fs/root.zig` - Added `pub const ext2_mount = @import("ext2/mount.zig")`

## Decisions Made
- `block_adapter.zig` is distinct from the existing `adapter.zig` (which provides FileOps/fd-based devfs bindings). The new file provides a BlockDevice vtable for the filesystem layer, per plan spec.
- LBA-to-native-block conversion handles both 512-byte-native and larger-block (e.g. 4096-byte) SCSI devices using overflow-safe arithmetic.
- `parseSuperblock` uses `[_]u8{0} ** 1024` zero-init (not `@splat(0)`) matching the established codebase convention.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Plan 02 can now wire `block_adapter.asBlockDevice` and `ext2_mount.init` into the kernel boot sequence at the correct LUN index and mount point (/mnt2).
- Plan 47 (inode traversal) will replace the ext2Open stub with real inode lookup once the BGDT and block read infrastructure are exercised.

## Self-Check: PASSED

All files verified present. Both task commits confirmed in git log.

---
*Phase: 46-superblock-parse-ro-mount*
*Completed: 2026-02-23*
