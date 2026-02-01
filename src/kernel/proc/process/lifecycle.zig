const std = @import("std");
const heap = @import("heap");
const console = @import("console");
const fd_mod = @import("fd");
const framebuffer = @import("framebuffer");
const virt_pci = @import("virt_pci");

const user_vmm_mod = @import("user_vmm");
const vmm = @import("vmm");
const pmm = @import("pmm");
const hal = @import("hal");
const sched = @import("sched");
const uapi = @import("uapi");
const aslr = @import("aslr");
const types = @import("types.zig");
const manager = @import("manager.zig");

const Process = types.Process;
const UserVmm = user_vmm_mod.UserVmm;

// =============================================================================
// Process Creation
// =============================================================================

/// Create a new process with fresh resources
///
/// Allocates a new PID, file descriptor table (with stdio), and address space.
/// If `parent` is provided, the new process is added as a child.
///
/// Returns error.WeakEntropy if ASLR cannot generate secure offsets (no hardware RNG).
pub fn createProcess(parent: ?*Process) !*Process {
    const alloc = heap.allocator();

    // Generate ASLR offsets for this process
    // SECURITY: This will fail if entropy is weak (per CLAUDE.md "Fail Secure" policy)
    const aslr_offsets = aslr.generateOffsets() catch |err| {
        console.err("Process: Failed to generate ASLR offsets: {}", .{err});
        return error.OutOfMemory; // Map to a standard error for callers
    };

    // Create file descriptor table
    const fd_table = try fd_mod.createFdTable();
    errdefer fd_mod.destroyFdTable(fd_table);

    // Pre-populate stdin/stdout/stderr
    // Std FDs are now created by the caller (init_proc.zig) or copied via fork


    // Create user address space with randomized mmap base
    const user_vmm = try UserVmm.initWithMmapBase(aslr_offsets.mmap_start);
    errdefer user_vmm.deinit();
    console.debug("Process: Created user_vmm at {*} (mmap_base={x})", .{ user_vmm, aslr_offsets.mmap_start });

    // Allocate process struct
    const proc = try alloc.create(Process);
    proc.* = Process{
        .pid = manager.allocatePid(),
        .pgid = 0, // Set below
        .sid = 0,  // Set below
        .parent = null,
        .first_child = null,
        .next_sibling = null,
        .state = .Running,
        .exit_status = 0,
        .fd_table = fd_table,
        .user_vmm = user_vmm,
        .cr3 = user_vmm.pml4_phys,
        .refcount = std.atomic.Value(u32).init(1),
        .heap_start = 0,
        .heap_break = 0,
        .capabilities = .{},
        .uid = 0,
        .gid = 0,
        .euid = 0,
        .egid = 0,
        .cwd = [_]u8{0} ** uapi.abi.MAX_PATH,
        .cwd_len = 1,
        .aslr_offsets = aslr_offsets,
    };

    // Initialize pgid/sid
    proc.pgid = proc.pid;
    proc.sid = proc.pid;

    // Initialize CWD to "/"
    proc.cwd[0] = '/';

    // Map VDSO
    {
        const vdso = @import("vdso");
        const base = vdso.map(proc) catch |err| blk: {
            console.warn("Process: Failed to map VDSO: {}", .{err});
            break :blk 0;
        };
        proc.vdso_base = base;
    }

    // Add to parent's children list
    if (parent) |p| {
        p.addChild(proc);
    }

    _ = manager.process_count.fetchAdd(1, .monotonic);
    console.debug("Process: Created pid={} (parent={})", .{
        proc.pid,
        if (parent) |p| p.pid else 0,
    });

    return proc;
}

/// Fork a process - create child with copied address space and FDs
///
/// Performs a deep copy of the parent's resources:
/// - File Descriptor Table (dup)
/// - User Address Space (copy pages, no COW yet)
/// - Heap state
///
/// The new process is added as a child of the parent.
pub fn forkProcess(parent: *Process) !*Process {
    const alloc = heap.allocator();

    // Duplicate file descriptor table
    const child_fd_table = try parent.fd_table.clone();
    errdefer fd_mod.destroyFdTable(child_fd_table);

    // Copy address space (full copy for MVP, CoW would be optimization)
    const child_vmm = try copyUserVmm(parent.user_vmm);
    errdefer child_vmm.deinit();

    // Allocate child process struct
    const child = try alloc.create(Process);
    child.* = Process{
        .refcount = std.atomic.Value(u32).init(1),
        .pid = manager.allocatePid(),
        .pgid = parent.pgid,
        .sid = parent.sid,
        .parent = null, // Set by addChild
        .first_child = null,
        .next_sibling = null,
        .state = .Running,
        .exit_status = 0,
        .fd_table = child_fd_table,
        .user_vmm = child_vmm,
        .cr3 = child_vmm.pml4_phys,
        .heap_start = parent.heap_start,
        .heap_break = parent.heap_break,
        .capabilities = try parent.capabilities.clone(alloc),
        .uid = parent.uid,
        .gid = parent.gid,
        .euid = parent.euid,
        .egid = parent.egid,
        // SECURITY: Child starts with zero DMA allocations.
        // While child inherits DmaCapability, it gets its own allocation counter.
        // This prevents the fork-multiply attack where repeated forks would allow
        // exceeding the intended DMA limit (N forks * max_pages).
        .dma_allocated_pages = 0,
        .cwd = parent.cwd,
        .cwd_len = parent.cwd_len,
        .vdso_base = parent.vdso_base,
        .umask = parent.umask,
        // Fork inherits parent's ASLR layout (same address space)
        .aslr_offsets = parent.aslr_offsets,
    };

    // Add to parent's children list
    parent.addChild(child);

    _ = manager.process_count.fetchAdd(1, .monotonic);
    console.info("Process: Forked pid={} from parent pid={}", .{ child.pid, parent.pid });

    return child;
}

/// Copy a UserVmm (for fork) - creates new address space with copied pages
fn copyUserVmm(src: *UserVmm) !*UserVmm {
    // Create new address space with same mmap base (fork inherits ASLR layout)
    const dst = try UserVmm.initWithMmapBase(src.mmap_base);
    errdefer dst.deinit();

    const cleanupMappedRange = struct {
        fn call(dst_vmm: *UserVmm, virt_start: u64, phys_start: u64, page_count: usize) void {
            var idx: usize = 0;
            while (idx < page_count) : (idx += 1) {
                const virt = virt_start + idx * pmm.PAGE_SIZE;
                vmm.unmapPage(dst_vmm.pml4_phys, virt) catch {};
            }
            pmm.freePages(phys_start, page_count);
        }
    }.call;

    // Copy each VMA
    var vma = src.vma_head;
    while (vma) |v| {
        const page_count = v.pageCount();
        const page_flags = v.toPageFlags();

        // Handle MAP_DEVICE VMAs specially - share the same physical memory
        // This is used for framebuffer and other MMIO regions that should
        // point to the same hardware in parent and child
        if ((v.flags & user_vmm_mod.MAP_DEVICE) != 0) {
            // Map the same physical pages (shared hardware mapping)
            var i: usize = 0;
            while (i < page_count) : (i += 1) {
                const src_virt = v.start + i * pmm.PAGE_SIZE;
                if (vmm.translate(src.pml4_phys, src_virt)) |src_phys| {
                    // Map same physical address in child - shared device memory
                    vmm.mapPage(dst.pml4_phys, src_virt, src_phys, page_flags) catch {
                        // Cleanup partial mappings
                        var j: usize = 0;
                        while (j < i) : (j += 1) {
                            const virt = v.start + j * pmm.PAGE_SIZE;
                            vmm.unmapPage(dst.pml4_phys, virt) catch {};
                        }
                        return error.OutOfMemory;
                    };
                }
            }

            // Create VMA in destination (same flags including MAP_DEVICE)
            const dst_vma = dst.createVma(v.start, v.end, v.prot, v.flags) catch {
                // Cleanup mappings on VMA alloc failure
                var cleanup_idx: usize = 0;
                while (cleanup_idx < page_count) : (cleanup_idx += 1) {
                    const virt = v.start + cleanup_idx * pmm.PAGE_SIZE;
                    vmm.unmapPage(dst.pml4_phys, virt) catch {};
                }
                return error.OutOfMemory;
            };
            dst.insertVma(dst_vma);
            dst.total_mapped += v.size();

            vma = v.next;
            continue;
        }

        // Normal VMA: allocate new physical pages and copy data
        const phys_pages = pmm.allocPages(page_count) orelse {
            return error.OutOfMemory;
        };

        // Copy data from source pages to destination pages
        const src_pages = v.start;
        var i: usize = 0;
        while (i < page_count) : (i += 1) {
            const src_virt = src_pages + i * pmm.PAGE_SIZE;
            const dst_phys = phys_pages + i * pmm.PAGE_SIZE;

            // Get source physical address
            if (vmm.translate(src.pml4_phys, src_virt)) |src_phys| {
                // Copy page data using HHDM mapping
                const src_ptr: [*]const u8 = hal.paging.physToVirt(src_phys);
                const dst_ptr: [*]u8 = hal.paging.physToVirt(dst_phys);
                hal.mem.copy(dst_ptr, src_ptr, pmm.PAGE_SIZE);
            } else {
                // Source page not mapped - zero the destination
                const dst_ptr: [*]u8 = hal.paging.physToVirt(dst_phys);
                hal.mem.fill(dst_ptr, 0, pmm.PAGE_SIZE);
            }
        }

        // Map pages in destination address space
        vmm.mapRange(dst.pml4_phys, v.start, phys_pages, v.size(), page_flags) catch {
            cleanupMappedRange(dst, v.start, phys_pages, page_count);
            return error.OutOfMemory;
        };

        // Create VMA in destination
        const dst_vma = dst.createVma(v.start, v.end, v.prot, v.flags) catch {
            cleanupMappedRange(dst, v.start, phys_pages, page_count);
            return error.OutOfMemory;
        };
        dst.insertVma(dst_vma);
        dst.total_mapped += v.size();

        vma = v.next;
    }

    return dst;
}

// =============================================================================
// Process Termination
// =============================================================================

/// Exit the current process/thread with the given status.
pub fn exit(status: i32) noreturn {
    if (sched.getCurrentThread()) |curr| {
        if (curr.process) |proc_opaque| {
            const proc: *Process = @ptrCast(@alignCast(proc_opaque));

            // Check if this is the last thread WITHOUT decrementing yet
            const is_last_thread = blk: {
                const REFCOUNT_MASK: u32 = 0x7FFFFFFF;
                const current = proc.refcount.load(.acquire);
                const thread_count = current & REFCOUNT_MASK;
                break :blk thread_count == 1;
            };

            if (is_last_thread) {
                // Last thread exiting - process becomes Zombie
                // Do NOT unref yet - wait4() will do that when reaping
                proc.exitWithStatus(status);
            } else {
                // Other threads remain - decrement refcount for this thread
                _ = proc.unref();
                console.debug("Thread: Exiting thread (pid={}, tid={})", .{ proc.pid, curr.tid });
            }
        }
    }

    sched.exitWithStatus(status);
    unreachable;
}

pub fn refProcess(self: *Process) void {
    self.ref();
}

/// Destroy a process and free all resources
/// Process must be in Zombie or Dead state
pub fn destroyProcess(proc: *Process) void {
    const alloc = heap.allocator();

    console.debug("Process: Destroying pid={}", .{proc.pid});
    proc.state = .Dead;

    // Release framebuffer ownership if this process owned it.
    // This prevents resource leaks when a display server crashes or exits.
    framebuffer.releaseOwnership(proc.pid);

    // Free any virtual PCI devices owned by this process.
    // This releases BAR backing memory and event ring pages.
    virt_pci.cleanupByPid(proc.pid);

    // Reparent children to init (PID 1) per POSIX semantics
    if (proc.first_child != null) {
        const held = sched.process_tree_lock.acquireWrite();
        defer held.release();

        const init_opt = manager.init_process;

        if (init_opt) |init| {
            if (init != proc) {
                var child = proc.first_child;
                while (child) |c| {
                    const next = c.next_sibling;
                    c.next_sibling = null;
                    init.addChildLocked(c); // using method from types.zig
                    child = next;
                }
                proc.first_child = null;
            } else {
                // Destroying init itself
                var child = proc.first_child;
                while (child) |c| {
                    const next = c.next_sibling;
                    c.parent = null;
                    c.next_sibling = null;
                    child = next;
                }
                proc.first_child = null;
            }
        } else {
            // Orphan children (no init)
            var child = proc.first_child;
            while (child) |c| {
                const next = c.next_sibling;
                c.parent = null;
                c.next_sibling = null;
                child = next;
            }
            proc.first_child = null;
        }
    }

    // Free file descriptor table
    fd_mod.destroyFdTable(proc.fd_table);

    // Free user address space
    proc.user_vmm.deinit();

    // Free capabilities
    proc.capabilities.deinit(alloc);

    // Free process struct
    alloc.destroy(proc);

    // Decrement process count
    while (true) {
        const current = manager.process_count.load(.acquire);
        if (current == 0) break;
        if (manager.process_count.cmpxchgWeak(current, current - 1, .release, .monotonic) == null) {
            break;
        }
    }
}
