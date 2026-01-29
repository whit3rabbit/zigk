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
        var sector_buf: [512]u8 = [_]u8{0} ** 512;
        sfs_io.readSector(file.fs.device_fd, phys_block, &sector_buf) catch return -5;

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
        var sector_buf: [512]u8 = [_]u8{0} ** 512;
        sfs_io.readSector(file.fs.device_fd, phys_block, &sector_buf) catch {};

        const chunk = @min(buf.len - written_count, 512 - byte_offset);
        @memcpy(sector_buf[byte_offset..][0..chunk], buf[written_count..][0..chunk]);

        sfs_io.writeSector(file.fs.device_fd, phys_block, &sector_buf) catch return -5;

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
            var dir_buf: [512]u8 = [_]u8{0} ** 512;
            sfs_io.readSector(file.fs.device_fd, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch {
                // Graceful degradation: data written, metadata update failed
                return std.math.cast(isize, written_count) orelse return -75;
            };

            // PHASE 3: Acquire lock for atomic update
            const lock_held = file.fs.alloc_lock.acquire();
            defer lock_held.release();

            // PHASE 4: Re-read under lock (TOCTOU prevention)
            sfs_io.readSector(file.fs.device_fd, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch {
                return std.math.cast(isize, written_count) orelse return -75;
            };

            // PHASE 5: Validate and update
            const entry: *t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset_in_block]));

            // SECURITY: Validate start_block to prevent wrong-file race
            if (entry.flags == 1 and entry.start_block == file.start_block) {
                entry.size = file.size;
                sfs_io.writeSector(file.fs.device_fd, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch {
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

        return fd.createFd(&sfs_ops, flags, file_ctx) catch {
            const lock_held = self.alloc_lock.acquire();
            defer lock_held.release();
            if (self.open_counts[found_idx] > 0) {
                self.open_counts[found_idx] -= 1;
            }
            alloc.destroy(file_ctx);
            return vfs.Error.NoMemory;
        };
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
                ._pad = [_]u8{0} ** (128 - 60),
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

            // PHASE 3: Atomic update UNDER LOCK
            console.debug("SFS: Acquiring alloc_lock", .{});
            const create_result: vfs.Error!void = blk: {
                const lock_held = self.alloc_lock.acquire();
                defer lock_held.release();
                console.debug("SFS: Lock acquired", .{});

                // Check file count under lock
                if (self.superblock.file_count >= t.MAX_FILES) {
                    break :blk vfs.Error.NoMemory;
                }

                // Re-read SPECIFIC BLOCK under lock to validate slot still free (TOCTOU prevention)
                const block_idx = new_idx / 4;
                const offset_in_block = std.math.mul(usize, new_idx % 4, 128) catch break :blk vfs.Error.IOError;

                console.debug("SFS: Reading block {} under lock", .{block_idx});
                var block_buf: [512]u8 = [_]u8{0} ** 512;
                sfs_io.readSector(self.device_fd, self.superblock.root_dir_start + block_idx, &block_buf) catch {
                    break :blk vfs.Error.IOError;
                };
                console.debug("SFS: Block read complete", .{});

                const verify_entry: *const t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));
                if (verify_entry.flags != 0) {
                    // Slot taken by another thread - race detected
                    break :blk vfs.Error.NoMemory;
                }

                // Write new entry to block
                const dest: *t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));
                dest.* = new_entry;

                console.debug("SFS: Writing block {} under lock", .{block_idx});
                // Write block back
                sfs_io.writeSector(self.device_fd, self.superblock.root_dir_start + block_idx, &block_buf) catch {
                    break :blk vfs.Error.IOError;
                };
                console.debug("SFS: Block write complete", .{});

                // Update superblock under lock
                self.superblock.file_count += 1;
                console.debug("SFS: Updating superblock", .{});
                sfs_io.updateSuperblock(self) catch {
                    self.superblock.file_count -= 1;
                    break :blk vfs.Error.IOError;
                };
                console.debug("SFS: Superblock updated", .{});

                // Update open count under lock
                self.open_counts[new_idx] = std.math.add(u32, self.open_counts[new_idx], 1) catch {
                    self.superblock.file_count -= 1;
                    break :blk vfs.Error.NoMemory;
                };

                console.debug("SFS: Lock will be released", .{});
                break :blk {};
            };

            console.debug("SFS: Checking create_result", .{});
            if (create_result) |_| {} else |err| {
                console.debug("SFS: Create failed with error", .{});
                return err;
            }
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

    // SECURITY: Hold lock through entire unlink operation to prevent TOCTOU race
    const lock_held = self.alloc_lock.acquire();
    defer lock_held.release();

    // SECURITY: Re-read the specific directory block under lock to prevent TOCTOU
    // The entry we found in the first pass may have been modified by another thread
    const block_idx = idx / 4;
    const offset_in_block = (idx % 4) * 128;
    var block_buf: [512]u8 = [_]u8{0} ** 512;
    sfs_io.readSector(self.device_fd, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;

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

    // Free blocks while holding lock (if not deferred)
    if (!is_open) {
        sfs_alloc.freeBlocks(self, e.start_block, blocks_used);
    }

    // Clear directory entry while holding lock
    e.flags = 0;
    e.name = [_]u8{0} ** 32;
    if (!is_open) {
        e.start_block = 0;
        e.size = 0;
    }

    // Write directory update while holding lock
    sfs_io.writeSector(self.device_fd, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;

    // Update superblock while holding lock
    self.superblock.file_count = std.math.sub(u32, self.superblock.file_count, 1) catch 0;
    sfs_io.updateSuperblock(self) catch return vfs.Error.IOError;

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

    // PHASE 3: Atomic update UNDER LOCK
    const held = self.alloc_lock.acquire();
    defer held.release();

    // Re-read specific block under lock (TOCTOU prevention)
    const block_idx = entry_idx / 4;
    const offset_in_block = std.math.mul(usize, entry_idx % 4, 128) catch return vfs.Error.IOError;

    var block_buf: [512]u8 = [_]u8{0} ** 512;
    sfs_io.readSector(self.device_fd, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;

    const e: *t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));

    // Validate entry still exists and has same name (TOCTOU check)
    if (e.flags != 1) {
        return vfs.Error.NotFound;
    }

    const e_name = std.mem.sliceTo(&e.name, 0);
    if (!std.mem.eql(u8, e_name, name)) {
        return vfs.Error.NotFound;
    }

    // Update mode
    const file_type = e.mode & 0o170000;
    e.mode = file_type | (mode & 0o7777);

    // Write block back
    sfs_io.writeSector(self.device_fd, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;
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

    // PHASE 3: Atomic update UNDER LOCK
    const held = self.alloc_lock.acquire();
    defer held.release();

    // Re-read specific block under lock (TOCTOU prevention)
    const block_idx = entry_idx / 4;
    const offset_in_block = std.math.mul(usize, entry_idx % 4, 128) catch return vfs.Error.IOError;

    var block_buf: [512]u8 = [_]u8{0} ** 512;
    sfs_io.readSector(self.device_fd, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;

    const e: *t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));

    // Validate entry still exists and has same name (TOCTOU check)
    if (e.flags != 1) {
        return vfs.Error.NotFound;
    }

    const e_name = std.mem.sliceTo(&e.name, 0);
    if (!std.mem.eql(u8, e_name, name)) {
        return vfs.Error.NotFound;
    }

    // Update ownership
    if (uid) |new_uid| e.uid = new_uid;
    if (gid) |new_gid| e.gid = new_gid;

    // Write block back
    sfs_io.writeSector(self.device_fd, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;
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
        ._pad = [_]u8{0} ** (128 - 60),
    };
    @memcpy(new_entry.name[0..name.len], name);

    // PHASE 4: Atomic update UNDER LOCK
    const held = self.alloc_lock.acquire();
    defer held.release();

    // Check file count limit under lock
    if (self.superblock.file_count >= t.MAX_FILES) {
        return vfs.Error.NoMemory;
    }

    // Re-read specific block under lock (TOCTOU prevention)
    const block_idx = new_idx / 4;
    const offset_in_block = std.math.mul(usize, new_idx % 4, 128) catch {
        return vfs.Error.IOError;
    };

    var block_buf: [512]u8 = [_]u8{0} ** 512;
    const dir_block = std.math.add(u32, self.superblock.root_dir_start, block_idx) catch {
        return vfs.Error.IOError;
    };

    sfs_io.readSector(self.device_fd, dir_block, &block_buf) catch {
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

    // Write new entry
    const dest: *t.DirEntry = @ptrCast(@alignCast(&block_buf[offset_in_block]));
    dest.* = new_entry;

    sfs_io.writeSector(self.device_fd, dir_block, &block_buf) catch {
        return vfs.Error.IOError;
    };

    // Update superblock under lock
    self.superblock.file_count = std.math.add(u32, self.superblock.file_count, 1) catch {
        console.err("SFS: Integer overflow in file_count increment", .{});
        return vfs.Error.IOError;
    };

    sfs_io.updateSuperblock(self) catch {
        self.superblock.file_count -= 1;
        return vfs.Error.IOError;
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

    // SECURITY: Hold lock through entire operation to prevent TOCTOU race
    const lock_held = self.alloc_lock.acquire();
    defer lock_held.release();

    // SECURITY: Re-read the specific directory block under lock
    // The entry we found may have been modified by another thread
    const block_idx = idx / 4;
    const offset_in_block = std.math.mul(usize, idx % 4, 128) catch return vfs.Error.IOError;

    var block_buf: [512]u8 = [_]u8{0} ** 512;
    sfs_io.readSector(self.device_fd, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;

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

    // Clear directory entry under lock
    e.flags = 0;
    e.name = [_]u8{0} ** 32;
    e.start_block = 0;
    e.size = 0;
    e.mode = 0;

    // Write updated directory block while holding lock
    sfs_io.writeSector(self.device_fd, self.superblock.root_dir_start + block_idx, &block_buf) catch return vfs.Error.IOError;

    // Update superblock file count while holding lock
    self.superblock.file_count = std.math.sub(u32, self.superblock.file_count, 1) catch 0;
    sfs_io.updateSuperblock(self) catch return vfs.Error.IOError;

    console.info("SFS: Removed directory '{s}'", .{name});
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
        stat.* = .{
            .dev = 0,
            .ino = file.entry_idx,
            .nlink = 1,
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

    stat.* = .{
        .dev = 0,
        .ino = file.entry_idx,
        .nlink = 1,
        .mode = metadata.mode,
        .uid = metadata.uid,
        .gid = metadata.gid,
        .rdev = 0,
        .size = @intCast(metadata.size),
        .blksize = 512,
        .blocks = @intCast((metadata.size + 511) / 512),
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
}

// =============================================================================
// Helper Functions
// =============================================================================

pub fn refreshSizeFromDisk(self: *t.SfsFile) ?u32 {
    if (self.entry_idx >= t.MAX_FILES) return null;

    const block_idx = self.entry_idx / 4;
    const offset_idx = self.entry_idx % 4;
    var dir_buf: [512]u8 = undefined;

    @import("hal").mmio.memoryBarrier(); // 
    sfs_io.readSector(self.fs.device_fd, self.fs.superblock.root_dir_start + block_idx, &dir_buf) catch return null;

    const entry: *const t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset_idx * 128]));
    if (entry.flags != 1) return null;
    if (entry.start_block != self.start_block) return null;

    const max_size = @as(u64, self.fs.superblock.total_blocks) * 512;
    if (entry.size > max_size) return null;

    return entry.size;
}

pub fn refreshMetadataFromDisk(self: *t.SfsFile) ?t.SfsFile.RefreshedMetadata {
    console.debug("SFS: refreshMetadataFromDisk entry_idx={}", .{self.entry_idx});
    if (self.entry_idx >= t.MAX_FILES) return null;

    const block_idx = self.entry_idx / 4;
    const offset_idx = self.entry_idx % 4;
    var dir_buf: [512]u8 = undefined;

    console.debug("SFS: refreshMetadata calling readSector block={}", .{block_idx});
    @import("hal").mmio.memoryBarrier(); //
    sfs_io.readSector(self.fs.device_fd, self.fs.superblock.root_dir_start + block_idx, &dir_buf) catch return null;
    console.debug("SFS: refreshMetadata readSector complete", .{});

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
    };
}

pub fn truncateFd(file_desc: *fd.FileDescriptor, length: usize) !void {
    if (file_desc.ops != &sfs_ops) return error.NotSfs;

    const file: *t.SfsFile = @ptrCast(@alignCast(file_desc.private_data));
    if (file.entry_idx >= t.MAX_FILES) return error.IOError;

    if (length > std.math.maxInt(u32)) return error.TooLarge;
    if (length > file.size) return error.TooLarge;

    const held = file.fs.alloc_lock.acquire();
    defer held.release();

    if (length > file.size) return error.TooLarge;

    const new_size: u32 = @intCast(length);
    const current_blocks: u32 = if (file.size == 0) 1 else (file.size + 511) / 512;
    const requested_blocks: u32 = if (new_size == 0) 1 else (new_size + 511) / 512;

    if (requested_blocks < current_blocks) {
        const free_start = file.start_block + requested_blocks;
        const free_count = current_blocks - requested_blocks;
        if (free_count > 0) {
            sfs_alloc.freeBlocks(file.fs, free_start, free_count);
        }

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

    var dir_buf: [512]u8 = undefined;
    sfs_io.readSector(file.fs.device_fd, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch return error.IOError;

    const entry: *t.DirEntry = @ptrCast(@alignCast(&dir_buf[offset_idx * 128]));
    entry.size = file.size;

    sfs_io.writeSector(file.fs.device_fd, file.fs.superblock.root_dir_start + block_idx, &dir_buf) catch return error.IOError;
}

pub const sfs_ops = fd.FileOps{
    .read = sfsRead,
    .write = sfsWrite,
    .close = sfsClose,
    .seek = sfsSeek,
    .stat = sfsStat,
    .ioctl = null,
    .mmap = null,
    .poll = null,
    .truncate = sfsTruncate,
    .getdents = sfsGetdents,
};

/// Get directory entries for SFS root directory
/// NOTE: dirp is a user-space pointer that must be validated by the caller (syscall layer)
pub fn sfsGetdents(file_desc: *fd.FileDescriptor, dirp: usize, count: usize) isize {
    const DT_DIR: u8 = 4;
    const DT_REG: u8 = 8;

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
        sfs_io.readSector(sfs.device_fd, sector, dir_buf[offset..][0..t.SECTOR_SIZE]) catch return -5;
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
            .d_type = if (entry.isDirectory()) DT_DIR else DT_REG,
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
