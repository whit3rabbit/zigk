# Phase 45: Build Infrastructure - Research

**Researched:** 2026-02-22
**Domain:** Zig build system (build.zig), mke2fs/e2fsprogs disk image creation, QEMU block device attachment, Zig BlockDevice abstraction
**Confidence:** HIGH

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| BUILD-01 | Build system creates a pre-formatted ext2 disk image via host mkfs.ext2 | Zig build system shell command pattern (`b.addSystemCommand`) already used for disk.img and sfs.img creation; mke2fs available via homebrew e2fsprogs and Android SDK; CI (ubuntu) has mke2fs natively |
| BUILD-02 | QEMU launches with ext2 image attached as a block device on both x86_64 and aarch64 | Existing QEMU command in build.zig already handles arch-split storage attachment (sfs.img via VirtIO-SCSI on aarch64, AHCI on x86_64); same pattern applies for ext2.img |
| BUILD-03 | BlockDevice abstraction provides driver-portable read/write by LBA without position state races | SFS io.zig has an acknowledged position-state race (save/restore device_fd.position under io_lock); new BlockDevice interface needs pread-style semantics with explicit LBA argument instead of mutating fd.position |

</phase_requirements>

## Summary

Phase 45 lays the plumbing that all subsequent ext2 phases depend on. It has three separable concerns: (1) creating a pre-formatted ext2 disk image during `zig build`, (2) attaching that image to QEMU on both architectures, and (3) defining a `BlockDevice` abstraction that downstream filesystem code uses for LBA-based I/O without touching `device_fd.position`.

The project already handles analogous disk image creation for `disk.img` (FAT ESP via `mtools`) and `sfs.img` (raw via dd). Extending that pattern to run `mke2fs` via `b.addSystemCommand` is straightforward. The CI pipeline runs on ubuntu-latest where `e2fsprogs` (`mke2fs`) is available by default. On macOS (developer machines) the Android SDK includes a compatible `mke2fs`, and `brew install e2fsprogs` provides the full suite keg-only at `/opt/homebrew/opt/e2fsprogs/sbin/mke2fs`. The build script must detect the tool's path and fail with a clear error if neither is found.

The `BlockDevice` interface fixes the root cause of the SFS position-state bug. `sfs/io.zig` currently works by setting `device_fd.position = lba * 512`, calling the FD's read/write, then restoring `position`. Even with the `io_lock` spinlock this is fragile: the FD's seek semantics belong to the caller, and any future concurrent filesystem would be prone to the same class of bug. The new abstraction must expose `fn readSectors(self, lba: u64, count: u32, buf: []u8) !void` and `fn writeSectors(...)` that pass the LBA directly to the underlying driver (AHCI `port.readSectors`, VirtIO-SCSI `lun.readBlocks`, NVMe `controller.readBlocks`) without going through `fd.position` at all.

**Primary recommendation:** Add a `BlockDevice` struct with `readSectors(lba, count, buf)` / `writeSectors(lba, count, buf)` fn pointers, create `ext2.img` via a `b.addSystemCommand` shell script that calls `mke2fs`, and attach it to QEMU using the same arch-split VirtIO-SCSI (aarch64) / IDE-AHCI (x86_64) pattern already used for `sfs.img`.

## Standard Stack

### Core
| Tool/Library | Version | Purpose | Why Standard |
|---|---|---|---|
| e2fsprogs mke2fs | 1.47.x (homebrew), stock on Ubuntu | Format ext2 disk image on host | Only tool that produces correct ext2 superblock; in-kernel mkfs explicitly out of scope per REQUIREMENTS.md |
| Zig build system `b.addSystemCommand` | 0.16.x (nightly) | Run mke2fs shell script at build time | Already used for FAT ESP creation; supports step dependencies |
| QEMU `-drive` / `-device` flags | QEMU 8.x | Attach raw disk image as block device | Already used for sfs.img (VirtIO-SCSI on aarch64, IDE on x86_64) |

### Supporting
| Library | Version | Purpose | When to Use |
|---|---|---|---|
| `extern struct` with comptime size assertions | Zig 0.16.x | On-disk type layout verification | All ext2 on-disk structs (Superblock, GroupDescriptor, Inode, DirEntry) |
| `sync.Spinlock` | project | Lock protecting BlockDevice state | Any shared BlockDevice pointer accessed from multiple filesystem threads |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|---|---|---|
| mke2fs host tool | In-kernel mkfs implementation | In-kernel mkfs explicitly ruled out in REQUIREMENTS.md; host tool is safer and simpler |
| AHCI for aarch64 ext2 disk | VirtIO-SCSI (current sfs.img pattern) | VirtIO-SCSI is already the working aarch64 storage path; do not add AHCI to aarch64 |
| FD-position-based I/O (current SFS) | Explicit LBA BlockDevice interface | FD position is shared state that requires a lock to be safe; LBA-direct is race-free |

**Installation (macOS dev machines):**
```bash
brew install e2fsprogs
# Binary is keg-only at: /opt/homebrew/opt/e2fsprogs/sbin/mke2fs
# or: /usr/local/opt/e2fsprogs/sbin/mke2fs
```

**Ubuntu CI:** `mke2fs` available in default apt packages; no extra install step needed.

## Architecture Patterns

### Recommended Project Structure

New files for this phase:
```
src/fs/
└── block_device.zig   # BlockDevice abstraction (the key new artifact)

src/fs/ext2/
└── types.zig          # ext2 on-disk structs with comptime size assertions
                       # (empty shell -- actual parsing in Phase 46)
```

The ext2 module itself is not implemented in this phase. Phase 45 only creates the disk image, attaches it, and defines the BlockDevice interface that Phase 46 will use.

### Pattern 1: Zig Build System Shell Command for mke2fs

**What:** Use `b.addSystemCommand(&.{"sh", "-c", script})` to run `mke2fs` during the build.
**When to use:** Any host-tool invocation that must happen before the QEMU run step.

The existing ESP creation in `build.zig` (around line 2886) uses this pattern with `dd`, `mformat`, and `mcopy`. The ext2 image creation follows the same approach.

```zig
// In build.zig, after kernel build, before run_cmd setup:
const ext2_script = b.fmt(
    \\set -e && \
    \\MKE2FS=$(which mke2fs 2>/dev/null || \
    \\         ls /opt/homebrew/opt/e2fsprogs/sbin/mke2fs 2>/dev/null || \
    \\         ls /usr/local/opt/e2fsprogs/sbin/mke2fs 2>/dev/null || \
    \\         echo "") && \
    \\if [ -z "$MKE2FS" ]; then \
    \\    echo "ERROR: mke2fs not found. Install with: brew install e2fsprogs" >&2; \
    \\    exit 1; \
    \\fi && \
    \\dd if=/dev/zero of=ext2.img bs=1M count={d} 2>/dev/null && \
    \\"$MKE2FS" -t ext2 -b 4096 -L "zk-ext2" ext2.img
, .{ext2_img_mb});
const create_ext2_cmd = b.addSystemCommand(&.{ "sh", "-c", ext2_script });
```

**Image size:** Start at 64MB (enough for multiple test files; ext2 with 4KB blocks gives ~16K inodes by default).

### Pattern 2: QEMU Block Device Attachment (arch-split)

**What:** Attach `ext2.img` as a second storage disk via the same arch-specific device already used for `sfs.img`.

```zig
// aarch64: ext2.img on VirtIO-SCSI (same controller as sfs.img, different LUN)
if (target_arch == .aarch64) {
    run_cmd.addArgs(&.{
        // scsi0 controller already added for sfs.img
        "-drive", "file=ext2.img,format=raw,if=none,id=ext2disk",
        "-device", "scsi-hd,drive=ext2disk,bus=scsi0.0",
    });
}

// x86_64: ext2.img on AHCI (second SATA port, /dev/sdb)
if (target_arch == .x86_64) {
    run_cmd.addArgs(&.{
        "-drive", "file=ext2.img,format=raw,if=none,id=ext2disk",
        "-device", "ide-hd,drive=ext2disk,bus=ide.0",
    });
}
```

Note: On x86_64 the boot disk already uses `ide.0`. Verify bus numbering. If `ide.0` is taken, use `ide.1` or switch to `ahci` with `ahci0.0` port index. Checking existing sfs.img handling: aarch64 uses VirtIO-SCSI, x86_64 does NOT currently attach sfs.img (there is no sfs.img attachment for x86_64 in the current build.zig). This means on x86_64 the AHCI controller (the SFS data source) must be inspected to determine how the kernel finds storage. The kernel currently uses AHCI port 0 on x86_64 as the SFS disk.

**CRITICAL:** x86_64 does not have an sfs.img in the current QEMU command. The AHCI disk on x86_64 is created by the `disk_image` tool (`disk.img`) and is the boot+SFS combined disk. To add ext2 storage on x86_64 without breaking the existing setup, add a second AHCI drive or use VirtIO-SCSI on x86_64 too for consistency.

**Recommended approach:** Use VirtIO-SCSI on BOTH architectures for ext2.img to maximize code sharing and avoid AHCI bus numbering complexity. The VirtIO-SCSI driver is already compiled for both architectures.

### Pattern 3: BlockDevice Abstraction (the position-race fix)

**What:** A thin struct with explicit LBA-based read/write function pointers, eliminating the save/restore of `device_fd.position`.
**When to use:** Anywhere a filesystem reads/writes raw sectors from a block device.

The current SFS io.zig bug:
```zig
// WRONG: race even with lock -- restoring position is not atomic with other callers
const old_pos = device_fd.position;
device_fd.position = @as(u64, lba) * 512;
const bytes_read = read_fn(device_fd, buf);
device_fd.position = old_pos; // another thread could see intermediate state
```

The fix is to expose a pread-equivalent directly from each driver. The AHCI, VirtIO-SCSI, and NVMe drivers all have native `readSectors(lba, count, buf)` functions. The BlockDevice abstraction exposes these directly.

```zig
// src/fs/block_device.zig
//
// Driver-portable block I/O without position-state races.
// Filesystems call readSectors/writeSectors with an explicit LBA.
// The underlying driver implementation is responsible for thread safety.

const std = @import("std");

pub const BlockDeviceError = error{
    IOError,
    InvalidLba,
    DeviceNotReady,
    BufferTooSmall,
};

/// Sector size. All LBA arithmetic uses 512-byte sectors.
/// Ext2 blocks are multiples of 512 bytes; use (block * sectors_per_block) for LBA.
pub const SECTOR_SIZE: usize = 512;

/// Driver-portable block device interface.
/// Implementations: AHCI port, VirtIO-SCSI LUN, NVMe namespace.
pub const BlockDevice = struct {
    /// Opaque driver context (e.g., *ahci.Port, *virtio_scsi.Lun)
    ctx: *anyopaque,

    /// Read `count` 512-byte sectors starting at `lba` into `buf`.
    /// buf.len must be >= count * SECTOR_SIZE.
    /// Thread-safe: no shared position state; LBA is passed per-call.
    readSectors: *const fn (ctx: *anyopaque, lba: u64, count: u32, buf: []u8) BlockDeviceError!void,

    /// Write `count` 512-byte sectors starting at `lba` from `buf`.
    writeSectors: *const fn (ctx: *anyopaque, lba: u64, count: u32, buf: []const u8) BlockDeviceError!void,

    /// Total sector count (device capacity)
    sector_count: u64,
};
```

Driver adapter shims (added in driver files or as wrappers):
```zig
// In src/drivers/storage/ahci/adapter.zig (or new block_device.zig shim):
pub fn fromAhciPort(port_ptr: *ahci.Port) BlockDevice {
    return .{
        .ctx = port_ptr,
        .readSectors = ahciRead,
        .writeSectors = ahciWrite,
        .sector_count = port_ptr.sector_count,
    };
}

fn ahciRead(ctx: *anyopaque, lba: u64, count: u32, buf: []u8) BlockDeviceError!void {
    const port: *ahci.Port = @ptrCast(@alignCast(ctx));
    port.readSectors(lba, count, buf) catch return error.IOError;
}
```

VirtIO-SCSI adapter follows the same pattern, calling `lun.readBlocks(lba, count, buf)`.

### Pattern 4: ext2 types.zig Comptime Assertions

Per the success criteria: `extern struct` on-disk types in `types.zig` pass `comptime` size assertions.

The SFS codebase already uses this pattern in `src/fs/sfs/types.zig`:
```zig
// Existing SFS pattern -- replicate for ext2
comptime {
    if (@sizeOf(DirEntry) != 128) {
        @compileError("DirEntry size mismatch: expected 128 bytes");
    }
}
```

For ext2 Phase 45, create `src/fs/ext2/types.zig` with the key on-disk structs and their comptime assertions. The ext2 superblock is 1024 bytes and starts at byte offset 1024 in the image (block 0 on disk, after the 1024-byte boot record area):

```zig
// src/fs/ext2/types.zig (shell for Phase 46 to fill out -- Phase 45 only needs the skeleton)
pub const SUPERBLOCK_OFFSET: u64 = 1024; // bytes from start of partition
pub const EXT2_MAGIC: u16 = 0xEF53;
pub const SECTOR_SIZE: usize = 512;

pub const Superblock = extern struct {
    s_inodes_count: u32,
    s_blocks_count: u32,
    s_r_blocks_count: u32,
    s_free_blocks_count: u32,
    s_free_inodes_count: u32,
    s_first_data_block: u32,
    s_log_block_size: u32,   // block_size = 1024 << s_log_block_size
    s_log_frag_size: i32,
    s_blocks_per_group: u32,
    s_frags_per_group: u32,
    s_inodes_per_group: u32,
    s_mtime: u32,
    s_wtime: u32,
    s_mnt_count: u16,
    s_max_mnt_count: i16,
    s_magic: u16,            // Must be 0xEF53
    s_state: u16,
    s_errors: u16,
    s_minor_rev_level: u16,
    s_lastcheck: u32,
    s_checkinterval: u32,
    s_creator_os: u32,
    s_rev_level: u32,
    s_def_resuid: u16,
    s_def_resgid: u16,
    // Extended superblock fields (rev >= 1)
    s_first_ino: u32,
    s_inode_size: u16,
    s_block_group_nr: u16,
    s_feature_compat: u32,
    s_feature_incompat: u32,
    s_feature_ro_compat: u32,
    s_uuid: [16]u8,
    s_volume_name: [16]u8,
    s_last_mounted: [64]u8,
    s_algo_bitmap: u32,
    // ... padding to 1024 bytes
    _pad: [1024 - 204]u8,
};

comptime {
    if (@sizeOf(Superblock) != 1024) {
        @compileError("ext2 Superblock must be exactly 1024 bytes");
    }
}
```

**Important:** The actual field count above is approximate. Phase 46 will fill this out with exact spec values. Phase 45 only needs to create the file with the struct skeleton and a size assertion that passes at 1024 bytes with correct padding.

### Anti-Patterns to Avoid

- **Using `device_fd.position` in ext2 I/O:** Never do this. Always call `BlockDevice.readSectors(lba, count, buf)` directly.
- **Single QEMU drive controller on aarch64 for two disks:** The existing aarch64 setup uses one VirtIO-SCSI controller (`-device virtio-scsi-pci,id=scsi0`). Adding a second scsi-hd device to the same controller works (SCSI supports multiple LUNs). Do not add a second VirtIO-SCSI controller unless a LUN limit is hit.
- **Hard-coding mke2fs path:** Always search multiple locations and fail with a clear message. CI will have it in PATH; macOS needs the keg-only path.
- **Checking for mke2fs at build time with Zig's fileExists:** The build system runs on the host. Use `sh -c "which mke2fs || ..."` in the shell script, not `fileExists()`, because fileExists uses `std.c.access` which expects a static path.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---|---|---|---|
| ext2 image formatting | Custom Zig formatter | `mke2fs` from e2fsprogs | mke2fs handles journal, feature flags, UUID generation, correct block group layout -- thousands of lines of complexity |
| Block device thread safety | Custom position-tracking wrapper with locks | BlockDevice fn pointer with LBA argument | LBA-direct avoids the lock entirely; no shared mutable state to protect |
| Tool availability detection | Complex Zig compile-time search | Shell `which` / `ls` fallback chain in the sh -c script | Shell is simpler, runs at build-execute time (not Zig compile time) |

**Key insight:** `mke2fs` is the canonical ext2 formatting tool. The ext2 on-disk format has enough edge cases (feature flags, journal, superblock backup copies, etc.) that getting it wrong is easy and silent. Using the reference implementation guarantees the kernel sees a valid image on the first boot.

## Common Pitfalls

### Pitfall 1: x86_64 AHCI Bus Conflict
**What goes wrong:** Adding `ide-hd,drive=ext2disk,bus=ide.0` when `ide.0` is already at capacity (2 devices: boot disk + SFS disk). QEMU silently ignores or errors on the device.
**Why it happens:** The `q35` machine has `ide.0` (primary) and `ide.1` (secondary). The current x86_64 boot uses one IDE-HD device on `ide.0`. If x86_64 needs a second data disk it may need a different controller.
**How to avoid:** Use VirtIO-SCSI on BOTH architectures for the ext2 disk. The kernel's VirtIO-SCSI driver already works on both. This avoids AHCI bus numbering complexity entirely.
**Warning signs:** QEMU fails with "Device 'ide-hd' could not be initialized" or the kernel does not see the ext2 device.

### Pitfall 2: mke2fs Not in PATH on macOS
**What goes wrong:** `build.zig` calls `mke2fs` and the tool is not found on macOS (homebrew installs it keg-only, not in PATH).
**Why it happens:** Homebrew marks `e2fsprogs` keg-only to avoid conflicting with macOS BSD tools. The binary is at `/opt/homebrew/opt/e2fsprogs/sbin/mke2fs`.
**How to avoid:** The shell script must use a fallback search: `which mke2fs 2>/dev/null || ls /opt/homebrew/opt/e2fsprogs/sbin/mke2fs 2>/dev/null || ls /usr/local/opt/e2fsprogs/sbin/mke2fs 2>/dev/null`. Fail with a clear install message if none found.
**Warning signs:** Build step silently produces a zeroed `ext2.img` or fails with "command not found".

### Pitfall 3: Android SDK mke2fs Incompatibility
**What goes wrong:** The Android SDK includes a `mke2fs` variant that may produce an Android-specific ext2 variant, not a standard ext2 that a kernel ext2 driver expects.
**Why it happens:** Android's `mke2fs` is patched to target Android's ext4 profile with specific feature flags. Running it against a standard kernel may produce images with unexpected feature flags.
**How to avoid:** In the tool search, prioritize homebrew's `e2fsprogs` over the Android SDK. The shell fallback chain must check homebrew paths before falling back to the system PATH (which may find the Android version).
**Warning signs:** Kernel rejects the image with "unsupported INCOMPAT features" during Phase 46 mount.

### Pitfall 4: ext2.img Step Not Wired into run_cmd
**What goes wrong:** `create_ext2_cmd` step exists but `run_cmd.step.dependOn(&create_ext2_cmd.step)` is missing.
**Why it happens:** The build.zig run step dependencies require explicit wiring. The existing `run_cmd.step.dependOn(&create_disk_img.step)` pattern shows how it's done but must be replicated for the new step.
**How to avoid:** After adding the `create_ext2_cmd` step, add `run_cmd.step.dependOn(&create_ext2_cmd.step)` in the same block as the other run_cmd dependencies.

### Pitfall 5: Ext2 Superblock at Byte 1024 Not Sector 0
**What goes wrong:** Code reads sector 0 (bytes 0-511) expecting the ext2 superblock, but it is at bytes 1024-2047.
**Why it happens:** ext2 reserves the first 1024 bytes for boot record (even on non-bootable partitions). The superblock is at offset 1024.
**How to avoid:** In `types.zig`, define `pub const SUPERBLOCK_OFFSET: u64 = 1024`. The BlockDevice caller must read starting at LBA 2 (bytes 1024-2047 = sectors 2-3) to get the superblock. Phase 46 implements this; Phase 45 only needs the constant.

### Pitfall 6: ext2.img Rebuild on Every `zig build`
**What goes wrong:** The `create_ext2_cmd` shell script runs every `zig build run`, destroying any data written by a previous kernel run.
**Why it happens:** `b.addSystemCommand` does not track outputs for caching. The existing `create_esp_cmd` and `create_disk_img` steps have the same issue.
**How to avoid:** Add an existence check to the shell script: `[ -f ext2.img ] && echo "ext2.img already exists, skipping" && exit 0`. This is the same behavior as `sfs.img` (the kernel formats it on first boot if needed). For ext2, mke2fs MUST run at build time because the kernel won't format the image. A sentinel file approach works: create `ext2.img.stamp` on success, check for it before re-running.
**Warning signs:** Each `zig build run` resets the filesystem.

## Code Examples

### Build Step: ext2.img Creation

```zig
// In build.zig pub fn build(b: *std.Build)
// Place after create_disk_img is defined, before run_cmd.step.dependOn

const ext2_img_mb: u32 = 64; // 64MB ext2 image

const ext2_script = b.fmt(
    \\set -e && \
    \\if [ -f ext2.img.stamp ]; then echo "ext2.img up to date, skipping"; exit 0; fi && \
    \\MKE2FS=$( \
    \\  ls /opt/homebrew/opt/e2fsprogs/sbin/mke2fs 2>/dev/null || \
    \\  ls /usr/local/opt/e2fsprogs/sbin/mke2fs 2>/dev/null || \
    \\  which mke2fs 2>/dev/null || \
    \\  echo "") && \
    \\if [ -z "$MKE2FS" ]; then \
    \\    echo "ERROR: mke2fs not found. On macOS: brew install e2fsprogs" >&2; \
    \\    exit 1; \
    \\fi && \
    \\echo "Using mke2fs: $MKE2FS" && \
    \\dd if=/dev/zero of=ext2.img bs=1M count={d} 2>/dev/null && \
    \\"$MKE2FS" -t ext2 -b 4096 -L "zk-ext2" -m 0 ext2.img && \
    \\touch ext2.img.stamp && \
    \\echo "ext2.img created successfully ({d}MB, 4KB blocks)"
, .{ ext2_img_mb, ext2_img_mb });

const create_ext2_cmd = b.addSystemCommand(&.{ "sh", "-c", ext2_script });

// Wire into run step
run_cmd.step.dependOn(&create_ext2_cmd.step);
```

**mke2fs flags:**
- `-t ext2`: Format as ext2 (not ext3/ext4, no journal)
- `-b 4096`: 4KB block size (matches page cache, reduces multi-sector reads)
- `-L "zk-ext2"`: Volume label for identification
- `-m 0`: No reserved blocks (kernel does not need them)

### QEMU Device Attachment (Both Architectures)

```zig
// In build.zig run_cmd setup, after existing sfs.img attachment

// VirtIO-SCSI for ext2 on aarch64 (same controller as sfs.img, different LUN)
if (target_arch == .aarch64) {
    run_cmd.addArgs(&.{
        "-drive", "file=ext2.img,format=raw,if=none,id=ext2disk",
        "-device", "scsi-hd,drive=ext2disk,bus=scsi0.0",
    });
}

// VirtIO-SCSI for ext2 on x86_64 (add VirtIO-SCSI controller if not present)
if (target_arch == .x86_64) {
    run_cmd.addArgs(&.{
        "-device", "virtio-scsi-pci,id=scsi0",
        "-drive", "file=ext2.img,format=raw,if=none,id=ext2disk",
        "-device", "scsi-hd,drive=ext2disk,bus=scsi0.0",
    });
}
```

Note: On x86_64, check whether `scsi0` controller was already added. If not, add it here. This is safe because the existing x86_64 QEMU command does NOT add a VirtIO-SCSI controller currently.

### BlockDevice Interface

```zig
// src/fs/block_device.zig
//
// LBA-based block device abstraction.
// No position state: every call specifies LBA explicitly.
// Thread-safe by construction (no shared mutable position field).

pub const BlockDeviceError = error{
    IOError,
    InvalidLba,
    DeviceNotReady,
    BufferTooSmall,
};

pub const SECTOR_SIZE: usize = 512;

pub const BlockDevice = struct {
    ctx: *anyopaque,
    readSectors: *const fn (ctx: *anyopaque, lba: u64, count: u32, buf: []u8) BlockDeviceError!void,
    writeSectors: *const fn (ctx: *anyopaque, lba: u64, count: u32, buf: []const u8) BlockDeviceError!void,
    sector_count: u64,

    pub fn read(self: BlockDevice, lba: u64, count: u32, buf: []u8) BlockDeviceError!void {
        if (buf.len < @as(usize, count) * SECTOR_SIZE) return error.BufferTooSmall;
        if (lba + count > self.sector_count) return error.InvalidLba;
        return self.readSectors(self.ctx, lba, count, buf);
    }

    pub fn write(self: BlockDevice, lba: u64, count: u32, buf: []const u8) BlockDeviceError!void {
        if (buf.len < @as(usize, count) * SECTOR_SIZE) return error.BufferTooSmall;
        if (lba + count > self.sector_count) return error.InvalidLba;
        return self.writeSectors(self.ctx, lba, count, buf);
    }
};
```

### VirtIO-SCSI BlockDevice Adapter

```zig
// In src/drivers/virtio/scsi/root.zig (or new adapter file)

const block_device = @import("../../../fs/block_device.zig");

pub fn asBlockDevice(lun_idx: u8) block_device.BlockDevice {
    return .{
        .ctx = @ptrFromInt(@as(usize, lun_idx)), // lun index as ctx
        .readSectors = virtioScsiRead,
        .writeSectors = virtioScsiWrite,
        .sector_count = getController().?.getLun(lun_idx).?.capacity_bytes / 512,
    };
}

fn virtioScsiRead(ctx: *anyopaque, lba: u64, count: u32, buf: []u8) block_device.BlockDeviceError!void {
    const lun_idx: u8 = @intCast(@intFromPtr(ctx) & 0xFF);
    const controller = getController() orelse return error.DeviceNotReady;
    controller.readBlocks(lun_idx, lba, count, buf) catch return error.IOError;
}
```

### ext2 types.zig Skeleton with Comptime Assertions

```zig
// src/fs/ext2/types.zig
// Phase 45: skeleton with size assertions.
// Phase 46: fill in full superblock/inode/dir-entry fields.

/// Byte offset of the ext2 superblock from the start of the partition.
/// Bytes 0-1023 are reserved for the boot record (even on non-bootable volumes).
pub const SUPERBLOCK_OFFSET: u64 = 1024;
pub const EXT2_MAGIC: u16 = 0xEF53;
pub const SECTOR_SIZE: usize = 512;

/// Sectors containing the superblock (LBA 2 and 3 at 512 bytes/sector)
pub const SUPERBLOCK_START_LBA: u64 = SUPERBLOCK_OFFSET / SECTOR_SIZE; // = 2

/// Ext2 superblock (1024 bytes, at partition offset 1024).
/// All fields little-endian.
/// Reference: https://ext4.wiki.kernel.org/index.php/Ext4_Disk_Layout#The_Super_Block
pub const Superblock = extern struct {
    s_inodes_count: u32 align(1),
    s_blocks_count: u32 align(1),
    s_r_blocks_count: u32 align(1),
    s_free_blocks_count: u32 align(1),
    s_free_inodes_count: u32 align(1),
    s_first_data_block: u32 align(1),
    s_log_block_size: u32 align(1),
    s_log_frag_size: i32 align(1),
    s_blocks_per_group: u32 align(1),
    s_frags_per_group: u32 align(1),
    s_inodes_per_group: u32 align(1),
    s_mtime: u32 align(1),
    s_wtime: u32 align(1),
    s_mnt_count: u16 align(1),
    s_max_mnt_count: i16 align(1),
    s_magic: u16 align(1),           // Must be EXT2_MAGIC = 0xEF53
    s_state: u16 align(1),
    s_errors: u16 align(1),
    s_minor_rev_level: u16 align(1),
    s_lastcheck: u32 align(1),
    s_checkinterval: u32 align(1),
    s_creator_os: u32 align(1),
    s_rev_level: u32 align(1),
    s_def_resuid: u16 align(1),
    s_def_resgid: u16 align(1),
    // Rev 1+ extended fields
    s_first_ino: u32 align(1),
    s_inode_size: u16 align(1),
    s_block_group_nr: u16 align(1),
    s_feature_compat: u32 align(1),
    s_feature_incompat: u32 align(1),
    s_feature_ro_compat: u32 align(1),
    s_uuid: [16]u8,
    s_volume_name: [16]u8,
    s_last_mounted: [64]u8,
    s_algo_bitmap: u32 align(1),
    // Performance hints
    s_prealloc_blocks: u8,
    s_prealloc_dir_blocks: u8,
    _align_pad: [2]u8,
    // Journal support (ext3)
    s_journal_uuid: [16]u8,
    s_journal_inum: u32 align(1),
    s_journal_dev: u32 align(1),
    s_last_orphan: u32 align(1),
    // Directory indexing support
    s_hash_seed: [4]u32,
    s_def_hash_version: u8,
    _reserved_char: u8,
    _reserved_word: u16 align(1),
    // Other options
    s_default_mount_opts: u32 align(1),
    s_first_meta_bg: u32 align(1),
    _reserved: [760]u8,              // Pad to 1024 bytes total
};

comptime {
    const sb_size = @sizeOf(Superblock);
    if (sb_size != 1024) {
        @compileError(std.fmt.comptimePrint(
            "ext2 Superblock size mismatch: got {d}, expected 1024", .{sb_size}
        ));
    }
}
```

**Note on padding:** The exact padding value for `_reserved` requires counting all preceding fields. The numbers above are approximate. When implementing, adjust the pad to make the comptime assertion pass. Total non-pad bytes are approximately 264; `_reserved` = `1024 - 264 = 760`. Verify by compiling.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|---|---|---|---|
| SFS: save/restore fd.position under io_lock | BlockDevice: explicit LBA per call | Phase 45 | Eliminates position-state race; no lock needed for LBA argument |
| sfs.img created manually by developer | ext2.img created automatically by `zig build` | Phase 45 | Reproducible dev/CI setup without manual host steps |
| Single storage filesystem (SFS) on one QEMU disk | Two storage disks: sfs.img (SFS at /mnt) + ext2.img (ext2 at /mnt2) | Phase 45 | ext2 coexists with SFS; 186 existing tests keep passing at /mnt |

**Decisions from STATE.md relevant to this phase:**
- ext2 mounts at `/mnt2` (not `/mnt`) -- SFS stays at `/mnt` to keep 186 tests passing
- 4KB block size for test images (aligns with page cache, reduces multi-sector reads)

## Open Questions

1. **x86_64 QEMU VirtIO-SCSI controller conflict**
   - What we know: Current x86_64 QEMU command does NOT include VirtIO-SCSI; aarch64 does.
   - What's unclear: Whether adding VirtIO-SCSI to x86_64 conflicts with anything (it should not, since the kernel already has the virtio_scsi driver compiled for both architectures).
   - Recommendation: Add `virtio-scsi-pci,id=scsi0` to x86_64 QEMU args alongside the existing AHCI boot disk. This is additive and non-breaking.

2. **ext2.img rebuild idempotency in CI**
   - What we know: CI runs a fresh checkout every time; ext2.img will not exist.
   - What's unclear: Whether a stamp-file approach interferes with Zig's incremental build cache.
   - Recommendation: Use the stamp file on developer machines; in CI the file simply does not exist and mke2fs runs unconditionally. The stamp file check (`[ -f ext2.img.stamp ]`) handles both cases correctly.

3. **Superblock padding calculation correctness**
   - What we know: ext2 spec defines superblock as exactly 1024 bytes starting at byte 1024 of the partition.
   - What's unclear: Whether the field list above captures all ext2 rev-1 fields correctly to pad to exactly 1024 bytes.
   - Recommendation: Use the comptime assertion as the authoritative check. Adjust `_reserved` array size until `@sizeOf(Superblock) == 1024` compiles.

## Sources

### Primary (HIGH confidence)
- Build.zig source in-repo (read directly) -- `b.addSystemCommand`, disk image creation, QEMU run configuration, arch-split storage patterns
- `src/fs/sfs/io.zig` (read directly) -- the position-state race being fixed by BlockDevice
- `src/fs/sfs/types.zig` (read directly) -- comptime size assertion pattern to replicate
- `src/drivers/virtio/scsi/root.zig` and `adapter.zig` (read directly) -- BlockDevice adapter pattern
- `.planning/REQUIREMENTS.md` (read directly) -- BUILD-01, BUILD-02, BUILD-03 exact requirements
- `.planning/STATE.md` (read directly) -- locked decisions (4KB blocks, /mnt2 mount point)

### Secondary (MEDIUM confidence)
- Homebrew `e2fsprogs` package info (verified: `brew info e2fsprogs` shows 1.47.3, keg-only at `/opt/homebrew/opt/e2fsprogs/sbin/`)
- Android SDK mke2fs at `/Users/whit3rabbit/Library/Android/sdk/platform-tools/mke2fs` (verified present, shows standard mke2fs usage)
- CI workflow `.github/workflows/ci.yml` (read directly) -- Ubuntu CI installs `mtools`, `xorriso` but NOT `e2fsprogs` explicitly (ubuntu has mke2fs in default image)

### Tertiary (LOW confidence)
- ext2 superblock field layout from training knowledge -- field names and offsets are well-established but exact padding calculation requires compilation to verify

## Metadata

**Confidence breakdown:**
- Standard stack (mke2fs, QEMU flags, Zig build patterns): HIGH -- verified in project source files
- Architecture patterns (BlockDevice interface design): HIGH -- root cause verified in sfs/io.zig, fix is straightforward
- ext2 superblock struct accuracy: MEDIUM -- field list matches spec but pad calculation requires compile-time verification
- Pitfalls (mke2fs path, QEMU bus conflicts): HIGH -- verified from build.zig and CI workflow inspection

**Research date:** 2026-02-22
**Valid until:** 2026-04-22 (stable domain -- ext2 spec and Zig 0.16.x build API are stable)
