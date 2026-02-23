# Roadmap: ZK Kernel

## Milestones

- v1.0 **POSIX Syscall Coverage** -- Phases 1-9 (shipped 2026-02-09)
- v1.1 **Hardening & Debt Cleanup** -- Phases 10-14 (shipped 2026-02-11)
- v1.2 **Systematic Syscall Coverage** -- Phases 15-26 (shipped 2026-02-16)
- v1.3 **Tech Debt Cleanup** -- Phases 27-35 (shipped 2026-02-19)
- v1.4 **Network Stack Hardening** -- Phases 36-39 (shipped 2026-02-20)
- v1.5 **Tech Debt Cleanup** -- Phases 40-44 (shipped 2026-02-22)
- v2.0 **ext2 Filesystem** -- Phases 45-53 (in progress)

## Phases

<details>
<summary>v1.0 POSIX Syscall Coverage (Phases 1-9) -- SHIPPED 2026-02-09</summary>

- [x] Phase 1: Trivial Stubs (4/4 plans) -- completed 2026-02-06
- [x] Phase 2: UID/GID Infrastructure (3/3 plans) -- completed 2026-02-06
- [x] Phase 3: File Ownership (2/2 plans) -- completed 2026-02-06
- [x] Phase 4: I/O Multiplexing Infrastructure (3/3 plans) -- completed 2026-02-07
- [x] Phase 5: Event Notification FDs (3/3 plans) -- completed 2026-02-07
- [x] Phase 6: Vectored & Positional I/O (3/3 plans) -- completed 2026-02-08
- [x] Phase 7: Filesystem Extras (3/3 plans) -- completed 2026-02-08
- [x] Phase 8: Socket Extras (3/3 plans) -- completed 2026-02-08
- [x] Phase 9: Process Control & SysV IPC (5/5 plans) -- completed 2026-02-09

</details>

<details>
<summary>v1.1 Hardening & Debt Cleanup (Phases 10-14) -- SHIPPED 2026-02-11</summary>

- [x] Phase 10: Critical Kernel Bugs (3/3 plans) -- completed 2026-02-09
- [x] Phase 11: SFS Deadlock Fix (1/1 plans) -- completed 2026-02-09
- [x] Phase 12: SFS Hard Link Support (2/2 plans) -- completed 2026-02-10
- [x] Phase 13: SFS Symlink & Timestamp Support (2/2 plans) -- completed 2026-02-10
- [x] Phase 14: WaitQueue Blocking & Optimizations (7/7 plans) -- completed 2026-02-11

</details>

<details>
<summary>v1.2 Systematic Syscall Coverage (Phases 15-26) -- SHIPPED 2026-02-16</summary>

- [x] Phase 15: File Synchronization (1/1 plans) -- completed 2026-02-12
- [x] Phase 16: Advanced File Operations (1/1 plans) -- completed 2026-02-12
- [x] Phase 17: Zero-Copy I/O (2/2 plans) -- completed 2026-02-13
- [x] Phase 18: Memory Management Extensions (1/1 plans) -- completed 2026-02-13
- [x] Phase 19: Process Control Extensions (1/1 plans) -- completed 2026-02-14
- [x] Phase 20: Signal Handling Extensions (1/1 plans) -- completed 2026-02-14
- [x] Phase 21: I/O Multiplexing Extension (1/1 plans) -- completed 2026-02-15
- [x] Phase 22: File Monitoring (1/1 plans) -- completed 2026-02-15
- [x] Phase 23: POSIX Timers (1/1 plans) -- completed 2026-02-15
- [x] Phase 24: Capabilities (1/1 plans) -- completed 2026-02-16
- [x] Phase 25: Seccomp (1/1 plans) -- completed 2026-02-16
- [x] Phase 26: Test Coverage Expansion (2/2 plans) -- completed 2026-02-16

</details>

<details>
<summary>v1.3 Tech Debt Cleanup (Phases 27-35) -- SHIPPED 2026-02-19</summary>

- [x] Phase 27: Quick Wins (2/2 plans) -- completed 2026-02-16
- [x] Phase 28: rt_sigsuspend Race Fix (1/1 plans) -- completed 2026-02-17
- [x] Phase 29: Siginfo Queue (2/2 plans) -- completed 2026-02-17
- [x] Phase 30: Signal Wakeup Integration (1/1 plans) -- completed 2026-02-18
- [x] Phase 31: Inotify Completion (1/1 plans) -- completed 2026-02-18
- [x] Phase 32: Timer Capacity Expansion (1/1 plans) -- completed 2026-02-18
- [x] Phase 33: Timer Resolution Improvement (3/3 plans) -- completed 2026-02-18
- [x] Phase 34: Timer Notification Modes (2/2 plans) -- completed 2026-02-19
- [x] Phase 35: VFS Page Cache and Zero-Copy (2/2 plans) -- completed 2026-02-19

</details>

<details>
<summary>v1.4 Network Stack Hardening (Phases 36-39) -- SHIPPED 2026-02-20</summary>

- [x] Phase 36: RTT Estimation and Congestion Module (2/2 plans) -- completed 2026-02-19
- [x] Phase 37: Dynamic Window Management and Persist Timer (2/2 plans) -- completed 2026-02-19
- [x] Phase 38: Socket Options and Raw Socket Blocking (2/2 plans) -- completed 2026-02-20
- [x] Phase 39: MSG Flags (3/3 plans) -- completed 2026-02-20

</details>

<details>
<summary>v1.5 Tech Debt Cleanup (Phases 40-44) -- SHIPPED 2026-02-22</summary>

- [x] Phase 40: Network Code Fixes (2/2 plans) -- completed 2026-02-21
- [x] Phase 41: Code Cleanup and Documentation (2/2 plans) -- completed 2026-02-21
- [x] Phase 42: QEMU Loopback Setup (1/1 plans) -- completed 2026-02-21
- [x] Phase 43: Network Feature Verification (3/3 plans) -- completed 2026-02-22
- [x] Phase 44: Audit Gap Closure (1/1 plans) -- completed 2026-02-21

</details>

### v2.0 ext2 Filesystem (In Progress)

**Milestone Goal:** Replace SFS with a full ext2 filesystem giving zk proper hierarchical directories, long filenames, and correct POSIX filesystem semantics. SFS remains at /mnt through Phases 45-52; Phase 53 switches the mount point and migrates all tests.

- [x] **Phase 45: Build Infrastructure** - ext2 disk image created at build time, QEMU drive attached, BlockDevice abstraction in place (completed 2026-02-23)
- [x] **Phase 46: Superblock Parse and Read-Only Mount** - ext2 mounts at /mnt2 with validated superblock, feature flags enforced (completed 2026-02-23)
- [ ] **Phase 47: Inode Read and Indirect Block Resolution** - inode reads correct for all indirection levels, root directory inode accessible
- [ ] **Phase 48: Directory Traversal, Path Resolution, and Inode Cache** - multi-level paths resolve, getdents works, stat returns correct metadata, inode cache live
- [ ] **Phase 49: Block and Inode Bitmap Allocation** - alloc and free primitives correct with two-phase lock pattern, superblock counters update atomically
- [ ] **Phase 50: File Write Operations** - create, write, truncate, and unlink all work on ext2 files
- [ ] **Phase 51: Directory Write Operations** - mkdir, rmdir, rename, hard link, and symlink all work on ext2 directories
- [ ] **Phase 52: Metadata and Mount Hardening** - chmod, chown, utimensat, statfs complete; superblock s_state tracks mount cleanly
- [ ] **Phase 53: Test Migration** - ext2 replaces SFS at /mnt, all 186 existing filesystem tests pass against ext2

## Phase Details

### Phase 45: Build Infrastructure
**Goal**: A pre-formatted ext2 disk image is created at build time and attached to QEMU on both architectures, with a driver-agnostic BlockDevice abstraction eliminating position-state races in block I/O.
**Depends on**: Phase 44 (v1.5 complete)
**Requirements**: BUILD-01, BUILD-02, BUILD-03
**Success Criteria** (what must be TRUE):
  1. `zig build -Darch=x86_64` produces ext2.img via mke2fs without manual host steps
  2. QEMU launches with ext2.img attached as a block device on both x86_64 and aarch64
  3. The kernel can call BlockDevice read/write with an explicit LBA and get the correct sector without position state races
  4. `extern struct` on-disk types in types.zig pass `comptime` size assertions at compile time
**Plans:** 2/2 plans complete
Plans:
- [ ] 45-01-PLAN.md -- ext2 disk image creation and QEMU attachment
- [ ] 45-02-PLAN.md -- BlockDevice abstraction and ext2 on-disk types

### Phase 46: Superblock Parse and Read-Only Mount
**Goal**: The kernel can parse an ext2 superblock, validate the magic number and feature flags, derive filesystem geometry, and register the filesystem with VFS for read-only access at /mnt2.
**Depends on**: Phase 45
**Requirements**: MOUNT-01, MOUNT-02, MOUNT-03, MOUNT-04
**Success Criteria** (what must be TRUE):
  1. Kernel logs superblock validation success (magic 0xEF53, block size, group count) on boot with ext2.img present
  2. Kernel panics or logs a clear error and refuses to mount if INCOMPAT feature flags contain unknown bits
  3. ext2 filesystem appears at /mnt2 in the VFS mount table alongside SFS at /mnt
  4. Block group descriptor table is read and group count matches the image geometry
**Plans:** 2/2 plans complete
Plans:
- [ ] 46-01-PLAN.md -- SCSI BlockDevice adapter + ext2 superblock parse, BGDT read, VFS adapter
- [ ] 46-02-PLAN.md -- Wire ext2 mount into boot sequence (init_hw, init_fs, main)

### Phase 47: Inode Read and Indirect Block Resolution
**Goal**: The kernel can read any inode by number with correct 1-based offset calculation and resolve file data through all indirection levels (direct, single-indirect, double-indirect).
**Depends on**: Phase 46
**Requirements**: INODE-01, INODE-02, INODE-03, INODE-04
**Success Criteria** (what must be TRUE):
  1. Reading inode 2 (root directory) returns a valid directory inode with correct mode and size
  2. A file using only direct blocks (<=48KB at 4KB blocks) reads back correctly byte-for-byte
  3. A file using singly indirect blocks (up to ~4MB) reads back correctly byte-for-byte
  4. A file using doubly indirect blocks (up to ~4GB) reads back correctly byte-for-byte
**Plans**: TBD

### Phase 48: Directory Traversal, Path Resolution, and Inode Cache
**Goal**: Users can open, stat, and list files and directories at arbitrary nesting depth on the ext2 mount, with fast symlink resolution and an inode cache eliminating redundant disk reads.
**Depends on**: Phase 47
**Requirements**: DIR-01, DIR-02, DIR-03, DIR-04, DIR-05, INODE-05
**Success Criteria** (what must be TRUE):
  1. `open("/mnt2/a/b/c/file.txt")` succeeds and reads the correct data from a pre-populated ext2 image
  2. `getdents` on an ext2 directory lists all entries including the last entry in each block (rec_len stride correct)
  3. `readlink` on a fast symlink (target <=60 bytes) returns the correct target path
  4. `stat` on an ext2 file returns correct mode, uid, gid, size, nlink, and timestamps
  5. `statfs` on the ext2 mount returns correct free block and inode counts
**Plans**: TBD

### Phase 49: Block and Inode Bitmap Allocation
**Goal**: The kernel can allocate and free blocks and inodes using group bitmaps with the two-phase lock pattern, updating group descriptors and the superblock atomically after each operation without deadlock.
**Depends on**: Phase 48
**Requirements**: ALLOC-01, ALLOC-02, ALLOC-03, ALLOC-04
**Success Criteria** (what must be TRUE):
  1. Allocating a block returns a block number in a valid group, with the bitmap bit set and group free count decremented
  2. Freeing a block clears the bitmap bit and increments the group free count, with the superblock total updated
  3. Allocating an inode returns an inode number in a valid group, with the bitmap bit set and group inode count decremented
  4. Freeing an inode clears the bitmap bit and increments the group inode count, with the superblock total updated
  5. Allocation under heavy use (group exhausted) falls back to the next group without deadlock or hang
**Plans**: TBD

### Phase 50: File Write Operations
**Goal**: Users can create, write, truncate, and delete files on the ext2 mount with correct block allocation, size tracking, and nlink accounting.
**Depends on**: Phase 49
**Requirements**: FILE-01, FILE-02, FILE-03, FILE-04, FILE-05
**Success Criteria** (what must be TRUE):
  1. `open("/mnt2/newfile", O_CREAT|O_WRONLY)` creates a new file visible in getdents
  2. Writing data past a block boundary allocates a new block and the data reads back correctly
  3. `truncate` on a file frees excess blocks; subsequent reads return zeros or ENOENT at truncated position
  4. `unlink` on a file with nlink=1 removes the directory entry and frees all blocks and the inode
  5. `rename` moves a file within the ext2 mount and the old name no longer appears in getdents
**Plans**: TBD

### Phase 51: Directory Write Operations
**Goal**: Users can create and remove directories, create hard links and symbolic links, and rename directories on the ext2 mount, with correct . and .. entries and parent nlink accounting.
**Depends on**: Phase 50
**Requirements**: DWRITE-01, DWRITE-02, DWRITE-03, DWRITE-04, DWRITE-05
**Success Criteria** (what must be TRUE):
  1. `mkdir("/mnt2/subdir")` creates a directory with correct . and .. entries and increments parent nlink
  2. `rmdir` on an empty directory frees its inode and block, removes the parent entry, and decrements parent nlink
  3. `link` creates a hard link; both names appear in getdents and stat shows nlink=2 on both
  4. `symlink` with a target <=60 bytes creates a fast symlink readable via readlink
  5. `rename` on a directory moves it with correct .. update in the renamed directory
**Plans**: TBD

### Phase 52: Metadata and Mount Hardening
**Goal**: Users can update file permissions, ownership, and timestamps on ext2 files, and the superblock correctly tracks mount state so e2fsck reports a clean filesystem after a full run.
**Depends on**: Phase 51
**Requirements**: META-01, META-02, META-03, META-04
**Success Criteria** (what must be TRUE):
  1. `chmod` on an ext2 file updates the inode mode; stat returns the new mode on the next call
  2. `chown` on an ext2 file updates inode uid and gid; stat returns the new values
  3. `utimensat` on an ext2 file updates atime and mtime; stat returns the new timestamps
  4. After a kernel shutdown sequence, running `e2fsck -n ext2.img` reports zero errors (s_state clean)
**Plans**: TBD

### Phase 53: Test Migration
**Goal**: ext2 replaces SFS as the writable filesystem at /mnt; all existing filesystem integration tests pass against ext2, completing the v2.0 milestone.
**Depends on**: Phase 52
**Requirements**: MIGRATE-01, MIGRATE-02
**Success Criteria** (what must be TRUE):
  1. The kernel boots with ext2 at /mnt and SFS no longer in the QEMU drive list
  2. All 186 existing filesystem integration tests pass (with the same 20 pre-existing skips, none ext2-specific)
  3. No SFS-specific tests remain that reference /mnt paths expecting SFS flat-directory behavior
**Plans**: TBD

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Trivial Stubs | v1.0 | 4/4 | Complete | 2026-02-06 |
| 2. UID/GID Infrastructure | v1.0 | 3/3 | Complete | 2026-02-06 |
| 3. File Ownership | v1.0 | 2/2 | Complete | 2026-02-06 |
| 4. I/O Multiplexing Infrastructure | v1.0 | 3/3 | Complete | 2026-02-07 |
| 5. Event Notification FDs | v1.0 | 3/3 | Complete | 2026-02-07 |
| 6. Vectored & Positional I/O | v1.0 | 3/3 | Complete | 2026-02-08 |
| 7. Filesystem Extras | v1.0 | 3/3 | Complete | 2026-02-08 |
| 8. Socket Extras | v1.0 | 3/3 | Complete | 2026-02-08 |
| 9. Process Control & SysV IPC | v1.0 | 5/5 | Complete | 2026-02-09 |
| 10. Critical Kernel Bugs | v1.1 | 3/3 | Complete | 2026-02-09 |
| 11. SFS Deadlock Fix | v1.1 | 1/1 | Complete | 2026-02-09 |
| 12. SFS Hard Link Support | v1.1 | 2/2 | Complete | 2026-02-10 |
| 13. SFS Symlink & Timestamp Support | v1.1 | 2/2 | Complete | 2026-02-10 |
| 14. WaitQueue Blocking & Optimizations | v1.1 | 7/7 | Complete | 2026-02-11 |
| 15. File Synchronization | v1.2 | 1/1 | Complete | 2026-02-12 |
| 16. Advanced File Operations | v1.2 | 1/1 | Complete | 2026-02-12 |
| 17. Zero-Copy I/O | v1.2 | 2/2 | Complete | 2026-02-13 |
| 18. Memory Management Extensions | v1.2 | 1/1 | Complete | 2026-02-13 |
| 19. Process Control Extensions | v1.2 | 1/1 | Complete | 2026-02-14 |
| 20. Signal Handling Extensions | v1.2 | 1/1 | Complete | 2026-02-14 |
| 21. I/O Multiplexing Extension | v1.2 | 1/1 | Complete | 2026-02-15 |
| 22. File Monitoring | v1.2 | 1/1 | Complete | 2026-02-15 |
| 23. POSIX Timers | v1.2 | 1/1 | Complete | 2026-02-15 |
| 24. Capabilities | v1.2 | 1/1 | Complete | 2026-02-16 |
| 25. Seccomp | v1.2 | 1/1 | Complete | 2026-02-16 |
| 26. Test Coverage Expansion | v1.2 | 2/2 | Complete | 2026-02-16 |
| 27. Quick Wins | v1.3 | 2/2 | Complete | 2026-02-16 |
| 28. rt_sigsuspend Race Fix | v1.3 | 1/1 | Complete | 2026-02-17 |
| 29. Siginfo Queue | v1.3 | 2/2 | Complete | 2026-02-17 |
| 30. Signal Wakeup Integration | v1.3 | 1/1 | Complete | 2026-02-18 |
| 31. Inotify Completion | v1.3 | 1/1 | Complete | 2026-02-18 |
| 32. Timer Capacity Expansion | v1.3 | 1/1 | Complete | 2026-02-18 |
| 33. Timer Resolution Improvement | v1.3 | 3/3 | Complete | 2026-02-18 |
| 34. Timer Notification Modes | v1.3 | 2/2 | Complete | 2026-02-19 |
| 35. VFS Page Cache and Zero-Copy | v1.3 | 2/2 | Complete | 2026-02-19 |
| 36. RTT Estimation and Congestion Module | v1.4 | 2/2 | Complete | 2026-02-19 |
| 37. Dynamic Window Management and Persist Timer | v1.4 | 2/2 | Complete | 2026-02-19 |
| 38. Socket Options and Raw Socket Blocking | v1.4 | 2/2 | Complete | 2026-02-20 |
| 39. MSG Flags | v1.4 | 3/3 | Complete | 2026-02-20 |
| 40. Network Code Fixes | v1.5 | 2/2 | Complete | 2026-02-21 |
| 41. Code Cleanup and Documentation | v1.5 | 2/2 | Complete | 2026-02-21 |
| 42. QEMU Loopback Setup | v1.5 | 1/1 | Complete | 2026-02-21 |
| 43. Network Feature Verification | v1.5 | 3/3 | Complete | 2026-02-22 |
| 44. Audit Gap Closure | v1.5 | 1/1 | Complete | 2026-02-21 |
| 45. Build Infrastructure | 2/2 | Complete    | 2026-02-23 | - |
| 46. Superblock Parse and Read-Only Mount | 2/2 | Complete   | 2026-02-23 | - |
| 47. Inode Read and Indirect Block Resolution | v2.0 | 0/TBD | Not started | - |
| 48. Directory Traversal, Path Resolution, and Inode Cache | v2.0 | 0/TBD | Not started | - |
| 49. Block and Inode Bitmap Allocation | v2.0 | 0/TBD | Not started | - |
| 50. File Write Operations | v2.0 | 0/TBD | Not started | - |
| 51. Directory Write Operations | v2.0 | 0/TBD | Not started | - |
| 52. Metadata and Mount Hardening | v2.0 | 0/TBD | Not started | - |
| 53. Test Migration | v2.0 | 0/TBD | Not started | - |

---
*Roadmap created: 2026-02-06*
*Last updated: 2026-02-22 -- Phase 45 planned (2 plans)*
