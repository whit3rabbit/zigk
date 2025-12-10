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
const elf = @import("elf");
const framebuffer = @import("framebuffer");

const mman_defs = uapi.mman;
const fs = @import("fs");
const user_mem = @import("user_mem");
const Errno = uapi.errno.Errno;

// Re-export validation functions from user_mem for local use
const isValidUserPtr = user_mem.isValidUserPtr;
const isValidUserAccess = user_mem.isValidUserAccess;
const AccessMode = user_mem.AccessMode;
const UserPtr = user_mem.UserPtr;
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
pub fn getGlobalFdTable() *FdTable {
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
                // Linux wait status encoding: exit_status << 8
                const wstatus_val: i32 = (zombie.exit_status & 0xFF) << 8;
                UserPtr.from(wstatus_ptr).writeValue(wstatus_val) catch {
                    // Ignore fault on write back, as we already reaped functionality
                };
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
    // Read timespec from userspace
    const req = UserPtr.from(req_ptr).readValue(Timespec) catch {
        return Errno.EFAULT.toReturn();
    };

    // Validate timespec values
    if (req.tv_sec < 0 or req.tv_nsec < 0 or req.tv_nsec >= 1_000_000_000) {
        return Errno.EINVAL.toReturn();
    }

    const sec_u: u64 = @intCast(req.tv_sec);
    if (sec_u > std.math.maxInt(u64) / 1_000_000_000) {
        return Errno.EINVAL.toReturn();
    }

    const sec_ns: u64 = sec_u * 1_000_000_000;
    const nsec_u: u64 = @intCast(req.tv_nsec);
    if (sec_ns > std.math.maxInt(u64) - nsec_u) {
        return Errno.EINVAL.toReturn();
    }

    const total_ns = sec_ns + nsec_u;
    if (total_ns == 0) {
        if (rem_ptr != 0) {
            const rem: Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
            UserPtr.from(rem_ptr).writeValue(rem) catch {
                return Errno.EFAULT.toReturn();
            };
        }
        return 0;
    }

    const tick_ns: u64 = 10_000_000;
    const duration_ticks = std.math.divCeil(u64, total_ns, tick_ns) catch unreachable;

    sched.sleepForTicks(duration_ticks);

    // On success, set remaining time to 0 if pointer provided
    if (rem_ptr != 0) {
        const rem: Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
        UserPtr.from(rem_ptr).writeValue(rem) catch {
            return Errno.EFAULT.toReturn();
        };
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

    // Get tick count and convert to time
    // Assuming 100 Hz timer (10ms per tick)
    const ticks = sched.getTickCount();
    const ms = ticks * 10;
    const tp = Timespec{
        .tv_sec = @intCast(ms / 1000),
        .tv_nsec = @intCast((ms % 1000) * 1_000_000),
    };

    UserPtr.from(tp_ptr).writeValue(tp) catch {
        return Errno.EFAULT.toReturn();
    };

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

    // Bounds check pointer (fast check)
    // We do full copy later, but this saves us allocation if obviously bad
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

    // Allocate kernel buffer for the read
    // For large reads, we should loop. For MVP, we cap at 4KB or alloc from heap?
    // Let's alloc from heap to be safe for now, or just limit large reads to 4096.
    // For robustness, clamping to 4096 is safer for kernel stack, but allocating is better.
    // Given the kernel heap allocator is available, let's use it.
    
    // Cap read size to avoid massive allocations (e.g. 1GB)
    const max_read_size = 64 * 1024; // 64KB chunks
    const read_size = @min(count, max_read_size);

    const kbuf = heap.allocator().alloc(u8, read_size) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer heap.allocator().free(kbuf);

    // Read into kernel buffer
    const bytes_read = read_fn(fd, kbuf);
    if (bytes_read < 0) return bytes_read;

    // Copy to user memory
    const uptr = UserPtr.from(buf_ptr);
    const valid_read = @as(usize, @intCast(bytes_read));
    
    // Only copy what was actually read
    const copy_res = uptr.copyFromKernel(kbuf[0..valid_read]);
    if (copy_res == error.Fault) {
        return Errno.EFAULT.toReturn();
    }

    return bytes_read;
}

/// sys_write (1) - Write to file descriptor
///
/// Writes up to count bytes from buf to fd.
/// Uses FD table to dispatch to appropriate device write operation.
pub fn sys_write(fd_num: usize, buf_ptr: usize, count: usize) isize {
    if (count == 0) {
        return 0;
    }
    
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

    // Cap write size
    const max_write_size = 64 * 1024;
    const write_size = @min(count, max_write_size);

    const kbuf = heap.allocator().alloc(u8, write_size) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer heap.allocator().free(kbuf);

    // Copy from user to kernel
    const uptr = UserPtr.from(buf_ptr);
    if (uptr.copyToKernel(kbuf) catch null == null) {
        return Errno.EFAULT.toReturn();
    }
    
    // Write from kernel buffer
    return write_fn(fd, kbuf);
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
    const max_len: usize = 1024;
    const copy_len = @min(len, max_len);

    // Allocate buffer on heap to preserve stack space
    const kbuf = heap.allocator().alloc(u8, copy_len) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer heap.allocator().free(kbuf);

    const uptr = UserPtr.from(buf_ptr);
    const actual_len = uptr.copyToKernel(kbuf) catch {
        return Errno.EFAULT.toReturn();
    };

    console.debug("[USER] {s}", .{kbuf[0..actual_len]});

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

    // Allocate path buffer on heap to preserve stack space
    const path_buf = heap.allocator().alloc(u8, user_mem.MAX_PATH_LEN) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer heap.allocator().free(path_buf);

    // Validate and read path string from userspace
    const path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return Errno.ENAMETOOLONG.toReturn();
        return Errno.EFAULT.toReturn();
    };

    if (path.len == 0) {
        return Errno.ENOENT.toReturn();
    }

    // Look up device by devfs
    if (devfs.lookupDevice(path)) |ops| {
        // Create device FD
        const fd = fd_mod.createFd(ops, @truncate(flags), null) catch {
            return Errno.ENOMEM.toReturn();
        };
        const alloc = heap.allocator();
        errdefer alloc.destroy(fd);

        const table = getGlobalFdTable();
        const fd_num = table.allocFdNum() orelse {
            return Errno.EMFILE.toReturn();
        };

        table.install(fd_num, fd);
        return @intCast(fd_num);
    }

    // Fallback: InitRD
    // Note: This is where we would check a real VFS in the future
    const fd = fs.initrd.InitRD.instance.openFile(path, @truncate(flags)) catch |err| {
        if (err == error.FileNotFound) {
            return Errno.ENOENT.toReturn();
        }
        return Errno.ENOMEM.toReturn();
    };
    const alloc = heap.allocator();
    errdefer alloc.destroy(fd);

    const table = getGlobalFdTable();
    const fd_num = table.allocFdNum() orelse {
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

    // Enforce per-process memory limit (DoS protection)
    const proc = getCurrentProcess();
    const aligned_len = std.mem.alignForward(usize, len, pmm.PAGE_SIZE);
    if (proc.rss_current + aligned_len > proc.rlimit_as) {
        return Errno.ENOMEM.toReturn();
    }

    const uvmm = getGlobalUserVmm();
    const result = uvmm.mmap(@intCast(addr), len, @truncate(prot), @truncate(flags));

    // Update RSS on successful mapping
    if (result >= 0) {
        proc.rss_current += aligned_len;
    }

    return result;
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
///
/// Replaces the current process image with a new program.
/// The new program is loaded from the specified path (InitRD lookup).
///
/// Args:
///   frame: SyscallFrame pointer (needed to redirect execution on success)
///   path_ptr: Pointer to null-terminated path string
///   argv_ptr: Pointer to null-terminated array of argument pointers
///   envp_ptr: Pointer to null-terminated array of environment pointers
///
/// Returns:
///   Does not return on success (new program starts)
///   -ENOENT if executable not found
///   -EFAULT for invalid pointers
///   -ENOEXEC for invalid executable format
///
/// Note: Currently only supports executables loaded via InitRD modules.
/// Filesystem-based executables require VFS implementation.
pub fn sys_execve(frame: *hal.syscall.SyscallFrame, path_ptr: usize, argv_ptr: usize, envp_ptr: usize) isize {
    // Allocate path buffer on heap to preserve stack space
    const path_buf = heap.allocator().alloc(u8, user_mem.MAX_PATH_LEN) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer heap.allocator().free(path_buf);

    // Validate and read path string from userspace
    const path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return Errno.ENAMETOOLONG.toReturn();
        return Errno.EFAULT.toReturn();
    };

    if (path.len == 0) {
        return Errno.ENOENT.toReturn();
    }

    console.debug("sys_execve: path='{s}'", .{path});

    // Parse argv and envp (collect up to 64 arguments each)
    // Heap-allocate the data buffer (128KB like Linux) to avoid stack overflow
    // and return proper E2BIG error if arguments exceed limit.
    const MAX_ARG_SIZE = 128 * 1024; // 128KB like Linux ARG_MAX
    const alloc = heap.allocator();
    const arg_data_buf = alloc.alloc(u8, MAX_ARG_SIZE) catch {
        return Errno.ENOMEM.toReturn();
    };
    defer alloc.free(arg_data_buf);

    var arg_data_idx: usize = 0;
    var argv_storage: [64][]const u8 = undefined;
    var argc: usize = 0;

    if (argv_ptr != 0) {
        var i: usize = 0;
        while (argc < 64) : (i += 1) {
            const ptr_addr = argv_ptr + i * @sizeOf(usize);
            const arg_ptr = UserPtr.from(ptr_addr).readValue(usize) catch break;

            if (arg_ptr == 0) break; // Null terminator of argv array

            const remaining_space = arg_data_buf[arg_data_idx..];
            // Return E2BIG if we've exhausted the argument buffer
            if (remaining_space.len == 0) {
                return Errno.E2BIG.toReturn();
            }

            const arg_slice = user_mem.copyStringFromUser(remaining_space, arg_ptr) catch |err| {
                if (err == error.NameTooLong) return Errno.E2BIG.toReturn();
                return Errno.EFAULT.toReturn();
            };

            argv_storage[argc] = arg_slice;
            arg_data_idx += arg_slice.len + 1; // +1 for null terminator space
            argc += 1;
        }
        // Check if we hit the 64 argument limit
        if (argc == 64) {
            const ptr_addr = argv_ptr + 64 * @sizeOf(usize);
            if (UserPtr.from(ptr_addr).readValue(usize)) |arg_ptr| {
                if (arg_ptr != 0) return Errno.E2BIG.toReturn(); // More than 64 args
            } else |_| {}
        }
    }

    const argv = argv_storage[0..argc];

    // Parse envp (collect up to 64 environment variables)
    var envp_storage: [64][]const u8 = undefined;
    var envc: usize = 0;

    if (envp_ptr != 0) {
        var i: usize = 0;
        while (envc < 64) : (i += 1) {
            const ptr_addr = envp_ptr + i * @sizeOf(usize);
            const env_ptr = UserPtr.from(ptr_addr).readValue(usize) catch break;

            if (env_ptr == 0) break;

            const remaining_space = arg_data_buf[arg_data_idx..];
            // Return E2BIG if we've exhausted the argument buffer
            if (remaining_space.len == 0) {
                return Errno.E2BIG.toReturn();
            }

            const env_slice = user_mem.copyStringFromUser(remaining_space, env_ptr) catch |err| {
                if (err == error.NameTooLong) return Errno.E2BIG.toReturn();
                return Errno.EFAULT.toReturn();
            };

            envp_storage[envc] = env_slice;
            arg_data_idx += env_slice.len + 1; // +1 for null terminator space
            envc += 1;
        }
    }

    const envp = envp_storage[0..envc];

    // argv and envp are parsed and ready for ELF loader
    // Using them below in elf.exec

    console.debug("sys_execve: argc={}, envc={}", .{ argc, envc });

    // Look up executable in InitRD
    const file = fs.initrd.InitRD.instance.findFile(path) orelse {
        // Executable not found
        return Errno.ENOENT.toReturn();
    };

    // Load and execute ELF
    // This creates a new address space and sets up the stack
    const result = elf.exec(file.data, argv, envp) catch |err| {
        console.err("sys_execve: Failed to exec: {}", .{err});
        return Errno.ENOEXEC.toReturn();
    };

    console.debug("sys_execve: Loaded ELF entry={x} stack={x} cr3={x}", .{
        result.entry_point,
        result.stack_pointer,
        result.pml4_phys,
    });

    const current_thread = sched.getCurrentThread().?;
    const current_proc = getCurrentProcess();

    // Save old CR3 to destroy later
    // Save old CR3 to destroy later
    const old_cr3 = current_proc.cr3;

    // Update process/thread state
    current_proc.cr3 = result.pml4_phys;
    current_proc.heap_start = result.heap_start;
    current_proc.heap_break = result.heap_start;
    current_thread.cr3 = result.pml4_phys;

    // Switch to new address space immediately
    hal.cpu.writeCr3(result.pml4_phys);

    // Update the SyscallFrame to return to the new entry point with new stack.
    // Using the typed SyscallFrame struct instead of magic offsets ensures
    // correctness even if the frame layout changes in asm_helpers.S.
    frame.setReturnRip(result.entry_point);
    frame.setUserRsp(result.stack_pointer);

    // Destroy old address space
    vmm.destroyAddressSpace(old_cr3);

    // Return 0 - this gets placed in RAX by the dispatcher.
    // On successful execve, this value becomes the argc seen by _start
    // (though typically argc comes from the stack, not RAX).
    return 0;
}


/// sys_brk (12) - Change data segment size
pub fn sys_brk(addr: u64) isize {
    const proc = getCurrentProcess();

    // If addr is 0, return current break
    if (addr == 0) {
        return @intCast(proc.heap_break);
    }

    // Checking inputs
    // We only support growing the heap for now, or keeping it same.
    // Shrinking is valid but complicates things (need to unmap).
    // Also need to check if new break is valid (e.g. not overlapping stack or kernel)
    
    // Check if less than start (invalid)
    if (addr < proc.heap_start) {
        return @intCast(proc.heap_break);
    }

    // Check upper bound - must not exceed user space
    if (addr > user_mem.USER_SPACE_END) {
        return @intCast(proc.heap_break);
    }

    // Enforce per-process memory limit (DoS protection)
    const new_heap_size = addr - proc.heap_start;
    if (proc.rss_current + new_heap_size > proc.rlimit_as) {
        return Errno.ENOMEM.toReturn();
    }

    // Align to page size for mapping
    const current_break_aligned = std.mem.alignForward(u64, proc.heap_break, pmm.PAGE_SIZE);
    const new_break_aligned = std.mem.alignForward(u64, addr, pmm.PAGE_SIZE);

    // Aligned value must also be within bounds (alignment could push it over)
    if (new_break_aligned > user_mem.USER_SPACE_END) {
        return @intCast(proc.heap_break);
    }

    if (new_break_aligned > current_break_aligned) {
        // Growing heap
        const size_to_map = new_break_aligned - current_break_aligned;
        const pages_to_map = size_to_map / pmm.PAGE_SIZE;

        // Allocate and map pages
        // We can use UserVmm or just direct mapping.
        // Process struct has user_vmm field.
        
        // TODO: Use proc.user_vmm logic to track VMAs?
        // For MVP, we just map the pages directly into the page table.
        // Ideally we should update VMA list too.
        
        // Let's use vmm directly first for simplicity, but we need physical pages.
        var i: usize = 0;
        while (i < pages_to_map) : (i += 1) {
            const phys_page = pmm.allocPage() orelse {
                // OOM - should cleanup already mapped pages?
                // For MVP, just fail. Real implementation needs rollback.
                return Errno.ENOMEM.toReturn();
            };
            
            const vaddr = current_break_aligned + (i * pmm.PAGE_SIZE);
            
            const flags = vmm.PageFlags{
                .writable = true,
                .user = true,
                .no_execute = true, // Heap should not be executable
            };

            vmm.mapPage(proc.cr3, vaddr, phys_page, flags) catch {
                pmm.freePage(phys_page);

                // Rollback: Unmap and free pages successfully mapped in this call
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    const rollback_addr = current_break_aligned + (j * pmm.PAGE_SIZE);
                    if (vmm.translate(proc.cr3, rollback_addr)) |paddr| {
                         pmm.freePage(paddr);
                         vmm.unmapPage(proc.cr3, rollback_addr) catch {};
                    }
                }
                return Errno.ENOMEM.toReturn();
            };
            
            // Zero the page (security)
            const ptr: [*]u8 = @ptrCast(hal.paging.physToVirt(phys_page));
            @memset(ptr[0..pmm.PAGE_SIZE], 0);

            // Track RSS for resource limit enforcement
            proc.rss_current += pmm.PAGE_SIZE;
        }
    } else if (new_break_aligned < current_break_aligned) {
        // Shrinking heap - not implemented yet
        // Would need to unmap pages and free physical memory
        // TODO: Decrement proc.rss_current when implemented
    }

    // Update break
    proc.heap_break = addr;
    return @intCast(addr);
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
///
/// Copies framebuffer dimensions and pixel format to userspace struct.
/// Returns 0 on success, -ENODEV if no framebuffer available,
/// -EFAULT for invalid pointer.
pub fn sys_get_fb_info(info_ptr: usize) isize {
    // Validate user pointer (FramebufferInfo is 24 bytes: 4*u32 + 6*u8 + 2*u8 padding)
    const info_size: usize = 24;
    if (!isValidUserPtr(info_ptr, info_size)) {
        return Errno.EFAULT.toReturn();
    }

    // Get framebuffer state from module (returns null if not available)
    const fb_state = framebuffer.getState() orelse {
        return Errno.ENODEV.toReturn();
    };

    // Copy framebuffer info to userspace
    // The struct layout must match FramebufferInfo in user/lib/syscall.zig
    const info_bytes: [*]u8 = @ptrFromInt(info_ptr);

    // Width (u32, offset 0)
    @as(*align(1) u32, @ptrCast(info_bytes + 0)).* = fb_state.width;
    // Height (u32, offset 4)
    @as(*align(1) u32, @ptrCast(info_bytes + 4)).* = fb_state.height;
    // Pitch (u32, offset 8)
    @as(*align(1) u32, @ptrCast(info_bytes + 8)).* = fb_state.pitch;
    // Bpp (u32, offset 12) - extend u8 to u32 for struct field
    @as(*align(1) u32, @ptrCast(info_bytes + 12)).* = @as(u32, fb_state.bpp);
    // Red shift (u8, offset 16)
    info_bytes[16] = fb_state.red_shift;
    // Red mask size (u8, offset 17)
    info_bytes[17] = fb_state.red_mask_size;
    // Green shift (u8, offset 18)
    info_bytes[18] = fb_state.green_shift;
    // Green mask size (u8, offset 19)
    info_bytes[19] = fb_state.green_mask_size;
    // Blue shift (u8, offset 20)
    info_bytes[20] = fb_state.blue_shift;
    // Blue mask size (u8, offset 21)
    info_bytes[21] = fb_state.blue_mask_size;
    // Reserved bytes (offset 22-23)
    info_bytes[22] = 0;
    info_bytes[23] = 0;

    console.debug("sys_get_fb_info: {d}x{d}x{d}", .{
        fb_state.width,
        fb_state.height,
        fb_state.bpp,
    });

    return 0;
}

/// sys_map_fb (1002) - Map framebuffer into process address space
///
/// Maps the physical framebuffer memory into the calling process's
/// address space at a fixed virtual address. Returns the virtual
/// address on success, or negative errno on failure.
///
/// Returns:
///   Virtual address on success (positive)
///   -ENODEV if no framebuffer available
///   -ENOMEM if mapping failed
pub fn sys_map_fb() isize {
    // Get framebuffer state from module
    const fb_state = framebuffer.getState() orelse {
        return Errno.ENODEV.toReturn();
    };

    // Get current process for page table
    const proc = getCurrentProcess();

    // Fixed virtual address for framebuffer in user space
    // Using high address to avoid conflicts with heap/stack
    const fb_virt_base: u64 = 0x0000_4000_0000_0000; // 64 TB mark

    // Calculate page-aligned size
    const fb_size = std.mem.alignForward(usize, fb_state.size, pmm.PAGE_SIZE);

    // Page flags for framebuffer: user accessible, writable, write-through for MMIO
    // Note: present/accessed/dirty are set automatically by the page table code
    const flags = hal.paging.PageFlags{
        .writable = true,
        .user = true,
        .write_through = true, // Write-through for framebuffer coherency
        .cache_disable = false,
        .global = false,
        .no_execute = true, // Framebuffer is data, not code
    };

    // Map framebuffer physical memory into user address space
    vmm.mapRange(proc.cr3, fb_virt_base, fb_state.phys_addr, fb_size, flags) catch |err| {
        console.err("sys_map_fb: Failed to map FB: {}", .{err});
        return Errno.ENOMEM.toReturn();
    };

    const fb_vma = proc.user_vmm.createVma(
        fb_virt_base,
        fb_virt_base + fb_size,
        user_vmm.PROT_READ | user_vmm.PROT_WRITE,
        user_vmm.MAP_SHARED | user_vmm.MAP_DEVICE,
    ) catch {
        var offset: usize = 0;
        while (offset < fb_size) : (offset += pmm.PAGE_SIZE) {
            vmm.unmapPage(proc.cr3, fb_virt_base + offset) catch {};
        }
        return Errno.ENOMEM.toReturn();
    };
    proc.user_vmm.insertVma(fb_vma);
    proc.user_vmm.total_mapped += fb_size;

    console.debug("sys_map_fb: Mapped FB at virt={x} (phys={x}, size={d})", .{
        fb_virt_base,
        fb_state.phys_addr,
        fb_size,
    });

    // Return the mapped virtual address
    // Cast to isize - this is safe because the address is well below isize max
    return @bitCast(fb_virt_base);
}
