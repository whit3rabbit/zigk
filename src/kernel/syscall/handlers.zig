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
const SyscallError = uapi.errno.SyscallError;

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
    // Linux exit status encoding: (status & 0xFF) << 8
    const exit_code: i32 = @truncate(@as(isize, @bitCast(status)));
    process_mod.exit((exit_code & 0xFF) << 8);
    unreachable;
}

/// sys_exit_group (231) - Exit all threads in process group
///
/// MVP: Same as sys_exit since we don't have process groups yet.
pub fn sys_exit_group(status: usize) isize {
    const exit_code: i32 = @truncate(@as(isize, @bitCast(status)));
    process_mod.exit((exit_code & 0xFF) << 8);
    unreachable;
}

/// sys_wait4 (61) - Wait for process state change
/// Full implementation with zombie reaping and parent/child tracking
pub fn sys_wait4(pid_arg: usize, wstatus_ptr: usize, options: usize, rusage_ptr: usize) SyscallError!usize {
    _ = rusage_ptr; // rusage not implemented

    const thread = @import("thread");

    const current_thread = sched.getCurrentThread() orelse {
        return error.ESRCH;
    };

    // Interpret pid argument
    const target_pid: i32 = @bitCast(@as(u32, @truncate(pid_arg)));
    const wnohang = (options & 1) != 0; // WNOHANG flag

    // Loop until we find a zombie child or no children remain
    while (true) {
        var found_zombie: ?*thread.Thread = null;
        var has_children = false;
        var has_matching_child = false;

        // Iterate children list manually to check Process PID
        var child_node = current_thread.first_child;
        while (child_node) |child| {
            // Get next sibling early since we might remove 'child'
            child_node = child.next_sibling;

            // Get child process PID
            var child_pid: i32 = 0;
            if (child.process) |p_ptr| {
                const proc = @as(*process_mod.Process, @ptrCast(@alignCast(p_ptr)));
                child_pid = @intCast(proc.pid);
            } else {
                // Kernel thread child? Skip or use TID as PID?
                child_pid = @intCast(child.tid);
            }

            // Check if this child matches target_pid
            const matches = if (target_pid == -1) true else (child_pid == target_pid);

            if (matches) {
                has_children = true;
                has_matching_child = true;

                if (child.state == .Zombie) {
                    found_zombie = child;
                    break;
                }
            } else if (target_pid == -1) {
                // Should be covered by matches=true above, but for clarity
                has_children = true;
            }
        }

        if (found_zombie) |zombie| {
            // Found a zombie - reap it

            // Get PID before destroying
            var reaped_pid: usize = 0;
            if (zombie.process) |p_ptr| {
                const proc = @as(*process_mod.Process, @ptrCast(@alignCast(p_ptr)));
                reaped_pid = proc.pid;
            } else {
                reaped_pid = @intCast(zombie.tid);
            }

            // Write exit status if pointer provided
            if (wstatus_ptr != 0) {
                // Use Process exit status as the source of truth if available
                var status: i32 = zombie.exit_status;
                if (zombie.process) |p_ptr| {
                    const proc = @as(*process_mod.Process, @ptrCast(@alignCast(p_ptr)));
                    status = proc.exit_status;
                }

                // Directly write exit_status (already encoded by sys_exit or crash handler)
                UserPtr.from(wstatus_ptr).writeValue(status) catch {
                    // Check for error.Fault in the catch block and return error.EFAULT instead of proceeding
                    return error.EFAULT;
                };
            }

            // Remove from parent's child list and destroy
            thread.removeChild(current_thread, zombie);
            const proc_opaque = thread.destroyThread(zombie);
            if (proc_opaque) |ptr| {
                const proc = @as(*process_mod.Process, @ptrCast(@alignCast(ptr)));
                if (proc.unref()) {
                    process_mod.destroyProcess(proc);
                }
            }

            return reaped_pid;
        }

        // No zombie found
        if (!has_matching_child and target_pid > 0) {
            return error.ECHILD;
        }

        if (!has_children and target_pid == -1) {
            return error.ECHILD;
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
pub fn sys_getpid() SyscallError!usize {
    if (sched.getCurrentThread()) |t| {
        return @intCast(t.tid);
    }
    // No current thread (shouldn't happen in normal operation)
    return 1;
}

/// sys_getppid (110) - Get parent process ID
///
/// MVP: Always returns 0 (init process has no parent).
pub fn sys_getppid() SyscallError!usize {
    return 0;
}

/// sys_getuid (102) - Get user ID
///
/// MVP: Always returns 0 (root).
pub fn sys_getuid() SyscallError!usize {
    return 0;
}

/// sys_getgid (104) - Get group ID
///
/// MVP: Always returns 0 (root group).
pub fn sys_getgid() SyscallError!usize {
    return 0;
}

// =============================================================================
// Signal and Thread Control
// =============================================================================

/// sys_rt_sigprocmask (14) - Examine and change blocked signals
///
/// Implements signal masking (SIG_BLOCK, SIG_UNBLOCK, SIG_SETMASK).
/// Returns 0 on success, negative errno on error.
pub fn sys_rt_sigprocmask(how: usize, set_ptr: usize, oldset_ptr: usize, sigsetsize: usize) SyscallError!usize {
    if (sigsetsize != @sizeOf(uapi.signal.SigSet)) {
        return error.EINVAL;
    }

    const current_thread = sched.getCurrentThread() orelse {
        return error.ESRCH;
    };

    // Store old set if requested
    if (oldset_ptr != 0) {
        UserPtr.from(oldset_ptr).writeValue(current_thread.sigmask) catch {
            return error.EFAULT;
        };
    }

    // If set_ptr is NULL, we are just querying
    if (set_ptr == 0) {
        return 0;
    }

    const new_set = UserPtr.from(set_ptr).readValue(uapi.signal.SigSet) catch {
        return error.EFAULT;
    };

    // Apply change based on 'how'
    switch (how) {
        uapi.signal.SIG_BLOCK => {
            current_thread.sigmask |= new_set;
        },
        uapi.signal.SIG_UNBLOCK => {
            current_thread.sigmask &= ~new_set;
        },
        uapi.signal.SIG_SETMASK => {
            current_thread.sigmask = new_set;
        },
        else => {
            return error.EINVAL;
        },
    }

    // SIGKILL and SIGSTOP cannot be blocked
    uapi.signal.sigdelset(&current_thread.sigmask, uapi.signal.SIGKILL);
    uapi.signal.sigdelset(&current_thread.sigmask, uapi.signal.SIGSTOP);

    return 0;
}

/// sys_rt_sigaction (13) - Examine and change a signal action
///
/// Args:
///   signum: Signal number
///   act_ptr: Pointer to new SigAction struct (or NULL)
///   oldact_ptr: Pointer to store old SigAction struct (or NULL)
///   sigsetsize: Size of sigset_t (should be 8 bytes)
///
/// Returns: 0 on success, negative errno on error.
pub fn sys_rt_sigaction(signum: usize, act_ptr: usize, oldact_ptr: usize, sigsetsize: usize) SyscallError!usize {
    if (sigsetsize != @sizeOf(uapi.signal.SigSet)) {
        return error.EINVAL;
    }

    if (signum == 0 or signum > 64) {
        return error.EINVAL;
    }

    // SIGKILL and SIGSTOP cannot be caught, blocked, or ignored
    if (signum == uapi.signal.SIGKILL or signum == uapi.signal.SIGSTOP) {
        return error.EINVAL;
    }

    const current_thread = sched.getCurrentThread() orelse {
        return error.ESRCH;
    };

    // Store old action if requested
    if (oldact_ptr != 0) {
        const old_action = current_thread.signal_actions[signum - 1];
        UserPtr.from(oldact_ptr).writeValue(old_action) catch {
            return error.EFAULT;
        };
    }

    // If act_ptr is NULL, we are just querying
    if (act_ptr == 0) {
        return 0;
    }

    // Read new action
    const new_action = UserPtr.from(act_ptr).readValue(uapi.signal.SigAction) catch {
        return error.EFAULT;
    };

    // Update action table
    current_thread.signal_actions[signum - 1] = new_action;

    return 0;
}

/// sys_rt_sigreturn (15) - Return from signal handler and restore context
///
/// This syscall is called by the signal trampoline. It restores the user context
/// saved on the stack (ucontext_t).
///
/// MVP: Does not return (returns via iretq with restored context).
pub fn sys_rt_sigreturn(frame: *hal.syscall.SyscallFrame) SyscallError!usize {
    // Get user stack pointer
    const user_rsp = frame.getUserRsp();

    // Read ucontext from stack
    // It should be at the top of the stack (after handler popped return address)
    const ucontext = UserPtr.from(user_rsp).readValue(uapi.signal.UContext) catch {
        // If we can't read the context, we can't restore state.
        // This is a fatal error for the thread.
        console.err("sys_rt_sigreturn: Failed to read ucontext from {x}", .{user_rsp});
        sched.exitWithStatus(128 + 11); // SIGSEGV
        unreachable;
    };

    // Restore registers from mcontext
    // We update the syscall frame, which will be used to restore state on return
    const mc = ucontext.mcontext;

    frame.r15 = mc.r15;
    frame.r14 = mc.r14;
    frame.r13 = mc.r13;
    frame.r12 = mc.r12;
    frame.r11 = mc.r11;
    frame.r10 = mc.r10;
    frame.r9 = mc.r9;
    frame.r8 = mc.r8;
    frame.rdi = mc.rdi;
    frame.rsi = mc.rsi;
    frame.rbp = mc.rbp;
    frame.rbx = mc.rbx;
    frame.rdx = mc.rdx;
    frame.rcx = mc.rcx;
    frame.rax = mc.rax;

    // Restore special registers
    // Note: We don't restore CS, SS, GS, FS blindly as it might be unsafe
    // But we should restore RFLAGS and RIP
    frame.setReturnRip(mc.rip);
    frame.setUserRsp(mc.rsp); // Restore stack pointer
    frame.r11 = mc.rflags; // Sysret restores RFLAGS from R11

    // Restore signal mask
    if (sched.getCurrentThread()) |t| {
        t.sigmask = ucontext.sigmask;
    }

    // Return value is ignored since we overwrote RAX/RDI/RSI etc.
    // The syscall exit stub will restore registers from frame.
    return 0; // Dummy return
}

/// sys_set_tid_address (218) - Set pointer to thread ID
///
/// Args:
///   tidptr: Pointer to int where kernel writes TID on thread exit (and futex wake)
///
/// Returns: Thread ID
///
/// MVP: Returns current TID. musl uses this for thread cancellation/cleanup.
pub fn sys_set_tid_address(tidptr: usize) SyscallError!usize {
    _ = tidptr; // We should store this in the Thread struct if we supported it

    if (sched.getCurrentThread()) |t| {
        return @intCast(t.tid);
    }
    return 1;
}

// =============================================================================
// Scheduling
// =============================================================================

/// sys_sched_yield (24) - Yield processor to other threads
pub fn sys_sched_yield() SyscallError!usize {
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
pub fn sys_nanosleep(req_ptr: usize, rem_ptr: usize) SyscallError!usize {
    // Read timespec from userspace
    const req = UserPtr.from(req_ptr).readValue(Timespec) catch {
        return error.EFAULT;
    };

    // Validate timespec values
    if (req.tv_sec < 0 or req.tv_nsec < 0 or req.tv_nsec >= 1_000_000_000) {
        return error.EINVAL;
    }

    const sec_u: u64 = @intCast(req.tv_sec);
    if (sec_u > std.math.maxInt(u64) / 1_000_000_000) {
        return error.EINVAL;
    }

    const sec_ns: u64 = sec_u * 1_000_000_000;
    const nsec_u: u64 = @intCast(req.tv_nsec);
    if (sec_ns > std.math.maxInt(u64) - nsec_u) {
        return error.EINVAL;
    }

    const total_ns = sec_ns + nsec_u;
    if (total_ns == 0) {
        if (rem_ptr != 0) {
            const rem: Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
            UserPtr.from(rem_ptr).writeValue(rem) catch {
                return error.EFAULT;
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
            return error.EFAULT;
        };
    }

    return 0;
}

/// sys_select (23) - Synchronous I/O multiplexing
///
/// Args:
///   nfds: Highest-numbered file descriptor + 1
///   readfds: FD set to watch for read readiness
///   writefds: FD set to watch for write readiness
///   exceptfds: FD set to watch for exceptions
///   timeout: Maximum wait time
///
/// MVP: Returns -ENOSYS (not implemented)
pub fn sys_select(nfds: usize, readfds: usize, writefds: usize, exceptfds: usize, timeout: usize) SyscallError!usize {
    _ = nfds;
    _ = readfds;
    _ = writefds;
    _ = exceptfds;
    _ = timeout;
    return error.ENOSYS;
}

/// Timespec structure (Linux compatible)
pub const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

/// sys_clock_gettime (228) - Get time from a clock
///
/// MVP: Returns tick count converted to timespec.
pub fn sys_clock_gettime(clk_id: usize, tp_ptr: usize) SyscallError!usize {
    _ = clk_id; // Ignore clock ID for MVP (all clocks return same value)

    if (tp_ptr == 0) {
        return error.EFAULT;
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
        return error.EFAULT;
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
pub fn sys_read(fd_num: usize, buf_ptr: usize, count: usize) SyscallError!usize {
    if (count == 0) {
        return 0;
    }

    // Get FD from table
    const table = getGlobalFdTable();
    const fd = table.get(@intCast(fd_num)) orelse {
        return error.EBADF;
    };

    // Check if FD is readable
    if (!fd.isReadable()) {
        return error.EBADF;
    }

    // Call device read operation
    const read_fn = fd.ops.read orelse {
        return error.ENOSYS;
    };

    // Allocate kernel buffer for the read
    // For large reads, we should loop. For MVP, we cap at 4KB or alloc from heap?
    // Let's alloc from heap to be safe for now, or just limit large reads to 4096.
    // For robustness, clamping to 4096 is safer for kernel stack, but allocating is better.
    // Given the kernel heap allocator is available, let's use it.

    // Cap read size to avoid massive allocations (e.g. 1GB)
    const max_read_size = 64 * 1024; // 64KB chunks
    const read_size = @min(count, max_read_size);

    // Validate buffer for write before consuming device data to avoid data loss
    if (!isValidUserAccess(buf_ptr, read_size, AccessMode.Write)) {
        return error.EFAULT;
    }

    const kbuf = heap.allocator().alloc(u8, read_size) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kbuf);

    // Read into kernel buffer (legacy isize return from device ops)
    const bytes_read = read_fn(fd, kbuf);
    if (bytes_read < 0) {
        // Device ops return negative errno - convert to SyscallError
        // For now, map common errors; device layer will migrate separately
        const errno_val: i32 = @intCast(-bytes_read);
        return switch (errno_val) {
            5 => error.EIO,
            11 => error.EAGAIN,
            14 => error.EFAULT,
            else => error.EIO,
        };
    }

    // Copy to user memory
    const uptr = UserPtr.from(buf_ptr);
    const valid_read = @as(usize, @intCast(bytes_read));

    // Only copy what was actually read
    const copy_res = uptr.copyFromKernel(kbuf[0..valid_read]);
    if (copy_res == error.Fault) {
        return error.EFAULT;
    }

    return valid_read;
}

/// sys_write (1) - Write to file descriptor
///
/// Writes up to count bytes from buf to fd.
/// Uses FD table to dispatch to appropriate device write operation.
pub fn sys_write(fd_num: usize, buf_ptr: usize, count: usize) SyscallError!usize {
    if (count == 0) {
        return 0;
    }

    if (!isValidUserPtr(buf_ptr, count)) {
        return error.EFAULT;
    }

    // Get FD from table
    const table = getGlobalFdTable();
    const fd = table.get(@intCast(fd_num)) orelse {
        return error.EBADF;
    };

    // Check if FD is writable
    if (!fd.isWritable()) {
        return error.EBADF;
    }

    // Call device write operation
    if (fd.ops.write == null) {
        console.warn("Syscall: Write on FD {} not supported", .{fd_num});
        return error.ENOSYS;
    }

    console.debug("Syscall: write(fd={}, count={})", .{fd_num, count});

    // Cap write size
    const max_write_size = 64 * 1024;
    const write_size = @min(count, max_write_size);

    const kbuf = heap.allocator().alloc(u8, write_size) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kbuf);

    // Copy from user to kernel
    const uptr = UserPtr.from(buf_ptr);
    if (uptr.copyToKernel(kbuf) catch null == null) {
        return error.EFAULT;
    }

    // Write from kernel buffer (legacy isize return from device ops)
    // Acquire lock for atomicity
    const held = fd.lock.acquire();
    defer held.release();

    const bytes_written = do_write_locked(fd, kbuf);
    if (bytes_written < 0) {
        const errno_val: i32 = @intCast(-bytes_written);
        return switch (errno_val) {
            5 => error.EIO,
            11 => error.EAGAIN,
            14 => error.EFAULT,
            32 => error.EPIPE,
            else => error.EIO,
        };
    }
    return @intCast(bytes_written);
}

/// Helper for locked write operations
fn do_write_locked(fd: *FileDescriptor, kbuf: []const u8) isize {
    const write_fn = fd.ops.write orelse return -5; // EIO
    return write_fn(fd, kbuf);
}

/// sys_writev (20) - Write data from multiple buffers
///
/// Args:
///   fd: File descriptor
///   bvec_ptr: Pointer to iovec array
///   count: Number of iovec structs
///
/// Returns: Total bytes written or error
pub fn sys_writev(fd: usize, bvec_ptr: usize, count: usize) SyscallError!usize {
    const Iovec = extern struct {
        base: usize,
        len: usize,
    };

    if (count == 0) return 0;
    if (count > 1024) return error.EINVAL;

    // Copy iovecs from user
    const kvecs = heap.allocator().alloc(Iovec, count) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kvecs);

    const uptr = UserPtr.from(bvec_ptr);
    if (uptr.copyToKernel(std.mem.sliceAsBytes(kvecs)) catch null == null) {
        return error.EFAULT;
    }

    var total_written: usize = 0;

    // Acquire FD lock once for the entire vector operation
    // This ensures output from other threads doesn't interleave between vectors
    const table = getGlobalFdTable();
    const fd_obj = table.get(@intCast(fd)) orelse {
        // Should have been checked by sys_write logically, but here we need the object for locking
        // However, sys_write checks it internally. We need it here to lock.
        // Let's rely on sys_write checking EBADF, but we need the lock.
        // Actually, we should check invalid FD here before loop.
        return error.EBADF;
    };
    
    // Check if writable
    if (!fd_obj.isWritable()) {
        return error.EBADF;
    }

    const held = fd_obj.lock.acquire();
    defer held.release();

    for (kvecs) |vec| {
        if (vec.len == 0) continue;

        // Perform write using our locked helper, handling chunks if needed
        var offset: usize = 0;
        while (offset < vec.len) {
            // Cap to avoid huge allocations in perform_write_locked
            const remaining = vec.len - offset;
            const chunk_len = @min(remaining, 64 * 1024);
            const current_base = vec.base + offset;

            const res = perform_write_locked(fd_obj, current_base, chunk_len) catch |err| {
                if (total_written > 0) return total_written;
                return err;
            };

            total_written += res;
            offset += res;

            // If partial write occurred (less than requested for this chunk),
            // stop and return what we have
            if (res < chunk_len) {
                return total_written;
            }
        }
    }

    return total_written;
}

/// Helper: Allocates buffer, copies from user, and calls do_write_locked.
/// Caller must hold fd.lock.
fn perform_write_locked(fd: *FileDescriptor, buf_ptr: usize, count: usize) SyscallError!usize {
    if (count == 0) return 0;
    
    if (!isValidUserPtr(buf_ptr, count)) {
        return error.EFAULT;
    }

    // Cap write size
    const max_write_size = 64 * 1024;
    const write_size = @min(count, max_write_size);

    const kbuf = heap.allocator().alloc(u8, write_size) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kbuf);

    // Copy from user to kernel
    const uptr = UserPtr.from(buf_ptr);
    if (uptr.copyToKernel(kbuf) catch null == null) {
        return error.EFAULT;
    }

    const bytes_written = do_write_locked(fd, kbuf);
    if (bytes_written < 0) {
        const errno_val: i32 = @intCast(-bytes_written);
        return switch (errno_val) {
            5 => error.EIO,
            11 => error.EAGAIN,
            14 => error.EFAULT,
            32 => error.EPIPE,
            else => error.EIO,
        };
    }
    return @intCast(bytes_written);
}

/// sys_ioctl (16) - Control device
///
/// MVP: Returns -ENOTTY (inappropriate ioctl for device)
/// This is sufficient for musl isatty() checks.
pub fn sys_ioctl(fd: usize, cmd: usize, arg: usize) SyscallError!usize {
    _ = fd;
    _ = cmd;
    _ = arg;
    return error.ENOTTY;
}



// =============================================================================
// Zscapek Custom Syscalls
// =============================================================================

/// Escape control characters in user-supplied strings for safe logging.
/// Replaces non-printable characters with ^X notation to prevent:
/// - ANSI escape code injection (terminal manipulation)
/// - Kernel log spoofing (fake [KERNEL] prefixes)
/// - Screen clearing or cursor manipulation
/// Returns the number of bytes written to output.
fn escapeControlChars(input: []const u8, output: []u8) usize {
    var out_idx: usize = 0;
    for (input) |c| {
        if (c >= 0x20 and c <= 0x7E) {
            if (out_idx >= output.len) break;
            // Printable ASCII - pass through
            output[out_idx] = c;
            out_idx += 1;
        } else if (c == '\n' or c == '\t') {
            if (out_idx >= output.len) break;
            // Allow newline and tab
            output[out_idx] = c;
            out_idx += 1;
        } else if (c < 32) {
            if (out_idx + 1 >= output.len) break;
            // Control character (0x00-0x1F) - escape as ^X
            output[out_idx] = '^';
            output[out_idx + 1] = c + 64; // ^@ for 0, ^A for 1, etc.
            out_idx += 2;
        } else {
            if (out_idx + 1 >= output.len) break;
            // High bytes (0x7F-0xFF) - escape as ^?
            output[out_idx] = '^';
            output[out_idx + 1] = '?';
            out_idx += 2;
        }
    }
    return out_idx;
}

/// sys_debug_log (1000) - Write debug message to kernel log
pub fn sys_debug_log(buf_ptr: usize, len: usize) SyscallError!usize {
    if (buf_ptr == 0 and len > 0) {
        return error.EFAULT;
    }

    if (len == 0) {
        return 0;
    }

    // Limit message length for safety
    const max_len: usize = 1024;
    const copy_len = @min(len, max_len);

    // Allocate buffer on heap to preserve stack space
    const kbuf = heap.allocator().alloc(u8, copy_len) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(kbuf);

    const uptr = UserPtr.from(buf_ptr);
    const actual_len = uptr.copyToKernel(kbuf) catch {
        return error.EFAULT;
    };

    // Sanitize output: escape control characters to prevent log injection
    // Double size to account for ^X escaping of control chars
    var sanitized: [2048]u8 = undefined;
    const sanitized_len = escapeControlChars(kbuf[0..actual_len], &sanitized);

    console.debug("[USER] {s}", .{sanitized[0..sanitized_len]});

    return actual_len;
}

/// sys_putchar (1005) - Write single character to console
pub fn sys_putchar(c: usize) SyscallError!usize {
    const char: u8 = @truncate(c);
    // Use HAL serial driver directly for single character output
    hal.serial.writeByte(char);
    return 0;
}

/// sys_getchar (1004) - Read single character from keyboard (blocking)
pub fn sys_getchar() SyscallError!usize {
    while (true) {
        if (keyboard.getChar()) |c| {
            return c;
        }
        // No character available, yield and try again
        sched.yield();
    }
}

/// sys_read_scancode (1003) - Read raw keyboard scancode (non-blocking)
pub fn sys_read_scancode() SyscallError!usize {
    if (keyboard.getScancode()) |scancode| {
        return scancode;
    }
    // No scancode available
    return error.EAGAIN;
}

// =============================================================================
// Stub Handlers (Return appropriate error codes)
// =============================================================================

/// sys_open (2) - Open a file or device
///
/// Opens a file/device and returns a new file descriptor.
/// Currently only supports device files in /dev/.
pub fn sys_open(path_ptr: usize, flags: usize, mode: usize) SyscallError!usize {
    _ = mode; // Mode is ignored for device files

    // Allocate path buffer on heap to preserve stack space
    const path_buf = heap.allocator().alloc(u8, user_mem.MAX_PATH_LEN) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(path_buf);

    // Validate and read path string from userspace
    const path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (path.len == 0) {
        return error.ENOENT;
    }

    // Look up device by devfs
    if (devfs.lookupDevice(path)) |ops| {
        // Create device FD
        const fd = fd_mod.createFd(ops, @truncate(flags), null) catch {
            return error.ENOMEM;
        };
        const alloc = heap.allocator();
        errdefer alloc.destroy(fd);

        const table = getGlobalFdTable();
        const fd_num = table.allocFdNum() orelse {
            return error.EMFILE;
        };

        table.install(fd_num, fd);
        return fd_num;
    }

    // Fallback: InitRD
    // Note: This is where we would check a real VFS in the future
    const fd = fs.initrd.InitRD.instance.openFile(path, @truncate(flags)) catch |err| {
        if (err == error.FileNotFound) {
            return error.ENOENT;
        }
        return error.ENOMEM;
    };
    const alloc = heap.allocator();
    errdefer alloc.destroy(fd);

    const table = getGlobalFdTable();
    const fd_num = table.allocFdNum() orelse {
        return error.EMFILE;
    };

    table.install(fd_num, fd);
    return fd_num;
}

/// sys_close (3) - Close a file descriptor
///
/// Closes the file descriptor and releases associated resources.
pub fn sys_close(fd_num: usize) SyscallError!usize {
    const table = getGlobalFdTable();
    const result = table.close(@intCast(fd_num));
    if (result < 0) {
        return error.EBADF;
    }
    return 0;
}

/// sys_lseek (8) - Reposition read/write file offset
///
/// Repositions the file offset of the open file description associated
/// with the file descriptor fd to the argument offset according to whence.
///
/// Args:
///   fd: File descriptor
///   offset: Offset value (interpretation depends on whence)
///   whence: 0=SEEK_SET (absolute), 1=SEEK_CUR (relative to current), 2=SEEK_END (relative to end)
///
/// Returns: New offset position on success, negative errno on error
pub fn sys_lseek(fd_num: usize, offset: i64, whence: u32) SyscallError!usize {
    const table = getGlobalFdTable();

    // Get the file descriptor
    const file_desc = table.get(@intCast(fd_num)) orelse {
        return error.EBADF;
    };

    // Check if the file supports seeking
    const seek_fn = file_desc.ops.seek orelse {
        // Device doesn't support seeking (e.g., pipes, sockets, console)
        return error.ESPIPE;
    };

    // Validate whence
    if (whence > 2) {
        return error.EINVAL;
    }

    // Call the device-specific seek operation (legacy isize return)
    const result = seek_fn(file_desc, offset, whence);
    if (result < 0) {
        const errno_val: i32 = @intCast(-result);
        return switch (errno_val) {
            9 => error.EBADF,
            22 => error.EINVAL,
            29 => error.ESPIPE,
            else => error.EINVAL,
        };
    }
    return @intCast(result);
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
pub fn sys_mmap(addr: usize, len: usize, prot: usize, flags: usize, fd: usize, offset: usize) SyscallError!usize {
    _ = fd; // File mappings not supported
    _ = offset;

    // Enforce per-process memory limit (DoS protection)
    const proc = getCurrentProcess();
    const aligned_len = std.mem.alignForward(usize, len, pmm.PAGE_SIZE);

    const new_rss = @addWithOverflow(proc.rss_current, aligned_len);
    if (new_rss[1] != 0 or new_rss[0] > proc.rlimit_as) {
        return error.ENOMEM;
    }

    const uvmm = getGlobalUserVmm();
    const result = uvmm.mmap(@intCast(addr), len, @truncate(prot), @truncate(flags));

    // Update RSS on successful mapping
    if (result >= 0) {
        proc.rss_current += aligned_len;
        return @intCast(result);
    }

    // Convert negative errno
    const errno_val: i32 = @intCast(-result);
    return switch (errno_val) {
        12 => error.ENOMEM,
        22 => error.EINVAL,
        else => error.ENOMEM,
    };
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
pub fn sys_mprotect(addr: usize, len: usize, prot: usize) SyscallError!usize {
    const uvmm = getGlobalUserVmm();
    const result = uvmm.mprotect(@intCast(addr), len, @truncate(prot));
    if (result < 0) {
        const errno_val: i32 = @intCast(-result);
        return switch (errno_val) {
            12 => error.ENOMEM,
            22 => error.EINVAL,
            13 => error.EACCES,
            else => error.EINVAL,
        };
    }
    return 0;
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
pub fn sys_munmap(addr: usize, len: usize) SyscallError!usize {
    const uvmm = getGlobalUserVmm();
    const result = uvmm.munmap(@intCast(addr), len);

    // Update RSS on successful unmap (mirrors sys_mmap increment)
    if (result == 0) {
        const aligned_len = std.mem.alignForward(usize, len, pmm.PAGE_SIZE);
        const proc = getCurrentProcess();
        if (proc.rss_current >= aligned_len) {
            proc.rss_current -= aligned_len;
        } else {
            // Underflow protection - reset to 0 if accounting got out of sync
            proc.rss_current = 0;
        }
        return 0;
    }

    const errno_val: i32 = @intCast(-result);
    return switch (errno_val) {
        22 => error.EINVAL,
        else => error.EINVAL,
    };
}

/// sys_socket (41) - Create a socket
/// MVP: Returns -ENOSYS (networking not implemented)
pub fn sys_socket(domain: usize, sock_type: usize, protocol: usize) SyscallError!usize {
    _ = domain;
    _ = sock_type;
    _ = protocol;
    // Networking will be implemented in Phase 7
    return error.ENOSYS;
}

/// sys_sendto (44) - Send a message on a socket
/// MVP: Returns -ENOSYS (networking not implemented)
pub fn sys_sendto(fd: usize, buf_ptr: usize, len: usize, flags: usize, addr_ptr: usize, addrlen: usize) SyscallError!usize {
    _ = fd;
    _ = buf_ptr;
    _ = len;
    _ = flags;
    _ = addr_ptr;
    _ = addrlen;
    return error.ENOSYS;
}

/// sys_recvfrom (45) - Receive a message from a socket
/// MVP: Returns -ENOSYS (networking not implemented)
pub fn sys_recvfrom(fd: usize, buf_ptr: usize, len: usize, flags: usize, addr_ptr: usize, addrlen_ptr: usize) SyscallError!usize {
    _ = fd;
    _ = buf_ptr;
    _ = len;
    _ = flags;
    _ = addr_ptr;
    _ = addrlen_ptr;
    return error.ENOSYS;
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
pub fn sys_fork(frame: *hal.syscall.SyscallFrame) SyscallError!usize {
    const thread = @import("thread");

    // Get current process
    const parent_proc = getCurrentProcess();

    // Fork the process (copies address space and FDs)
    const child_proc = process_mod.forkProcess(parent_proc) catch |err| {
        console.err("sys_fork: Failed to fork process: {}", .{err});
        return error.ENOMEM;
    };

    // Get current thread to copy its state
    const parent_thread = sched.getCurrentThread() orelse {
        // No current thread - this shouldn't happen
        process_mod.destroyProcess(child_proc);
        return error.ESRCH;
    };

    // Create child thread
    // The child thread needs to be set up to return 0 from this syscall
    const child_thread = thread.createUserThread(
        0, // Entry point will be set from parent's saved state
        .{
            .name = parent_thread.getName(),
            .cr3 = child_proc.cr3,
            .user_stack_top = parent_thread.user_stack_top,
            .process = @ptrCast(child_proc),
        },
    ) catch {
        process_mod.destroyProcess(child_proc);
        return error.ENOMEM;
    };

    // Copy parent's kernel stack frame to child
    // This makes the child resume at the same point as parent
    copyThreadState(frame, parent_thread, child_thread);

    // Set child's return value to 0 (RAX in syscall return)
    // The return value is stored in the saved interrupt frame
    setForkChildReturn(child_thread);

    // Set up parent-child relationship in thread hierarchy
    thread.addChild(parent_thread, child_thread);

    // Add child thread to scheduler
    sched.addThread(child_thread);

    // Return child PID to parent
    return child_proc.pid;
}

/// Copy thread state from parent to child for fork
fn copyThreadState(
    parent_frame: *hal.syscall.SyscallFrame,
    parent: *@import("thread").Thread,
    child: *@import("thread").Thread,
) void {
    // Build a fresh interrupt frame for the child using the live syscall frame.
    const child_frame: *hal.idt.InterruptFrame = @ptrFromInt(child.kernel_rsp);

    child_frame.* = .{
        .r15 = parent_frame.r15,
        .r14 = parent_frame.r14,
        .r13 = parent_frame.r13,
        .r12 = parent_frame.r12,
        .r11 = 0, // Clobbered by SYSCALL, leave zeroed for cleanliness
        .r10 = parent_frame.r10,
        .r9 = parent_frame.r9,
        .r8 = parent_frame.r8,
        .rdi = parent_frame.rdi,
        .rsi = parent_frame.rsi,
        .rbp = parent_frame.rbp,
        .rdx = parent_frame.rdx,
        .rcx = parent_frame.rcx, // RCX is clobbered by SYSCALL; keep value for parity
        .rbx = parent_frame.rbx,
        .rax = parent_frame.rax,
        .vector = 0,
        .error_code = 0,
        .rip = parent_frame.getReturnRip(),
        .cs = hal.gdt.USER_CODE,
        .rflags = parent_frame.r11,
        .rsp = parent_frame.getUserRsp(),
        .ss = hal.gdt.USER_DATA,
    };

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

    const frame: *hal.idt.InterruptFrame = @ptrFromInt(child.kernel_rsp);
    frame.rax = 0; // Child gets 0 from fork()
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
pub fn sys_execve(frame: *hal.syscall.SyscallFrame, path_ptr: usize, argv_ptr: usize, envp_ptr: usize) SyscallError!usize {
    // Allocate path buffer on heap to preserve stack space
    const path_buf = heap.allocator().alloc(u8, user_mem.MAX_PATH_LEN) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(path_buf);

    // Validate and read path string from userspace
    const path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (path.len == 0) {
        return error.ENOENT;
    }

    console.debug("sys_execve: path='{s}'", .{path});

    // Parse argv and envp (collect up to 64 arguments each)
    // Heap-allocate the data buffer (128KB like Linux) to avoid stack overflow
    // and return proper E2BIG error if arguments exceed limit.
    const MAX_ARG_SIZE = 128 * 1024; // 128KB like Linux ARG_MAX
    const MAX_ARG_STRLEN = 4096; // 4KB per-argument limit (like Linux PAGE_SIZE)
    const alloc = heap.allocator();
    const arg_data_buf = alloc.alloc(u8, MAX_ARG_SIZE) catch {
        return error.ENOMEM;
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
                return error.E2BIG;
            }

            const arg_slice = user_mem.copyStringFromUser(remaining_space, arg_ptr) catch |err| {
                if (err == error.NameTooLong) return error.E2BIG;
                return error.EFAULT;
            };

            // Per-argument length limit (security hardening)
            if (arg_slice.len > MAX_ARG_STRLEN) {
                return error.E2BIG;
            }

            argv_storage[argc] = arg_slice;
            arg_data_idx += arg_slice.len + 1; // +1 for null terminator space
            argc += 1;
        }
        // Check if we hit the 64 argument limit
        if (argc == 64) {
            const ptr_addr = argv_ptr + 64 * @sizeOf(usize);
            if (UserPtr.from(ptr_addr).readValue(usize)) |arg_ptr| {
                if (arg_ptr != 0) return error.E2BIG; // More than 64 args
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
                return error.E2BIG;
            }

            const env_slice = user_mem.copyStringFromUser(remaining_space, env_ptr) catch |err| {
                if (err == error.NameTooLong) return error.E2BIG;
                return error.EFAULT;
            };

            // Per-argument length limit (security hardening)
            if (env_slice.len > MAX_ARG_STRLEN) {
                return error.E2BIG;
            }

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
        return error.ENOENT;
    };

    // Load and execute ELF
    // This creates a new address space and sets up the stack
    const result = elf.exec(file.data, argv, envp) catch |err| {
        console.err("sys_execve: Failed to exec: {}", .{err});
        return error.ENOEXEC;
    };

    console.debug("sys_execve: Loaded ELF entry={x} stack={x} cr3={x}", .{
        result.entry_point,
        result.stack_pointer,
        result.pml4_phys,
    });

    // Vulnerability Fix: Ensure entry_point is canonical low-half address
    // sysretq throws #GP if RCX (return RIP) is non-canonical.
    if (!user_mem.isValidUserPtr(result.entry_point, 1)) {
        return error.EFAULT;
    }

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

    // Clear inherited register state so the new program starts with clean GPRs.
    zeroExecveRegisters(frame);

    // Destroy old address space
    vmm.destroyAddressSpace(old_cr3);

    // Return 0 - this gets placed in RAX by the dispatcher.
    // On successful execve, this value becomes the argc seen by _start
    // (though typically argc comes from the stack, not RAX).
    return 0;
}

/// Zero general-purpose registers in the syscall frame for execve
/// Keeps RIP (rcx) and RSP intact; sets RFLAGS to a clean user value.
fn zeroExecveRegisters(frame: *hal.syscall.SyscallFrame) void {
    frame.r15 = 0;
    frame.r14 = 0;
    frame.r13 = 0;
    frame.r12 = 0;
    frame.rbp = 0;
    frame.rbx = 0;
    frame.r9 = 0;
    frame.r8 = 0;
    frame.r10 = 0;
    frame.rdx = 0;
    frame.rsi = 0;
    frame.rdi = 0;
    frame.rax = 0;
    // rcx holds return RIP for SYSRET; keep as set by setReturnRip
    // Provide clean user RFLAGS (IF=1, reserved bit 1 set)
    frame.r11 = 0x202;
}


/// sys_brk (12) - Change data segment size
pub fn sys_brk(addr: u64) SyscallError!usize {
    const proc = getCurrentProcess();

    const rollbackNewPages = struct {
        fn run(p: *Process, start: u64, len: u64) void {
            var offset: u64 = 0;
            const page_size: u64 = pmm.PAGE_SIZE;
            while (offset < len) : (offset += page_size) {
                const vaddr = start + offset;
                if (vmm.translate(p.cr3, vaddr)) |paddr| {
                    pmm.freePage(paddr);
                    vmm.unmapPage(p.cr3, vaddr) catch {};
                    if (p.rss_current >= page_size) {
                        p.rss_current -= page_size;
                    }
                }
            }
        }
    }.run;

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
    if (addr > proc.heap_break) {
        const growth = addr - proc.heap_break;
        const new_rss = @addWithOverflow(proc.rss_current, growth);
        if (new_rss[1] != 0 or new_rss[0] > proc.rlimit_as) {
            return error.ENOMEM;
        }
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
        // Check for overlap with existing VMAs
        if (proc.user_vmm.findOverlappingVma(current_break_aligned, new_break_aligned)) |_| {
            return error.ENOMEM;
        }

        // The expandHeap method in UserVmm handles mapping pages and updating VMA list.
        const res = proc.user_vmm.expandHeap(current_break_aligned, new_break_aligned);
        if (res < 0) {
            const errno_val: i32 = @intCast(-res);
            return switch (errno_val) {
                12 => error.ENOMEM,
                else => error.ENOMEM,
            };
        }

        // Update RSS manually since expandHeap relies on caller for accounting
        const size = new_break_aligned - current_break_aligned;
        proc.rss_current += size;

    } else if (new_break_aligned < current_break_aligned) {
        // Shrinking heap
        // The shrinkHeap method in UserVmm handles unmapping pages and updating VMA list.
        proc.user_vmm.shrinkHeap(current_break_aligned, new_break_aligned);

        // Update RSS manually
        const size = current_break_aligned - new_break_aligned;
        if (proc.rss_current >= size) {
            proc.rss_current -= size;
        } else {
            proc.rss_current = 0;
        }
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
pub fn sys_arch_prctl(code: usize, addr: usize) SyscallError!usize {
    const curr = sched.getCurrentThread() orelse {
        // No current thread - should not happen in normal operation
        return error.ESRCH;
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
                return error.EFAULT;
            }
            // Write current FS base to user pointer using safe copy
            UserPtr.from(addr).writeValue(curr.fs_base) catch {
                return error.EFAULT;
            };
            return 0;
        },
        ARCH_SET_GS, ARCH_GET_GS => {
            // GS is reserved for kernel use (SWAPGS, per-CPU data)
            return error.EINVAL;
        },
        else => {
            return error.EINVAL;
        },
    }
}

/// sys_get_fb_info (1001) - Get framebuffer info
///
/// Copies framebuffer dimensions and pixel format to userspace struct.
/// Returns 0 on success, -ENODEV if no framebuffer available,
/// -EFAULT for invalid pointer.
pub fn sys_get_fb_info(info_ptr: usize) SyscallError!usize {
    // FramebufferInfo is 24 bytes: 4*u32 + 6*u8 + 2*u8 padding
    const info_size: usize = 24;

    // Get framebuffer state from module (returns null if not available)
    const fb_state = framebuffer.getState() orelse {
        return error.ENODEV;
    };

    // Build framebuffer info in kernel buffer first
    // Struct layout must match FramebufferInfo in user/lib/syscall.zig
    var info_buf: [info_size]u8 = undefined;

    // Width (u32, offset 0)
    std.mem.writeInt(u32, info_buf[0..4], fb_state.width, .little);
    // Height (u32, offset 4)
    std.mem.writeInt(u32, info_buf[4..8], fb_state.height, .little);
    // Pitch (u32, offset 8)
    std.mem.writeInt(u32, info_buf[8..12], fb_state.pitch, .little);
    // Bpp (u32, offset 12) - extend u8 to u32 for struct field
    std.mem.writeInt(u32, info_buf[12..16], @as(u32, fb_state.bpp), .little);
    // Red shift (u8, offset 16)
    info_buf[16] = fb_state.red_shift;
    // Red mask size (u8, offset 17)
    info_buf[17] = fb_state.red_mask_size;
    // Green shift (u8, offset 18)
    info_buf[18] = fb_state.green_shift;
    // Green mask size (u8, offset 19)
    info_buf[19] = fb_state.green_mask_size;
    // Blue shift (u8, offset 20)
    info_buf[20] = fb_state.blue_shift;
    // Blue mask size (u8, offset 21)
    info_buf[21] = fb_state.blue_mask_size;
    // Reserved bytes (offset 22-23)
    info_buf[22] = 0;
    info_buf[23] = 0;

    // Copy to userspace using safe copy (handles faults gracefully)
    const uptr = UserPtr.from(info_ptr);
    _ = uptr.copyFromKernel(&info_buf) catch {
        return error.EFAULT;
    };

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
pub fn sys_map_fb() SyscallError!usize {
    // Get framebuffer state from module
    const fb_state = framebuffer.getState() orelse {
        return error.ENODEV;
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
        return error.ENOMEM;
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
        return error.ENOMEM;
    };
    proc.user_vmm.insertVma(fb_vma);
    proc.user_vmm.total_mapped += fb_size;

    console.debug("sys_map_fb: Mapped FB at virt={x} (phys={x}, size={d})", .{
        fb_virt_base,
        fb_state.phys_addr,
        fb_size,
    });

    // Return the mapped virtual address
    return @intCast(fb_virt_base);
}
