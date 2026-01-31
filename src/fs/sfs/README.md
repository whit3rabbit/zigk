# SFS (Simple File System)

A lightweight, flat-structure filesystem for the ZK microkernel with driver-agnostic I/O.

## Architecture Overview

SFS provides a simple, persistent filesystem mounted at `/mnt` with the following characteristics:

- **Flat directory structure** (no nested subdirectories)
- **64 files maximum** per filesystem
- **32-character filename limit**
- **512-byte sector size** (standard disk blocks)
- **Driver-agnostic I/O** (works with AHCI, VirtIO-SCSI, NVMe)

## Directory Layout

```
src/fs/sfs/
├── README.md          # This file
├── root.zig           # Filesystem initialization and mounting
├── types.zig          # Core data structures (Superblock, DirEntry, SfsFile)
├── io.zig             # Driver-agnostic sector I/O operations
├── alloc.zig          # Block allocation and bitmap management
└── ops.zig            # File operations (read, write, open, close, etc.)
```

## Layer Architecture

SFS follows a clean layered architecture that abstracts hardware details:

```
┌─────────────────────────────────────────────────────────────┐
│ Userspace (sys_write, sys_read, sys_open)                  │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ VFS Layer (vfs.open, path routing)                          │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ SFS Layer                                                    │
│  - ops.zig: sfsRead, sfsWrite, sfsOpen                      │
│  - io.zig: readSector, writeSector, readSectorsAsync        │
│  - alloc.zig: allocateBlock, freeBlock, loadBitmapBatch     │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ File Descriptor Layer (device_fd.ops.read/write)            │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Block Device Driver Layer                                   │
│  - AHCI: ahci/adapter.zig (x86_64)                          │
│  - VirtIO-SCSI: virtio/scsi/adapter.zig (aarch64)           │
│  - NVMe: nvme/adapter.zig                                   │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Hardware (DMA with physical addresses)                      │
└─────────────────────────────────────────────────────────────┘
```

### Key Design Principle: Driver Agnosticism

**All SFS I/O operations use file descriptor-based abstractions**, not direct driver calls.

**Correct (current implementation):**
```zig
// io.zig
pub fn writeSector(device_fd: *fd.FileDescriptor, lba: u32, buf: []const u8) !void {
    device_fd.position = @as(u64, lba) * 512;
    if (device_fd.ops.write) |write_fn| {
        const bytes_written = write_fn(device_fd, buf[0..512]);
        // ... error handling
    }
}
```

**Incorrect (old implementation - DO NOT USE):**
```zig
// ❌ WRONG: Hardcoded to AHCI controller
pub fn writeSectorAsync(self: *SFS, lba: u32, buf: []const u8) !void {
    const controller = ahci.getController() orelse return error.IOError;  // ❌ FAILS ON VIRTIO-SCSI
    controller.writeSectors(self.port_num, lba, 1, buf);
}
```

**Why this matters:**
- **x86_64 systems** typically use AHCI (SATA) controllers
- **aarch64 systems** use VirtIO-SCSI or NVMe
- File descriptor abstraction works on **any block device driver**
- Eliminates platform-specific code paths

## On-Disk Layout

SFS uses a simple linear layout on the block device:

```
┌──────────────────────────────────────────────────────────────┐
│ LBA 0: Superblock (512 bytes)                               │
│  - Magic: 0x53465330                                         │
│  - Version, block counts, free block tracking                │
├──────────────────────────────────────────────────────────────┤
│ LBA 1-16: Allocation Bitmap (16 blocks = 8KB)               │
│  - 1 bit per data block (0=free, 1=allocated)               │
│  - Supports up to 65,536 data blocks (32MB filesystem)       │
├──────────────────────────────────────────────────────────────┤
│ LBA 17-20: Root Directory (4 blocks = 2KB)                  │
│  - 64 directory entries × 32 bytes each                      │
│  - Entry format: name[32], start_block, size, mode, times    │
├──────────────────────────────────────────────────────────────┤
│ LBA 21+: Data Blocks                                         │
│  - File contents stored contiguously                         │
│  - Allocation managed by bitmap and next_free_block          │
└──────────────────────────────────────────────────────────────┘
```

### Superblock Structure

```zig
pub const Superblock = extern struct {
    magic: u32,              // 0x53465330 (SFS0)
    version: u32,            // Current: 1
    block_size: u32,         // 512 bytes
    total_blocks: u32,       // Total disk blocks
    file_count: u32,         // Active files (max 64)
    free_blocks: u32,        // Available blocks for allocation
    bitmap_start: u32,       // LBA 1
    bitmap_blocks: u32,      // 16 blocks
    root_dir_start: u32,     // LBA 17
    data_start: u32,         // LBA 21
    next_free_block: u32,    // Hint for fast allocation
};
```

## Core Operations

### File Creation Flow

```
1. sys_open("/mnt/file.txt", O_CREAT)
   ↓
2. VFS routes to sfsOpen (ops.zig)
   ↓
3. sfsOpen calls allocateBlock (alloc.zig)
   ↓
4. allocateBlock:
   - Acquires alloc_lock
   - Loads bitmap via loadBitmapBatch → readSector (FD-based)
   - Finds free bit in bitmap
   - Writes updated bitmap sector via writeSector (FD-based)
   - Updates superblock via writeSector (FD-based)
   ↓
5. Creates DirEntry in root directory
   ↓
6. Returns FileDescriptor to userspace
```

### Write Operation Flow

```
1. sys_write(fd, buf, len)
   ↓
2. VFS calls fd.ops.write → sfsWrite (ops.zig)
   ↓
3. sfsWrite checks if blocks needed:
   - If growing: allocate blocks under alloc_lock
   - Persist superblock changes
   ↓
4. Write data:
   - Aligned writes: call writeSectorsAsync directly
   - Unaligned writes: read-modify-write with bounce buffer
   ↓
5. writeSectorsAsync → writeSector (io.zig)
   ↓
6. writeSector uses device_fd.ops.write (driver-agnostic)
   ↓
7. Driver layer (AHCI/VirtIO-SCSI/NVMe) performs DMA
```

### Read Operation Flow

Similar to write, but uses `readSector`/`readSectorsAsync` and no allocation needed.

## Key Features

### 1. TOCTOU Protection

File size checks are **refreshed under lock** to prevent time-of-check-to-time-of-use races:

```zig
pub fn sfsRead(file_desc: *fd.FileDescriptor, buf: []u8) isize {
    const held = file_desc.lock.acquire();
    defer held.release();

    // SECURITY: Refresh size under lock (prevents TOCTOU)
    const current_size = refreshSizeFromDisk(file) orelse return 0;
    if (current_size < file.size) {
        file.size = current_size;  // Another process truncated the file
    }
    // ... proceed with validated size
}
```

### 2. Allocation Lock Ordering

To prevent deadlocks, locks are acquired in strict order:

1. `file_desc.lock` (held by syscall layer)
2. `alloc_lock` (for bitmap/superblock)
3. **Never** call blocking I/O while holding `alloc_lock`

### 3. Bitmap Caching

The bitmap is cached in memory (8KB) to reduce disk I/O:

```zig
// Allocated during mount (root.zig)
self.bitmap_cache = alloc.alloc(u8, bitmap_size) catch null;
self.bitmap_cache_valid = false;

// Loaded on first use (alloc.zig)
if (self.bitmap_cache) |cache| {
    if (!self.bitmap_cache_valid) {
        loadBitmapIntoCached(self, cache);  // FD-based read
        self.bitmap_cache_valid = true;
    }
}
```

### 4. Security Features

- **Filename validation**: Prevents path traversal (`../`), null bytes, control characters
- **Bounds checking**: All offset calculations use checked arithmetic to prevent overflow
- **Input validation**: Superblock fields validated on mount to prevent malicious disk images
- **SMAP compliance**: User pointers never dereferenced directly (uses `UserPtr`)

## File Limitations

| Limit | Value | Rationale |
|-------|-------|-----------|
| Max files | 64 | 4 blocks × 512 bytes / 32 bytes per entry |
| Max filename | 31 chars | 32-byte entry with null terminator |
| Max file size | ~32MB | Limited by bitmap size (16 blocks) |
| Directory nesting | 0 (flat) | Simplicity for embedded systems |

## Testing

SFS is covered by integration tests in `src/user/test_runner/tests/`:

- `file_io.zig`: Basic read/write/open/close operations
- `sfs.zig`: SFS-specific tests (create, write, capacity)
- `regression.zig`: TOCTOU protection, deadlock prevention, max capacity

Run tests:
```bash
zig build test-kernel              # All tests
./scripts/run_tests.sh             # x86_64 automated
ARCH=aarch64 ./scripts/run_tests.sh  # aarch64 automated
```

## Porting to New Drivers

To add a new block device driver:

1. Implement `FileOps` in your driver's adapter:
   ```zig
   pub const block_ops = FileOps{
       .read = blockRead,
       .write = blockWrite,
       .close = blockClose,
       .seek = blockSeek,
       .stat = blockStat,
       // ... other ops
   };
   ```

2. Register device in DevFS:
   ```zig
   try devfs.registerDevice("sda", &your_driver.block_ops, private_data);
   ```

3. SFS will automatically work with your driver - **no SFS code changes needed**

## Historical Notes

### Why the Refactor (January 2025)?

Originally, SFS I/O was hardcoded to AHCI:

```zig
// Old code (BROKEN on aarch64)
const controller = ahci.getController() orelse return error.IOError;
controller.writeSectors(port_num, lba, count, buf);
```

This failed on aarch64 systems using VirtIO-SCSI because `ahci.getController()` returned null.

The fix refactored all I/O to use file descriptors:

```zig
// New code (works everywhere)
try writeSector(self.device_fd, lba, buf);
```

**Impact:**
- 185 lines removed
- Works on x86_64 (AHCI), aarch64 (VirtIO-SCSI), and NVMe
- All 70 tests pass on both architectures

## References

- VFS layer: `src/fs/vfs.zig`
- DevFS (device registration): `src/kernel/fs/devfs.zig`
- File descriptors: `src/kernel/fd.zig`
- AHCI driver: `src/drivers/storage/ahci/`
- VirtIO-SCSI driver: `src/drivers/virtio/scsi/`
- Test suite: `src/user/test_runner/tests/`

## License

Part of the ZK microkernel project.
