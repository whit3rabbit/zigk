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
const ipc_msg = @import("ipc_msg");
const list = @import("list");
const capabilities = @import("capabilities");
const aslr = @import("aslr");
// const sync = @import("sync"); // Removed: Cycle

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
    pub const MailboxLock = struct {
        locked: std.atomic.Value(u32) = .{ .raw = 0 },

        pub const Held = struct {
            lock: *MailboxLock, // Mutable pointer needed for store
            irq_state: bool,
            pub fn release(h: Held) void {
                 h.lock.locked.store(0, .release);
                 if (h.irq_state) hal.cpu.enableInterrupts();
            }
        };

        pub fn acquire(self: *MailboxLock) Held {
             const hal_cpu = hal.cpu;
             const irq_state = hal_cpu.interruptsEnabled();
             hal_cpu.disableInterrupts();
             while (true) {
                 if (self.locked.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) break;
                 // Spin hint
                 if (@import("builtin").os.tag == .freestanding) {
                     asm volatile ("pause"
                         :
                         :
                         : .{ .memory = true }
                     );
                 } else {
                     std.Thread.yield() catch {};
                 }
             }
             return .{ .lock = self, .irq_state = irq_state };
        }
    };

    /// Maximum messages per mailbox to prevent memory exhaustion
    pub const MAX_MAILBOX_LEN: usize = 1024;

    /// Lock for mailbox/IPC state (inlined to avoid cycle)
    mailbox_lock: MailboxLock = .{},

    /// IPC Message Queue
    mailbox: list.IntrusiveDoublyLinkedList(ipc_msg.KernelMessage) = .{},
    /// Number of queued IPC messages (bounded for DoS protection)
    mailbox_len: usize = 0,

    /// Thread waiting for a message (if any)
    msg_waiter: ?*sched.Thread = null,
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
    /// When refcount drops to 0, the process structure is freed.
    refcount: std.atomic.Value(u32),

    /// Heap start address (base of the program break)
    heap_start: u64,
    /// Heap break (current top of the heap)
    heap_break: u64,

    /// Capabilities
    capabilities: std.ArrayListUnmanaged(capabilities.Capability) = .{},

    /// SECURITY: Cumulative DMA pages allocated by this process.
    /// Used to enforce DMA capability limits across multiple allocations.
    /// A process with max_pages=256 cannot exceed 256 total pages at any time.
    dma_allocated_pages: u32 = 0,
    

    /// Current Working Directory
    cwd: [uapi.abi.MAX_PATH]u8,
    cwd_len: usize,

    /// VDSO Base Address (ASLR)
    vdso_base: u64 = 0,

    /// ASLR offsets for stack, PIE, mmap, heap (per-process)
    aslr_offsets: aslr.AslrOffsets = .{},

    /// Per-process file creation mask
    umask: u32 = 0o022,
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
        const held = sched.process_tree_lock.acquireWrite();
        defer held.release();
        self.addChildLocked(child);
    }

    /// Add a child process (Lock must be held by caller)
    pub fn addChildLocked(self: *Process, child: *Process) void {
        child.parent = self;
        child.next_sibling = self.first_child;
        self.first_child = child;
    }

    /// Remove a child from this process's children list
    pub fn removeChild(self: *Process, child: *Process) void {
        const held = sched.process_tree_lock.acquireWrite();
        defer held.release();
        self.removeChildLocked(child);
    }

    /// Remove a child from this process's children list (Lock must be held by caller)
    pub fn removeChildLocked(self: *Process, child: *Process) void {
        child.parent = null;

        if (self.first_child == child) {
            self.first_child = child.next_sibling;
        } else {
            var curr = self.first_child;
            while (curr) |c| {
                if (c.next_sibling == child) {
                    c.next_sibling = child.next_sibling;
                    break;
                }
                curr = c.next_sibling;
            }
        }
        child.next_sibling = null;
    }

    /// Check if target is a child of this process
    pub fn hasChild(self: *Process, target: *Process) bool {
        var child = self.first_child;
        while (child) |c| {
            if (c == target) return true;
            child = c.next_sibling;
        }
        return false;
    }

    /// Find a zombie child matching target PID
    /// pid = -1: any child, pid > 0: specific child
    pub fn findZombieChild(self: *Process, pid_filter: i32) ?*Process {
        const held = sched.process_tree_lock.acquireRead();
        defer held.release();

        var child = self.first_child;
        while (child) |c| {
            // Apply PID filter
            if (pid_filter > 0 and c.pid != @as(u32, @intCast(pid_filter))) {
                child = c.next_sibling;
                continue;
            }

            // Check if zombie
            if (c.state == .Zombie) {
                return c;
            }
            child = c.next_sibling;
        }
        return null;
    }

    /// Check if process has any children
    /// Acquires process_tree_lock to ensure consistent view of child list
    pub fn hasAnyChildren(self: *Process) bool {
        const held = sched.process_tree_lock.acquireRead();
        defer held.release();
        return self.first_child != null;
    }

    /// Check if process has any non-zombie children matching PID
    /// Acquires process_tree_lock to ensure consistent view during iteration
    pub fn hasLivingChildren(self: *Process, target_pid: i32) bool {
        const held = sched.process_tree_lock.acquireRead();
        defer held.release();
        return self.hasLivingChildrenLocked(target_pid);
    }

    /// Check if process has any non-zombie children matching PID (lock must be held)
    fn hasLivingChildrenLocked(self: *Process, target_pid: i32) bool {
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
        _ = self.refcount.fetchAdd(1, .acquire);
    }

    /// Decrement reference count, returns true if process should be freed.
    ///
    /// SECURITY: Uses compare-and-swap to prevent double-free race condition.
    ///
    /// The race occurs when two threads concurrently call unref() with refcount=1:
    /// 1. Thread A: fetchSub returns prev=1, refcount becomes 0
    /// 2. Thread B: fetchSub returns prev=0, refcount wraps to 0xFFFFFFFF
    /// 3. Both threads return true and try to free the process -> DOUBLE FREE
    ///
    /// Using CAS ensures only one thread can successfully decrement 1->0 and get
    /// the "should free" indication. Other concurrent unrefs will either:
    /// - See the new value (0) and panic (correct behavior for bug detection)
    /// - Retry with the correct value (if refcount > 1)
    ///
    /// Note: The high bit (0x80000000) may be set during execve to indicate
    /// "execve in progress". We mask this out when checking the thread count.
    pub fn unref(self: *Process) bool {
        const EXECVE_IN_PROGRESS_BIT: u32 = 0x80000000;
        const REFCOUNT_MASK: u32 = ~EXECVE_IN_PROGRESS_BIT;

        while (true) {
            const current = self.refcount.load(.acquire);
            const thread_count = current & REFCOUNT_MASK;

            if (thread_count == 0) {
                // This should never happen in correct code - indicates a bug
                console.panic("Process: unref on zero refcount (pid={})", .{self.pid});
            }

            const new_value = (current & EXECVE_IN_PROGRESS_BIT) | (thread_count - 1);

            if (self.refcount.cmpxchgWeak(current, new_value, .release, .monotonic) == null) {
                // CAS succeeded - check if this was the last reference
                return thread_count == 1;
            }
            // CAS failed - another thread modified refcount, retry
        }
    }

    /// Transition to zombie state
    pub fn exitWithStatus(self: *Process, status: i32) void {
        self.exit_status = status;
        self.state = .Zombie;

        console.debug("Process: pid={} exited with status {}", .{ self.pid, status });
    }

    // =========================================================================
    // Capability Checks
    // =========================================================================
    // Note: These functions iterate capabilities without synchronization.
    // This is safe because capabilities are immutable after process creation
    // (set only in init_proc.zig). If dynamic capability grants are added,
    // a reader-writer lock must protect these functions and the grant path.

    /// Check if process has interrupt capability
    pub fn hasInterruptCapability(self: *Process, irq: u8) bool {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .Interrupt => |int_cap| {
                    if (int_cap.irq == irq) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// Check if process has IO port capability
    /// SECURITY: Uses saturating addition to prevent integer overflow.
    /// Without this, port=0xFFF0 + len=0x20 would wrap to 0x10, potentially
    /// granting unintended access to low ports (e.g., DMA controller).
    pub fn hasIoPortCapability(self: *Process, port: u16) bool {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .IoPort => |io_cap| {
                    const cap_end = io_cap.port +| io_cap.len; // Saturating add
                    if (port >= io_cap.port and port < cap_end) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// Check if process has MMIO capability for the given physical address range
    pub fn hasMmioCapability(self: *Process, phys_addr: u64, size: u64) bool {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .Mmio => |mmio_cap| {
                    // Check if requested range is fully within granted range
                    const req_end = phys_addr +| size; // Saturating add to prevent overflow
                    const cap_end = mmio_cap.phys_addr +| mmio_cap.size;
                    if (phys_addr >= mmio_cap.phys_addr and req_end <= cap_end) {
                        return true;
                    }
                },
                else => {},
            }
        }
        return false;
    }

    /// Check if process has DMA memory capability for the given page count.
    /// SECURITY: Checks if the new allocation would exceed cumulative limits.
    /// Returns true only if (current_allocated + page_count) <= max_pages.
    pub fn hasDmaCapability(self: *Process, page_count: u32) bool {
        // Calculate new total with overflow check
        const new_total = @addWithOverflow(self.dma_allocated_pages, page_count);
        if (new_total[1] != 0) {
            // Overflow - definitely exceeds any reasonable limit
            return false;
        }

        for (self.capabilities.items) |cap| {
            switch (cap) {
                .DmaMemory => |dma_cap| {
                    if (new_total[0] <= dma_cap.max_pages) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// Check if process has PCI config space capability for the given device
    pub fn hasPciConfigCapability(self: *Process, bus: u8, device: u5, func: u3) bool {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .PciConfig => |pci_cap| {
                    if (pci_cap.bus == bus and pci_cap.device == device and pci_cap.func == func) {
                        return true;
                    }
                },
                else => {},
            }
        }
        return false;
    }

    /// Check if process has input injection capability (keyboard/mouse IPC to kernel)
    pub fn hasInputInjectionCapability(self: *Process) bool {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .InputInjection => return true,
                else => {},
            }
        }
        return false;
    }
};

// =============================================================================
// Process ID Allocation
// =============================================================================

var next_pid: u32 = 1; // PID 0 reserved for kernel
var process_count = std.atomic.Value(u32).init(0);

fn allocatePid() u32 {
    const max_attempts = @as(usize, process_count.load(.monotonic)) + 1;
    var attempts: usize = 0;

    const held = sched.process_tree_lock.acquireWrite();
    defer held.release();

    while (attempts <= max_attempts) : (attempts += 1) {
        if (next_pid == 0) {
            next_pid = 1;
        }

        const candidate = next_pid;
        next_pid +%= 1;

        // findProcessByPidLocked required to avoid deadlock (lock already held)
        if (findProcessByPidLocked(candidate) == null) {
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
///
/// This is the ancestor of all user processes.
/// If it doesn't exist yet, it is created.
/// Init process has no parent (null).
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
///
/// Allocates a new PID, file descriptor table (with stdio), and address space.
/// If `parent` is provided, the new process is added as a child.
pub fn createProcess(parent: ?*Process) !*Process {
    const alloc = heap.allocator();

    // Generate ASLR offsets for this process
    const aslr_offsets = aslr.generateOffsets();

    // Create file descriptor table
    const fd_table = try fd_mod.createFdTable();
    errdefer fd_mod.destroyFdTable(fd_table);

    // Pre-populate stdin/stdout/stderr
    try devfs.createStdFds(fd_table);

    // Create user address space with randomized mmap base
    const user_vmm = try UserVmm.initWithMmapBase(aslr_offsets.mmap_start);
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
        .refcount = std.atomic.Value(u32).init(1),
        .heap_start = 0,
        .heap_break = 0,
        .capabilities = .{},
        .cwd = undefined,
        .cwd_len = 1,
        .aslr_offsets = aslr_offsets,
    };

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

    _ = process_count.fetchAdd(1, .monotonic);
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
        .pid = allocatePid(),
        .parent = null, // Set by addChild
        .first_child = null,
        .next_sibling = null,
        .state = .Running,
        .exit_status = 0,
        .fd_table = child_fd_table,
        .user_vmm = child_vmm,
        .cr3 = child_vmm.pml4_phys,
        .refcount = std.atomic.Value(u32).init(1),
        .heap_start = parent.heap_start,
        .heap_break = parent.heap_break,
        .capabilities = try parent.capabilities.clone(alloc),
        // SECURITY: Child inherits parent's DMA allocation count since it shares
        // the same capability limits. The total across parent+child must not exceed
        // the granted max_pages.
        .dma_allocated_pages = parent.dma_allocated_pages,
        .cwd = parent.cwd,
        .cwd_len = parent.cwd_len,
        .vdso_base = parent.vdso_base,
        .umask = parent.umask,
        // Fork inherits parent's ASLR layout (same address space)
        .aslr_offsets = parent.aslr_offsets,
    };

    // Add to parent's children list
    parent.addChild(child);

    _ = process_count.fetchAdd(1, .monotonic);
    console.info("Process: Forked pid={} from parent pid={}", .{ child.pid, parent.pid });

    return child;
}

/// Exit the current process/thread with the given status.
///
/// Multi-threading:
/// - Decrements process refcount.
/// - If refcount drops to 0 (last thread), transitions process to Zombie.
/// - Otherwise, just exits the thread.
pub fn exit(status: i32) noreturn {
    if (sched.getCurrentThread()) |curr| {
        if (curr.process) |proc_opaque| {
            const proc: *Process = @ptrCast(@alignCast(proc_opaque));

            // Decrement refcount. Returns true if this was the last thread.
            if (proc.unref()) {
                // Last thread exiting - process becomes Zombie
                proc.exitWithStatus(status);
            } else {
                // Other threads remain - just this thread exits
                console.debug("Thread: Exiting thread (pid={}, tid={})", .{proc.pid, curr.tid});
            }
        }
    }

    sched.exitWithStatus(status);
    unreachable;
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
    // Hold lock for entire reparenting operation to prevent concurrent child list modification
    if (proc.first_child != null) {
        const held = sched.process_tree_lock.acquireWrite();
        defer held.release();

        const init_opt: ?*Process = getInitProcess() catch null;

        // Only reparent if init exists and we're not destroying init itself
        if (init_opt) |init| {
            if (init != proc) {
                var child = proc.first_child;
                while (child) |c| {
                    const next = c.next_sibling;
                    c.next_sibling = null;
                    init.addChildLocked(c);
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

    // Free capabilities
    proc.capabilities.deinit(alloc);

    // Free process struct
    alloc.destroy(proc);

    // Decrement process count atomically, preventing underflow via CAS
    while (true) {
        const current = process_count.load(.acquire);
        if (current == 0) break;
        if (process_count.cmpxchgWeak(current, current - 1, .release, .monotonic) == null) {
            break;
        }
    }
}

// =============================================================================
// Process Queries
// =============================================================================

/// Get current process count
pub fn getProcessCount() u32 {
    return process_count.load(.monotonic);
}

/// Find process by PID
/// Note: Linear search - optimize if needed
pub fn findProcessByPid(target_pid: u32) ?*Process {
    const held = sched.process_tree_lock.acquireRead();
    defer held.release();
    return findProcessByPidLocked(target_pid);
}

fn findProcessByPidLocked(target_pid: u32) ?*Process {
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
