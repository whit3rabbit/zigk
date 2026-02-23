# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-22)

**Core value:** Every implemented syscall must work correctly on both x86_64 and aarch64 with matching behavior, tested via the existing integration test harness.
**Current focus:** v2.0 ext2 Filesystem -- Phase 45: Build Infrastructure

## Current Position

Phase: 45 of 53 (Build Infrastructure)
Plan: 2 of TBD in current phase
Status: In progress
Last activity: 2026-02-23 -- 45-02 complete (BlockDevice vtable + ext2 on-disk types)

Progress: [░░░░░░░░░░] 2% (v2.0, 2 plans complete) | 44/44 phases complete (prior milestones)

## Performance Metrics

**Velocity:**
- Total plans completed: 91 (v1.0: 29, v1.1: 15, v1.2: 14, v1.3: 15, v1.4: 9, v1.5: 9)
- Total phases: 44 complete across 6 milestones, 9 planned for v2.0
- Timeline: 17 days (2026-02-06 to 2026-02-22)

**By Milestone:**

| Milestone | Phases | Plans | Duration |
|-----------|--------|-------|----------|
| v1.0 | 1-9 | 29 | 4 days |
| v1.1 | 10-14 | 15 | 2 days |
| v1.2 | 15-26 | 14 | 5 days |
| v1.3 | 27-35 | 15 | 4 days |
| v1.4 | 36-39 | 9 | 2 days |
| v1.5 | 40-44 | 9 | 3 days |
| v2.0 | 45-53 | TBD | - |
| Phase 45 P02 | 3 | 3 tasks | 3 files |

## Accumulated Context

### Decisions

See PROJECT.md Key Decisions table for full history.

Recent decisions relevant to v2.0:
- ext2 mounts at /mnt2 during Phases 45-52 (SFS stays at /mnt to keep 186 tests passing)
- 4KB block size for test images (aligns with page cache, reduces multi-sector reads)
- Phase 48 combines inode cache with directory traversal (cache validates against working traversal code)
- Two-phase alloc lock pattern from sfs/alloc.zig applied to Phase 49 (prevents close-deadlock recurrence)
- Phase 53 is one atomic commit switching mount point and migrating tests (avoids CI gap)
- [45-01] Stamp file sentinel (ext2.img.stamp) guards idempotency of mke2fs invocation across zig build run calls
- [45-01] Homebrew mke2fs paths checked before system PATH to avoid Android SDK mke2fs shadowing on macOS
- [45-01] aarch64: ext2disk is second LUN on existing scsi0 (no second controller); x86_64: new scsi0 controller for ext2disk
- [45-02] SECTOR_SIZE (512) used for all LBA arithmetic; sector_size field is informational for alignment only
- [45-02] DirEntry is extern struct with 8-byte header only; name lives inline in block buffer after header
- [45-02] SUPPORTED_INCOMPAT = INCOMPAT_FILETYPE only; mke2fs enables this by default
- [45-02] s_log_frag_size typed as u32 (not i32) for extern struct compatibility in Zig

### Pending Todos

None.

### Blockers/Concerns

- SFS close deadlock after many operations (documented in MEMORY.md) -- ext2 should resolve permanently
- 3 pre-existing aarch64 test failures (wait4 nohang, waitid WNOHANG, timerfd expiration) -- unrelated to filesystem work, do not attempt to fix
- QEMU TCG uncalibrated TSC prevents timer-based test paths -- unrelated to filesystem work
- Phase 49 (bitmap allocation) needs explicit lock interaction design before coding: alloc_lock + group_lock + io_lock when falling back to adjacent block groups
- Phase 51 (directory rename) needs explicit algorithm design: RENAME_NOREPLACE/RENAME_EXCHANGE with entry split/merge on excess rec_len

## Session Continuity

Last session: 2026-02-23
Stopped at: 45-02 complete -- BlockDevice vtable + ext2 on-disk types committed, both archs build clean
Resume file: None

**Next action:** Continue Phase 45 plans (45-03+) or plan Phase 46 (ext2 superblock parsing)

---
*State initialized: 2026-02-06*
*Last updated: 2026-02-23 after 45-01 and 45-02 completion*
