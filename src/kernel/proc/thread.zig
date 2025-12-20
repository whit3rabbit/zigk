//! Thread Management
//!
//! Provides thread creation, destruction, and state management.
//! Each thread has its own kernel stack with a guard page for overflow detection.
//!
//! Design:
//!   - `Thread` struct contains saved context, stacks, and FPU state.
//!   - Kernel stacks allocated with guard page (unmapped page below stack).
//!   - FPU state preserved for userland threads.
//!   - Thread IDs are globally unique, never reused during kernel lifetime.
//!
//! Stack Layout (per thread):
//!   `[Guard Page - unmapped] <- Bottom (low address)`
//!   `[Kernel Stack]          <- Stack grows down from top`
//!   `[Stack Top]             <- RSP starts here`

const std = @import("std");
const hal = @import("hal");
const pmm = @import("pmm");
const vmm = @import("vmm");
const heap = @import("heap");
const console = @import("console");
const config = @import("config");
const kernel_stack = @import("kernel_stack");
const uapi = @import("uapi");

const fpu = hal.fpu;
const paging = hal.paging;

/// Thread execution states
pub const ThreadState = enum(u8) {
    /// Thread is ready to run, waiting in the ready queue
    Ready,
    /// Thread is currently executing on the CPU
    Running,
    /// Thread is blocked waiting for an event (I/O, sleep, lock, etc.)
    Blocked,
    /// Thread has exited but resources not yet reclaimed
    Zombie,
};

/// Futex wakeup reason - distinguishes timeout from normal wakeup
pub const FutexWakeupReason = enum(u8) {
    /// Not waiting on a futex
    none,
    /// Woken by FUTEX_WAKE
    woken,
    /// Woken by timeout expiry
    timeout,
};

/// Thread structure
///
/// Represents an execution context in the kernel.
/// All fields are protected by the scheduler lock when accessed from other threads.
pub const Thread = struct {
    /// Unique thread identifier (never reused)
    tid: u32,

    /// Current execution state
    state: ThreadState,

    /// Saved kernel stack pointer
    /// Points to saved interrupt frame (ISR stack) during context switch.
    /// This is the stack pointer loaded into RSP when this thread is scheduled.
    kernel_rsp: u64,

    /// Kernel stack bounds (for guard page and allocation tracking)
    kernel_stack_base: u64, // Low address (including guard page)
    kernel_stack_top: u64, // High address (initial RSP)
    kernel_stack_pages: usize, // Number of pages including guard

    /// Kernel stack allocation info (for proper cleanup with guard pages)
    /// If use_kernel_stack_allocator is true, this contains the stack slot/phys info
    kernel_stack_info: ?kernel_stack.KernelStack,
    use_kernel_stack_allocator: bool,

    /// User stack top (0 for kernel-only threads)
    user_stack_top: u64,

    /// Page table root (CR3 value, 0 = use kernel page tables)
    cr3: u64,

    /// FPU/SSE state for this thread
    fpu_state: fpu.FpuState,

    /// Whether this thread has used FPU/SSE instructions since last context switch
    /// Used for lazy FPU switching - only save/restore if thread actually used FPU
    fpu_used: bool,

    /// FS segment base for Thread Local Storage (TLS)
    /// Set via arch_prctl(ARCH_SET_FS), restored on context switch
    fs_base: u64,

    /// Number of spinlocks currently held by this thread
    /// Used to detect unsafe yield() calls while holding locks
    lock_depth: u32 = 0,

    /// Thread name for debugging (null-terminated, max 31 chars + null)
    name: [32]u8,

    /// Owning process (for cleanup)
    /// Opaque pointer to avoid circular dependency
    process: ?*anyopaque,

    /// Blocked signals mask
    sigmask: uapi.signal.SigSet,

    /// Pending signals bitmap
    pending_signals: u64,

    /// Signal actions table (index 0 is unused, 1-64 correspond to signals)
    signal_actions: [64]uapi.signal.SigAction,

    /// Alternate signal stack (set via sigaltstack syscall)
    /// Used when SA_ONSTACK flag is set in signal action
    alternate_stack: uapi.signal.StackT = .{ .sp = 0, .flags = 2, .size = 0 }, // SS_DISABLE=2

    /// Doubly-linked list pointers for ready queue
    next: ?*Thread,
    prev: ?*Thread,

    // Process hierarchy (for wait4/fork)

    /// Parent thread (null for init thread)
    parent: ?*Thread,
    /// First child thread (head of child list)
    first_child: ?*Thread,
    /// Next sibling (for child list traversal)
    next_sibling: ?*Thread,
    /// Exit status (set on exit, read by wait4)
    exit_status: i32,
    /// Wake tick for timed sleep (0 = not scheduled)
    wake_time: u64,
    /// Sleep list links (used by scheduler)
    sleep_prev: ?*Thread,
    sleep_next: ?*Thread,

    /// Pending wakeup flag for block()/unblock() synchronization
    /// Set by unblock() if thread hasn't blocked yet; checked/cleared by block()
    /// SECURITY: Prevents TOCTOU race in block() - see sched.zig security comments
    pending_wakeup: bool = false,

    /// Wait4 coordination flag to avoid lost wakeups on child exit
    wait4_waiting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Stopped by signal (SIGSTOP/SIGTSTP/SIGTTIN/SIGTTOU)
    /// Distinguished from normal blocking so SIGCONT can resume only signal-stopped threads
    stopped: bool = false,

    /// CPU affinity mask (0xFFFFFFFF = any CPU, otherwise bitmask of allowed CPUs)
    /// Used for cache locality and NUMA awareness
    cpu_affinity: u32 = 0xFFFFFFFF,

    /// Last CPU this thread ran on (for cache-aware scheduling)
    /// Set during context switch, used to prefer same CPU on next schedule
    last_cpu: u32 = 0,

    /// Address in userspace to clear (zero) and wake (futex) when thread exits.
    /// Used by pthread_join() implementations (CLONE_CHILD_CLEARTID).
    clear_child_tid: u64 = 0,

    // Futex timeout support

    /// Reason for most recent futex wakeup (timeout vs normal wake)
    futex_wakeup_reason: FutexWakeupReason = .none,

    /// Opaque pointer to FutexBucket when waiting with timeout
    /// Used by wakeSleepingThreads to find and remove from wait queue on timeout
    futex_bucket: ?*anyopaque = null,

    /// Wait queue linkage (separate from sleep_next/prev to allow simultaneous membership)
    wait_queue_next: ?*Thread = null,
    wait_queue_prev: ?*Thread = null,

    /// Get thread name as a slice
    pub fn getName(self: *const Thread) []const u8 {
        // Find null terminator
        var len: usize = 0;
        while (len < self.name.len and self.name[len] != 0) : (len += 1) {}
        return self.name[0..len];
    }

    /// Set thread name
    pub fn setName(self: *Thread, new_name: []const u8) void {
        const copy_len = @min(new_name.len, self.name.len - 1);
        hal.mem.copy(self.name[0..copy_len].ptr, new_name[0..copy_len].ptr, copy_len);
        self.name[copy_len] = 0; // Null terminate
    }
};

comptime {
    // FXSAVE/FXRSTOR require 16-byte alignment for the FPU state area
    std.debug.assert(@alignOf(Thread) >= 16);
}

/// Thread creation errors
pub const ThreadError = error{
    OutOfMemory,
    TooManyThreads,
    InvalidEntryPoint,
    StackAllocationFailed,
    PageMappingFailed,
};

/// Thread creation options
pub const ThreadOptions = struct {
    /// Stack size in bytes (will be rounded up to page size)
    stack_size: usize = config.default_stack_size,

    /// Thread name for debugging
    name: []const u8 = "unnamed",

    /// CR3 value for address space (0 = use kernel page tables)
    cr3: u64 = 0,

    /// Priority (reserved for future use)
    priority: u8 = 128,

    /// Initial user stack pointer (for user threads)
    user_stack_top: u64 = 0,

    /// Owning process (optional)
    process: ?*anyopaque = null,
};

// Thread ID counter - atomically incremented for each new thread
var next_tid: u32 = 0;

// Thread creation statistics
var total_threads_created: u32 = 0;
var active_thread_count: u32 = 0;

/// Allocate a new unique thread ID
/// SECURITY: Uses atomic increment to prevent duplicate TIDs when multiple
/// CPUs create threads concurrently (e.g., concurrent fork() syscalls).
fn allocateTid() u32 {
    return @atomicRmw(u32, &next_tid, .Add, 1, .seq_cst);
}

/// Create a new kernel thread
///
/// Allocates a thread structure and a kernel stack.
/// Sets up the initial stack frame to simulate a return from interrupt into `entry`.
/// The thread is added to the global list but not the ready queue (use `sched.addThread`).
///
/// Arguments:
///   entry: Function to execute (must not return)
///   options: Configuration options (name, stack size, etc.)
pub fn createKernelThread(
    entry: *const fn (?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
    options: ThreadOptions,
) ThreadError!*Thread {
    // Check thread limit
    if (active_thread_count >= config.max_threads) {
        console.warn("Thread: Max thread limit ({d}) reached", .{config.max_threads});
        return ThreadError.TooManyThreads;
    }

    // Stack allocation strategy:
    // - If kernel_stack allocator is initialized, use it (proper guard pages)
    // - Otherwise fall back to HHDM (early boot, no guard protection)
    var stack_info: ?kernel_stack.KernelStack = null;
    var guard_page_virt: u64 = undefined;
    var stack_base_virt: u64 = undefined;
    var stack_top_virt: u64 = undefined;
    var total_pages: usize = undefined;
    var use_ks_allocator = false;

    if (kernel_stack.isInitialized()) {
        // Use the proper kernel stack allocator with guard page protection
        const ks = kernel_stack.alloc() catch |err| {
            console.err("Thread: kernel_stack.alloc failed: {}", .{err});
            return ThreadError.OutOfMemory;
        };
        stack_info = ks;
        guard_page_virt = ks.guard_virt;
        stack_base_virt = ks.stack_base;
        stack_top_virt = ks.stack_top;
        total_pages = kernel_stack.STACK_SLOT_PAGES;
        use_ks_allocator = true;
    } else {
        // Fallback: HHDM-based allocation (early boot)
        // NOTE: We still create a proper guard page by unmapping the HHDM page
        const stack_size = std.mem.alignForward(usize, options.stack_size, pmm.PAGE_SIZE);
        const stack_pages = stack_size / pmm.PAGE_SIZE;
        total_pages = stack_pages + 1;

        const stack_phys = pmm.allocPages(stack_pages) orelse {
            console.err("Thread: Failed to allocate {d} stack pages", .{stack_pages});
            return ThreadError.OutOfMemory;
        };
        // Note: In fallback mode, we don't have proper errdefer cleanup
        // since we can't easily undo the allocation if thread creation fails later

        stack_base_virt = @intFromPtr(paging.physToVirt(stack_phys));
        guard_page_virt = stack_base_virt - pmm.PAGE_SIZE;
        stack_top_virt = stack_base_virt + stack_size;

        // Unmap the guard page in HHDM to provide stack overflow protection
        // even during early boot. This page is part of the HHDM linear map
        // so unmapping it creates a hole that will fault on access.
        vmm.unmapPage(vmm.getKernelPml4(), guard_page_virt) catch |err| {
            // NotMapped is expected for fresh allocations - guard was never mapped
            // Other errors are concerning but continue - better to have a thread
            // without guard protection than no thread at all during early boot
            if (err != error.NotMapped) {
                console.warn("Thread: Failed to unmap guard page {x}: {}", .{ guard_page_virt, err });
            }
        };
    }

    // Allocate thread structure from heap
    const alloc = heap.allocator();
    const thread = alloc.create(Thread) catch {
        if (stack_info) |si| {
            kernel_stack.free(si);
        }
        return ThreadError.OutOfMemory;
    };
    errdefer alloc.destroy(thread);

    // Initialize thread structure
    thread.* = Thread{
        .tid = allocateTid(),
        .state = .Ready,
        .kernel_rsp = 0, // Will be set below
        .kernel_stack_base = guard_page_virt,
        .kernel_stack_top = stack_top_virt,
        .kernel_stack_pages = total_pages,
        .kernel_stack_info = stack_info,
        .use_kernel_stack_allocator = use_ks_allocator,
        .user_stack_top = 0, // Kernel thread
        .cr3 = options.cr3,
        .fpu_state = fpu.FpuState.init(),
        .fpu_used = false, // Lazy FPU: will be set true on first FPU access
        .fs_base = 0, // TLS base, set via arch_prctl
        .clear_child_tid = 0,
        .name = [_]u8{0} ** 32,
        .next = null,
        .prev = null,
        .parent = null,
        .first_child = null,
        .next_sibling = null,
        .exit_status = 0,
        .wake_time = 0,
        .sleep_prev = null,
        .sleep_next = null,
        .process = null,
        .sigmask = 0,
        .pending_signals = 0,
        .signal_actions = [_]uapi.signal.SigAction{std.mem.zeroes(uapi.signal.SigAction)} ** 64,
    };

    // Set thread name
    thread.setName(options.name);

    // Set up initial stack frame for context switch
    // The thread will "return" from a fake context switch into entry()
    // Set up initial stack frame for context switch
    // The thread will "return" from a fake context switch into entry()
    thread.kernel_rsp = setupInitialStack(stack_top_virt, @intFromPtr(entry), @intFromPtr(arg));

    // Update statistics
    total_threads_created += 1;
    active_thread_count += 1;

    if (config.debug_scheduler) {
        console.info("Thread: Created '{s}' (tid={d}, stack={x}-{x})", .{
            thread.getName(),
            thread.tid,
            thread.kernel_stack_base,
            thread.kernel_stack_top,
        });
    }

    return thread;
}

/// Create a new user thread
///
/// Similar to kernel thread, but sets up the stack for a return to Ring 3 (User Mode).
/// Requires a valid CR3 (address space) and user stack pointer.
///
/// Arguments:
///   entry: User virtual address of entry point
///   options: Thread options (must include cr3 and user_stack_top)
pub fn createUserThread(
    entry: u64,
    options: ThreadOptions,
) ThreadError!*Thread {
     // Check thread limit
    if (active_thread_count >= config.max_threads) {
        console.warn("Thread: Max thread limit ({d}) reached", .{config.max_threads});
        return ThreadError.TooManyThreads;
    }

    // Stack allocation strategy:
    // - If kernel_stack allocator is initialized, use it (proper guard pages)
    // - Otherwise fall back to HHDM (early boot, no guard protection)
    var stack_info: ?kernel_stack.KernelStack = null;
    var guard_page_virt: u64 = undefined;
    var stack_base_virt: u64 = undefined;
    var stack_top_virt: u64 = undefined;
    var total_pages: usize = undefined;
    var use_ks_allocator = false;

    // Fallback variables for cleanup
    var fallback_stack_phys: u64 = undefined;
    var fallback_stack_pages: usize = 0;

    if (kernel_stack.isInitialized()) {
        const ks = kernel_stack.alloc() catch |err| {
            console.err("Thread: kernel_stack.alloc failed for user thread: {}", .{err});
            return ThreadError.OutOfMemory;
        };
        stack_info = ks;
        guard_page_virt = ks.guard_virt;
        stack_base_virt = ks.stack_base;
        stack_top_virt = ks.stack_top;
        total_pages = kernel_stack.STACK_SLOT_PAGES;
        use_ks_allocator = true;
    } else {
        // Fallback: HHDM-based allocation
        // Note: User threads still need a kernel stack for syscalls/interrupts
        var stack_size = options.stack_size;
        if (stack_size == 0) stack_size = config.default_stack_size;

        const aligned_stack_size = std.mem.alignForward(usize, stack_size, pmm.PAGE_SIZE);
        const stack_pages = aligned_stack_size / pmm.PAGE_SIZE;
        total_pages = stack_pages + 1; // +1 for guard page

        // Allocate physical pages for kernel stack
        const stack_phys = pmm.allocPages(stack_pages) orelse {
            console.err("Thread: Failed to allocate {d} stack pages", .{stack_pages});
            return ThreadError.OutOfMemory;
        };

        fallback_stack_phys = stack_phys;
        fallback_stack_pages = stack_pages;

        // Calculate virtual addresses for kernel stack (HHDM)
        stack_base_virt = @intFromPtr(paging.physToVirt(stack_phys));
        guard_page_virt = stack_base_virt - pmm.PAGE_SIZE;
        stack_top_virt = stack_base_virt + aligned_stack_size;
    }

    // Allocate thread structure
    const alloc = heap.allocator();
    const thread = alloc.create(Thread) catch {
        if (use_ks_allocator) {
            if (stack_info) |si| kernel_stack.free(si);
        } else if (fallback_stack_pages > 0) {
            pmm.freePages(fallback_stack_phys, fallback_stack_pages);
        }
        return ThreadError.OutOfMemory;
    };
    errdefer alloc.destroy(thread);

    // Initialize thread structure
    thread.* = Thread{
        .tid = allocateTid(),
        .state = .Ready,
        .kernel_rsp = 0, // Will be set below
        .kernel_stack_base = guard_page_virt,
        .kernel_stack_top = stack_top_virt, // This is RSP0
        .kernel_stack_pages = total_pages,
        .kernel_stack_info = stack_info,
        .use_kernel_stack_allocator = use_ks_allocator,
        .user_stack_top = options.user_stack_top,
        .cr3 = options.cr3, // Must be provided for user thread
        .fpu_state = fpu.FpuState.init(),
        .fpu_used = false,
        .fs_base = 0, // TLS base, set via arch_prctl
        .clear_child_tid = 0,
        .name = [_]u8{0} ** 32,
        .next = null,
        .prev = null,
        .parent = null,
        .first_child = null,
        .next_sibling = null,
        .exit_status = 0,
        .wake_time = 0,
        .sleep_prev = null,
        .sleep_next = null,
        .process = options.process,
        .sigmask = 0,
        .pending_signals = 0,
        .signal_actions = [_]uapi.signal.SigAction{std.mem.zeroes(uapi.signal.SigAction)} ** 64,
    };

    thread.setName(options.name);

    // Set up initial stack frame for context switch (iretq to user mode)
    thread.kernel_rsp = setupUserStack(stack_top_virt, entry, options.user_stack_top);

    // Update statistics
    total_threads_created += 1;
    active_thread_count += 1;

    if (config.debug_scheduler) {
        console.info("Thread: Created user '{s}' (tid={d}, cr3={x})", .{
            thread.getName(),
            thread.tid,
            thread.cr3,
        });
    }

    return thread;
}

/// Set up initial stack frame for a kernel thread
///
/// Builds a fake interrupt frame on the kernel stack.
/// When the scheduler switches to this thread using `iretq`, the CPU will:
/// 1. Pop CS, RIP, RFLAGS, RSP, SS (privilege level change or not).
/// 2. Jump to `entry_rip` with the specified stack.
///
///   arg: Argument to pass to the thread (passed in RDI)
///
/// Returns the adjusted stack pointer (initial RSP).
fn setupInitialStack(stack_top: u64, entry_rip: u64, arg: u64) u64 {
    var sp = stack_top;

    // Build a fake interrupt frame that matches what isr_common expects
    // When the scheduler switches to this thread, isr_common will pop
    // these values and iretq will jump to entry_rip

    // iretq frame (pushed by CPU on interrupt, popped by iretq)
    sp -= 8;
    writeStackU64(sp, 0x10); // SS (kernel data selector)
    sp -= 8;
    writeStackU64(sp, stack_top - 8); // RSP (we'll use same stack)
    sp -= 8;
    writeStackU64(sp, 0x202); // RFLAGS (IF=1, reserved bit 1 always set)
    sp -= 8;
    writeStackU64(sp, 0x08); // CS (kernel code selector)
    sp -= 8;
    writeStackU64(sp, entry_rip); // RIP (thread entry point)

    // Error code and vector (skipped by isr_common with add $16, %rsp)
    sp -= 8;
    writeStackU64(sp, 0); // error_code (fake)
    sp -= 8;
    writeStackU64(sp, 0); // vector (fake)

    // General purpose registers (matching isr_common push order)
    // rax, rbx, rcx, rdx, rbp, rsi, rdi, r8-r15
    sp -= 8;
    writeStackU64(sp, 0); // RAX
    sp -= 8;
    writeStackU64(sp, 0); // RBX
    sp -= 8;
    writeStackU64(sp, 0); // RCX
    sp -= 8;
    writeStackU64(sp, 0); // RDX
    sp -= 8;
    writeStackU64(sp, 0); // RBP
    sp -= 8;
    writeStackU64(sp, 0); // RSI
    sp -= 8;
    writeStackU64(sp, arg); // RDI (First element of System V ABI)
    sp -= 8;
    writeStackU64(sp, 0); // R8
    sp -= 8;
    writeStackU64(sp, 0); // R9
    sp -= 8;
    writeStackU64(sp, 0); // R10
    sp -= 8;
    writeStackU64(sp, 0); // R11
    sp -= 8;
    writeStackU64(sp, 0); // R12
    sp -= 8;
    writeStackU64(sp, 0); // R13
    sp -= 8;
    writeStackU64(sp, 0); // R14
    sp -= 8;
    writeStackU64(sp, 0); // R15

    return sp;
}

/// Set up initial kernel stack for switching to user mode
fn setupUserStack(kernel_stack_top: u64, entry_rip: u64, user_stack_top: u64) u64 {
    var sp = kernel_stack_top;

    console.debug("setupUserStack: top={x} entry={x} user_sp={x}", .{
        kernel_stack_top, entry_rip, user_stack_top,
    });

    // Build interrupt frame for iretq to Ring 3
    // Stack layout (pushed by CPU on interrupt / expected by iretq):
    // SS (user data)
    // RSP (user stack)
    // RFLAGS
    // CS (user code)
    // RIP (user entry)

    // SS
    sp -= 8;
    const ss_addr = sp;
    writeStackU64(sp, hal.gdt.USER_DATA); // User data selector with RPL 3 already set in GDT module

    // RSP (User Stack)
    sp -= 8;
    writeStackU64(sp, user_stack_top);

    // RFLAGS
    sp -= 8;
    // IF=1 (interrupts enabled), Reserved(1)=1, IOPL=0
    writeStackU64(sp, 0x202);

    // CS
    sp -= 8;
    const cs_addr = sp;
    writeStackU64(sp, hal.gdt.USER_CODE); // User code selector with RPL 3

    // RIP
    sp -= 8;
    writeStackU64(sp, entry_rip);

    // --- End of IRETQ frame ---

    // Now push values that isr_common expects to pop

    // Error code and vector (fake)
    sp -= 8;
    writeStackU64(sp, 0); // error_code
    sp -= 8;
    writeStackU64(sp, 0); // vector

    // General purpose registers
    var i: usize = 0;
    while (i < 15) : (i += 1) { // 15 registers (RAX..R15)
        sp -= 8;
        writeStackU64(sp, 0);
    }

    // Verify the values we wrote by reading them back
    const cs_ptr: *const u64 = @ptrFromInt(cs_addr);
    const ss_ptr: *const u64 = @ptrFromInt(ss_addr);
    console.debug("setupUserStack: CS at {x} = {x} (expect 0x23), SS at {x} = {x} (expect 0x1b)", .{
        cs_addr, cs_ptr.*, ss_addr, ss_ptr.*,
    });
    console.debug("setupUserStack: returning kernel_rsp={x} (frame size={d})", .{
        sp, kernel_stack_top - sp,
    });

    return sp;
}

/// Write a u64 value to a stack address
fn writeStackU64(addr: u64, value: u64) void {
    const ptr: *u64 = @ptrFromInt(addr);
    ptr.* = value;
}

/// Destroy a thread and free its resources
/// Thread must be in Zombie state and removed from all queues
pub fn destroyThread(thread: *Thread) ?*anyopaque {
    if (config.debug_scheduler) {
        console.info("Thread: Destroying '{s}' (tid={d})", .{
            thread.getName(),
            thread.tid,
        });
    }

    // Free kernel stack
    if (thread.use_kernel_stack_allocator) {
        // Use kernel_stack allocator (proper guard page cleanup)
        if (thread.kernel_stack_info) |si| {
            kernel_stack.free(si);
        }
    } else {
        // Legacy HHDM path - free physical pages directly
        const stack_virt = thread.kernel_stack_base + pmm.PAGE_SIZE; // Skip guard
        const stack_phys = paging.virtToPhys(stack_virt);
        const stack_pages = thread.kernel_stack_pages - 1; // Exclude guard page
        pmm.freePages(stack_phys, stack_pages);
    }

    // Capture process pointer before destroying thread
    const proc = thread.process;
    thread.process = null;

    // Free thread structure
    const alloc = heap.allocator();
    alloc.destroy(thread);

    active_thread_count -= 1;
    
    return proc;
}

/// Get the current count of active threads
pub fn getActiveThreadCount() u32 {
    return active_thread_count;
}

/// Get total threads ever created
pub fn getTotalThreadsCreated() u32 {
    return total_threads_created;
}

// =============================================================================
// Process Hierarchy Management (for wait4/fork)
// =============================================================================

/// Add a child thread to a parent's child list
pub fn addChild(parent: *Thread, child: *Thread) void {
    child.parent = parent;
    child.next_sibling = parent.first_child;
    parent.first_child = child;
}

/// Remove a child thread from its parent's child list
pub fn removeChild(parent: *Thread, child: *Thread) void {
    // Clear parent reference
    child.parent = null;

    // Remove from sibling list
    if (parent.first_child == child) {
        // Child is first in list
        parent.first_child = child.next_sibling;
    } else {
        // Find child's predecessor in sibling list
        var prev: ?*Thread = parent.first_child;
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

/// Find a zombie child matching the target PID
/// pid = -1: any child, pid > 0: specific child
pub fn findZombieChild(parent: *Thread, target_pid: i32) ?*Thread {
    var child = parent.first_child;
    while (child) |c| {
        if (c.state == .Zombie) {
            if (target_pid == -1) {
                // Any zombie child
                return c;
            } else if (target_pid > 0 and c.tid == @as(u32, @intCast(target_pid))) {
                // Specific child
                return c;
            }
        }
        child = c.next_sibling;
    }
    return null;
}

/// Check if parent has any living (non-zombie) children
pub fn hasLivingChildren(parent: *Thread, target_pid: i32) bool {
    var child = parent.first_child;
    while (child) |c| {
        if (c.state != .Zombie) {
            if (target_pid == -1) {
                return true;
            } else if (target_pid > 0 and c.tid == @as(u32, @intCast(target_pid))) {
                return true;
            }
        }
        child = c.next_sibling;
    }
    return false;
}

/// Check if parent has any children at all
pub fn hasAnyChildren(parent: *Thread) bool {
    return parent.first_child != null;
}

/// Set thread exit status (called during exit)
pub fn setExitStatus(t: *Thread, status: i32) void {
    t.exit_status = status;
}

/// Wait for a thread to exit (reach Zombie state)
///
/// Blocks the calling thread until the target thread has exited.
/// Uses polling with yield to avoid busy-waiting.
///
/// SAFETY: Caller must ensure:
/// - Target thread is not the calling thread (would deadlock)
/// - Target thread will eventually exit (otherwise blocks forever)
///
/// After join() returns, the thread is in Zombie state and can be
/// destroyed with destroyThread().
pub fn join(t: *Thread) void {
    const sched = @import("sched");

    // Poll for Zombie state, yielding between checks
    while (true) {
        // Atomic load to safely read state from another thread
        const state = @atomicLoad(ThreadState, &t.state, .acquire);
        if (state == .Zombie) {
            break;
        }
        // Yield to give the target thread CPU time to finish
        sched.yield();
    }
}

/// Wait for a thread to exit with a timeout (in scheduler ticks)
///
/// Returns true if thread exited, false if timeout expired.
pub fn joinWithTimeout(t: *Thread, timeout_ticks: u64) bool {
    const sched = @import("sched");
    const start_tick = sched.getTickCount();

    while (true) {
        const state = @atomicLoad(ThreadState, &t.state, .acquire);
        if (state == .Zombie) {
            return true;
        }

        // Check timeout
        const elapsed = sched.getTickCount() - start_tick;
        if (elapsed >= timeout_ticks) {
            return false;
        }

        sched.yield();
    }
}
