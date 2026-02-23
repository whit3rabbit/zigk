---
phase: 45-build-infrastructure
plan: 02
subsystem: filesystem
tags: [ext2, block-device, freestanding, zig, kernel]

# Dependency graph
requires:
  - phase: 45-01
    provides: QEMU VirtIO-SCSI ext2.img device attachment and build infrastructure
provides:
  - src/fs/block_device.zig -- driver-portable LBA-based block I/O interface (BlockDevice, SECTOR_SIZE, BlockDeviceError)
  - src/fs/ext2/types.zig -- ext2 on-disk structs with comptime size assertions (Superblock, GroupDescriptor, Inode, DirEntry)
  - fs/root.zig -- exports block_device and ext2 modules
affects:
  - 46-ext2-superblock -- reads Superblock via BlockDevice.readSectors
  - 47-ext2-inode -- uses Inode, GroupDescriptor structs from types.zig
  - 48-ext2-directory -- uses DirEntry, Inode helpers from types.zig
  - 49-ext2-alloc -- uses GroupDescriptor bitmap fields
  - 50-ext2-write -- uses Inode.i_blocks, i_block[] for write paths

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "BlockDevice vtable: ctx/*anyopaque + fn pointers for driver portability without heap allocation"
    - "extern struct with comptime @sizeOf assertions for on-disk format verification at compile time"
    - "SECTOR_SIZE-based LBA validation with std.math.mul/add overflow safety"

key-files:
  created:
    - src/fs/block_device.zig
    - src/fs/ext2/types.zig
  modified:
    - src/fs/root.zig

key-decisions:
  - "Use SECTOR_SIZE (512) for all LBA arithmetic regardless of sector_size field -- LBA addressing is always 512-byte units; sector_size is informational for alignment optimization only"
  - "DirEntry defined as extern struct (fixed 8-byte header) -- name follows inline in block buffer, not in struct; iteration uses rec_len offset stepping"
  - "SUPPORTED_INCOMPAT = INCOMPAT_FILETYPE only -- mke2fs enables it by default, and it is the only safe incompat feature to support in Phase 46"
  - "s_log_frag_size field uses u32 not i32 -- Zig extern struct packing requires unsigned type even though Linux uses i32"

patterns-established:
  - "BlockDevice vtable pattern: drivers fill ctx + fn pointers; callers use convenience methods with built-in overflow-safe validation"
  - "Comptime size assertion pattern: place inside the extern struct body so assertion fires on any @import, not just explicit instantiation"

requirements-completed: [BUILD-03]

# Metrics
duration: 3min
completed: 2026-02-23
---

# Phase 45 Plan 02: Build Infrastructure Summary

**Stateless LBA block device vtable and comptime-verified ext2 on-disk types (Superblock 1024B, GroupDescriptor 32B, Inode 128B, DirEntry 8B header) wired into fs/root.zig**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-23T11:51:25Z
- **Completed:** 2026-02-23T11:54:41Z
- **Tasks:** 3
- **Files modified:** 3

## Accomplishments

- BlockDevice vtable with overflow-safe readSectors/writeSectors eliminates the position-state race present in SFS io.zig
- All four ext2 on-disk structs pass comptime @sizeOf assertions (1024, 32, 128, 8 bytes respectively), preventing silent data corruption in Phase 46+
- Both x86_64 and aarch64 kernel builds succeed with zero errors after wiring into fs/root.zig

## Task Commits

Each task was committed atomically:

1. **Task 1: Create BlockDevice abstraction** - `5b6d9db` (feat)
2. **Task 2: Create ext2 on-disk types with comptime size assertions** - `5c377fb` (feat)
3. **Task 3: Wire new modules into fs/root.zig and verify compilation** - `a7a8c90` (feat)

## Files Created/Modified

- `src/fs/block_device.zig` -- BlockDevice vtable struct with readSectors/writeSectors, overflow-safe bounds checks, no shared state
- `src/fs/ext2/types.zig` -- Superblock (1024B), GroupDescriptor (32B), Inode (128B), DirEntry (8B), all constants and helpers
- `src/fs/root.zig` -- Added exports: `block_device` and `ext2`

## Decisions Made

- SECTOR_SIZE (512) used for all LBA arithmetic regardless of `sector_size` field, which is informational only for physical alignment optimization.
- DirEntry is `extern struct` with a fixed 8-byte header; the name lives inline in the block buffer immediately after the header and is accessed via pointer arithmetic by the caller.
- SUPPORTED_INCOMPAT = INCOMPAT_FILETYPE only -- mke2fs enables this by default, it is the only safe incompat feature for Phase 46 to recognize.
- s_log_frag_size field typed as u32 (not i32) because Zig extern struct packing does not tolerate signed types in this position.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None. The Superblock reserved array calculation (760 bytes at offset 264 to fill to 1024) was verified manually before writing and the comptime assertion passed on first compile.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 46 (ext2 superblock parsing) can import `@import("fs").block_device.BlockDevice` and `@import("fs").ext2` directly
- BlockDevice.readSectors is the only I/O primitive Phase 46 needs -- no driver adapters required yet (adapters for AHCI/VirtIO-SCSI come in Phase 46)
- All four struct sizes are compile-time verified, so Phase 46 can safely @ptrCast block buffers to *Superblock, *GroupDescriptor, *Inode, *DirEntry without size ambiguity

---
*Phase: 45-build-infrastructure*
*Completed: 2026-02-23*
