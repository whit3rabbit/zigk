// Error string functions (string.h)
//
// Functions for converting error codes to human-readable strings.

const errno_mod = @import("../errno.zig");

/// Get error message string for errno value
pub export fn strerror(errnum: c_int) [*:0]const u8 {
    const idx: usize = @intCast(if (errnum < 0) 0 else errnum);

    if (idx < errno_mod.error_strings.len) {
        return errno_mod.error_strings[idx];
    }

    return errno_mod.unknown_error;
}

/// Thread-safe strerror (copies to user buffer)
/// Returns 0 on success, errno on error
pub export fn strerror_r(errnum: c_int, buf: ?[*]u8, buflen: usize) c_int {
    if (buf == null or buflen == 0) return errno_mod.EINVAL;

    const msg = strerror(errnum);
    const b = buf.?;

    // Copy message to buffer
    var i: usize = 0;
    while (i < buflen - 1 and msg[i] != 0) : (i += 1) {
        b[i] = msg[i];
    }
    b[i] = 0;

    // Check if message was truncated
    if (msg[i] != 0) {
        return errno_mod.ERANGE;
    }

    return 0;
}

// perror is implemented in stdio/streams.zig since it requires stderr access
