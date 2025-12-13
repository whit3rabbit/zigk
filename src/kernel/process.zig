// Process Management
//
// Implements Unix-style process abstraction for fork/execve/wait semantics.
// Each process owns:
//   - File descriptor table (shared FDs across threads)
//   - Virtual address space (UserVmm with VMA tracking)
//   - Process hierarchy (parent/children for wait4)
//
// Design:
//   - Process owns resources, Thread executes code
//   - One main thread per process for MVP (multi-threading in future)
//   - fork() copies address space and FDs
//   - execve() replaces address space with new ELF
//   - exit() transitions to zombie, wait4() reaps

const std = @import("std");
const heap = @import("heap");
const console = @import("console");
const fd_mod = @import("fd");
const devfs = @import("devfs");
const user_vmm_mod = @import("user_vmm");
const vmm = @import("vmm");
const pmm = @import("pmm");
const hal = @import("hal");
const sched = @import("sched");
const uapi = @import("uapi");

const FdTable = fd_mod.FdTable;
const UserVmm = user_vmm_mod.UserVmm;
const Errno = uapi.errno.Errno;

// =============================================================================
// Process State
// =============================================================================

pub const ProcessState = enum(u8) {
    /// Process is running or runnable
    Running,
    /// Process has exited but not yet reaped by parent
    Zombie,
    /// Process has been reaped and resources freed
    Dead,
};

// =============================================================================
// Process Structure
// =============================================================================

/// Process - owns resources and process hierarchy
pub const Process = struct {
    /// Unique process identifier
    pid: u32,

    /// Parent process (null for init)
    parent: ?*Process,

    /// First child process (head of children list)
    first_child: ?*Process,

    /// Next sibling (for parent's children list)
    next_sibling: ?*Process,

    /// Process state
    state: ProcessState,

    /// Exit status (valid when state == Zombie)
    exit_status: i32,

    /// File descriptor table (shared by threads in this process)
    fd_table: *FdTable,

    /// Virtual address space manager
    user_vmm: *UserVmm,

    /// Page table root (CR3 value)
    cr3: u64,

    /// Reference count (for multi-threaded processes)
    refcount: u32,

    /// Heap management
    heap_start: u64,
    heap_break: u64,

    /// Resource limits (DoS protection)
    /// Maximum virtual address space size (default 256 MB)
    rlimit_as: u64 = 256 * 1024 * 1024,
    /// Current resident set size (tracked for enforcement)
    rss_current: u64 = 0,

    // =========================================================================
    // Process Hierarchy Methods
    // =========================================================================

    /// Add a child process
    pub fn addChild(self: *Process, child: *Process) void {
        child.parent = self;
        child.next_sibling = self.first_child;
        self.first_child = child;
    }

    /// Remove a child from this process's children list
    pub fn removeChild(self: *Process, child: *Process) void {
        child.parent = null;

        if (self.first_child == child) {
            self.first_child = child.next_sibling;
        } else {
            var prev: ?*Process = self.first_child;
            while (prev) |p| {
                if (p.next_sibling == child) {
                    p.next_sibling = child.next_sibling;
                    break;
                }
                prev = p.next_sibling;
            }
        }
        child.next_sibling = null;
    }

    /// Find a zombie child matching target PID
    /// pid = -1: any child, pid > 0: specific child
    pub fn findZombieChild(self: *Process, target_pid: i32) ?*Process {
        var child = self.first_child;
        while (child) |c| {
            if (c.state == .Zombie) {
                if (target_pid == -1) {
                    return c;
                } else if (target_pid > 0 and c.pid == @as(u32, @intCast(target_pid))) {
                    return c;
                }
            }
            child = c.next_sibling;
        }
        return null;
    }

    /// Check if process has any children
    pub fn hasAnyChildren(self: *Process) bool {
        return self.first_child != null;
    }

    /// Check if process has any non-zombie children matching PID
    pub fn hasLivingChildren(self: *Process, target_pid: i32) bool {
        var child = self.first_child;
        while (child) |c| {
            if (c.state != .Zombie) {
                if (target_pid == -1) {
                    return true;
                } else if (target_pid > 0 and c.pid == @as(u32, @intCast(target_pid))) {
                    return true;
                }
            }
            child = c.next_sibling;
        }
        return false;
    }

    // =========================================================================
    // Resource Management
    // =========================================================================

    /// Increment reference count
    pub fn ref(self: *Process) void {
        self.refcount += 1;
    }

    /// Decrement reference count, returns true if process should be freed
    pub fn unref(self: *Process) bool {
        if (self.refcount == 0) {
            console.warn("Process: unref on zero refcount (pid={})", .{self.pid});
            return true;
        }
        self.refcount -= 1;
        return self.refcount == 0;
    }

    /// Transition to zombie state
    pub fn exitWithStatus(self: *Process, status: i32) void {
        self.exit_status = status;
        self.state = .Zombie;

        console.debug("Process: pid={} exited with status {}", .{ self.pid, status });
    }
};

// =============================================================================
// Process ID Allocation
// =============================================================================

var next_pid: u32 = 1; // PID 0 reserved for kernel
var process_count: u32 = 0;

fn allocatePid() u32 {
    const max_attempts = @as(usize, process_count) + 1;
    var attempts: usize = 0;

    while (attempts <= max_attempts) : (attempts += 1) {
        if (next_pid == 0) {
            next_pid = 1;
        }

        const candidate = next_pid;
        next_pid +%= 1;

        if (findProcessByPid(candidate) == null) {
            return candidate;
        }
    }

    console.panic("Process: PID space exhausted", .{});
}

// =============================================================================
// Init Process (PID 1)
// =============================================================================

var init_process: ?*Process = null;

/// Get or create the init process (PID 1)
/// This is the ancestor of all user processes
pub fn getInitProcess() !*Process {
    if (init_process) |init| {
        return init;
    }

    // Create init process
    init_process = try createProcess(null);
    console.info("Process: Created init process (pid={})", .{init_process.?.pid});
    return init_process.?;
}

// =============================================================================
// Process Creation
// =============================================================================

/// Create a new process with fresh resources
pub fn createProcess(parent: ?*Process) !*Process {
    const alloc = heap.allocator();

    // Create file descriptor table
    const fd_table = try fd_mod.createFdTable();
    errdefer fd_mod.destroyFdTable(fd_table);

    // Pre-populate stdin/stdout/stderr
    try devfs.createStdFds(fd_table);

    // Create user address space
    const user_vmm = try UserVmm.init();
    errdefer user_vmm.deinit();

    // Allocate process struct
    const proc = try alloc.create(Process);
    proc.* = Process{
        .pid = allocatePid(),
        .parent = null,
        .first_child = null,
        .next_sibling = null,
        .state = .Running,
        .exit_status = 0,
        .fd_table = fd_table,
        .user_vmm = user_vmm,
        .cr3 = user_vmm.pml4_phys,
        .refcount = 1,
        .heap_start = 0,
        .heap_break = 0,
    };

    // Add to parent's children list
    if (parent) |p| {
        p.addChild(proc);
    }

    process_count += 1;
    console.debug("Process: Created pid={} (parent={})", .{
        proc.pid,
        if (parent) |p| p.pid else 0,
    });

    return proc;
}

/// Fork a process - create child with copied address space and FDs
pub fn forkProcess(parent: *Process) !*Process {
    const alloc = heap.allocator();

    // Duplicate file descriptor table
    const child_fd_table = try parent.fd_table.dup();
    errdefer fd_mod.destroyFdTable(child_fd_table);

    // Copy address space (full copy for MVP, CoW would be optimization)
    const child_vmm = try copyUserVmm(parent.user_vmm);
    errdefer child_vmm.deinit();

    // Allocate child process struct
    const child = try alloc.create(Process);
    child.* = Process{
        .pid = allocatePid(),
        .parent = null, // Set by addChild
        .first_child = null,
        .next_sibling = null,
        .state = .Running,
        .exit_status = 0,
        .fd_table = child_fd_table,
        .user_vmm = child_vmm,
        .cr3 = child_vmm.pml4_phys,
        .refcount = 1,
        .heap_start = parent.heap_start,
        .heap_break = parent.heap_break,
    };

    // Add to parent's children list
    parent.addChild(child);

    process_count += 1;
    console.info("Process: Forked pid={} from parent pid={}", .{ child.pid, parent.pid });

    return child;
}

/// Exit the current process with the given status.
/// Marks the owning Process as Zombie (if present) and delegates
/// the thread teardown to the scheduler.
pub fn exit(status: i32) noreturn {
    if (sched.getCurrentThread()) |curr| {
        if (curr.process) |proc_opaque| {
            const proc: *Process = @ptrCast(@alignCast(proc_opaque));
            proc.exitWithStatus(status);
        }
    }

    sched.exitWithStatus(status);
    unreachable;
}

/// Copy a UserVmm (for fork) - creates new address space with copied pages
fn copyUserVmm(src: *UserVmm) !*UserVmm {
    // Create new address space
    const dst = try UserVmm.init();
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
                @memcpy(dst_ptr[0..pmm.PAGE_SIZE], src_ptr[0..pmm.PAGE_SIZE]);
            } else {
                // Source page not mapped - zero the destination
                const dst_ptr: [*]u8 = hal.paging.physToVirt(dst_phys);
                @memset(dst_ptr[0..pmm.PAGE_SIZE], 0);
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
// Process Destruction
// =============================================================================

/// Destroy a process and free all resources
/// Process must be in Zombie or Dead state
pub fn destroyProcess(proc: *Process) void {
    const alloc = heap.allocator();

    console.debug("Process: Destroying pid={}", .{proc.pid});
    proc.state = .Dead;

    // Reparent children to init (PID 1) per POSIX semantics
    // This prevents zombie leaks when parent exits before children
    if (proc.first_child != null) {
        const init_opt: ?*Process = getInitProcess() catch null;

        // Only reparent if init exists and we're not destroying init itself
        if (init_opt) |init| {
            if (init != proc) {
                var child = proc.first_child;
                while (child) |c| {
                    const next = c.next_sibling;
                    c.next_sibling = null;
                    init.addChild(c);
                    child = next;
                }
                proc.first_child = null;
            } else {
                // Destroying init itself - orphan children (edge case)
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
            // Init not available (early boot) - orphan children
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

    // Free process struct
    alloc.destroy(proc);

    process_count -= 1;
}

// =============================================================================
// Process Queries
// =============================================================================

/// Get current process count
pub fn getProcessCount() u32 {
    return process_count;
}

/// Find process by PID
/// Note: Linear search - optimize if needed
pub fn findProcessByPid(target_pid: u32) ?*Process {
    // Check init process
    if (init_process) |init| {
        if (init.pid == target_pid) {
            return init;
        }
        // Search init's descendants
        return findInTree(init, target_pid);
    }
    return null;
}

fn findInTree(proc: *Process, target_pid: u32) ?*Process {
    var child = proc.first_child;
    while (child) |c| {
        if (c.pid == target_pid) {
            return c;
        }
        if (findInTree(c, target_pid)) |found| {
            return found;
        }
        child = c.next_sibling;
    }
    return null;
}
