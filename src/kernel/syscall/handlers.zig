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
// Process Control
// =============================================================================

/// sys_exit (60) - Terminate the current thread
///
/// Note: In MVP, this terminates the current thread. Full implementation
/// would terminate the entire process (all threads).
pub fn sys_exit(status: usize) isize {
    const exit_code: i32 = @truncate(@as(isize, @bitCast(status)));
    console.debug("sys_exit: code={d}", .{exit_code});

    // Tell scheduler to exit current thread
    sched.exit();

    // Should not return, but if it does, return the status
    return @bitCast(status);
}

/// sys_exit_group (231) - Exit all threads in process group
///
/// MVP: Same as sys_exit since we don't have process groups yet.
pub fn sys_exit_group(status: usize) isize {
    return sys_exit(status);
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
    // Validate request pointer
    if (req_ptr == 0) {
        return Errno.EFAULT.toReturn();
    }

    // Read timespec from userspace
    // TODO: Proper user pointer validation
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

    if (buf_ptr == 0 and count > 0) {
        return Errno.EFAULT.toReturn();
    }

    if (count == 0) {
        return 0;
    }

    // TODO: Proper user pointer validation
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
