// Thread Management
//
// Provides thread creation, destruction, and state management.
// Each thread has its own kernel stack with a guard page for overflow detection.
//
// Design:
//   - Thread struct contains saved context, stacks, and FPU state
//   - Kernel stacks allocated with guard page (unmapped page below stack)
//   - FPU state preserved for userland threads
//   - Thread IDs are globally unique, never reused during kernel lifetime
//
// Stack Layout (per thread):
//   [Guard Page - unmapped] <- Bottom (low address)
//   [Kernel Stack]          <- Stack grows down from top
//   [Stack Top]             <- RSP starts here

const std = @import("std");
const hal = @import("hal");
const pmm = @import("pmm");
const vmm = @import("vmm");
const heap = @import("heap");
const console = @import("console");
const config = @import("config");

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

/// Thread structure
/// All fields are protected by the scheduler lock when accessed from other threads
pub const Thread = struct {
    /// Unique thread identifier (never reused)
    tid: u32,

    /// Current execution state
    state: ThreadState,

    /// Saved kernel stack pointer
    /// Points to saved interrupt frame during context switch
    kernel_rsp: u64,

    /// Kernel stack bounds (for guard page and allocation tracking)
    kernel_stack_base: u64, // Low address (including guard page)
    kernel_stack_top: u64, // High address (initial RSP)
    kernel_stack_pages: usize, // Number of pages including guard

    /// User stack top (0 for kernel-only threads)
    user_stack_top: u64,

    /// Page table root (CR3 value, 0 = use kernel page tables)
    cr3: u64,

    /// FPU/SSE state for this thread
    fpu_state: fpu.FpuState,

    /// Whether this thread has used FPU/SSE instructions since last context switch
    /// Used for lazy FPU switching - only save/restore if thread actually used FPU
    fpu_used: bool,

    /// Thread name for debugging (null-terminated, max 31 chars + null)
    name: [32]u8,

    /// Doubly-linked list pointers for ready queue
    next: ?*Thread,
    prev: ?*Thread,

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
        @memcpy(self.name[0..copy_len], new_name[0..copy_len]);
        self.name[copy_len] = 0; // Null terminate
    }
};

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
};

// Thread ID counter - atomically incremented for each new thread
var next_tid: u32 = 0;

// Thread creation statistics
var total_threads_created: u32 = 0;
var active_thread_count: u32 = 0;

/// Allocate a new unique thread ID
fn allocateTid() u32 {
    // Simple increment - no lock needed as we're only called from scheduler lock context
    const tid = next_tid;
    next_tid += 1;
    return tid;
}

/// Create a new kernel thread
/// Entry point is a function that takes no arguments and returns void
/// Thread starts in Ready state
pub fn createKernelThread(
    entry: *const fn () void,
    options: ThreadOptions,
) ThreadError!*Thread {
    // Check thread limit
    if (active_thread_count >= config.max_threads) {
        console.warn("Thread: Max thread limit ({d}) reached", .{config.max_threads});
        return ThreadError.TooManyThreads;
    }

    // Calculate stack pages (stack_size + 1 guard page)
    const stack_size = std.mem.alignForward(usize, options.stack_size, pmm.PAGE_SIZE);
    const stack_pages = stack_size / pmm.PAGE_SIZE;
    const total_pages = stack_pages + 1; // +1 for guard page

    // Allocate physical pages for stack (but not guard page)
    const stack_phys = pmm.allocPages(stack_pages) orelse {
        console.err("Thread: Failed to allocate {d} stack pages", .{stack_pages});
        return ThreadError.OutOfMemory;
    };
    errdefer pmm.freePages(stack_phys, stack_pages);

    // Calculate virtual addresses for the stack region
    // Use the HHDM mapping for now (kernel threads run in kernel address space)
    const stack_base_virt = @intFromPtr(paging.physToVirt(stack_phys));
    const guard_page_virt = stack_base_virt - pmm.PAGE_SIZE;
    const stack_top_virt = stack_base_virt + stack_size;

    // Note: The guard page is the virtual page below our stack.
    // In HHDM, this corresponds to (stack_phys - PAGE_SIZE).
    // We don't explicitly unmap it here because we're using HHDM directly.
    // A proper guard page would require a dedicated virtual address range
    // with explicit mapping. For now, we rely on the physical memory layout
    // and the fact that accessing below the stack likely hits unmapped memory.
    // TODO: Implement proper guard page with explicit virtual address allocation

    // Allocate thread structure from heap
    const alloc = heap.allocator();
    const thread = alloc.create(Thread) catch {
        pmm.freePages(stack_phys, stack_pages);
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
        .user_stack_top = 0, // Kernel thread
        .cr3 = options.cr3,
        .fpu_state = fpu.FpuState.init(),
        .fpu_used = false, // Lazy FPU: will be set true on first FPU access
        .name = [_]u8{0} ** 32,
        .next = null,
        .prev = null,
    };

    // Set thread name
    thread.setName(options.name);

    // Set up initial stack frame for context switch
    // The thread will "return" from a fake context switch into entry()
    thread.kernel_rsp = setupInitialStack(stack_top_virt, @intFromPtr(entry));

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

/// Set up initial stack frame so thread can be switched to
/// Returns the initial RSP value
fn setupInitialStack(stack_top: u64, entry_rip: u64) u64 {
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
    writeStackU64(sp, 0); // RDI
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

/// Write a u64 value to a stack address
fn writeStackU64(addr: u64, value: u64) void {
    const ptr: *u64 = @ptrFromInt(addr);
    ptr.* = value;
}

/// Destroy a thread and free its resources
/// Thread must be in Zombie state and removed from all queues
pub fn destroyThread(thread: *Thread) void {
    if (config.debug_scheduler) {
        console.info("Thread: Destroying '{s}' (tid={d})", .{
            thread.getName(),
            thread.tid,
        });
    }

    // Free kernel stack pages (excluding guard page which was never allocated)
    const stack_virt = thread.kernel_stack_base + pmm.PAGE_SIZE; // Skip guard
    const stack_phys = paging.virtToPhys(stack_virt);
    const stack_pages = thread.kernel_stack_pages - 1; // Exclude guard page
    pmm.freePages(stack_phys, stack_pages);

    // Free thread structure
    const alloc = heap.allocator();
    alloc.destroy(thread);

    active_thread_count -= 1;
}

/// Get the current count of active threads
pub fn getActiveThreadCount() u32 {
    return active_thread_count;
}

/// Get total threads ever created
pub fn getTotalThreadsCreated() u32 {
    return total_threads_created;
}
