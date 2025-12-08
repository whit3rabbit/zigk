// Syscall Handlers
//
// Implements Linux-compatible syscalls for userland processes.
// All handlers follow Linux x86_64 ABI: return value in RAX,
// negative values indicate error (-errno).
//
// Note: These are MVP implementations. Full implementations will
// require proper process management, file descriptors, etc.

const std = @import("std");
const uapi = @import("uapi");
const console = @import("console");
const hal = @import("hal");
const sched = @import("sched");
const keyboard = @import("keyboard");
const fd_mod = @import("fd");
const devfs = @import("devfs");
const user_vmm = @import("user_vmm");
const process_mod = @import("process");
const vmm = @import("vmm");
const pmm = @import("pmm");
const heap = @import("heap");

const Errno = uapi.errno.Errno;
const UserVmm = user_vmm.UserVmm;
const FdTable = fd_mod.FdTable;
const FileDescriptor = fd_mod.FileDescriptor;
const Process = process_mod.Process;

// =============================================================================
// Current Process Tracking
// =============================================================================
// For Phase 4, we track the current process. Falls back to init process
// when no explicit current process is set.

var current_process: ?*Process = null;

/// Get the current process (init if none set)
pub fn getCurrentProcess() *Process {
    if (current_process) |proc| {
        return proc;
    }

    // First access - get or create init process
    current_process = process_mod.getInitProcess() catch {
        console.err("Process: Failed to create init process", .{});
        @panic("Cannot create init process");
    };

    console.info("Process: Using init process (pid={})", .{current_process.?.pid});
    return current_process.?;
}

/// Set the current process (for context switching)
pub fn setCurrentProcess(proc: *Process) void {
    current_process = proc;
}

// =============================================================================
// Global FD Table (MVP single-process)
// =============================================================================
// In Phase 4 (Process model), this uses the current process's FD table.
// Falls back to global for backward compatibility.

var global_fd_table: ?*FdTable = null;
var fd_table_initialized: bool = false;

/// Get the FD table for the current process
fn getGlobalFdTable() *FdTable {
    // Use current process's FD table if available
    if (current_process) |proc| {
        return proc.fd_table;
    }

    // Fallback to global for backward compatibility
    if (global_fd_table) |table| {
        return table;
    }

    // First access - use init process's FD table
    const init_proc = getCurrentProcess();
    return init_proc.fd_table;
}

// =============================================================================
// Global User VMM (MVP single-process)
// =============================================================================
// In Phase 4 (Process model), this uses the current process's UserVmm.
// Falls back to global for backward compatibility.

var global_user_vmm: ?*UserVmm = null;

/// Get the UserVmm for the current process
fn getGlobalUserVmm() *UserVmm {
    // Use current process's UserVmm if available
    if (current_process) |proc| {
        return proc.user_vmm;
    }

    // Fallback to global for backward compatibility
    if (global_user_vmm) |uvmm| {
        return uvmm;
    }

    // First access - use init process's UserVmm
    const init_proc = getCurrentProcess();
    return init_proc.user_vmm;
}

// =============================================================================
// User Pointer Validation
// =============================================================================

/// Userspace address range boundaries
/// User code lives below the kernel in the canonical lower half
const USER_SPACE_START: u64 = 0x0000_0000_0040_0000; // 4MB (above null guard)
const USER_SPACE_END: u64 = 0x0000_7FFF_FFFF_FFFF; // Top of canonical lower half

/// Validate that a user pointer is within the userspace address range.
/// Returns true if the pointer appears valid for userspace access.
/// Note: This is a basic bounds check - does not verify page mapping.
pub fn isValidUserPtr(ptr: usize, len: usize) bool {
    // Null pointer is never valid
    if (ptr == 0) return false;

    // Check pointer is in userspace range
    if (ptr < USER_SPACE_START or ptr > USER_SPACE_END) return false;

    // Check for overflow
    const end_addr = @addWithOverflow(ptr, len);
    if (end_addr[1] != 0) return false; // Overflow occurred

    // Check end is still in userspace
    if (end_addr[0] > USER_SPACE_END) return false;

    return true;
}

/// Validate a user string pointer (null-terminated, max length)
pub fn isValidUserString(ptr: usize, max_len: usize) bool {
    return isValidUserPtr(ptr, max_len);
}

// =============================================================================
// Process Control
// =============================================================================

/// sys_exit (60) - Terminate the current thread
///
/// Note: In MVP, this terminates the current thread. Full implementation
/// would terminate the entire process (all threads).
pub fn sys_exit(status: usize) isize {
    const exit_code: i32 = @truncate(@as(isize, @bitCast(status)));
    console.debug("sys_exit: code={d}", .{exit_code});

    // Tell scheduler to exit current thread with status
    sched.exitWithStatus(exit_code);

    // Should not return, but if it does, return the status
    return @bitCast(status);
}

/// sys_exit_group (231) - Exit all threads in process group
///
/// MVP: Same as sys_exit since we don't have process groups yet.
pub fn sys_exit_group(status: usize) isize {
    return sys_exit(status);
}

/// sys_wait4 (61) - Wait for process state change
/// Full implementation with zombie reaping and parent/child tracking
pub fn sys_wait4(pid_arg: usize, wstatus_ptr: usize, options: usize, rusage_ptr: usize) isize {
    _ = rusage_ptr; // rusage not implemented

    const thread = @import("thread");

    const current = sched.getCurrentThread() orelse {
        return Errno.ESRCH.toReturn();
    };

    // Interpret pid argument
    const target_pid: i32 = @bitCast(@as(u32, @truncate(pid_arg)));
    const wnohang = (options & 1) != 0; // WNOHANG flag

    // Loop until we find a zombie child or no children remain
    while (true) {
        // Check for zombie children
        if (thread.findZombieChild(current, target_pid)) |zombie| {
            // Found a zombie - reap it

            // Write exit status if pointer provided
            if (wstatus_ptr != 0) {
                if (isValidUserPtr(wstatus_ptr, @sizeOf(i32))) {
                    const wstatus: *i32 = @ptrFromInt(wstatus_ptr);
                    // Linux wait status encoding: exit_status << 8
                    wstatus.* = (zombie.exit_status & 0xFF) << 8;
                }
            }

            // Save TID before destroying
            const reaped_tid = zombie.tid;

            // Remove from parent's child list and destroy
            thread.removeChild(current, zombie);
            thread.destroyThread(zombie);

            return @intCast(reaped_tid);
        }

        // No zombie found - check if we have any children at all
        if (!thread.hasAnyChildren(current)) {
            return Errno.ECHILD.toReturn();
        }

        // Check if any living children match the target
        if (target_pid > 0 and !thread.hasLivingChildren(current, target_pid)) {
            return Errno.ECHILD.toReturn();
        }

        // WNOHANG: don't block, return 0 if no zombies
        if (wnohang) {
            return 0;
        }

        // Block and wait for child to exit
        sched.block();
    }
}

/// sys_getpid (39) - Get process ID
///
/// MVP: Returns thread ID since we don't have processes yet.
pub fn sys_getpid() isize {
    if (sched.getCurrentThread()) |t| {
        return t.tid;
    }
    // No current thread (shouldn't happen in normal operation)
    return 1;
}

/// sys_getppid (110) - Get parent process ID
///
/// MVP: Always returns 0 (init process has no parent).
pub fn sys_getppid() isize {
    return 0;
}

/// sys_getuid (102) - Get user ID
///
/// MVP: Always returns 0 (root).
pub fn sys_getuid() isize {
    return 0;
}

/// sys_getgid (104) - Get group ID
///
/// MVP: Always returns 0 (root group).
pub fn sys_getgid() isize {
    return 0;
}

// =============================================================================
// Scheduling
// =============================================================================

/// sys_sched_yield (24) - Yield processor to other threads
pub fn sys_sched_yield() isize {
    sched.yield();
    return 0;
}

/// sys_nanosleep (35) - High-resolution sleep
///
/// Args:
///   req_ptr: Pointer to timespec with requested sleep duration
///   rem_ptr: Pointer to timespec for remaining time (if interrupted)
///
/// MVP: Busy-waits for the duration. Full implementation would
/// block the thread and use a timer to wake it.
pub fn sys_nanosleep(req_ptr: usize, rem_ptr: usize) isize {
    // Validate request pointer is in userspace
    if (!isValidUserPtr(req_ptr, @sizeOf(Timespec))) {
        return Errno.EFAULT.toReturn();
    }

    // Read timespec from userspace
    const req: *const Timespec = @ptrFromInt(req_ptr);

    // Validate timespec values
    if (req.tv_nsec < 0 or req.tv_nsec >= 1_000_000_000) {
        return Errno.EINVAL.toReturn();
    }

    // Calculate total nanoseconds to sleep
    // For MVP, we just yield repeatedly (no real timing)
    // Full implementation would use PIT or HPET for timing
    const total_ns: i64 = req.tv_sec * 1_000_000_000 + req.tv_nsec;

    // Simple busy-wait with yields (not accurate, just for MVP)
    // Each yield is approximately 10ms with default timer frequency
    const yields_needed = @max(1, @divTrunc(total_ns, 10_000_000));
    var i: i64 = 0;
    while (i < yields_needed) : (i += 1) {
        sched.yield();
    }

    // On success, set remaining time to 0 if pointer provided
    if (rem_ptr != 0) {
        const rem: *Timespec = @ptrFromInt(rem_ptr);
        rem.tv_sec = 0;
        rem.tv_nsec = 0;
    }

    return 0;
}

/// Timespec structure (Linux compatible)
pub const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

/// sys_clock_gettime (228) - Get time from a clock
///
/// MVP: Returns tick count converted to timespec.
pub fn sys_clock_gettime(clk_id: usize, tp_ptr: usize) isize {
    _ = clk_id; // Ignore clock ID for MVP (all clocks return same value)

    if (tp_ptr == 0) {
        return Errno.EFAULT.toReturn();
    }

    const tp: *Timespec = @ptrFromInt(tp_ptr);

    // Get tick count and convert to time
    // Assuming 100 Hz timer (10ms per tick)
    const ticks = sched.getTickCount();
    const ms = ticks * 10;
    tp.tv_sec = @intCast(ms / 1000);
    tp.tv_nsec = @intCast((ms % 1000) * 1_000_000);

    return 0;
}

// =============================================================================
// I/O Operations
// =============================================================================

/// sys_read (0) - Read from file descriptor
///
/// Reads up to count bytes from fd into buf.
/// Uses FD table to dispatch to appropriate device read operation.
pub fn sys_read(fd_num: usize, buf_ptr: usize, count: usize) isize {
    if (count == 0) {
        return 0;
    }

    // Validate user buffer pointer
    if (!isValidUserPtr(buf_ptr, count)) {
        return Errno.EFAULT.toReturn();
    }

    // Get FD from table
    const table = getGlobalFdTable();
    const fd = table.get(@intCast(fd_num)) orelse {
        return Errno.EBADF.toReturn();
    };

    // Check if FD is readable
    if (!fd.isReadable()) {
        return Errno.EBADF.toReturn();
    }

    // Call device read operation
    const read_fn = fd.ops.read orelse {
        return Errno.ENOSYS.toReturn();
    };

    const buf: [*]u8 = @ptrFromInt(buf_ptr);
    return read_fn(fd, buf, count);
}

/// sys_write (1) - Write to file descriptor
///
/// Writes up to count bytes from buf to fd.
/// Uses FD table to dispatch to appropriate device write operation.
pub fn sys_write(fd_num: usize, buf_ptr: usize, count: usize) isize {
    if (count == 0) {
        return 0;
    }

    // Validate user buffer pointer
    if (!isValidUserPtr(buf_ptr, count)) {
        return Errno.EFAULT.toReturn();
    }

    // Get FD from table
    const table = getGlobalFdTable();
    const fd = table.get(@intCast(fd_num)) orelse {
        return Errno.EBADF.toReturn();
    };

    // Check if FD is writable
    if (!fd.isWritable()) {
        return Errno.EBADF.toReturn();
    }

    // Call device write operation
    const write_fn = fd.ops.write orelse {
        return Errno.ENOSYS.toReturn();
    };

    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    return write_fn(fd, buf, count);
}

/// sys_brk (12) - Change data segment size (heap)
///
/// MVP: Not implemented - returns current break (0).
/// Full implementation requires process memory management.
pub fn sys_brk(addr: usize) isize {
    // For MVP, just return the requested address
    // This is a stub that pretends to work
    _ = addr;
    return 0;
}

// =============================================================================
// ZigK Custom Syscalls
// =============================================================================

/// sys_debug_log (1000) - Write debug message to kernel log
pub fn sys_debug_log(buf_ptr: usize, len: usize) isize {
    if (buf_ptr == 0 and len > 0) {
        return Errno.EFAULT.toReturn();
    }

    if (len == 0) {
        return 0;
    }

    // Limit message length for safety
    const max_len: usize = 4096;
    const actual_len = @min(len, max_len);

    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    console.debug("[USER] {s}", .{buf[0..actual_len]});

    return @intCast(actual_len);
}

/// sys_putchar (1005) - Write single character to console
pub fn sys_putchar(c: usize) isize {
    const char: u8 = @truncate(c);
    // Use HAL serial driver directly for single character output
    hal.serial.writeByte(char);
    return 0;
}

/// sys_getchar (1004) - Read single character from keyboard (blocking)
pub fn sys_getchar() isize {
    while (true) {
        if (keyboard.getChar()) |c| {
            return c;
        }
        // No character available, yield and try again
        sched.yield();
    }
}

/// sys_read_scancode (1003) - Read raw keyboard scancode (non-blocking)
pub fn sys_read_scancode() isize {
    if (keyboard.getScancode()) |scancode| {
        return scancode;
    }
    // No scancode available
    return Errno.EAGAIN.toReturn();
}

// =============================================================================
// Stub Handlers (Return appropriate error codes)
// =============================================================================

/// sys_open (2) - Open a file or device
///
/// Opens a file/device and returns a new file descriptor.
/// Currently only supports device files in /dev/.
pub fn sys_open(path_ptr: usize, flags: usize, mode: usize) isize {
    _ = mode; // Mode is ignored for device files

    // Validate path pointer (assume max path length of 4096)
    const max_path: usize = 4096;
    if (!isValidUserString(path_ptr, max_path)) {
        return Errno.EFAULT.toReturn();
    }

    // Read path string from userspace
    const path_bytes: [*]const u8 = @ptrFromInt(path_ptr);

    // Find null terminator (max 4096 chars)
    var path_len: usize = 0;
    while (path_len < max_path and path_bytes[path_len] != 0) : (path_len += 1) {}

    if (path_len == 0) {
        return Errno.ENOENT.toReturn();
    }

    const path = path_bytes[0..path_len];

    // Look up device by path
    const ops = devfs.lookupDevice(path) orelse {
        // Not a known device
        return Errno.ENOENT.toReturn();
    };

    // Create new file descriptor
    const fd = fd_mod.createFd(ops, @truncate(flags), null) catch {
        return Errno.ENOMEM.toReturn();
    };

    // Allocate FD number and install
    const table = getGlobalFdTable();
    const fd_num = table.allocFdNum() orelse {
        // Table is full - in MVP we just leak the FD
        // Full implementation would free it here
        return Errno.EMFILE.toReturn();
    };

    table.install(fd_num, fd);

    return @intCast(fd_num);
}

/// sys_close (3) - Close a file descriptor
///
/// Closes the file descriptor and releases associated resources.
pub fn sys_close(fd_num: usize) isize {
    const table = getGlobalFdTable();
    return table.close(@intCast(fd_num));
}

/// sys_mmap (9) - Map memory pages
///
/// Maps virtual memory into the process address space.
/// Currently supports anonymous mappings only.
///
/// Args:
///   addr: Hint address (0 for kernel choice), exact address if MAP_FIXED
///   len: Size in bytes
///   prot: Protection flags (PROT_READ, PROT_WRITE, PROT_EXEC)
///   flags: Map flags (MAP_ANONYMOUS, MAP_PRIVATE, MAP_FIXED)
///   fd: File descriptor (ignored for MAP_ANONYMOUS)
///   offset: File offset (ignored for MAP_ANONYMOUS)
///
/// Returns: Mapped address on success, negative errno on error
pub fn sys_mmap(addr: usize, len: usize, prot: usize, flags: usize, fd: usize, offset: usize) isize {
    _ = fd; // File mappings not supported
    _ = offset;

    const uvmm = getGlobalUserVmm();
    return uvmm.mmap(@intCast(addr), len, @truncate(prot), @truncate(flags));
}

/// sys_mprotect (10) - Set memory protection
///
/// Changes protection on a region of memory.
///
/// Args:
///   addr: Start address (must be page-aligned)
///   len: Size in bytes
///   prot: New protection flags
///
/// Returns: 0 on success, negative errno on error
pub fn sys_mprotect(addr: usize, len: usize, prot: usize) isize {
    const uvmm = getGlobalUserVmm();
    return uvmm.mprotect(@intCast(addr), len, @truncate(prot));
}

/// sys_munmap (11) - Unmap memory pages
///
/// Unmaps a region of memory from the process address space.
///
/// Args:
///   addr: Start address (must be page-aligned)
///   len: Size in bytes
///
/// Returns: 0 on success, negative errno on error
pub fn sys_munmap(addr: usize, len: usize) isize {
    const uvmm = getGlobalUserVmm();
    return uvmm.munmap(@intCast(addr), len);
}

/// sys_socket (41) - Create a socket
/// MVP: Returns -ENOSYS (networking not implemented)
pub fn sys_socket(domain: usize, sock_type: usize, protocol: usize) isize {
    _ = domain;
    _ = sock_type;
    _ = protocol;
    // Networking will be implemented in Phase 7
    return Errno.ENOSYS.toReturn();
}

/// sys_sendto (44) - Send a message on a socket
/// MVP: Returns -ENOSYS (networking not implemented)
pub fn sys_sendto(fd: usize, buf_ptr: usize, len: usize, flags: usize, addr_ptr: usize, addrlen: usize) isize {
    _ = fd;
    _ = buf_ptr;
    _ = len;
    _ = flags;
    _ = addr_ptr;
    _ = addrlen;
    return Errno.ENOSYS.toReturn();
}

/// sys_recvfrom (45) - Receive a message from a socket
/// MVP: Returns -ENOSYS (networking not implemented)
pub fn sys_recvfrom(fd: usize, buf_ptr: usize, len: usize, flags: usize, addr_ptr: usize, addrlen_ptr: usize) isize {
    _ = fd;
    _ = buf_ptr;
    _ = len;
    _ = flags;
    _ = addr_ptr;
    _ = addrlen_ptr;
    return Errno.ENOSYS.toReturn();
}

/// sys_fork (57) - Create a child process
///
/// Creates a new process by duplicating the calling process.
/// The child process has:
///   - Copied address space (all VMAs and their contents)
///   - Duplicated file descriptor table
///   - Parent set to the calling process
///
/// Returns:
///   - Child PID to parent process
///   - 0 to child process
///   - Negative errno on error
pub fn sys_fork() isize {
    const thread = @import("thread");

    // Get current process
    const parent_proc = getCurrentProcess();

    // Fork the process (copies address space and FDs)
    const child_proc = process_mod.forkProcess(parent_proc) catch |err| {
        console.err("sys_fork: Failed to fork process: {}", .{err});
        return Errno.ENOMEM.toReturn();
    };

    // Get current thread to copy its state
    const parent_thread = sched.getCurrentThread() orelse {
        // No current thread - this shouldn't happen
        process_mod.destroyProcess(child_proc);
        return Errno.ESRCH.toReturn();
    };

    // Create child thread
    // The child thread needs to be set up to return 0 from this syscall
    const child_thread = thread.createUserThread(
        0, // Entry point will be set from parent's saved state
        .{
            .name = parent_thread.getName(),
            .cr3 = child_proc.cr3,
            .user_stack_top = parent_thread.user_stack_top,
        },
    ) catch {
        process_mod.destroyProcess(child_proc);
        return Errno.ENOMEM.toReturn();
    };

    // Copy parent's kernel stack frame to child
    // This makes the child resume at the same point as parent
    copyThreadState(parent_thread, child_thread);

    // Set child's return value to 0 (RAX in syscall return)
    // The return value is stored in the saved interrupt frame
    setForkChildReturn(child_thread);

    // Set up parent-child relationship in thread hierarchy
    thread.addChild(parent_thread, child_thread);

    // Add child thread to scheduler
    sched.addThread(child_thread);

    // Return child PID to parent
    return @intCast(child_proc.pid);
}

/// Copy thread state from parent to child for fork
fn copyThreadState(parent: *@import("thread").Thread, child: *@import("thread").Thread) void {
    // Copy the saved interrupt frame from parent's kernel stack
    // The frame contains all registers including RIP (resume point)
    const frame_size: usize = 23 * 8; // 15 GPRs + vec + err + 5 iretq values

    const parent_frame_ptr: [*]u8 = @ptrFromInt(parent.kernel_rsp);
    const child_frame_ptr: [*]u8 = @ptrFromInt(child.kernel_rsp);

    @memcpy(child_frame_ptr[0..frame_size], parent_frame_ptr[0..frame_size]);

    // Copy FS base (TLS)
    child.fs_base = parent.fs_base;
}

/// Set the child's return value to 0 for fork
/// Modifies RAX in the saved interrupt frame
fn setForkChildReturn(child: *@import("thread").Thread) void {
    // The interrupt frame has RAX as the first GPR after vec/err
    // Stack layout (from bottom, growing down):
    // [SS, RSP, RFLAGS, CS, RIP, err, vec, RAX, RBX, ...]
    // RAX is at offset 14*8 from the top of the frame

    // The child's kernel_rsp points to the bottom of the saved frame
    // RAX is at offset (frame_size - 8*1) from kernel_rsp
    // Actually, RAX is the first GPR pushed, so it's at the highest address
    // in the GPR section

    // Frame layout from low to high addresses (kernel_rsp points here):
    // R15, R14, R13, R12, R11, R10, R9, R8, RDI, RSI, RBP, RDX, RCX, RBX, RAX
    // vec, err, RIP, CS, RFLAGS, RSP, SS

    // RAX is 14 u64s from kernel_rsp
    const rax_offset: usize = 14 * 8;
    const rax_ptr: *u64 = @ptrFromInt(child.kernel_rsp + rax_offset);
    rax_ptr.* = 0; // Child gets 0 from fork()
}

/// sys_execve (59) - Execute a program
/// MVP: Returns -ENOSYS (process execution not implemented)
pub fn sys_execve(path_ptr: usize, argv_ptr: usize, envp_ptr: usize) isize {
    _ = path_ptr;
    _ = argv_ptr;
    _ = envp_ptr;
    return Errno.ENOSYS.toReturn();
}

// arch_prctl operation codes (Linux ABI)
const ARCH_SET_GS: usize = 0x1001;
const ARCH_SET_FS: usize = 0x1002;
const ARCH_GET_FS: usize = 0x1003;
const ARCH_GET_GS: usize = 0x1004;

/// sys_arch_prctl (158) - Set architecture-specific thread state
///
/// Manages FS/GS segment bases for Thread Local Storage (TLS).
/// Only FS operations are supported; GS is reserved for kernel use.
///
/// Args:
///   code - Operation: ARCH_SET_FS (0x1002) or ARCH_GET_FS (0x1003)
///   addr - For SET: new FS base value. For GET: pointer to store current value.
///
/// Returns:
///   0 on success
///   -EINVAL for unsupported operation codes
///   -EFAULT for invalid user pointer (GET only)
pub fn sys_arch_prctl(code: usize, addr: usize) isize {
    const curr = sched.getCurrentThread() orelse {
        // No current thread - should not happen in normal operation
        return Errno.ESRCH.toReturn();
    };

    switch (code) {
        ARCH_SET_FS => {
            // Store FS base in thread struct for context switch restoration
            curr.fs_base = addr;
            // Write to IA32_FS_BASE MSR for immediate effect
            hal.cpu.writeMsr(hal.cpu.IA32_FS_BASE, addr);
            return 0;
        },
        ARCH_GET_FS => {
            // Validate user pointer
            if (!isValidUserPtr(addr, @sizeOf(u64))) {
                return Errno.EFAULT.toReturn();
            }
            // Write current FS base to user pointer
            const ptr: *u64 = @ptrFromInt(addr);
            ptr.* = curr.fs_base;
            return 0;
        },
        ARCH_SET_GS, ARCH_GET_GS => {
            // GS is reserved for kernel use (SWAPGS, per-CPU data)
            return Errno.EINVAL.toReturn();
        },
        else => {
            return Errno.EINVAL.toReturn();
        },
    }
}

/// sys_get_fb_info (1001) - Get framebuffer info
/// MVP: Returns -ENODEV (no framebuffer driver)
pub fn sys_get_fb_info(info_ptr: usize) isize {
    _ = info_ptr;
    // Framebuffer driver not implemented
    return Errno.ENODEV.toReturn();
}

/// sys_map_fb (1002) - Map framebuffer into process address space
/// MVP: Returns -ENODEV (no framebuffer driver)
pub fn sys_map_fb() isize {
    return Errno.ENODEV.toReturn();
}
