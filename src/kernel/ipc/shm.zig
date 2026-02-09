const std = @import("std");
const process = @import("process");
const pmm = @import("pmm");
const hal = @import("hal");
const ipc_perm = @import("ipc_perm.zig");
const uapi = @import("uapi");
const user_mem = @import("user_mem");
const vmm = @import("vmm");
const sync = @import("sync");
const console = @import("console");

const IPC_PRIVATE = uapi.ipc.sysv.IPC_PRIVATE;
const IPC_CREAT = uapi.ipc.sysv.IPC_CREAT;
const IPC_EXCL = uapi.ipc.sysv.IPC_EXCL;
const IPC_RMID = uapi.ipc.sysv.IPC_RMID;
const IPC_STAT = uapi.ipc.sysv.IPC_STAT;
const IPC_SET = uapi.ipc.sysv.IPC_SET;
const SHM_RDONLY = uapi.ipc.sysv.SHM_RDONLY;
const SHM_RND = uapi.ipc.sysv.SHM_RND;
const SHMMNI = uapi.ipc.sysv.SHMMNI;
const SHMMAX = uapi.ipc.sysv.SHMMAX;
const SHMMIN = uapi.ipc.sysv.SHMMIN;
const ShmidDs = uapi.ipc.sysv.ShmidDs;
const IpcPermUser = uapi.ipc.sysv.IpcPermUser;

const ShmSegment = struct {
    id: u32,
    key: i32,
    perm: ipc_perm.IpcPerm,
    size: usize,
    phys_pages: ?u64, // Physical address from PMM
    num_pages: usize,
    attach_count: u32,
    cpid: u32,
    lpid: u32,
    atime: i64,
    dtime: i64,
    ctime: i64,
    marked_for_deletion: bool,
    in_use: bool,
};

var segments: [SHMMNI]ShmSegment = [_]ShmSegment{.{
    .id = 0,
    .key = 0,
    .perm = .{ .key = 0, .cuid = 0, .cgid = 0, .uid = 0, .gid = 0, .mode = 0, .seq = 0 },
    .size = 0,
    .phys_pages = null,
    .num_pages = 0,
    .attach_count = 0,
    .cpid = 0,
    .lpid = 0,
    .atime = 0,
    .dtime = 0,
    .ctime = 0,
    .marked_for_deletion = false,
    .in_use = false,
}} ** SHMMNI;

var shm_lock: sync.Spinlock = .{};
var seq_counter: u16 = 0;

fn getCurrentTime() i64 {
    // Simplified: return 0 for MVP. Can be replaced with proper RTC/TSC time later.
    return 0;
}

pub fn shmget(key: i32, size: usize, flags: i32, proc: *const process.Process) !u32 {
    // Validate size
    if (size < SHMMIN or size > SHMMAX) return error.EINVAL;

    const held = shm_lock.acquire();
    defer held.release();

    // IPC_PRIVATE always creates a new segment
    if (key != IPC_PRIVATE) {
        // Search for existing segment with this key
        for (&segments) |*seg| {
            if (seg.in_use and seg.key == key and !seg.marked_for_deletion) {
                // Found existing segment
                if ((flags & IPC_EXCL) != 0 and (flags & IPC_CREAT) != 0) {
                    return error.EEXIST;
                }
                // Check read permission
                if (!ipc_perm.checkAccess(&seg.perm, proc, .read)) {
                    return error.EACCES;
                }
                return seg.id;
            }
        }
    }

    // Not found or IPC_PRIVATE - create new segment if IPC_CREAT is set
    if ((flags & IPC_CREAT) == 0 and key != IPC_PRIVATE) {
        return error.ENOENT;
    }

    // Find free slot
    var free_idx: ?usize = null;
    for (&segments, 0..) |*seg, i| {
        if (!seg.in_use) {
            free_idx = i;
            break;
        }
    }

    if (free_idx == null) return error.ENOSPC;
    const idx = free_idx.?;

    // Calculate number of pages needed
    const num_pages = std.math.divCeil(usize, size, pmm.PAGE_SIZE) catch return error.EINVAL;

    // Allocate physical pages (zeroed for security)
    const phys_addr = pmm.allocZeroedPages(num_pages) orelse return error.ENOMEM;

    // Initialize segment metadata
    const seg = &segments[idx];
    seq_counter +%= 1;
    if (seq_counter == 0) seq_counter = 1; // Avoid seq=0

    seg.id = ipc_perm.makeId(idx, seq_counter);
    seg.key = key;
    seg.perm = .{
        .key = key,
        .cuid = proc.euid,
        .cgid = proc.egid,
        .uid = proc.euid,
        .gid = proc.egid,
        .mode = @truncate(@as(u32, @bitCast(flags)) & 0o777),
        .seq = seq_counter,
    };
    seg.size = size;
    seg.phys_pages = phys_addr;
    seg.num_pages = num_pages;
    seg.attach_count = 0;
    seg.cpid = proc.pid;
    seg.lpid = 0;
    seg.atime = 0;
    seg.dtime = 0;
    seg.ctime = getCurrentTime();
    seg.marked_for_deletion = false;
    seg.in_use = true;

    return seg.id;
}

pub fn shmat(id: u32, shmaddr: usize, shmflg: u32, proc: *process.Process) !usize {
    // Find segment and check access
    const idx = ipc_perm.idToIndex(id);
    const seq = ipc_perm.idToSeq(id);

    if (idx >= SHMMNI) return error.EINVAL;

    var phys_addr: u64 = undefined;
    var num_pages: usize = undefined;
    var size: usize = undefined;

    {
        const held = shm_lock.acquire();
        defer held.release();

        const seg = &segments[idx];
        if (!seg.in_use or seg.perm.seq != seq) return error.EINVAL;
        if (seg.marked_for_deletion) return error.EIDRM;

        // Check permissions
        const mode: ipc_perm.AccessMode = if ((shmflg & SHM_RDONLY) != 0) .read else .write;
        if (!ipc_perm.checkAccess(&seg.perm, proc, mode)) {
            return error.EACCES;
        }

        phys_addr = seg.phys_pages.?;
        num_pages = seg.num_pages;
        size = seg.size;
    }

    // Determine virtual address
    var virt_addr: u64 = @intCast(shmaddr);
    if (shmaddr == 0) {
        // Find free range in process address space
        virt_addr = proc.user_vmm.findFreeRange(size) orelse return error.ENOMEM;
    } else {
        // Round down to page boundary if SHM_RND
        if ((shmflg & SHM_RND) != 0) {
            virt_addr = std.mem.alignBackward(u64, virt_addr, pmm.PAGE_SIZE);
        }
        // Validate alignment
        if (virt_addr % pmm.PAGE_SIZE != 0) return error.EINVAL;
    }

    // Map physical pages into process address space
    const page_flags = vmm.PageFlags{
        .writable = (shmflg & SHM_RDONLY) == 0,
        .user = true,
        .write_through = false,
        .cache_disable = false,
        .global = false,
        .no_execute = true,
    };

    const map_size = num_pages * pmm.PAGE_SIZE;
    vmm.mapRange(proc.cr3, virt_addr, phys_addr, map_size, page_flags) catch {
        return error.ENOMEM;
    };

    // Create VMA
    const vma = proc.user_vmm.createVma(
        virt_addr,
        virt_addr + map_size,
        if ((shmflg & SHM_RDONLY) != 0) 0x1 else 0x3, // PROT_READ or PROT_READ|PROT_WRITE
        0x1, // MAP_SHARED
    ) catch {
        // Rollback mapping
        var off: usize = 0;
        while (off < map_size) : (off += pmm.PAGE_SIZE) {
            vmm.unmapPage(proc.cr3, virt_addr + off) catch {};
        }
        return error.ENOMEM;
    };

    proc.user_vmm.insertVma(vma);

    // Update segment metadata
    {
        const held = shm_lock.acquire();
        defer held.release();

        const seg = &segments[idx];
        if (!seg.in_use or seg.perm.seq != seq) {
            // Segment was removed between checks - rollback
            _ = proc.user_vmm.munmap(virt_addr, map_size);
            return error.EIDRM;
        }

        seg.attach_count += 1;
        seg.lpid = proc.pid;
        seg.atime = getCurrentTime();
    }

    return @intCast(virt_addr);
}

pub fn shmdt(shmaddr: usize, proc: *process.Process) !void {
    const virt_addr: u64 = @intCast(shmaddr);

    // Find VMA containing this address
    const vma = proc.user_vmm.findOverlappingVma(virt_addr, virt_addr + 1) orelse return error.EINVAL;

    // Determine size from VMA
    const size = vma.end - vma.start;

    // Find matching segment by scanning (simplified approach)
    // In a production system, we'd store the shmid in the VMA metadata
    var seg_idx: ?usize = null;
    {
        const held = shm_lock.acquire();
        defer held.release();

        for (&segments, 0..) |*seg, i| {
            if (seg.in_use and seg.phys_pages != null) {
                // Check if this VMA's physical mapping matches this segment
                // For MVP, we assume the first page check is sufficient
                const seg_phys = seg.phys_pages.?;
                const vma_phys = vmm.translate(proc.cr3, virt_addr) orelse continue;
                if (vma_phys == seg_phys) {
                    seg_idx = i;
                    break;
                }
            }
        }
    }

    if (seg_idx == null) return error.EINVAL;

    // Unmap pages
    const result = proc.user_vmm.munmap(virt_addr, size);
    if (result != 0) return error.EINVAL;

    // Update segment metadata
    {
        const held = shm_lock.acquire();
        defer held.release();

        const seg = &segments[seg_idx.?];
        if (seg.attach_count > 0) {
            seg.attach_count -= 1;
        }
        seg.lpid = proc.pid;
        seg.dtime = getCurrentTime();

        // If marked for deletion and no more attachments, free resources
        if (seg.marked_for_deletion and seg.attach_count == 0) {
            if (seg.phys_pages) |phys| {
                pmm.freePages(phys, seg.num_pages);
            }
            seg.in_use = false;
        }
    }
}

pub fn shmctl(id: u32, cmd: i32, buf_ptr: usize, proc: *const process.Process) !usize {
    const idx = ipc_perm.idToIndex(id);
    const seq = ipc_perm.idToSeq(id);

    if (idx >= SHMMNI) return error.EINVAL;

    const held = shm_lock.acquire();
    defer held.release();

    const seg = &segments[idx];
    if (!seg.in_use or seg.perm.seq != seq) return error.EINVAL;

    switch (cmd) {
        IPC_STAT => {
            // Check read permission
            if (!ipc_perm.checkAccess(&seg.perm, proc, .read)) {
                return error.EACCES;
            }

            // Fill ShmidDs structure
            const ds = ShmidDs{
                .shm_perm = .{
                    .key = seg.perm.key,
                    .uid = seg.perm.uid,
                    .gid = seg.perm.gid,
                    .cuid = seg.perm.cuid,
                    .cgid = seg.perm.cgid,
                    .mode = seg.perm.mode,
                    .seq = seg.perm.seq,
                },
                .shm_segsz = seg.size,
                .shm_atime = seg.atime,
                .shm_dtime = seg.dtime,
                .shm_ctime = seg.ctime,
                .shm_cpid = seg.cpid,
                .shm_lpid = seg.lpid,
                .shm_nattch = seg.attach_count,
            };

            // Copy to userspace
            const uptr = user_mem.UserPtr.from(buf_ptr);
            uptr.writeValue(ds) catch return error.EFAULT;

            return 0;
        },

        IPC_SET => {
            // Check owner/creator permission
            if (!ipc_perm.isOwnerOrCreator(&seg.perm, proc.euid)) {
                return error.EPERM;
            }

            // Read ShmidDs from userspace
            const uptr = user_mem.UserPtr.from(buf_ptr);
            const ds = uptr.readValue(ShmidDs) catch return error.EFAULT;

            // Update permissions
            seg.perm.uid = ds.shm_perm.uid;
            seg.perm.gid = ds.shm_perm.gid;
            seg.perm.mode = ds.shm_perm.mode & 0o777;
            seg.ctime = getCurrentTime();

            return 0;
        },

        IPC_RMID => {
            // Check owner/creator permission
            if (!ipc_perm.isOwnerOrCreator(&seg.perm, proc.euid)) {
                return error.EPERM;
            }

            if (seg.attach_count == 0) {
                // No attachments - free immediately
                if (seg.phys_pages) |phys| {
                    pmm.freePages(phys, seg.num_pages);
                }
                seg.in_use = false;
            } else {
                // Mark for delayed deletion
                seg.marked_for_deletion = true;
                seg.key = -1; // Remove from key lookup
            }

            return 0;
        },

        else => return error.EINVAL,
    }
}
