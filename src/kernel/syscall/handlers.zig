// Syscall Handlers
//
// Implements Linux-compatible syscalls for userland processes.
// All handlers follow Linux x86_64 ABI: return value in RAX,
// negative values indicate error (-errno).
//
// Note: These are MVP implementations. Full implementations will
// require proper process management, file descriptors, etc.

const uapi = @import("uapi");
const console = @import("console");
const hal = @import("hal");
const sched = @import("sched");
const keyboard = @import("keyboard");

const Errno = uapi.errno.Errno;

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
/// MVP: Only supports stdin (fd 0) via keyboard driver.
pub fn sys_read(fd: usize, buf_ptr: usize, count: usize) isize {
    // Only support stdin for MVP
    if (fd != 0) {
        return Errno.EBADF.toReturn();
    }

    if (buf_ptr == 0) {
        return Errno.EFAULT.toReturn();
    }

    if (count == 0) {
        return 0;
    }

    const buf: [*]u8 = @ptrFromInt(buf_ptr);

    // Read characters from keyboard
    // For MVP, read one character at a time (blocking)
    var bytes_read: usize = 0;
    while (bytes_read < count) {
        // Try to get a character from keyboard buffer
        if (keyboard.getChar()) |c| {
            buf[bytes_read] = c;
            bytes_read += 1;

            // Return after newline (line-buffered mode)
            if (c == '\n') {
                break;
            }
        } else {
            // No character available
            if (bytes_read > 0) {
                // Return what we have
                break;
            }
            // Nothing read yet, yield and try again
            sched.yield();
        }
    }

    return @intCast(bytes_read);
}

/// sys_write (1) - Write to file descriptor
///
/// MVP: Supports stdout (1) and stderr (2) via serial console.
pub fn sys_write(fd: usize, buf_ptr: usize, count: usize) isize {
    // Only support stdout and stderr for MVP
    if (fd != 1 and fd != 2) {
        return Errno.EBADF.toReturn();
    }

    if (count == 0) {
        return 0;
    }

    // Validate user buffer pointer
    if (!isValidUserPtr(buf_ptr, count)) {
        return Errno.EFAULT.toReturn();
    }

    const buf: [*]const u8 = @ptrFromInt(buf_ptr);

    // Write to serial console
    console.print(buf[0..count]);

    return @intCast(count);
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

/// sys_open (2) - Open a file
/// MVP: Returns -ENOENT (no filesystem)
pub fn sys_open(path_ptr: usize, flags: usize, mode: usize) isize {
    _ = flags;
    _ = mode;
    // Validate path pointer (assume max path length of 4096)
    if (!isValidUserString(path_ptr, 4096)) {
        return Errno.EFAULT.toReturn();
    }
    // No filesystem in MVP
    return Errno.ENOENT.toReturn();
}

/// sys_close (3) - Close a file descriptor
/// MVP: Returns -EBADF for all FDs except pre-opened 0/1/2
pub fn sys_close(fd: usize) isize {
    // Pre-opened FDs (stdin/stdout/stderr) cannot be closed in MVP
    if (fd <= 2) {
        return 0; // Pretend success
    }
    return Errno.EBADF.toReturn();
}

/// sys_mmap (9) - Map memory pages
/// MVP: Returns -ENOMEM (no userspace memory management)
pub fn sys_mmap(addr: usize, len: usize, prot: usize, flags: usize, fd: usize, offset: usize) isize {
    _ = addr;
    _ = len;
    _ = prot;
    _ = flags;
    _ = fd;
    _ = offset;
    return Errno.ENOMEM.toReturn();
}

/// sys_mprotect (10) - Set memory protection
/// MVP: Returns -ENOMEM (no userspace memory management)
pub fn sys_mprotect(addr: usize, len: usize, prot: usize) isize {
    _ = addr;
    _ = len;
    _ = prot;
    return Errno.ENOMEM.toReturn();
}

/// sys_munmap (11) - Unmap memory pages
/// MVP: Returns -EINVAL (no userspace memory management)
pub fn sys_munmap(addr: usize, len: usize) isize {
    _ = addr;
    _ = len;
    return Errno.EINVAL.toReturn();
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
/// MVP: Returns -ENOSYS (process forking not implemented)
pub fn sys_fork() isize {
    return Errno.ENOSYS.toReturn();
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
