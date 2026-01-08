const std = @import("std");
const hal = @import("hal");
const list = @import("list");
const capabilities = @import("capabilities");
const ipc_msg = @import("ipc_msg");
const fd_mod = @import("fd");
const user_vmm_mod = @import("user_vmm");
const aslr = @import("aslr");
const uapi = @import("uapi");
const sched = @import("sched"); // For Thread and Locks
const console = @import("console");

const FdTable = fd_mod.FdTable;
const UserVmm = user_vmm_mod.UserVmm;

/// Process State
pub const ProcessState = enum(u8) {
    /// Process is running or runnable
    Running,
    /// Process has exited but not yet reaped by parent
    Zombie,
    /// Process has been reaped and resources freed
    Dead,
};

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
                    hal.cpu.pause();
                } else {
                    std.Thread.yield() catch {};
                }
            }
            return .{ .lock = self, .irq_state = irq_state };
        }
    };

    /// Maximum messages per mailbox to prevent memory exhaustion
    pub const MAX_MAILBOX_LEN: usize = 1024;

    /// CWD lock type (lightweight spinlock)
    pub const CwdLock = struct {
        locked: std.atomic.Value(u32) = .{ .raw = 0 },

        pub const Held = struct {
            lock: *CwdLock,
            irq_state: bool,
            pub fn release(h: Held) void {
                h.lock.locked.store(0, .release);
                if (h.irq_state) hal.cpu.enableInterrupts();
            }
        };

        pub fn acquire(self: *CwdLock) Held {
            const hal_cpu = hal.cpu;
            const irq_state = hal_cpu.interruptsEnabled();
            hal_cpu.disableInterrupts();
            while (true) {
                if (self.locked.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) break;
                if (@import("builtin").os.tag == .freestanding) {
                    hal.cpu.pause();
                } else {
                    std.Thread.yield() catch {};
                }
            }
            return .{ .lock = self, .irq_state = irq_state };
        }
    };

    /// Lock for mailbox/IPC state
    mailbox_lock: MailboxLock = .{},

    /// IPC Message Queue
    mailbox: list.IntrusiveDoublyLinkedList(ipc_msg.KernelMessage) = .{},
    /// Number of queued IPC messages (bounded for DoS protection)
    mailbox_len: usize = 0,

    /// Thread waiting for a message (if any)
    msg_waiter: ?*sched.Thread = null,
    /// Unique process identifier
    pid: u32,
    /// Process Group ID
    pgid: u32,
    /// Session ID
    sid: u32,

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

    /// Capabilities granted to this process
    ///
    /// SECURITY INVARIANT: Capabilities are IMMUTABLE after process creation.
    /// They are set once during init_proc/spawn and cloned (to a new list) during fork.
    /// The parent's capability list is never modified by fork.
    ///
    /// This invariant allows lock-free iteration in has*Capability() functions.
    /// If dynamic capability modification is ever added (e.g., cap_grant syscall),
    /// a reader-writer lock MUST be added to prevent TOCTOU races during iteration.
    capabilities: std.ArrayListUnmanaged(capabilities.Capability) = .{},

    /// SECURITY: Cumulative DMA pages allocated by this process.
    dma_allocated_pages: u32 = 0,

    /// SECURITY: Cumulative IOMMU DMA bytes allocated by this process.
    iommu_allocated_bytes: u64 = 0,

    /// Current Working Directory
    cwd: [uapi.abi.MAX_PATH]u8,
    cwd_len: usize,
    /// SECURITY: Lock for CWD access to prevent races between chdir and openat
    cwd_lock: CwdLock = .{},



    /// VDSO Base Address (ASLR)
    vdso_base: u64 = 0,

    /// ASLR offsets for stack, PIE, mmap, heap (per-process)
    aslr_offsets: aslr.AslrOffsets = .{},

    /// Per-process file creation mask
    umask: u32 = 0o022,

    /// SECURITY: Lock for credential fields (uid/gid/euid/egid/suid/sgid).
    /// Required to prevent TOCTOU races where concurrent setuid/setgid calls
    /// could observe inconsistent credential state during permission checks.
    /// Similar to Linux's cred_guard_mutex.
    cred_lock: CwdLock = .{},

    /// User and group identity (Linux-compatible uid/gid)
    uid: u32 = 0,
    gid: u32 = 0,
    euid: u32 = 0,
    egid: u32 = 0,
    /// Saved set-user-ID and set-group-ID (for setresuid/setresgid)
    suid: u32 = 0,
    sgid: u32 = 0,

    /// Supplementary group IDs (POSIX supplementary groups)
    /// NGROUPS_MAX is typically 32 on Linux; we use 16 for simplicity
    supplementary_groups: [16]u32 = [_]u32{0} ** 16,
    supplementary_groups_count: u8 = 0,

    /// Resource limits (DoS protection)
    /// Maximum virtual address space size (default 256 MB)
    rlimit_as: u64 = 256 * 1024 * 1024,
    /// Current resident set size (tracked for enforcement)
    rss_current: u64 = 0,

    // Methods for hierarchy management that operate directly on state
    // Moved here to allow simple imports

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
    pub fn hasAnyChildren(self: *Process) bool {
        const held = sched.process_tree_lock.acquireRead();
        defer held.release();
        return self.first_child != null;
    }

    /// Check if process has any non-zombie children matching PID
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
    pub fn unref(self: *Process) bool {
        const EXECVE_IN_PROGRESS_BIT: u32 = 0x80000000;
        const REFCOUNT_MASK: u32 = ~EXECVE_IN_PROGRESS_BIT;

        while (true) {
            const current = self.refcount.load(.acquire);
            const thread_count = current & REFCOUNT_MASK;

            if (thread_count == 0) {
                 // internal panic if debugging available, or just loop
                 @panic("Process: unref on zero refcount");
            }

            const new_value = (current & EXECVE_IN_PROGRESS_BIT) | (thread_count - 1);

            if (self.refcount.cmpxchgWeak(current, new_value, .release, .monotonic) == null) {
                return thread_count == 1;
            }
        }
    }

    /// Transition to zombie state
    pub fn exitWithStatus(self: *Process, status: i32) void {
        self.exit_status = status;
        self.state = .Zombie;
        // console import needed? types.zig didn't import console initially?
        // Let's check imports.
    }

    // =========================================================================
    // Capability Checks
    // =========================================================================

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

    /// Check if process has MMIO capability
    pub fn hasMmioCapability(self: *Process, phys_addr: u64, size: u64) bool {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .Mmio => |mmio_cap| {
                    const req_end = phys_addr +| size;
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

    /// Check if process has display server capability
    /// Display server capability grants framebuffer access and input routing
    pub fn hasDisplayServerCapability(self: *Process) bool {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .DisplayServer => |ds_cap| {
                    if (ds_cap.owns_framebuffer) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// Check if process has DMA memory capability
    pub fn hasDmaCapability(self: *Process, page_count: u32) bool {
        const new_total = @addWithOverflow(self.dma_allocated_pages, page_count);
        if (new_total[1] != 0) return false;

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

    /// Get the maximum DMA pages allowed by capability.
    /// Returns 0 if no DmaMemory capability exists.
    /// Used for atomic reservation pattern to prevent TOCTOU races.
    pub fn getDmaCapabilityLimit(self: *Process) u32 {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .DmaMemory => |dma_cap| return dma_cap.max_pages,
                else => {},
            }
        }
        return 0;
    }

    /// Get IOMMU DMA capability for a specific device
    /// Returns the capability if found, null otherwise
    pub fn getIommuDmaCapability(self: *Process, bus: u8, device: u5, func: u3) ?capabilities.IommuDmaCapability {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .IommuDma => |iommu_cap| {
                    if (iommu_cap.bus == bus and iommu_cap.device == device and iommu_cap.func == func) {
                        return iommu_cap;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    /// Check if process has PCI config space capability
    pub fn hasPciConfigCapability(self: *Process, bus: u8, device: u5, func: u3) bool {
        return self.getPciConfigCapability(bus, device, func) != null;
    }

    /// Get PCI config space capability for a device (returns null if not found)
    /// SECURITY: Use this to check allow_unsafe flag before writing restricted registers
    pub fn getPciConfigCapability(self: *Process, bus: u8, device: u5, func: u3) ?capabilities.PciConfigCapability {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .PciConfig => |pci_cap| {
                    if (pci_cap.bus == bus and pci_cap.device == device and pci_cap.func == func) {
                        return pci_cap;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    /// Check if process has input injection capability
    pub fn hasInputInjectionCapability(self: *Process) bool {
        return self.getInputInjectionCapability() != null;
    }

    /// Get input injection capability if present
    /// SECURITY: Use this to access rate limiting and device filtering settings
    pub fn getInputInjectionCapability(self: *Process) ?capabilities.InputInjectionCapability {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .InputInjection => |input_cap| return input_cap,
                else => {},
            }
        }
        return null;
    }

    /// Check if process has file capability
    pub fn hasFileCapability(self: *Process, path: []const u8, op: u8) bool {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .File => |file_cap| {
                    if (file_cap.allows(path, op)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// Check if process has SetUid capability
    pub fn hasSetUidCapability(self: *Process, target_uid: u32) bool {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .SetUid => |setuid_cap| {
                    if (setuid_cap.allows(target_uid)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// Check if process has SetGid capability
    pub fn hasSetGidCapability(self: *Process, target_gid: u32) bool {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .SetGid => |setgid_cap| {
                    if (setgid_cap.allows(target_gid)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// Check if process has hypervisor capability
    pub fn hasHypervisorCapability(self: *Process) bool {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .Hypervisor => return true,
                else => {},
            }
        }
        return false;
    }

    /// Get hypervisor capability if present
    pub fn getHypervisorCapability(self: *Process) ?capabilities.HypervisorCapability {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .Hypervisor => |hv_cap| return hv_cap,
                else => {},
            }
        }
        return null;
    }

    /// Check if process is member of a group (egid or supplementary)
    /// Used for POSIX permission checking
    pub fn isGroupMember(self: *const Process, gid: u32) bool {
        // Check primary effective group
        if (self.egid == gid) return true;

        // Check supplementary groups
        for (self.supplementary_groups[0..self.supplementary_groups_count]) |sg| {
            if (sg == gid) return true;
        }

        return false;
    }

    /// Check if process has network configuration capability for given interface
    pub fn hasNetConfigCapability(self: *Process, iface_idx: usize) bool {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .NetConfig => |net_cap| {
                    if (net_cap.allowsInterface(iface_idx)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// Get network config capability if present and allowed for interface
    pub fn getNetConfigCapability(self: *Process, iface_idx: usize) ?capabilities.NetConfigCapability {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .NetConfig => |net_cap| {
                    if (net_cap.allowsInterface(iface_idx)) return net_cap;
                },
                else => {},
            }
        }
        return null;
    }

    /// Check if process has raw socket capability (CAP_NET_RAW equivalent).
    /// Required for creating SOCK_RAW sockets for ICMP, packet crafting, etc.
    pub fn hasNetRawCapability(self: *Process) bool {
        for (self.capabilities.items) |cap| {
            switch (cap) {
                .NetRaw => return true,
                else => {},
            }
        }
        return false;
    }
};
