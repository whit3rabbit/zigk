// Custom Syscall Handlers (Zscapek-specific)
//
// Implements kernel-specific debug and I/O syscalls:
// - sys_debug_log: Write debug message to kernel log
// - sys_putchar: Write single character to console
// - sys_getchar: Read single character from keyboard (blocking)
// - sys_read_scancode: Read raw keyboard scancode (non-blocking)

const base = @import("base.zig");
const uapi = @import("uapi");
const console = @import("console");
const hal = @import("hal");
const keyboard = @import("keyboard");
const heap = @import("heap");
const sched = @import("sched");
const usb = @import("usb");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;

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
    // Poll USB events first (fallback for when MSI-X interrupts aren't firing)
    // This processes any pending HID reports from USB keyboards
    _ = usb.xhci.pollEvents();

    if (keyboard.getScancode()) |scancode| {
        return scancode;
    }
    // No scancode available
    return error.EAGAIN;
}
