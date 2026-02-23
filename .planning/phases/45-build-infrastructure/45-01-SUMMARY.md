---
phase: 45-build-infrastructure
plan: 01
subsystem: infra
tags: [ext2, mke2fs, qemu, virtio-scsi, build-system, e2fsprogs]

# Dependency graph
requires: []
provides:
  - "ext2.img creation step in build.zig via mke2fs (idempotent, stamp-file guarded)"
  - "QEMU VirtIO-SCSI ext2disk attachment for x86_64 (new scsi0 controller)"
  - "QEMU VirtIO-SCSI ext2disk attachment for aarch64 (second LUN on existing scsi0)"
  - "*.stamp in .gitignore"
  - "e2fsprogs in CI apt-get install (integration-tests and build-validation jobs)"
affects:
  - 45-build-infrastructure
  - 46-ext2-superblock-and-bgd
  - 47-ext2-block-inode-alloc
  - 48-ext2-inode-cache
  - 49-ext2-directory-ops
  - 50-ext2-file-ops
  - 51-ext2-rename
  - 52-ext2-vfs-integration
  - 53-ext2-migration

# Tech tracking
tech-stack:
  added: [mke2fs, e2fsprogs]
  patterns:
    - "Stamp file sentinel (ext2.img.stamp) for idempotent build steps"
    - "Homebrew path priority for macOS tools to avoid Android SDK shadowing"
    - "VirtIO-SCSI multi-LUN: aarch64 adds ext2disk to existing scsi0 alongside sfsdisk"
    - "VirtIO-SCSI new controller: x86_64 adds scsi0 dedicated to ext2disk"

key-files:
  created: []
  modified:
    - "build.zig"
    - ".gitignore"
    - ".github/workflows/ci.yml"

key-decisions:
  - "ext2.img created at zig build run time (not plain zig build) -- image is a runtime artifact, not a build artifact"
  - "Stamp file guards idempotency: subsequent zig build run invocations skip mke2fs"
  - "Homebrew mke2fs paths checked before system PATH to avoid Android SDK mke2fs on macOS"
  - "aarch64: ext2disk as second LUN on existing scsi0 (SCSI multi-LUN, no second controller)"
  - "x86_64: new virtio-scsi-pci scsi0 controller dedicated to ext2disk (SFS uses AHCI)"

patterns-established:
  - "Stamp file pattern: touch <artifact>.stamp on success, check before regenerating"
  - "mke2fs flags: -t ext2 -b 4096 -L zk-ext2 -m 0 (no journal, 4KB blocks, no reserved)"

requirements-completed: [BUILD-01, BUILD-02]

# Metrics
duration: 2min
completed: 2026-02-23
---

# Phase 45 Plan 01: Build Infrastructure Summary

**64MB ext2 disk image created by mke2fs at build time and attached as VirtIO-SCSI block device on both x86_64 and aarch64 via new build.zig steps**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-23T11:51:25Z
- **Completed:** 2026-02-23T11:53:35Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Added `create_ext2_cmd` build step that calls mke2fs with ext2 format, 4KB blocks, and zk-ext2 volume label
- Stamp file (`ext2.img.stamp`) makes the creation idempotent across multiple `zig build run` invocations
- aarch64: ext2disk added as a second LUN on existing scsi0 controller (alongside sfsdisk)
- x86_64: new virtio-scsi-pci controller (scsi0) added with ext2disk as sole device
- CI workflow now explicitly installs e2fsprogs in both integration-tests and build-validation jobs

## Task Commits

Each task was committed atomically:

1. **Task 1: Add ext2.img creation build step and update gitignore/CI** - `01d5989` (feat)
2. **Task 2: Add QEMU VirtIO-SCSI ext2 device attachment for both architectures** - `a7eef9f` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified
- `build.zig` - Added create_ext2_cmd step (lines 2944-2992) and VirtIO-SCSI device args for both archs (lines 2813-2827)
- `.gitignore` - Added `*.stamp` after `*.img` line
- `.github/workflows/ci.yml` - Added `e2fsprogs` to integration-tests apt-get list and build-validation ISO step

## Decisions Made
- Stamp file sentinel pattern chosen over checking file existence with mke2fs (avoids re-running mke2fs on images that were manually deleted and recreated externally)
- Homebrew mke2fs paths (`/opt/homebrew/opt/e2fsprogs/sbin/mke2fs` then `/usr/local/opt/e2fsprogs/sbin/mke2fs`) checked before system PATH to avoid Android SDK's mke2fs being picked up on macOS developer machines
- aarch64 uses SCSI multi-LUN (no second controller) to match the existing SFS pattern and avoid controller ID conflicts
- x86_64 gets a new scsi0 controller because SFS on x86_64 uses AHCI on the boot disk, so there was no existing SCSI controller to reuse

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None. Both architectures compiled cleanly after each change. Build output was zero lines (no warnings).

One observation: on this macOS machine, Homebrew e2fsprogs is not installed, so the script falls back to `which mke2fs` which resolves to `/Users/whit3rabbit/Library/Android/sdk/platform-tools/mke2fs`. The Android SDK mke2fs is functional for creating a basic ext2 image but is not the preferred tool. Users should run `brew install e2fsprogs` to get the proper version. The error message in the script guides this.

## User Setup Required

On macOS (Apple Silicon): `brew install e2fsprogs` to get the preferred mke2fs. The Android SDK mke2fs (if present via PATH) will work as a fallback but is not recommended.

## Next Phase Readiness

- build.zig infrastructure complete: `zig build run` will produce ext2.img and attach it as VirtIO-SCSI block device
- Phase 45 Plan 02 (ext2 superblock read) can now proceed -- the block device will be available as the second SCSI disk in the guest
- No regressions: existing SFS disk setup is unchanged on both architectures

---
*Phase: 45-build-infrastructure*
*Completed: 2026-02-23*

## Self-Check: PASSED

All files verified:
- FOUND: 45-01-SUMMARY.md
- FOUND: .gitignore (*.stamp added)
- FOUND: ci.yml (e2fsprogs added)
- FOUND: commit 01d5989 (Task 1)
- FOUND: commit a7eef9f (Task 2)
