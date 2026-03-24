const std = @import("std");
const fd = @import("fd");
const vfs = @import("../vfs.zig");
const meta = @import("fs_meta");
const uapi = @import("uapi");
const console = @import("console");
const heap = @import("heap");
const t = @import("types.zig");
const sfs_io = @import("io.zig");
const sfs_alloc = @import("alloc.zig");

// =============================================================================
// File Operation Implementations
// =============================================================================

/// Maximum sectors for batched reads - 32 sectors = 16KB (safe for kernel stack)
pub const MAX_BATCH_SECTORS: u16 = 32;

pub fn sfsRead(file_desc: *fd.FileDescriptor, buf: []u8) isize {
    const held = file_desc.lock.acquire();
    defer held.release();

    const file: *t.SfsFile = @ptrCast(@alignCast(file_desc.private_data));

    const current_size = refreshSizeFromDisk(file) orelse {
        return 0;
    };
    if (current_size < file.size) {
        file.size = current_size;
        if (file_desc.position > current_size) {
            file_desc.position = current_size;
        }
    }

    if (file_desc.position >= file.size) return 0;

    const remaining = file.size - file_desc.position;
    const to_read = @min(buf.len, remaining);

    const start_byte = file_desc.position;
    const end_byte = std.math.add(usize, start_byte, to_read) catch {
        return 0;
    };
    const first_sector = start_byte / 512;
    const last_sector = (std.math.add(usize, end_byte, 511) catch {
        return 0;
    }) / 512;
    const sector_count = std.math.sub(usize, last_sector, first_sector) catch {
        return 0;
    };

    const first_sector_u32 = std.math.cast(u32, first_sector) orelse return -5;

    const file_blocks: u32 = if (file.size == 0) 1 else (file.size + 511) / 512;
    if (first_sector_u32 >= file_blocks) {
        return 0;
    }

    const phys_block_start = file.start_block + first_sector_u32;
    if (phys_block_start >= file.fs.superblock.total_blocks) {
        console.warn("SFS: Read block {} exceeds total_blocks {}", .{ phys_block_start, file.fs.superblock.total_blocks });
        return -5;
    }

    const sector_count_u16 = std.math.cast(u16, @min(sector_count, MAX_BATCH_SECTORS)) orelse return -5;

    if (sector_count > 1 and sector_count <= MAX_BATCH_SECTORS) {
        const total_bytes = @as(usize, sector_count_u16) * 512;

        // SECURITY: Allocate on heap to prevent stack overflow (16KB is too large for kernel stack)
        const alloc = heap.allocator();
        const sector_buf = alloc.alloc(u8, MAX_BATCH_SECTORS * 512) catch return -12; // ENOMEM
        defer alloc.free(sector_buf);

        // SECURITY: Zero-initialize to prevent information leak if DMA fails or returns partial data
        @memset(sector_buf, 0);

        const end_block = phys_block_start + sector_count_u16 - 1;
        if (end_block >= file.fs.superblock.total_blocks) {
            console.warn("SFS: Read end block {} exceeds total_blocks {}", .{ end_block, file.fs.superblock.total_blocks });
            return -5;
        }

        sfs_io.readSectorsAsync(file.fs, phys_block_start, sector_count_u16, sector_buf[0..total_bytes]) catch return -5;

        const byte_offset = start_byte % 512;
        @memcpy(buf[0..to_read], sector_buf[byte_offset..][0..to_read]);

        file_desc.position += to_read;
        return std.math.cast(isize, to_read) orelse return -75;
    }

    var read_count: usize = 0;
    var current_pos = file_desc.position;

    while (read_count < to_read) {
        const rel_pos = current_pos;
        const block_offset = rel_pos / 512;
        const byte_offset = rel_pos % 512;

        const block_offset_u32 = std.math.cast(u32, block_offset) orelse return -5;

        if (block_offset_u32 >= file_blocks) {
            break;
        }

        const phys_block = file.start_block + block_offset_u32;
        if (phys_block >= file.fs.superblock.total_blocks) {
            console.warn("SFS: Read block {} exceeds total_blocks {}", .{ phys_block, file.fs.superblock.total_blocks });
            return -5;
        }

        // SECURITY: Zero-initialize to prevent information leak if read fails
        var sector_buf: [512]u8 align(4) = [_]u8{0} ** 512;
        sfs_io.readSector(file.fs, phys_block, &sector_buf) catch return -5;

        const chunk = @min(to_read - read_count, 512 - byte_offset);
        @memcpy(buf[read_count..][0..chunk], sector_buf[byte_offset..][0..chunk]);

        read_count += chunk;
        current_pos += chunk;
    }

    file_desc.position += read_count;
    return std.math.cast(isize, read_count) orelse return -75;
}

pub fn sfsWrite(file_desc: *fd.FileDescriptor, buf: []const u8) isize {
    // NOTE: Caller (sys_write) holds file_desc.lock
    const file: *t.SfsFile = @ptrCast(@alignCast(file_desc.private_data));

    const prelim_current_blocks: u32 = if (file.size == 0) 1 else (file.size + 511) / 512;

    const new_size_needed = std.math.add(u64, file_desc.position, buf.len) catch {
        return -27; // EFBIG
    };
    const new_blocks_needed = (new_size_needed + 511) / 512;
    const new_blocks_needed_u32 = std.math.cast(u32, new_blocks_needed) orelse return -27;

    if (new_blocks_needed_u32 > prelim_current_blocks) {
        // PHASE 1: Allocate UNDER LOCK with double-check
        var allocated = false;
        var old_next_free: u32 = 0;
        var blocks_added: u32 = 0;
        {
            const alloc_held = file.fs.alloc_lock.acquire();
            defer alloc_held.release();

            // Re-validate under lock (another thread may have allocated)
            const current_blocks: u32 = if (file.size == 0) 1 else (file.size + 511) / 512;
            const end_block = file.start_block + current_blocks;

            if (new_blocks_needed_u32 > current_blocks) {
                // Verify file is at end of allocation zone
                if (end_block != file.fs.superblock.next_free_block) {
                    if (file.size != 0) {
                        console.warn("SFS: Cannot grow file not at end of allocation", .{});
                        return -28; // ENOSPC
                    }
                }

                blocks_added = new_blocks_needed_u32 - current_blocks;
                if (blocks_added > file.fs.superblock.free_blocks) {
                    return -28;
                }

                const new_next_free = std.math.add(u32, file.fs.superblock.next_free_block, blocks_added) catch {
                    return -28;
                };
                if (new_next_free > file.fs.superblock.total_blocks) {
                    return -28;
                }

                // Save old value for rollback
                old_next_free = file.fs.superblock.next_free_block;

                // Update in-memory superblock under lock
                file.fs.superblock.next_free_block = new_next_free;
                file.fs.superblock.free_blocks -= blocks_added;
                allocated = true;
            }
            // Lock released here
        }

        // PHASE 2: Persist AFTER lock release
        if (allocated) {
            sfs_io.updateSuperblock(file.fs) catch {
                // Rollback in-memory state on persist failure
                const rollback_held = file.fs.alloc_lock.acquire();
                defer rollback_held.release();
                file.fs.superblock.next_free_block = old_next_free;
                file.fs.superblock.free_blocks += blocks_added;
                return -5;
            };
        }
    }

    // SECURITY: Handle sparse file writes - zero-fill gaps when writing beyond EOF
    // This prevents information leaks from uninitialized disk sectors
    const current_size: u64 = file.size;
    if (file_desc.position > current_size) {
        // Calculate blocks that need zero-filling
        const gap_start_byte = current_size;
        const gap_end_byte = file_desc.position;

        // Zero-fill the gap sector by sector
        var fill_pos = gap_start_byte;
        while (fill_pos < gap_end_byte) {
            const block_offset = fill_pos / 512;
            const byte_offset = fill_pos % 512;

            const block_offset_u32 = std.math.cast(u32, block_offset) orelse return -27;
            const phys_block = file.start_block + block_offset_u32;

            if (phys_block >= file.fs.superblock.total_blocks) {
                console.warn("SFS: Gap fill block {} exceeds total_blocks {}", .{ phys_block, file.fs.superblock.total_blocks });
                return -5;
            }

            // SECURITY: Zero-initialize buffer to prevent information leak
            var zero_sector: [512]u8 align(4) = [_]u8{0} ** 512;

            // If not starting at sector boundary, read existing data first
            if (byte_offset != 0 or (gap_end_byte - fill_pos) < (512 - byte_offset)) {
                sfs_io.readSector(file.fs, phys_block, &zero_sector) catch {};
            }

            // Calculate how many bytes to zero in this sector
            const bytes_to_zero = @min(512 - byte_offset, gap_end_byte - fill_pos);
            @memset(zero_sector[byte_offset..][0..bytes_to_zero], 0);

            // Write back the sector
            sfs_io.writeSector(file.fs, phys_block, &zero_sector) catch return -5;

            // Advance to next sector or end of gap
            fill_pos = std.math.add(u64, fill_pos, bytes_to_zero) catch return -27;
        }

        // Update file size to include the gap (but don't update directory yet - that happens at end of write)
        file.size = std.math.cast(u32, gap_end_byte) orelse return -27;
    }

    var written_count: usize = 0;
    var current_pos = file_desc.position;

    const start_byte_offset = current_pos % 512;

    if (start_byte_offset == 0 and buf.len >= 1024) {
        const full_sectors = @min(buf.len / 512, MAX_BATCH_SECTORS);
        if (full_sectors >= 2) {
            const block_offset_u32 = std.math.cast(u32, current_pos / 512) orelse return -5;
            const phys_block = file.start_block + block_offset_u32;

            if (phys_block >= file.fs.superblock.total_blocks) {
                console.warn("SFS: Write block {} exceeds total_blocks {}", .{ phys_block, file.fs.superblock.total_blocks });
                return -5;
            }

            const sector_count_u16: u16 = @intCast(full_sectors);
            const end_block = phys_block + sector_count_u16 - 1;
            if (end_block >= file.fs.superblock.total_blocks) {
                console.warn("SFS: Write end block {} exceeds total_blocks {}", .{ end_block, file.fs.superblock.total_blocks });
                return -5;
            }

            const batch_bytes = @as(usize, sector_count_u16) * 512;

            sfs_io.writeSectorsAsync(file.fs, phys_block, sector_count_u16, buf[0..batch_bytes]) catch return -5;

            written_count = batch_bytes;
            current_pos += batch_bytes;
        }
    }

    while (written_count < buf.len) {
        const rel_pos = current_pos;
        const block_offset = rel_pos / 512;
        const byte_offset = rel_pos % 512;

        const block_offset_u32 = std.math.cast(u32, block_offset) orelse return -5;
        const phys_block = file.start_block + block_offset_u32;

        if (phys_block >= file.fs.superblock.total_blocks) {
            console.warn("SFS: Write block {} exceeds total_blocks {}", .{ phys_block, file.fs.superblock.total_blocks });
            return -5;
        }

        // SECURITY: Zero-initialize to prevent information leak if read fails or returns partial data
        var sector_buf: [512]u8 align(4) = [_]u8{0} ** 512;
        sfs_io.readSector(file.fs, phys_block, &sector_buf) catch {};

        const chunk = @min(buf.len - written_count, 512 - byte_offset);
        @memcpy(sector_buf[byte_offset..][0..chunk], buf[written_count..][0..chunk]);

        sfs_io.writeSector(file.fs, phys_block, &sector_buf) catch return -5;

        written_count += chunk;
        current_pos += chunk;
    }

    file_desc.position += written_count;
    if (file_desc.position > file.size) {
        file.size = std.math.cast(u32, file_desc.position) orelse return -27;

        if (file.entry_idx < t.MAX_FILES) {
            // PHASE 1: Calculate block location UNLOCKED
            const block_idx = file.entry_idx / 4;
            const offset_idx = file.entry_idx % 4;
            const offset_in_block = offset_idx * 128;

            // PHASE 2: Read directory block UNLOCKED
            var dir_buf: [512]u8 align(4) = [_]u8{0} ** 512;
            sfs_io.readSector(file.fs, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch {
                // Graceful degradation: data written, metadata update failed
                return std.math.cast(isize, written_count) orelse return -75;
            };

            // PHASE 3: Acquire lock, re-read for TOCTOU, modify in buffer, release lock
            var should_write = false;
            {
                const lock_held = file.fs.alloc_lock.acquire();
                defer lock_held.release();

                // Re-read under lock (TOCTOU prevention)
                sfs_io.readSector(file.fs, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch {
                    return std.math.cast(isize, written_count) orelse return -75;
                };

                // Validate and update in buffer
                const entry: *t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset_in_block]));

                // SECURITY: Validate start_block to prevent wrong-file race
                if (entry.flags == 1 and entry.start_block == file.start_block) {
                    entry.size = file.size;
                    should_write = true;
                }
            }

            // PHASE 4: Write directory block OUTSIDE lock
            if (should_write) {
                sfs_io.writeSector(file.fs, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch {
                    console.warn("SFS: Failed to write directory size update", .{});
                };
            }
        }
    }

    return std.math.cast(isize, written_count) orelse return -75;
}

pub fn sfsClose(file_desc: *fd.FileDescriptor) isize {
    const alloc = heap.allocator();
    const file: *t.SfsFile = @ptrCast(@alignCast(file_desc.private_data));

    const entry_idx = file.entry_idx;
    const fs = file.fs;

    if (entry_idx >= t.MAX_FILES) {
        console.err("SFS: Invalid entry_idx {} in close (max={})", .{ entry_idx, t.MAX_FILES });
        alloc.destroy(file);
        return -5;
    }

    var should_delete = false;
    var deferred_start_block: u32 = 0;
    var deferred_block_count: u32 = 0;
    {
        const lock_held = fs.alloc_lock.acquire();
        defer lock_held.release();

        if (entry_idx >= fs.open_counts.len) {
            alloc.destroy(file);
            return -5;
        }

        if (fs.open_counts[entry_idx] > 0) {
            fs.open_counts[entry_idx] -= 1;
        }

        if (fs.open_counts[entry_idx] == 0 and fs.pending_delete[entry_idx]) {
            should_delete = true;
            fs.pending_delete[entry_idx] = false;
            deferred_start_block = fs.deferred_info[entry_idx].start_block;
            deferred_block_count = fs.deferred_info[entry_idx].block_count;
            fs.deferred_info[entry_idx] = .{ .start_block = 0, .block_count = 0 };
        }
    }

    if (should_delete) {
        sfs_alloc.freeBlocks(fs, deferred_start_block, deferred_block_count);
        console.info("SFS: Deferred deletion completed for entry {} (freed {} blocks at {})", .{ entry_idx, deferred_block_count, deferred_start_block });
    }

    alloc.destroy(file);
    return 0;
}

pub fn sfsUnmount(ctx: ?*anyopaque) void {
    if (ctx) |ptr| {
        const self: *t.SFS = @ptrCast(@alignCast(ptr));
        {
            const held = self.alloc_lock.acquire();
            defer held.release();
            self.mounted = false;
            for (self.open_counts) |count| {
                if (count > 0) {
                    console.warn("SFS: Unmounting with open files - operations may fail", .{});
                    break;
                }
            }
        }

        if (self.device_fd.ops.close) |close_fn| {
            _ = close_fn(self.device_fd);
        }

        if (self.bitmap_cache) |cache| {
            heap.allocator().free(cache);
        }

        heap.allocator().destroy(self);
    }
}

/// Open a file in the SFS filesystem.
///
/// SECURITY NOTE: Permission checks (mode/uid/gid validation) are intentionally NOT performed here.
/// This follows the layered security model where:
///   1. Syscall layer (sys_open) validates user credentials and access rights
///   2. VFS layer performs path canonicalization and mount-point permission checks
///   3. Filesystem layer (here) handles storage-level operations only
///
/// This design prevents redundant checks and ensures permission policy is centralized.
/// Direct calls to sfsOpen from kernel code bypass permission checks by design (kernel has full access).
/// See: src/kernel/sys/syscall/fs/open.zig for permission enforcement.
pub fn sfsOpen(ctx: ?*anyopaque, path: []const u8, flags: u32) vfs.Error!*fd.FileDescriptor {
    const self: *t.SFS = @ptrCast(@alignCast(ctx));
    if (!self.mounted) return vfs.Error.IOError;

    const alloc = heap.allocator();
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    // Handle directory opening (root directory "/" or ".") BEFORE validation
    // Empty name is allowed for root directory
    if (name.len == 0 or std.mem.eql(u8, name, ".")) {
        // Create a directory file descriptor for getdents support
        const file_ctx = alloc.create(t.SfsFile) catch return vfs.Error.NoMemory;
        file_ctx.* = .{
            .fs = self,
            .start_block = 0, // Not used for directory
            .size = 0, // Not used for directory
            .entry_idx = 0, // Root directory
            .mode = meta.S_IFDIR | 0o755, // Directory mode
            .uid = 0,
            .gid = 0,
        };

        // Create FD - use sfs_ops which includes our getdents function
        return fd.createFd(&sfs_ops, flags, file_ctx) catch {
            alloc.destroy(file_ctx);
            return vfs.Error.NoMemory;
        };
    }

    // Validate filename for regular files (after root directory handling)
    if (!sfs_alloc.isValidFilename(name)) return vfs.Error.AccessDenied;

    if (name.len >= 32) return vfs.Error.NameTooLong;

    var entry_idx: ?u32 = null;
    var entry: t.DirEntry = undefined;

    // SECURITY: Allocate directory buffer on heap to prevent stack overflow
    const dir_buf = alloc.alloc(u8, t.ROOT_DIR_BLOCKS * 512) catch return vfs.Error.NoMemory;
    defer alloc.free(dir_buf);
    sfs_io.readDirectoryAsync(self, dir_buf) catch return vfs.Error.IOError;

    const total_entries = t.ROOT_DIR_BLOCKS * 4;
    var idx: u32 = 0;
    while (idx < total_entries) : (idx += 1) {
        const offset = idx * 128;
        const e: *t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset]));

        if (e.flags == 1) {
            const e_name = std.mem.sliceTo(&e.name, 0);
            if (e_name.len >= 32) continue;
            if (std.mem.eql(u8, e_name, name)) {
                entry_idx = idx;
                entry = e.*;
                break;
            }
        }
    }

    if (entry_idx) |found_idx| {
        // Validate block range for regular files only
        // Directories have start_block=0 and don't own data blocks
        if (!entry.isDirectory()) {
            if (entry.start_block < self.superblock.data_start or
                entry.start_block >= self.superblock.total_blocks)
            {
                console.warn("SFS: Corrupted entry '{s}' with invalid start_block {}", .{ name, entry.start_block });
                return vfs.Error.IOError;
            }

            const max_possible_blocks = self.superblock.total_blocks - entry.start_block;
            const max_possible_size = max_possible_blocks * 512;
            if (entry.size > max_possible_size) {
                console.warn("SFS: Corrupted entry '{s}' with size {} > max {}", .{ name, entry.size, max_possible_size });
                return vfs.Error.IOError;
            }
        }

        // SECURITY: Handle O_TRUNC before creating file context
        if ((flags & fd.O_TRUNC) != 0 and !entry.isDirectory()) {
            // Check if file is writable
            const access_mode = flags & fd.O_ACCMODE;
            if (access_mode == fd.O_WRONLY or access_mode == fd.O_RDWR) {
                // Calculate block location
                const block_idx = found_idx / 4;
                const offset_in_block = std.math.mul(usize, found_idx % 4, 128) catch return vfs.Error.IOError;

                // Acquire lock, re-read, validate, modify in buffer, release lock
                var block_buf: [512]u8 align(4) = [_]u8{0} ** 512;
                {
                    const held_trunc = self.alloc_lock.acquire();
                    defer held_trunc.release();

                    // Re-read directory entry under lock (TOCTOU prevention)
                    sfs_io.readSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;

                    const trunc_entry: *t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));

                    // Validate entry still exists and matches
                    if (trunc_entry.flags != 1) return vfs.Error.NotFound;
                    if (trunc_entry.start_block != entry.start_block) return vfs.Error.NotFound;

                    // Update size to 0 in buffer (keep blocks allocated for simplicity)
                    trunc_entry.size = 0;
                }

                // Write directory sector back OUTSIDE lock
                sfs_io.writeSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;

                // Update entry in our local copy so file_ctx gets correct size
                entry.size = 0;
            }
        }

        const file_ctx = alloc.create(t.SfsFile) catch return vfs.Error.NoMemory;
        file_ctx.* = .{
            .fs = self,
            .start_block = entry.start_block,
            .size = entry.size,
            .entry_idx = found_idx,
            .mode = entry.mode,
            .uid = entry.uid,
            .gid = entry.gid,
        };

        {
            const lock_held = self.alloc_lock.acquire();
            defer lock_held.release();

            if (self.pending_delete[found_idx]) {
                alloc.destroy(file_ctx);
                return vfs.Error.NotFound;
            }
            self.open_counts[found_idx] = std.math.add(u32, self.open_counts[found_idx], 1) catch {
                alloc.destroy(file_ctx);
                return vfs.Error.NoMemory;
            };
        }

        const file_fd = fd.createFd(&sfs_ops, flags, file_ctx) catch {
            const lock_held = self.alloc_lock.acquire();
            defer lock_held.release();
            if (self.open_counts[found_idx] > 0) {
                self.open_counts[found_idx] -= 1;
            }
            alloc.destroy(file_ctx);
            return vfs.Error.NoMemory;
        };

        // SECURITY: Handle O_APPEND by seeking to EOF
        // This must be done after FD creation to access position field
        if ((flags & fd.O_APPEND) != 0 and !entry.isDirectory()) {
            const fd_held = file_fd.lock.acquire();
            defer fd_held.release();
            // Use the actual current size (may have been truncated by O_TRUNC above)
            file_fd.position = file_ctx.size;
        }

        return file_fd;
    } else {
        if ((flags & fd.O_CREAT) != 0) {
            console.debug("SFS: O_CREAT - allocating block", .{});
            // SECURITY: Allocate block FIRST (takes its own lock internally),
            // then do all metadata updates atomically under a single lock hold.
            // This prevents TOCTOU race where another thread could see partial state.
            const start_block = sfs_alloc.allocateBlock(self) catch {
                return vfs.Error.NoMemory;
            };
            console.debug("SFS: Allocated block {}", .{start_block});

            // If anything fails after block allocation, free the block
            errdefer sfs_alloc.freeBlock(self, start_block) catch {};

            const default_mode: u32 = meta.S_IFREG | 0o644;
            var new_entry = t.DirEntry{
                .name = [_]u8{0} ** 32,
                .start_block = start_block,
                .size = 0,
                .flags = 1,
                .mode = default_mode,
                .uid = 0,
                .gid = 0,
                .mtime = 0,
                .atime = 0,
                .nlink = 1,
                ._pad = [_]u8{0} ** (128 - 68),
            };
            @memcpy(new_entry.name[0..name.len], name);

            console.debug("SFS: Reading directory (unlocked)", .{});
            // PHASE 1: Read directory UNLOCKED to find free slot
            sfs_io.readDirectoryAsync(self, dir_buf) catch {
                return vfs.Error.IOError;
            };
            console.debug("SFS: Directory read complete", .{});

            // PHASE 2: Find free slot UNLOCKED
            var free_slot: ?u32 = null;
            for (0..t.MAX_FILES) |slot_i| {
                const slot_idx: u32 = @intCast(slot_i);
                const blk_idx = slot_idx / 4;
                const off_idx = slot_idx % 4;
                const e: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf[blk_idx * 512 + off_idx * 128]));
                if (e.flags == 0) {
                    free_slot = slot_idx;
                    break;
                }
            }

            const new_idx = free_slot orelse {
                console.debug("SFS: No free slots available", .{});
                return vfs.Error.NoMemory;
            };
            console.debug("SFS: Found free slot {}", .{new_idx});

            // PHASE 3: Calculate block location
            const block_idx = new_idx / 4;
            const offset_in_block = std.math.mul(usize, new_idx % 4, 128) catch return vfs.Error.IOError;

            // PHASE 4: Acquire lock, re-read, validate, modify in buffer, update counters, release lock
            console.debug("SFS: Acquiring alloc_lock", .{});
            var block_buf: [512]u8 align(4) = [_]u8{0} ** 512;
            {
                const lock_held = self.alloc_lock.acquire();
                defer lock_held.release();
                console.debug("SFS: Lock acquired", .{});

                // Check file count under lock
                if (self.superblock.file_count >= t.MAX_FILES) {
                    return vfs.Error.NoMemory;
                }

                // Re-read SPECIFIC BLOCK under lock to validate slot still free (TOCTOU prevention)
                console.debug("SFS: Reading block {} under lock", .{block_idx});
                sfs_io.readSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch {
                    return vfs.Error.IOError;
                };
                const verify_entry: *const t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));
                if (verify_entry.flags != 0) {
                    // Slot taken by another thread - race detected
                    return vfs.Error.NoMemory;
                }

                // Write new entry to buffer
                const dest: *t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));
                dest.* = new_entry;

                // Update superblock file count in memory
                self.superblock.file_count += 1;

                // Clear stale pending_delete state from previous file at this slot.
                // When a file is unlinked while open, pending_delete is set. The
                // directory entry's flags are cleared to 0 on disk, making the slot
                // appear free. If the close that should clear pending_delete never
                // runs (FD leak), the stale pending_delete blocks future opens of
                // any new file created at this slot.
                self.pending_delete[new_idx] = false;
                self.deferred_info[new_idx] = .{ .start_block = 0, .block_count = 0 };

                // Set open count (not increment -- fresh file at this slot)
                self.open_counts[new_idx] = 1;

            }

            // PHASE 5: Write directory block OUTSIDE lock
            sfs_io.writeSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch |err| {
                // Rollback on write failure
                const held = self.alloc_lock.acquire();
                defer held.release();
                if (self.open_counts[new_idx] > 0) self.open_counts[new_idx] -= 1;
                self.superblock.file_count -= 1;
                return err;
            };
            console.debug("SFS: Block write complete", .{});

            // PHASE 6: Write superblock OUTSIDE lock
            console.debug("SFS: Updating superblock outside lock", .{});
            sfs_io.updateSuperblock(self) catch |err| {
                // Rollback on superblock write failure (directory already written - partial state)
                const held = self.alloc_lock.acquire();
                defer held.release();
                if (self.open_counts[new_idx] > 0) self.open_counts[new_idx] -= 1;
                self.superblock.file_count -= 1;
                return err;
            };
            console.debug("SFS: Superblock updated", .{});

            console.debug("SFS: Create succeeded, allocating file context", .{});

            const file_ctx = alloc.create(t.SfsFile) catch {
                const lock_held = self.alloc_lock.acquire();
                defer lock_held.release();
                if (self.open_counts[new_idx] > 0) self.open_counts[new_idx] -= 1;
                return vfs.Error.NoMemory;
            };
            console.debug("SFS: File context allocated", .{});

            file_ctx.* = .{
                .fs = self,
                .start_block = new_entry.start_block,
                .size = 0,
                .entry_idx = new_idx,
                .mode = new_entry.mode,
                .uid = new_entry.uid,
                .gid = new_entry.gid,
            };

            console.debug("SFS: Creating file descriptor", .{});
            return fd.createFd(&sfs_ops, flags, file_ctx) catch {
                console.debug("SFS: createFd failed, rolling back", .{});
                const lock_held = self.alloc_lock.acquire();
                defer lock_held.release();
                if (self.open_counts[new_idx] > 0) self.open_counts[new_idx] -= 1;
                alloc.destroy(file_ctx);
                return vfs.Error.NoMemory;
            };
        }

        return vfs.Error.NotFound;
    }
}

pub fn sfsUnlink(ctx: ?*anyopaque, path: []const u8) vfs.Error!void {
    const self: *t.SFS = @ptrCast(@alignCast(ctx));
    if (!self.mounted) return vfs.Error.IOError;

    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;
    if (!sfs_alloc.isValidFilename(name)) return vfs.Error.AccessDenied;
    if (name.len == 0 or name.len >= 32) return vfs.Error.NotFound;

    // SECURITY: Allocate directory buffer on heap to prevent stack overflow
    const alloc = heap.allocator();
    const dir_buf_unlink = alloc.alloc(u8, t.ROOT_DIR_BLOCKS * 512) catch return vfs.Error.NoMemory;
    defer alloc.free(dir_buf_unlink);

    // First pass: find the entry index (unlocked, for efficiency)
    var found_idx: ?u32 = null;
    {
        sfs_io.readDirectoryAsync(self, dir_buf_unlink) catch return vfs.Error.IOError;

        const total_entries = t.ROOT_DIR_BLOCKS * 4;
        var idx: u32 = 0;
        while (idx < total_entries) : (idx += 1) {
            const offset = idx * 128;
            const e: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf_unlink[offset]));

            if (e.flags == 1) {
                const e_name = std.mem.sliceTo(&e.name, 0);
                if (e_name.len >= 32) continue;
                if (std.mem.eql(u8, e_name, name)) {
                    found_idx = idx;
                    break;
                }
            }
        }
    }

    const idx = found_idx orelse return vfs.Error.NotFound;

    // Capture block info under lock, then free blocks OUTSIDE the lock.
    // freeBlocks -> freeBlock acquires alloc_lock internally, so calling it
    // while already holding alloc_lock would self-deadlock (non-reentrant spinlock).
    var free_start: u32 = 0;
    var free_count: u32 = 0;
    var needs_free = false;
    {
        // SECURITY: Hold lock through directory mutation to prevent TOCTOU race
        const lock_held = self.alloc_lock.acquire();
        defer lock_held.release();

        // SECURITY: Re-read the specific directory block under lock to prevent TOCTOU
        // The entry we found in the first pass may have been modified by another thread
        const block_idx = idx / 4;
        const offset_in_block = (idx % 4) * 128;
        var block_buf: [512]u8 align(4) = [_]u8{0} ** 512;
        sfs_io.readSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;

        const e: *t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));

        // Re-validate entry under lock: check it still exists and has the same name
        if (e.flags != 1) {
            return vfs.Error.NotFound;
        }
        const e_name = std.mem.sliceTo(&e.name, 0);
        if (!std.mem.eql(u8, e_name, name)) {
            // Entry was replaced with a different file - race condition
            return vfs.Error.NotFound;
        }

        const blocks_used: u32 = if (e.size == 0) 1 else (e.size + 511) / 512;
        const target_start_block = e.start_block;
        const effective_nlink = if (e.nlink == 0) @as(u32, 1) else e.nlink;

        var is_open = false;
        if (self.open_counts[idx] > 0) {
            is_open = true;
            self.pending_delete[idx] = true;
            self.deferred_info[idx] = .{
                .start_block = e.start_block,
                .block_count = blocks_used,
            };
            console.info("SFS: Deferring deletion of '{s}' (open_count={},blocks={})", .{ name, self.open_counts[idx], blocks_used });
        }

        // CRITICAL: Handle hard links with global nlink synchronization
        if (effective_nlink > 1 and !is_open) {
            // This file has other hard links - decrement nlink on ALL entries sharing start_block
            // Do NOT free blocks yet
            e.flags = 0;
            e.name = [_]u8{0} ** 32;

            // Write this block first to remove the unlinked entry
            sfs_io.writeSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;

            // Now scan ALL directory blocks to update siblings' nlink
            const new_nlink = effective_nlink - 1;
            var sibling_block_idx: u32 = 0;
            while (sibling_block_idx < t.ROOT_DIR_BLOCKS) : (sibling_block_idx += 1) {
                var sibling_buf: [512]u8 align(4) = [_]u8{0} ** 512;
                sfs_io.readSector(self, self.superblock.root_dir_start + sibling_block_idx, &sibling_buf) catch return vfs.Error.IOError;

                var modified = false;
                var entry_in_block: u32 = 0;
                while (entry_in_block < 4) : (entry_in_block += 1) {
                    const sibling_offset = entry_in_block * 128;
                    const sibling: *t.DirEntry = @ptrCast(@alignCast(&sibling_buf[sibling_offset]));

                    // Update any active entry with matching start_block
                    if (sibling.flags == 1 and sibling.start_block == target_start_block) {
                        sibling.nlink = new_nlink;
                        modified = true;
                    }
                }

                if (modified) {
                    sfs_io.writeSector(self, self.superblock.root_dir_start + sibling_block_idx, &sibling_buf) catch return vfs.Error.IOError;
                }
            }

            // Decrement file count (one entry removed)
            self.superblock.file_count = std.math.sub(u32, self.superblock.file_count, 1) catch 0;
            sfs_io.updateSuperblock(self) catch return vfs.Error.IOError;
        } else {
            // Last link or nlink==1 - standard deletion
            // Capture block info for freeing outside the lock
            if (!is_open) {
                free_start = e.start_block;
                free_count = blocks_used;
                needs_free = true;
            }

            // Clear directory entry while holding lock
            e.flags = 0;
            e.name = [_]u8{0} ** 32;
            if (!is_open) {
                e.start_block = 0;
                e.size = 0;
            }

            // Write directory update while holding lock
            sfs_io.writeSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;

            // Update superblock while holding lock
            self.superblock.file_count = std.math.sub(u32, self.superblock.file_count, 1) catch 0;
            sfs_io.updateSuperblock(self) catch return vfs.Error.IOError;
        }
    }

    // Free blocks OUTSIDE the lock -- freeBlock acquires alloc_lock internally
    if (needs_free) {
        sfs_alloc.freeBlocks(self, free_start, free_count);
    }

    console.info("SFS: Unlinked '{s}'", .{name});
}

pub fn sfsStatPath(ctx: ?*anyopaque, path: []const u8) ?vfs.FileMeta {
    const self: *t.SFS = @ptrCast(@alignCast(ctx));
    if (!self.mounted) return null;

    if (path.len == 0 or std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, ".")) {
        return vfs.FileMeta{
            .mode = meta.S_IFDIR | 0o755,
            .uid = 0,
            .gid = 0,
            .exists = true,
            .readonly = false,
        };
    }

    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;
    if (!sfs_alloc.isValidFilename(name)) return null;
    if (name.len == 0 or name.len >= 32) return null;

    // SECURITY: Allocate directory buffer on heap to prevent stack overflow
    const alloc = heap.allocator();
    const dir_buf = alloc.alloc(u8, t.ROOT_DIR_BLOCKS * 512) catch return null;
    defer alloc.free(dir_buf);
    sfs_io.readDirectoryAsync(self, dir_buf) catch return null;

    const total_entries = t.ROOT_DIR_BLOCKS * 4;
    var idx: u32 = 0;
    while (idx < total_entries) : (idx += 1) {
        const offset = idx * 128;
        const e: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset]));

        if (e.flags == 1) {
            const e_name = std.mem.sliceTo(&e.name, 0);
            if (e_name.len >= 32) continue;
            if (std.mem.eql(u8, e_name, name)) {
                return vfs.FileMeta{
                    .mode = e.mode,
                    .uid = e.uid,
                    .gid = e.gid,
                    .exists = true,
                    .readonly = false,
                    .size = e.size,
                    .mtime = @intCast(e.mtime),
                    .atime = @intCast(e.atime),
                };
            }
        }
    }

    return null;
}

pub fn sfsChmod(ctx: ?*anyopaque, path: []const u8, mode: u32) vfs.Error!void {
    const self: *t.SFS = @ptrCast(@alignCast(ctx));
    if (!self.mounted) return vfs.Error.IOError;

    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;
    if (!sfs_alloc.isValidFilename(name)) return vfs.Error.AccessDenied;
    if (name.len == 0 or name.len >= 32) return vfs.Error.NotFound;

    // PHASE 1: Read directory UNLOCKED to find entry
    const alloc = heap.allocator();
    const dir_buf = alloc.alloc(u8, t.ROOT_DIR_BLOCKS * 512) catch return vfs.Error.NoMemory;
    defer alloc.free(dir_buf);

    sfs_io.readDirectoryAsync(self, dir_buf) catch return vfs.Error.IOError;

    // PHASE 2: Find entry UNLOCKED
    var found_idx: ?u32 = null;
    const total_entries = t.ROOT_DIR_BLOCKS * 4;
    var idx: u32 = 0;
    while (idx < total_entries) : (idx += 1) {
        const offset = idx * 128;
        const e: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset]));

        if (e.flags == 1) {
            const e_name = std.mem.sliceTo(&e.name, 0);
            if (e_name.len >= 32) continue;
            if (std.mem.eql(u8, e_name, name)) {
                found_idx = idx;
                break;
            }
        }
    }

    const entry_idx = found_idx orelse return vfs.Error.NotFound;

    // PHASE 3: Calculate block location
    const block_idx = entry_idx / 4;
    const offset_in_block = std.math.mul(usize, entry_idx % 4, 128) catch return vfs.Error.IOError;

    // PHASE 4: Acquire lock, re-read, validate, modify in buffer, release lock
    var block_buf: [512]u8 align(4) = [_]u8{0} ** 512;
    {
        const held = self.alloc_lock.acquire();
        defer held.release();

        // Re-read specific block under lock (TOCTOU prevention)
        sfs_io.readSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;

        const e: *t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));

        // Validate entry still exists and has same name (TOCTOU check)
        if (e.flags != 1) {
            return vfs.Error.NotFound;
        }

        const e_name = std.mem.sliceTo(&e.name, 0);
        if (!std.mem.eql(u8, e_name, name)) {
            return vfs.Error.NotFound;
        }

        // Update mode in buffer
        const file_type = e.mode & 0o170000;
        e.mode = file_type | (mode & 0o7777);
    }

    // PHASE 5: Write block back OUTSIDE lock
    sfs_io.writeSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;
}

pub fn sfsChown(ctx: ?*anyopaque, path: []const u8, uid: ?u32, gid: ?u32) vfs.Error!void {
    const self: *t.SFS = @ptrCast(@alignCast(ctx));
    if (!self.mounted) return vfs.Error.IOError;

    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;
    if (!sfs_alloc.isValidFilename(name)) return vfs.Error.AccessDenied;
    if (name.len == 0 or name.len >= 32) return vfs.Error.NotFound;

    // PHASE 1: Read directory UNLOCKED to find entry
    const alloc = heap.allocator();
    const dir_buf = alloc.alloc(u8, t.ROOT_DIR_BLOCKS * 512) catch return vfs.Error.NoMemory;
    defer alloc.free(dir_buf);

    sfs_io.readDirectoryAsync(self, dir_buf) catch return vfs.Error.IOError;

    // PHASE 2: Find entry UNLOCKED
    var found_idx: ?u32 = null;
    const total_entries = t.ROOT_DIR_BLOCKS * 4;
    var idx: u32 = 0;
    while (idx < total_entries) : (idx += 1) {
        const offset = idx * 128;
        const e: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset]));

        if (e.flags == 1) {
            const e_name = std.mem.sliceTo(&e.name, 0);
            if (e_name.len >= 32) continue;
            if (std.mem.eql(u8, e_name, name)) {
                found_idx = idx;
                break;
            }
        }
    }

    const entry_idx = found_idx orelse return vfs.Error.NotFound;

    // PHASE 3: Calculate block location
    const block_idx = entry_idx / 4;
    const offset_in_block = std.math.mul(usize, entry_idx % 4, 128) catch return vfs.Error.IOError;

    // PHASE 4: Acquire lock, re-read, validate, modify in buffer, release lock
    var block_buf: [512]u8 align(4) = [_]u8{0} ** 512;
    {
        const held = self.alloc_lock.acquire();
        defer held.release();

        // Re-read specific block under lock (TOCTOU prevention)
        sfs_io.readSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;

        const e: *t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));

        // Validate entry still exists and has same name (TOCTOU check)
        if (e.flags != 1) {
            return vfs.Error.NotFound;
        }

        const e_name = std.mem.sliceTo(&e.name, 0);
        if (!std.mem.eql(u8, e_name, name)) {
            return vfs.Error.NotFound;
        }

        // Update ownership in buffer
        if (uid) |new_uid| e.uid = new_uid;
        if (gid) |new_gid| e.gid = new_gid;
    }

    // PHASE 5: Write block back OUTSIDE lock
    sfs_io.writeSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;
}

/// Create a directory in the SFS filesystem.
///
/// SECURITY NOTES:
/// - Validates path to reject nested paths (SFS is flat - no subdirectories)
/// - Uses TOCTOU prevention by holding alloc_lock during entire metadata update
/// - Uses checked arithmetic for all index calculations
/// - Directories are metadata-only (no block allocation needed)
///
/// SFS Directory Representation:
/// - mode = S_IFDIR | 0o755 (directory type + permissions)
/// - size = 0 (directories don't store data)
/// - start_block = 0 (sentinel - no block allocation)
/// - flags = 1 (active entry)
pub fn sfsMkdir(ctx: ?*anyopaque, path: []const u8, mode: u32) vfs.Error!void {
    const self: *t.SFS = @ptrCast(@alignCast(ctx));
    if (!self.mounted) return vfs.Error.IOError;

    // Extract name from path (strip leading '/')
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    // Validate filename: no nested paths, no path traversal
    if (!sfs_alloc.isValidFilename(name)) return vfs.Error.AccessDenied;

    // Check for nested paths (SFS is flat - no subdirectories)
    if (std.mem.indexOf(u8, name, "/")) |_| {
        return vfs.Error.NotSupported;
    }

    // Validate name length
    if (name.len == 0 or name.len >= 32) return vfs.Error.InvalidPath;

    // Reject root directory creation
    if (std.mem.eql(u8, name, ".")) return vfs.Error.InvalidPath;

    // PHASE 1: Read directory UNLOCKED to check conflicts and find free slot
    const alloc = heap.allocator();
    const dir_buf = alloc.alloc(u8, t.ROOT_DIR_BLOCKS * 512) catch return vfs.Error.NoMemory;
    defer alloc.free(dir_buf);

    sfs_io.readDirectoryAsync(self, dir_buf) catch return vfs.Error.IOError;

    // PHASE 2: Scan for conflicts and find free slot UNLOCKED
    var free_slot: ?u32 = null;
    const total_entries = t.ROOT_DIR_BLOCKS * 4;
    const total_entries_checked = @min(total_entries, t.MAX_FILES);

    var idx: u32 = 0;
    while (idx < total_entries_checked) : (idx += 1) {
        const offset = std.math.mul(usize, idx, 128) catch {
            console.err("SFS: Integer overflow in mkdir offset calculation", .{});
            return vfs.Error.IOError;
        };

        const e: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset]));

        if (e.flags == 1) {
            const e_name = std.mem.sliceTo(&e.name, 0);
            if (e_name.len >= 32) continue;
            if (std.mem.eql(u8, e_name, name)) {
                return vfs.Error.AlreadyExists;
            }
        } else if (free_slot == null) {
            free_slot = idx;
        }
    }

    const new_idx = free_slot orelse {
        return vfs.Error.NoMemory;
    };

    // PHASE 3: Build directory entry
    const dir_mode = meta.S_IFDIR | (mode & 0o7777);
    var new_entry = t.DirEntry{
        .name = [_]u8{0} ** 32,
        .start_block = 0, // Directories don't own blocks
        .size = 0, // Directories have no size
        .flags = 1, // Active entry
        .mode = dir_mode,
        .uid = 0,
        .gid = 0,
        .mtime = 0,
        .atime = 0,
        .nlink = 1,
        ._pad = [_]u8{0} ** (128 - 68),
    };
    @memcpy(new_entry.name[0..name.len], name);

    // PHASE 4: Calculate block location
    const block_idx = new_idx / 4;
    const offset_in_block = std.math.mul(usize, new_idx % 4, 128) catch {
        return vfs.Error.IOError;
    };

    const dir_block = std.math.add(u32, self.superblock.root_dir_start, block_idx) catch {
        return vfs.Error.IOError;
    };

    // PHASE 5: Acquire lock, re-read, validate, modify in buffer, update counter, release lock
    var block_buf: [512]u8 align(4) = [_]u8{0} ** 512;
    {
        const held = self.alloc_lock.acquire();
        defer held.release();

        // Check file count limit under lock
        if (self.superblock.file_count >= t.MAX_FILES) {
            return vfs.Error.NoMemory;
        }

        // Re-read specific block under lock (TOCTOU prevention)
        sfs_io.readSector(self, dir_block, &block_buf) catch {
            return vfs.Error.IOError;
        };

        // Validate slot is still free (TOCTOU check)
        const verify_entry: *const t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));
        if (verify_entry.flags != 0) {
            return vfs.Error.NoMemory; // Slot taken by another thread
        }

        // Re-check for name conflicts in this block
        for (0..4) |i| {
            const check_offset = i * 128;
            const check_entry: *const t.DirEntry = @ptrCast(@alignCast(&block_buf[check_offset]));
            if (check_entry.flags == 1) {
                const check_name = std.mem.sliceTo(&check_entry.name, 0);
                if (std.mem.eql(u8, check_name, name)) {
                    return vfs.Error.AlreadyExists;
                }
            }
        }

        // Write new entry to buffer
        const dest: *t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));
        dest.* = new_entry;

        // Update superblock file count in memory
        self.superblock.file_count = std.math.add(u32, self.superblock.file_count, 1) catch {
            console.err("SFS: Integer overflow in file_count increment", .{});
            return vfs.Error.IOError;
        };
    }

    // PHASE 6: Write directory block OUTSIDE lock
    sfs_io.writeSector(self, dir_block, &block_buf) catch |err| {
        // Rollback file_count on write failure
        const held = self.alloc_lock.acquire();
        defer held.release();
        self.superblock.file_count -= 1;
        return err;
    };

    // PHASE 7: Write superblock OUTSIDE lock
    sfs_io.updateSuperblock(self) catch |err| {
        // Rollback on superblock write failure (directory already written - partial state)
        const held = self.alloc_lock.acquire();
        defer held.release();
        self.superblock.file_count -= 1;
        return err;
    };

    console.info("SFS: Created directory '{s}' at slot {}", .{ name, new_idx });
}

/// Remove a directory from the SFS filesystem.
///
/// SECURITY NOTES:
/// - TOCTOU Prevention: Re-reads directory entry under lock to prevent race conditions
/// - Directory Verification: Uses isDirectory() method to ensure entry is a directory type
/// - Open Directory Protection: Checks open_counts to prevent removing directories with active FDs
/// - Integer Safety: Uses checked arithmetic for all offset calculations
///
/// Error Codes:
/// - NotFound: Directory does not exist
/// - NotDirectory: Entry exists but is a regular file
/// - Busy: Directory is currently open (has active file descriptors)
/// - IOError: Disk read/write failure
pub fn sfsRmdir(ctx: ?*anyopaque, path: []const u8) vfs.Error!void {
    const self: *t.SFS = @ptrCast(@alignCast(ctx));
    if (!self.mounted) return vfs.Error.IOError;

    // Extract name, stripping leading slash
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    // Validate filename - reject invalid characters and nested paths
    if (!sfs_alloc.isValidFilename(name)) return vfs.Error.AccessDenied;

    // Reject empty names and names that are too long
    if (name.len == 0 or name.len >= 32) return vfs.Error.NotFound;

    // Cannot remove root directory
    if (std.mem.eql(u8, name, ".")) return vfs.Error.AccessDenied;

    // SECURITY: Allocate directory buffer on heap to prevent stack overflow
    const alloc = heap.allocator();
    const dir_buf_search = alloc.alloc(u8, t.ROOT_DIR_BLOCKS * 512) catch return vfs.Error.NoMemory;
    defer alloc.free(dir_buf_search);

    // SECURITY: First pass - find entry index unlocked for efficiency
    var found_idx: ?u32 = null;
    {
        sfs_io.readDirectoryAsync(self, dir_buf_search) catch return vfs.Error.IOError;

        const total_entries = t.ROOT_DIR_BLOCKS * 4;
        var idx: u32 = 0;
        while (idx < total_entries) : (idx += 1) {
            // SECURITY: Use checked arithmetic for offset calculation
            const offset = std.math.mul(usize, idx, 128) catch return vfs.Error.IOError;
            const e: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf_search[offset]));

            if (e.flags == 1) {
                const e_name = std.mem.sliceTo(&e.name, 0);
                if (e_name.len >= 32) continue;
                if (std.mem.eql(u8, e_name, name)) {
                    found_idx = idx;
                    break;
                }
            }
        }
    }

    const idx = found_idx orelse return vfs.Error.NotFound;

    // Calculate block location
    const block_idx = idx / 4;
    const offset_in_block = std.math.mul(usize, idx % 4, 128) catch return vfs.Error.IOError;

    // Acquire lock, re-read, validate, modify in buffer, update counter, release lock
    var block_buf: [512]u8 align(4) = [_]u8{0} ** 512;
    {
        const lock_held = self.alloc_lock.acquire();
        defer lock_held.release();

        // Re-read the specific directory block under lock (TOCTOU prevention)
        sfs_io.readSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;

        const e: *t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));

        // SECURITY: Re-validate entry under lock - check it still exists and has the same name
        if (e.flags != 1) {
            return vfs.Error.NotFound;
        }

        const e_name = std.mem.sliceTo(&e.name, 0);
        if (!std.mem.eql(u8, e_name, name)) {
            // Entry was replaced with a different file - race condition detected
            return vfs.Error.NotFound;
        }

        // SECURITY: Verify entry is a directory, not a regular file
        if (!e.isDirectory()) {
            return vfs.Error.NotDirectory;
        }

        // SECURITY: Check if directory is currently open
        // Validate index bounds before accessing open_counts array
        if (idx >= t.MAX_FILES) {
            return vfs.Error.IOError;
        }

        if (self.open_counts[idx] > 0) {
            // Directory has active file descriptors - cannot remove
            return vfs.Error.Busy;
        }

        // NOTE: For SFS (flat filesystem), directories don't own data blocks
        // They are metadata-only entries (size=0, start_block=0)
        // No block deallocation needed unlike sfsUnlink for files

        // Clear directory entry in buffer
        e.flags = 0;
        e.name = [_]u8{0} ** 32;
        e.start_block = 0;
        e.size = 0;
        e.mode = 0;

        // Update superblock file count in memory
        self.superblock.file_count = std.math.sub(u32, self.superblock.file_count, 1) catch 0;
    }

    // Write updated directory block OUTSIDE lock
    sfs_io.writeSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch |err| {
        // Rollback file_count on write failure
        const held = self.alloc_lock.acquire();
        defer held.release();
        self.superblock.file_count = std.math.add(u32, self.superblock.file_count, 1) catch std.math.maxInt(u32);
        return err;
    };

    // Write superblock OUTSIDE lock
    sfs_io.updateSuperblock(self) catch |err| {
        // Rollback on superblock write failure (directory already cleared - partial state)
        const held = self.alloc_lock.acquire();
        defer held.release();
        self.superblock.file_count = std.math.add(u32, self.superblock.file_count, 1) catch std.math.maxInt(u32);
        return err;
    };

    console.info("SFS: Removed directory '{s}'", .{name});
}

/// Create a hard link to an existing file on SFS
/// SECURITY: TOCTOU-safe via multi-phase lock pattern
/// CRITICAL: Global nlink synchronization - ALL entries sharing start_block get same nlink value
pub fn sfsLink(ctx: ?*anyopaque, old_path: []const u8, new_path: []const u8) vfs.Error!void {
    const self: *t.SFS = @ptrCast(@alignCast(ctx));
    if (!self.mounted) return vfs.Error.IOError;

    // Extract names from paths (strip leading '/')
    const old_name = if (old_path.len > 0 and old_path[0] == '/') old_path[1..] else old_path;
    const new_name = if (new_path.len > 0 and new_path[0] == '/') new_path[1..] else new_path;

    // Validate both filenames
    if (!sfs_alloc.isValidFilename(old_name)) return vfs.Error.AccessDenied;
    if (!sfs_alloc.isValidFilename(new_name)) return vfs.Error.AccessDenied;
    if (old_name.len == 0 or old_name.len >= 32) return vfs.Error.NotFound;
    if (new_name.len == 0 or new_name.len >= 32) return vfs.Error.InvalidPath;

    // Reject nested paths (SFS is flat)
    if (std.mem.indexOf(u8, old_name, "/")) |_| return vfs.Error.InvalidPath;
    if (std.mem.indexOf(u8, new_name, "/")) |_| return vfs.Error.InvalidPath;

    // SECURITY: Allocate directory buffer on heap to prevent stack overflow
    const alloc = heap.allocator();
    const dir_buf = alloc.alloc(u8, t.ROOT_DIR_BLOCKS * 512) catch return vfs.Error.NoMemory;
    defer alloc.free(dir_buf);

    // PHASE 1: Read directory UNLOCKED to find old entry and check conflicts
    var old_idx: ?u32 = null;
    var free_slot: ?u32 = null;
    var old_entry: t.DirEntry = undefined;
    {
        sfs_io.readDirectoryAsync(self, dir_buf) catch return vfs.Error.IOError;

        const total_entries = t.ROOT_DIR_BLOCKS * 4;
        var idx: u32 = 0;
        while (idx < total_entries) : (idx += 1) {
            const offset = std.math.mul(usize, idx, 128) catch return vfs.Error.IOError;
            const e: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset]));

            if (e.flags == 1) {
                const e_name = std.mem.sliceTo(&e.name, 0);
                if (e_name.len >= 32) continue;
                if (std.mem.eql(u8, e_name, old_name)) {
                    old_idx = idx;
                    old_entry = e.*;
                }
                if (std.mem.eql(u8, e_name, new_name)) {
                    return vfs.Error.AlreadyExists;
                }
            } else if (free_slot == null) {
                free_slot = idx;
            }
        }
    }

    const old_entry_idx = old_idx orelse return vfs.Error.NotFound;
    const new_idx = free_slot orelse return vfs.Error.NoMemory;

    // PHASE 2: Verify old entry is a regular file (not directory or symlink)
    if (!old_entry.isRegularFile()) {
        return vfs.Error.AccessDenied; // POSIX: EPERM for hard links to directories
    }
    if (old_entry.isSymlink()) {
        return vfs.Error.AccessDenied; // Simplification: reject hard links to symlinks
    }

    // PHASE 3: Calculate block locations
    const old_block_idx = old_entry_idx / 4;
    const old_offset_in_block = std.math.mul(usize, old_entry_idx % 4, 128) catch return vfs.Error.IOError;
    const new_block_idx = new_idx / 4;
    const new_offset_in_block = std.math.mul(usize, new_idx % 4, 128) catch return vfs.Error.IOError;

    // PHASE 4: Under lock - create link with global nlink synchronization
    var old_block_buf: [512]u8 align(4) = [_]u8{0} ** 512;
    var new_block_buf: [512]u8 align(4) = [_]u8{0} ** 512;
    const same_block = (old_block_idx == new_block_idx);
    {
        const lock_held = self.alloc_lock.acquire();
        defer lock_held.release();

        // Check file count limit
        if (self.superblock.file_count >= t.MAX_FILES) {
            return vfs.Error.NoMemory;
        }

        // Re-read old entry's block under lock (TOCTOU prevention)
        sfs_io.readSector(self, self.superblock.root_dir_start + old_block_idx, &old_block_buf) catch return vfs.Error.IOError;

        const old_e: *const t.DirEntry = @ptrCast(@alignCast(&old_block_buf[old_offset_in_block]));

        // Re-validate old entry under lock
        if (old_e.flags != 1) {
            return vfs.Error.NotFound;
        }
        const old_e_name = std.mem.sliceTo(&old_e.name, 0);
        if (!std.mem.eql(u8, old_e_name, old_name)) {
            return vfs.Error.NotFound;
        }

        // Re-read new entry's block if different
        if (same_block) {
            @memcpy(&new_block_buf, &old_block_buf);
        } else {
            sfs_io.readSector(self, self.superblock.root_dir_start + new_block_idx, &new_block_buf) catch return vfs.Error.IOError;
        }

        // Re-check new name doesn't exist
        const new_e_check: *const t.DirEntry = @ptrCast(@alignCast(&new_block_buf[new_offset_in_block]));
        if (new_e_check.flags != 0) {
            return vfs.Error.AlreadyExists;
        }

        // Compute new nlink value
        const old_nlink = if (old_e.nlink == 0) @as(u32, 1) else old_e.nlink;
        const new_nlink = old_nlink + 1;

        // Create new directory entry (hard link)
        var new_entry = t.DirEntry{
            .name = [_]u8{0} ** 32,
            .start_block = old_e.start_block,
            .size = old_e.size,
            .flags = 1,
            .mode = old_e.mode,
            .uid = old_e.uid,
            .gid = old_e.gid,
            .mtime = old_e.mtime,
            .atime = old_e.atime,
            .nlink = new_nlink,
            ._pad = [_]u8{0} ** (128 - 68),
        };
        @memcpy(new_entry.name[0..new_name.len], new_name);

        // Write new entry to buffer
        const new_e: *t.DirEntry = @ptrCast(@alignCast(&new_block_buf[new_offset_in_block]));
        new_e.* = new_entry;

        // When old and new entries share the same block, sync new_block_buf back
        // to old_block_buf so the nlink sync loop sees both entries
        if (same_block) {
            @memcpy(&old_block_buf, &new_block_buf);
        }

        // CRITICAL: Global nlink synchronization
        // Update nlink on ALL entries sharing the same start_block
        var sibling_block_idx: u32 = 0;
        while (sibling_block_idx < t.ROOT_DIR_BLOCKS) : (sibling_block_idx += 1) {
            var sibling_buf: [512]u8 align(4) = [_]u8{0} ** 512;

            // Avoid re-reading blocks we already have in memory
            if (sibling_block_idx == old_block_idx) {
                @memcpy(&sibling_buf, &old_block_buf);
            } else if (sibling_block_idx == new_block_idx) {
                @memcpy(&sibling_buf, &new_block_buf);
            } else {
                sfs_io.readSector(self, self.superblock.root_dir_start + sibling_block_idx, &sibling_buf) catch return vfs.Error.IOError;
            }

            var modified = false;
            var entry_in_block: u32 = 0;
            while (entry_in_block < 4) : (entry_in_block += 1) {
                const sibling_offset = entry_in_block * 128;
                const sibling: *t.DirEntry = @ptrCast(@alignCast(&sibling_buf[sibling_offset]));

                // Update any active entry with matching start_block
                if (sibling.flags == 1 and sibling.start_block == old_e.start_block) {
                    sibling.nlink = new_nlink;
                    modified = true;
                }
            }

            if (modified) {
                // Write back outside lock (done in PHASE 5)
                // But update our in-memory copies
                if (sibling_block_idx == old_block_idx) {
                    @memcpy(&old_block_buf, &sibling_buf);
                } else if (sibling_block_idx == new_block_idx) {
                    @memcpy(&new_block_buf, &sibling_buf);
                }
            }
        }

        // Increment file count in memory
        self.superblock.file_count += 1;
    }

    // PHASE 5: Write all modified blocks OUTSIDE lock
    sfs_io.writeSector(self, self.superblock.root_dir_start + old_block_idx, &old_block_buf) catch |err| {
        // Rollback file_count
        const held = self.alloc_lock.acquire();
        defer held.release();
        self.superblock.file_count -= 1;
        return err;
    };

    if (!same_block) {
        sfs_io.writeSector(self, self.superblock.root_dir_start + new_block_idx, &new_block_buf) catch |err| {
            // Partial failure - old block written with updated nlink, but new entry not created
            // This is technically inconsistent but recoverable
            const held = self.alloc_lock.acquire();
            defer held.release();
            self.superblock.file_count -= 1;
            return err;
        };
    }

    // Now write all other blocks with updated nlink
    var sibling_block_idx: u32 = 0;
    while (sibling_block_idx < t.ROOT_DIR_BLOCKS) : (sibling_block_idx += 1) {
        if (sibling_block_idx == old_block_idx or sibling_block_idx == new_block_idx) {
            continue; // Already written
        }

        var sibling_buf: [512]u8 align(4) = [_]u8{0} ** 512;
        sfs_io.readSector(self, self.superblock.root_dir_start + sibling_block_idx, &sibling_buf) catch continue;

        var modified = false;
        var entry_in_block: u32 = 0;
        while (entry_in_block < 4) : (entry_in_block += 1) {
            const sibling_offset = entry_in_block * 128;
            const sibling: *t.DirEntry = @ptrCast(@alignCast(&sibling_buf[sibling_offset]));

            if (sibling.flags == 1 and sibling.start_block == old_entry.start_block) {
                const old_nlink = if (old_entry.nlink == 0) @as(u32, 1) else old_entry.nlink;
                sibling.nlink = old_nlink + 1;
                modified = true;
            }
        }

        if (modified) {
            sfs_io.writeSector(self, self.superblock.root_dir_start + sibling_block_idx, &sibling_buf) catch {};
        }
    }

    // PHASE 6: Write superblock OUTSIDE lock
    sfs_io.updateSuperblock(self) catch |err| {
        // Rollback on failure
        const held = self.alloc_lock.acquire();
        defer held.release();
        self.superblock.file_count -= 1;
        return err;
    };

    console.info("SFS: Created hard link '{s}' -> '{s}'", .{ new_name, old_name });
}

pub fn sfsRename(ctx: ?*anyopaque, old_path: []const u8, new_path: []const u8) vfs.Error!void {
    const self: *t.SFS = @ptrCast(@alignCast(ctx));
    if (!self.mounted) return vfs.Error.IOError;

    // Extract names from paths (strip leading '/')
    const old_name = if (old_path.len > 0 and old_path[0] == '/') old_path[1..] else old_path;
    const new_name = if (new_path.len > 0 and new_path[0] == '/') new_path[1..] else new_path;

    // Validate both filenames
    if (!sfs_alloc.isValidFilename(old_name)) return vfs.Error.AccessDenied;
    if (!sfs_alloc.isValidFilename(new_name)) return vfs.Error.AccessDenied;
    if (old_name.len == 0 or old_name.len >= 32) return vfs.Error.NotFound;
    if (new_name.len == 0 or new_name.len >= 32) return vfs.Error.InvalidPath;

    // If same name, no-op (success)
    if (std.mem.eql(u8, old_name, new_name)) return;

    // SECURITY: Allocate directory buffer on heap to prevent stack overflow
    const alloc = heap.allocator();
    const dir_buf = alloc.alloc(u8, t.ROOT_DIR_BLOCKS * 512) catch return vfs.Error.NoMemory;
    defer alloc.free(dir_buf);

    // PHASE 1: Read directory UNLOCKED to find old entry and check if new name exists
    var old_idx: ?u32 = null;
    var new_idx: ?u32 = null;
    {
        sfs_io.readDirectoryAsync(self, dir_buf) catch return vfs.Error.IOError;

        const total_entries = t.ROOT_DIR_BLOCKS * 4;
        var idx: u32 = 0;
        while (idx < total_entries) : (idx += 1) {
            const offset = std.math.mul(usize, idx, 128) catch return vfs.Error.IOError;
            const e: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset]));

            if (e.flags == 1) {
                const e_name = std.mem.sliceTo(&e.name, 0);
                if (e_name.len >= 32) continue;
                if (std.mem.eql(u8, e_name, old_name)) {
                    old_idx = idx;
                }
                if (std.mem.eql(u8, e_name, new_name)) {
                    new_idx = idx;
                }
            }
        }
    }

    const old_entry_idx = old_idx orelse return vfs.Error.NotFound;

    // Calculate block locations
    const old_block_idx = old_entry_idx / 4;
    const old_offset_in_block = std.math.mul(usize, old_entry_idx % 4, 128) catch return vfs.Error.IOError;

    // PHASE 2: Under lock - handle rename
    var old_block_buf: [512]u8 align(4) = [_]u8{0} ** 512;
    var new_block_buf: [512]u8 align(4) = [_]u8{0} ** 512;
    var new_entry_to_delete: ?struct { idx: u32, start_block: u32, block_count: u32, is_dir: bool } = null;
    var same_block = false;

    {
        const lock_held = self.alloc_lock.acquire();
        defer lock_held.release();

        // Re-read old entry's block under lock (TOCTOU prevention)
        sfs_io.readSector(self, self.superblock.root_dir_start + old_block_idx, &old_block_buf) catch return vfs.Error.IOError;

        const old_e: *t.DirEntry = @ptrCast(@alignCast(&old_block_buf[old_offset_in_block]));

        // Re-validate old entry under lock
        if (old_e.flags != 1) {
            return vfs.Error.NotFound;
        }
        const old_e_name = std.mem.sliceTo(&old_e.name, 0);
        if (!std.mem.eql(u8, old_e_name, old_name)) {
            return vfs.Error.NotFound;
        }

        // If new_name exists, we need to delete it first (POSIX rename semantics)
        if (new_idx) |new_entry_idx| {
            const new_block_idx = new_entry_idx / 4;
            const new_offset_in_block = std.math.mul(usize, new_entry_idx % 4, 128) catch return vfs.Error.IOError;

            // Check if old and new entries are in the same block
            same_block = (old_block_idx == new_block_idx);

            // Read new entry's block (might be same as old_block_buf)
            if (same_block) {
                @memcpy(&new_block_buf, &old_block_buf);
            } else {
                sfs_io.readSector(self, self.superblock.root_dir_start + new_block_idx, &new_block_buf) catch return vfs.Error.IOError;
            }

            const new_e: *t.DirEntry = @ptrCast(@alignCast(&new_block_buf[new_offset_in_block]));

            // Validate new entry exists
            if (new_e.flags != 1) {
                // Entry disappeared - proceed with simple rename
            } else {
                // POSIX: Cannot rename over a directory with rename()
                if (new_e.isDirectory()) {
                    return vfs.Error.IsDirectory;
                }

                // Mark new entry for deletion
                const blocks_used: u32 = if (new_e.size == 0) 1 else (new_e.size + 511) / 512;

                // Check if new entry is open
                var is_open = false;
                if (self.open_counts[new_entry_idx] > 0) {
                    is_open = true;
                    self.pending_delete[new_entry_idx] = true;
                    self.deferred_info[new_entry_idx] = .{
                        .start_block = new_e.start_block,
                        .block_count = blocks_used,
                    };
                }

                // Save info for freeing outside lock
                if (!is_open) {
                    new_entry_to_delete = .{
                        .idx = new_entry_idx,
                        .start_block = new_e.start_block,
                        .block_count = blocks_used,
                        .is_dir = false,
                    };
                }

                // Clear the new entry in buffer
                new_e.flags = 0;
                new_e.name = [_]u8{0} ** 32;
                if (!is_open) {
                    new_e.start_block = 0;
                    new_e.size = 0;
                }

                // Update file count (one file deleted)
                self.superblock.file_count = std.math.sub(u32, self.superblock.file_count, 1) catch 0;
            }
        }

        // Now rename old entry by changing its name.
        // If same_block and new_idx != null, new_e's modifications were made on
        // new_block_buf (a separate copy). We must merge those changes into
        // old_block_buf first, THEN apply the rename on old_block_buf so it
        // doesn't get reverted.
        if (same_block and new_idx != null) {
            // Copy the cleared new_entry from new_block_buf into old_block_buf
            const new_offset = (new_idx.? % 4) * 128;
            @memcpy(old_block_buf[new_offset..][0..128], new_block_buf[new_offset..][0..128]);
        }

        old_e.name = [_]u8{0} ** 32;
        @memcpy(old_e.name[0..new_name.len], new_name);
    }

    // PHASE 3: Write blocks OUTSIDE lock
    sfs_io.writeSector(self, self.superblock.root_dir_start + old_block_idx, &old_block_buf) catch |err| {
        // Rollback on write failure
        const held = self.alloc_lock.acquire();
        defer held.release();
        if (new_entry_to_delete != null or (new_idx != null and !same_block)) {
            self.superblock.file_count = std.math.add(u32, self.superblock.file_count, 1) catch std.math.maxInt(u32);
        }
        return err;
    };

    // If new entry was in a different block, write that block too
    if (new_idx != null and !same_block) {
        const new_entry_idx = new_idx.?;
        const new_block_idx = new_entry_idx / 4;
        sfs_io.writeSector(self, self.superblock.root_dir_start + new_block_idx, &new_block_buf) catch |err| {
            // Partial failure - directory blocks inconsistent
            // Old entry renamed, but new entry not deleted
            return err;
        };
    }

    // Write superblock if file count changed
    if (new_entry_to_delete != null or new_idx != null) {
        sfs_io.updateSuperblock(self) catch |err| {
            const held = self.alloc_lock.acquire();
            defer held.release();
            if (new_entry_to_delete != null or new_idx != null) {
                self.superblock.file_count = std.math.add(u32, self.superblock.file_count, 1) catch std.math.maxInt(u32);
            }
            return err;
        };
    }

    // PHASE 4: Free blocks of deleted entry OUTSIDE lock (if not open)
    if (new_entry_to_delete) |del| {
        sfs_alloc.freeBlocks(self, del.start_block, del.block_count);
    }

}

/// Rename a file with flags (RENAME_NOREPLACE, RENAME_EXCHANGE)
pub fn sfsRename2(ctx: ?*anyopaque, old_path: []const u8, new_path: []const u8, flags: u32) vfs.Error!void {
    const self: *t.SFS = @ptrCast(@alignCast(ctx));
    if (!self.mounted) return vfs.Error.IOError;

    // Define flag constants
    const RENAME_NOREPLACE: u32 = 1;
    const RENAME_EXCHANGE: u32 = 2;

    // Extract names from paths (strip leading '/')
    const old_name = if (old_path.len > 0 and old_path[0] == '/') old_path[1..] else old_path;
    const new_name = if (new_path.len > 0 and new_path[0] == '/') new_path[1..] else new_path;

    // Validate both filenames
    if (!sfs_alloc.isValidFilename(old_name)) return vfs.Error.AccessDenied;
    if (!sfs_alloc.isValidFilename(new_name)) return vfs.Error.AccessDenied;
    if (old_name.len == 0 or old_name.len >= 32) return vfs.Error.NotFound;
    if (new_name.len == 0 or new_name.len >= 32) return vfs.Error.InvalidPath;

    // If same name, no-op (success)
    if (std.mem.eql(u8, old_name, new_name)) return;

    // Flags == 0: Delegate to standard rename
    if (flags == 0) {
        return sfsRename(ctx, old_path, new_path);
    }

    // Unsupported flag combinations
    if (flags & ~(RENAME_NOREPLACE | RENAME_EXCHANGE) != 0) {
        return vfs.Error.NotSupported;
    }

    const alloc = heap.allocator();
    const dir_buf = alloc.alloc(u8, t.ROOT_DIR_BLOCKS * 512) catch return vfs.Error.NoMemory;
    defer alloc.free(dir_buf);

    // PHASE 1: Read directory UNLOCKED to find both entries
    var old_idx: ?u32 = null;
    var new_idx: ?u32 = null;
    {
        sfs_io.readDirectoryAsync(self, dir_buf) catch return vfs.Error.IOError;

        const total_entries = t.ROOT_DIR_BLOCKS * 4;
        var idx: u32 = 0;
        while (idx < total_entries) : (idx += 1) {
            const offset = std.math.mul(usize, idx, 128) catch return vfs.Error.IOError;
            const e: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset]));

            if (e.flags == 1) {
                const e_name = std.mem.sliceTo(&e.name, 0);
                if (e_name.len >= 32) continue;
                if (std.mem.eql(u8, e_name, old_name)) {
                    old_idx = idx;
                }
                if (std.mem.eql(u8, e_name, new_name)) {
                    new_idx = idx;
                }
            }
        }
    }

    const old_entry_idx = old_idx orelse return vfs.Error.NotFound;

    // RENAME_NOREPLACE: Fail if new name exists
    if (flags & RENAME_NOREPLACE != 0) {
        if (new_idx != null) {
            return vfs.Error.AlreadyExists;
        }
        // No existing new entry, proceed with simple rename
        return sfsRename(ctx, old_path, new_path);
    }

    // RENAME_EXCHANGE: Swap the names of two files
    if (flags & RENAME_EXCHANGE != 0) {
        const new_entry_idx = new_idx orelse return vfs.Error.NotFound;

        // Calculate block locations
        const old_block_idx = old_entry_idx / 4;
        const old_offset_in_block = std.math.mul(usize, old_entry_idx % 4, 128) catch return vfs.Error.IOError;
        const new_block_idx = new_entry_idx / 4;
        const new_offset_in_block = std.math.mul(usize, new_entry_idx % 4, 128) catch return vfs.Error.IOError;

        const same_block = (old_block_idx == new_block_idx);

        var old_block_buf: [512]u8 align(4) = [_]u8{0} ** 512;
        var new_block_buf: [512]u8 align(4) = [_]u8{0} ** 512;

        // PHASE 2: Under lock - swap names
        {
            const lock_held = self.alloc_lock.acquire();
            defer lock_held.release();

            // Re-read blocks under lock (TOCTOU prevention)
            sfs_io.readSector(self, self.superblock.root_dir_start + old_block_idx, &old_block_buf) catch return vfs.Error.IOError;

            if (same_block) {
                // Both entries in same sector: use single buffer for both pointers
                const old_e: *t.DirEntry = @ptrCast(@alignCast(&old_block_buf[old_offset_in_block]));
                const new_e: *t.DirEntry = @ptrCast(@alignCast(&old_block_buf[new_offset_in_block]));

                if (old_e.flags != 1) return vfs.Error.NotFound;
                if (new_e.flags != 1) return vfs.Error.NotFound;

                const old_e_name = std.mem.sliceTo(&old_e.name, 0);
                const new_e_name = std.mem.sliceTo(&new_e.name, 0);
                if (!std.mem.eql(u8, old_e_name, old_name)) return vfs.Error.NotFound;
                if (!std.mem.eql(u8, new_e_name, new_name)) return vfs.Error.NotFound;

                const temp_name: [32]u8 = old_e.name;
                old_e.name = new_e.name;
                new_e.name = temp_name;
            } else {
                // Different sectors: swap across two buffers
                sfs_io.readSector(self, self.superblock.root_dir_start + new_block_idx, &new_block_buf) catch return vfs.Error.IOError;

                const old_e: *t.DirEntry = @ptrCast(@alignCast(&old_block_buf[old_offset_in_block]));
                const new_e: *t.DirEntry = @ptrCast(@alignCast(&new_block_buf[new_offset_in_block]));

                if (old_e.flags != 1) return vfs.Error.NotFound;
                if (new_e.flags != 1) return vfs.Error.NotFound;

                const old_e_name = std.mem.sliceTo(&old_e.name, 0);
                const new_e_name = std.mem.sliceTo(&new_e.name, 0);
                if (!std.mem.eql(u8, old_e_name, old_name)) return vfs.Error.NotFound;
                if (!std.mem.eql(u8, new_e_name, new_name)) return vfs.Error.NotFound;

                const temp_name: [32]u8 = old_e.name;
                old_e.name = new_e.name;
                new_e.name = temp_name;
            }
        }

        // PHASE 3: Write blocks OUTSIDE lock
        sfs_io.writeSector(self, self.superblock.root_dir_start + old_block_idx, &old_block_buf) catch return vfs.Error.IOError;

        if (!same_block) {
            sfs_io.writeSector(self, self.superblock.root_dir_start + new_block_idx, &new_block_buf) catch return vfs.Error.IOError;
        }

        console.info("SFS: Exchanged '{s}' <-> '{s}'", .{ old_name, new_name });
        return;
    }

    // Should not reach here
    return vfs.Error.NotSupported;
}

/// Set file timestamps (atime and mtime) on SFS files
/// SECURITY: TOCTOU-safe via lock-held re-read pattern
/// Note: SFS stores timestamps as u32 Unix seconds, nanosecond precision is lost
pub fn sfsSetTimestamps(ctx: ?*anyopaque, path: []const u8, atime_sec: i64, atime_nsec: i64, mtime_sec: i64, mtime_nsec: i64) vfs.Error!void {
    _ = atime_nsec; // Not stored in SFS (u32 seconds only)
    _ = mtime_nsec; // Not stored in SFS (u32 seconds only)

    const self: *t.SFS = @ptrCast(@alignCast(ctx));
    if (!self.mounted) return vfs.Error.IOError;

    // Extract name from path (strip leading '/')
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    // Validate filename
    if (!sfs_alloc.isValidFilename(name)) return vfs.Error.AccessDenied;
    if (name.len == 0 or name.len >= 32) return vfs.Error.NotFound;

    // PHASE 1: Read directory UNLOCKED to find entry
    const alloc = heap.allocator();
    const dir_buf = alloc.alloc(u8, t.ROOT_DIR_BLOCKS * 512) catch return vfs.Error.NoMemory;
    defer alloc.free(dir_buf);

    sfs_io.readDirectoryAsync(self, dir_buf) catch return vfs.Error.IOError;

    // PHASE 2: Find entry UNLOCKED
    var found_idx: ?u32 = null;
    const total_entries = t.ROOT_DIR_BLOCKS * 4;
    var idx: u32 = 0;
    while (idx < total_entries) : (idx += 1) {
        const offset = std.math.mul(usize, idx, 128) catch return vfs.Error.IOError;
        const e: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset]));

        if (e.flags == 1) {
            const e_name = std.mem.sliceTo(&e.name, 0);
            if (e_name.len >= 32) continue;
            if (std.mem.eql(u8, e_name, name)) {
                found_idx = idx;
                break;
            }
        }
    }

    const entry_idx = found_idx orelse return vfs.Error.NotFound;

    // PHASE 3: Calculate block location
    const block_idx = entry_idx / 4;
    const offset_in_block = std.math.mul(usize, entry_idx % 4, 128) catch return vfs.Error.IOError;

    // PHASE 4: Acquire lock, re-read, validate, modify in buffer, release lock
    var block_buf: [512]u8 align(4) = [_]u8{0} ** 512;
    {
        const held = self.alloc_lock.acquire();
        defer held.release();

        // Re-read specific block under lock (TOCTOU prevention)
        sfs_io.readSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;

        const e: *t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));

        // Validate entry still exists and has same name (TOCTOU check)
        if (e.flags != 1) {
            return vfs.Error.NotFound;
        }

        const e_name = std.mem.sliceTo(&e.name, 0);
        if (!std.mem.eql(u8, e_name, name)) {
            return vfs.Error.NotFound;
        }

        // Update timestamps in buffer
        // -1 means UTIME_OMIT (leave unchanged)
        if (atime_sec != -1) {
            const atime_u32: u32 = @truncate(@as(u64, @bitCast(atime_sec)));
            e.atime = atime_u32;
        }
        if (mtime_sec != -1) {
            const mtime_u32: u32 = @truncate(@as(u64, @bitCast(mtime_sec)));
            e.mtime = mtime_u32;
        }
    }

    // PHASE 5: Write block back OUTSIDE lock
    sfs_io.writeSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;
}

pub fn sfsSeek(file_desc: *fd.FileDescriptor, offset: i64, whence: u32) isize {
    const file: *t.SfsFile = @ptrCast(@alignCast(file_desc.private_data));
    const size: i64 = @intCast(file.size);
    const current = std.math.cast(i64, file_desc.position) orelse return -75;

    const new_pos: i64 = switch (whence) {
        0 => offset,
        1 => current + offset,
        2 => size + offset,
        else => return -22,
    };

    if (new_pos < 0) return -22;

    const max_pos: i64 = std.math.maxInt(u32);
    if (new_pos > max_pos) return -27;

    file_desc.position = std.math.cast(usize, new_pos) orelse return -75;
    return std.math.cast(isize, new_pos) orelse return -75;
}

pub fn sfsStat(file_desc: *fd.FileDescriptor, stat_buf: *anyopaque) isize {
    const file: *t.SfsFile = @ptrCast(@alignCast(file_desc.private_data));
    const stat: *uapi.stat.Stat = @ptrCast(@alignCast(stat_buf));

    const metadata = refreshMetadataFromDisk(file) orelse {
        const nlink = if (file.mode & meta.S_IFDIR != 0) @as(u32, 1) else @as(u32, 1);
        stat.* = .{
            .dev = 0,
            .ino = file.entry_idx,
            .nlink = nlink,
            .mode = file.mode,
            .uid = file.uid,
            .gid = file.gid,
            .rdev = 0,
            .size = @intCast(file.size),
            .blksize = 512,
            .blocks = @intCast((file.size + 511) / 512),
            .atime = 0,
            .atime_nsec = 0,
            .mtime = 0,
            .mtime_nsec = 0,
            .ctime = 0,
            .ctime_nsec = 0,
            .__pad0 = 0,
            .__unused = [_]i64{0} ** 3,
        };
        return 0;
    };

    // Use nlink from metadata, but default to 1 if 0 (backward compat)
    const nlink = if (metadata.nlink == 0) @as(u32, 1) else metadata.nlink;

    stat.* = .{
        .dev = 0,
        .ino = file.entry_idx,
        .nlink = nlink,
        .mode = metadata.mode,
        .uid = metadata.uid,
        .gid = metadata.gid,
        .rdev = 0,
        .size = @intCast(metadata.size),
        .blksize = 512,
        .blocks = @intCast((metadata.size + 511) / 512),
        .atime = @intCast(metadata.atime),
        .atime_nsec = 0,
        .mtime = @intCast(metadata.mtime),
        .mtime_nsec = 0,
        .ctime = @intCast(metadata.mtime), // SFS doesn't track ctime separately
        .ctime_nsec = 0,
        .__pad0 = 0,
        .__unused = [_]i64{0} ** 3,
    };
    return 0;
}

// =============================================================================
// Helper Functions
// =============================================================================

pub fn refreshSizeFromDisk(self: *t.SfsFile) ?u32 {
    if (self.entry_idx >= t.MAX_FILES) return null;

    const block_idx = self.entry_idx / 4;
    const offset_idx = self.entry_idx % 4;
    var dir_buf: [512]u8 align(4) = undefined;

    @import("hal").mmio.memoryBarrier(); //
    sfs_io.readSector(self.fs, self.fs.superblock.root_dir_start + block_idx, &dir_buf) catch return null;

    const entry: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset_idx * 128]));
    if (entry.flags != 1) return null;
    if (entry.start_block != self.start_block) return null;

    const max_size = @as(u64, self.fs.superblock.total_blocks) * 512;
    if (entry.size > max_size) return null;

    return entry.size;
}

pub fn refreshMetadataFromDisk(self: *t.SfsFile) ?t.SfsFile.RefreshedMetadata {
    if (self.entry_idx >= t.MAX_FILES) return null;

    const block_idx = self.entry_idx / 4;
    const offset_idx = self.entry_idx % 4;
    var dir_buf: [512]u8 align(4) = undefined;

    @import("hal").mmio.memoryBarrier();
    sfs_io.readSector(self.fs, self.fs.superblock.root_dir_start + block_idx, &dir_buf) catch return null;

    const entry: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset_idx * 128]));
    if (entry.flags != 1) return null;
    if (entry.start_block != self.start_block) return null;

    const max_size = @as(u64, self.fs.superblock.total_blocks) * 512;
    if (entry.size > max_size) return null;

    return t.SfsFile.RefreshedMetadata{
        .size = entry.size,
        .mode = entry.mode,
        .uid = entry.uid,
        .gid = entry.gid,
        .mtime = entry.mtime,
        .atime = entry.atime,
        .nlink = entry.nlink,
    };
}

pub fn truncateFd(file_desc: *fd.FileDescriptor, length: usize) !void {
    if (file_desc.ops != &sfs_ops) return error.NotSfs;

    const file: *t.SfsFile = @ptrCast(@alignCast(file_desc.private_data));
    if (file.entry_idx >= t.MAX_FILES) return error.IOError;

    if (length > std.math.maxInt(u32)) return error.TooLarge;

    const new_size: u32 = @intCast(length);

    if (length > file.size) {
        // Extension path: allocate blocks and zero-fill (same pattern as sfsWrite)
        const current_blocks: u32 = if (file.size == 0) 1 else (file.size + 511) / 512;
        const requested_blocks: u32 = (new_size + 511) / 512;

        if (requested_blocks > current_blocks) {
            // Allocate additional blocks under alloc_lock
            var old_next_free: u32 = 0;
            var blocks_added: u32 = 0;
            {
                const alloc_held = file.fs.alloc_lock.acquire();
                defer alloc_held.release();

                // Re-check under lock
                const cur_blocks: u32 = if (file.size == 0) 1 else (file.size + 511) / 512;
                if (requested_blocks > cur_blocks) {
                    const end_block = file.start_block + cur_blocks;
                    if (end_block != file.fs.superblock.next_free_block) {
                        if (file.size != 0) return error.IOError; // ENOSPC: file not at allocation frontier
                    }

                    blocks_added = requested_blocks - cur_blocks;
                    if (blocks_added > file.fs.superblock.free_blocks) return error.IOError;

                    const new_next_free = std.math.add(u32, file.fs.superblock.next_free_block, blocks_added) catch return error.IOError;
                    if (new_next_free > file.fs.superblock.total_blocks) return error.IOError;

                    old_next_free = file.fs.superblock.next_free_block;
                    file.fs.superblock.next_free_block = new_next_free;
                    file.fs.superblock.free_blocks -= blocks_added;
                }
            }

            // Persist superblock after lock release
            if (blocks_added > 0) {
                sfs_io.updateSuperblock(file.fs) catch {
                    const rollback_held = file.fs.alloc_lock.acquire();
                    defer rollback_held.release();
                    file.fs.superblock.next_free_block = old_next_free;
                    file.fs.superblock.free_blocks += blocks_added;
                    return error.IOError;
                };
            }
        }

        // Zero-fill from old size to new size (prevent information leaks)
        var fill_pos: u64 = file.size;
        while (fill_pos < new_size) {
            const sector_idx = @as(u32, @intCast(fill_pos / 512));
            const sector_offset = @as(u32, @intCast(fill_pos % 512));
            const abs_sector = file.start_block + sector_idx;

            var sector_buf: [512]u8 align(4) = undefined;
            if (sector_offset > 0) {
                // Partial sector: read existing, zero the rest
                sfs_io.readSector(file.fs, abs_sector, &sector_buf) catch return error.IOError;
            } else {
                @memset(&sector_buf, 0);
            }
            const fill_end = @min(512, sector_offset + (new_size - @as(u32, @intCast(fill_pos))));
            @memset(sector_buf[sector_offset..fill_end], 0);
            sfs_io.writeSector(file.fs, abs_sector, &sector_buf) catch return error.IOError;
            fill_pos += (fill_end - sector_offset);
        }

        // Update size and directory entry under alloc_lock
        {
            const held = file.fs.alloc_lock.acquire();
            defer held.release();

            file.size = new_size;

            const block_idx = file.entry_idx / 4;
            const offset_idx = file.entry_idx % 4;

            var dir_buf: [512]u8 align(4) = undefined;
            sfs_io.readSector(file.fs, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch return error.IOError;

            const entry: *t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset_idx * 128]));
            entry.size = file.size;

            sfs_io.writeSector(file.fs, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch return error.IOError;
        }
    } else {
        // Shrink path: capture block info under lock, free blocks outside
        var free_start: u32 = 0;
        var free_count: u32 = 0;
        {
            const held = file.fs.alloc_lock.acquire();
            defer held.release();

            if (length > file.size) return error.TooLarge;

            const current_blocks: u32 = if (file.size == 0) 1 else (file.size + 511) / 512;
            const requested_blocks: u32 = if (new_size == 0) 1 else (new_size + 511) / 512;

            if (requested_blocks < current_blocks) {
                free_start = file.start_block + requested_blocks;
                free_count = current_blocks - requested_blocks;

                const end_block = file.start_block + current_blocks;
                if (end_block == file.fs.superblock.next_free_block) {
                    file.fs.superblock.next_free_block = file.start_block + requested_blocks;
                    sfs_io.updateSuperblock(file.fs) catch return error.IOError;
                }
            }

            file.size = new_size;

            {
                const fd_lock = file_desc.lock.acquire();
                defer fd_lock.release();
                if (file_desc.position > new_size) {
                    file_desc.position = new_size;
                }
            }

            const block_idx = file.entry_idx / 4;
            const offset_idx = file.entry_idx % 4;

            var dir_buf: [512]u8 align(4) = undefined;
            sfs_io.readSector(file.fs, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch return error.IOError;

            const entry: *t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset_idx * 128]));
            entry.size = file.size;

            sfs_io.writeSector(file.fs, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch return error.IOError;
        }

        // Free blocks OUTSIDE the lock -- freeBlock acquires alloc_lock internally
        if (free_count > 0) {
            sfs_alloc.freeBlocks(file.fs, free_start, free_count);
        }
    }
}

fn sfsPoll(file_desc: *fd.FileDescriptor, requested_events: u32) u32 {
    _ = file_desc;
    _ = requested_events;
    // Regular files are always ready (Linux behavior)
    return uapi.epoll.EPOLLIN | uapi.epoll.EPOLLOUT;
}

/// Change file ownership for SFS files (FD-based, for fchown syscall).
/// SECURITY: Permission checks are performed at syscall layer (sys_fchown).
/// This function only updates metadata on disk.
pub fn sfsFdChown(file_desc: *fd.FileDescriptor, uid: ?u32, gid: ?u32) isize {
    const held = file_desc.lock.acquire();
    defer held.release();

    const file: *t.SfsFile = @ptrCast(@alignCast(file_desc.private_data));

    // Update in-memory metadata
    if (uid) |new_uid| file.uid = new_uid;
    if (gid) |new_gid| file.gid = new_gid;

    // Write metadata to disk
    // DirEntry entries are 128 bytes, 4 per 512-byte sector
    const block_idx = file.entry_idx / 4;
    const offset_in_block = (file.entry_idx % 4) * 128;

    var sector: [512]u8 align(512) = undefined;
    sfs_io.readSector(file.fs, file.fs.superblock.root_dir_start + block_idx, &sector) catch return -5; // EIO

    const entry: *t.DirEntry = @ptrCast(@alignCast(&sector[offset_in_block]));
    if (uid) |new_uid| entry.uid = new_uid;
    if (gid) |new_gid| entry.gid = new_gid;

    sfs_io.writeSector(file.fs, file.fs.superblock.root_dir_start + block_idx, &sector) catch return -5; // EIO

    return 0;
}

pub const sfs_ops = fd.FileOps{
    .read = sfsRead,
    .write = sfsWrite,
    .close = sfsClose,
    .seek = sfsSeek,
    .stat = sfsStat,
    .ioctl = null,
    .mmap = null,
    .poll = sfsPoll,
    .truncate = sfsTruncate,
    .getdents = sfsGetdents,
    .chown = sfsFdChown,
};

/// Get directory entries for SFS root directory
/// NOTE: dirp is a user-space pointer that must be validated by the caller (syscall layer)
pub fn sfsGetdents(file_desc: *fd.FileDescriptor, dirp: usize, count: usize) isize {
    const DT_DIR: u8 = 4;
    const DT_REG: u8 = 8;
    const DT_LNK: u8 = 10;

    const held = file_desc.lock.acquire();
    defer held.release();

    const file: *t.SfsFile = @ptrCast(@alignCast(file_desc.private_data));
    const sfs = file.fs;

    // SECURITY: Allocate directory buffer on heap to prevent stack overflow
    const alloc = heap.allocator();
    const dir_buf = alloc.alloc(u8, t.ROOT_DIR_BLOCKS * t.SECTOR_SIZE) catch return -12; // ENOMEM
    defer alloc.free(dir_buf);

    // Read root directory entries
    var i: u32 = 0;
    while (i < t.ROOT_DIR_BLOCKS) : (i += 1) {
        const sector = sfs.superblock.root_dir_start + i;
        const offset = i * t.SECTOR_SIZE;
        sfs_io.readSector(sfs, sector, dir_buf[offset..][0..t.SECTOR_SIZE]) catch return -5;
    }

    const entries: [*]const t.DirEntry = @ptrCast(@alignCast(dir_buf.ptr));
    const start_index = std.math.cast(usize, file_desc.position) orelse return -22;

    var bytes_written: usize = 0;

    // SECURITY NOTE: This function assumes dirp has been validated as a valid user address
    // by the syscall layer before being called. We use volatile writes to prevent compiler
    // optimization from reordering user-space writes.
    const user_buf: [*]volatile u8 = @ptrFromInt(dirp);

    var idx: usize = start_index;
    while (idx < t.MAX_FILES) : (idx += 1) {
        const entry = &entries[idx];

        // Skip inactive entries
        if ((entry.flags & 1) == 0) continue;

        // Get null-terminated name
        const name_end = std.mem.indexOfScalar(u8, &entry.name, 0) orelse entry.name.len;
        const name = entry.name[0..name_end];
        if (name.len == 0) continue;

        const name_len = name.len;
        const reclen = @sizeOf(uapi.dirent.Dirent64) + name_len + 1;
        const aligned_reclen = std.mem.alignForward(usize, reclen, 8);

        if (bytes_written + aligned_reclen > count) {
            break;
        }

        var ent: uapi.dirent.Dirent64 = .{
            .d_ino = idx + 1,
            .d_off = @intCast(idx + 1),
            .d_reclen = @intCast(aligned_reclen),
            .d_type = if (entry.isSymlink()) DT_LNK else if (entry.isDirectory()) DT_DIR else DT_REG,
            .d_name = undefined,
        };

        // Copy dirent structure
        const ent_bytes = std.mem.asBytes(&ent);
        for (ent_bytes, 0..) |byte, j| {
            user_buf[bytes_written + j] = byte;
        }

        // Copy filename
        const name_offset = bytes_written + @offsetOf(uapi.dirent.Dirent64, "d_name");
        for (name, 0..) |byte, j| {
            user_buf[name_offset + j] = byte;
        }
        // Null terminator
        user_buf[name_offset + name_len] = 0;

        bytes_written += aligned_reclen;
        file_desc.position = idx + 1;
    }

    return std.math.cast(isize, bytes_written) orelse -75;
}

fn sfsTruncate(file_desc: *fd.FileDescriptor, length: u64) error{ AccessDenied, IOError }!void {
    // SECURITY: Use checked cast to prevent truncation on hypothetical 32-bit targets
    const length_usize = std.math.cast(usize, length) orelse return error.IOError;
    truncateFd(file_desc, length_usize) catch {
        return error.IOError;
    };
}

/// Create a symbolic link
pub fn sfsSymlink(ctx: ?*anyopaque, target: []const u8, linkpath: []const u8) vfs.Error!void {
    const self: *t.SFS = @ptrCast(@alignCast(ctx));
    if (!self.mounted) return vfs.Error.IOError;

    // Extract linkname from linkpath (strip leading '/')
    const linkname = if (linkpath.len > 0 and linkpath[0] == '/') linkpath[1..] else linkpath;

    // Validate linkname
    if (!sfs_alloc.isValidFilename(linkname)) return vfs.Error.AccessDenied;
    if (linkname.len == 0 or linkname.len >= 32) return vfs.Error.NameTooLong;

    // Validate target
    if (target.len == 0) return vfs.Error.NotFound; // ENOENT for empty target
    if (target.len > 511) return vfs.Error.NameTooLong; // Max 511 bytes (fits in one 512B block)

    const alloc = heap.allocator();

    // SECURITY: Allocate a data block FIRST to store the target path
    const start_block = sfs_alloc.allocateBlock(self) catch {
        return vfs.Error.NoMemory;
    };
    errdefer sfs_alloc.freeBlock(self, start_block) catch {};

    // Write target string to the allocated block
    var target_buf: [512]u8 align(4) = [_]u8{0} ** 512;
    @memcpy(target_buf[0..target.len], target);
    sfs_io.writeSector(self, start_block, &target_buf) catch {
        return vfs.Error.IOError;
    };

    // SECURITY: Allocate directory buffer on heap to prevent stack overflow
    const dir_buf = alloc.alloc(u8, t.ROOT_DIR_BLOCKS * 512) catch return vfs.Error.NoMemory;
    defer alloc.free(dir_buf);

    // PHASE 1: Read directory UNLOCKED to find free slot and check name
    sfs_io.readDirectoryAsync(self, dir_buf) catch {
        return vfs.Error.IOError;
    };

    // Check if linkname already exists
    for (0..t.MAX_FILES) |i| {
        const idx: u32 = @intCast(i);
        const blk_idx = idx / 4;
        const off_idx = idx % 4;
        const e: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf[blk_idx * 512 + off_idx * 128]));
        if (e.flags == 1) {
            const e_name = std.mem.sliceTo(&e.name, 0);
            if (std.mem.eql(u8, e_name, linkname)) {
                return vfs.Error.AlreadyExists;
            }
        }
    }

    // PHASE 2: Find free slot UNLOCKED
    var free_slot: ?u32 = null;
    for (0..t.MAX_FILES) |slot_i| {
        const slot_idx: u32 = @intCast(slot_i);
        const blk_idx = slot_idx / 4;
        const off_idx = slot_idx % 4;
        const e: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf[blk_idx * 512 + off_idx * 128]));
        if (e.flags == 0) {
            free_slot = slot_idx;
            break;
        }
    }

    const new_idx = free_slot orelse {
        return vfs.Error.NoMemory;
    };

    // Create new symlink entry
    var new_entry = t.DirEntry{
        .name = [_]u8{0} ** 32,
        .start_block = start_block,
        .size = @intCast(target.len), // size stores target string length
        .flags = 1,
        .mode = meta.S_IFLNK | 0o777, // Symlinks are always rwxrwxrwx per POSIX
        .uid = 0,
        .gid = 0,
        .mtime = 0,
        .atime = 0,
        .nlink = 1,
        ._pad = [_]u8{0} ** (128 - 68),
    };
    @memcpy(new_entry.name[0..linkname.len], linkname);

    // PHASE 3: Calculate block location
    const block_idx = new_idx / 4;
    const offset_in_block = std.math.mul(usize, new_idx % 4, 128) catch return vfs.Error.IOError;

    // PHASE 4: Acquire lock, re-read, validate, modify in buffer, update counters, release lock
    var block_buf: [512]u8 align(4) = [_]u8{0} ** 512;
    {
        const lock_held = self.alloc_lock.acquire();
        defer lock_held.release();

        // Check file count under lock
        if (self.superblock.file_count >= t.MAX_FILES) {
            return vfs.Error.NoMemory;
        }

        // Re-read SPECIFIC BLOCK under lock to validate slot still free (TOCTOU prevention)
        sfs_io.readSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch {
            return vfs.Error.IOError;
        };

        const verify_entry: *const t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));
        if (verify_entry.flags != 0) {
            // Slot taken by another thread - race detected
            return vfs.Error.NoMemory;
        }

        // Write new entry to buffer
        const dest: *t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));
        dest.* = new_entry;

        // Update superblock file count in memory
        self.superblock.file_count += 1;
    }

    // PHASE 5: Write directory block OUTSIDE lock
    sfs_io.writeSector(self, self.superblock.root_dir_start + block_idx, &block_buf) catch {
        // Rollback file_count on write failure
        const rollback_held = self.alloc_lock.acquire();
        defer rollback_held.release();
        self.superblock.file_count -= 1;
        return vfs.Error.IOError;
    };

    // PHASE 6: Write superblock OUTSIDE lock
    sfs_io.updateSuperblock(self) catch {
        return vfs.Error.IOError;
    };
}

/// Read a symbolic link's target
pub fn sfsReadlink(ctx: ?*anyopaque, path: []const u8, buf: []u8) vfs.Error!usize {
    const self: *t.SFS = @ptrCast(@alignCast(ctx));
    if (!self.mounted) return vfs.Error.IOError;

    // Extract name from path (strip leading '/')
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;

    // Validate name
    if (!sfs_alloc.isValidFilename(name)) return vfs.Error.AccessDenied;
    if (name.len == 0 or name.len >= 32) return vfs.Error.NotFound;

    const alloc = heap.allocator();

    // SECURITY: Allocate directory buffer on heap to prevent stack overflow
    const dir_buf = alloc.alloc(u8, t.ROOT_DIR_BLOCKS * 512) catch return vfs.Error.NoMemory;
    defer alloc.free(dir_buf);

    // Read directory (UNLOCKED scan is fine for read-only operation)
    sfs_io.readDirectoryAsync(self, dir_buf) catch {
        return vfs.Error.IOError;
    };

    // Find entry by name
    for (0..t.MAX_FILES) |i| {
        const idx: u32 = @intCast(i);
        const blk_idx = idx / 4;
        const off_idx = idx % 4;
        const entry: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf[blk_idx * 512 + off_idx * 128]));

        if (entry.flags == 1) {
            const e_name = std.mem.sliceTo(&entry.name, 0);
            if (std.mem.eql(u8, e_name, name)) {
                // Found the entry - check if it's a symlink
                if (!entry.isSymlink()) {
                    return vfs.Error.NotSupported; // Maps to EINVAL at syscall layer (not a symlink)
                }

                // Validate start_block is within valid range
                if (entry.start_block < self.superblock.data_start or
                    entry.start_block >= self.superblock.total_blocks)
                {
                    return vfs.Error.IOError;
                }

                // Validate size is reasonable (max 511 bytes)
                if (entry.size > 511) {
                    return vfs.Error.IOError;
                }

                // Read the data block containing the target path
                var sector_buf: [512]u8 align(4) = [_]u8{0} ** 512; // Zero-init to prevent info leak
                sfs_io.readSector(self, entry.start_block, &sector_buf) catch {
                    return vfs.Error.IOError;
                };

                // Copy target to output buffer
                const copy_len = @min(entry.size, buf.len);
                @memcpy(buf[0..copy_len], sector_buf[0..copy_len]);

                return copy_len;
            }
        }
    }

    // Entry not found
    return vfs.Error.NotFound;
}

/// SFS statfs implementation
pub fn sfsStatfs(ctx: ?*anyopaque) vfs.Error!uapi.stat.Statfs {
    const self: *t.SFS = @ptrCast(@alignCast(ctx.?));

    // Read stats from superblock (already maintained by allocation code)
    const total_blocks = self.superblock.total_blocks;
    const free_blocks = self.superblock.free_blocks;
    const file_count = self.superblock.file_count;
    const total_inodes = @as(u32, t.MAX_FILES);

    return uapi.stat.Statfs{
        .f_type = 0x5346532f, // SFS_MAGIC (from types.zig)
        .f_bsize = 512,
        .f_blocks = @as(i64, total_blocks),
        .f_bfree = @as(i64, free_blocks),
        .f_bavail = @as(i64, free_blocks),
        .f_files = @as(i64, total_inodes),
        .f_ffree = @as(i64, total_inodes - file_count),
        .f_fsid = .{ .val = .{ 0, 0 } },
        .f_namelen = 32, // DirEntry.name field size
        .f_frsize = 512,
        .f_flags = 0,
        .f_spare = [_]i64{0} ** 4,
    };
}
