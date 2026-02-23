# Phase 47: Inode Read and Indirect Block Resolution - Research

**Researched:** 2026-02-23
**Domain:** ext2 filesystem -- inode location math, block indirection, VFS FileDescriptor creation
**Confidence:** HIGH

## Summary

Phase 47 extends the Phase 46 ext2 mount stub to perform real inode lookups. The on-disk types (`Inode`, `GroupDescriptor`, `Superblock`) are fully defined in `src/fs/ext2/types.zig`. The `Ext2Fs` struct and `BlockDevice` vtable exist in `src/fs/ext2/mount.zig`. All arithmetic formulas for inode location are well-specified by the ext2 standard and map directly onto existing constants in `types.zig`.

The four requirements (INODE-01 through INODE-04) decompose into three distinct problems: (1) inode table lookup by inode number using BGDT + 1-based offset calculation, (2) translating a logical file block number to a physical disk block through direct blocks (i_block[0..11]), (3) singly indirect block resolution through one level of indirection (i_block[12]), and (4) doubly indirect block resolution through two levels (i_block[13]). The block buffer for indirection tables is always exactly one filesystem block (4096 bytes for the test images) and must be heap-allocated to avoid kernel stack overflow.

The VFS integration path is clear: `ext2Open` (currently a stub returning `NotFound`) must perform path-to-inode lookup via directory traversal, then construct a `FileDescriptor` with read/seek/close callbacks using `fd.createFd()`. However, Phase 47's scope is inode read and block resolution -- not full directory traversal. The success criteria do not require `open("/mnt2/foo")` to work; they require that an inode number can be resolved correctly given direct input. The deliverable is an internal `readInode(fs, inum)` function and a `readFileBlock(fs, inode, logical_block)` function. Directory traversal (which calls these) is Phase 48.

The critical open concern from STATE.md is the aarch64 ext2 LUN: VirtIO-SCSI target 1 fails BAD_TARGET on QEMU 10.x/HVF for aarch64. The ext2 block device may not be present at all on aarch64. Phase 47 must degrade gracefully when `ext2_block_dev == null` -- no code paths in Phase 47 should panic or fail the boot. All new ext2 code is only reachable through VFS open on `/mnt2`, which silently returns `NotFound` when the device is absent.

**Primary recommendation:** Add `readInode` and `readFileBlock` to `src/fs/ext2/mount.zig` (or a new `src/fs/ext2/inode.zig`), wire them into an updated `ext2Open` that performs single-component path lookup against the root directory, and add userspace integration tests that open a known file from the ext2 image and verify byte-for-byte correctness.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| INODE-01 | Kernel reads inodes by number with correct 1-based offset calculation | Formula: `(inum-1) % ipg` gives intra-group offset; group = `(inum-1) / ipg`; byte offset = `gd.bg_inode_table * block_size + offset_in_group * inode_size`. Constants: `s_inodes_per_group`, `s_inode_size` from Superblock, `bg_inode_table` from GroupDescriptor. |
| INODE-02 | Kernel resolves file data via direct blocks (i_block[0..11]) | `inode.i_block[logical_block]` gives physical block number directly for logical_block < 12. Physical LBA = `block_num * sectors_per_block`. Zero block number (i_block[n] == 0) means sparse hole -- return zeros per ADV-03, deferred but benign to handle now. |
| INODE-03 | Kernel resolves file data via singly indirect blocks (i_block[12]) | Read i_block[12] as a block of u32 pointers. Index = `logical_block - 12`. Block contains `block_size / 4` pointers. For 4KB blocks: 1024 pointers, covering up to 1024 additional blocks (4MB). |
| INODE-04 | Kernel resolves file data via doubly indirect blocks (i_block[13]) | Read i_block[13] as outer table, then index by `(logical_block - 12 - ptrs_per_block) / ptrs_per_block` to get inner table block, then index inner table by remainder. For 4KB blocks: covers blocks 12+1024 through 12+1024+1024^2. |
</phase_requirements>

## Standard Stack

### Core

| Component | Location | Purpose | Why Standard |
|-----------|----------|---------|--------------|
| `src/fs/ext2/types.zig` | Existing | Inode struct (128 bytes), GroupDescriptor, Superblock helpers | Comptime-verified layouts, inode_size field handles dynamic rev |
| `src/fs/ext2/mount.zig` | Existing | Ext2Fs state (dev, superblock, block_groups), VFS callbacks | Phase 46 deliverable; this phase extends it |
| `src/fs/block_device.zig` | Existing | `BlockDevice.readSectors(lba, count, buf)` | All disk reads go through this; bounds-checked, driver-portable |
| `src/kernel/fs/fd.zig` | Existing | `createFd(ops, flags, private_data)` | Standard FD creation, refcounted, sets cloexec from flags |
| `src/fs/meta.zig` | Existing | `FileMeta` struct | Returned by `ext2StatPath`; has mode, uid, gid, ino, size |
| `heap.allocator()` | Existing | Block buffer allocation | Indirect block tables are 4KB -- must be heap-allocated |
| `std.math.add/mul` | std lib | Overflow-safe inode offset arithmetic | CLAUDE.md rule 5, mandatory for all offset calculations |

### New Files to Create

| File | Purpose |
|------|---------|
| `src/fs/ext2/inode.zig` | `readInode(fs, inum)`, `resolveBlock(fs, inode, logical_block)`, `Ext2File` private_data struct |

Alternatively, these functions can be added directly to `mount.zig`. A separate `inode.zig` is cleaner because Phase 48 (directory traversal) will add more functions to the same file. Either approach compiles identically. Recommendation: use `inode.zig` to keep `mount.zig` focused on init/VFS wiring.

### Supporting

| Component | Purpose | When to Use |
|-----------|---------|-------------|
| `console.err/warn/info` | Diagnostic logging | All inode resolution errors should log block number and inode number |
| `std.mem.bytesAsSlice(u32, buf)` | Cast raw block bytes to u32 pointer table | Interpreting indirect block tables |
| `@memset(buf, 0)` | Zero-initialize before reads | Security: DMA hygiene (CLAUDE.md rule 3) |

## Architecture Patterns

### Recommended Structure

```
src/fs/ext2/
    types.zig       # EXISTING: on-disk structs (Phase 45-02)
    mount.zig       # EXISTING: Ext2Fs state, init(), VFS callbacks (Phase 46)
    inode.zig       # NEW: readInode(), resolveBlock(), Ext2File, FileOps vtable
```

`src/fs/root.zig` already re-exports `ext2/mount.zig`. Add `pub const ext2_inode = @import("ext2/inode.zig");` if needed, or keep inode.zig internal to mount.zig via `const inode = @import("inode.zig");`.

### Pattern 1: Inode Location Formula (INODE-01)

The ext2 inode numbering is 1-based. Inode 1 is the bad block inode, inode 2 is the root directory. The formula maps inode number to a physical disk offset:

```zig
// Source: ext2 spec section 4.2
// Inode numbers are 1-based. inodes_per_group (ipg) = sb.s_inodes_per_group
pub fn readInode(fs: *Ext2Fs, inum: u32) Ext2Error!types.Inode {
    if (inum == 0) return error.InvalidInode; // inode 0 is reserved/invalid
    const ipg = fs.superblock.s_inodes_per_group;
    if (ipg == 0) return error.InvalidSuperblock;

    // Which block group?
    const group_idx = (inum - 1) / ipg;
    if (group_idx >= fs.group_count) return error.InvalidInode;

    // Offset within the group's inode table (0-based)
    const offset_in_group = (inum - 1) % ipg;

    // Block group descriptor for this group
    const gd = fs.block_groups[group_idx];
    const inode_table_block = gd.bg_inode_table;

    // Byte offset from the start of the inode table block
    const inode_size: u64 = @as(u64, fs.inode_size);
    const byte_offset_in_table = std.math.mul(u64, @as(u64, offset_in_group), inode_size)
        catch return error.InvalidInode;

    // Absolute byte offset on disk = inode_table_block * block_size + byte_offset_in_table
    const block_size: u64 = @as(u64, fs.block_size);
    const table_start_byte = std.math.mul(u64, @as(u64, inode_table_block), block_size)
        catch return error.InvalidInode;
    const inode_byte_offset = std.math.add(u64, table_start_byte, byte_offset_in_table)
        catch return error.InvalidInode;

    // Convert byte offset to LBA (SECTOR_SIZE = 512)
    const lba = inode_byte_offset / SECTOR_SIZE;
    const byte_in_sector = @as(usize, inode_byte_offset % SECTOR_SIZE);

    // Read enough sectors to cover the inode
    // An inode is at most 128 bytes (GOOD_OLD_REV) or up to 256 bytes (DYNAMIC_REV)
    // Worst case: inode crosses a sector boundary at byte 384 of a sector -> spans 2 sectors
    const sectors_needed: u32 = if (byte_in_sector + fs.inode_size > SECTOR_SIZE) 2 else 1;

    // SECURITY: Zero-initialize buffer before DMA read (CLAUDE.md rule 3)
    var buf: [2 * SECTOR_SIZE]u8 align(4) = [_]u8{0} ** (2 * SECTOR_SIZE);
    fs.dev.readSectors(lba, sectors_needed, buf[0 .. sectors_needed * SECTOR_SIZE])
        catch return error.IOError;

    // Cast to Inode -- only first 128 bytes are valid (inode_size <= sizeof Inode for now)
    const inode: types.Inode = @as(*const types.Inode,
        @ptrCast(@alignCast(buf[byte_in_sector..].ptr))).*;

    return inode;
}
```

**Critical detail**: `inode_size` from the superblock (via `fs.inode_size`) determines the stride in the inode table, but the on-disk `Inode` struct is always 128 bytes for the fields we care about. For DYNAMIC_REV images with `s_inode_size > 128`, the inode table entries are larger, but the first 128 bytes are the standard fields. The cast to `types.Inode` (128 bytes) is safe as long as we read at least `byte_in_sector + 128` bytes.

### Pattern 2: Block Resolution -- Direct Blocks (INODE-02)

```zig
// Source: ext2 spec section 4.4
// logical_block: 0-indexed block offset within the file
// Returns: physical block number (0 = sparse/unallocated = return zeros, ADV-03)
pub fn resolveBlock(fs: *Ext2Fs, inode: *const types.Inode, logical_block: u32) Ext2Error!u32 {
    const ptrs_per_block: u32 = fs.block_size / 4; // u32 pointers per block

    if (logical_block < types.DIRECT_BLOCKS) {
        // Direct: i_block[0..11]
        return inode.i_block[logical_block];
    }

    // Subtract direct range for single-indirect and beyond
    const lb_after_direct = logical_block - types.DIRECT_BLOCKS;
    // ...
}
```

For a file <= 48KB (at 4KB block size, 12 direct blocks * 4096 = 49152 bytes, but i_size caps it), all blocks are direct. INODE-02 is the simplest case.

### Pattern 3: Singly Indirect Blocks (INODE-03)

```zig
// logical_block >= 12
// Indirect block is i_block[12], which is itself a block of u32 physical block numbers
if (lb_after_direct < ptrs_per_block) {
    const indirect_block_num = inode.i_block[types.INDIRECT_BLOCK];
    if (indirect_block_num == 0) return 0; // sparse

    // SECURITY: Heap-allocate to avoid 4KB stack overflow (CLAUDE.md: Large struct return-by-value)
    const alloc = heap.allocator();
    const block_buf = alloc.alloc(u8, fs.block_size) catch return error.OutOfMemory;
    defer alloc.free(block_buf);
    @memset(block_buf, 0); // DMA hygiene

    const lba = std.math.mul(u64, @as(u64, indirect_block_num),
        @as(u64, fs.sectors_per_block)) catch return error.InvalidInode;
    fs.dev.readSectors(lba, fs.sectors_per_block, block_buf) catch return error.IOError;

    const ptrs = std.mem.bytesAsSlice(u32, block_buf);
    return ptrs[lb_after_direct]; // physical block number
}
```

### Pattern 4: Doubly Indirect Blocks (INODE-04)

```zig
// logical_block >= 12 + ptrs_per_block
const lb_after_single = lb_after_direct - ptrs_per_block;
if (lb_after_single < ptrs_per_block * ptrs_per_block) {
    const dindirect_block_num = inode.i_block[types.DOUBLE_INDIRECT_BLOCK];
    if (dindirect_block_num == 0) return 0; // sparse

    const alloc = heap.allocator();

    // Read outer (double-indirect) table
    const outer_buf = alloc.alloc(u8, fs.block_size) catch return error.OutOfMemory;
    defer alloc.free(outer_buf);
    @memset(outer_buf, 0);

    const outer_lba = std.math.mul(u64, @as(u64, dindirect_block_num),
        @as(u64, fs.sectors_per_block)) catch return error.InvalidInode;
    fs.dev.readSectors(outer_lba, fs.sectors_per_block, outer_buf) catch return error.IOError;

    const outer_ptrs = std.mem.bytesAsSlice(u32, outer_buf);
    const outer_idx = lb_after_single / ptrs_per_block;
    const inner_block_num = outer_ptrs[outer_idx];
    if (inner_block_num == 0) return 0; // sparse

    // Read inner (single-indirect) table
    const inner_buf = alloc.alloc(u8, fs.block_size) catch return error.OutOfMemory;
    defer alloc.free(inner_buf);
    @memset(inner_buf, 0);

    const inner_lba = std.math.mul(u64, @as(u64, inner_block_num),
        @as(u64, fs.sectors_per_block)) catch return error.InvalidInode;
    fs.dev.readSectors(inner_lba, fs.sectors_per_block, inner_buf) catch return error.IOError;

    const inner_ptrs = std.mem.bytesAsSlice(u32, inner_buf);
    const inner_idx = lb_after_single % ptrs_per_block;
    return inner_ptrs[inner_idx];
}

return error.FileTooLarge; // Triple-indirect (ADV-01, deferred)
```

### Pattern 5: FileDescriptor Creation for ext2 Files

Following the SFS `sfsOpen` pattern (`src/fs/sfs/ops.zig:436`) and `fd.createFd` (`src/kernel/fs/fd.zig:532`):

```zig
// Ext2File: private_data for FileDescriptor
const Ext2File = struct {
    fs: *Ext2Fs,
    inode_num: u32,
    inode: types.Inode,
    size: u64,
};

// FileOps vtable for ext2 regular files
const ext2_file_ops = fd.FileOps{
    .read = ext2FileRead,
    .write = null,      // Read-only Phase 47
    .close = ext2FileClose,
    .seek = ext2FileSeek,
    .stat = ext2FileStat,
    .ioctl = null,
    .mmap = null,
    .poll = null,
    .truncate = null,
};

fn ext2Open(ctx: ?*anyopaque, path: []const u8, flags: u32) vfs.Error!*fd.FileDescriptor {
    const fs: *Ext2Fs = @ptrCast(@alignCast(ctx.?));

    // Phase 47: reject writes (read-only)
    if ((flags & fd.O_ACCMODE) != fd.O_RDONLY) return error.AccessDenied;

    // Resolve path to inode number (Phase 47 scope: root-only lookup for testing)
    const inum = lookupInRootDir(fs, path) catch return error.NotFound;

    const inode = readInode(fs, inum) catch return error.IOError;

    const alloc = heap.allocator();
    const file_ctx = alloc.create(Ext2File) catch return error.NoMemory;
    errdefer alloc.destroy(file_ctx);
    file_ctx.* = .{
        .fs = fs,
        .inode_num = inum,
        .inode = inode,
        .size = inode.i_size,
    };

    return fd.createFd(&ext2_file_ops, flags, file_ctx) catch {
        alloc.destroy(file_ctx);
        return error.NoMemory;
    };
}
```

Note: `lookupInRootDir` requires directory traversal. The scope question (see Open Questions) is whether Phase 47 implements this lookup or defers it to Phase 48. The success criteria mention "reading inode 2 (root directory)" and reading files by byte content, which implies the test harness calls an internal inode read function directly (not through VFS open). Recommendation: implement the internal `readInode` and `resolveBlock` functions fully, and wire a minimal single-level path lookup (root dir entry scan) for the VFS open path, leaving full multi-component traversal to Phase 48.

### Pattern 6: ext2FileRead -- Reading File Data Block by Block

```zig
fn ext2FileRead(file_desc: *fd.FileDescriptor, buf: []u8) isize {
    const file: *Ext2File = @ptrCast(@alignCast(file_desc.private_data.?));
    const fs = file.fs;

    if (file_desc.position >= file.size) return 0;

    const remaining = file.size - file_desc.position;
    const to_read = @min(buf.len, remaining);
    var read_count: usize = 0;
    var pos = file_desc.position;

    while (read_count < to_read) {
        const logical_block = @as(u32, @intCast(pos / fs.block_size));
        const byte_in_block = @as(usize, @intCast(pos % fs.block_size));

        const phys_block = resolveBlock(fs, &file.inode, logical_block) catch return -5; // EIO

        const chunk = @min(to_read - read_count, fs.block_size - byte_in_block);

        if (phys_block == 0) {
            // Sparse block: return zeros (ADV-03 deferred but benign to handle)
            @memset(buf[read_count..][0..chunk], 0);
        } else {
            // SECURITY: Heap-allocate block buffer (4KB too large for kernel stack)
            const alloc = heap.allocator();
            const block_buf = alloc.alloc(u8, fs.block_size) catch return -12; // ENOMEM
            defer alloc.free(block_buf);
            @memset(block_buf, 0); // DMA hygiene

            const lba = std.math.mul(u64, @as(u64, phys_block),
                @as(u64, fs.sectors_per_block)) catch return -5;
            fs.dev.readSectors(lba, fs.sectors_per_block, block_buf) catch return -5;

            @memcpy(buf[read_count..][0..chunk], block_buf[byte_in_block..][0..chunk]);
        }

        read_count += chunk;
        pos += chunk;
    }

    file_desc.position += read_count;
    return std.math.cast(isize, read_count) orelse return -75; // EOVERFLOW
}
```

**Performance note**: This allocates one heap buffer per block read. For Phase 47 correctness testing this is fine. Phase 48 may introduce a page cache or larger read-ahead buffer. Do not optimize prematurely.

### Anti-Patterns to Avoid

- **Stack-allocated 4KB block buffer**: A `var buf: [4096]u8 = undefined;` for an indirect block table will overflow the kernel stack in the read path (especially on aarch64 where kernel stack is tighter). Always use `heap.allocator().alloc(u8, fs.block_size)` for block-sized buffers.
- **Inode 0 as valid**: ext2 reserves inode 0. Any code path that accepts inode number 0 must return an error immediately. The formula `(inum - 1) / ipg` wraps to a huge number for inum=0 in u32 arithmetic.
- **Casting without align(4)**: The sector buffer for inode reads must be `align(4)` to cast to `*const types.Inode`. Stack buffers of `[u8]` default to align(1). Use `align(4)` annotation.
- **Using inode_size as struct size**: `fs.inode_size` is the stride between inodes in the table (may be 256 for DYNAMIC_REV). The `types.Inode` struct is always 128 bytes. Do not attempt to @ptrCast to a 256-byte struct -- read 128 bytes and the rest is padding/extended fields we don't use.
- **Not checking zero block pointers**: `i_block[n] == 0` means the block is not allocated (sparse file). Dereferencing block 0 as a data block would read the boot sector or MBR. This must be caught and handled (return zeros for read).
- **Unchecked integer arithmetic in inode offset**: `(inum-1)` underflows for inum=0 in unsigned arithmetic. `offset_in_group * inode_size` can overflow u32 for large inode tables. Use `std.math.mul` and check group_idx against group_count.
- **Reading inode table block without rounding up to sector**: The inode table starts at a block boundary but the inode we want may be in the middle. The LBA calculation `inode_byte_offset / SECTOR_SIZE` produces the correct starting sector, but we must read enough sectors to cover the whole inode (may span a sector boundary).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Block-to-LBA conversion | Custom multiplication | `block_num * fs.sectors_per_block` with `std.math.mul` | Overflow-safe, already established pattern in mount.zig |
| Block buffer allocation | Stack array | `heap.allocator().alloc(u8, fs.block_size)` | 4KB on kernel stack causes stack overflow on aarch64 (CLAUDE.md MEMORY.md pattern) |
| u32 pointer table slicing | Byte-by-byte loop | `std.mem.bytesAsSlice(u32, buf)` | Correct alignment semantics, compiler-verified |
| Inode validation | Ad-hoc range checks | Explicit `if (inum == 0) return error.InvalidInode` + `if (group_idx >= fs.group_count) return error.InvalidInode` | Prevents the BGDT out-of-bounds read |
| FD creation | Custom FileDescriptor init | `fd.createFd(ops, flags, private_data)` | Correct refcounting, cloexec propagation, position=0 |

## Common Pitfalls

### Pitfall 1: Inode 1-Based Offset Off-by-One
**What goes wrong:** Using `inum / ipg` instead of `(inum - 1) / ipg` results in the wrong block group for all inodes. Inode 1 lands in group 0, but `1 / ipg = 0` only if `ipg > 1`, whereas `(1-1) / ipg = 0` is always correct. For inode 2 (root): `(2-1) / ipg = 1/ipg = 0` (correct for typical ipg values).
**Why it happens:** Off-by-one on 1-based indexing is the classic ext2 beginner mistake.
**How to avoid:** Always use `(inum - 1)` in both the group index and the intra-group offset.
**Warning signs:** Reading inode 2 returns garbage (wrong inode); mode field does not show directory bit (0x4000).

### Pitfall 2: 4KB Block Buffer on Kernel Stack
**What goes wrong:** `var buf: [4096]u8 = undefined;` inside `readInode` or `resolveBlock` blows the kernel stack, causing a double fault on x86_64 or a page fault on the stack guard page on aarch64.
**Why it happens:** The MEMORY.md notes "Large Struct Return-by-Value = Stack Overflow on aarch64". 4096 bytes of stack allocation for block buffers triggers the same class of problem.
**How to avoid:** Always `heap.allocator().alloc(u8, fs.block_size)` for block-sized buffers. For the inode sector read, 2 * 512 = 1024 bytes is acceptable on the stack.
**Warning signs:** PageFault in kernel stack guard region during ext2 open; happens specifically on aarch64 first.

### Pitfall 3: Missing DMA Hygiene on Block Reads
**What goes wrong:** Uninitialized block buffer passed to `readSectors`. If the device fails silently or returns partial data, the uninitialized bytes leak kernel stack/heap memory as file data.
**Why it happens:** `var buf: [N]u8 = undefined;` is idiomatic Zig but dangerous for DMA (CLAUDE.md rule 3).
**How to avoid:** Always `@memset(buf, 0)` or `= [_]u8{0} ** N` before passing to `readSectors`.
**Warning signs:** Files read from ext2 contain extra bytes of garbage after actual content.

### Pitfall 4: sectors_per_block vs block_size Confusion
**What goes wrong:** Passing `block_size` (e.g., 4096) as the sector count to `readSectors` instead of `sectors_per_block` (e.g., 8). `BlockDevice.readSectors` validates `buf.len >= count * SECTOR_SIZE`, so passing 4096 as count requires a 2MB buffer and will fail with `BufferTooSmall`.
**Why it happens:** The `count` parameter to `readSectors` is in 512-byte sectors, not bytes. `fs.sectors_per_block` is already computed in `Ext2Fs` from Phase 46.
**How to avoid:** Use `fs.sectors_per_block` (a u32 field on `Ext2Fs`) as the `count`. The buffer size should be `fs.block_size` bytes.
**Warning signs:** `BlockDeviceError.BufferTooSmall` during inode table reads.

### Pitfall 5: Block Number 0 as Valid Data Block
**What goes wrong:** `inode.i_block[n] == 0` is treated as block 0 of the disk (boot sector). Reading block 0 returns MBR/GPT data, not file content.
**Why it happens:** In ext2, block number 0 in a block pointer means "not allocated" (sparse). Block 0 on disk is the boot block, which ext2 never uses for data.
**How to avoid:** In `resolveBlock`, check `if (inode.i_block[n] == 0) return 0;` and similarly for indirect block pointers. The caller (`ext2FileRead`) must treat physical block 0 as sparse and return zeros.
**Warning signs:** Files on ext2 contain MBR/GPT data at sparse offsets.

### Pitfall 6: Indirect Block Read Without Full Alignment Cast
**What goes wrong:** `std.mem.bytesAsSlice(u32, buf)` where `buf` is not 4-byte aligned fails with a comptime or runtime alignment error.
**Why it happens:** heap.allocator().alloc(u8, N) returns alignment 1 by default for u8 slices. Casting to u32 slice requires alignment 4.
**How to avoid:** Use `heap.allocator().alignedAlloc(u8, .@"4", fs.block_size)` for indirect block buffers, or cast via `@as([*]u32, @ptrCast(@alignCast(buf.ptr)))`. The aligned alloc approach is cleaner.
**Warning signs:** Zig runtime alignment panic inside `resolveBlock` on first indirect block read.

### Pitfall 7: aarch64 -- ext2 Disk Absent
**What goes wrong:** `ext2_block_dev` is null on aarch64 due to the QEMU 10.x/HVF VirtIO-SCSI BAD_TARGET issue. Any call path that assumes the device exists panics.
**Why it happens:** STATE.md documents "aarch64 ext2 LUN: VirtIO-SCSI sequential scan reports BAD_TARGET for SCSI target 1 even with explicit scsi-id=1; ext2 gracefully skips on aarch64 (warning logged). Root cause unknown."
**How to avoid:** Phase 47 code only runs when ext2 is mounted at /mnt2. If the device is absent, /mnt2 is not mounted, and all new code is unreachable. Do NOT add aarch64-specific workarounds yet. Document the limitation.
**Warning signs:** On aarch64 boot, "ext2: no block device -- skipping /mnt2" is expected and correct behavior.

### Pitfall 8: Inode Size vs. Inode Table Stride
**What goes wrong:** Using `@sizeOf(types.Inode)` (128) as the stride between inodes in the table, instead of `fs.inode_size` (which may be 256 for DYNAMIC_REV images).
**Why it happens:** The `types.Inode` struct captures only the standard fields. DYNAMIC_REV can extend the inode to 256 bytes, but the extra bytes (128..255) are extended attributes / creation time. The stride in the table is `s_inode_size`, not `@sizeOf(Inode)`.
**How to avoid:** Use `fs.inode_size` (stored in `Ext2Fs` from Phase 46) as the stride. The cast to `types.Inode` reads only the first 128 bytes, which is correct.
**Warning signs:** Every other inode read returns garbage (128-byte misalignment for 256-byte inodes).

## Code Examples

### Full readInode Implementation

```zig
// Source: ext2 spec section 4.2 + types.zig constants
// File: src/fs/ext2/inode.zig
const std = @import("std");
const types = @import("types.zig");
const heap = @import("heap");
const console = @import("console");
const BlockDevice = @import("block_device").BlockDevice;
const SECTOR_SIZE = @import("block_device").SECTOR_SIZE;

pub const Ext2Error = error{ IOError, InvalidInode, InvalidSuperblock, OutOfMemory, FileTooLarge };

pub fn readInode(fs: anytype, inum: u32) Ext2Error!types.Inode {
    if (inum == 0) return error.InvalidInode;

    const ipg = fs.superblock.s_inodes_per_group;
    if (ipg == 0) return error.InvalidSuperblock;

    const group_idx = (inum - 1) / ipg;
    if (group_idx >= fs.group_count) return error.InvalidInode;

    const offset_in_group = (inum - 1) % ipg;
    const gd = fs.block_groups[group_idx];

    const inode_size: u64 = fs.inode_size;
    const byte_offset_in_table = std.math.mul(u64, @as(u64, offset_in_group), inode_size)
        catch return error.InvalidInode;
    const table_start_byte = std.math.mul(u64, @as(u64, gd.bg_inode_table), @as(u64, fs.block_size))
        catch return error.InvalidInode;
    const inode_byte_offset = std.math.add(u64, table_start_byte, byte_offset_in_table)
        catch return error.InvalidInode;

    const lba = inode_byte_offset / SECTOR_SIZE;
    const byte_in_sector = @as(usize, @intCast(inode_byte_offset % SECTOR_SIZE));

    // Read 2 sectors to handle inode spanning sector boundary
    // 2 * 512 = 1024 bytes -- safe for kernel stack
    var buf: [2 * SECTOR_SIZE]u8 align(4) = [_]u8{0} ** (2 * SECTOR_SIZE);
    const sectors_needed: u32 = if (byte_in_sector + @as(usize, fs.inode_size) > SECTOR_SIZE) 2 else 1;
    fs.dev.readSectors(lba, sectors_needed, buf[0 .. sectors_needed * SECTOR_SIZE])
        catch return error.IOError;

    if (byte_in_sector + @sizeOf(types.Inode) > buf.len) return error.InvalidInode;
    const inode: types.Inode = @as(*const types.Inode,
        @ptrCast(@alignCast(buf[byte_in_sector..].ptr))).*;

    console.debug("ext2: inode {d}: mode=0x{X:0>4} size={d} links={d}", .{
        inum, inode.i_mode, inode.i_size, inode.i_links_count,
    });
    return inode;
}
```

### Sparse Block Handling in resolveBlock

```zig
// Returns 0 for sparse blocks (caller must return zeros for reads)
pub fn resolveBlock(fs: anytype, inode: *const types.Inode, logical_block: u32) Ext2Error!u32 {
    const ptrs_per_block: u32 = fs.block_size / 4;

    // Direct blocks: i_block[0..11]
    if (logical_block < types.DIRECT_BLOCKS) {
        return inode.i_block[logical_block]; // 0 = sparse
    }

    const lb1 = logical_block - types.DIRECT_BLOCKS;

    // Single-indirect: i_block[12]
    if (lb1 < ptrs_per_block) {
        const ind_num = inode.i_block[types.INDIRECT_BLOCK];
        if (ind_num == 0) return 0; // sparse

        const alloc = heap.allocator();
        const ibuf = alloc.alignedAlloc(u8, .@"4", fs.block_size) catch return error.OutOfMemory;
        defer alloc.free(ibuf);
        @memset(ibuf, 0);

        const lba = std.math.mul(u64, @as(u64, ind_num), @as(u64, fs.sectors_per_block))
            catch return error.InvalidInode;
        fs.dev.readSectors(lba, fs.sectors_per_block, ibuf) catch return error.IOError;

        const ptrs = std.mem.bytesAsSlice(u32, ibuf);
        if (lb1 >= ptrs.len) return error.InvalidInode;
        return ptrs[lb1];
    }

    const lb2 = lb1 - ptrs_per_block;

    // Double-indirect: i_block[13]
    if (lb2 < ptrs_per_block * ptrs_per_block) {
        const dind_num = inode.i_block[types.DOUBLE_INDIRECT_BLOCK];
        if (dind_num == 0) return 0; // sparse

        const alloc = heap.allocator();
        const outer = alloc.alignedAlloc(u8, .@"4", fs.block_size) catch return error.OutOfMemory;
        defer alloc.free(outer);
        @memset(outer, 0);

        const outer_lba = std.math.mul(u64, @as(u64, dind_num), @as(u64, fs.sectors_per_block))
            catch return error.InvalidInode;
        fs.dev.readSectors(outer_lba, fs.sectors_per_block, outer) catch return error.IOError;

        const outer_ptrs = std.mem.bytesAsSlice(u32, outer);
        const outer_idx = lb2 / ptrs_per_block;
        if (outer_idx >= outer_ptrs.len) return error.InvalidInode;
        const inner_num = outer_ptrs[outer_idx];
        if (inner_num == 0) return 0; // sparse

        const inner = alloc.alignedAlloc(u8, .@"4", fs.block_size) catch return error.OutOfMemory;
        defer alloc.free(inner);
        @memset(inner, 0);

        const inner_lba = std.math.mul(u64, @as(u64, inner_num), @as(u64, fs.sectors_per_block))
            catch return error.InvalidInode;
        fs.dev.readSectors(inner_lba, fs.sectors_per_block, inner) catch return error.IOError;

        const inner_ptrs = std.mem.bytesAsSlice(u32, inner);
        const inner_idx = lb2 % ptrs_per_block;
        if (inner_idx >= inner_ptrs.len) return error.InvalidInode;
        return inner_ptrs[inner_idx];
    }

    // Triple-indirect: deferred (ADV-01)
    return error.FileTooLarge;
}
```

### Test Image Preparation (for success criteria verification)

The ext2 test image must contain files of known size and content to verify correctness. This is a build-time concern in Phase 45's `mke2fs` step. To test all indirection levels, the image needs:

1. A file <= 48KB (direct blocks only): any file already on the image satisfies INODE-02
2. A file ~5MB (requires single-indirect): must be created in `e2fsprogs` population step
3. A file ~5MB+ spanning into doubly indirect blocks: must be created in `e2fsprogs` population step

**Critical**: Phase 45 currently creates an ext2 image with `mke2fs` but does NOT populate files into it. Phase 47 either needs a build step to populate test files (using `e2cp` or `debugfs`), or the test must use a different verification approach (e.g., read root inode 2 and verify mode/type, without needing large files).

The success criteria explicitly require byte-for-byte correctness for single-indirect and doubly-indirect files. This means the build step must write known files to the image. Research into the Phase 45 build script is needed to determine if a `debugfs` or `e2cp` step exists.

## State of the Art

| Old Approach | Current Approach | Notes |
|--------------|-----------------|-------|
| Phase 46 ext2Open: always returns NotFound | Phase 47 ext2Open: resolves inode, reads file data | Building on Phase 46 stub |
| SFS: flat block list, start_block + offset | ext2: BGDT + indirect pointer trees | Full POSIX filesystem indirection |
| SFS: 512-byte sectors, single-sector reads | ext2: 4KB blocks, multi-sector reads | Block size from superblock, not hardcoded |

**Deprecated in Phase 47:**
- `ext2Open` returning `error.NotFound` for all paths -- replaced with actual inode lookup
- `ext2StatPath` returning `null` for all paths -- replaced with inode-based metadata

## Open Questions

1. **Does the Phase 45 ext2.img contain test files for indirect block testing?**
   - What we know: Phase 45-01 creates the ext2 image with `mke2fs` (format only), but the STATE.md does not mention any file population step (no `e2cp`, `debugfs`, or `dd` to create test files inside the image).
   - What's unclear: If the image is empty (only root directory inode 2), then INODE-02/03/04 tests need actual files. The success criteria require byte-for-byte verification.
   - Recommendation: Plan 47-01 should include a build step to write test files into the ext2 image: one small file (<= 48KB), one medium file (~5MB), one large file (~6MB) using `debugfs` or `e2cp` from e2fsprogs. Alternatively, a simpler test is to verify that inode 2 (root directory) has mode 0x41ED (directory, 0755) and i_size > 0 -- this only requires INODE-01 and does not need file data. Check the current build.zig ext2 image creation step to see what files exist before planning the test strategy.

2. **Single-component path lookup vs. full directory traversal in ext2Open**
   - What we know: The success criteria say "reading inode 2 returns valid directory inode" and "a file using only direct blocks reads back correctly byte-for-byte." These could be tested via internal kernel unit tests (not VFS open) or via userspace tests that open files by path.
   - What's unclear: If tests must call `open("/mnt2/filename")`, Phase 47 needs root directory scanning. If tests verify inode data directly via a kernel test API, directory traversal can be deferred to Phase 48.
   - Recommendation: Implement minimal root directory scanning in Phase 47 (scan inode 2's data blocks for matching DirEntry). This is a small addition that makes the phase self-contained and enables userspace tests. Full multi-level traversal remains Phase 48. This is the correct scope call: the phase description says "read any inode by number," which implies at least single-level lookup to be testable.

3. **ext2Fs struct locking -- is a Spinlock needed on ext2Fs for Phase 47?**
   - What we know: Phase 46 did not add a spinlock to `Ext2Fs` (read-only mount). Phase 47 adds actual reads against `block_groups` and the `BlockDevice`. The `BlockDevice.readSectors` call is stateless (LBA + buffer, no position state). The `block_groups` slice is read-only after mount.
   - What's unclear: Are multiple threads expected to call `ext2Open` concurrently in Phase 47 tests?
   - Recommendation: No additional spinlock needed for Phase 47. The `Ext2Fs` fields written after mount are: none. `block_groups` is read-only. `dev.readSectors` is stateless per the BlockDevice design. The VFS spinlock already serializes mount/unmount. This is a deliberate simplification; Phase 48 (inode cache) will introduce per-entry locking.

4. **Stack size safety margin for the `resolveBlock` call chain**
   - What we know: MEMORY.md documents a history of stack overflow at the syscall dispatch level from adding too many inline branches. The `resolveBlock` function itself uses heap for block buffers, but the call chain (VFS open -> ext2Open -> lookupInRootDir -> readInode -> resolveBlock) adds ~3-4 frames.
   - What's unclear: How deep the current call stack is when ext2 read is eventually called from a userspace read syscall.
   - Recommendation: Keep `readInode` stack frame small (2 * 512 = 1024 bytes for inode buf, a few u64 locals). Keep `resolveBlock` stack frame small (all block buffers on heap). This is already required by Pitfall 2 avoidance. If test failures appear as double faults, increase stack size as done previously (24 pages, 96KB).

## Sources

### Primary (HIGH confidence)

- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/ext2/types.zig` -- Inode struct (128 bytes, i_block[15]), GroupDescriptor (bg_inode_table field), Superblock (s_inodes_per_group, s_inode_size), DIRECT_BLOCKS=12, INDIRECT_BLOCK=12, DOUBLE_INDIRECT_BLOCK=13 -- verified by reading file directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/ext2/mount.zig` -- Ext2Fs struct (dev, superblock, block_groups, block_size, sectors_per_block, group_count, inode_size), Phase 46 stub callbacks -- verified by reading file directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/block_device.zig` -- BlockDevice.readSectors API, SECTOR_SIZE=512 -- verified by reading file directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/kernel/fs/fd.zig` -- createFd(ops, flags, private_data) implementation, FileOps vtable fields -- verified by reading file directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/src/fs/sfs/ops.zig` -- sfsOpen pattern (createFd call, Ext2File analogue), sfsRead pattern (block-by-block read) -- verified by reading file directly
- `/Users/whit3rabbit/Documents/GitHub/zigk/.planning/STATE.md` -- aarch64 LUN BAD_TARGET concern, mount at /mnt2, inode_size field decision
- `/Users/whit3rabbit/Documents/GitHub/zigk/.planning/REQUIREMENTS.md` -- INODE-01 through INODE-04 definitions
- ext2 specification: https://www.nongnu.org/ext2-doc/ext2.html (inode location formula section 4.2, block indirection section 4.4) -- cited in types.zig; formulas verified against constants in types.zig

### Secondary (MEDIUM confidence)

- MEMORY.md documented kernel stack behavior: "4KB struct return-by-value = stack overflow on aarch64" -- verified to be the right pattern for block buffers (heap allocation required)
- ext2 block size for test images: 4096 bytes per STATE.md decision "4KB block size for test images" -- HIGH confidence since this was a deliberate engineering decision, not a default

### Tertiary (LOW confidence)

- QEMU aarch64 ext2 LUN BAD_TARGET root cause: "QEMU 10.x HVF VirtIO-SCSI multi-target behavior" -- not investigated in this research session. The impact is known (ext2 absent on aarch64) and gracefully handled.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all components are existing codebase files, read and verified
- Architecture patterns: HIGH -- inode formula is mechanical from ext2 spec constants already in types.zig; block indirection is algorithmic with no ambiguity
- Pitfalls: HIGH -- stack overflow and alignment issues are well-documented in MEMORY.md and CLAUDE.md; the 1-based inode off-by-one is the canonical ext2 beginner trap
- Open questions: MEDIUM -- test image content and scope of root-dir scan are planning decisions, not research gaps

**Research date:** 2026-02-23
**Valid until:** 2026-03-23 (stable internal codebase; invalidated only by Phase 46 changes to Ext2Fs or VFS restructuring)
