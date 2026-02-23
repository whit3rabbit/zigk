# Requirements: ZK Kernel ext2 Filesystem

**Defined:** 2026-02-22
**Core Value:** Every implemented syscall must work correctly on both x86_64 and aarch64 with matching behavior, tested via the existing integration test harness.

## v2.0 Requirements

Requirements for ext2 filesystem implementation. Each maps to roadmap phases.

### Build Infrastructure

- [x] **BUILD-01**: Build system creates a pre-formatted ext2 disk image via host mkfs.ext2
- [x] **BUILD-02**: QEMU launches with ext2 image attached as a block device on both x86_64 and aarch64
- [x] **BUILD-03**: BlockDevice abstraction provides driver-portable read/write by LBA without position state races

### Read-Only Mount

- [x] **MOUNT-01**: Kernel parses ext2 superblock, validates magic (0xEF53), and derives block size
- [x] **MOUNT-02**: Kernel reads block group descriptor table and validates group counts
- [x] **MOUNT-03**: Kernel checks INCOMPAT feature flags and refuses to mount unsupported features
- [x] **MOUNT-04**: ext2 filesystem registers with VFS and mounts at a writable mount point

### Inode and Block I/O

- [ ] **INODE-01**: Kernel reads inodes by number with correct 1-based offset calculation
- [ ] **INODE-02**: Kernel resolves file data via direct blocks (i_block[0..11])
- [ ] **INODE-03**: Kernel resolves file data via singly indirect blocks (i_block[12])
- [ ] **INODE-04**: Kernel resolves file data via doubly indirect blocks (i_block[13])
- [ ] **INODE-05**: Inode cache (fixed-size LRU) avoids redundant disk reads during path traversal

### Directory and Path Resolution

- [ ] **DIR-01**: Kernel traverses nested directories to resolve multi-component paths
- [ ] **DIR-02**: Kernel lists directory contents via getdents with correct rec_len stride
- [ ] **DIR-03**: Kernel reads fast symlinks (target in i_block[], <=60 bytes)
- [ ] **DIR-04**: stat_path returns correct metadata (mode, uid, gid, size, timestamps, nlink)
- [ ] **DIR-05**: statfs returns filesystem-level free space and inode counts

### Block and Inode Allocation

- [ ] **ALLOC-01**: Kernel allocates free blocks from block group bitmaps with group locality
- [ ] **ALLOC-02**: Kernel frees blocks and updates bitmap + group descriptor + superblock atomically
- [ ] **ALLOC-03**: Kernel allocates free inodes from inode group bitmaps
- [ ] **ALLOC-04**: Kernel frees inodes and updates bitmap + group descriptor + superblock atomically

### File Write Operations

- [ ] **FILE-01**: User can create new files (open with O_CREAT allocates inode and directory entry)
- [ ] **FILE-02**: User can write data to files (extending block allocation as needed)
- [ ] **FILE-03**: User can truncate files (freeing excess blocks)
- [ ] **FILE-04**: User can delete files (unlink decrements nlink, frees blocks at nlink=0)
- [ ] **FILE-05**: User can rename files within the filesystem

### Directory Write Operations

- [ ] **DWRITE-01**: User can create directories (mkdir allocates inode, creates . and .. entries)
- [ ] **DWRITE-02**: User can remove empty directories (rmdir verifies empty, frees resources)
- [ ] **DWRITE-03**: User can create hard links (link increments nlink, adds directory entry)
- [ ] **DWRITE-04**: User can create symbolic links (symlink with fast path for short targets)
- [ ] **DWRITE-05**: User can rename directories

### Metadata Operations

- [ ] **META-01**: User can change file permissions (chmod updates inode mode)
- [ ] **META-02**: User can change file ownership (chown updates inode uid/gid)
- [ ] **META-03**: User can set timestamps (utimensat updates inode atime/mtime)
- [ ] **META-04**: Kernel writes superblock mount state (dirty on mount, clean on unmount)

### Test Migration

- [ ] **MIGRATE-01**: Existing filesystem integration tests pass when targeting ext2 mount point
- [ ] **MIGRATE-02**: ext2 functions as drop-in SFS replacement for all writable filesystem operations

## v2.1+ Requirements

Deferred to future release. Tracked but not in current roadmap.

### Advanced ext2 Features

- **ADV-01**: Triply indirect block reads (i_block[14]) for files >4GB
- **ADV-02**: Slow symlinks (target stored in data block, >60 bytes)
- **ADV-03**: Sparse file support (i_block[n]==0 returns zeroes)
- **ADV-04**: HTree indexed directory support for O(log n) lookup
- **ADV-05**: Superblock mount count tracking and max mount warnings

### Journaling (ext3 upgrade path)

- **JOURNAL-01**: Write-ahead logging for metadata operations
- **JOURNAL-02**: Journal replay on unclean mount detection

## Out of Scope

| Feature | Reason |
|---------|--------|
| ext4 extents | Different on-disk format, separate milestone |
| ext4 64-bit block numbers | ext2 supports up to 4TB at 4KB blocks, sufficient |
| Online resize (resize2fs) | Fixed-size images created at build time |
| Extended attributes (xattr) | Complex, depends on security model not yet designed |
| POSIX ACLs | Implemented via xattr, deferred with it |
| Transparent compression | INCOMPAT flag -- refuse to mount if present |
| CUBIC/BBR congestion control | Unrelated to filesystem milestone |
| In-kernel mkfs | Pre-format on host with e2fsprogs, safer and simpler |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| BUILD-01 | Phase 45 | Complete |
| BUILD-02 | Phase 45 | Complete |
| BUILD-03 | Phase 45 | Complete |
| MOUNT-01 | Phase 46 | Complete |
| MOUNT-02 | Phase 46 | Complete |
| MOUNT-03 | Phase 46 | Complete |
| MOUNT-04 | Phase 46 | Complete |
| INODE-01 | Phase 47 | Pending |
| INODE-02 | Phase 47 | Pending |
| INODE-03 | Phase 47 | Pending |
| INODE-04 | Phase 47 | Pending |
| INODE-05 | Phase 48 | Pending |
| DIR-01 | Phase 48 | Pending |
| DIR-02 | Phase 48 | Pending |
| DIR-03 | Phase 48 | Pending |
| DIR-04 | Phase 48 | Pending |
| DIR-05 | Phase 48 | Pending |
| ALLOC-01 | Phase 49 | Pending |
| ALLOC-02 | Phase 49 | Pending |
| ALLOC-03 | Phase 49 | Pending |
| ALLOC-04 | Phase 49 | Pending |
| FILE-01 | Phase 50 | Pending |
| FILE-02 | Phase 50 | Pending |
| FILE-03 | Phase 50 | Pending |
| FILE-04 | Phase 50 | Pending |
| FILE-05 | Phase 50 | Pending |
| DWRITE-01 | Phase 51 | Pending |
| DWRITE-02 | Phase 51 | Pending |
| DWRITE-03 | Phase 51 | Pending |
| DWRITE-04 | Phase 51 | Pending |
| DWRITE-05 | Phase 51 | Pending |
| META-01 | Phase 52 | Pending |
| META-02 | Phase 52 | Pending |
| META-03 | Phase 52 | Pending |
| META-04 | Phase 52 | Pending |
| MIGRATE-01 | Phase 53 | Pending |
| MIGRATE-02 | Phase 53 | Pending |

**Coverage:**
- v2.0 requirements: 37 total
- Mapped to phases: 37
- Unmapped: 0

---
*Requirements defined: 2026-02-22*
*Last updated: 2026-02-22 after roadmap creation (all 37 requirements mapped)*
